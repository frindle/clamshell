// Tests for Sources/Clamshell/Resources/webclient/hello.js
import { test } from 'node:test';
import assert from 'node:assert';
import * as H from '../Sources/Clamshell/Resources/webclient/hello.js';

// ── Test 1: screenPx — landscape case (1366, 1024, dpr 2) ──────────────
test('screenPx returns correct landscape dimensions', () => {
  const result = H.screenPx(1366, 1024, 2);
  // pw = round(1366*2)=2732, ph = round(1024*2)=2048
  // max/min normalize: w=2732, h=2048 (already landscape)
  assert.strictEqual(result.w, 2732);
  assert.strictEqual(result.h, 2048);
});

// ── Test 2: helloPayload — 11-byte protocol message ────────────────────
test('helloPayload produces 11-byte array with correct encoding', () => {
  const buf = H.helloPayload(1366, 1024, 2);
  assert.strictEqual(buf.length, 11);
  assert.strictEqual(buf[0], 1);      // version
  assert.strictEqual(buf[1], 1);      // requestedCodec = H.264
  const dv = new DataView(buf.buffer, buf.byteOffset);
  const w = dv.getUint32(2, false);  // offset 2, big-endian
  const h = dv.getUint32(6, false);  // offset 6, big-endian
  assert.strictEqual(w, 2732);
  assert.strictEqual(h, 2048);
  assert.strictEqual(buf[10], 0);     // flags byte
});

// ── Test 3: clientDisplaysPayload — 9-byte payload (direct call) ───────
test('clientDisplaysPayload produces 9-byte array with correct encoding', () => {
  const buf = H.clientDisplaysPayload(1366, 1024, 2);
  assert.strictEqual(buf.length, 9);
  const dv = new DataView(buf.buffer, buf.byteOffset);
  const w = dv.getUint32(0, false);
  const h = dv.getUint32(4, false);
  assert.strictEqual(w, 2732);
  assert.strictEqual(h, 2048);
  assert.strictEqual(buf[8], 0);      // flags
});

// ── Test 4: debounce — rapid calls fire fn exactly once after delay ───
test('debounce fires the wrapped function exactly once after delay', () => {
  const timers = {
    setTimeout: null,
    clearTimeout: null,
    _callbacks: {},
    _nextId: 1,
    _lastId: undefined,
  };
  timers.setTimeout = (fn, ms) => {
    const id = timers._nextId++;
    timers._callbacks[id] = fn;
    timers._lastId = id;
    return id;
  };
  timers.clearTimeout = (id) => {
    delete timers._callbacks[id];
  };

  let callCount = 0;
  const args = [];
  const fn = (...a) => { callCount++; args.push(a); };
  const debounced = H.debounce(fn, 50, timers);

  // Schedule three quick calls — none should run synchronously
  debounced('a');
  debounced('b');
  debounced('c');

  assert.strictEqual(callCount, 0, 'debounce must NOT run fn synchronously');

  // Fire the last scheduled timeout manually
  if (timers._lastId !== undefined && timers._callbacks[timers._lastId]) {
    timers._callbacks[timers._lastId]();
  }

  assert.strictEqual(callCount, 1, 'should have fired exactly once');
  assert.deepStrictEqual(args, [['c']], 'should have used the last arguments');
});

// ── Test 5: attachResizeReporter — handler defers sendPayload via debounce ──
test('attachResizeReporter returns a handler that defers sendPayload via debounce', () => {
  let sentPayloads = [];
  const sendPayload = (p) => { sentPayloads.push(p); };

  const timers = {
    setTimeout: null,
    clearTimeout: null,
    _callbacks: {},
    _nextId: 1,
    _lastId: undefined,
  };
  timers.setTimeout = (fn, ms) => {
    const id = timers._nextId++;
    timers._callbacks[id] = fn;
    timers._lastId = id;
    return id;
  };
  timers.clearTimeout = (id) => {
    delete timers._callbacks[id];
  };

  const win = {
    innerWidth: 1366,
    innerHeight: 1024,
    devicePixelRatio: 2,
    addEventListener(type, handler) {
      assert.strictEqual(type, 'resize');
      assert.strictEqual(typeof handler, 'function');
      this._handler = handler;
    },
  };

  const handler = H.attachResizeReporter(win, sendPayload, 50, timers);

  // Must return a callable handler (not null)
  assert.strictEqual(typeof handler, 'function', 'handler must not be null');

  // Call the handler 3 times rapidly — nothing should send yet
  handler();
  handler();
  handler();

  assert.strictEqual(sentPayloads.length, 0, 'no sends before timer fires');

  // Fire the last scheduled timeout manually
  if (timers._lastId !== undefined && timers._callbacks[timers._lastId]) {
    timers._callbacks[timers._lastId]();
  }

  // After timer fires, exactly one 9-byte payload should be sent
  assert.strictEqual(sentPayloads.length, 1, 'exactly one send after timer fires');
  const p = sentPayloads[0];
  assert.strictEqual(p.length, 9, 'payload must be 9 bytes');
  const dv = new DataView(p.buffer, p.byteOffset);
  assert.strictEqual(dv.getUint32(0, false), 2732, 'width must match');
  assert.strictEqual(dv.getUint32(4, false), 2048, 'height must match');
  assert.strictEqual(p[8], 0, 'flags must be 0');
});

test('screenPx landscape-normalizes portrait, clamps small windows, defaults missing dpr', () => {
  assert.deepStrictEqual(H.screenPx(390, 844, 3), { w: 2532, h: 1170 });
  assert.deepStrictEqual(H.screenPx(300, 200, 1), { w: 640, h: 480 });
  assert.deepStrictEqual(H.screenPx(1000, 700, undefined), { w: 1000, h: 700 });
  assert.deepStrictEqual(H.screenPx(1000, 700, 0), { w: 1000, h: 700 });
  const b = H.helloPayload(390, 844, 3);
  const dv = new DataView(b.buffer, b.byteOffset);
  assert.strictEqual(dv.getUint32(2, false), 2532);
  assert.strictEqual(dv.getUint32(6, false), 1170);
});

test('attachResizeReporter registers the returned handler for resize', () => {
  const calls = [];
  const win = { innerWidth: 800, innerHeight: 600, devicePixelRatio: 1,
    addEventListener(type, fn) { calls.push([type, fn]); } };
  const timers = { setTimeout: () => 1, clearTimeout: () => {} };
  const h = H.attachResizeReporter(win, () => {}, 250, timers);
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(calls[0][0], 'resize');
  assert.strictEqual(calls[0][1], h);
});
