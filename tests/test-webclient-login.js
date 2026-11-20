// Tests for webclient/login.js: the LOGIN_CREDENTIALS payload and its limits,
// the 3 second limiter, and the password-manager-friendly form. Synthetic values only.
import { test } from 'node:test';
import assert from 'node:assert';
import * as L from '../Sources/Clamshell/Resources/webclient/login.js';
import { CAP } from '../Sources/Clamshell/Resources/webclient/input.js';
import { WEB_CAPS } from '../Sources/Clamshell/Resources/webclient/auth.js';

test('message type and capability bit match PROTOCOL.md', () => {
  assert.strictEqual(L.LOGIN_CREDENTIALS, 0x5C);
  assert.strictEqual(CAP.loginCredentials, 1 << 8);
  assert.notStrictEqual(WEB_CAPS & CAP.loginCredentials, 0, 'the web client sets bit 8');
});

test('payload is the documented JSON', () => {
  const body = L.loginPayload('testuser', 'not-a-real-password');
  assert.deepStrictEqual(JSON.parse(new TextDecoder().decode(body)), { v: 1, kind: 'login', user: 'testuser', password: 'not-a-real-password' });
});

test('fields the host would ignore are refused here', () => {
  assert.strictEqual(L.loginPayload('', 'x'), null);
  assert.strictEqual(L.loginPayload('x', ''), null);
  assert.strictEqual(L.loginPayload('a\tb', 'x'), null, 'tab');
  assert.strictEqual(L.loginPayload('x', 'a\nb'), null, 'line break');
  assert.strictEqual(L.loginPayload('x', 'a\u007fb'), null, 'DEL');
  assert.strictEqual(L.loginPayload('x', 'a\u0085b'), null, 'C1 control');
  assert.strictEqual(L.loginPayload('x'.repeat(513), 'x'), null);
  assert.notStrictEqual(L.loginPayload('x'.repeat(512), 'y'.repeat(512)), null);
  // 512 bytes counts bytes, not characters: 257 two-byte characters is too long.
  assert.strictEqual(L.validField('é'.repeat(257)), false);
  assert.strictEqual(L.validField('é'.repeat(256)), true);
  assert.strictEqual(L.loginPayload(null, 'x'), null);
});

test('limiter allows one message per 3 seconds', () => {
  let t = 1000;
  const lim = new L.LoginLimiter(() => t);
  assert.strictEqual(lim.waitMs(), 0);
  assert.strictEqual(lim.tryTake(), true);
  t += 1000;
  assert.strictEqual(lim.tryTake(), false);
  assert.strictEqual(lim.waitMs(), 2000);
  t += 2000;
  assert.strictEqual(lim.tryTake(), true);
});

test('loginProblem explains bad input and waiting', () => {
  const lim = new L.LoginLimiter(() => 0);
  assert.match(L.loginProblem('', 'x', lim), /Enter the account name/);
  assert.strictEqual(L.loginProblem('u', 'p', lim), null);
  lim.tryTake();
  assert.match(L.loginProblem('u', 'p', lim), /Wait 3 s/);
});

// A minimal DOM: just what buildCredentialForm touches.
class El {
  constructor(tag) { this.tag = tag; this.attrs = {}; this.children = []; this.handlers = {}; this.value = ''; }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...c) { this.children.push(...c); }
  addEventListener(t, f) { this.handlers[t] = f; }
}
const fakeDoc = { createElement: (t) => new El(t) };

test('form is a real form that a password manager fills', () => {
  let got = null;
  const f = L.buildCredentialForm(fakeDoc, { id: 'loginForm', submitLabel: 'Log in', onSubmit: (u, p) => { got = [u, p]; } });
  assert.strictEqual(f.form.tag, 'form');
  assert.strictEqual(f.form.id, 'loginForm');
  assert.strictEqual(f.user.attrs.autocomplete, 'username');
  assert.strictEqual(f.user.name, 'username');
  assert.ok(f.user.id);
  assert.strictEqual(f.pass.attrs.autocomplete, 'current-password');
  assert.strictEqual(f.pass.type, 'password');
  assert.strictEqual(f.pass.name, 'password');
  assert.ok(f.pass.id && f.pass.id !== f.user.id);
  assert.strictEqual(f.submitButton.type, 'submit');
  assert.deepStrictEqual(f.form.children, [f.user, f.pass, f.submitButton]);
  f.user.value = 'testuser'; f.pass.value = 'secret-for-test';
  let prevented = false;
  f.form.handlers.submit({ preventDefault: () => { prevented = true; } });
  assert.ok(prevented, 'the page never navigates');
  assert.deepStrictEqual(got, ['testuser', 'secret-for-test']);
});

test('nothing here stores the password', async () => {
  const { readFileSync } = await import('node:fs');
  const src = readFileSync(new URL('../Sources/Clamshell/Resources/webclient/login.js', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /localStorage|sessionStorage|indexedDB|console\./);
});
