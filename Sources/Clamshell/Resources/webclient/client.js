// Browser client for Clamshell's native streaming protocol (PROTOCOL.md).
// Vanilla ES module, no build step, no dependencies: WebCodecs decodes video,
// Canvas 2D renders it, WebSocket carries the framed protocol, native
// Clipboard API + the existing /clipboard HTTP bridge sync the pasteboard.
//
// Mirrors ClamshellViewer/Sources/StreamClient.swift's behavior: reconnect
// forever with capped exponential backoff, request H.264 for browser
// compatibility (see WebServer.swift's streamBridge doc comment for why),
// verify decode support before committing, and surface the same banners the
// native client shows (software encoding, host locked).
//
// Audio: AUDIO_FRAME (0x13) is played by audio.js once the user turns sound
// on from the menu (browsers only let audio start from a click).

import { codeToMacVK } from '/client/keymap.js';
import {
  helloPayload, clientDisplaysPayload, attachResizeReporter, loadPrefs, savePrefs, normalizePrefs, parseSize, SIZE_PRESETS, pickCodec, parseLockState, shouldShowVncFallback, shouldAutoVncAfterFailures,
} from '/client/hello.js';
import {
  HeldKeys, reconnectDelay, frameAction, ctrlAsCmdDefault, remapKey, modifierFlags, keepaliveDue,
  CAP, hostHas, setHostCapabilities, protocolButton, claimsButton,
  encodeMouseMove, encodeMouseButton, encodeKey, encodeScroll, encodeMouseRelative, encodeButtonAtCursor,
} from '/client/input.js';
import { AudioPlayer, audioSupported } from '/client/audio.js';
import {
  fullscreenApi, isStandalone, fullscreenMode, loadStartFullscreen, saveStartFullscreen, shouldAutoEnter,
} from '/client/fullscreen.js';
import { buildCredentialForm, loginPayload, loginProblem, LoginLimiter } from '/client/login.js';
import {
  AuthFlow, KnownHosts, WEB_CAPS, hasWebCrypto, idbStore, memoryStore, loadDeviceKey, loadKnownHosts,
  saveKnownHosts, webDeviceName, normalizeAddress,
} from '/client/auth.js';

const params = new URLSearchParams(location.search);
const display = ['a', 'b', 'c'].includes(params.get('display')) ? params.get('display') : 'a';
const isPrimary = display === 'a';
// The clipboard endpoint needs a token. The server writes it into this page;
// a `?token=` in the address is used first, for a page opened with one.
function pageClipboardToken() {
  const meta = document.querySelector('meta[name="clamshell-clipboard-token"]');
  if (!meta || !meta.content) return null;
  try { return decodeURIComponent(meta.content); } catch (e) { return null; }
}
const token = params.get('token') || pageClipboardToken();

// Browser-facing WS bridge ports (see WebServer.swift streamBridgePorts):
// one per display, each proxying to the matching local StreamServer port.
const BRIDGE_PORT = { a: 5906, b: 5907, c: 5908 }[display];

// Message types (StreamProtocol.swift).
const T = {
  HELLO: 0x01, HELLO_ACK: 0x02, CLIENT_DISPLAYS: 0x03, STREAM_STATUS: 0x04, HOST_LOCK_STATE: 0x05,
  PING: 0x07, VIDEO_FRAME: 0x10, KEYFRAME_REQUEST: 0x11, AUDIO_FRAME: 0x13,
  RESTART_REQUEST: 0x60, RESTART_RESULT: 0x61, LOGIN_CREDENTIALS: 0x5C,
  MOUSE_MOVE: 0x20, MOUSE_BUTTON: 0x21, KEY: 0x22, SCROLL: 0x23, CLIPBOARD: 0x30,
};

// Re-report the window size to the host (CLIENT_DISPLAYS) after resizing stops;
// the initial size rides in HELLO.
// Monitor-size preference (menu: Display size / Retina), kept per browser.
function safeStorage() { try { return window.localStorage; } catch (e) { return null; } }
let displayPrefs = (() => { const st = safeStorage(); return st ? loadPrefs(st) : normalizePrefs(null); })();

// Codec to request: HEVC when this browser can decode it, until an HEVC
// decoder error makes us fall back to H.264 for the rest of the session.
let wantCodec = 1;
let h264Only = false;
try { h264Only = window.sessionStorage.getItem('clamshell.h264') === '1'; } catch (e) { /* ignore */ }

attachResizeReporter(window, (p) => send(frameMsg(T.CLIENT_DISPLAYS, p)), 250, globalThis, () => displayPrefs);

const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const vncFallback = document.getElementById('vncFallback');
const statusEl = document.getElementById('status');
const statusText = document.getElementById('statusText');
const menu = document.getElementById('hoverMenu');
const statsEl = document.getElementById('stats');
const fullscreenBtn = document.getElementById('fullscreenBtn');
const soundBtn = document.getElementById('soundBtn');

function showStatus(text) {
  statusText.textContent = text;
  statusEl.style.display = 'flex';
  canvas.classList.add('stale'); // keep the last picture, dimmed, behind the message
}
function hideStatus() {
  const ul = document.getElementById('unlockLink'); if (ul) ul.remove();
  statusEl.style.display = 'none';
  canvas.classList.remove('stale');
}
const swBanner = document.getElementById('swBanner');
const lockBanner = document.getElementById('lockBanner');
const errBanner = document.getElementById('errBanner');
const qualityDot = document.getElementById('qualityDot');

// Store original lock banner text for restoration
const originalLockBannerText = lockBanner.textContent;

// noVNC lock-screen fallback page. It MUST point at "/vnc.html", not "/":
// WebServer's "/" handler 302-redirects to "/client" (this same native
// client that is looping), so a bare-slash fallback just reloads the broken
// page. "/vnc.html" is served directly (with the clipboard bridge injected)
// on both transports -- port 5901 direct-LAN, or same-origin over the
// Cloudflare Tunnel (README "Browser access"), which routes this hostname to
// the same WebServer.
// Over LAN TLS (https on a port, not through the tunnel) noVNC is told where
// the TLS websocket is: host, port 5902 and encrypt=1, plus autoconnect.
const vncFallbackURL = location.protocol === 'https:'
  ? (location.port
    ? `${location.origin}/vnc.html?autoconnect=1&host=${encodeURIComponent(location.hostname)}&port=5902&encrypt=1`
    : `${location.origin}/vnc.html`)
  : `http://${location.hostname}:5901/vnc.html`;

// Display size picker, Retina toggle. In-DOM buttons (a native <select> loses
// its popup when the hover menu closes); clicks keep the menu open.
{
  const panel = document.getElementById('hoverPanel');
  const sizeBtn = document.getElementById('sizeBtn');
  const sizeList = document.getElementById('sizeList');
  const retinaBtn = document.getElementById('retinaBtn');
  const customRow = document.getElementById('customRow');
  const customInput = document.getElementById('customInput');
  const customApply = document.getElementById('customApply');
  const sizeLabel = () => {
    const p = displayPrefs;
    if (p.size === 'custom') return p.custom;
    return (SIZE_PRESETS.find((x) => x.id === p.size) || SIZE_PRESETS[0]).label;
  };
  const refresh = () => {
    sizeBtn.textContent = `Display size: ${sizeLabel()}`;
    retinaBtn.textContent = `Retina: ${displayPrefs.retina ? '2\u00d7' : '1\u00d7'}`;
    customRow.hidden = displayPrefs.size !== 'custom' && !customRow.dataset.editing;
    for (const b of sizeList.querySelectorAll('button')) b.classList.toggle('on', b.dataset.id === displayPrefs.size);
  };
  for (const p of SIZE_PRESETS) {
    const b = document.createElement('button');
    b.dataset.id = p.id;
    b.textContent = p.label;
    b.addEventListener('click', () => {
      if (p.id === 'custom') {
        customRow.dataset.editing = '1';
        customInput.value = displayPrefs.custom || '';
        refresh();
        customInput.focus();
        return;
      }
      delete customRow.dataset.editing;
      displayPrefs = normalizePrefs({ ...displayPrefs, size: p.id });
      refresh(); applyDisplayPrefs();
    });
    sizeList.appendChild(b);
  }
  sizeBtn.addEventListener('click', () => { sizeList.hidden = !sizeList.hidden; });
  retinaBtn.addEventListener('click', () => {
    displayPrefs = normalizePrefs({ ...displayPrefs, retina: !displayPrefs.retina });
    refresh(); applyDisplayPrefs();
  });
  const applyCustom = () => {
    const sz = parseSize(customInput.value);
    customInput.classList.toggle('bad', !sz);
    if (!sz) return;
    delete customRow.dataset.editing;
    displayPrefs = normalizePrefs({ ...displayPrefs, size: 'custom', custom: `${sz.w}x${sz.h}` });
    refresh(); applyDisplayPrefs();
  };
  customApply.addEventListener('click', applyCustom);
  customInput.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Enter') applyCustom(); });
  // Keep the menu open while it is being used.
  panel.addEventListener('click', () => menu.classList.add('open'));
  document.addEventListener('pointerdown', (e) => { if (!menu.contains(e.target)) menu.classList.remove('open'); });
  refresh();
}

// Populate the hover menu with the other two displays.
{
  const panel = document.getElementById('hoverPanel');
  for (const d of ['a', 'b', 'c']) {
    if (d === display) continue;
    const a = document.createElement('a');
    a.href = d === 'a' ? '/client' : `/client?display=${d}`;
    a.target = '_blank';
    a.rel = 'noopener';
    a.textContent = `Open Display ${d.toUpperCase()}`;
    panel.insertBefore(a, statsEl);
  }
}

// MARK: - Wire framing

function frameMsg(type, payload = new Uint8Array(0)) {
  const buf = new Uint8Array(5 + payload.length);
  buf[0] = type;
  new DataView(buf.buffer).setUint32(1, payload.length, false);
  buf.set(payload, 5);
  return buf;
}

function f32(v) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setFloat32(0, v, false);
  return b;
}

function concat(...parts) {
  const len = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(len);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

function beU16(buf, off) { return (buf[off] << 8) | buf[off + 1]; }
function beU32(buf, off) {
  return ((buf[off] << 24) | (buf[off + 1] << 16) | (buf[off + 2] << 8) | buf[off + 3]) >>> 0;
}
function beF32(buf, off) { return new DataView(buf.buffer, buf.byteOffset + off, 4).getFloat32(0, false); }

// MARK: - WebSocket connection + reconnect (mirrors StreamClient.swift)

let ws = null;
let reconnectAttempt = 0;
let wantConnection = true;
let reconnectTimer = null;
let countdownTimer = null;
// Track fallback reasons to avoid conflicts between failure-based and host-locked states
let lockedByHost = false;
let lastLockState = null; // last HOST_LOCK_STATE, so a dead VNC link is never auto-loaded
let fallbackDueToFailure = false;

const CONNECT_TIMEOUT_MS = 10000;

// The device key and the saved Macs live in this browser's IndexedDB (auth.js).
// Without IndexedDB they last only as long as the page.
let identityPromise = null;
// The message about an unreadable saved copy, while it is on screen. Nothing
// else hid it, so it stayed through every reconnect on the same page.
let knownHostsBanner = null;
function loadIdentity() {
  if (!identityPromise) {
    identityPromise = (async () => {
      const store = typeof indexedDB === 'undefined' ? memoryStore() : idbStore();
      if (!hasWebCrypto()) {
        // A plain http page: no key to prove anything with (see auth.js).
        return { store, deviceKey: null, known: new KnownHosts() };
      }
      const deviceKey = await loadDeviceKey(store);
      const { known, damaged, why } = await loadKnownHosts(store);
      // `why` says which check failed (never an address), so a screenshot is enough to diagnose it.
      if (damaged) {
        knownHostsBanner = `The saved Macs could not be read (${why}). Each will be checked again as if new.`;
        showBanner(errBanner, knownHostsBanner);
      }
      return { store, deviceKey, known };
    })().catch((e) => { identityPromise = null; throw e; });
  }
  return identityPromise;
}

function showBanner(el, text) { el.textContent = text; el.classList.add('show'); }

let connectSeq = 0;
let current = null; // the connection in charge: { sock, flow, timers, end, url }
let flow = null;
let nextCarry = null; // what the flow wants the next attempt to know (auth.js newCarry)

function connect() {
  clearTimeout(reconnectTimer); reconnectTimer = null;
  clearInterval(countdownTimer); countdownTimer = null;
  const attempt = ++connectSeq;
  loadIdentity().then((id) => { if (attempt === connectSeq && wantConnection) openSocket(id); }, (err) => {
    if (attempt !== connectSeq) return;
    console.warn('[Clamshell] could not load the device key:', err && err.code ? err.code : 'error');
    scheduleReconnect();
  });
}

function openSocket(id) {
  const wsUrl = location.protocol === 'https:'
    // Network.framework's server-side WS listener can't see the handshake
    // path, so path-based disambiguation happens at the Cloudflare Tunnel
    // layer instead: /ws/{a,b,c} are separate ingress rules pointing
    // directly at each display's dedicated bridge port (5906/5907/5908) —
    // the Mac side needs no path parsing since each port is already
    // single-purpose.
    // Served over https on a port (LAN TLS, README) rather than through the
    // tunnel on 443: the bridge ports speak TLS themselves.
    ? (location.port ? `wss://${location.hostname}:${BRIDGE_PORT}` : `wss://${location.host}/ws/${display}`)
    : `ws://${location.hostname}:${BRIDGE_PORT}`;
  const sock = new WebSocket(wsUrl);
  ws = sock;
  sock.binaryType = 'arraybuffer';
  const conn = { sock, flow: null, timers: {}, end: null, url: wsUrl, known: id.known, id };
  conn.flow = new AuthFlow({
    deviceKey: id.deviceKey, deviceName: webDeviceName(navigator.userAgent), dialledURL: wsUrl,
    known: id.known, carry: nextCarry || undefined, caps: WEB_CAPS, makeHello: helloMessage,
    emit: (action) => onFlowAction(conn, action),
  });
  nextCarry = null;
  flow = conn.flow;
  current = conn;
  // A handshake that never completes (tunnel up, host asleep) can hang for a
  // minute or more before the browser gives up. Cut it short and retry.
  const connectTimeout = setTimeout(() => {
    if (sock.readyState === WebSocket.CONNECTING) sock.close();
  }, CONNECT_TIMEOUT_MS);
  sock.onopen = () => {
    clearTimeout(connectTimeout);
    if (sock !== ws) return;
    // Nothing is sent here: the host speaks first (auth.js AuthFlow).
    audio.reset();
    showStatus('Connecting…');
    conn.flow.opened();
  };
  sock.onmessage = (ev) => {
    if (sock !== ws) return;
    const buf = new Uint8Array(ev.data);
    if (buf.length < 5) return;
    const type = buf[0];
    const len = beU32(buf, 1);
    const payload = buf.subarray(5, 5 + len);
    conn.flow.received(type, payload);
  };
  sock.onclose = () => {
    clearTimeout(connectTimeout);
    if (sock !== ws) return; // an older socket; a newer one is already in charge
    // The flow decides whether this ends the attempt (it does not while a
    // question about a host is open, because the flow closed the socket itself).
    conn.flow.socketClosed();
  };
  sock.onerror = () => {}; // onclose always follows
}

// The flow only describes what to do; this does it.
function onFlowAction(conn, a) {
  if (conn !== current) return;
  switch (a.do) {
    case 'send': rawSend(conn.sock, a.data); break;
    case 'startTimer':
      clearTimeout(conn.timers[a.timer]);
      conn.timers[a.timer] = setTimeout(() => { conn.flow.timerFired(a.timer); }, a.seconds * 1000);
      break;
    case 'cancelTimer': clearTimeout(conn.timers[a.timer]); delete conn.timers[a.timer]; break;
    case 'state': renderAuthState(conn, a.state); break;
    case 'deliver': handle(a.type, a.payload); break;
    case 'change': applyKnownChange(conn, a.change); break;
    case 'hostCapabilities': setHostCapabilities(a.bits); updateLoginButton(); break;
    case 'close': try { conn.sock.close(); } catch (e) { /* ignore */ } break;
    case 'end': onFlowEnd(conn, a.end, a.reason); break;
    default: break;
  }
}

function onFlowEnd(conn, end, reason) {
  for (const t of Object.values(conn.timers)) clearTimeout(t);
  conn.timers = {};
  conn.end = end;
  console.warn('[Clamshell] connection ended:', end.kind, '-', reason);
  try { conn.sock.close(); } catch (e) { /* ignore */ }
  if (end.kind === 'stop') {
    // A refusal screen is showing. Do not retry and do not cover it with noVNC.
    resetSessionState();
    dropFailureFallback();
    return;
  }
  nextCarry = end.kind === 'reconnect' ? end.carry : null;
  if (end.kind === 'reconnect' && end.after === 0) { resetSessionState(); connect(); return; }
  if (end.kind === 'reconnect') { scheduleReconnect({ delay: end.after, quiet: true }); return; }
  scheduleReconnect();
}

function dropFailureFallback() {
  if (!fallbackDueToFailure || lockedByHost) return;
  fallbackDueToFailure = false;
  vncFallback.classList.remove('show');
  vncFallback.src = 'about:blank';
  lockBanner.textContent = originalLockBannerText;
  lockBanner.classList.remove('show');
}

function resetSessionState() {
  decoder = null;
  kbps = 0;
  // The host has forgotten what we were holding; forget it here too.
  held.releaseAll();
  buttonsDown.clear();
}

let saving = Promise.resolve();
function applyKnownChange(conn, change) {
  conn.known.apply(change, Math.floor(Date.now() / 1000));
  saving = saving.then(() => saveKnownHosts(conn.id.store, conn.known)).then(() => {
    // The saved copy was just rewritten from what could be read: the message
    // about the old one no longer applies.
    if (knownHostsBanner && errBanner.textContent === knownHostsBanner) errBanner.classList.remove('show');
    knownHostsBanner = null;
  }).catch(() => {
    showBanner(errBanner, 'This browser could not save the Mac it just checked. It will ask again next time.');
  });
}

function scheduleReconnect({ delay = null, quiet = false } = {}) {
  if (!wantConnection || reconnectTimer) return;
  resetSessionState();
  let left;
  if (delay === null) { reconnectAttempt++; left = reconnectDelay(reconnectAttempt); } // 1,2,4,8,10,10s…
  else left = delay;
  const offline = navigator.onLine === false;
  const text = () => offline
    ? 'This device is offline — will reconnect when the network is back'
    : `Connection lost — reconnecting in ${left} s (try ${reconnectAttempt})`;
  if (!quiet) {
    showStatus(text());
    clearInterval(countdownTimer);
    countdownTimer = setInterval(() => { if (left > 1) { left--; showStatus(text()); } }, 1000);
  }

  // Check if we should fall back to noVNC after repeated failures
  if (delay === null && !fallbackDueToFailure && !lockedByHost && shouldAutoVncAfterFailures(lastLockState, reconnectAttempt)) {
    fallbackDueToFailure = true;
    vncFallback.src = vncFallbackURL;
    vncFallback.classList.add('show');
    // Show appropriate banner text for failure-based fallback
    lockBanner.textContent = "Can't reach the desktop — showing the login screen instead.";
    lockBanner.classList.add('show');
  }

  reconnectTimer = setTimeout(() => { reconnectTimer = null; if (wantConnection) connect(); }, left * 1000);
  if (delay === null && reconnectAttempt >= 2) {
    showStatus(offlineShell
      ? 'Not answering. If the Mac restarted, its disk may be waiting to be unlocked.'
      : 'Not answering. If the Mac restarted: Unlock from the iPad/Windows app.');
    showUnlockLink();
  }
}

// "Unlock disk" for a page that stays open while the Mac is down: a plain link to the browser SSH
// terminal (unlockTerminalURL in the host's preferences). Nothing is shown when it is not set.
// The page never sees a password: the terminal is a separate site.
function showUnlockLink() {
  const meta = document.querySelector('meta[name="clamshell-unlock-terminal-url"]');
  let url = '';
  try { url = decodeURIComponent((meta && meta.content) || ''); } catch (e) { return; }
  if (!/^https:\/\//i.test(url) || document.getElementById('unlockLink')) return;
  const a = document.createElement('a');
  a.id = 'unlockLink'; a.href = url; a.target = '_blank'; a.rel = 'noopener noreferrer';
  a.textContent = 'Unlock disk'; a.style.cssText = 'margin-left:12px;color:#8cf;';
  statusText.after(a);
}

// Don't sit out the rest of a backoff when we have a good reason to think
// the connection will work now: the network just came back, or the user
// just returned to the tab.
function reconnectNow() {
  if (!reconnectTimer || !wantConnection) return;
  showStatus('Reconnecting…');
  connect();
}
window.addEventListener('online', reconnectNow);

// Retries forever regardless of tab visibility (no explicit disconnect UI) —
// navigating away / closing the tab is what actually stops it, matching the
// native client's "retries forever until user disconnects" contract.

let lastSentAt = Date.now();
// Everything the page sends goes through the flow: it drops messages until the
// host has been verified and let this browser in, and seals them after that.
function send(data) {
  if (flow) flow.send(data);
}
function rawSend(sock, data) {
  if (sock === ws && sock.readyState === WebSocket.OPEN) { sock.send(data); lastSentAt = Date.now(); }
}

// Keepalive (see input.js keepaliveDue). Old hosts skip the unknown type.
setInterval(() => {
  if (ws && ws.readyState === WebSocket.OPEN && keepaliveDue(Date.now(), lastSentAt)) send(frameMsg(T.PING));
}, 5000);

// The flow sends this when the session may start (sealed after a verified accept).
function helloMessage() {
  return frameMsg(T.HELLO, helloPayload(window.innerWidth, window.innerHeight, window.devicePixelRatio,
    { prefs: displayPrefs, codec: wantCodec }));
}

// MARK: - Auth screens (plain markup; wording as in the iOS app)

const authPanel = document.getElementById('authPanel');
const authTitle = document.getElementById('authTitle');
const authText = document.getElementById('authText');
const authRows = document.getElementById('authRows');
const authButtons = document.getElementById('authButtons');
const authForget = document.getElementById('authForget');
const unverifiedBanner = document.getElementById('unverifiedBanner');

function hideCard() { authPanel.hidden = true; }

function showCard({ title, text, rows = [], buttons = [], forgetHostId = null }) {
  authTitle.textContent = title;
  authText.textContent = text;
  authRows.replaceChildren(...rows.map((r) => {
    const d = document.createElement('div');
    d.className = 'authRow';
    d.textContent = r;
    return d;
  }));
  const made = buttons.map(([label, secondary, fn]) => {
    const b = document.createElement('button');
    b.textContent = label;
    if (secondary) b.className = 'secondary';
    b.addEventListener('click', fn);
    return b;
  });
  authButtons.replaceChildren(...made);
  authForget.replaceChildren();
  if (forgetHostId) renderForget(forgetHostId);
  statusEl.style.display = 'none';
  canvas.classList.add('stale');
  authPanel.hidden = false;
  if (made[0]) made[0].focus();
}

// A separate, small control that never connects, and asks first.
function renderForget(hostId) {
  const link = document.createElement('button');
  link.className = 'link';
  link.textContent = 'Forget saved identity';
  link.addEventListener('click', () => {
    const q = document.createElement('span');
    q.textContent = 'Forget the saved identity of this Mac? It will be checked again as if new the next time. ';
    const yes = document.createElement('button');
    yes.className = 'link';
    yes.textContent = 'Forget';
    yes.addEventListener('click', () => {
      const conn = current;
      if (conn) applyKnownChange(conn, { kind: 'forget', hostId });
      authForget.textContent = 'Saved identity forgotten. Reload this page to connect.';
    });
    const no = document.createElement('button');
    no.className = 'link';
    no.textContent = 'Keep';
    no.addEventListener('click', () => { authForget.replaceChildren(link); });
    authForget.replaceChildren(q, yes, no);
  });
  authForget.replaceChildren(link);
}

// Stops trying for good, as the Cancel and Close buttons of the cards do.
function userDisconnect() {
  wantConnection = false;
  connectSeq++;
  clearTimeout(reconnectTimer); reconnectTimer = null;
  clearInterval(countdownTimer); countdownTimer = null;
  const conn = current;
  if (conn) {
    for (const t of Object.values(conn.timers)) clearTimeout(t);
    conn.timers = {};
    try { conn.sock.close(); } catch (e) { /* ignore */ }
  }
  setHostCapabilities(0);
  updateLoginButton();
  resetSessionState();
  hideCard();
  showStatus('Disconnected. Reload this page to connect again.');
}

function renderAuthState(conn, s) {
  unverifiedBanner.classList.toggle('show', s.kind === 'connected' && !s.verified);
  if (s.kind !== 'connected' && s.kind !== 'connecting') unverifiedBanner.classList.remove('show');
  const savedHostId = () => {
    const addr = normalizeAddress(conn.url);
    const st = addr ? conn.known.standing(addr) : null;
    return st && st.kind === 'host' ? st.id : null;
  };
  switch (s.kind) {
    case 'connecting':
      hideCard();
      showStatus('Connecting…');
      break;
    case 'waiting':
      showCard({
        title: 'Waiting for approval',
        text: `On ${s.hostName}, open Clamshell in the menu bar and approve this browser. Check that the Mac shows the same fingerprint for it.`,
        rows: [`This browser: ${s.deviceName}, ${s.deviceFingerprint}`, `The Mac: ${s.hostName}, ${s.hostFingerprint}`],
        buttons: [['Cancel', true, userDisconnect]],
      });
      break;
    case 'confirmHost':
      showCard({
        title: 'Is this your Mac?',
        text: `${s.hostName} let this browser in without asking. Before you connect, check that this fingerprint matches the one under Devices in Clamshell's menu on the Mac.`,
        rows: [s.fingerprint],
        buttons: [['Connect', false, () => { conn.flow.answered(true); }], ['Cancel', true, () => { conn.flow.answered(false); }]],
      });
      break;
    case 'changedIdentity':
      showCard({
        title: "This Mac's identity has changed",
        text: `The computer at ${s.address} is not the one this browser saved. Clamshell may have been set up again on it, it may be a different computer, or someone may be in the way of the connection. Nothing was sent to it.`,
        rows: [`Saved: ${s.savedFingerprint}`, `Now showing: ${s.nowFingerprint}`],
        buttons: [['Close', true, userDisconnect]],
        forgetHostId: savedHostId(),
      });
      break;
    case 'didNotIdentify':
      showCard({
        title: 'This Mac did not identify itself',
        text: `${s.hostName} has always proved who it is before, and this time it did not. Nothing was sent to it.`,
        buttons: [['Close', true, userDisconnect]],
        forgetHostId: savedHostId(),
      });
      break;
    case 'askUnverified':
      showCard({
        title: "This Mac can't prove who it is",
        text: `It may be running a version of Clamshell older than 0.12. Whatever you type goes to the computer that answers at ${s.address}. Connect anyway?`,
        buttons: [['Connect', false, () => { conn.flow.answered(true); }], ['Cancel', true, () => { conn.flow.answered(false); }]],
      });
      break;
    case 'needsHttps':
      showCard({ title: 'This page cannot prove which device it is', text: s.text, buttons: [['Close', true, userDisconnect]] });
      break;
    case 'denied':
      showCard({
        title: 'This Mac turned this browser away',
        text: `It was denied or revoked on ${s.hostName}. It can be allowed again under Devices in Clamshell's menu on the Mac.`,
        buttons: [['Close', true, userDisconnect]],
      });
      break;
    case 'invalid':
      showCard({
        title: 'This Mac did not accept this browser',
        text: `${s.hostName} could not accept this browser's request. Nothing more was sent.`,
        buttons: [['Close', true, userDisconnect]],
      });
      break;
    case 'busy':
      showCard({
        title: 'The Mac is busy',
        text: `The Mac is busy. Trying again in ${s.retryIn} s.`,
        buttons: [['Cancel', true, userDisconnect]],
      });
      break;
    case 'connected':
      onConnected();
      break;
    default: // 'failed': the reconnect logic shows the status
      break;
  }
}

function onConnected() {
  hideCard();
  reconnectAttempt = 0;
  showStatus('Connected — waiting for video…');
  // The native stream is back. If noVNC was showing only because we could
  // not connect -- as opposed to the host reporting itself locked -- drop
  // back to the canvas. A genuinely locked host keeps noVNC up even with
  // the socket open, so lockedByHost wins.
  dropFailureFallback();
}

// Re-send the size right away (menu choice changed). The host resizes in place.
function applyDisplayPrefs() {
  const st = safeStorage();
  if (st) savePrefs(st, displayPrefs);
  send(frameMsg(T.CLIENT_DISPLAYS, clientDisplaysPayload(
    window.innerWidth, window.innerHeight, window.devicePixelRatio, displayPrefs)));
}

// HEVC decoder failed mid-stream: reconnect asking for H.264, and stick with
// it until the tab is closed.
function fallBackToH264(reason) {
  if (wantCodec === 1) return false;
  console.warn('[Clamshell] HEVC decode failed, reconnecting with H.264:', reason);
  wantCodec = 1;
  h264Only = true;
  try { window.sessionStorage.setItem('clamshell.h264', '1'); } catch (e) { /* ignore */ }
  decoder = null;
  showStatus('Switching to H.264…');
  if (ws) { try { ws.close(); } catch (e) { /* ignore */ } }
  return true;
}

// MARK: - HELLO_ACK / video decode setup

let decoder = null;
let videoW = 0, videoH = 0;
let kbps = 0;
let framesDrawn = 0;
let waitingForKey = false;

async function handle(type, payload) {
  switch (type) {
    case T.HELLO_ACK: {
      if (payload.length < 10) return;
      const codecByte = payload[1]; // 1 = H.264, 2 = HEVC
      videoW = beU32(payload, 2);
      videoH = beU32(payload, 6);
      const hardware = payload.length >= 11 ? (payload[10] & 1) === 1 : true;
      canvas.width = videoW;
      canvas.height = videoH;
      swBanner.classList.toggle('show', !hardware);
      decoder = null; // rebuilt from the next keyframe's parameter sets
      waitingForKey = true; // delta frames before that keyframe are skipped
      pendingCodecByte = codecByte;
      break;
    }
    case T.RESTART_RESULT: {
      const texts = ['Restarting. The disk will not ask to be unlocked this time.',
        'The Mac did not accept that user name and password. Nothing was restarted.',
        'This Mac cannot do an authenticated restart.', 'Could not start the restart.'];
      showCard({ title: 'Restart', text: texts[payload[0]] || texts[3], buttons: [['OK', false, hideCard]] });
      break;
    }
    case T.STREAM_STATUS: {
      if (payload.length < 2) return;
      kbps = beU16(payload, 0);
      qualityDot.style.background = kbps >= 15000 ? '#2ecc71' : kbps >= 6000 ? '#f1c40f' : '#e67e22';
      break;
    }
    case T.HOST_LOCK_STATE: {
      const ls = parseLockState(payload);
      if (!ls) break;
      const locked = ls.locked;
      // Track whether we're locked by host to avoid conflicts with failure-based fallbacks
      lockedByHost = locked;
      lastLockState = ls;
      
      // Auto-forward into the noVNC bridge while locked, same as
      // ViewerApp.swift's LockedHostView — screensharingd can reach a
      // locked Mac where native Screen Recording capture can't. Reverts to
      // the canvas on its own once a later HOST_LOCK_STATE reports
      // unlocked; the native stream is never torn down underneath it.
      if (locked && ls.native) {
        // nativeLockScreen: keep the native stream, banner only. If the
        // fallback page was up (an earlier non-native lock, or a failed
        // connection), take it down: the native stream carries the lock screen.
        vncFallback.classList.remove('show');
        vncFallback.src = 'about:blank';
        fallbackDueToFailure = false;
        hideStatus();
        canvas.focus();
        requestKeyframe();
      } else if (shouldShowVncFallback(ls)) {
        vncFallback.src = vncFallbackURL;
        vncFallback.classList.add('show');
        hideStatus();
      } else if (locked) {
        // Locked, but there is no VNC link to offer: stay on the native
        // stream and show the banner only.
        vncFallback.classList.remove('show');
        vncFallback.src = 'about:blank';
        hideStatus();
        canvas.focus();
        requestKeyframe();
      } else {
        vncFallback.classList.remove('show');
        vncFallback.src = 'about:blank';
        canvas.focus();
        // The picture may have frozen while locked; start from a fresh one.
        requestKeyframe();
      }
      lockBanner.textContent = (locked && !shouldShowVncFallback(ls)) ? 'Mac is locked \u2014 type the password to unlock' : originalLockBannerText;
      lockBanner.classList.toggle('show', locked);
      break;
    }
    case T.VIDEO_FRAME:
      onVideoFrame(payload);
      break;
    case T.AUDIO_FRAME:
      audio.push(payload);
      break;
    case T.CLIPBOARD: {
      if (!isPrimary) return;
      const text = new TextDecoder().decode(payload);
      lastClipboard = text;
      if (navigator.clipboard) navigator.clipboard.writeText(text).catch(() => {});
      break;
    }
  }
}

// MARK: - Video decode (WebCodecs)

let pendingCodecByte = 1;
let decoderFailed = false;

function nalType(nalHeaderByte, isHEVC) {
  return isHEVC ? (nalHeaderByte >> 1) & 0x3f : nalHeaderByte & 0x1f;
}

// AVCC ([4-byte BE length][NAL])* -> Annex-B (start codes), same total size.
function avccToAnnexB(nalData) {
  const out = new Uint8Array(nalData.length);
  let i = 0, o = 0;
  while (i + 4 <= nalData.length) {
    const len = beU32(nalData, i);
    i += 4;
    if (len < 0 || i + len > nalData.length) break;
    out[o] = 0; out[o + 1] = 0; out[o + 2] = 0; out[o + 3] = 1; o += 4;
    out.set(nalData.subarray(i, i + len), o);
    o += len; i += len;
  }
  return out.subarray(0, o);
}

// Best-effort codec string for VideoDecoder.isConfigSupported/configure.
// H.264: read the exact profile_idc/constraint/level_idc out of the in-band
// SPS (byte-accurate). HEVC: fixed Main-profile guess — isConfigSupported
// catches a mismatch and surfaces the "can't decode" banner below rather
// than silently failing.
function codecString(nalData, isHEVC) {
  if (!isHEVC) {
    let i = 0;
    while (i + 4 <= nalData.length) {
      const len = beU32(nalData, i); i += 4;
      if (i + len > nalData.length) break;
      if (nalType(nalData[i], false) === 7 && len >= 4) { // SPS
        const hex = (b) => b.toString(16).padStart(2, '0');
        return `avc1.${hex(nalData[i + 1])}${hex(nalData[i + 2])}${hex(nalData[i + 3])}`;
      }
      i += len;
    }
    return 'avc1.640028'; // High@4.0 fallback if no SPS found (shouldn't happen)
  }
  return 'hvc1.1.6.L93.B0'; // Main profile, level 3.1 — best-effort guess
}

async function onVideoFrame(payload) {
  if (payload.length < 9 || decoderFailed) return;
  const keyframe = (payload[0] & 1) === 1;
  const ptsMicros = Number(
    (BigInt(beU32(payload, 1)) << 32n) | BigInt(beU32(payload, 5))
  );
  const nalData = payload.subarray(9);
  const isHEVC = pendingCodecByte === 2;

  if (!decoder && keyframe) {
    const codec = codecString(nalData, isHEVC);
    try {
      const support = await VideoDecoder.isConfigSupported({ codec, codedWidth: videoW, codedHeight: videoH });
      if (!support.supported) throw new Error(`unsupported: ${codec}`);
      const dec = new VideoDecoder({
        output: (frame) => { drawFrame(frame); frame.close(); },
        // A decoder that reports an error is closed for good. Drop it so the
        // next keyframe builds a new one (before, every later frame threw).
        error: (e) => {
          console.error('[Clamshell] decoder error', e);
          if (decoder === dec) decoder = null;
          if (isHEVC && fallBackToH264(e)) return;
          requestKeyframe();
        },
      });
      dec.configure({ codec, codedWidth: videoW, codedHeight: videoH, optimizeForLatency: true });
      decoder = dec;
    } catch (e) {
      if (isHEVC && fallBackToH264(e)) return;
      decoderFailed = true;
      const name = isHEVC ? 'HEVC' : 'H.264';
      errBanner.textContent = `This browser can't decode ${name} (${e.message || e}) — try Chrome (chrome://flags → enable HEVC) or Safari.`;
      errBanner.classList.add('show');
      hideStatus();
      return;
    }
  }
  if (!decoder) return; // no keyframe yet
  // Catch up instead of replaying a backlog, and decode nothing while hidden.
  const action = frameAction({
    keyframe, waitingForKey, queueSize: decoder.decodeQueueSize, hidden: document.hidden,
  });
  if (action !== 'decode') {
    if (action === 'resync') requestKeyframe();
    waitingForKey = true;
    return;
  }
  waitingForKey = false;
  const annexB = avccToAnnexB(nalData);
  try {
    decoder.decode(new EncodedVideoChunk({
      type: keyframe ? 'key' : 'delta',
      timestamp: ptsMicros,
      data: annexB,
    }));
  } catch (e) {
    console.error('[Clamshell] decode() threw', e);
    decoder = null;
    requestKeyframe();
  }
}

function drawFrame(frame) {
  if (canvas.width !== frame.displayWidth) canvas.width = frame.displayWidth;
  if (canvas.height !== frame.displayHeight) canvas.height = frame.displayHeight;
  ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
  framesDrawn++;
  if (statusEl.style.display !== 'none') hideStatus();
}

function requestKeyframe() { send(frameMsg(T.KEYFRAME_REQUEST)); }

// MARK: - Input (mouse, keyboard, scroll)

function normFromEvent(e) {
  const rect = canvas.getBoundingClientRect();
  const cw = canvas.width || 1, ch = canvas.height || 1;
  const scale = Math.min(rect.width / cw, rect.height / ch);
  const dispW = cw * scale, dispH = ch * scale;
  const offX = (rect.width - dispW) / 2, offY = (rect.height - dispH) / 2;
  const x = (e.clientX - rect.left - offX) / dispW;
  const y = (e.clientY - rect.top - offY) / dispH;
  return { x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) };
}

// Pointer events (not mouse events) so a drag that leaves the canvas keeps
// reporting to us and its button-up is never lost, and so touch works.
const buttonsDown = new Set(); // protocol buttons: 0 left, 1 right, 2 middle, 3 back, 4 forward
let lastPos = { x: 0.5, y: 0.5 };
let pendingMove = null;

// Pointer lock (host capability relativeMouse). While the canvas holds the
// lock the pointer is reported as movement and buttons act where the host
// cursor is; when the lock ends everything is absolute again.
let pointerLocked = false;
let pendingRel = null; // {dx, dy} gathered since the last frame

// Mice report up to 1000 moves a second; the host can't use more than one
// per frame. Send the newest position once per animation frame.
function queueMove(pos) {
  lastPos = pos;
  if (pendingMove) { pendingMove = pos; return; }
  pendingMove = pos;
  requestAnimationFrame(flushMove);
}
function flushMove() {
  flushRelative();
  if (!pendingMove) return;
  const { x, y } = pendingMove;
  pendingMove = null;
  send(encodeMouseMove(x, y));
}
// Relative movement adds up instead of being replaced.
function queueRelative(dx, dy) {
  if (pendingRel) { pendingRel.dx += dx; pendingRel.dy += dy; return; }
  pendingRel = { dx, dy };
  requestAnimationFrame(flushRelative);
}
function flushRelative() {
  if (!pendingRel) return;
  const { dx, dy } = pendingRel;
  pendingRel = null;
  if (dx !== 0 || dy !== 0) send(encodeMouseRelative(dx, dy));
}
function sendButton(button, down, pos) {
  flushMove(); // the host must see the move before the click
  if (down) buttonsDown.add(button); else buttonsDown.delete(button);
  if (pointerLocked) { send(encodeButtonAtCursor(button, down)); return; }
  lastPos = pos;
  send(encodeMouseButton(button, down, pos.x, pos.y));
}
function releaseButtons() {
  for (const b of [...buttonsDown]) sendButton(b, false, lastPos);
}

// Touch: tap = click, drag = drag, long press = right click, two fingers = scroll.
const touches = new Map(); // pointerId -> {x, y} in client px
let touchStart = null;     // {x, y, pos} of the first finger
let touchDragging = false;
let touchConsumed = false; // this gesture already did something; no click on lift
let longPressTimer = null;
const TOUCH_SLOP = 8, LONG_PRESS_MS = 550;

function touchDown(e) {
  touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (touches.size === 1) {
    const pos = normFromEvent(e);
    touchStart = { x: e.clientX, y: e.clientY, pos };
    touchDragging = false; touchConsumed = false;
    queueMove(pos);
    longPressTimer = setTimeout(() => {
      if (touches.size !== 1 || touchDragging || touchConsumed) return;
      touchConsumed = true;
      sendButton(1, true, pos); sendButton(1, false, pos);
    }, LONG_PRESS_MS);
  } else {
    clearTimeout(longPressTimer);
    if (touchDragging) { sendButton(0, false, lastPos); touchDragging = false; }
    touchConsumed = true; // two fingers: scrolling
  }
}
function touchMove(e) {
  const prev = touches.get(e.pointerId);
  if (!prev) return;
  touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (touches.size >= 2) {
    // Content follows the fingers. Each finger reports, so share it out.
    const n = touches.size;
    send(frameMsg(T.SCROLL, concat(f32(-(e.clientX - prev.x) * 2 / n), f32(-(e.clientY - prev.y) * 2 / n))));
    return;
  }
  if (touchConsumed || !touchStart) return;
  if (!touchDragging) {
    if (Math.hypot(e.clientX - touchStart.x, e.clientY - touchStart.y) < TOUCH_SLOP) return;
    clearTimeout(longPressTimer);
    touchDragging = true;
    sendButton(0, true, touchStart.pos);
  }
  queueMove(normFromEvent(e));
}
function touchUp(e, cancelled) {
  if (!touches.delete(e.pointerId)) return;
  clearTimeout(longPressTimer);
  if (touchDragging) {
    sendButton(0, false, cancelled ? lastPos : normFromEvent(e));
    touchDragging = false;
  } else if (!touchConsumed && !cancelled && touchStart) {
    sendButton(0, true, touchStart.pos); sendButton(0, false, touchStart.pos);
  }
  if (touches.size === 0) touchStart = null;
}

canvas.addEventListener('pointermove', (e) => {
  if (e.pointerType === 'touch') { touchMove(e); return; }
  if (pointerLocked) { queueRelative(e.movementX, e.movementY); return; }
  queueMove(normFromEvent(e));
});
canvas.addEventListener('pointerdown', (e) => {
  canvas.focus();
  maybeResumeSound();
  if (e.pointerType === 'touch') { e.preventDefault(); touchDown(e); return; }
  const button = protocolButton(e.button);
  if (button === null) return;
  if (claimsButton(e.button)) e.preventDefault();
  try { canvas.setPointerCapture(e.pointerId); } catch (err) {}
  sendButton(button, true, normFromEvent(e));
  // A mouse press captures the pointer when the host takes relative movement.
  if (!pointerLocked && hostHas(CAP.relativeMouse) && canvas.requestPointerLock) {
    try { const p = canvas.requestPointerLock(); if (p && p.catch) p.catch(() => {}); } catch (err) { /* ignore */ }
  }
});
canvas.addEventListener('pointerup', (e) => {
  if (e.pointerType === 'touch') { touchUp(e, false); return; }
  const button = protocolButton(e.button);
  if (button === null) return;
  if (claimsButton(e.button)) e.preventDefault();
  sendButton(button, false, normFromEvent(e));
});
// Back and forward would otherwise navigate the page away, and a middle click
// would start autoscroll, once the host takes those buttons.
for (const type of ['mousedown', 'mouseup', 'auxclick']) {
  canvas.addEventListener(type, (e) => { if (claimsButton(e.button)) e.preventDefault(); });
}
document.addEventListener('pointerlockchange', () => {
  const locked = document.pointerLockElement === canvas;
  if (locked === pointerLocked) return;
  if (!locked) {
    // Let go while buttons still go out the way they were pressed.
    releaseInput();
    pendingRel = null;
  }
  pointerLocked = locked;
});
canvas.addEventListener('pointercancel', (e) => {
  if (e.pointerType === 'touch') { touchUp(e, true); return; }
  releaseButtons();
});
canvas.addEventListener('contextmenu', (e) => e.preventDefault());

canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
  // Normalize LINE/PAGE deltaMode to an approximate pixel value.
  const mul = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? canvas.clientHeight : 1;
  send(encodeScroll(e.deltaX * mul, e.deltaY * mul));
}, { passive: false });

// "Ctrl acts as Cmd": remembered per browser, on by default on Windows/Linux.
const CTRL_KEY = 'clamshell.ctrlAsCmd';
let ctrlAsCmd = ctrlAsCmdDefault(navigator);
try {
  const v = window.localStorage.getItem(CTRL_KEY);
  if (v === '1' || v === '0') ctrlAsCmd = v === '1';
} catch (e) { /* ignore */ }

function cgFlags(e) {
  return modifierFlags({
    caps: !!(e.getModifierState && e.getModifierState('CapsLock')),
    shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey,
  }, ctrlAsCmd);
}

function sendKey(macVK, down, flags) {
  send(encodeKey(macVK, down, flags));
}

const held = new HeldKeys();

// Let go of everything the host thinks is held. Without this, switching
// away mid-shortcut (Cmd-Tab) left Cmd stuck down on the Mac.
function releaseInput() {
  for (const vk of held.releaseAll()) sendKey(vk, false, 0n);
  releaseButtons();
}
window.addEventListener('blur', releaseInput);
canvas.addEventListener('blur', releaseInput);

canvas.addEventListener('keydown', (e) => {
  const vk = remapKey(e.code, codeToMacVK[e.code], ctrlAsCmd);
  if (codeToMacVK[e.code] === undefined) return;
  e.preventDefault();
  maybeResumeSound();
  if (!e.repeat && pasteFromLocal(e, vk)) return;
  held.press(e.code, vk);
  sendKey(vk, true, cgFlags(e));
});
canvas.addEventListener('keyup', (e) => {
  const vk = remapKey(e.code, codeToMacVK[e.code], ctrlAsCmd);
  if (codeToMacVK[e.code] === undefined) return;
  e.preventDefault();
  const flags = cgFlags(e);
  const released = held.release(e.code);
  if (released.length === 0) { sendKey(vk, false, flags); return; }
  for (const k of released) sendKey(k, false, flags);
});

// MARK: - Clipboard (reuses the existing /clipboard HTTP bridge, same
// focus-pull/hide-push pattern as WebServer.swift's clipboardScript).
// Primary connection (display=a) only, matching the protocol's "only the
// primary connection carries audio and clipboard".

let lastClipboard = null;

// Chromium lets a page read the clipboard after a one-time permission
// prompt. Safari shows a "Paste" bubble on every read and Firefox refuses,
// so only Chromium gets the read-on-paste path below.
let canReadClipboard = false;
// Resolves once the permission state is known, so the first Cmd-V never races it.
let clipboardPermission = Promise.resolve();
if (isPrimary && navigator.clipboard && navigator.clipboard.readText && navigator.permissions) {
  clipboardPermission = navigator.permissions.query({ name: 'clipboard-read' })
    .then((p) => { canReadClipboard = p.state !== 'denied'; })
    .catch(() => {});
}

// Cmd-V: send what's on *this* computer's clipboard first, on the same
// socket as the keystroke so the host has it before it pastes. Before, the
// local clipboard only reached the Mac when the tab was hidden, so copying
// in another window and pasting here pasted something old.
//
// The very first read can show Chrome's permission prompt. The prompt takes
// focus (the blur handler lets go of Cmd on the Mac) and the key must not go
// out until the read is answered, or a bare "v" is typed. So the whole chord
// is sent after the read settles, Cmd included, when the read took long
// enough to have been a prompt.
let pasteBusy = false;
function pasteFromLocal(e, vk) {
  // The key that means Command here: Ctrl when swapped, else the Meta key.
  const cmdDown = ctrlAsCmd ? e.ctrlKey : e.metaKey;
  const otherDown = ctrlAsCmd ? e.metaKey : e.ctrlKey;
  if (e.code !== 'KeyV' || !cmdDown || otherDown || e.altKey) return false;
  if (pasteBusy) return true; // a read is pending: swallow, don't type a stray "v"
  const flags = cgFlags(e);
  const cmdVK = 55; // left Command
  pasteBusy = true;
  const started = Date.now();
  clipboardPermission
    .then(() => {
      if (!canReadClipboard) return 'skip';
      return navigator.clipboard.readText().then((t) => {
        if (t && t !== lastClipboard) {
          lastClipboard = t;
          send(frameMsg(T.CLIPBOARD, new TextEncoder().encode(t)));
        }
      });
    })
    .catch(() => {})
    .finally(() => {
      pasteBusy = false;
      const slow = Date.now() - started > 250; // a permission prompt was up
      if (slow) sendKey(cmdVK, true, flags);
      sendKey(vk, true, flags); sendKey(vk, false, flags);
      if (slow) sendKey(cmdVK, false, 0n);
    });
  return true;
}

if (isPrimary && navigator.clipboard) {
  const q = token ? `?token=${encodeURIComponent(token)}` : '';
  let lastChangeCount = -1;
  window.addEventListener('focus', async () => {
    try {
      const r = await fetch(`/clipboard${q}`);
      const j = await r.json();
      if (j.changeCount !== lastChangeCount) {
        lastChangeCount = j.changeCount;
        if (j.text && j.text !== lastClipboard) {
          lastClipboard = j.text;
          await navigator.clipboard.writeText(j.text);
        }
      }
    } catch (e) {}
  });
  document.addEventListener('visibilitychange', async () => {
    if (!document.hidden) return;
    try {
      const t = await navigator.clipboard.readText();
      if (t && t !== lastClipboard) {
        lastClipboard = t;
        await fetch(`/clipboard${q}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text: t }),
        });
      }
    } catch (e) {}
  });
}

// MARK: - Tab visibility

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    releaseInput();
    waitingForKey = true; // frames are dropped while hidden (frameAction)
  } else {
    reconnectNow();
    requestKeyframe(); // show a current picture straight away
  }
});

// MARK: - Menu: full screen, sound, stats

// Touch devices have no hover; tapping the dot opens and closes the menu.
qualityDot.addEventListener('click', () => menu.classList.toggle('open'));
canvas.addEventListener('pointerdown', () => menu.classList.remove('open'));

// Ctrl acts as Cmd toggle
{
  const ctrlBtn = document.getElementById('ctrlBtn');
  const show = () => { ctrlBtn.textContent = `Ctrl acts as \u2318: ${ctrlAsCmd ? 'on' : 'off'}`; };
  ctrlBtn.addEventListener('click', () => {
    releaseInput(); // don't leave the old mapping's modifier held
    ctrlAsCmd = !ctrlAsCmd;
    try { window.localStorage.setItem(CTRL_KEY, ctrlAsCmd ? '1' : '0'); } catch (e) { /* ignore */ }
    show();
    canvas.focus();
  });
  show();
}

// Full screen (fullscreen.js): a toggle where the browser allows it, plus
// "Start in full screen"; on iPhone, how to add the page to the Home Screen.
{
  const fs = fullscreenApi(document);
  const standalone = isStandalone(window);
  const mode = fullscreenMode({ api: fs, standalone });
  const startBtn = document.getElementById('startFsBtn');
  const hint = document.getElementById('fsHint');
  let startOn = loadStartFullscreen(safeStorage());
  let autoUsed = false;
  let autoPointer = null;
  let hintTimer = null;

  const show = () => {
    const on = !!(fs && fs.active());
    fullscreenBtn.textContent = mode === 'homescreen' ? 'Full screen…' : (on ? 'Exit full screen' : 'Full screen');
    startBtn.textContent = `Start in full screen: ${startOn ? 'on' : 'off'}`;
  };
  const enter = async () => { try { await fs.enter(); } catch (e) { /* refused */ } canvas.focus(); };
  const showHint = () => {
    hint.classList.add('show');
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => hint.classList.remove('show'), 12000);
  };

  fullscreenBtn.hidden = mode === 'none';
  startBtn.hidden = mode !== 'toggle' || standalone;
  fullscreenBtn.addEventListener('click', async () => {
    if (mode === 'homescreen') { showHint(); return; }
    try { if (fs.active()) await fs.exit(); else await fs.enter(); } catch (e) { /* refused */ }
    canvas.focus();
  });
  startBtn.addEventListener('click', () => {
    startOn = !startOn;
    saveStartFullscreen(safeStorage(), startOn);
    show();
  });
  hint.addEventListener('click', () => hint.classList.remove('show'));

  for (const type of (fs ? fs.events : [])) {
    document.addEventListener(type, () => {
      show();
      // In full screen, Chromium can hand us keys the browser normally keeps
      // (Esc, and on Windows/Linux the system shortcuts) so they reach the Mac.
      if (navigator.keyboard && navigator.keyboard.lock) {
        if (fs.active()) navigator.keyboard.lock().catch(() => {}); else navigator.keyboard.unlock();
      }
    });
  }

  // "Start in full screen": the first click or tap on the screen enters full
  // screen and is kept from the Mac (down, moves and up), so the Mac doesn't
  // get a click or a drag while the page changes size under the pointer.
  // Browsers allow the request on a mouse press but, for a touch or a pen,
  // only on the release (a touch could still turn into a scroll), so a mouse
  // asks on the press and the others on the release.
  // Capture phase on window, so this runs before the canvas handlers.
  let autoAskOnRelease = false;
  window.addEventListener('pointerdown', (e) => {
    if (e.target !== canvas || !e.isPrimary || autoPointer !== null) return;
    if (!shouldAutoEnter({ pref: startOn, api: fs, standalone, used: autoUsed })) return;
    autoUsed = true;
    autoPointer = e.pointerId;
    autoAskOnRelease = e.pointerType !== 'mouse';
    e.preventDefault();
    e.stopImmediatePropagation();
    if (!autoAskOnRelease) enter();
  }, true);
  window.addEventListener('pointermove', (e) => {
    if (e.pointerId === autoPointer) e.stopImmediatePropagation();
  }, true);
  window.addEventListener('pointerup', (e) => {
    if (e.pointerId !== autoPointer) return;
    autoPointer = null;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (autoAskOnRelease) enter();
  }, true);
  window.addEventListener('pointercancel', (e) => {
    if (e.pointerId !== autoPointer) return;
    autoPointer = null;
    autoUsed = false; // the browser took the touch (a scroll or a gesture): the next tap tries again
    e.stopImmediatePropagation();
  }, true);

  show();
}

const audio = new AudioPlayer();
const SOUND_KEY = 'clamshell.sound';
let wantSound = false;
try { wantSound = localStorage.getItem(SOUND_KEY) === '1'; } catch (e) {}

function showSound() { soundBtn.textContent = audio.on ? 'Sound: on' : 'Sound: off'; }
async function setSound(on) {
  if (on) {
    if (!(await audio.start())) {
      soundBtn.textContent = "Sound: this browser can't play it";
      wantSound = false;
      return;
    }
  } else {
    audio.stop();
  }
  wantSound = on;
  try { localStorage.setItem(SOUND_KEY, on ? '1' : '0'); } catch (e) {}
  showSound();
}
// Sound was on last time: browsers need a click or key press before audio
// can start, so pick it up on the first one.
function maybeResumeSound() {
  if (wantSound && !audio.on && !audio.starting) {
    audio.starting = true;
    setSound(true).finally(() => { audio.starting = false; });
  }
}
if (isPrimary && audioSupported()) {
  soundBtn.hidden = false;
  soundBtn.addEventListener('click', () => { setSound(!audio.on); canvas.focus(); });
} else {
  wantSound = false;
}

setInterval(() => {
  const fps = framesDrawn; framesDrawn = 0;
  const open = ws && ws.readyState === WebSocket.OPEN;
  if (!open) { statsEl.textContent = 'Not connected'; qualityDot.style.background = '#c0392b'; return; }
  if (!kbps) qualityDot.style.background = '#666';
  const rate = kbps ? ` · ${(kbps / 1000).toFixed(1)} Mbps` : '';
  statsEl.textContent = videoW ? `${videoW}×${videoH} · ${fps} fps${rate}` : 'Connected';
  qualityDot.title = statsEl.textContent;
}, 1000);

// Decide the codec before the first HELLO (isConfigSupported is async).
pickCodec(globalThis.VideoDecoder, h264Only).then((c) => { wantCodec = c; }, () => {}).finally(() => connect());

// MARK: - Password forms (Restart, Log in)
// Real <form>s with autocomplete="username" / "current-password", so a password manager fills them.
// The password is only in the field until the form is sent; then the whole form is removed.
function showCredentialCard({ title, text, formId, submitLabel, onSubmit }) {
  const f = buildCredentialForm(document, {
    id: formId, submitLabel,
    onSubmit: (u, p, parts) => {
      const done = onSubmit(u, p);
      if (done === false) return; // not sent (bad input or too soon): keep what was typed
      parts.pass.value = '';
      parts.user.value = '';
      authRows.replaceChildren(); // the fields leave the page with the password
    },
  });
  showCard({ title, text, rows: [], buttons: [['Cancel', true, hideCard]] });
  authRows.replaceChildren(f.form);
  f.user.focus();
}

const restartBtn = document.getElementById('restartBtn');
restartBtn.addEventListener('click', () => {
  showCredentialCard({
    title: 'Restart the Mac',
    text: 'Restarts now and skips the disk unlock screen once. Nothing is saved.',
    formId: 'restartForm', submitLabel: 'Restart',
    onSubmit: (user, password) => {
      send(frameMsg(T.RESTART_REQUEST, new TextEncoder().encode(JSON.stringify({ username: user, password })))); // inside the encrypted session; never stored
      authText.textContent = 'Sent. Waiting for the Mac to answer…';
    },
  });
});

// Login window: shown only when the host says it is at the login window (capability bit 8).
const loginBtn = document.getElementById('loginBtn');
const loginLimiter = new LoginLimiter();
function updateLoginButton() { loginBtn.hidden = !hostHas(CAP.loginCredentials); }
loginBtn.addEventListener('click', () => {
  if (!hostHas(CAP.loginCredentials)) return;
  showCredentialCard({
    title: 'Log in to the Mac',
    text: 'Types this account name and password into the Mac\'s login window. Nothing is saved.',
    formId: 'loginForm', submitLabel: 'Log in',
    onSubmit: (user, password) => {
      const problem = loginProblem(user, password, loginLimiter);
      if (problem) { authText.textContent = problem; return false; }
      const body = loginPayload(user, password);
      loginLimiter.tryTake();
      send(frameMsg(T.LOGIN_CREDENTIALS, body));
      authText.textContent = 'Sent. Watch the Mac\'s screen for the result.';
      setTimeout(hideCard, 2500);
    },
  });
});

// MARK: - Offline shell (service worker)
// Keeps the last good page so it still opens while the Mac restarts. Needs https or localhost.
let offlineShell = false;
(function setupOfflineShell() {
  if (!('serviceWorker' in navigator)) return;
  if (params.get('nosw') === '1') { // kill switch from the page side
    navigator.serviceWorker.getRegistrations().then((rs) => rs.forEach((r) => r.unregister())).catch(() => {});
    if (window.caches) caches.keys().then((ks) => ks.filter((k) => k.startsWith('clamshell-shell-')).forEach((k) => caches.delete(k))).catch(() => {});
    return;
  }
  navigator.serviceWorker.register('/client/sw.js', { scope: '/client' }).then(() => { offlineShell = true; }, () => {});
})();
