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
// Scope note (ponytail): AUDIO_FRAME (0x13) is intentionally ignored — audio
// playback wasn't in this client's requested scope (video+control+clipboard
// only). Add a WebCodecs AudioDecoder + Web Audio playback path if wanted;
// the fixed-format AAC-LC 48kHz stereo access units need a synthesized
// AudioSpecificConfig (0x11,0x90) since the wire carries no ADTS/cookie.

import { codeToMacVK } from '/client/keymap.js';

const params = new URLSearchParams(location.search);
const display = ['a', 'b', 'c'].includes(params.get('display')) ? params.get('display') : 'a';
const isPrimary = display === 'a';
const token = params.get('token'); // optional clipboardToken passthrough

// Browser-facing WS bridge ports (see WebServer.swift streamBridgePorts):
// one per display, each proxying to the matching local StreamServer port.
const BRIDGE_PORT = { a: 5906, b: 5907, c: 5908 }[display];

// Message types (StreamProtocol.swift).
const T = {
  HELLO: 0x01, HELLO_ACK: 0x02, STREAM_STATUS: 0x04, HOST_LOCK_STATE: 0x05,
  VIDEO_FRAME: 0x10, KEYFRAME_REQUEST: 0x11, AUDIO_FRAME: 0x13,
  MOUSE_MOVE: 0x20, MOUSE_BUTTON: 0x21, KEY: 0x22, SCROLL: 0x23, CLIPBOARD: 0x30,
};

const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const statusEl = document.getElementById('status');
const swBanner = document.getElementById('swBanner');
const lockBanner = document.getElementById('lockBanner');
const errBanner = document.getElementById('errBanner');
const qualityDot = document.getElementById('qualityDot');

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
    panel.appendChild(a);
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

function connect() {
  const wsUrl = location.protocol === 'https:'
    // Network.framework's server-side WS listener can't see the handshake
    // path, so path-based disambiguation happens at the Cloudflare Tunnel
    // layer instead: clamshell.penndalton.com/ws/{a,b,c} are separate
    // ingress rules pointing directly at each display's dedicated bridge
    // port (5906/5907/5908) — the Mac side needs no path parsing since
    // each port is already single-purpose.
    ? `wss://${location.host}/ws/${display}`
    : `ws://${location.hostname}:${BRIDGE_PORT}`;
  ws = new WebSocket(wsUrl);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    reconnectAttempt = 0;
    sendHello();
  };
  ws.onmessage = (ev) => {
    const buf = new Uint8Array(ev.data);
    if (buf.length < 5) return;
    const type = buf[0];
    const len = beU32(buf, 1);
    const payload = buf.subarray(5, 5 + len);
    handle(type, payload);
  };
  ws.onclose = scheduleReconnect;
  ws.onerror = () => {}; // onclose always follows
}

function scheduleReconnect() {
  if (!wantConnection) return;
  statusEl.textContent = 'Reconnecting…';
  statusEl.style.display = 'flex';
  decoder = null;
  reconnectAttempt++;
  const delay = Math.min(2 ** (reconnectAttempt - 1), 10) * 1000; // 1,2,4,8,10,10s…
  setTimeout(() => { if (wantConnection) connect(); }, delay);
}

// Retries forever regardless of tab visibility (no explicit disconnect UI) —
// navigating away / closing the tab is what actually stops it, matching the
// native client's "retries forever until user disconnects" contract.

function send(data) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(data); }

function sendHello() {
  send(frameMsg(T.HELLO, new Uint8Array([1 /* version */, 1 /* requestedCodec = H.264 */])));
}

// MARK: - HELLO_ACK / video decode setup

let decoder = null;
let videoW = 0, videoH = 0;

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
      statusEl.style.display = 'none';
      decoder = null; // rebuilt from the next keyframe's parameter sets
      pendingCodecByte = codecByte;
      break;
    }
    case T.STREAM_STATUS: {
      if (payload.length < 2) return;
      const kbps = beU16(payload, 0);
      qualityDot.style.display = 'inline-block';
      qualityDot.style.background = kbps >= 15000 ? '#2ecc71' : kbps >= 6000 ? '#f1c40f' : '#e67e22';
      break;
    }
    case T.HOST_LOCK_STATE: {
      const locked = payload[0] === 1;
      lockBanner.classList.toggle('show', locked);
      break;
    }
    case T.VIDEO_FRAME:
      onVideoFrame(payload);
      break;
    case T.AUDIO_FRAME:
      break; // out of scope — see file header
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
        error: (e) => { console.error('[Clamshell] decoder error', e); requestKeyframe(); },
      });
      dec.configure({ codec, codedWidth: videoW, codedHeight: videoH, optimizeForLatency: true });
      decoder = dec;
    } catch (e) {
      decoderFailed = true;
      const name = isHEVC ? 'HEVC' : 'H.264';
      errBanner.textContent = `This browser can't decode ${name} (${e.message || e}) — try Chrome (chrome://flags → enable HEVC) or Safari.`;
      errBanner.classList.add('show');
      statusEl.style.display = 'none';
      return;
    }
  }
  if (!decoder) return; // no keyframe yet
  const annexB = avccToAnnexB(nalData);
  try {
    decoder.decode(new EncodedVideoChunk({
      type: keyframe ? 'key' : 'delta',
      timestamp: ptsMicros,
      data: annexB,
    }));
  } catch (e) {
    console.error('[Clamshell] decode() threw', e);
    requestKeyframe();
  }
}

function drawFrame(frame) {
  if (canvas.width !== frame.displayWidth) canvas.width = frame.displayWidth;
  if (canvas.height !== frame.displayHeight) canvas.height = frame.displayHeight;
  ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
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

canvas.addEventListener('mousemove', (e) => {
  const { x, y } = normFromEvent(e);
  send(frameMsg(T.MOUSE_MOVE, concat(f32(x), f32(y))));
});
canvas.addEventListener('mousedown', (e) => {
  canvas.focus();
  if (e.button !== 0 && e.button !== 2) return;
  const { x, y } = normFromEvent(e);
  send(frameMsg(T.MOUSE_BUTTON, concat(new Uint8Array([e.button === 2 ? 1 : 0, 1]), f32(x), f32(y))));
});
canvas.addEventListener('mouseup', (e) => {
  if (e.button !== 0 && e.button !== 2) return;
  const { x, y } = normFromEvent(e);
  send(frameMsg(T.MOUSE_BUTTON, concat(new Uint8Array([e.button === 2 ? 1 : 0, 0]), f32(x), f32(y))));
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

canvas.addEventListener('keydown', (e) => {
  const vk = codeToMacVK[e.code];
  if (vk === undefined) return;
  e.preventDefault();
  sendKey(vk, true, cgFlags(e));
});
canvas.addEventListener('keyup', (e) => {
  const vk = codeToMacVK[e.code];
  if (vk === undefined) return;
  e.preventDefault();
  sendKey(vk, false, cgFlags(e));
});

// MARK: - Clipboard (reuses the existing /clipboard HTTP bridge, same
// focus-pull/hide-push pattern as WebServer.swift's clipboardScript).
// Primary connection (display=a) only, matching the protocol's "only the
// primary connection carries audio and clipboard".

let lastClipboard = null;
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

connect();
