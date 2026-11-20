// Pure logic for Desk Tab Send. No browser APIs are touched here, so it runs under Node for tests.
// Loaded as a classic script in the browser (attaches to globalThis.DeskTabSend) and with require() in tests.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.DeskTabSend = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const PROTOCOL_VERSION = 1;
  const MAX_URL = 8192;
  const MAX_TITLE = 512;
  const DEFAULTS = Object.freeze({ port: 5911, token: '', targetName: 'the other Mac' });

  // Only ordinary web pages travel. about:, chrome:, moz-extension:, javascript:, data:, file: and the rest never do.
  function isSendableUrl(u) {
    if (typeof u !== 'string' || u.length === 0 || u.length > MAX_URL) return false;
    let parsed;
    try { parsed = new URL(u); } catch (e) { return false; }
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  }

  function clampTitle(t) {
    return typeof t === 'string' ? t.slice(0, MAX_TITLE) : '';
  }

  function num(n) {
    return typeof n === 'number' && Number.isFinite(n) ? n : null;
  }

  // Media state per plan 9.3 kind E: where playback was, and whether it was playing.
  function sanitizeMedia(m) {
    if (!m || typeof m !== 'object') return null;
    const time = num(m.time);
    if (time === null || time < 0) return null;
    return { time, playing: m.playing === true };
  }

  function sanitizeScroll(n) {
    const v = num(n);
    return v === null || v < 0 ? 0 : v;
  }

  // What leaves this browser for one tab. null if the page may not be sent.
  function buildPayload(tab, state, now) {
    if (!tab || !isSendableUrl(tab.url)) return null;
    const s = state || {};
    return {
      url: tab.url,
      title: clampTitle(tab.title),
      scrollX: sanitizeScroll(s.scrollX),
      scrollY: sanitizeScroll(s.scrollY),
      media: sanitizeMedia(s.media),
      sentAt: now,
    };
  }

  function normalizeSettings(raw) {
    const r = raw && typeof raw === 'object' ? raw : {};
    const port = Number.isInteger(r.port) && r.port >= 1024 && r.port <= 65535 ? r.port : DEFAULTS.port;
    const token = typeof r.token === 'string' ? r.token.slice(0, 256) : DEFAULTS.token;
    const name = typeof r.targetName === 'string' ? r.targetName.trim().slice(0, 40) : '';
    return { port, token, targetName: name || DEFAULTS.targetName };
  }

  // The placer is always on this machine; the extension never talks to anything else.
  function httpUrl(settings, path) { return 'http://127.0.0.1:' + settings.port + path; }
  function wsUrl(settings) { return 'ws://127.0.0.1:' + settings.port + '/v1/tab-events'; }

  function authHeaders(settings) {
    const h = { 'Content-Type': 'application/json' };
    if (settings.token) h.Authorization = 'Bearer ' + settings.token;
    return h;
  }

  // "Open this tab on the other Mac".
  function buildSendRequest(settings, payload) {
    return {
      url: httpUrl(settings, '/v1/tab-send'),
      init: { method: 'POST', headers: authHeaders(settings), body: JSON.stringify({ v: PROTOCOL_VERSION, kind: 'send', tab: payload }) },
    };
  }

  // "Bring this tab here": asks the placer to have the other copy send its active tab.
  function buildBringRequest(settings) {
    return {
      url: httpUrl(settings, '/v1/tab-send'),
      init: { method: 'POST', headers: authHeaders(settings), body: JSON.stringify({ v: PROTOCOL_VERSION, kind: 'bring' }) },
    };
  }

  // First message on the event socket. Browsers cannot set headers on a WebSocket, so the token goes in a message, not the URL.
  function buildHello(settings) {
    return JSON.stringify({ v: PROTOCOL_VERSION, kind: 'hello', token: settings.token });
  }

  // A message from the placer. Anything malformed or unknown is dropped (returns null), never thrown.
  function parseIncoming(raw) {
    let m;
    try { m = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (e) { return null; }
    if (!m || typeof m !== 'object' || m.v !== PROTOCOL_VERSION) return null;
    const id = typeof m.id === 'string' && m.id.length > 0 && m.id.length <= 128 ? m.id : null;
    if (m.kind === 'send-active-tab') return id ? { kind: 'send-active-tab', id } : null;
    if (m.kind === 'open-tab') {
      const t = m.tab;
      if (!id || !t || !isSendableUrl(t.url)) return null;
      return {
        kind: 'open-tab',
        id,
        tab: {
          url: t.url,
          title: clampTitle(t.title),
          scrollX: sanitizeScroll(t.scrollX),
          scrollY: sanitizeScroll(t.scrollY),
          media: sanitizeMedia(t.media),
        },
      };
    }
    return null;
  }

  // Reconnect delays: base, 2x, 4x ... capped. `jitter` is a 0..1 value so tests are deterministic.
  class Backoff {
    constructor(opts) {
      const o = opts || {};
      this.base = o.base || 1000;
      this.max = o.max || 30000;
      this.attempt = 0;
    }
    next(jitter) {
      const j = typeof jitter === 'number' ? Math.min(Math.max(jitter, 0), 1) : 0;
      const d = Math.min(this.max, this.base * Math.pow(2, this.attempt));
      this.attempt += 1;
      return Math.round(d * (1 - 0.2 * j));
    }
    reset() { this.attempt = 0; }
  }

  // Remembers the last N message ids so a relayed message that arrives twice opens one tab.
  class Seen {
    constructor(size) { this.size = size || 50; this.ids = []; }
    check(id) {
      if (this.ids.indexOf(id) !== -1) return false;
      this.ids.push(id);
      if (this.ids.length > this.size) this.ids.shift();
      return true;
    }
  }

  // ---- page side (content script), written against injected win/doc so tests need no DOM ----

  function pickMedia(doc) {
    const list = Array.prototype.slice.call(doc.querySelectorAll('video, audio'));
    const usable = list.filter(function (e) { return Number.isFinite(e.duration) && e.duration > 0; });
    const playing = usable.find(function (e) { return !e.paused && !e.ended; });
    return playing || usable[0] || null;
  }

  function collectPageState(win, doc) {
    const el = pickMedia(doc);
    return {
      scrollX: sanitizeScroll(win.scrollX),
      scrollY: sanitizeScroll(win.scrollY),
      media: el ? { time: el.currentTime, playing: !el.paused && !el.ended } : null,
    };
  }

  // Restores scroll (retrying while the page is still too short to scroll that far) and media position.
  // `schedule(fn, ms)` is setTimeout in the browser. Resolves with what was applied.
  function applyPageState(win, doc, tab, schedule, opts) {
    const o = opts || {};
    const tries = o.tries || 20;
    const every = o.everyMs || 250;
    const result = { scrolled: false, media: false };
    return new Promise(function (resolve) {
      const el = tab.media ? pickMedia(doc) : null;
      if (el && tab.media) {
        try {
          el.currentTime = tab.media.time;
          result.media = true;
          // Browsers may refuse to start playback without a user gesture; that is fine, it stays paused at the right second.
          if (tab.media.playing) { const p = el.play(); if (p && typeof p.catch === 'function') p.catch(function () {}); }
        } catch (e) { /* leave media as it is */ }
      }
      let n = 0;
      (function step() {
        n += 1;
        win.scrollTo(tab.scrollX, tab.scrollY);
        const reachedY = Math.abs(win.scrollY - tab.scrollY) < 2;
        const reachedX = Math.abs(win.scrollX - tab.scrollX) < 2;
        if ((reachedX && reachedY) || n >= tries) { result.scrolled = reachedX && reachedY; resolve(result); return; }
        schedule(step, every);
      })();
    });
  }

  return {
    PROTOCOL_VERSION, MAX_URL, MAX_TITLE, DEFAULTS,
    isSendableUrl, clampTitle, sanitizeMedia, buildPayload, normalizeSettings,
    httpUrl, wsUrl, buildSendRequest, buildBringRequest, buildHello, parseIncoming,
    Backoff, Seen, collectPageState, applyPageState,
  };
});
