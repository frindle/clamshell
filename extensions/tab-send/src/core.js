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

  // Tokens shorter than this are refused: the handshake is a keyed digest, so a short typed secret could be
  // guessed offline by any local program that watched one exchange. Options can generate a strong one.
  const MIN_TOKEN = 32;
  function tokenIsStrong(t) { return typeof t === 'string' && t.length >= MIN_TOKEN; }

  // Addresses that point at this machine or a private network: router pages, admin consoles, dev servers.
  // A tab for one of these is never opened without a click (see controller). Any IPv6 literal counts as local.
  function isLocalHost(u) {
    let h;
    try { h = new URL(u).hostname.toLowerCase(); } catch (e) { return true; }
    if (h.charAt(0) === '[') return true;
    // A trailing dot is the same name ("localhost." and "router." resolve exactly like the dotless forms).
    h = h.replace(/\.+$/, '');
    if (h === '') return true;
    if (h === 'localhost' || /\.(localhost|local|lan|internal|home|corp|intranet|private|localdomain|home\.arpa|box)$/.test(h)) return true;
    if (h.indexOf('.') === -1) return true; // single-label names resolve on the local network (a router called "router")
    const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(h);
    if (m) {
      const a = +m[1], b = +m[2];
      return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
        (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || a >= 224;
    }
    return false;
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

  // ---- authentication ----
  // The token is a shared secret and is never sent. Each side proves it knows the token by an HMAC over fresh
  // nonces from both sides, so a program that merely listens on the port can neither learn the token nor pass as the placer.
  //   client -> hello {cnonce, proof = H("hello|cnonce")}   (server stays silent unless this verifies)
  //   server -> challenge {snonce, proof = H("server|cnonce|snonce")}
  //   client -> auth {proof = H("client|cnonce|snonce")}      server -> ready
  // Later HTTP requests are signed with the session: H("http|snonce|seq|body"), seq strictly increasing.

  function toHex(buf) {
    return Array.prototype.map.call(new Uint8Array(buf), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
  }

  // HMAC-SHA256 as hex. `subtle` is crypto.subtle (browser) or webcrypto.subtle (Node tests).
  async function hmacHex(subtle, token, message) {
    const enc = new TextEncoder();
    const key = await subtle.importKey('raw', enc.encode(token), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    return toHex(await subtle.sign('HMAC', key, enc.encode(message)));
  }

  function randomNonce(cryptoObj) {
    return toHex(cryptoObj.getRandomValues(new Uint8Array(16)));
  }

  // Compares two strings without stopping at the first difference.
  function safeEqual(a, b) {
    if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
    let d = 0;
    for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return d === 0;
  }

  function isNonce(n) { return typeof n === 'string' && /^[0-9a-f]{32,128}$/.test(n); }

  const serverProofInput = function (cnonce, snonce) { return 'server|' + cnonce + '|' + snonce; };
  const helloProofInput = function (cnonce) { return 'hello|' + cnonce; };
  const clientProofInput = function (cnonce, snonce) { return 'client|' + cnonce + '|' + snonce; };
  const httpProofInput = function (snonce, seq, body) { return 'http|' + snonce + '|' + seq + '|' + body; };

  function signedHeaders(session, seq, sig) {
    return { 'Content-Type': 'application/json', 'X-Desk-Session': session, 'X-Desk-Seq': String(seq), 'X-Desk-Sig': sig };
  }

  // Requests are built unsigned-body first so the caller can sign the exact bytes sent.
  function sendBody(payload) { return JSON.stringify({ v: PROTOCOL_VERSION, kind: 'send', tab: payload }); }
  function bringBody() { return JSON.stringify({ v: PROTOCOL_VERSION, kind: 'bring' }); }
  function buildRequest(settings, body, auth) {
    return { url: httpUrl(settings, '/v1/tab-send'), init: { method: 'POST', headers: signedHeaders(auth.session, auth.seq, auth.sig), body } };
  }

  // First message on the event socket: a fresh nonce and a proof that the client knows the token. The placer
  // answers nothing to a peer that has not proved it first, so it never hands a keyed digest to a stranger.
  function buildHello(cnonce, proof) {
    return JSON.stringify({ v: PROTOCOL_VERSION, kind: 'hello', cnonce, proof });
  }

  function buildAuth(proof) { return JSON.stringify({ v: PROTOCOL_VERSION, kind: 'auth', proof }); }

  // Handshake messages from the placer (before the session is trusted). null if malformed.
  function parseHandshake(raw) {
    let m;
    try { m = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (e) { return null; }
    if (!m || typeof m !== 'object' || m.v !== PROTOCOL_VERSION) return null;
    if (m.kind === 'challenge' && isNonce(m.snonce) && typeof m.proof === 'string') return { kind: 'challenge', snonce: m.snonce, proof: m.proof };
    if (m.kind === 'ready') return { kind: 'ready' };
    return null;
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
    isSendableUrl, isLocalHost, tokenIsStrong, MIN_TOKEN, helloProofInput, clampTitle, sanitizeMedia, buildPayload, normalizeSettings,
    httpUrl, wsUrl, hmacHex, randomNonce, safeEqual, serverProofInput, clientProofInput, httpProofInput,
    sendBody, bringBody, buildRequest, buildHello, buildAuth, parseHandshake, parseIncoming,
    Backoff, Seen, collectPageState, applyPageState,
  };
});
