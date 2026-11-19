// Tests for Sources/Clamshell/Resources/webclient/auth.js against the reference
// vectors in tests/vectors/auth-v1.json (the same file the Swift tests use).
// Run: node tests/test-webclient-auth.js   (Node 20 or later)
import { test } from 'node:test';
import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import * as A from '../Sources/Clamshell/Resources/webclient/auth.js';
import { signingKeyFrom, b64u } from './auth-test-host.js';

const V = JSON.parse(readFileSync(new URL('./vectors/auth-v1.json', import.meta.url), 'utf8'));
const cr = globalThis.crypto;
const hex = (s) => A.fromHex(s);
const h = A.toHex;

async function vectorHandshake(signFn) {
  const ephemeral = await A.importEphemeral(hex(V.clientEphemeral.private), hex(V.clientEphemeral.public), cr);
  const sign = signFn || await signingKeyFrom(hex(V.deviceKey.private), hex(V.deviceKey.public));
  return A.ClientHandshake.create({
    challengePayload: hex(V.challenge), deviceKey: hex(V.deviceKey.public), caps: V.clientCaps,
    name: V.deviceName, sign, extensions: [{ type: V.responseExtension.type, value: hex(V.responseExtension.value) }],
    ephemeral, nonce: hex(V.clientNonce), cr,
  });
}

// ── Ids and fingerprints ───────────────────────────────────────────────
test('ids and fingerprints equal the vector', async () => {
  assert.strictEqual(await A.keyId(hex(V.hostIdentity.public), cr), V.hostId);
  assert.strictEqual(await A.keyId(hex(V.deviceKey.public), cr), V.deviceId);
  assert.strictEqual(A.fingerprintOfId(V.hostId), V.hostFingerprint);
  assert.strictEqual(await A.fingerprintOfKey(hex(V.deviceKey.public), cr), V.deviceFingerprint);
});

test('public key validity: curve point, length and first byte', async () => {
  assert.strictEqual(await A.isValidPublicKey(hex(V.hostIdentity.public), cr), true);
  const off = hex(V.hostIdentity.public); off[64] ^= 1;
  assert.strictEqual(await A.isValidPublicKey(off, cr), false);
  assert.strictEqual(await A.isValidPublicKey(hex(V.hostIdentity.public).subarray(0, 64), cr), false);
  const compressedTag = hex(V.hostIdentity.public); compressedTag[0] = 2;
  assert.strictEqual(await A.isValidPublicKey(compressedTag, cr), false);
  assert.strictEqual(await A.isValidPublicKey(new Uint8Array(65), cr), false);
});

// ── Parsing ────────────────────────────────────────────────────────────
test('the challenge parses to the vector fields', () => {
  const c = A.parseChallenge(hex(V.challenge));
  assert.strictEqual(c.caps, V.hostCaps);
  assert.strictEqual(c.displayName, V.hostName);
  assert.strictEqual(h(c.nonce), V.hostNonce);
  assert.strictEqual(h(c.ephemeral), V.hostEphemeral.public);
  assert.strictEqual(h(c.identity), V.hostIdentity.public);
});

test('a challenge of another version, a short one and a long one are refused', () => {
  const good = hex(V.challenge);
  const v2 = good.slice(); v2[0] = 2;
  assert.throws(() => A.parseChallenge(v2), { code: 'unsupportedVersion' });
  assert.throws(() => A.parseChallenge(good.subarray(0, good.length - 1)), { code: 'malformed' });
  assert.throws(() => A.parseChallenge(A.concat(good, Uint8Array.of(0))), { code: 'malformed' });
  assert.throws(() => A.parseChallenge(new Uint8Array(0)), { code: 'malformed' });
});

test('an extension block that runs past its end is malformed', () => {
  assert.throws(() => A.decodeExtensions(Uint8Array.of(1, 0, 5, 9)), { code: 'malformed' });
  assert.deepStrictEqual(A.decodeExtensions(Uint8Array.of(127, 0, 1, 9)).map((e) => e.type), [127]);
});

// ── The response ───────────────────────────────────────────────────────
test('the response body and signature input equal the vector; its signature verifies', async () => {
  const hs = await vectorHandshake();
  const body = hs.response.subarray(0, hs.response.length - 64);
  assert.strictEqual(h(body), V.responseBody);
  assert.strictEqual(h(A.clientSignatureInput(hex(V.challenge), body)), V.clientSignatureInput);
  const sig = hs.response.subarray(hs.response.length - 64);
  // WebCrypto signatures are randomized: verify, do not compare bytes.
  assert.strictEqual(await A.verifySignature(sig, hex(V.clientSignatureInput), hex(V.deviceKey.public), cr), true);
  assert.strictEqual(hs.response.length, hex(V.response).length);
});

test('the vector’s own client signature verifies', async () => {
  assert.strictEqual(await A.verifySignature(hex(V.clientSignature), hex(V.clientSignatureInput),
    hex(V.deviceKey.public), cr), true);
  const bad = hex(V.clientSignature); bad[10] ^= 1;
  assert.strictEqual(await A.verifySignature(bad, hex(V.clientSignatureInput), hex(V.deviceKey.public), cr), false);
});

test('a signer that returns the wrong length fails the handshake', async () => {
  await assert.rejects(vectorHandshake(async () => new Uint8Array(63)), { code: 'badSignature' });
});

test('a challenge with an off-curve key fails the handshake', async () => {
  const c = hex(V.challenge);
  c[1 + 4 + 32 + 65 + 64] ^= 1; // last byte of the identity key
  const ephemeral = await A.importEphemeral(hex(V.clientEphemeral.private), hex(V.clientEphemeral.public), cr);
  await assert.rejects(A.ClientHandshake.create({
    challengePayload: c, deviceKey: hex(V.deviceKey.public), caps: 10, name: 'x',
    sign: async () => new Uint8Array(64), ephemeral, nonce: hex(V.clientNonce), cr,
  }), { code: 'invalidKey' });
});

// ── Results ────────────────────────────────────────────────────────────
// The host's results and the session keys cover the response exactly as sent,
// signature included. A real signature is random, so these tests hand the
// handshake the vector's own signature and check the response then equals the
// vector's byte for byte.
const recordedSignature = async () => hex(V.clientSignature);

test('with the recorded signature the whole response equals the vector', async () => {
  const hs = await vectorHandshake(recordedSignature);
  assert.strictEqual(h(hs.response), V.response);
});

test('results: the three vector results verify with their status', async () => {
  const hs = await vectorHandshake(recordedSignature);
  for (const [name, status] of [['accepted', 0], ['pending', 1], ['busy', 4]]) {
    const r = V.results[name];
    assert.strictEqual(await hs.statusOfResult(hex(r.payload)), status, name);
    assert.strictEqual(h(A.hostSignatureInput(hex(V.challenge),
      status === 4 ? new Uint8Array(0) : hex(V.response), hex(r.body))), r.signatureInput, name);
  }
});

test('results: a changed byte, a swapped status and a short payload are refused', async () => {
  const hs = await vectorHandshake(recordedSignature);
  const pending = hex(V.results.pending.payload);
  const flipped = pending.slice(); flipped[20] ^= 1;
  await assert.rejects(hs.statusOfResult(flipped));
  // The signature of "pending" does not carry over to "accepted".
  const swapped = pending.slice(); swapped[0] = 0;
  await assert.rejects(hs.statusOfResult(swapped), { code: 'badSignature' });
  await assert.rejects(hs.statusOfResult(pending.subarray(0, 30)), { code: 'malformed' });
  const unknownStatus = pending.slice(); unknownStatus[0] = 9;
  await assert.rejects(hs.statusOfResult(unknownStatus), { code: 'malformed' });
});

// ── Session keys ───────────────────────────────────────────────────────
test('the derived keys and the transcript hash equal the vector', async () => {
  const hs = await vectorHandshake(recordedSignature);
  const m = await hs.sessionMaterial();
  assert.strictEqual(h(m.transcriptHash), V.transcriptHash);
  assert.strictEqual(h(m.hostToClient), V.keyHostToClient);
  assert.strictEqual(h(m.clientToHost), V.keyClientToHost);
});

// ── SECURE ─────────────────────────────────────────────────────────────
test('sealed samples match the vector byte for byte, and the host’s open', async () => {
  const c2hKey = await A.importSessionKey(hex(V.keyClientToHost), cr);
  const h2cKey = await A.importSessionKey(hex(V.keyHostToClient), cr);
  const written = [];
  const sealer = new A.Sealer(c2hKey, (d) => written.push(d), { cr });
  const opener = new A.Opener(h2cKey, { cr });
  for (const s of V.secure) {
    assert.strictEqual(h(A.secureNonce(s.counter)), s.nonce);
    if (s.direction === 'clientToHost') sealer.seal(hex(s.inner));
    else {
      const o = await opener.open(hex(s.frame).subarray(5));
      assert.strictEqual(h(A.concat(Uint8Array.of(o.type), A.u32(o.payload.length), o.payload)), s.inner);
    }
  }
  await sealer.settled();
  assert.deepStrictEqual(written.map(h), V.secure.filter((s) => s.direction === 'clientToHost').map((s) => s.frame));
});

async function pair() {
  const key = await A.importSessionKey(hex(V.keyClientToHost), cr);
  const written = [];
  const errors = [];
  return {
    written, errors,
    sealer: new A.Sealer(key, (d) => written.push(d), { cr, onError: (e) => errors.push(e) }),
    opener: () => new A.Opener(key, { cr }),
  };
}

test('sealing and opening: a round trip works', async () => {
  const p = await pair();
  const inner = A.frame(0x22, Uint8Array.of(0, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0));
  p.sealer.seal(inner);
  await p.sealer.settled();
  const o = await p.opener().open(p.written[0].subarray(5));
  assert.strictEqual(o.type, 0x22);
  assert.strictEqual(h(o.payload), h(inner.subarray(5)));
});

test('a changed byte is refused', async () => {
  const p = await pair();
  p.sealer.seal(A.frame(0x07));
  await p.sealer.settled();
  const bad = p.written[0].subarray(5).slice(); bad[2] ^= 1;
  await assert.rejects(p.opener().open(bad), { code: 'decryptFailed' });
  await assert.rejects(p.opener().open(new Uint8Array(15)), { code: 'decryptFailed' });
});

test('a repeated message and a reordered message are refused', async () => {
  const p = await pair();
  p.sealer.seal(A.frame(0x07));
  p.sealer.seal(A.frame(0x07, Uint8Array.of(1)));
  await p.sealer.settled();
  const [first, second] = p.written.map((m) => m.subarray(5));
  const repeat = p.opener();
  await repeat.open(first);
  await assert.rejects(repeat.open(first), { code: 'decryptFailed' });
  const reorder = p.opener();
  await assert.rejects(reorder.open(second), { code: 'decryptFailed' });
});

test('SECURE and AUTH messages may not go inside SECURE, either way', async () => {
  const p = await pair();
  for (const t of [0x0F, 0x08, 0x09, 0x0A]) {
    assert.throws(() => p.sealer.seal(A.frame(t)), { code: 'forbiddenInnerMessage' });
  }
  assert.throws(() => p.sealer.seal(new Uint8Array(4)), { code: 'forbiddenInnerMessage' });
  assert.throws(() => p.sealer.seal(Uint8Array.of(7, 0, 0, 0, 3)), { code: 'forbiddenInnerMessage' });
  assert.strictEqual(p.sealer.counter, 0, 'a refused message uses no counter');
});

test('200 messages queued in one synchronous burst arrive in counter order', async () => {
  const p = await pair();
  for (let i = 0; i < 200; i++) p.sealer.seal(A.frame(0x22, Uint8Array.of(i, i >> 8, ...new Uint8Array(i % 7))));
  assert.strictEqual(p.sealer.counter, 200);
  await p.sealer.settled();
  assert.strictEqual(p.written.length, 200);
  const o = p.opener();
  for (let i = 0; i < 200; i++) {
    const m = await o.open(p.written[i].subarray(5));
    assert.strictEqual(m.payload[0], i & 0xFF, `message ${i}`);
  }
});

test('a failed seal stops the chain and reports once', async () => {
  const key = await cr.subtle.importKey('raw', new Uint8Array(32), 'AES-GCM', false, ['decrypt']); // cannot encrypt
  const written = []; const errors = [];
  const s = new A.Sealer(key, (d) => written.push(d), { cr, onError: (e) => errors.push(e) });
  s.seal(A.frame(0x07)); s.seal(A.frame(0x07));
  await s.settled();
  assert.strictEqual(written.length, 0);
  assert.strictEqual(errors.length, 1);
  assert.throws(() => s.seal(A.frame(0x07)), { code: 'closed' });
});

// ── Names ──────────────────────────────────────────────────────────────
test('cleanName drops control and invisible characters and caps at 64 bytes', () => {
  assert.strictEqual(A.cleanName('  Studio ‮\u0007 '), 'Studio');
  assert.strictEqual(A.cleanName('a​b'), 'ab');
  assert.strictEqual(A.cleanName('\u0000\u0001'), '');
  const long = A.cleanName('é'.repeat(60));
  assert.strictEqual(new TextEncoder().encode(long).length, 64);
  assert.strictEqual(A.cleanName('x'.repeat(100)).length, 64);
  assert.strictEqual(A.cleanName('Mac'), 'Mac');
});

test('webDeviceName is plain ASCII and at most 64 bytes', () => {
  const ua = {
    safariMac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
    chromeWin: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    edge: 'Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/120.0 Safari/537.36 Edg/120.0',
    firefoxLinux: 'Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0',
    ipad: 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  };
  assert.strictEqual(A.webDeviceName(ua.safariMac), 'Safari on Mac');
  assert.strictEqual(A.webDeviceName(ua.chromeWin), 'Chrome on Windows');
  assert.strictEqual(A.webDeviceName(ua.edge), 'Edge on Windows');
  assert.strictEqual(A.webDeviceName(ua.firefoxLinux), 'Firefox on Linux');
  assert.strictEqual(A.webDeviceName(ua.ipad), 'Safari on iPad');
  assert.strictEqual(A.webDeviceName(''), 'Browser');
  assert.strictEqual(A.webDeviceName(undefined), 'Browser');
  for (const u of Object.values(ua)) assert.match(A.webDeviceName(u), /^[\x20-\x7E]{1,64}$/);
});

test('the web client offers only what it does', () => {
  assert.strictEqual(A.WEB_CAPS, 0b1010);
  assert.strictEqual(A.WEB_CAPS & (1 << 2), 0, 'no text input');
  assert.strictEqual(A.WEB_CAPS & ((1 << 4) | (1 << 5) | (1 << 6)), 0);
});

// ── The device key ─────────────────────────────────────────────────────
test('the device key is made once, cannot be exported, and signs', async () => {
  const store = A.memoryStore();
  const a = await A.loadDeviceKey(store, cr);
  const b = await A.loadDeviceKey(store, cr);
  assert.strictEqual(h(a.publicRaw), h(b.publicRaw));
  assert.strictEqual(a.publicRaw.length, 65);
  const record = await store.get(A.DEVICE_KEY_NAME);
  assert.strictEqual(record.privateKey.extractable, false);
  await assert.rejects(cr.subtle.exportKey('pkcs8', record.privateKey));
  await assert.rejects(cr.subtle.exportKey('jwk', record.privateKey));
  const input = A.bytes('hello');
  assert.strictEqual(await A.verifySignature(await a.sign(input), input, a.publicRaw, cr), true);
});

test('a store that cannot be read fails the attempt and makes no key', async () => {
  let writes = 0;
  const store = {
    async get() { throw new Error('locked'); },
    async set() { writes++; }, async add() { writes++; return true; }, async delete() {},
  };
  await assert.rejects(A.loadDeviceKey(store, cr), { code: 'storeUnreadable' });
  assert.strictEqual(writes, 0);
});

test('a record that is not a key pair is an error, not a reason for a new key', async () => {
  let writes = 0;
  const store = {
    async get() { return { junk: true }; },
    async set() { writes++; }, async add() { writes++; return true; }, async delete() {},
  };
  await assert.rejects(A.loadDeviceKey(store, cr), { code: 'storeUnreadable' });
  assert.strictEqual(writes, 0);
});

test('when another tab made the key first, that key is used', async () => {
  const inner = A.memoryStore();
  const first = await A.loadDeviceKey(inner, cr);
  let reads = 0;
  const racing = {
    async get(k) { reads++; return reads === 1 ? undefined : inner.get(k); },
    set: (k, v) => inner.set(k, v), add: (k, v) => inner.add(k, v), delete: (k) => inner.delete(k),
  };
  const second = await A.loadDeviceKey(racing, cr);
  assert.strictEqual(h(first.publicRaw), h(second.publicRaw));
});

// ── Addresses ──────────────────────────────────────────────────────────
test('normalizeAddress: bare hosts, ws and wss, ports and paths', () => {
  assert.strictEqual(A.normalizeAddress('192.0.2.5'), '192.0.2.5:5903');
  assert.strictEqual(A.normalizeAddress('Host.Example.com:1234'), 'host.example.com:1234');
  assert.strictEqual(A.normalizeAddress('192.0.2.5:80'), '192.0.2.5:80');
  assert.strictEqual(A.normalizeAddress('ws://Example.com'), 'example.com:80');
  assert.strictEqual(A.normalizeAddress('wss://example.com/ws/a'), 'example.com:443');
  assert.strictEqual(A.normalizeAddress('wss://example.com/ws/b?x=1#y'), 'example.com:443');
  assert.strictEqual(A.normalizeAddress('wss://u:p@example.com:8443'), 'example.com:8443');
  assert.strictEqual(A.normalizeAddress('ws://[2001:db8::1]:5903'), '[2001:db8::1]:5903');
  assert.strictEqual(A.normalizeAddress('http://example.com'), null);
  assert.strictEqual(A.normalizeAddress(''), null);
  assert.strictEqual(A.normalizeAddress('ws://example.com:0'), null);
});

test('normalizeAddress drops an IPv6 zone id, as the Swift and C# code do', () => {
  assert.strictEqual(A.normalizeAddress('ws://[fe80::1%en0]:5903'), '[fe80::1]:5903');
  assert.strictEqual(A.normalizeAddress('ws://[fe80::1%25en0]:5903'), '[fe80::1]:5903');
  assert.strictEqual(A.normalizeAddress('wss://[2001:db8::1%eth0]/ws/a'), '[2001:db8::1]:443');
  assert.strictEqual(A.normalizeAddress('[fe80::1%en0]'), '[fe80::1]:5903');
  // The same Mac with and without a zone is one address.
  assert.strictEqual(A.normalizeAddress('ws://[fe80::1%en0]:5903'), A.normalizeAddress('ws://[fe80::1]:5903'));
  // Nothing else changes: a percent sign elsewhere is still not an address.
  assert.strictEqual(A.normalizeAddress('ws://[%en0]:5903'), null);
});

test('hintAddress keeps the spec’s limits', () => {
  assert.strictEqual(A.hintAddress('wss://mac.example.com/ws/a'), 'mac.example.com:443');
  assert.strictEqual(A.hintAddress('ws://192.0.2.7:5903'), '192.0.2.7:5903');
  assert.strictEqual(A.hintAddress('https://mac.example.com'), null);
  assert.strictEqual(A.hintAddress('mac.example.com'), null);
  assert.strictEqual(A.hintAddress('wss://u@mac.example.com'), null);
  assert.strictEqual(A.hintAddress('wss://mac.example.com/?a=1'), null);
  assert.strictEqual(A.hintAddress('wss://mac.example.com/#a'), null);
  assert.strictEqual(A.hintAddress(`wss://mac.example.com/${'a'.repeat(300)}`), null);
});

// ── Known hosts ────────────────────────────────────────────────────────
const KEY_A = hex(V.hostIdentity.public);
const KEY_B = hex(V.deviceKey.public);
const ID_A = V.hostId;
const ID_B = V.deviceId;

test('known hosts: recording binds an address and clears the unverified mark', () => {
  const k = new A.KnownHosts();
  k.allowUnverified('ws://192.0.2.5:5903');
  assert.strictEqual(k.standing('192.0.2.5:5903').kind, 'unknownAllowed');
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Studio', address: 'ws://192.0.2.5:5903' }, 10);
  assert.deepStrictEqual(k.standing('192.0.2.5:5903'), { kind: 'host', id: ID_A });
  assert.deepStrictEqual(k.unverifiedAllowed, []);
  assert.strictEqual(k.standing('192.0.2.9:5903').kind, 'unknown');
  assert.strictEqual(k.isVerified('192.0.2.5:5903', ID_A), true);
});

test('known hosts: /ws/a and /ws/b on one hostname are one address', () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Studio', address: 'wss://mac.example.com/ws/a' }, 1);
  assert.deepStrictEqual(k.standing('wss://mac.example.com/ws/b'), { kind: 'host', id: ID_A });
});

test('known hosts: an address moves to the host that is verified there now', () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'A', address: '192.0.2.5:5903' }, 1);
  k.recordVerified({ key: KEY_B, id: ID_B, name: 'B', address: '192.0.2.5:5903' }, 2);
  assert.deepStrictEqual(k.standing('192.0.2.5:5903'), { kind: 'host', id: ID_B });
  assert.strictEqual(k.host(ID_A).addresses.length, 0);
});

test('known hosts: bind needs a known host', () => {
  const k = new A.KnownHosts();
  k.bind('192.0.2.5:5903', ID_A, 1);
  assert.strictEqual(k.hosts.length, 0);
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'A', address: '192.0.2.1:5903' }, 1);
  k.bind('192.0.2.2:5903', ID_A, 2);
  assert.deepStrictEqual(k.standing('192.0.2.2:5903'), { kind: 'host', id: ID_A });
});

test('known hosts: hints obey the limits and cannot take another host’s address', () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'A', address: '192.0.2.1:5903' }, 1);
  k.recordVerified({ key: KEY_B, id: ID_B, name: 'B', address: '192.0.2.2:5903' }, 1);
  k.addHints(['wss://mac.example.com/ws/a', 'ws://192.0.2.2:5903', 'https://nope.example.com',
    'wss://u@nope.example.com', `wss://x.example.com/${'a'.repeat(300)}`], ID_A, 2);
  assert.deepStrictEqual(k.host(ID_A).addresses.map((a) => a.address), ['192.0.2.1:5903', 'mac.example.com:443']);
  assert.strictEqual(k.host(ID_A).addresses[1].verified, false);
  assert.deepStrictEqual(k.standing('192.0.2.2:5903'), { kind: 'host', id: ID_B });
});

test('known hosts: at most 16 addresses per host; hints go first, the one unused longest', () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'A', address: '192.0.2.1:5903' }, 1000);
  const urls = [];
  for (let i = 1; i <= 20; i++) urls.push(`ws://192.0.2.${100 + i}:5903`);
  k.addHints(urls, ID_A, 5);
  const list = k.host(ID_A).addresses;
  assert.strictEqual(list.length, 16);
  assert.ok(list.some((a) => a.address === '192.0.2.1:5903'), 'the verified address stays');
  assert.ok(!list.some((a) => a.address === '192.0.2.101:5903'), 'the oldest hint went');
});

test('known hosts: at most 64 unverified-allowed addresses, oldest dropped', () => {
  const k = new A.KnownHosts();
  for (let i = 0; i < 70; i++) k.allowUnverified(`ws://198.51.100.${i}:5903`);
  assert.strictEqual(k.unverifiedAllowed.length, 64);
  assert.strictEqual(k.standing('198.51.100.0:5903').kind, 'unknown');
  assert.strictEqual(k.standing('198.51.100.69:5903').kind, 'unknownAllowed');
});

test('known hosts: forgetting removes the key and every address', () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'A', address: '192.0.2.1:5903' }, 1);
  k.addHints(['ws://192.0.2.9:5903'], ID_A, 2);
  k.forget(ID_A);
  assert.strictEqual(k.hosts.length, 0);
  assert.strictEqual(k.standing('192.0.2.1:5903').kind, 'unknown');
  assert.strictEqual(k.standing('192.0.2.9:5903').kind, 'unknown');
});

test('known hosts: dial order is last success, then verified, then hints', () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'A', address: '192.0.2.1:5903' }, 1);
  k.addHints(['ws://192.0.2.9:5903'], ID_A, 50);
  k.bind('192.0.2.2:5903', ID_A, 9);
  assert.deepStrictEqual(k.dialOrder(ID_A), ['192.0.2.2:5903', '192.0.2.1:5903', '192.0.2.9:5903']);
});

test('known hosts: encode and decode keep everything', async () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Studio', address: 'wss://mac.example.com/ws/a' }, 3);
  k.addHints(['ws://192.0.2.9:5903'], ID_A, 4);
  k.allowUnverified('ws://192.0.2.77:5903');
  const { known, damaged } = await A.KnownHosts.decode(k.encode(), cr);
  assert.strictEqual(damaged, false);
  assert.deepStrictEqual(known.hosts, k.hosts);
  assert.deepStrictEqual(known.unverifiedAllowed, k.unverifiedAllowed);
});

test('known hosts: nothing stored is an empty store, not damage', async () => {
  const r = await A.KnownHosts.decode(undefined, cr);
  assert.strictEqual(r.damaged, false);
  assert.strictEqual(r.known.hosts.length, 0);
});

test('known hosts: a damaged store is empty and says so; readable entries are kept', async () => {
  for (const bad of ['not json', '{"version":1}', '[]', '5']) {
    const r = await A.KnownHosts.decode(bad, cr);
    assert.strictEqual(r.damaged, true, bad);
    assert.strictEqual(r.known.hosts.length, 0);
  }
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Studio', address: '192.0.2.1:5903' }, 1);
  const stored = JSON.parse(k.encode());
  stored.hosts.push({ key: 'zz', name: 'junk', addresses: [] });
  stored.hosts.push({ key: A.toHex(new Uint8Array(65)), name: 'off curve', addresses: [] });
  stored.hosts.push(7);
  stored.hosts[0].addresses.push({ address: 'ws://not-normalized', verified: true, lastUsed: 1 });
  stored.unverifiedAllowed = ['198.51.100.1:5903', 5];
  const r = await A.KnownHosts.decode(JSON.stringify(stored), cr);
  assert.strictEqual(r.damaged, true);
  assert.deepStrictEqual(r.known.hosts.map((x) => x.id), [ID_A]);
  assert.deepStrictEqual(r.known.host(ID_A).addresses.map((x) => x.address), ['192.0.2.1:5903']);
  assert.deepStrictEqual(r.known.unverifiedAllowed, ['198.51.100.1:5903']);
});

test('known hosts: the id comes from the key, not from the stored text', async () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Studio', address: '192.0.2.1:5903' }, 1);
  const stored = JSON.parse(k.encode());
  stored.hosts[0].id = ID_B; // a lie
  const r = await A.KnownHosts.decode(JSON.stringify(stored), cr);
  assert.strictEqual(r.known.hosts[0].id, ID_A);
});

test('known hosts: load and save through a store', async () => {
  const store = A.memoryStore();
  const first = await A.loadKnownHosts(store, cr);
  assert.strictEqual(first.known.hosts.length, 0);
  first.known.recordVerified({ key: KEY_A, id: ID_A, name: 'Studio', address: '192.0.2.1:5903' }, 1);
  await A.saveKnownHosts(store, first.known);
  const again = await A.loadKnownHosts(store, cr);
  assert.strictEqual(again.known.hosts.length, 1);
  const broken = await A.loadKnownHosts({ async get() { throw new Error('x'); } }, cr);
  assert.strictEqual(broken.damaged, true);
});

// ── Fallback addresses reach the same display ───────────────────────────
function twoRoutes() {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Example Mac', address: 'ws://192.0.2.10:5903' }, 1);
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Example Mac', address: 'ws://192.0.2.10:5904' }, 2);
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Example Mac', address: 'ws://198.51.100.7:5903' }, 3);
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Example Mac', address: 'wss://mac.example.com/ws/a' }, 4);
  return k;
}
const sorted = (list) => [...list].sort();

test('fallback: the tunnel path is kept when an address is saved, and survives a save and a load', async () => {
  const k = twoRoutes();
  assert.strictEqual(k.host(ID_A).addresses.find((x) => x.address === 'mac.example.com:443').path, '/ws/a');
  assert.strictEqual(k.host(ID_A).addresses.find((x) => x.address === '192.0.2.10:5903').path, undefined);
  const r = await A.KnownHosts.decode(k.encode(), cr);
  assert.strictEqual(r.damaged, false);
  assert.deepStrictEqual(r.known.hosts, k.hosts);
});

test('fallback: a fallback for display A keeps to display A, and B to B', () => {
  const k = twoRoutes();
  assert.deepStrictEqual(sorted(k.fallbackUrls(ID_A, 'ws://192.0.2.10:5903')),
    ['ws://198.51.100.7:5903', 'wss://mac.example.com/ws/a']);
  assert.deepStrictEqual(k.fallbackUrls(ID_A, 'ws://192.0.2.10:5904'), ['wss://mac.example.com/ws/b']);
  assert.deepStrictEqual(k.fallbackUrls(ID_A, 'wss://mac.example.com/ws/b'), ['ws://192.0.2.10:5904']);
  assert.deepStrictEqual(sorted(k.fallbackUrls(ID_A, 'wss://mac.example.com/ws/a')),
    ['ws://192.0.2.10:5903', 'ws://198.51.100.7:5903']);
});

test('fallback: a saved tunnel with no path gives no tunnel fallback; an old copy still loads', async () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Example Mac', address: '192.0.2.10' }, 1);
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Example Mac', address: 'wss://mac.example.com' }, 2);
  assert.deepStrictEqual(k.fallbackUrls(ID_A, 'ws://192.0.2.10:5903'), []);
  const r = await A.KnownHosts.decode(k.encode(), cr);
  assert.strictEqual(r.damaged, false);
  assert.deepStrictEqual(r.known.fallbackUrls(ID_A, 'ws://192.0.2.10:5903'), []);
  r.known.bind('wss://mac.example.com/ws/a', ID_A, 9);
  assert.deepStrictEqual(r.known.fallbackUrls(ID_A, 'ws://192.0.2.10:5903'), ['wss://mac.example.com/ws/a']);
});

test('fallback: a hint fills in a missing path and never moves an address', () => {
  const k = new A.KnownHosts();
  k.recordVerified({ key: KEY_A, id: ID_A, name: 'Example Mac', address: '192.0.2.10' }, 1);
  k.recordVerified({ key: KEY_B, id: ID_B, name: 'Other Mac', address: '198.51.100.9' }, 1);
  k.addHints(['wss://mac.example.com/ws/a', 'ws://198.51.100.9:5903'], ID_A, 2);
  assert.strictEqual(k.host(ID_A).addresses.find((x) => x.address === 'mac.example.com:443').path, '/ws/a');
  assert.deepStrictEqual(k.standing('198.51.100.9:5903'), { kind: 'host', id: ID_B });
});

test('fallback: only a display path is kept', () => {
  assert.strictEqual(A.displayPath('wss://mac.example.com/tunnel/ws/b'), '/tunnel/ws/b');
  assert.strictEqual(A.displayPath('wss://mac.example.com'), null);
  assert.strictEqual(A.displayPath('wss://mac.example.com/ws/ab'), null);
  assert.strictEqual(A.displayPath('ws://192.0.2.10:5903/ws/a'), null);
  assert.strictEqual(A.displayIndex('ws://192.0.2.10:5905'), 2);
  assert.strictEqual(A.displayIndex('192.0.2.10'), 0);
  assert.strictEqual(A.displayIndex('ws://192.0.2.10:8443'), null);
  assert.strictEqual(A.displayIndex('wss://mac.example.com'), null);
});

test('ClientInfo helpers: cleanURL and HOST_INFO urls', () => {
  assert.strictEqual(A.cleanURL('wss://u:p@mac.example.com/ws/a?token=1#x'), 'wss://mac.example.com/ws/a');
  assert.strictEqual(A.cleanURL('nonsense'), null);
  const info = JSON.stringify({ displays: [{ urls: ['ws://192.0.2.1:5903', 7] }, { urls: 'no' }, null] });
  assert.deepStrictEqual(A.hostInfoURLs(A.bytes(info)), ['ws://192.0.2.1:5903']);
  assert.deepStrictEqual(A.hostInfoURLs(A.bytes('{')), []);
  assert.deepStrictEqual(A.hostInfoURLs(new Uint8Array(70000)), []);
  void b64u;
});
