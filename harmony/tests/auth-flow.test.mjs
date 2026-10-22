import test from 'node:test';
import assert from 'node:assert/strict';
import { AppModel } from '../.build/app/AppModel.js';
import { SavedAccount } from '../.build/app/Contracts.js';
import { createAuthHarness, MemoryStore, settleUntil } from './helpers/auth-harness.mjs';

const idsLogin = 'https://ids.xmu.edu.cn/authserver/login?service=https%3A%2F%2Flnt.xmu.edu.cn';
const courseHome = 'https://lnt.xmu.edu.cn/user/index';

async function homeFixture(t) {
  const harness = createAuthHarness();
  t.after(() => harness.dispose());
  const store = new MemoryStore();
  const model = new AppModel(store, harness.auth);
  await model.initialize();
  await model.saveAccount(undefined, 'student', 'test-password', '离线账号');
  return { ...harness, store, model };
}

for (const layout of ['mobile', 'desktop']) {
test(`${layout} saved-account login fills visible password form before PageEnd and opens native courses`, async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  const inputs = showPasswordForm({ layout });
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => {
    state.ready = true;
    // A SPA route can change the controller URL without another navigation callback.
    navigate(courseHome, { begin: false });
  };
  await model.run(() => model.enterCourses());

  assert.equal(model.notice, '');
  assert.equal(model.busy, false);
  assert.equal(auth.active, false);
  assert.equal(model.screen, 'courses');
  assert.equal(model.courses[0]?.name, '离线回归测试课程');
  assert.equal(model.currentSession?.profile.id, '42');
  assert.equal(state.submitted, 1);
  assert.equal(inputs.username.value, 'student');
  assert.equal(inputs.password.value, 'test-password');
  assert.equal(inputs.hiddenUsername.value, '');
  assert.equal(inputs.hiddenPassword.value, '');
  assert.ok(inputs.username.events.includes('input'));
  assert.ok(inputs.password.events.includes('change'));
  assert.ok(state.scriptResults.includes('filled'));
  assert.ok(state.scriptResults.includes('submitted'));
  assert.equal(state.events.includes('end'), false);
  assert.deepEqual(state.requests.map(request => new URL(request.url).pathname), [
    '/api/profile', '/api/current-semester-info', '/api/my-courses'
  ]);
  assert.ok(state.requests.every(request => request.headers.Cookie === 'session=offline-school-session'));
  assert.ok(state.requests.every(request => request.headers['User-Agent'] === 'ArkWeb Offline Mobile Test'));
});
}

test('visible captcha automatically exposes webpage, verified SPA completion closes it and continues courses', async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  showPasswordForm({ captcha: true });
  state.onLoad = () => navigate(idsLogin);
  const entering = model.run(() => model.enterCourses());
  await settleUntil(() => auth.manual, 'Captcha must switch to webpage mode automatically');
  assert.equal(model.busy, true);
  assert.equal(auth.active, true);
  assert.equal(state.submitted, 0);
  assert.equal(state.requests.length, 0);

  // Represents the user finishing the school page; no synthetic page-end event is supplied.
  let confirmProfile;
  state.profileGate = new Promise(resolve => { confirmProfile = resolve; });
  state.ready = true;
  navigate(courseHome, { begin: false });
  await settleUntil(() => auth.verifying && state.requests.length > 0, 'Returned school login must enter a verification phase');
  assert.equal(auth.active, true);
  assert.equal(model.screen, 'home');
  assert.equal(model.busy, true);
  assert.equal(model.currentSession, undefined);
  confirmProfile();
  await entering;
  assert.equal(model.notice, '');
  assert.equal(auth.active, false);
  assert.equal(model.busy, false);
  assert.equal(model.screen, 'courses');
  assert.equal(model.courses.length, 1);
  assert.equal(state.events.includes('end'), false);
});

test('hidden slider markup does not prevent automatic saved-account login', async t => {
  const { auth, state, model, navigate, showPasswordForm, showSliderChallenge } = await homeFixture(t);
  showPasswordForm();
  showSliderChallenge(false);
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());
  assert.equal(model.notice, '');
  assert.equal(auth.manual, false);
  assert.equal(state.submitted, 1);
  assert.equal(model.screen, 'courses');
});

test('temporary null script results before layout retry automatically instead of failing login', async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  showPasswordForm();
  state.rawScriptResults = [null, 'null'];
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());
  assert.equal(model.notice, '');
  assert.equal(auth.manual, false);
  assert.equal(state.rawScriptResults.length, 0);
  assert.equal(state.submitted, 1);
  assert.equal(model.screen, 'courses');
});

test('verified school session on a login ticket URL enters courses without waiting for another route', async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  showPasswordForm();
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => {
    state.ready = true;
    navigate('https://lnt.xmu.edu.cn/login?ticket=offline-ticket', { begin: false });
  };
  await model.run(() => model.enterCourses());
  assert.equal(model.notice, '');
  assert.equal(auth.active, false);
  assert.equal(model.screen, 'courses');
  assert.equal(model.courses.length, 1);
});

test('brief cookie propagation delay after school redirect is retried before native course handoff', async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  showPasswordForm();
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => {
    state.ready = true;
    state.cookieDelay = 3;
    navigate(courseHome, { begin: false });
  };
  await model.run(() => model.enterCourses());
  assert.equal(model.notice, '');
  assert.equal(auth.active, false);
  assert.equal(state.cookieReads.length, 4);
  assert.equal(model.screen, 'courses');
});

test('missing cookies after captcha completion end the handoff promptly and release home controls', async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  showPasswordForm({ captcha: true });
  state.onLoad = () => navigate(idsLogin);
  const entering = model.run(() => model.enterCourses());
  await settleUntil(() => auth.manual);
  state.ready = true;
  state.cookieDelay = Infinity;
  navigate(courseHome, { begin: false });
  await entering;
  assert.equal(auth.active, false);
  assert.equal(auth.verifying, false);
  assert.equal(model.busy, false);
  assert.equal(model.screen, 'home');
  assert.equal(model.currentSession, undefined);
  assert.match(model.notice, /未能确认学校登录状态/);
  assert.ok(state.cookieReads.length > 1 && state.cookieReads.length < 30);
  assert.equal(state.requests.length, 0);
});

test('incorrect saved credentials exit the login page and release the home operation gate', async t => {
  const { auth, state, model, navigate, showPasswordForm, showError } = await homeFixture(t);
  showPasswordForm();
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => showError('用户名或密码错误');
  await model.run(() => model.enterCourses());
  assert.equal(auth.active, false);
  assert.equal(model.busy, false);
  assert.equal(model.screen, 'home');
  assert.equal(model.currentSession, undefined);
  assert.match(model.notice, /账号或密码错误/);
  assert.equal(state.submitted, 1);
  assert.equal(state.requests.length, 0);
});

test('manual captcha completion cannot attach a different student to the selected account', async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  showPasswordForm({ captcha: true });
  state.onLoad = () => navigate(idsLogin);
  const entering = model.run(() => model.enterCourses());
  await settleUntil(() => auth.manual);
  state.profile = { id: '99', user_no: 'another-student', name: '其他用户' };
  state.ready = true;
  navigate(courseHome, { begin: false });
  await entering;
  assert.equal(auth.active, false);
  assert.equal(model.busy, false);
  assert.equal(model.currentSession, undefined);
  assert.equal(model.screen, 'home');
  assert.match(model.notice, /账号不一致/);
  assert.deepEqual(state.requests.map(request => new URL(request.url).pathname), ['/api/profile']);
});

test('late JavaScript result after cancelling an old login cannot submit or replace a new session', async t => {
  const harness = createAuthHarness();
  t.after(() => harness.dispose());
  const { auth, state, navigate, showPasswordForm } = harness;
  const account = new SavedAccount();
  account.username = 'student';
  showPasswordForm();
  state.onLoad = () => navigate(idsLogin);
  const oldControllerIndex = state.controllers.length;
  let releaseOldScript;
  const oldScript = new Promise(resolve => { releaseOldScript = resolve; });
  state.onEvaluate = (script, controller) => {
    if (controller === state.controllers[oldControllerIndex]) { return oldScript; }
  };
  const first = auth.authenticate(account, 'old-password', false);
  const cancelled = assert.rejects(first, error => error.code === 'cancelled');
  await settleUntil(() => state.scriptStarts.length > 0);
  auth.cancel();
  await cancelled;

  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  const nextLogin = auth.authenticate(account, 'new-password', false);
  releaseOldScript();
  const next = await nextLogin;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(next.accountID, account.id);
  assert.equal(next.profile.id, '42');
  assert.equal(state.submitted, 1);
  assert.equal(state.nodes.get('password').value, 'new-password');
  assert.equal(auth.active, false);
  assert.equal(state.requests.length, 1);
});
