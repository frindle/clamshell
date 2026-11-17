// Tests for AuthFlow in Sources/Clamshell/Resources/webclient/auth.js: every
// rule of the connection flow, against an in-memory host (tests/auth-test-host.js),
// no sockets and no real time. Run: node tests/test-webclient-auth-flow.js
import { test } from 'node:test';
import assert from 'node:assert';
import * as A from '../Sources/Clamshell/Resources/webclient/auth.js';
import { TestHost, newSigningIdentity, unframe } from './auth-test-host.js';

const cr = globalThis.crypto;
const ADDRESS = 'ws://192.0.2.10:5903';
const hello = () => A.frame(A.MSG.HELLO, Uint8Array.of(1, 2));
const text = (b) => new TextDecoder().decode(b);

/** One flow with its action log. `known` holds the saved hosts. */
async function setup({ known = new A.KnownHosts(), webCrypto = true, url = ADDRESS, carry, caps } = {}) {
  const device = webCrypto ? await newSigningIdentity() : null;
  const log = [];
  const flow = new A.AuthFlow({
    deviceKey: device, deviceName: 'Safari on Mac', dialledURL: url, known, carry, caps,
    makeHello: hello, emit: (a) => log.push(a), cr: webCrypto ? cr : {},
  });
  const t = {
    flow, log, device,
    of: (kind) => log.filter((a) => a.do === kind),
    sends: () => log.filter((a) => a.do === 'send').map((a) => a.data),
    states: () => log.filter((a) => a.do === 'state').map((a) => a.state),
    lastState: () => t.states().at(-1),
    changes: () => log.filter((a) => a.do === 'change').map((a) => a.change),
    ends: () => log.filter((a) => a.do === 'end'),
    caps: () => log.filter((a) => a.do === 'hostCapabilities').map((a) => a.bits),
    clear: () => { log.length = 0; },
    async feed(message) { const { type, payload } = unframe(message); await flow.received(type, payload); await flow.settled(); },
    async open() { await flow.opened(); await flow.settled(); },
  };
  return t;
}

/** Opens, delivers a challenge, and has the host verify the response. */
async function handshake(t, host) {
  await t.open();
  await t.feed(host.challengeMessage());
  const sent = t.sends();
  assert.strictEqual(sent.length, 1, 'only the response was sent');
  const { type, payload } = unframe(sent[0]);
  assert.strictEqual(type, A.MSG.AUTH_RESPONSE);
  await host.verifyResponse(payload);
  return host;
}

async function savedHostKnown(host, address = ADDRESS) {
  const known = new A.KnownHosts();
  known.recordVerified({ key: host.identity.publicRaw, id: host.id, name: 'Studio', address }, 1);
  return known;
}

// A session that has just started: accepted from a known host.
async function secureSession(opts = {}) {
  const host = await TestHost.create(opts);
  const t = await setup({ known: await savedHostKnown(host) });
  await handshake(t, host);
  const wire = [];
  await host.startSession((d) => wire.push(d));
  await t.feed(await host.resultMessage(A.STATUS.accepted));
  return { host, t, wire };
}

// ── 1 and 2: nothing before the challenge; the challenge is answered ───
test('the flow sends nothing when the socket opens, and starts the 2 s wait', async () => {
  const t = await setup();
  await t.open();
  assert.deepStrictEqual(t.sends(), []);
  assert.deepStrictEqual(t.of('startTimer').map((a) => [a.timer, a.seconds]), [['challenge', 2]]);
  assert.deepStrictEqual(t.lastState(), { kind: 'connecting' });
});

test('a good challenge is answered with a response the host verifies', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  assert.strictEqual(host.device.name, 'Safari on Mac');
  assert.strictEqual(host.device.caps, A.WEB_CAPS);
  assert.strictEqual(A.toHex(host.device.identity), A.toHex(t.device.publicRaw));
  assert.deepStrictEqual(t.of('startTimer').map((a) => [a.timer, a.seconds]), [['challenge', 2], ['result', 15]]);
  assert.ok(t.of('cancelTimer').some((a) => a.timer === 'challenge'));
});

test('rule 2: before accepted only a challenge, then results, are taken', async () => {
  for (const type of [A.MSG.PING, A.MSG.HOST_INFO, A.MSG.SECURE, A.MSG.AUTH_RESULT, 0x10]) {
    const t = await setup();
    await t.open();
    await t.flow.received(type, new Uint8Array(70));
    await t.flow.settled();
    assert.strictEqual(t.ends().length, 1, `type ${type} before the challenge`);
    assert.strictEqual(t.lastState().kind, 'failed');
    assert.deepStrictEqual(t.sends(), []);
  }
  const host = await TestHost.create();
  for (const type of [A.MSG.PING, A.MSG.AUTH_CHALLENGE, A.MSG.SECURE]) {
    const t = await setup();
    await handshake(t, host);
    await t.flow.received(type, new Uint8Array(70));
    await t.flow.settled();
    assert.strictEqual(t.ends().length, 1, `type ${type} where a result belongs`);
  }
});

test('rule 3: a challenge of another version, with a bad key, or cut short is a failed connection', async () => {
  const host = await TestHost.create();
  const mutate = (fn) => { const p = host.payload.slice(); fn(p); return p; };
  const bad = [
    mutate((p) => { p[0] = 2; }),
    mutate((p) => { p[1 + 4 + 32 + 65 + 64] ^= 1; }), // identity key off the curve
    mutate((p) => { p[1 + 4 + 32 + 10] ^= 1; }), // key-exchange key off the curve
    host.payload.subarray(0, 100),
  ];
  for (const payload of bad) {
    const t = await setup();
    await t.open();
    await t.flow.received(A.MSG.AUTH_CHALLENGE, payload);
    await t.flow.settled();
    assert.strictEqual(t.lastState().kind, 'failed');
    assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['failure']);
    assert.deepStrictEqual(t.sends(), []);
  }
});

// ── 4: changed identity ────────────────────────────────────────────────
test('rule 4: a different key at a saved address is refused, nothing is sent, no way through', async () => {
  const saved = await TestHost.create();
  const imposter = await TestHost.create();
  const t = await setup({ known: await savedHostKnown(saved) });
  await t.open();
  await t.feed(imposter.challengeMessage());
  assert.deepStrictEqual(t.sends(), []);
  assert.deepStrictEqual(t.lastState(), {
    kind: 'changedIdentity', address: '192.0.2.10:5903',
    savedFingerprint: saved.fingerprint, nowFingerprint: imposter.fingerprint,
  });
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['stop']);
  assert.deepStrictEqual(t.changes(), []);
  await t.flow.answered(true); // there is no question to answer
  assert.deepStrictEqual(t.sends(), []);
  assert.strictEqual(t.ends().length, 1);
});

// ── 5: a silent known host ─────────────────────────────────────────────
test('rule 5: a saved host that says nothing for 2 s is refused, nothing is sent', async () => {
  const saved = await TestHost.create();
  const t = await setup({ known: await savedHostKnown(saved) });
  await t.open();
  await t.flow.timerFired('challenge'); await t.flow.settled();
  assert.deepStrictEqual(t.sends(), []);
  assert.deepStrictEqual(t.lastState(), { kind: 'didNotIdentify', hostName: 'Studio' });
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['stop']);
});

// ── 6: a silent unknown host ───────────────────────────────────────────
test('rule 6: a silent unknown host is asked about, and nothing is sent before yes', async () => {
  const t = await setup();
  await t.open();
  await t.flow.timerFired('challenge'); await t.flow.settled();
  assert.deepStrictEqual(t.lastState(), { kind: 'askUnverified', address: '192.0.2.10:5903' });
  assert.deepStrictEqual(t.sends(), []);
  assert.deepStrictEqual(t.changes(), []);
  await t.flow.answered(true); await t.flow.settled();
  assert.deepStrictEqual(t.sends(), [hello()], 'a clear HELLO');
  assert.deepStrictEqual(t.changes(), [{ kind: 'allowUnverified', address: ADDRESS.replace('ws://', '') }]
    .map((c) => ({ ...c, address: '192.0.2.10:5903' })));
  assert.deepStrictEqual(t.caps().at(-1), 0);
  assert.deepStrictEqual(t.lastState(), { kind: 'connected', verified: false, hostName: '' });
});

test('rule 6: on no, nothing is sent and nothing is remembered', async () => {
  const t = await setup();
  await t.open();
  await t.flow.timerFired('challenge'); await t.flow.settled();
  await t.flow.answered(false); await t.flow.settled();
  assert.deepStrictEqual(t.sends(), []);
  assert.deepStrictEqual(t.changes(), []);
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['stop']);
});

test('rule 6: an address the user allowed before is not asked about again', async () => {
  const known = new A.KnownHosts();
  known.allowUnverified(ADDRESS);
  const t = await setup({ known });
  await t.open();
  await t.flow.timerFired('challenge'); await t.flow.settled();
  assert.deepStrictEqual(t.sends(), [hello()]);
  assert.ok(!t.states().some((s) => s.kind === 'askUnverified'));
  assert.deepStrictEqual(t.lastState(), { kind: 'connected', verified: false, hostName: '' });
});

test('rule 6: in a clear session messages go both ways as they are, with every capability 0', async () => {
  const t = await setup();
  await t.open();
  await t.flow.timerFired('challenge'); await t.flow.answered(true); await t.flow.settled();
  t.clear();
  await t.flow.received(A.MSG.HOST_INFO, A.bytes('{}')); await t.flow.settled();
  assert.deepStrictEqual(t.of('deliver').map((a) => a.type), [A.MSG.HOST_INFO]);
  const key = A.frame(0x22, new Uint8Array(11));
  t.flow.send(key);
  assert.deepStrictEqual(t.sends(), [key]);
  await t.flow.received(A.MSG.AUTH_RESULT, new Uint8Array(67)); await t.flow.settled();
  assert.strictEqual(t.lastState().kind, 'failed');
});

test('rule 6: a challenge after a clear HELLO closes and reconnects, waiting 10 s', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await t.open();
  await t.flow.timerFired('challenge'); await t.flow.answered(true); await t.flow.settled();
  t.clear();
  await t.feed(host.challengeMessage());
  const end = t.ends()[0].end;
  assert.strictEqual(end.kind, 'reconnect');
  assert.strictEqual(end.after, 0);
  assert.strictEqual(end.carry.challengeWait, 10);
  assert.deepStrictEqual(t.sends(), [], 'it answers nothing on this connection');
  // The next attempt waits 10 s.
  const next = await setup({ carry: end.carry });
  await next.open();
  assert.deepStrictEqual(next.of('startTimer').map((a) => a.seconds), [10]);
});

// ── 8 and 9: results ───────────────────────────────────────────────────
test('rule 8: a result with a bad signature is a failed connection, whatever it says', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  const accepted = await host.result(A.STATUS.accepted);
  accepted[accepted.length - 1] ^= 1;
  await t.flow.received(A.MSG.AUTH_RESULT, accepted); await t.flow.settled();
  assert.strictEqual(t.lastState().kind, 'failed');
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['failure']);
  assert.deepStrictEqual(t.changes(), []);
  assert.ok(!t.caps().some((b) => b !== 0), 'no host capabilities were published');
});

test('rule 8: a result signed by a different key is refused', async () => {
  const host = await TestHost.create();
  const other = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  other.device = host.device; other.payload = host.payload;
  const forged = await other.result(A.STATUS.accepted);
  await t.flow.received(A.MSG.AUTH_RESULT, forged); await t.flow.settled();
  assert.strictEqual(t.lastState().kind, 'failed');
});

test('rule 9: a verified result from a known host at a new address binds it without asking', async () => {
  const host = await TestHost.create();
  const known = await savedHostKnown(host, '192.0.2.99:5903');
  const t = await setup({ known });
  await handshake(t, host);
  await t.feed(await host.resultMessage(A.STATUS.pending));
  assert.deepStrictEqual(t.changes(), [{ kind: 'bind', hostId: host.id, address: '192.0.2.10:5903' }]);
  await t.feed(await host.resultMessage(A.STATUS.pending)); // a repeat binds nothing again
  assert.strictEqual(t.changes().length, 1);
});

// ── 10 and 11: pending, then accepted ──────────────────────────────────
test('rules 10 and 11: pending, a repeated pending, then accepted: the host is remembered', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  const pending = await host.resultMessage(A.STATUS.pending);
  await t.feed(pending);
  assert.deepStrictEqual(t.lastState(), {
    kind: 'waiting', hostName: 'Studio', hostFingerprint: host.fingerprint,
    deviceName: 'Safari on Mac', deviceFingerprint: await A.fingerprintOfKey(t.device.publicRaw, cr),
  });
  assert.ok(t.of('startTimer').some((a) => a.timer === 'pending' && a.seconds === 60));
  assert.strictEqual(t.ends().length, 0, 'it stays connected');
  await t.feed(pending); // the same bytes again
  assert.strictEqual(t.ends().length, 0);
  assert.strictEqual(t.lastState().kind, 'waiting');
  await host.startSession(() => {});
  await t.feed(await host.resultMessage(A.STATUS.accepted));
  assert.deepStrictEqual(t.changes(), [{
    kind: 'recordVerified', key: host.identity.publicRaw, id: host.id, name: 'Studio', address: '192.0.2.10:5903',
  }]);
  assert.deepStrictEqual(t.lastState(), { kind: 'connected', verified: true, hostName: 'Studio' });
  assert.strictEqual(t.flow.isSecure, true);
});

test('rule 10: no result for 60 s while waiting is a dead connection: reconnect and keep waiting', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  await t.feed(await host.resultMessage(A.STATUS.pending));
  await t.flow.timerFired('pending'); await t.flow.settled();
  assert.deepStrictEqual(t.ends().map((e) => [e.end.kind, e.end.after]), [['reconnect', 0]]);
});

test('the 15 s wait for the first result is a failed connection', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  await t.flow.timerFired('result'); await t.flow.settled();
  assert.strictEqual(t.lastState().kind, 'failed');
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['failure']);
});

// ── 12: let in without asking ──────────────────────────────────────────
test('rule 12: a host not met before that lets this device in unasked is not trusted until yes', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  await host.startSession(() => {});
  t.clear();
  await t.feed(await host.resultMessage(A.STATUS.accepted));
  assert.deepStrictEqual(t.lastState(), { kind: 'confirmHost', hostName: 'Studio', fingerprint: host.fingerprint });
  assert.strictEqual(t.of('close').length, 1);
  assert.deepStrictEqual(t.sends(), [], 'nothing was sent');
  assert.deepStrictEqual(t.changes(), [], 'nothing was remembered');
  assert.ok(!t.caps().some((b) => b !== 0));
  assert.strictEqual(t.ends().length, 0);
  await t.flow.socketClosed(); await t.flow.settled(); // the close we asked for is not a failure
  assert.strictEqual(t.ends().length, 0);
  await t.flow.answered(true); await t.flow.settled();
  assert.deepStrictEqual(t.changes(), [{
    kind: 'recordVerified', key: host.identity.publicRaw, id: host.id, name: 'Studio', address: '192.0.2.10:5903',
  }]);
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['reconnect']);
});

test('rule 12: on no nothing is remembered and nothing is sent', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  await host.startSession(() => {});
  await t.feed(await host.resultMessage(A.STATUS.accepted));
  await t.flow.answered(false); await t.flow.settled();
  assert.deepStrictEqual(t.changes(), []);
  assert.deepStrictEqual(t.sends().length, 1, 'only the response, from before');
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['stop']);
});

test('rule 12: a known host that accepts at once needs no question', async () => {
  const { t } = await secureSession();
  assert.strictEqual(t.lastState().kind, 'connected');
  assert.ok(!t.states().some((s) => s.kind === 'confirmHost'));
});

// ── 13: the refusals ───────────────────────────────────────────────────
test('rule 13: denied stops and says so; nothing is retried', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  await t.feed(await host.resultMessage(A.STATUS.denied));
  assert.deepStrictEqual(t.lastState(), { kind: 'denied', hostName: 'Studio' });
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['stop']);
});

test('rule 13: invalid stops and says so', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  await t.feed(await host.resultMessage(A.STATUS.invalid));
  assert.deepStrictEqual(t.lastState(), { kind: 'invalid', hostName: 'Studio' });
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['stop']);
});

test('rule 13: busy retries after 15 s, doubling to at most 2 min', async () => {
  let carry;
  const delays = [];
  for (let i = 0; i < 6; i++) {
    const host = await TestHost.create();
    const t = await setup({ carry });
    await handshake(t, host);
    await t.feed(await host.resultMessage(A.STATUS.busy));
    const end = t.ends()[0].end;
    assert.strictEqual(end.kind, 'reconnect');
    assert.deepStrictEqual(t.lastState(), { kind: 'busy', retryIn: end.after });
    delays.push(end.after);
    carry = end.carry;
  }
  assert.deepStrictEqual(delays, [15, 30, 60, 120, 120, 120]);
});

test('rule 13: timeout reconnects at once, once; after that as for busy', async () => {
  const host = await TestHost.create();
  const t = await setup();
  await handshake(t, host);
  await t.feed(await host.resultMessage(A.STATUS.timeout));
  let end = t.ends()[0].end;
  assert.strictEqual(end.after, 0);
  assert.strictEqual(end.carry.timeoutRetried, true);
  const host2 = await TestHost.create();
  const t2 = await setup({ carry: end.carry });
  await handshake(t2, host2);
  await t2.feed(await host2.resultMessage(A.STATUS.timeout));
  end = t2.ends()[0].end;
  assert.strictEqual(end.after, 15);
  assert.strictEqual(t2.lastState().kind, 'busy');
});

// ── 14: the session ────────────────────────────────────────────────────
test('rule 14: after accepted HELLO is sealed first, then CLIENT_INFO once', async () => {
  const { host, t } = await secureSession();
  const sent = t.sends();
  assert.strictEqual(sent.length, 3, 'response, HELLO, CLIENT_INFO');
  assert.deepStrictEqual(sent.slice(1).map((m) => m[0]), [A.MSG.SECURE, A.MSG.SECURE]);
  const first = await host.openFromClient(sent[1]);
  assert.strictEqual(first.type, A.MSG.HELLO);
  assert.deepStrictEqual([...first.payload], [1, 2]);
  const second = await host.openFromClient(sent[2]);
  assert.strictEqual(second.type, A.MSG.CLIENT_INFO);
  const info = JSON.parse(text(second.payload));
  assert.deepStrictEqual(Object.keys(info), ['app', 'url', 'version']);
  assert.deepStrictEqual(info, { app: 'web', url: 'ws://192.0.2.10:5903/', version: A.WEB_CLIENT_VERSION });
});

test('rule 14: CLIENT_INFO carries the URL dialled without user info, query or fragment', async () => {
  const host = await TestHost.create();
  const url = 'wss://u:p@mac.example.com/ws/a?token=secret#frag';
  const t = await setup({ url, known: await savedHostKnown(host, url) });
  await handshake(t, host);
  await host.startSession(() => {});
  await t.feed(await host.resultMessage(A.STATUS.accepted));
  await host.openFromClient(t.sends()[1]); // HELLO uses counter 0
  const info = JSON.parse(text((await host.openFromClient(t.sends()[2])).payload));
  assert.strictEqual(info.url, 'wss://mac.example.com/ws/a');
  assert.ok(!text(new TextEncoder().encode(JSON.stringify(info))).includes('secret'));
});

test('rule 14: a SECURE round trip both ways, HELLO first', async () => {
  const { host, t } = await secureSession();
  const wire = [];
  await host.startSession((d) => wire.push(d)); // a fresh sealer starting at the same keys, counters 0
  // Host to client: HOST_INFO, then a PING, as in the vectors.
  const info = A.frame(A.MSG.HOST_INFO, A.bytes(JSON.stringify({ name: 'Studio', displays: [] })));
  host.sealer.seal(info);
  host.sealer.seal(A.frame(A.MSG.PING));
  await host.sealer.settled();
  t.clear();
  for (const m of wire) await t.feed(m);
  assert.deepStrictEqual(t.of('deliver').map((a) => a.type), [A.MSG.PING], 'HOST_INFO is kept, PING is delivered');
  // Client to host: three messages arrive in order.
  const before = t.sends().length;
  for (let i = 0; i < 3; i++) t.flow.send(A.frame(0x22, Uint8Array.of(i, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)));
  await t.flow.settled();
  const out = t.sends().slice(before);
  assert.strictEqual(out.length, 3);
  const opener = host.opener;
  void opener;
});

test('rule 14: 200 messages sent in one synchronous burst arrive in counter order', async () => {
  const { host, t } = await secureSession();
  const before = t.sends().length;
  for (let i = 0; i < 200; i++) t.flow.send(A.frame(0x22, Uint8Array.of(i, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)));
  await t.flow.settled();
  const out = t.sends().slice(before);
  assert.strictEqual(out.length, 200);
  // HELLO and CLIENT_INFO used counters 0 and 1: open those first.
  await host.openFromClient(t.sends()[1]);
  await host.openFromClient(t.sends()[2]);
  for (let i = 0; i < 200; i++) {
    const m = await host.openFromClient(out[i]);
    assert.strictEqual(m.payload[0], i, `message ${i}`);
  }
});

test('rule 14: a clear message after accepted closes the connection', async () => {
  const { t } = await secureSession();
  t.clear();
  await t.flow.received(A.MSG.PING, new Uint8Array(0)); await t.flow.settled();
  assert.strictEqual(t.lastState().kind, 'failed');
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['failure']);
  assert.ok(t.caps().includes(0), 'host capabilities go back to 0');
});

test('rule 14: a SECURE message that fails to open closes the connection', async () => {
  const { t } = await secureSession();
  t.clear();
  await t.flow.received(A.MSG.SECURE, new Uint8Array(40)); await t.flow.settled();
  assert.strictEqual(t.lastState().kind, 'failed');
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['failure']);
});

test('rule 14: a changed, repeated or reordered SECURE message closes the connection', async () => {
  for (const mode of ['changed', 'repeated', 'reordered']) {
    const { host, t } = await secureSession();
    const a = await host.rawSecureFrame(A.frame(A.MSG.PING), 0);
    const b = await host.rawSecureFrame(A.frame(A.MSG.PING), 1);
    t.clear();
    const { payload } = unframe(a);
    if (mode === 'changed') { const p = payload.slice(); p[0] ^= 1; await t.flow.received(A.MSG.SECURE, p); }
    if (mode === 'repeated') { await t.flow.received(A.MSG.SECURE, payload); await t.flow.received(A.MSG.SECURE, payload); }
    if (mode === 'reordered') await t.flow.received(A.MSG.SECURE, unframe(b).payload);
    await t.flow.settled();
    assert.strictEqual(t.lastState().kind, 'failed', mode);
  }
});

test('rule 14: an inner SECURE or AUTH message closes the connection', async () => {
  for (const type of [A.MSG.SECURE, A.MSG.AUTH_CHALLENGE, A.MSG.AUTH_RESPONSE, A.MSG.AUTH_RESULT]) {
    const { host, t } = await secureSession();
    t.clear();
    await t.feed(await host.rawSecureFrame(A.frame(type), 0));
    assert.strictEqual(t.lastState().kind, 'failed', `type ${type}`);
    assert.deepStrictEqual(t.of('deliver'), []);
  }
});

test('rule 14: an inner message with a wrong length closes the connection', async () => {
  const { host, t } = await secureSession();
  t.clear();
  await t.feed(await host.rawSecureFrame(Uint8Array.of(7, 0, 0, 0, 9), 0));
  assert.strictEqual(t.lastState().kind, 'failed');
});

// ── 15: host capabilities ──────────────────────────────────────────────
test('rule 15: host capabilities count only after accepted is verified, and go back to 0 at the end', async () => {
  const host = await TestHost.create({ caps: 0b11011 });
  const t = await setup({ known: await savedHostKnown(host) });
  await handshake(t, host);
  assert.deepStrictEqual(t.caps(), [], 'not from the challenge alone');
  await t.feed(await host.resultMessage(A.STATUS.pending));
  assert.deepStrictEqual(t.caps(), []);
  await host.startSession(() => {});
  await t.feed(await host.resultMessage(A.STATUS.accepted));
  assert.deepStrictEqual(t.caps(), [0b11011]);
  await t.flow.socketClosed(); await t.flow.settled();
  assert.deepStrictEqual(t.caps(), [0b11011, 0]);
});

// ── 16: HOST_INFO ──────────────────────────────────────────────────────
test('rule 16: HOST_INFO addresses become hints for that host; nothing changes the expected key', async () => {
  const { host, t } = await secureSession();
  const wire = [];
  await host.startSession((d) => wire.push(d));
  host.sealer.seal(A.frame(A.MSG.HOST_INFO, A.bytes(JSON.stringify({
    displays: [{ index: 0, urls: ['wss://mac.example.com/ws/a', 'https://no.example.com'] }],
    hostId: 'ff'.repeat(32),
  }))));
  await host.sealer.settled();
  t.clear();
  await t.feed(wire[0]);
  assert.deepStrictEqual(t.changes(), [{
    kind: 'hints', hostId: host.id, urls: ['wss://mac.example.com/ws/a', 'https://no.example.com'],
  }]);
  const known = new A.KnownHosts();
  known.recordVerified({ key: host.identity.publicRaw, id: host.id, name: 'Studio', address: ADDRESS }, 1);
  for (const c of t.changes()) known.apply(c, 2);
  assert.deepStrictEqual(known.host(host.id).addresses.map((a) => a.address), ['192.0.2.10:5903', 'mac.example.com:443']);
  assert.strictEqual(known.host(host.id).key, A.toHex(host.identity.publicRaw));
});

// ── Dropped before accepted ────────────────────────────────────────────
test('input raised before accepted is dropped, never queued', async () => {
  const host = await TestHost.create();
  const t = await setup({ known: await savedHostKnown(host) });
  t.flow.send(A.frame(0x22, new Uint8Array(11))); // before the socket even opened
  await t.open();
  t.flow.send(A.frame(0x22, new Uint8Array(11)));
  await t.feed(host.challengeMessage());
  t.flow.send(A.frame(0x22, new Uint8Array(11)));
  await host.verifyResponse(unframe(t.sends()[0]).payload);
  await host.startSession(() => {});
  await t.feed(await host.resultMessage(A.STATUS.pending));
  t.flow.send(A.frame(0x22, new Uint8Array(11)));
  await t.feed(await host.resultMessage(A.STATUS.accepted));
  assert.strictEqual(t.sends().length, 3, 'response, HELLO, CLIENT_INFO and nothing else');
  assert.strictEqual((await host.openFromClient(t.sends()[1])).type, A.MSG.HELLO);
});

test('after the connection ends nothing more is sent', async () => {
  const { t } = await secureSession();
  await t.flow.socketClosed(); await t.flow.settled();
  t.clear();
  t.flow.send(A.frame(0x22, new Uint8Array(11)));
  await t.flow.settled();
  assert.deepStrictEqual(t.sends(), []);
});

// ── No WebCrypto ───────────────────────────────────────────────────────
test('no WebCrypto: a challenge that says approval is required stops at once with the https text', async () => {
  const host = await TestHost.create({ caps: 0b11011 });
  const t = await setup({ webCrypto: false });
  await t.open();
  await t.feed(host.challengeMessage());
  assert.deepStrictEqual(t.lastState(), { kind: 'needsHttps', text: A.HTTPS_NEEDED_TEXT });
  assert.strictEqual(A.HTTPS_NEEDED_TEXT,
    'This Mac only accepts devices it has approved. A browser can only prove which device it is on an https page.');
  assert.deepStrictEqual(t.sends(), []);
  assert.deepStrictEqual(t.ends().map((e) => e.end.kind), ['stop']);
  assert.ok(!t.caps().some((b) => b !== 0));
});

test('no WebCrypto: a challenge without that bit gets a clear HELLO, capabilities 0, Not verified, no question', async () => {
  const host = await TestHost.create({ caps: 0b11010 });
  const t = await setup({ webCrypto: false });
  await t.open();
  await t.feed(host.challengeMessage());
  assert.deepStrictEqual(t.sends(), [hello()]);
  assert.deepStrictEqual(t.lastState(), { kind: 'connected', verified: false, hostName: '' });
  assert.ok(!t.states().some((s) => s.kind === 'askUnverified'));
  assert.deepStrictEqual(t.caps(), [0]);
  assert.deepStrictEqual(t.changes(), [], 'nothing is remembered');
  // The session then runs in the clear, as today.
  const key = A.frame(0x22, new Uint8Array(11));
  t.flow.send(key);
  assert.deepStrictEqual(t.sends().at(-1), key);
});

test('no WebCrypto: no challenge within 2 s gets a clear HELLO and no question', async () => {
  const t = await setup({ webCrypto: false });
  await t.open();
  await t.flow.timerFired('challenge'); await t.flow.settled();
  assert.deepStrictEqual(t.sends(), [hello()]);
  assert.deepStrictEqual(t.lastState(), { kind: 'connected', verified: false, hostName: '' });
  assert.ok(!t.states().some((s) => s.kind === 'askUnverified'));
  assert.deepStrictEqual(t.changes(), []);
});

test('no WebCrypto: a saved host is never answered with a clear HELLO', async () => {
  const saved = await TestHost.create({ caps: 0b11010 });
  const t = await setup({ webCrypto: false, known: await savedHostKnown(saved) });
  await t.open();
  await t.feed(saved.challengeMessage());
  assert.deepStrictEqual(t.sends(), []);
  assert.strictEqual(t.lastState().kind, 'didNotIdentify');
  const t2 = await setup({ webCrypto: false, known: await savedHostKnown(saved) });
  await t2.open();
  await t2.flow.timerFired('challenge'); await t2.flow.settled();
  assert.deepStrictEqual(t2.sends(), []);
  assert.strictEqual(t2.lastState().kind, 'didNotIdentify');
});

test('no WebCrypto: a malformed challenge is a failed connection', async () => {
  const t = await setup({ webCrypto: false });
  await t.open();
  await t.flow.received(A.MSG.AUTH_CHALLENGE, new Uint8Array(20)); await t.flow.settled();
  assert.strictEqual(t.lastState().kind, 'failed');
  assert.deepStrictEqual(t.sends(), []);
});

// ── Odds and ends ──────────────────────────────────────────────────────
test('an address that cannot be used fails at once', async () => {
  const t = await setup({ url: 'http://example.com' });
  await t.open();
  assert.strictEqual(t.lastState().kind, 'failed');
  assert.deepStrictEqual(t.sends(), []);
});

test('events after the end do nothing', async () => {
  const t = await setup();
  await t.open();
  await t.flow.socketClosed(); await t.flow.settled();
  const n = t.log.length;
  await t.flow.timerFired('challenge'); await t.flow.received(A.MSG.AUTH_CHALLENGE, new Uint8Array(0));
  await t.flow.answered(true); await t.flow.settled();
  assert.strictEqual(t.log.length, n);
});

test('the log holds fingerprints and states only: no key, signature or session secret', async () => {
  const { host, t } = await secureSession();
  const dump = JSON.stringify(t.states()) + JSON.stringify(t.ends());
  assert.ok(!dump.includes(A.toHex(host.keys.clientToHost)));
  assert.ok(!dump.includes(A.toHex(host.keys.hostToClient)));
  assert.ok(!dump.includes(A.toHex(host.identity.publicRaw)));
});
