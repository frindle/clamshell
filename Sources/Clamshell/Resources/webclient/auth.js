// Device authentication and the encrypted session for the browser client
// (PROTOCOL.md "Device authentication and encrypted session").
//
// No page and no socket in here: WebCrypto is handed in (`cr`, default
// `globalThis.crypto`), and every import is relative, so node can load this
// file. tests/vectors/auth-v1.json pins every byte it produces; the Swift
// reference is Sources/Clamshell/Streaming/SecureSession.swift.
//
// Sections: bytes and framing, names, ids and keys, handshake payloads, the
// handshake, session keys, SECURE sealing and opening, the device key and the
// stores, known hosts, and the connection flow (AuthFlow).

// ── Constants ───────────────────────────────────────────────────────────
export const MSG = {
  HELLO: 0x01, PING: 0x07,
  AUTH_CHALLENGE: 0x08, AUTH_RESPONSE: 0x09, AUTH_RESULT: 0x0A,
  HOST_INFO: 0x0B, CLIENT_INFO: 0x0C, SECURE: 0x0F,
};
export const STATUS = { accepted: 0, pending: 1, denied: 2, invalid: 3, busy: 4, timeout: 5 };
export const AUTH = {
  version: 1, keyBytes: 65, nonceBytes: 32, signatureBytes: 64,
  maxNameBytes: 64, tagBytes: 16, counterLimit: 2 ** 48,
};
// What the web client really does today: relative mouse (pointer lock) and
// the extra mouse buttons, the Restart button (bit 7) and the Log in form for
// the login window (bit 8). It never sends text input. Bits 4 to 6 stay 0.
export const WEB_CAPS = (1 << 1) | (1 << 3) | (1 << 7) | (1 << 8);
// A choice of this client: the page is served by the host, so there is no
// separate release number to report.
export const WEB_CLIENT_VERSION = '1';
export const DEFAULT_PORT = 5903;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const clientContext = textEncoder.encode('clamshell-auth-v1/client\0');
const hostContext = textEncoder.encode('clamshell-auth-v1/host\0');
const sessionInfo = textEncoder.encode('clamshell-session-v1');

export class AuthError extends Error {
  constructor(code, message) { super(message || code); this.code = code; }
}

// ── Bytes and framing ───────────────────────────────────────────────────
export function bytes(text) { return textEncoder.encode(text); }

export function concat(...parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

export function u32(n) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n, false);
  return b;
}

export function u16(n) {
  const b = new Uint8Array(2);
  new DataView(b.buffer).setUint16(0, n, false);
  return b;
}

export function toHex(b) {
  let s = '';
  for (const x of b) s += x.toString(16).padStart(2, '0');
  return s;
}

export function fromHex(text) {
  if (typeof text !== 'string' || text.length % 2 !== 0 || /[^0-9a-fA-F]/.test(text)) return null;
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(text.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function equalBytes(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

/** `L(x)`: the 4-byte big-endian length of x, then x. */
export function prefixed(x) { return concat(u32(x.length), x); }

/** One whole message: type, 4-byte big-endian length, payload. */
export function frame(type, payload = new Uint8Array(0)) {
  return concat(Uint8Array.of(type), u32(payload.length), payload);
}

export function clientSignatureInput(challenge, responseBody) {
  return concat(clientContext, prefixed(challenge), prefixed(responseBody));
}

export function hostSignatureInput(challenge, response, resultBody) {
  return concat(hostContext, prefixed(challenge), prefixed(response), prefixed(resultBody));
}

class Reader {
  constructor(b) { this.b = b; this.o = 0; }
  get remaining() { return this.b.length - this.o; }
  get atEnd() { return this.remaining === 0; }
  byte() { return this.remaining >= 1 ? this.b[this.o++] : null; }
  take(n) {
    if (!(n >= 0) || this.remaining < n) return null;
    const out = this.b.subarray(this.o, this.o + n);
    this.o += n;
    return out;
  }
  u16() { const t = this.take(2); return t ? (t[0] << 8) | t[1] : null; }
  u32() { const t = this.take(4); return t ? ((t[0] * 2 ** 24) + (t[1] << 16) + (t[2] << 8) + t[3]) : null; }
}

// ── Names ───────────────────────────────────────────────────────────────
const strippedScalar = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}\p{Cn}\p{Co}]/u;
const edgeSpace = /^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu;

/**
 * A name as it is shown: no control characters, no invisible formatting
 * characters (the bidirectional overrides among them), no space at either
 * end, and at most 64 bytes of UTF-8 without splitting a character.
 */
export function cleanName(raw) {
  let kept = '';
  for (const ch of String(raw)) if (!strippedScalar.test(ch)) kept += ch;
  const trimmed = kept.replace(edgeSpace, '');
  let out = '';
  let n = 0;
  for (const ch of trimmed) {
    const len = textEncoder.encode(ch).length;
    if (n + len > AUTH.maxNameBytes) break;
    n += len;
    out += ch;
  }
  return out.replace(edgeSpace, '');
}

/** "Safari on Mac": ASCII, at most 64 bytes, from the user agent. */
export function webDeviceName(ua) {
  const s = String(ua || '');
  let browser = 'Browser';
  if (/Edg(e|A|iOS)?\//.test(s)) browser = 'Edge';
  else if (/(Chrome|CriOS)\//.test(s)) browser = 'Chrome';
  else if (/(Firefox|FxiOS)\//.test(s)) browser = 'Firefox';
  else if (/Safari\//.test(s)) browser = 'Safari';
  let os = '';
  if (/iPhone/.test(s)) os = 'iPhone';
  else if (/iPad/.test(s)) os = 'iPad';
  else if (/Android/.test(s)) os = 'Android';
  else if (/CrOS/.test(s)) os = 'ChromeOS';
  else if (/Windows/.test(s)) os = 'Windows';
  else if (/Mac OS X|Macintosh/.test(s)) os = 'Mac';
  else if (/Linux|X11/.test(s)) os = 'Linux';
  const name = os ? `${browser} on ${os}` : browser;
  return name.slice(0, AUTH.maxNameBytes);
}

// ── Ids and keys ────────────────────────────────────────────────────────
export function getCrypto(cr) { return cr || globalThis.crypto || null; }

/** True when WebCrypto is there to prove anything (not on plain http://). */
export function hasWebCrypto(cr) {
  const c = getCrypto(cr);
  return !!(c && c.subtle && typeof c.getRandomValues === 'function');
}

export async function sha256(data, cr) {
  return new Uint8Array(await getCrypto(cr).subtle.digest('SHA-256', data));
}

/** Lowercase hex SHA-256 of the 65-byte public key. */
export async function keyId(publicKey, cr) { return toHex(await sha256(publicKey, cr)); }

/** `AB12-CD34-EF56-7890`: the first 16 characters of an id, upper case, in fours. */
export function fingerprintOfId(id) {
  const head = id.toUpperCase().slice(0, 16);
  return head.match(/.{1,4}/g).join('-');
}

export async function fingerprintOfKey(publicKey, cr) {
  return fingerprintOfId(await keyId(publicKey, cr));
}

const ECDSA = { name: 'ECDSA', namedCurve: 'P-256' };
const ECDH = { name: 'ECDH', namedCurve: 'P-256' };

/** A 65-byte uncompressed point that is on the curve. */
export async function isValidPublicKey(key, cr) {
  if (!(key instanceof Uint8Array) || key.length !== AUTH.keyBytes || key[0] !== 0x04) return false;
  try {
    await getCrypto(cr).subtle.importKey('raw', key, ECDSA, true, ['verify']);
    return true;
  } catch { return false; }
}

export async function verifySignature(signature, input, publicKey, cr) {
  if (!(signature instanceof Uint8Array) || signature.length !== AUTH.signatureBytes) return false;
  if (!(await isValidPublicKey(publicKey, cr))) return false;
  const subtle = getCrypto(cr).subtle;
  try {
    const key = await subtle.importKey('raw', publicKey, ECDSA, false, ['verify']);
    return await subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, signature, input);
  } catch { return false; }
}

// ── Handshake payloads ──────────────────────────────────────────────────
export function encodeExtensions(list) {
  const parts = [];
  for (const e of list || []) {
    if (e.value.length > 0xFFFF) throw new AuthError('malformed');
    parts.push(Uint8Array.of(e.type), u16(e.value.length), e.value);
  }
  const out = concat(...parts);
  if (out.length > 0xFFFF) throw new AuthError('malformed');
  return out;
}

/** Records fill the block exactly; one that runs past the end is malformed. */
export function decodeExtensions(block) {
  const out = [];
  const r = new Reader(block);
  while (!r.atEnd) {
    const type = r.byte();
    const len = r.u16();
    const value = len === null ? null : r.take(len);
    if (type === null || value === null) throw new AuthError('malformed');
    out.push({ type, value });
  }
  return out;
}

/** The fields AUTH_CHALLENGE and AUTH_RESPONSE share, in wire order. */
export function encodeHello({ caps, nonce, ephemeral, identity, name, extensions }) {
  if (nonce.length !== AUTH.nonceBytes || ephemeral.length !== AUTH.keyBytes
      || identity.length !== AUTH.keyBytes) throw new AuthError('malformed');
  const nameBytes = bytes(name);
  if (nameBytes.length > AUTH.maxNameBytes) throw new AuthError('malformed');
  const ext = encodeExtensions(extensions);
  return concat(Uint8Array.of(AUTH.version), u32(caps >>> 0), nonce, ephemeral, identity,
    Uint8Array.of(nameBytes.length), nameBytes, u16(ext.length), ext);
}

function decodeHello(r) {
  const version = r.byte();
  if (version === null) throw new AuthError('malformed');
  if (version !== AUTH.version) throw new AuthError('unsupportedVersion');
  const caps = r.u32();
  const nonce = r.take(AUTH.nonceBytes);
  const ephemeral = r.take(AUTH.keyBytes);
  const identity = r.take(AUTH.keyBytes);
  const nameLen = r.byte();
  const nameBytes = nameLen !== null && nameLen <= AUTH.maxNameBytes ? r.take(nameLen) : null;
  const extLen = nameBytes ? r.u16() : null;
  const ext = extLen !== null ? r.take(extLen) : null;
  if (caps === null || !nonce || !ephemeral || !identity || !nameBytes || !ext) throw new AuthError('malformed');
  return {
    caps, nonce, ephemeral, identity,
    name: textDecoder.decode(nameBytes),
    extensions: decodeExtensions(ext),
  };
}

/** Layout only: nothing is trusted until the keys are checked. */
export function parseChallenge(payload) {
  const r = new Reader(payload);
  const hello = decodeHello(r);
  if (!r.atEnd) throw new AuthError('malformed');
  return { ...hello, displayName: cleanName(hello.name), payload };
}

export function parseResult(payload) {
  const r = new Reader(payload);
  const status = r.byte();
  const extLen = status === null ? null : r.u16();
  const ext = extLen === null ? null : r.take(extLen);
  if (status === null || status > STATUS.timeout || ext === null
      || r.remaining !== AUTH.signatureBytes) throw new AuthError('malformed');
  const signature = r.take(AUTH.signatureBytes);
  return {
    status,
    extensions: decodeExtensions(ext),
    body: payload.subarray(0, payload.length - AUTH.signatureBytes),
    signature,
  };
}

// ── The handshake (client side) ─────────────────────────────────────────
export async function transcriptHash(challenge, response, cr) {
  return sha256(concat(prefixed(challenge), prefixed(response)), cr);
}

/**
 * Session key material: ECDH on the two key-exchange keys (the X coordinate),
 * then HKDF-SHA256 with salt hostNonce ‖ clientNonce and info
 * "clamshell-session-v1" ‖ transcript hash, 64 bytes. Symmetric: the host's
 * side of a test passes its own private key and the client's public one.
 */
export async function deriveSessionMaterial({ privateKey, peerPublic, hostNonce, clientNonce,
  challenge, response }, cr) {
  const subtle = getCrypto(cr).subtle;
  const peer = await subtle.importKey('raw', peerPublic, ECDH, false, []);
  const z = await subtle.deriveBits({ name: 'ECDH', public: peer }, privateKey, 256);
  const th = await transcriptHash(challenge, response, cr);
  const hkdf = await subtle.importKey('raw', z, 'HKDF', false, ['deriveBits']);
  const okm = new Uint8Array(await subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: concat(hostNonce, clientNonce), info: concat(sessionInfo, th) },
    hkdf, 512));
  return {
    hostToClient: okm.slice(0, 32),
    clientToHost: okm.slice(32, 64),
    transcriptHash: th,
  };
}

/**
 * A new key-exchange pair. Tests pass `ephemeral` instead (see
 * `importEphemeral`), so the bytes are fixed.
 */
export async function generateEphemeral(cr) {
  const subtle = getCrypto(cr).subtle;
  const pair = await subtle.generateKey(ECDH, false, ['deriveBits']);
  const publicRaw = new Uint8Array(await subtle.exportKey('raw', pair.publicKey));
  return { privateKey: pair.privateKey, publicRaw };
}

/** For tests: a key-exchange pair from a 32-byte scalar and its 65-byte public key. */
export async function importEphemeral(privateScalar, publicRaw, cr) {
  const b64 = (b) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const privateKey = await getCrypto(cr).subtle.importKey('jwk', {
    kty: 'EC', crv: 'P-256', d: b64(privateScalar),
    x: b64(publicRaw.subarray(1, 33)), y: b64(publicRaw.subarray(33, 65)),
  }, ECDH, false, ['deriveBits']);
  return { privateKey, publicRaw };
}

export class ClientHandshake {
  constructor(fields) { Object.assign(this, fields); }

  /**
   * Reads the challenge, builds the signed response. Throws for a challenge of
   * another version or with a key that is not a valid curve point: either is a
   * failed connection.
   */
  static async create({ challengePayload, deviceKey, caps, name, sign, extensions = [],
    ephemeral, nonce, cr }) {
    const c = getCrypto(cr);
    const challenge = parseChallenge(challengePayload);
    if (!(await isValidPublicKey(challenge.identity, c)) || !(await isValidPublicKey(challenge.ephemeral, c))
        || !(await isValidPublicKey(deviceKey, c))) throw new AuthError('invalidKey');
    const eph = ephemeral || await generateEphemeral(c);
    const clientNonce = nonce || c.getRandomValues(new Uint8Array(AUTH.nonceBytes));
    const body = encodeHello({ caps, nonce: clientNonce, ephemeral: eph.publicRaw, identity: deviceKey,
      name: cleanName(name), extensions });
    const signature = await sign(clientSignatureInput(challengePayload, body));
    if (!(signature instanceof Uint8Array) || signature.length !== AUTH.signatureBytes) {
      throw new AuthError('badSignature');
    }
    const hostId = await keyId(challenge.identity, c);
    return new ClientHandshake({
      cr: c, challenge, response: concat(body, signature), nonce: clientNonce, ephemeral: eph,
      hostId, hostFingerprint: fingerprintOfId(hostId),
    });
  }

  get hostIdentityKey() { return this.challenge.identity; }
  get hostName() { return this.challenge.displayName; }
  get hostCapabilities() { return this.challenge.caps; }

  /**
   * The status of an AUTH_RESULT whose signature verifies against the
   * challenge's host key. One that does not verify is a failed connection,
   * whatever its status says.
   */
  async statusOfResult(payload) {
    const result = parseResult(payload);
    const covered = (result.status === STATUS.busy || result.status === STATUS.timeout)
      ? new Uint8Array(0) : this.response;
    const input = hostSignatureInput(this.challenge.payload, covered, result.body);
    if (!(await verifySignature(result.signature, input, this.hostIdentityKey, this.cr))) {
      throw new AuthError('badSignature');
    }
    return result.status;
  }

  /** The two session keys as raw bytes (see `deriveSessionMaterial`). */
  sessionMaterial() {
    return deriveSessionMaterial({
      privateKey: this.ephemeral.privateKey, peerPublic: this.challenge.ephemeral,
      hostNonce: this.challenge.nonce, clientNonce: this.nonce,
      challenge: this.challenge.payload, response: this.response,
    }, this.cr);
  }
}

// ── SECURE ──────────────────────────────────────────────────────────────
/** `0x00000000 ‖ u64be(counter)`. */
export function secureNonce(counter) {
  const n = new Uint8Array(12);
  const dv = new DataView(n.buffer);
  dv.setUint32(4, Math.floor(counter / 2 ** 32), false);
  dv.setUint32(8, counter % 2 ** 32, false);
  return n;
}

/** SECURE and the three AUTH messages never travel inside SECURE. */
export function isForbiddenInner(type) {
  return type === MSG.SECURE || type === MSG.AUTH_CHALLENGE || type === MSG.AUTH_RESPONSE
    || type === MSG.AUTH_RESULT;
}

export function importSessionKey(raw, cr) {
  return getCrypto(cr).subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

/**
 * Encrypts one direction. A message gets its counter in the synchronous step
 * that queues it, and is handed to `write` from one promise chain, so the
 * order on the wire is the order of the counters. A failure stops the chain
 * and calls `onError` once; nothing after it is written.
 */
export class Sealer {
  constructor(key, write, { cr, onError } = {}) {
    this.key = key; this.write = write; this.cr = getCrypto(cr);
    this.onError = onError || (() => {});
    this.counter = 0;
    this.failed = false;
    this.chain = Promise.resolve();
  }

  /** Queues one whole inner message. Throws at once if it may not be sent. */
  seal(inner) {
    if (this.failed) throw new AuthError('closed');
    if (this.counter >= AUTH.counterLimit) throw new AuthError('counterExhausted');
    if (inner.length < 5 || new DataView(inner.buffer, inner.byteOffset, inner.length).getUint32(1, false) !== inner.length - 5
        || isForbiddenInner(inner[0])) throw new AuthError('forbiddenInnerMessage');
    const counter = this.counter++;
    const copy = inner.slice();
    const done = this.chain.then(async () => {
      if (this.failed) return;
      const ct = new Uint8Array(await this.cr.subtle.encrypt(
        { name: 'AES-GCM', iv: secureNonce(counter), tagLength: 128 }, this.key, copy));
      if (this.failed) return;
      this.write(frame(MSG.SECURE, ct));
    }).catch((e) => {
      if (this.failed) return;
      this.failed = true;
      this.onError(e);
    });
    this.chain = done;
    return done;
  }

  /** Resolves when everything queued so far has been written. */
  settled() { return this.chain; }
}

/**
 * Decrypts the other direction. `open` calls must be awaited one at a time in
 * arrival order (AuthFlow does); any error means the connection is closed.
 */
export class Opener {
  constructor(key, { cr } = {}) { this.key = key; this.cr = getCrypto(cr); this.counter = 0; }

  async open(payload) {
    if (this.counter >= AUTH.counterLimit) throw new AuthError('counterExhausted');
    if (payload.length < AUTH.tagBytes) throw new AuthError('decryptFailed');
    let inner;
    try {
      inner = new Uint8Array(await this.cr.subtle.decrypt(
        { name: 'AES-GCM', iv: secureNonce(this.counter), tagLength: 128 }, this.key, payload));
    } catch { throw new AuthError('decryptFailed'); }
    this.counter++;
    if (inner.length < 5 || new DataView(inner.buffer, inner.byteOffset, inner.length).getUint32(1, false) !== inner.length - 5) {
      throw new AuthError('malformed');
    }
    if (isForbiddenInner(inner[0])) throw new AuthError('forbiddenInnerMessage');
    return { type: inner[0], payload: inner.subarray(5) };
  }
}

// ── Stores ──────────────────────────────────────────────────────────────
/** A store for tests: the same interface as the IndexedDB one. */
export function memoryStore(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    async get(k) { return map.has(k) ? map.get(k) : undefined; },
    async set(k, v) { map.set(k, v); },
    async add(k, v) { if (map.has(k)) return false; map.set(k, v); return true; },
    async delete(k) { map.delete(k); },
  };
}

/**
 * IndexedDB, which can hold CryptoKey objects without making them readable.
 * `add` fails when the key exists, so two tabs cannot both make a device key.
 */
export function idbStore(dbName = 'clamshell-auth', storeName = 'kv') {
  let opened = null;
  function db() {
    if (!opened) {
      opened = new Promise((resolve, reject) => {
        const req = globalThis.indexedDB.open(dbName, 1);
        req.onupgradeneeded = () => req.result.createObjectStore(storeName);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error || new Error('IndexedDB could not be opened'));
        req.onblocked = () => reject(new Error('IndexedDB is blocked'));
      });
      opened.catch(() => { opened = null; });
    }
    return opened;
  }
  async function run(mode, fn) {
    const d = await db();
    return new Promise((resolve, reject) => {
      const tx = d.transaction(storeName, mode);
      let request;
      try { request = fn(tx.objectStore(storeName)); } catch (e) { reject(e); return; }
      tx.oncomplete = () => resolve(request ? request.result : undefined);
      tx.onerror = () => reject(tx.error || new Error('IndexedDB failed'));
      tx.onabort = () => reject(tx.error || new Error('IndexedDB aborted'));
    });
  }
  return {
    get: (k) => run('readonly', (s) => s.get(k)),
    set: (k, v) => run('readwrite', (s) => { s.put(v, k); }),
    delete: (k) => run('readwrite', (s) => { s.delete(k); }),
    async add(k, v) {
      const d = await db();
      return new Promise((resolve, reject) => {
        const tx = d.transaction(storeName, 'readwrite');
        const req = tx.objectStore(storeName).add(v, k);
        req.onerror = (ev) => { ev.preventDefault(); resolve(false); };
        tx.oncomplete = () => resolve(true);
        tx.onabort = () => { if (!req.error) reject(tx.error || new Error('IndexedDB aborted')); };
      });
    },
  };
}

// ── The device key ──────────────────────────────────────────────────────
export const DEVICE_KEY_NAME = 'device-key';

/**
 * This browser's signing key. Made once, with `extractable: false`, and kept
 * as CryptoKey objects: the private key cannot be exported and nothing tries
 * to. A new key is made only when the store says there is none. A store that
 * cannot be read, or a record that is not a key pair, is an error: a fresh key
 * would be a new device the Mac has never approved.
 */
export async function loadDeviceKey(store, cr) {
  const c = getCrypto(cr);
  let record;
  try { record = await store.get(DEVICE_KEY_NAME); } catch (e) {
    throw new AuthError('storeUnreadable', 'This browser\u2019s device key could not be read.');
  }
  if (record === undefined || record === null) {
    const pair = await c.subtle.generateKey(ECDSA, false, ['sign', 'verify']);
    const fresh = { privateKey: pair.privateKey, publicKey: pair.publicKey };
    let added;
    try {
      added = typeof store.add === 'function'
        ? await store.add(DEVICE_KEY_NAME, fresh)
        : (await store.set(DEVICE_KEY_NAME, fresh), true);
      if (!added) record = await store.get(DEVICE_KEY_NAME);
    } catch (e) {
      throw new AuthError('storeUnwritable', 'This browser\u2019s device key could not be saved.');
    }
    if (added) record = fresh;
  }
  if (!record || !record.privateKey || !record.publicKey || record.privateKey.type !== 'private'
      || record.privateKey.algorithm?.name !== 'ECDSA') {
    throw new AuthError('storeUnreadable', 'This browser\u2019s device key could not be read.');
  }
  const publicRaw = new Uint8Array(await c.subtle.exportKey('raw', record.publicKey));
  const privateKey = record.privateKey;
  return {
    publicRaw,
    sign: async (input) => new Uint8Array(await c.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, input)),
  };
}

// ── Known hosts ─────────────────────────────────────────────────────────
// What the browser remembers about the Macs it has met: each host's identity
// key, the name it last gave, and the addresses it has been reached at or has
// reported. Public keys and addresses only. A port of
// Sources/Clamshell/Streaming/KnownHosts.swift.
export const KNOWN = { maxAddressesPerHost: 16, maxHintBytes: 256, maxAllowedAddresses: 64 };
export const KNOWN_HOSTS_NAME = 'known-hosts';

/**
 * The lower-cased `host:port` a client dials, from a bare host (default port
 * 5903) or a ws/wss URL (default 80 or 443). Scheme, path, user info, query
 * and fragment are dropped. null when the text is not an address.
 */
export function normalizeAddress(text) {
  // An IPv6 zone id ("[fe80::1%en0]", or "%25en0" as a URL writes it) names a
  // local interface, not a Mac; the Swift and C# code drop it, so this does.
  const t = String(text).replace(/^[ \t]+|[ \t]+$/g, '').replace(/(\[[^\]%]*)%[^\]]*\]/, '$1]');
  if (!t) return null;
  const bare = !t.includes('://');
  let u;
  try { u = new URL(bare ? `x://${t}` : t); } catch { return null; }
  const scheme = bare ? 'ws' : u.protocol.replace(/:$/, '').toLowerCase();
  if (scheme !== 'ws' && scheme !== 'wss') return null;
  let host = u.hostname.toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
  if (!host) return null;
  const port = u.port ? Number(u.port) : (bare ? DEFAULT_PORT : (scheme === 'wss' ? 443 : 80));
  if (!(port >= 1 && port <= 65535)) return null;
  return `${host.includes(':') ? `[${host}]` : host}:${port}`;
}

/** The address of a URL a host reported in HOST_INFO, under the spec's limits. */
export function hintAddress(url) {
  if (typeof url !== 'string' || bytes(url).length > KNOWN.maxHintBytes || !url.includes('://')) return null;
  if (url.includes('?') || url.includes('#')) return null;
  let u;
  try { u = new URL(url); } catch { return null; }
  const scheme = u.protocol.replace(/:$/, '').toLowerCase();
  if ((scheme !== 'ws' && scheme !== 'wss') || u.username || u.password || !u.hostname) return null;
  return normalizeAddress(url);
}

/**
 * The path of a wss URL when it names a display: ends in `/ws/<letter>`, at
 * most 64 bytes, only letters, digits and `/ _ . -`. null otherwise.
 */
export function displayPath(text) {
  if (typeof text !== 'string' || !text.includes('://')) return null;
  let u;
  try { u = new URL(text); } catch { return null; }
  if (u.protocol !== 'wss:') return null;
  const p = u.pathname;
  return bytes(p).length <= 64 && /^[A-Za-z0-9/_.-]*\/ws\/[a-z]$/.test(p) ? p : null;
}

/** The port of a normalized `host:port`. */
export function portOf(address) {
  const n = Number(address.slice(address.lastIndexOf(':') + 1));
  return Number.isInteger(n) ? n : null;
}

/**
 * Which display a dialled address is for, counting from 0 (A). A `/ws/<letter>`
 * path names it; a direct address is on port 5903 + n. null when neither says.
 */
export function displayIndex(text) {
  const p = displayPath(text);
  if (p) return p.charCodeAt(p.length - 1) - 97;
  const a = normalizeAddress(text);
  const port = a ? portOf(a) : null;
  if (port === null || port === 443) return null;
  const n = port - DEFAULT_PORT;
  return n >= 0 && n < 26 ? n : null;
}

/** `wss://host` + the saved path with its final display letter replaced. */
export function tunnelUrl(host, path, display) {
  if (!(display >= 0 && display <= 25) || displayPath(`wss://${host}${path}`) !== path) return null;
  return `wss://${host}${path.slice(0, -1)}${String.fromCharCode(97 + display)}`;
}

export class KnownHosts {
  constructor() {
    /** [{id, key (hex), name, addresses: [{address, verified, lastUsed, lastSuccess}]}] */
    this.hosts = [];
    /** Addresses the user let an unverified connection go to, oldest first. */
    this.unverifiedAllowed = [];
  }

  host(id) { return this.hosts.find((h) => h.id === id) || null; }

  /** `{kind: 'host', id}`, `{kind: 'unknown'}` or `{kind: 'unknownAllowed'}`. */
  standing(address) {
    const a = normalizeAddress(address);
    if (a === null) return { kind: 'unknown' };
    const h = this.hosts.find((x) => x.addresses.some((y) => y.address === a));
    if (h) return { kind: 'host', id: h.id };
    return { kind: this.unverifiedAllowed.includes(a) ? 'unknownAllowed' : 'unknown' };
  }

  isVerified(address, hostId) {
    const a = normalizeAddress(address);
    const h = this.host(hostId);
    return !!(a && h && h.addresses.some((x) => x.address === a && x.verified));
  }

  /** The addresses to try for a host: last successful first, then verified, then hints. */
  dialOrder(hostId) {
    const h = this.host(hostId);
    if (!h) return [];
    const ls = (x) => (x.lastSuccess === null || x.lastSuccess === undefined ? -Infinity : x.lastSuccess);
    return h.addresses.map((x, i) => ({ x, i })).sort((l, r) => {
      if (ls(l.x) !== ls(r.x)) return ls(r.x) - ls(l.x);
      if (l.x.verified !== r.x.verified) return l.x.verified ? -1 : 1;
      if (l.x.lastUsed !== r.x.lastUsed) return r.x.lastUsed - l.x.lastUsed;
      return l.i - r.i;
    }).map((e) => e.x.address);
  }

  /**
   * The URLs to try after `picked` for a host, in dial order, every one for
   * the same display as `picked`: a direct address on the same port (or on the
   * picked display's port, when `picked` is a tunnel), and a tunnel address
   * with the saved path switched to the picked display's letter. An address
   * with no saved path (a copy from before the path was kept) gives no tunnel
   * fallback until the next connection that reaches it.
   */
  fallbackUrls(hostId, picked) {
    const pickedAddress = normalizeAddress(picked);
    const h = this.host(hostId);
    if (!pickedAddress || !h) return [];
    const index = displayIndex(picked);
    const pickedPort = portOf(pickedAddress);
    const out = [];
    for (const address of this.dialOrder(hostId)) {
      if (address === pickedAddress) continue;
      const port = portOf(address);
      const name = address.slice(0, address.lastIndexOf(':'));
      if (port === 443) {
        const saved = h.addresses.find((x) => x.address === address).path;
        if (index === null || !saved) continue;
        const url = tunnelUrl(name, saved, index);
        if (url) out.push(url);
      } else {
        const want = pickedPort === 443 ? (index === null ? null : DEFAULT_PORT + index) : pickedPort;
        if (want === port) out.push(`ws://${name}:${port}`);
      }
    }
    return out;
  }

  /**
   * Remembers a host whose key was verified at an address: adds it if new,
   * binds the address to it (taking the address from any other host), and
   * clears the "unverified allowed" mark. `id` is the key's id.
   */
  recordVerified({ key, id, name, address }, now) {
    const a = normalizeAddress(address);
    if (!(key instanceof Uint8Array) || key.length !== AUTH.keyBytes || !a || !id) return;
    const shown = cleanName(name);
    const existing = this.host(id);
    if (existing) {
      if (shown) existing.name = shown;
    } else {
      this.hosts.push({ id, key: toHex(key), name: shown, addresses: [] });
    }
    this.bind(address, id, now);
  }

  /** Binds an address to a host that is already known. Does nothing for an unknown host. */
  bind(address, id, now) {
    const a = normalizeAddress(address);
    const h = this.host(id);
    if (!a || !h) return;
    // `address` may be the URL that was dialled: its display path is kept.
    const path = displayPath(address);
    for (const other of this.hosts) if (other !== h) other.addresses = other.addresses.filter((x) => x.address !== a);
    const have = h.addresses.find((x) => x.address === a);
    if (have) {
      have.verified = true; have.lastUsed = now; have.lastSuccess = now;
      if (path) have.path = path;
    } else {
      h.addresses.push({ address: a, verified: true, lastUsed: now, lastSuccess: now, ...(path ? { path } : {}) });
    }
    this.unverifiedAllowed = this.unverifiedAllowed.filter((x) => x !== a);
    this.#trim(h);
  }

  /**
   * Adds the addresses a host reported as hints. A URL that breaks the spec's
   * limits is skipped, and so is an address that belongs to another host.
   */
  addHints(urls, id, now) {
    const h = this.host(id);
    if (!h) return;
    for (const url of urls) {
      const a = hintAddress(url);
      if (!a) continue;
      if (this.hosts.some((o) => o !== h && o.addresses.some((x) => x.address === a))) continue;
      const path = displayPath(url);
      const have = h.addresses.find((x) => x.address === a);
      if (have) {
        // Already known: only fill in a display path it does not have yet.
        if (!have.path && path) have.path = path;
        continue;
      }
      h.addresses.push({ address: a, verified: false, lastUsed: now, lastSuccess: null, ...(path ? { path } : {}) });
      this.unverifiedAllowed = this.unverifiedAllowed.filter((x) => x !== a);
      this.#trim(h);
    }
  }

  /** The user let an unverified connection go to this address. Ignored for a host's address. */
  allowUnverified(address) {
    const a = normalizeAddress(address);
    if (!a || this.standing(a).kind === 'host' || this.unverifiedAllowed.includes(a)) return;
    this.unverifiedAllowed.push(a);
    if (this.unverifiedAllowed.length > KNOWN.maxAllowedAddresses) {
      this.unverifiedAllowed = this.unverifiedAllowed.slice(-KNOWN.maxAllowedAddresses);
    }
  }

  /** Removes a host's key and every address bound to it. */
  forget(id) { this.hosts = this.hosts.filter((h) => h.id !== id); }

  /** At most 16 per host: a hint goes before any verified address, the one unused longest first. */
  #trim(h) {
    while (h.addresses.length > KNOWN.maxAddressesPerHost) {
      const hints = h.addresses.filter((x) => !x.verified);
      const pool = hints.length ? hints : h.addresses;
      let drop = pool[0];
      for (const x of pool) if (x.lastUsed < drop.lastUsed) drop = x;
      h.addresses.splice(h.addresses.indexOf(drop), 1);
    }
  }

  /** Applies one change the flow reported. */
  apply(change, now) {
    switch (change.kind) {
      case 'recordVerified': this.recordVerified(change, now); break;
      case 'bind': this.bind(change.address, change.hostId, now); break;
      case 'hints': this.addHints(change.urls, change.hostId, now); break;
      case 'allowUnverified': this.allowUnverified(change.address); break;
      case 'forget': this.forget(change.hostId); break;
      default: break;
    }
  }

  encode() {
    return JSON.stringify({ version: 1, hosts: this.hosts, unverifiedAllowed: this.unverifiedAllowed });
  }

  /**
   * Reads a stored copy. `undefined` or `null` means nothing was stored yet. A
   * copy that cannot be read gives an empty store and `damaged`; one with some
   * unreadable entries keeps every entry that could be read and sets `damaged`
   * too. A host key that is not a valid curve point, or whose id does not match
   * its key, is dropped. `why` names the first problem found (no addresses or
   * names in it), so a damaged copy can be told apart from a screenshot.
   */
  static async decode(text, cr) {
    const out = new KnownHosts();
    if (text === undefined || text === null) return { known: out, damaged: false, why: null };
    let stored;
    try { stored = JSON.parse(text); } catch { return { known: out, damaged: true, why: 'the saved copy is not readable data' }; }
    if (!stored || typeof stored !== 'object' || !Array.isArray(stored.hosts)) {
      return { known: out, damaged: true, why: 'the saved copy has no list of Macs' };
    }
    let why = null;
    const flag = (w) => { if (!why) why = w; };
    const claimed = new Set();
    for (const entry of stored.hosts) {
      const key = entry && typeof entry.key === 'string' ? fromHex(entry.key) : null;
      if (!key || !(await isValidPublicKey(key, cr))) { flag('a saved key is not valid'); continue; }
      const id = await keyId(key, cr);
      const addresses = [];
      for (const a of Array.isArray(entry.addresses) ? entry.addresses : []) {
        const n = a && typeof a.address === 'string' ? normalizeAddress(a.address) : null;
        const bad = !n ? 'an address cannot be read'
          : n !== a.address ? 'an address is not in its standard form'
          : claimed.has(n) || addresses.some((x) => x.address === n) ? 'an address is listed twice'
          : typeof a.lastUsed !== 'number' ? 'an address has no last-used time' : null;
        if (bad) { flag(bad); continue; }
        // A path that is not a display path is dropped, not trusted.
        const path = typeof a.path === 'string' && portOf(n) === 443 && displayPath(`wss://x${a.path}`) === a.path
          ? a.path : null;
        addresses.push({
          address: n, verified: a.verified === true, lastUsed: a.lastUsed,
          lastSuccess: typeof a.lastSuccess === 'number' ? a.lastSuccess : null,
          ...(path ? { path } : {}),
        });
      }
      const name = cleanName(typeof entry.name === 'string' ? entry.name : '');
      const have = out.host(id);
      if (have) { flag('a Mac is listed twice'); have.addresses.push(...addresses); } else out.hosts.push({ id, key: toHex(key), name, addresses });
      for (const a of addresses) claimed.add(a.address);
    }
    for (const h of out.hosts) out.#trim(h);
    const allowed = Array.isArray(stored.unverifiedAllowed) ? stored.unverifiedAllowed : [];
    for (const text2 of allowed) {
      const n = typeof text2 === 'string' ? normalizeAddress(text2) : null;
      if (!n || n !== text2) { flag('an allowed address is not in its standard form'); continue; }
      if (!claimed.has(n) && !out.unverifiedAllowed.includes(n)) out.unverifiedAllowed.push(n);
    }
    if (out.unverifiedAllowed.length > KNOWN.maxAllowedAddresses) {
      out.unverifiedAllowed = out.unverifiedAllowed.slice(-KNOWN.maxAllowedAddresses);
    }
    return { known: out, damaged: why !== null, why };
  }
}

/** Loads known hosts through a store. A store that cannot be read gives an empty one, damaged. */
export async function loadKnownHosts(store, cr) {
  let text;
  try { text = await store.get(KNOWN_HOSTS_NAME); } catch {
    return { known: new KnownHosts(), damaged: true, why: 'this browser\u2019s storage could not be read' };
  }
  return KnownHosts.decode(text, cr);
}

export async function saveKnownHosts(store, known) {
  await store.set(KNOWN_HOSTS_NAME, known.encode());
}

// ── The connection flow ─────────────────────────────────────────────────
export const FLOW = {
  challengeWait: 2, lateChallengeWait: 10, resultWait: 15, pendingWait: 60,
  busyFirstDelay: 15, busyMaxDelay: 120,
};

export const HTTPS_NEEDED_TEXT = 'This Mac only accepts devices it has approved. '
  + 'A browser can only prove which device it is on an https page.';

export function newCarry() {
  return { challengeWait: FLOW.challengeWait, busyDelay: FLOW.busyFirstDelay, timeoutRetried: false };
}

/** The URL without user info, query or fragment, as the spec wants it. */
export function cleanURL(text) {
  try {
    const u = new URL(text);
    u.username = ''; u.password = ''; u.search = ''; u.hash = '';
    return u.toString();
  } catch { return null; }
}

/** Every URL HOST_INFO lists, with sane caps on how much is read. */
export function hostInfoURLs(payload) {
  if (payload.length > 64 * 1024) return [];
  let obj;
  try { obj = JSON.parse(textDecoder.decode(payload)); } catch { return []; }
  if (!obj || !Array.isArray(obj.displays)) return [];
  const out = [];
  for (const d of obj.displays.slice(0, 8)) {
    if (!d || !Array.isArray(d.urls)) continue;
    for (const u of d.urls.slice(0, 32)) if (typeof u === 'string') out.push(u);
  }
  return out;
}

/**
 * One connection attempt as a state machine (PROTOCOL.md "Client rules", and
 * rules 1 to 16 of the client brief). It has no socket, no clock and no
 * storage: the caller feeds it events and does what `emit` is called with.
 *
 * Events: opened(), socketClosed(), timerFired(name), answered(yes),
 * received(type, payload), send(message). All but send() join one queue, so
 * the asynchronous crypto cannot reorder them. send() takes its counter
 * synchronously (see Sealer).
 *
 * Actions (plain objects with `do`): send {data}, startTimer {timer, seconds},
 * cancelTimer {timer}, state {state}, deliver {type, payload}, change {change},
 * hostCapabilities {bits}, close {reason}, end {end, reason}. State objects
 * hold values only: never a key, a signature or message contents.
 *
 * Without WebCrypto (plain http://) there is no device key: a challenge that
 * says approval is required ends at once with HTTPS_NEEDED_TEXT; any other
 * challenge, or none within the wait, gives a clear HELLO and a session shown
 * as "Not verified", with every host capability 0 and no question asked.
 */
export class AuthFlow {
  constructor(config) {
    this.config = config;
    this.cr = getCrypto(config.cr);
    this.webCrypto = hasWebCrypto(this.cr) && !!config.deviceKey;
    this.known = config.known || new KnownHosts();
    this.carry = config.carry || newCarry();
    this.caps = config.caps === undefined ? WEB_CAPS : config.caps;
    this.address = normalizeAddress(config.dialledURL);
    this.standing = this.address ? this.known.standing(this.address) : { kind: 'unknown' };
    this.phase = 'idle';
    this.handshake = null;
    this.waitingShown = false;
    this.bound = false;
    this.sealer = null;
    this.opener = null;
    this.capsPublished = false;
    this.helloOnTimeout = false;
    this.deviceFingerprint = '';
    this.queue = Promise.resolve();
    this.emitFn = config.emit || (() => {});
  }

  get deviceName() {
    const cleaned = cleanName(this.config.deviceName || '');
    return cleaned || 'Browser';
  }

  get isSecure() { return this.phase === 'secure'; }
  get isEnded() { return this.phase === 'ended'; }

  #emit(action) { this.emitFn(action); }
  #state(state) { this.#emit({ do: 'state', state }); }

  /** Resolves when every queued event and every sealed message has been handled. */
  async settled() {
    let q;
    do { q = this.queue; await q; if (this.sealer) await this.sealer.settled(); } while (q !== this.queue);
  }

  #enqueue(fn) {
    this.queue = this.queue.then(fn).catch((e) => {
      // A bug or an unexpected throw must end the connection, not hang it.
      this.#fail(`internal error: ${e && e.code ? e.code : 'unexpected'}`);
    });
    return this.queue;
  }

  // ── Events ────────────────────────────────────────────────────────────
  /** The socket opened. Nothing is sent: the host speaks first. */
  opened() {
    return this.#enqueue(async () => {
      if (this.phase !== 'idle') return;
      if (!this.address) return this.#fail('the address cannot be used');
      if (this.webCrypto) this.deviceFingerprint = await fingerprintOfKey(this.config.deviceKey.publicRaw, this.cr);
      this.phase = 'awaitingChallenge';
      this.#state({ kind: 'connecting' });
      this.#emit({ do: 'startTimer', timer: 'challenge', seconds: this.carry.challengeWait });
    });
  }

  /** The socket closed or failed from the other side or the network. */
  socketClosed() {
    return this.#enqueue(async () => {
      if (this.phase === 'ended' || this.phase === 'askingHost') return;
      this.#finish({ kind: 'failure' }, 'the connection closed', null);
    });
  }

  timerFired(timer) {
    return this.#enqueue(async () => {
      if (timer === 'challenge' && this.phase === 'awaitingChallenge') return this.#challengeTimedOut();
      if (timer === 'result' && this.phase === 'awaitingResult') return this.#fail('the host did not answer');
      if (timer === 'pending' && this.phase === 'pending') {
        this.#finish({ kind: 'reconnect', after: 0, carry: this.carry }, 'no result for 60 s', { kind: 'connecting' });
      }
    });
  }

  /** The user answered the question the state asks (`askUnverified` or `confirmHost`). */
  answered(yes) {
    return this.#enqueue(async () => {
      if (this.phase === 'askingUnverified') {
        if (!yes || !this.address) return this.#finish({ kind: 'stop' }, 'user declined', null);
        this.phase = 'clearSession';
        this.helloOnTimeout = true;
        this.#emit({ do: 'change', change: { kind: 'allowUnverified', address: this.address } });
        this.#emit({ do: 'send', data: this.config.makeHello() });
        this.#emit({ do: 'hostCapabilities', bits: 0 });
        this.#state({ kind: 'connected', verified: false, hostName: '' });
      } else if (this.phase === 'askingHost') {
        const h = this.handshake;
        if (!yes || !h || !this.address) return this.#finish({ kind: 'stop' }, 'user declined', null);
        this.phase = 'ended';
        this.#emit({ do: 'change', change: { kind: 'recordVerified', key: h.hostIdentityKey, id: h.hostId,
          name: h.hostName, address: this.config.dialledURL } });
        this.#emit({ do: 'end', end: { kind: 'reconnect', after: 0, carry: newCarry() },
          reason: 'host confirmed by the user' });
      }
    });
  }

  /** One message from the host: its type byte and payload. */
  received(type, payload) {
    return this.#enqueue(async () => {
      switch (this.phase) {
        case 'idle': case 'ended': case 'askingHost':
          return;
        case 'awaitingChallenge': case 'askingUnverified':
          if (type !== MSG.AUTH_CHALLENGE) return this.#fail('message before the challenge');
          return this.#handleChallenge(payload);
        case 'clearSession':
          if (type === MSG.AUTH_CHALLENGE) {
            if (!this.helloOnTimeout) return this.#fail('unexpected message in a clear session');
            // A host that does speak auth, only slower than we waited.
            const next = { ...this.carry, challengeWait: FLOW.lateChallengeWait };
            return this.#finish({ kind: 'reconnect', after: 0, carry: next }, 'challenge after a clear HELLO',
              { kind: 'connecting' });
          }
          if (type === MSG.AUTH_RESULT || type === MSG.SECURE || type === MSG.AUTH_RESPONSE) {
            return this.#fail('unexpected message in a clear session');
          }
          return this.#emit({ do: 'deliver', type, payload });
        case 'awaitingResult': case 'pending':
          if (type !== MSG.AUTH_RESULT) return this.#fail('message before the result');
          return this.#handleResult(payload);
        case 'secure':
          if (type !== MSG.SECURE) return this.#fail('clear message after accepted');
          return this.#handleSecure(payload);
        default:
      }
    });
  }

  /**
   * The app wants to send one whole framed message. Before `accepted` is
   * verified nothing goes out: it is dropped, never queued. In a clear
   * session it goes as it is. In a secure session it is sealed here, in call
   * order, and written from the sealer's chain in the same order.
   */
  send(message) {
    if (this.phase === 'clearSession') { this.#emit({ do: 'send', data: message }); return; }
    if (this.phase !== 'secure' || !this.sealer) return;
    try { this.sealer.seal(message); } catch (e) {
      this.#enqueue(async () => this.#fail('could not seal a message'));
    }
  }

  // ── Challenge ─────────────────────────────────────────────────────────
  #challengeTimedOut() {
    if (this.standing.kind === 'host') {
      const name = this.known.host(this.standing.id)?.name || '';
      return this.#finish({ kind: 'stop' }, 'a saved host did not identify itself', { kind: 'didNotIdentify', hostName: name });
    }
    if (!this.address) return this.#fail('the address cannot be used');
    if (!this.webCrypto) {
      // Nothing to prove anything with, and nobody to ask: the page came over
      // the same unprotected connection.
      this.phase = 'clearSession';
      this.helloOnTimeout = true;
      this.#emit({ do: 'send', data: this.config.makeHello() });
      this.#emit({ do: 'hostCapabilities', bits: 0 });
      this.#state({ kind: 'connected', verified: false, hostName: '' });
      return;
    }
    if (this.standing.kind === 'unknownAllowed') {
      this.phase = 'clearSession';
      this.helloOnTimeout = true;
      this.#emit({ do: 'send', data: this.config.makeHello() });
      this.#emit({ do: 'hostCapabilities', bits: 0 });
      this.#state({ kind: 'connected', verified: false, hostName: '' });
      return;
    }
    this.phase = 'askingUnverified';
    this.#state({ kind: 'askUnverified', address: this.address });
  }

  async #handleChallenge(payload) {
    let challenge;
    try { challenge = parseChallenge(payload); } catch { return this.#fail('the challenge is not valid'); }
    if (!this.webCrypto) return this.#challengeWithoutCrypto(challenge);
    if (!(await isValidPublicKey(challenge.identity, this.cr))) return this.#fail('the challenge is not valid');
    const id = await keyId(challenge.identity, this.cr);
    if (this.phase === 'ended') return;
    // Rule 4, unless the key that answered is another saved Mac's: that one passes
    // its own pin, and the result step decides what to do (the address moves, and
    // the attempt ends so a caller with more addresses can try the next).
    if (this.standing.kind === 'host' && this.standing.id !== id && this.known.host(id) === null) {
      return this.#finish({ kind: 'stop' }, 'identity changed', {
        kind: 'changedIdentity', address: this.address || '',
        savedFingerprint: fingerprintOfId(this.standing.id), nowFingerprint: fingerprintOfId(id),
      });
    }
    let h;
    try {
      h = await ClientHandshake.create({
        challengePayload: payload, deviceKey: this.config.deviceKey.publicRaw, caps: this.caps,
        name: this.deviceName, sign: this.config.deviceKey.sign, extensions: this.config.extensions || [],
        ephemeral: this.config.ephemeral, nonce: this.config.nonce, cr: this.cr,
      });
    } catch { return this.#fail('could not answer the challenge'); }
    if (this.phase === 'ended') return;
    this.handshake = h;
    this.phase = 'awaitingResult';
    this.#emit({ do: 'cancelTimer', timer: 'challenge' });
    this.#emit({ do: 'send', data: frame(MSG.AUTH_RESPONSE, h.response) });
    this.#emit({ do: 'startTimer', timer: 'result', seconds: FLOW.resultWait });
    this.#state({ kind: 'connecting' });
  }

  #challengeWithoutCrypto(challenge) {
    // Bit 0 is read from a message nobody has verified: it only chooses which
    // message to show, and never unlocks anything.
    if ((challenge.caps & 1) !== 0) {
      return this.#finish({ kind: 'stop' }, 'approval is required and this page has no WebCrypto',
        { kind: 'needsHttps', text: HTTPS_NEEDED_TEXT });
    }
    if (this.standing.kind === 'host') {
      const name = this.known.host(this.standing.id)?.name || '';
      return this.#finish({ kind: 'stop' }, 'a saved host cannot be checked here', { kind: 'didNotIdentify', hostName: name });
    }
    this.phase = 'clearSession';
    this.helloOnTimeout = false;
    this.#emit({ do: 'cancelTimer', timer: 'challenge' });
    this.#emit({ do: 'send', data: this.config.makeHello() });
    this.#emit({ do: 'hostCapabilities', bits: 0 });
    this.#state({ kind: 'connected', verified: false, hostName: '' });
  }

  // ── Result ────────────────────────────────────────────────────────────
  async #handleResult(payload) {
    const h = this.handshake;
    let status;
    try { status = await h.statusOfResult(payload); } catch { return this.#fail('a result did not verify'); }
    if (this.phase === 'ended') return;
    this.#emit({ do: 'cancelTimer', timer: 'result' });
    this.#emit({ do: 'cancelTimer', timer: 'pending' });
    const hostKnown = this.known.host(h.hostId) !== null;
    // A verified result proves the host holds the key in the challenge.
    if (hostKnown && !this.bound && this.address) {
      this.bound = true;
      if (!(this.standing.kind === 'host' && this.standing.id === h.hostId)) {
        // The dialled URL, not the bare address: a tunnel's display path is
        // kept with the address so a later fallback reaches the same display.
        this.#emit({ do: 'change', change: { kind: 'bind', hostId: h.hostId, address: this.config.dialledURL } });
      }
    }
    const name = h.hostName;
    // A different saved Mac answered at an address that was another saved Mac's.
    // It passes its own pin, so it is not a success for the one picked: the
    // address has moved (the change above) and this attempt ends.
    const picked = this.config.expectedHostId || (this.standing.kind === 'host' ? this.standing.id : null);
    if (hostKnown && picked && picked !== h.hostId && this.known.host(picked) !== null) {
      const now = this.known.host(h.hostId)?.name || name;
      return this.#finish({ kind: 'nextAddress' }, 'the address reached a different saved Mac',
        { kind: 'failed', reason: `This address now reaches ${now}` });
    }
    switch (status) {
      case STATUS.pending:
        this.phase = 'pending';
        this.waitingShown = true;
        this.#emit({ do: 'startTimer', timer: 'pending', seconds: FLOW.pendingWait });
        this.#state({ kind: 'waiting', hostName: name, hostFingerprint: h.hostFingerprint,
          deviceName: this.deviceName, deviceFingerprint: this.deviceFingerprint });
        return;
      case STATUS.accepted:
        if (this.waitingShown || hostKnown) {
          if (!this.address) return this.#fail('the address cannot be used');
          this.#emit({ do: 'change', change: { kind: 'recordVerified', key: h.hostIdentityKey, id: h.hostId,
            name, address: this.config.dialledURL } });
          return this.#startSession(h);
        }
        // Rule 12: let in without being asked, by a host not met before.
        this.phase = 'askingHost';
        this.#emit({ do: 'close', reason: 'a host not met before let this device in; asking the user' });
        this.#state({ kind: 'confirmHost', hostName: name, fingerprint: h.hostFingerprint });
        return;
      case STATUS.denied:
        return this.#finish({ kind: 'stop' }, 'denied', { kind: 'denied', hostName: name });
      case STATUS.invalid:
        return this.#finish({ kind: 'stop' }, 'invalid', { kind: 'invalid', hostName: name });
      case STATUS.busy:
        return this.#retry(true);
      default: // timeout
        if (!this.carry.timeoutRetried) {
          return this.#finish({ kind: 'reconnect', after: 0, carry: { ...this.carry, timeoutRetried: true } },
            'timeout', { kind: 'connecting' });
        }
        return this.#retry(false);
    }
  }

  #retry(afterBusy) {
    const delay = this.carry.busyDelay;
    const next = { ...this.carry, busyDelay: Math.min(delay * 2, FLOW.busyMaxDelay) };
    this.#finish({ kind: 'reconnect', after: delay, carry: next }, afterBusy ? 'busy' : 'timeout again',
      { kind: 'busy', retryIn: delay });
  }

  // ── Session ───────────────────────────────────────────────────────────
  async #startSession(h) {
    try {
      const m = await h.sessionMaterial();
      const sealKey = await importSessionKey(m.clientToHost, this.cr);
      const openKey = await importSessionKey(m.hostToClient, this.cr);
      if (this.phase === 'ended') return;
      this.opener = new Opener(openKey, { cr: this.cr });
      this.sealer = new Sealer(sealKey, (data) => {
        if (this.phase !== 'ended') this.#emit({ do: 'send', data });
      }, { cr: this.cr, onError: () => this.#enqueue(async () => this.#fail('could not seal a message')) });
      this.phase = 'secure';
      this.capsPublished = true;
      this.#emit({ do: 'hostCapabilities', bits: h.hostCapabilities });
      this.#state({ kind: 'connected', verified: true, hostName: h.hostName });
      this.sealer.seal(this.config.makeHello());
      this.sealer.seal(frame(MSG.CLIENT_INFO, this.#clientInfo()));
    } catch { this.#fail('could not start the encrypted session'); }
  }

  #clientInfo() {
    const obj = { app: 'web' };
    const url = cleanURL(this.config.dialledURL);
    if (url) obj.url = url;
    obj.version = this.config.appVersion || WEB_CLIENT_VERSION;
    return bytes(JSON.stringify(obj));
  }

  async #handleSecure(payload) {
    let inner;
    try { inner = await this.opener.open(payload); } catch { return this.#fail('a SECURE message did not open'); }
    if (this.phase === 'ended') return;
    if (inner.type === MSG.HOST_INFO) {
      const urls = hostInfoURLs(inner.payload);
      if (urls.length) this.#emit({ do: 'change', change: { kind: 'hints', hostId: this.handshake.hostId, urls } });
      return;
    }
    this.#emit({ do: 'deliver', type: inner.type, payload: inner.payload });
  }

  // ── Ending ────────────────────────────────────────────────────────────
  #fail(reason) {
    this.#finish({ kind: 'failure' }, reason, { kind: 'failed', reason });
  }

  #finish(end, reason, shown) {
    if (this.phase === 'ended') return;
    this.phase = 'ended';
    for (const timer of ['challenge', 'result', 'pending']) this.#emit({ do: 'cancelTimer', timer });
    if (this.capsPublished) {
      this.capsPublished = false;
      this.#emit({ do: 'hostCapabilities', bits: 0 });
    }
    if (shown) this.#state(shown);
    this.#emit({ do: 'end', end, reason });
  }
}
