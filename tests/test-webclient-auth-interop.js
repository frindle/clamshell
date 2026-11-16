// Interop check: the web client's auth.js against the real Mac host.
//
//   node tests/test-webclient-auth-interop.js <path to the Clamshell binary> <port>
//
// Needs Node 22 or later (a global WebSocket) and WebCrypto. There is no skip
// path: a missing WebSocket or crypto.subtle is a failure. It starts
// `Clamshell auth-interop-host <port>` (loopback only, device approval on,
// nothing captured or typed) with a temporary state directory, then:
//   1. reads the challenge and checks that it asks for approval;
//   2. answers it and gets a verified "pending";
//   3. runs `Clamshell approve <fingerprint>` and gets a verified "accepted"
//      on the same connection;
//   4. opens the first SECURE message (HOST_INFO) and does a sealed PING round trip;
//   5. runs `Clamshell revoke <fingerprint>` and sees the host close the connection;
//   6. connects again with the same key and gets a verified "denied".
// It sends no HELLO, so no screen capture starts. The host and the directory
// are removed at the end, also on failure. Exit code 0 only if all six passed.
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  MSG, STATUS, WEB_CAPS, ClientHandshake, Opener, Sealer, frame, parseChallenge, keyId,
  fingerprintOfKey, loadDeviceKey, memoryStore, importSessionKey, generateEphemeral,
} from '../Sources/Clamshell/Resources/webclient/auth.js';

const binary = process.argv[2];
const port = Number(process.argv[3]);
const STEP_MS = 15000;

class Failure extends Error {}
function check(ok, what) { if (!ok) throw new Failure(`expected that ${what}`); }

/** One WebSocket connection; messages queue up and are read in order. */
class Peer {
  constructor(url) {
    this.events = [];
    this.waiter = null;
    this.closed = false;
    this.ws = new WebSocket(url);
    this.ws.binaryType = 'arraybuffer';
    this.opened = new Promise((resolve, reject) => {
      this.ws.addEventListener('open', resolve);
      this.ws.addEventListener('error', () => reject(new Failure('the connection could not be opened')));
    });
    this.ws.addEventListener('message', (ev) => this.#push({ data: new Uint8Array(ev.data) }));
    this.ws.addEventListener('close', () => { this.closed = true; this.#push({ closed: true }); });
  }

  #push(e) {
    this.events.push(e);
    if (this.waiter) { const w = this.waiter; this.waiter = null; w(); }
  }

  /** The next event: { type, payload } for a message, { closed: true } at the end. */
  async next(ms = STEP_MS) {
    const deadline = Date.now() + ms;
    while (this.events.length === 0) {
      const left = deadline - Date.now();
      if (left <= 0) throw new Failure('a message did not arrive in time');
      await new Promise((resolve) => { this.waiter = resolve; setTimeout(resolve, left); });
    }
    const e = this.events.shift();
    if (e.closed) return e;
    const view = new DataView(e.data.buffer, e.data.byteOffset, e.data.length);
    check(e.data.length >= 5 && e.data.length === 5 + view.getUint32(1, false), 'a message is framed');
    return { type: e.data[0], payload: e.data.subarray(5) };
  }

  send(data) { this.ws.send(data); }
  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

async function connectAndAnswer(url, device) {
  const peer = new Peer(url);
  await peer.opened;
  const first = await peer.next();
  check(first.type === MSG.AUTH_CHALLENGE, 'the host speaks first, with a challenge');
  const challenge = parseChallenge(first.payload);
  const hs = await ClientHandshake.create({
    challengePayload: first.payload, deviceKey: device.publicRaw, caps: WEB_CAPS,
    name: 'Interop test browser', sign: device.sign, ephemeral: await generateEphemeral(),
  });
  peer.send(frame(MSG.AUTH_RESPONSE, hs.response));
  return { peer, hs, challenge };
}

async function run() {
  check(typeof WebSocket === 'function', 'this Node has a global WebSocket (Node 22 or later)');
  check(globalThis.crypto && globalThis.crypto.subtle, 'this Node has crypto.subtle');
  check(binary && Number.isInteger(port) && port >= 1024, 'the binary path and a port were given');

  const stateDir = mkdtempSync(join(tmpdir(), 'clamshell-interop-'));
  const env = { ...process.env, CLAMSHELL_STATE_DIR: stateDir };
  let host = null;
  const peers = [];
  try {
    // Start the host and wait for its one line.
    host = spawn(binary, ['auth-interop-host', String(port)], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let hostOut = '';
    host.stdout.on('data', (d) => { hostOut += d; });
    host.stderr.on('data', () => {});
    const started = Date.now();
    while (!hostOut.includes('listening')) {
      check(host.exitCode === null, `the host stayed up (it said: ${hostOut.trim()})`);
      check(Date.now() - started < 30000, 'the host started within 30 s');
      await new Promise((r) => setTimeout(r, 100));
    }
    const url = `ws://127.0.0.1:${port}`;
    const device = await loadDeviceKey(memoryStore());
    const fingerprint = await fingerprintOfKey(device.publicRaw);

    // 1 and 2: the challenge asks for approval; the answer gets a verified pending.
    const one = await connectAndAnswer(url, device);
    peers.push(one.peer);
    check((one.challenge.caps & 1) !== 0, 'the challenge says approval is required');
    const hostId = await keyId(one.challenge.identity);
    const first = await one.peer.next();
    check(first.type === MSG.AUTH_RESULT, 'a result follows the response');
    check(await one.hs.statusOfResult(first.payload) === STATUS.pending, 'the first verified result is pending');
    console.log(`ok 1-2: challenge asks for approval; verified pending for ${fingerprint}`);

    // 3: approve on the host, get a verified accepted on the same connection.
    const approve = spawnSync(binary, ['approve', fingerprint], { env, encoding: 'utf8' });
    check(approve.status === 0, `approve exits 0 (${(approve.stdout || '').trim()} ${(approve.stderr || '').trim()})`);
    let status = STATUS.pending;
    while (status === STATUS.pending) {
      const m = await one.peer.next();
      check(m.type === MSG.AUTH_RESULT, 'only results arrive before accepted');
      status = await one.hs.statusOfResult(m.payload);
    }
    check(status === STATUS.accepted, 'the next result that is not pending is accepted');
    console.log('ok 3: approved on the host, verified accepted on the same connection');

    // 4: the session is sealed: HOST_INFO first, then a PING round trip.
    const material = await one.hs.sessionMaterial();
    const opener = new Opener(await importSessionKey(material.hostToClient));
    const sealer = new Sealer(await importSessionKey(material.clientToHost), (d) => one.peer.send(d), {});
    const secure = await one.peer.next();
    check(secure.type === MSG.SECURE, 'the session starts with a SECURE message');
    const info = await opener.open(secure.payload);
    check(info.type === MSG.HOST_INFO, 'the first message inside is HOST_INFO');
    const hostInfo = JSON.parse(new TextDecoder().decode(info.payload));
    check(hostInfo.hostId === hostId, 'HOST_INFO names the host that signed the challenge');
    sealer.seal(frame(MSG.PING));
    await sealer.settled();
    const echo = await one.peer.next();
    check(echo.type === MSG.SECURE, 'the echo is SECURE');
    const inner = await opener.open(echo.payload);
    check(inner.type === MSG.PING && inner.payload.length === 0, 'the echo is an empty PING');
    console.log('ok 4: HOST_INFO opened; sealed PING round trip');

    // 5: revoke on the host; it closes this connection.
    const revoke = spawnSync(binary, ['revoke', fingerprint], { env, encoding: 'utf8' });
    check(revoke.status === 0, `revoke exits 0 (${(revoke.stdout || '').trim()} ${(revoke.stderr || '').trim()})`);
    const until = Date.now() + 5000;
    for (;;) {
      const left = until - Date.now();
      check(left > 0, 'the host closed the connection within 5 s of revoke');
      const m = await one.peer.next(left);
      if (m.closed) break;
    }
    console.log('ok 5: host closed the connection after revoke');

    // 6: the same key again is told denied, verified.
    const two = await connectAndAnswer(url, device);
    peers.push(two.peer);
    const result = await two.peer.next();
    check(result.type === MSG.AUTH_RESULT, 'a result follows the response');
    check(await two.hs.statusOfResult(result.payload) === STATUS.denied, 'the revoked device gets a verified denied');
    console.log('ok 6: a revoked device gets a verified denied');
  } finally {
    for (const p of peers) p.close();
    if (host && host.exitCode === null) {
      host.kill('SIGTERM');
      await new Promise((r) => { host.once('exit', r); setTimeout(r, 6000); });
      if (host.exitCode === null) host.kill('SIGKILL');
    }
    rmSync(stateDir, { recursive: true, force: true });
  }
}

run().then(() => { console.log('PASS: auth.js and the Mac host agree'); process.exit(0); }, (e) => {
  console.log(`FAIL: ${e && e.message ? e.message : e}`);
  process.exit(1);
});
