// Pure helpers for the client display report the browser client sends the
// host (PROTOCOL.md: HELLO trailing bytes / CLIENT_DISPLAYS). No DOM access
// at load time, so `node --test` can import this module directly.

// Client size in device pixels: css size x devicePixelRatio, landscape-normalized,
// clamped to the host's 640x480 minimum.
export function screenPx(cssW, cssH, dpr) {
  const ratio = (typeof dpr === 'number' && isFinite(dpr) && dpr > 0) ? dpr : 1;
  const pw = Math.round(cssW * ratio);
  const ph = Math.round(cssH * ratio);
  const w = Math.max(pw, ph);
  const h = Math.min(pw, ph);
  return { w: Math.max(w, 640), h: Math.max(h, 480) };
}

// ── Monitor-size preference ────────────────────────────────────────────
// 'fit' follows the browser window (the original behaviour); the others ask
// the host for a fixed virtual monitor. `retina` picks 2x (sharp) or 1x
// (a quarter of the pixels, for slow links).
export const SIZE_PRESETS = [
  { id: 'fit', label: 'Fit window' },
  { id: '1920x1080', label: '1920\u00d71080' },
  { id: '2560x1440', label: '2560\u00d71440' },
  { id: '3440x1440', label: '3440\u00d71440' },
  { id: '5120x1440', label: '5120\u00d71440' },
  { id: 'custom', label: 'Custom' },
];
export const DEFAULT_PREFS = Object.freeze({ size: 'fit', custom: '', retina: true });
export const PREFS_KEY = 'clamshell.display';
// Host limits (ClientDisplayRequest.swift).
export const MAX_W = 7680, MAX_H = 4320, MIN_W = 640, MIN_H = 480;

// "2560x1440", "2560 X 1440", "2560\u00d71440" -> {w, h}, or null if unusable.
export function parseSize(text) {
  const m = /^\s*(\d{3,5})\s*[x\u00d7*,]\s*(\d{3,5})\s*$/i.exec(String(text ?? ''));
  if (!m) return null;
  const w = Number(m[1]), h = Number(m[2]);
  if (w < MIN_W || h < MIN_H || w > MAX_W || h > MAX_H) return null;
  return { w, h };
}

// Merge anything (stored JSON, partial object) into a valid prefs object.
export function normalizePrefs(raw) {
  const p = { ...DEFAULT_PREFS };
  if (raw && typeof raw === 'object') {
    if (typeof raw.size === 'string' && SIZE_PRESETS.some((x) => x.id === raw.size)) p.size = raw.size;
    if (typeof raw.custom === 'string') p.custom = raw.custom.slice(0, 20);
    if (typeof raw.retina === 'boolean') p.retina = raw.retina;
  }
  if (p.size === 'custom' && !parseSize(p.custom)) p.size = 'fit';
  return p;
}

export function loadPrefs(storage) {
  try { return normalizePrefs(JSON.parse(storage.getItem(PREFS_KEY))); } catch (e) { return { ...DEFAULT_PREFS }; }
}
export function savePrefs(storage, prefs) {
  try { storage.setItem(PREFS_KEY, JSON.stringify(normalizePrefs(prefs))); return true; } catch (e) { return false; }
}

// What to ask the host for: pixel size and whether the display is plain 1x.
export function displayRequest(cssW, cssH, dpr, prefs = DEFAULT_PREFS) {
  const p = normalizePrefs(prefs);
  if (p.size === 'fit') {
    if (p.retina) return { ...screenPx(cssW, cssH, dpr), oneX: false };
    return { ...screenPx(cssW, cssH, 1), oneX: true };
  }
  const base = p.size === 'custom' ? parseSize(p.custom) : parseSize(p.size);
  let scale = p.retina ? 2 : 1;
  if (base.w * scale > MAX_W || base.h * scale > MAX_H) scale = 1; // e.g. 5120x1440 @2x
  return { w: base.w * scale, h: base.h * scale, oneX: scale === 1 };
}

// Flags byte: bit 0 = second display (not sent by the browser), bit 1 = plain 1x.
function flagsFor(req) { return req.oneX ? 0x02 : 0; }

// HELLO payload: version(1)=1, requestedCodec(1) (1 = H.264, 2 = HEVC),
// widthPx(4 BE), heightPx(4 BE), flags(1). Old hosts ignore flag bit 1.
export function helloPayload(cssW, cssH, dpr, opts = {}) {
  const req = displayRequest(cssW, cssH, dpr, opts.prefs);
  const buf = new Uint8Array(11);
  const dv = new DataView(buf.buffer, buf.byteOffset);
  dv.setUint8(0, 1);       // version
  dv.setUint8(1, opts.codec === 2 ? 2 : 1);
  dv.setUint32(2, req.w, false);
  dv.setUint32(6, req.h, false);
  dv.setUint8(10, flagsFor(req));
  return buf;
}

// CLIENT_DISPLAYS payload: widthPx(4 BE), heightPx(4 BE), flags(1).
export function clientDisplaysPayload(cssW, cssH, dpr, prefs) {
  const req = displayRequest(cssW, cssH, dpr, prefs);
  const buf = new Uint8Array(9);
  const dv = new DataView(buf.buffer, buf.byteOffset);
  dv.setUint32(0, req.w, false);
  dv.setUint32(4, req.h, false);
  dv.setUint8(8, flagsFor(req));
  return buf;
}

// ── Codec choice ───────────────────────────────────────────────────────
// HEVC Main level 4.0 is what the host's encoder produces; the real string is
// re-derived from the keyframe once frames arrive (client.js codecString).
export const HEVC_PROBE = { codec: 'hvc1.1.6.L93.B0', codedWidth: 1920, codedHeight: 1080 };

// 2 (HEVC) if the browser's VideoDecoder can decode it, else 1 (H.264).
export async function pickCodec(VideoDecoderCtor, stickyH264 = false) {
  if (stickyH264) return 1;
  try {
    if (!VideoDecoderCtor || typeof VideoDecoderCtor.isConfigSupported !== 'function') return 1;
    const r = await VideoDecoderCtor.isConfigSupported(HEVC_PROBE);
    return r && r.supported ? 2 : 1;
  } catch (e) { return 1; }
}

// Trailing-edge debounce over an injectable timer pair.
export function debounce(fn, ms, timers = globalThis) {
  let timerId = null;
  let args = [];
  return (...a) => {
    args = a;
    if (timerId !== null) timers.clearTimeout(timerId);
    timerId = timers.setTimeout(() => {
      timerId = null;
      fn(...args);
    }, ms);
  };
}

// Re-report the window size to the host after the window stops resizing.
// `getPrefs` (optional) supplies the current monitor-size preference.
export function attachResizeReporter(win, sendPayload, ms = 250, timers = globalThis, getPrefs = null) {
  const handler = debounce(() => {
    sendPayload(clientDisplaysPayload(win.innerWidth, win.innerHeight, win.devicePixelRatio, getPrefs ? getPrefs() : undefined));
  }, ms, timers);
  win.addEventListener('resize', handler);
  return handler;
}
