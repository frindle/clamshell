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
import { helloPayload, attachResizeReporter } from '/client/hello.js';
import { HeldKeys, reconnectDelay, frameAction } from '/client/input.js';
import { AudioPlayer, audioSupported } from '/client/audio.js';

const params = new URLSearchParams(location.search);
const display = ['a', 'b', 'c'].includes(params.get('display')) ? params.get('display') : 'a';
const isPrimary = display === 'a';
const token = params.get('token'); // optional clipboardToken passthrough

// Browser-facing WS bridge ports (see WebServer.swift streamBridgePorts):
// one per display, each proxying to the matching local StreamServer port.
const BRIDGE_PORT = { a: 5906, b: 5907, c: 5908 }[display];

// Message types (StreamProtocol.swift).
const T = {
  HELLO: 0x01, HELLO_ACK: 0x02, CLIENT_DISPLAYS: 0x03, STREAM_STATUS: 0x04, HOST_LOCK_STATE: 0x05,
  VIDEO_FRAME: 0x10, KEYFRAME_REQUEST: 0x11, AUDIO_FRAME: 0x13,
  MOUSE_MOVE: 0x20, MOUSE_BUTTON: 0x21, KEY: 0x22, SCROLL: 0x23, CLIPBOARD: 0x30,
};

// Re-report the window size to the host (CLIENT_DISPLAYS) after resizing stops;
// the initial size rides in HELLO.
attachResizeReporter(window, (p) => send(frameMsg(T.CLIENT_DISPLAYS, p)));

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
const vncFallbackURL = location.protocol === 'https:'
  ? `${location.origin}/vnc.html`
  : `http://${location.hostname}:5901/vnc.html`;

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
let fallbackDueToFailure = false;

const CONNECT_TIMEOUT_MS = 10000;

function connect() {
  clearTimeout(reconnectTimer); reconnectTimer = null;
  clearInterval(countdownTimer); countdownTimer = null;
  const wsUrl = location.protocol === 'https:'
    // Network.framework's server-side WS listener can't see the handshake
    // path, so path-based disambiguation happens at the Cloudflare Tunnel
    // layer instead: /ws/{a,b,c} are separate ingress rules pointing
    // directly at each display's dedicated bridge port (5906/5907/5908) —
    // the Mac side needs no path parsing since each port is already
    // single-purpose.
    ? `wss://${location.host}/ws/${display}`
    : `ws://${location.hostname}:${BRIDGE_PORT}`;
  const sock = new WebSocket(wsUrl);
  ws = sock;
  sock.binaryType = 'arraybuffer';
  // A handshake that never completes (tunnel up, host asleep) can hang for a
  // minute or more before the browser gives up. Cut it short and retry.
  const connectTimeout = setTimeout(() => {
    if (sock.readyState === WebSocket.CONNECTING) sock.close();
  }, CONNECT_TIMEOUT_MS);
  sock.onopen = () => {
    clearTimeout(connectTimeout);
    if (sock !== ws) return;
    reconnectAttempt = 0;
    showStatus('Connected — waiting for video…');
    // The native stream is back. If noVNC was showing only because we could
    // not connect -- as opposed to the host reporting itself locked -- drop
    // back to the canvas. A genuinely locked host keeps noVNC up even with
    // the socket open, so lockedByHost wins.
    if (fallbackDueToFailure && !lockedByHost) {
      fallbackDueToFailure = false;
      vncFallback.classList.remove('show');
      vncFallback.src = 'about:blank';
      lockBanner.textContent = originalLockBannerText;
      lockBanner.classList.remove('show');
    }
    audio.reset();
    sendHello();
  };
  sock.onmessage = (ev) => {
    if (sock !== ws) return;
    const buf = new Uint8Array(ev.data);
    if (buf.length < 5) return;
    const type = buf[0];
    const len = beU32(buf, 1);
    const payload = buf.subarray(5, 5 + len);
    handle(type, payload);
  };
  sock.onclose = () => {
    clearTimeout(connectTimeout);
    if (sock !== ws) return; // an older socket; a newer one is already in charge
    scheduleReconnect();
  };
  sock.onerror = () => {}; // onclose always follows
}

function scheduleReconnect() {
  if (!wantConnection || reconnectTimer) return;
  decoder = null;
  kbps = 0;
  // The host has forgotten what we were holding; forget it here too.
  held.releaseAll();
  buttonsDown.clear();
  reconnectAttempt++;
  let left = reconnectDelay(reconnectAttempt); // 1,2,4,8,10,10s…
  const offline = navigator.onLine === false;
  const text = () => offline
    ? 'This device is offline — will reconnect when the network is back'
    : `Connection lost — reconnecting in ${left} s (try ${reconnectAttempt})`;
  showStatus(text());
  clearInterval(countdownTimer);
  countdownTimer = setInterval(() => { if (left > 1) { left--; showStatus(text()); } }, 1000);

  // Check if we should fall back to noVNC after repeated failures
  if (reconnectAttempt >= 3 && !fallbackDueToFailure && !lockedByHost) {
    fallbackDueToFailure = true;
    vncFallback.src = vncFallbackURL;
    vncFallback.classList.add('show');
    // Show appropriate banner text for failure-based fallback
    lockBanner.textContent = "Can't reach the desktop — showing the login screen instead.";
    lockBanner.classList.add('show');
  }

  reconnectTimer = setTimeout(() => { reconnectTimer = null; if (wantConnection) connect(); }, left * 1000);
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

function send(data) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(data); }

function sendHello() {
  send(frameMsg(T.HELLO, helloPayload(window.innerWidth, window.innerHeight, window.devicePixelRatio)));
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
      waitingForKey = false;
      pendingCodecByte = codecByte;
      break;
    }
    case T.STREAM_STATUS: {
      if (payload.length < 2) return;
      kbps = beU16(payload, 0);
      qualityDot.style.background = kbps >= 15000 ? '#2ecc71' : kbps >= 6000 ? '#f1c40f' : '#e67e22';
      break;
    }
    case T.HOST_LOCK_STATE: {
      const locked = payload[0] === 1;
      // Track whether we're locked by host to avoid conflicts with failure-based fallbacks
      lockedByHost = locked;
      
      // Auto-forward into the noVNC bridge while locked, same as
      // ViewerApp.swift's LockedHostView — screensharingd can reach a
      // locked Mac where native Screen Recording capture can't. Reverts to
      // the canvas on its own once a later HOST_LOCK_STATE reports
      // unlocked; the native stream is never torn down underneath it.
      if (locked) {
        vncFallback.src = vncFallbackURL;
        vncFallback.classList.add('show');
        hideStatus();
      } else {
        vncFallback.classList.remove('show');
        vncFallback.src = 'about:blank';
        canvas.focus();
        // The picture may have frozen while locked; start from a fresh one.
        requestKeyframe();
      }
      lockBanner.textContent = originalLockBannerText;
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
          requestKeyframe();
        },
      });
      dec.configure({ codec, codedWidth: videoW, codedHeight: videoH, optimizeForLatency: true });
      decoder = dec;
    } catch (e) {
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
const buttonsDown = new Set(); // 0 = left, 1 = right
let lastPos = { x: 0.5, y: 0.5 };
let pendingMove = null;

// Mice report up to 1000 moves a second; the host can't use more than one
// per frame. Send the newest position once per animation frame.
function queueMove(pos) {
  lastPos = pos;
  if (pendingMove) { pendingMove = pos; return; }
  pendingMove = pos;
  requestAnimationFrame(flushMove);
}
function flushMove() {
  if (!pendingMove) return;
  const { x, y } = pendingMove;
  pendingMove = null;
  send(frameMsg(T.MOUSE_MOVE, concat(f32(x), f32(y))));
}
function sendButton(button, down, pos) {
  flushMove(); // the host must see the move before the click
  lastPos = pos;
  if (down) buttonsDown.add(button); else buttonsDown.delete(button);
  send(frameMsg(T.MOUSE_BUTTON, concat(new Uint8Array([button, down ? 1 : 0]), f32(pos.x), f32(pos.y))));
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
  queueMove(normFromEvent(e));
});
canvas.addEventListener('pointerdown', (e) => {
  canvas.focus();
  maybeResumeSound();
  if (e.pointerType === 'touch') { e.preventDefault(); touchDown(e); return; }
  if (e.button !== 0 && e.button !== 2) return;
  try { canvas.setPointerCapture(e.pointerId); } catch (err) {}
  sendButton(e.button === 2 ? 1 : 0, true, normFromEvent(e));
});
canvas.addEventListener('pointerup', (e) => {
  if (e.pointerType === 'touch') { touchUp(e, false); return; }
  if (e.button !== 0 && e.button !== 2) return;
  sendButton(e.button === 2 ? 1 : 0, false, normFromEvent(e));
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
  send(frameMsg(T.SCROLL, concat(f32(e.deltaX * mul), f32(e.deltaY * mul))));
}, { passive: false });

function cgFlags(e) {
  let f = 0n;
  if (e.getModifierState && e.getModifierState('CapsLock')) f |= 0x10000n;
  if (e.shiftKey) f |= 0x20000n;
  if (e.ctrlKey) f |= 0x40000n;
  if (e.altKey) f |= 0x80000n;
  if (e.metaKey) f |= 0x100000n;
  return f;
}

function sendKey(macVK, down, flags) {
  const b = new Uint8Array(11);
  new DataView(b.buffer).setUint16(0, macVK, false);
  b[2] = down ? 1 : 0;
  new DataView(b.buffer).setBigUint64(3, flags, false);
  send(frameMsg(T.KEY, b));
}

const held = new HeldKeys();

// Let go of everything the host thinks is held. Without this, switching
// away mid-shortcut (Cmd-Tab) left Cmd stuck down on the Mac.
function releaseInput() {
  for (const vk of held.releaseAll()) sendKey(vk, false, 0n);
  releaseButtons();
}
window.addEventListener('blur', releaseInput);

canvas.addEventListener('keydown', (e) => {
  const vk = codeToMacVK[e.code];
  if (vk === undefined) return;
  e.preventDefault();
  maybeResumeSound();
  if (!e.repeat && pasteFromLocal(e, vk)) return;
  held.press(e.code, vk);
  sendKey(vk, true, cgFlags(e));
});
canvas.addEventListener('keyup', (e) => {
  const vk = codeToMacVK[e.code];
  if (vk === undefined) return;
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
if (isPrimary && navigator.clipboard && navigator.clipboard.readText && navigator.permissions) {
  navigator.permissions.query({ name: 'clipboard-read' })
    .then((p) => { canReadClipboard = p.state !== 'denied'; })
    .catch(() => {});
}

// Cmd-V: send what's on *this* computer's clipboard first, on the same
// socket as the keystroke so the host has it before it pastes. Before, the
// local clipboard only reached the Mac when the tab was hidden, so copying
// in another window and pasting here pasted something old.
function pasteFromLocal(e, vk) {
  if (!canReadClipboard || e.code !== 'KeyV' || !e.metaKey || e.ctrlKey || e.altKey) return false;
  const flags = cgFlags(e);
  navigator.clipboard.readText()
    .then((t) => {
      if (t && t !== lastClipboard) {
        lastClipboard = t;
        send(frameMsg(T.CLIPBOARD, new TextEncoder().encode(t)));
      }
    })
    .catch(() => {})
    .finally(() => { sendKey(vk, true, flags); sendKey(vk, false, flags); });
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

fullscreenBtn.hidden = !document.documentElement.requestFullscreen;
fullscreenBtn.addEventListener('click', async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  } catch (e) {}
  canvas.focus();
});
document.addEventListener('fullscreenchange', () => {
  const on = !!document.fullscreenElement;
  fullscreenBtn.textContent = on ? 'Exit full screen' : 'Full screen';
  // In full screen, Chromium can hand us keys the browser normally keeps
  // (Esc, and on Windows/Linux the system shortcuts) so they reach the Mac.
  if (navigator.keyboard && navigator.keyboard.lock) {
    if (on) navigator.keyboard.lock().catch(() => {}); else navigator.keyboard.unlock();
  }
});

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

connect();
