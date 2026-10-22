import test from 'node:test';
import assert from 'node:assert/strict';
import { AppModel } from '../.build/app/AppModel.js';
import { SavedAccount } from '../.build/app/Contracts.js';
import { createAuthHarness, MemoryStore, settleUntil } from './helpers/auth-harness.mjs';

const idsLogin = 'https://ids.xmu.edu.cn/authserver/login?service=https%3A%2F%2Flnt.xmu.edu.cn';
const courseHome = 'https://lnt.xmu.edu.cn/user/index';
const mobileHome = 'https://c-mobile.xmu.edu.cn/home';

// Reproduce the school's service choice: accepted mobile logins land in c-mobile,
// which cannot supply the LNT session required by the native course API.
function schoolReturnURL(userAgent) {
  return /Mobile/i.test(userAgent) ? mobileHome : courseHome;
}

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
  assert.equal(inputs.password.disabled, true);
  assert.equal(state.nodes.get('saltPassword').value, 'offline-encrypted-password');
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
  assert.ok(state.requests.every(request => request.headers['User-Agent'] === state.loads[0].userAgent));
  assert.doesNotMatch(state.loads[0].userAgent, /Mobile/i);
});
}

for (const manual of [false, true]) {
test(`${manual ? 'captcha' : 'automatic'} login sets desktop identity before loading and returns from SSO to native courses`, async t => {
  const harness = await homeFixture(t);
  const { auth, state, model, navigate, showPasswordForm } = harness;
  const defaultUserAgent = auth.controller.getUserAgent();
  assert.equal(schoolReturnURL(defaultUserAgent), mobileHome, 'The default phone identity reproduces the wrong service redirect');
  showPasswordForm({ captcha: manual, layout: 'desktop' });
  const redirects = [];
  state.onLoad = () => navigate(idsLogin);
  const finishSSO = () => {
    const userAgent = auth.controller.getUserAgent();
    const url = schoolReturnURL(userAgent);
    redirects.push(url);
    state.ready = url === courseHome;
    navigate(url, { begin: false });
  };
  state.onSubmit = finishSSO;
  const entering = model.run(() => model.enterCourses());
  if (manual) {
    await settleUntil(() => auth.manual, 'School captcha must expose its original page');
    finishSSO();
  }
  await entering;

  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(model.courses.length, 1);
  assert.equal(auth.active, false);
  assert.deepEqual(redirects, [courseHome]);
  assert.equal(state.submitted, manual ? 0 : 1);
  assert.equal(state.userAgentChanges.length, 1);
  assert.equal(state.userAgentChanges[0].controller, state.loads[0].controller);
  assert.equal(state.userAgentChanges[0].value, state.loads[0].userAgent);
  assert.deepEqual(state.events.slice(0, 3), ['clear-cookies', 'user-agent', 'load']);
  assert.ok(state.requests.every(request => request.headers['User-Agent'] === state.loads[0].userAgent));
  assert.ok(state.requests.every(request => request.headers.Cookie === 'session=offline-school-session'));
  assert.deepEqual(state.cleared, [true, true]);
});
}

test('a document loading longer than ten seconds stays automatic and opens native courses when ready', async t => {
  const { auth, state, document, elapsed, model, navigate, showPasswordForm } = await homeFixture(t);
  document.readyState = 'loading';
  state.onLoad = () => navigate(idsLogin);
  state.onEvaluate = () => {
    if (elapsed() >= 13000 && document.readyState === 'loading') {
      document.readyState = 'complete';
      showPasswordForm({ layout: 'desktop' });
    }
  };
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());

  assert.ok(elapsed() >= 13000);
  assert.ok(state.scriptResults.includes('loading'));
  assert.equal(state.transitions.some(transition => transition.manual), false);
  assert.equal(state.submitted, 1);
  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(auth.active, false);
});

test('school initialization lasting twenty seconds uses the automatic phase instead of a separate early cutoff', async t => {
  const { auth, state, elapsed, model, navigate, showPasswordForm } = await homeFixture(t);
  const inputs = showPasswordForm({ layout: 'desktop' });
  state.pageWindow.jQuery.isReady = false;
  const earlyAttempts = [];
  state.onLoad = () => navigate(idsLogin);
  state.onEvaluate = () => {
    if (elapsed() < 20000) {
      earlyAttempts.push([inputs.username.value, inputs.password.value, state.clicks]);
    } else { state.pageWindow.jQuery.isReady = true; }
  };
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());

  assert.ok(elapsed() >= 20000);
  assert.ok(earlyAttempts.length > 60);
  assert.ok(earlyAttempts.every(values => values[0] === '' && values[1] === '' && values[2] === 0));
  assert.ok(state.scriptResults.includes('initializing'));
  assert.equal(state.transitions.some(transition => transition.manual), false);
  assert.equal(state.submitted, 1);
  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(auth.active, false);
});

test('the default QR page waits for its document then follows the original password-login link automatically', async t => {
  const { auth, state, document, elapsed, model, navigate, showAccountLoginLink, showPasswordForm } = await homeFixture(t);
  const accountLogin = 'https://ids.xmu.edu.cn/authserver/login?type=userNameLogin&service=https%3A%2F%2Flnt.xmu.edu.cn';
  showAccountLoginLink({ href: accountLogin });
  document.readyState = 'loading';
  const earlyClicks = [];
  state.onLoad = () => navigate(idsLogin);
  state.onEvaluate = () => {
    if (elapsed() < 13000) { earlyClicks.push(state.loginModeSwitches.length); }
    else { document.readyState = 'complete'; }
  };
  state.onLoginModeSwitch = url => {
    assert.equal(document.readyState, 'complete');
    showPasswordForm({ layout: 'desktop' });
    navigate(url);
  };
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());

  assert.ok(earlyClicks.length > 40);
  assert.ok(earlyClicks.every(count => count === 0));
  assert.deepEqual(state.loginModeSwitches, [accountLogin]);
  assert.ok(state.scriptResults.includes('loading'));
  assert.ok(state.scriptResults.includes('switch'));
  assert.equal(state.transitions.some(transition => transition.manual), false);
  assert.equal(state.clicks, 1);
  assert.equal(state.submitted, 1);
  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(auth.active, false);
});

test('an unknown completed form ends at the automatic timeout without exposing a manual webpage', async t => {
  const { auth, state, elapsed, model, navigate } = await homeFixture(t);
  state.onLoad = () => navigate(idsLogin);
  await model.run(() => model.enterCourses());

  assert.ok(elapsed() > 40000 && elapsed() < 45000);
  assert.equal(state.transitions.some(transition => transition.manual), false);
  assert.equal(auth.manual, false);
  assert.equal(auth.active, false);
  assert.equal(model.busy, false);
  assert.equal(model.screen, 'home');
  assert.equal(model.currentSession, undefined);
  assert.match(model.notice, /登录超时/);
  assert.doesNotMatch(model.notice, /网页登录超时/);
  assert.equal(state.clicks, 0);
  assert.equal(state.requests.length, 0);
});

test('a slow password-mode navigation clicks the original QR link only once while its old document remains', async t => {
  const { auth, state, elapsed, model, navigate, showAccountLoginLink, showPasswordForm } = await homeFixture(t);
  const accountLogin = 'https://ids.xmu.edu.cn/authserver/login?type=userNameLogin';
  const link = showAccountLoginLink({ href: accountLogin });
  let firstSwitchAt;
  let destinationLoaded = false;
  state.onLoad = () => navigate(idsLogin);
  state.onLoginModeSwitch = () => { firstSwitchAt ??= elapsed(); };
  state.onEvaluate = () => {
    if (!destinationLoaded && firstSwitchAt !== undefined && elapsed() - firstSwitchAt >= 13000) {
      destinationLoaded = true;
      showPasswordForm({ layout: 'desktop' });
      navigate(accountLogin);
    }
  };
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());

  assert.ok(elapsed() - firstSwitchAt >= 13000);
  assert.equal(link.getAttribute('data-free-rollcall-switch'), 'pending');
  assert.deepEqual(state.loginModeSwitches, [accountLogin]);
  assert.ok(state.scriptResults.filter(result => result === 'loading').length > 40);
  assert.equal(state.transitions.some(transition => transition.manual), false);
  assert.equal(state.submitted, 1);
  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(auth.active, false);
});

test('the password-mode navigation marker belongs to its document and permits a new QR document to switch', async t => {
  const { auth, state, model, navigate, showAccountLoginLink, showPasswordForm } = await homeFixture(t);
  const accountLogin = 'https://ids.xmu.edu.cn/authserver/login?type=userNameLogin';
  const links = [showAccountLoginLink({ href: accountLogin })];
  state.onLoad = () => navigate(idsLogin);
  state.onLoginModeSwitch = url => {
    if (state.loginModeSwitches.length === 1) {
      // A school redirect replaced the first QR document; its marker must not leak into this one.
      links.push(showAccountLoginLink({ href: accountLogin }));
      assert.equal(links[1].getAttribute('data-free-rollcall-switch'), null);
      navigate(idsLogin);
    } else {
      showPasswordForm({ layout: 'desktop' });
      navigate(url);
    }
  };
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());

  assert.notEqual(links[0], links[1]);
  assert.ok(links.every(link => link.getAttribute('data-free-rollcall-switch') === 'pending'));
  assert.deepEqual(state.loginModeSwitches, [accountLogin, accountLogin]);
  assert.equal(state.transitions.some(transition => transition.manual), false);
  assert.equal(state.submitted, 1);
  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(auth.active, false);
});

test('a captcha discovered after automatic QR switching exposes verification and then returns to native courses', async t => {
  const { auth, state, model, navigate, showAccountLoginLink, showPasswordForm } = await homeFixture(t);
  showAccountLoginLink();
  state.onLoad = () => navigate(idsLogin);
  state.onLoginModeSwitch = () => {
    assert.equal(auth.manual, false, 'A QR login page alone is not a manual-verification condition');
    showPasswordForm({ layout: 'desktop', captcha: true });
    navigate('https://ids.xmu.edu.cn/authserver/login?type=userNameLogin');
  };
  const entering = model.run(() => model.enterCourses());
  await settleUntil(() => auth.manual, 'Only the real captcha must switch to the school verification page');

  assert.equal(state.loginModeSwitches.length, 1);
  assert.equal(state.clicks, 0);
  assert.equal(state.submitted, 0);
  assert.equal(model.screen, 'home');
  assert.equal(model.busy, true);
  state.ready = true;
  navigate(courseHome, { begin: false });
  await entering;

  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(model.courses.length, 1);
  assert.equal(auth.active, false);
});

test('desktop SSO still clears each account cookies and keeps returned clients isolated', async t => {
  const harness = createAuthHarness();
  t.after(() => harness.dispose());
  const { auth, state, navigate, showPasswordForm } = harness;
  const sessions = [];
  const cookies = ['session=first-account', 'session=second-account'];
  for (const [index, username] of ['student', 'second-student'].entries()) {
    const account = new SavedAccount();
    account.username = username;
    state.profile = { id: String(42 + index), user_no: username, name: '离线用户' };
    state.cookie = cookies[index];
    showPasswordForm({ layout: 'desktop' });
    state.onLoad = () => {
      assert.equal(state.ready, false, 'Old Web cookies must be cleared before loading another account');
      navigate(idsLogin);
    };
    state.onSubmit = () => {
      state.ready = true;
      navigate(schoolReturnURL(auth.controller.getUserAgent()), { begin: false });
    };
    sessions.push(await auth.authenticate(account, 'offline-password', false));
    assert.equal(sessions[index].profile.id, String(42 + index));
    assert.equal(sessions[index].accountID, account.id);
    assert.equal(state.ready, false, 'The Web cookie context must be cleared after session handoff');
  }
  assert.deepEqual(state.cleared, [true, true, true, true]);
  assert.deepEqual(state.loads.map(load => load.cleared), [1, 3]);
  assert.equal(state.userAgentChanges.length, 2);
  assert.notEqual(state.loads[0].controller, state.loads[1].controller);
  await sessions[0].client.currentSemesterCourses();
  await sessions[1].client.currentSemesterCourses();
  assert.deepEqual(state.requests.map(request => request.headers.Cookie), [
    ...cookies, cookies[0], cookies[0], cookies[1], cookies[1]
  ]);
  assert.ok(state.requests.every(request => request.headers['User-Agent'] === state.loads[0].userAgent));
});

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

test('navigation swallowing the submit result never fills or submits the accepted school form again', async t => {
  for (const lostResult of ['null', '']) {
    const { state, model, navigate, showPasswordForm } = await homeFixture(t);
    const inputs = showPasswordForm();
    let swallowed = false;
    let laterReads = 0;
    state.onLoad = () => navigate(idsLogin);
    state.onScriptResult = result => {
      if (result === 'submitted' && !swallowed) { swallowed = true; return lostResult; }
      return JSON.stringify(result);
    };
    state.onEvaluate = () => {
      // The old document can still be observed while the network navigation is pending.
      if (state.submitted > 0 && ++laterReads === 4) {
        state.ready = true;
        navigate(courseHome, { begin: false });
      }
    };
    await model.run(() => model.enterCourses());
    assert.equal(swallowed, true);
    assert.equal(model.notice, '');
    assert.equal(model.screen, 'courses');
    assert.equal(state.clicks, 1, `Only one school click is allowed after result ${JSON.stringify(lostResult)}`);
    assert.equal(state.submitted, 1);
    assert.equal(inputs.username.events.filter(event => event === 'input').length, 1);
    assert.equal(inputs.password.events.filter(event => event === 'input').length, 1);
  }
});

test('hidden server rejection after a full-page submit is reported even when its result was lost', async t => {
  const { auth, state, model, navigate, showPasswordForm, showError } = await homeFixture(t);
  showPasswordForm();
  let swallowed = false;
  state.onLoad = () => navigate(idsLogin);
  state.onScriptResult = result => {
    if (result === 'submitted' && !swallowed) { swallowed = true; return 'null'; }
    return JSON.stringify(result);
  };
  state.onSubmit = () => {
    showPasswordForm();
    showError('用户名或密码错误', { visible: false });
    navigate(idsLogin);
  };
  await model.run(() => model.enterCourses());
  assert.equal(swallowed, true);
  assert.equal(auth.active, false);
  assert.equal(model.busy, false);
  assert.equal(model.screen, 'home');
  assert.match(model.notice, /账号或密码错误/);
  assert.equal(state.clicks, 1);
  assert.equal(state.submitted, 1);
  assert.equal(state.requests.length, 0);
});

test('jQuery ready alone does not bypass the school mode switch from the first hidden phone form', async t => {
  const { state, model, navigate, showPasswordForm } = await homeFixture(t);
  const inputs = showPasswordForm({ hiddenLoginMode: 'dynamicLogin' });
  assert.equal(state.pageWindow.jQuery.isReady, true);
  const earlyAttempts = [];
  state.onEvaluate = () => {
    if (state.scriptStarts.length <= 3) {
      earlyAttempts.push([inputs.username.value, inputs.password.value, state.clicks]);
    } else { inputs.hiddenMode.remove(); }
  };
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());
  assert.deepEqual(earlyAttempts, [['', '', 0], ['', '', 0], ['', '', 0]]);
  assert.ok(state.scriptResults.includes('initializing'));
  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
  assert.equal(state.clicks, 1);
  assert.equal(state.submitted, 1);
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

for (const source of ['hidden server field', 'visible school toast']) {
test(`${source} reports rejected school credentials instead of waiting indefinitely`, async t => {
  const { auth, state, model, navigate, showPasswordForm, showError, showToast } = await homeFixture(t);
  showPasswordForm();
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => {
    if (source === 'hidden server field') { showError('用户名或密码错误', { visible: false }); }
    else { showToast('用户名或密码错误'); }
  };
  await model.run(() => model.enterCourses());
  assert.equal(auth.active, false);
  assert.equal(model.busy, false);
  assert.equal(model.screen, 'home');
  assert.match(model.notice, /账号或密码错误/);
  assert.equal(state.clicks, 1);
  assert.equal(state.submitted, 1);
  assert.equal(state.requests.length, 0);
});
}

const readinessCases = [
  ['jQuery', state => {
    const original = state.pageWindow.jQuery;
    delete state.pageWindow.jQuery;
    delete state.pageWindow.$;
    return () => { state.pageWindow.jQuery = original; state.pageWindow.$ = original; };
  }],
  ['jQuery ready handler', state => {
    state.pageWindow.jQuery.isReady = false;
    return () => { state.pageWindow.jQuery.isReady = true; };
  }],
  ...['checkForm', 'encryptPassword'].map(name => [name, state => {
    const original = state.pageWindow[name];
    delete state.pageWindow[name];
    return () => { state.pageWindow[name] = original; };
  }]),
  ['form execution field', state => {
    const field = state.nodes.get('execution');
    const parent = field.parentElement;
    field.remove();
    return () => parent.append(field);
  }],
  ['password login mode', state => {
    state.nodes.get('cllt').value = 'dynamicLogin';
    return () => { state.nodes.get('cllt').value = 'userNameLogin'; };
  }],
  ['password encryption salt', state => {
    state.nodes.get('pwdEncryptSalt').value = '';
    return () => { state.nodes.get('pwdEncryptSalt').value = 'offline-salt'; };
  }]
];

for (const [prerequisite, defer] of readinessCases) {
test(`complete DOM waits for school ${prerequisite} before filling or submitting`, async t => {
  const { state, model, navigate, showPasswordForm } = await homeFixture(t);
  const inputs = showPasswordForm();
  const finishInitializing = defer(state);
  const earlyAttempts = [];
  state.onEvaluate = () => {
    if (state.scriptStarts.length <= 3) {
      earlyAttempts.push([inputs.username.value, inputs.password.value, state.clicks]);
    } else { finishInitializing(); }
  };
  state.onLoad = () => navigate(idsLogin);
  state.onSubmit = () => { state.ready = true; navigate(courseHome, { begin: false }); };
  await model.run(() => model.enterCourses());
  assert.deepEqual(earlyAttempts, [['', '', 0], ['', '', 0], ['', '', 0]]);
  assert.ok(state.scriptResults.includes('initializing'));
  assert.equal(state.clicks, 1);
  assert.equal(state.submitted, 1);
  assert.equal(model.notice, '');
  assert.equal(model.screen, 'courses');
});
}

for (const rejection of ['handler not bound', 'validation returned false', 'encrypted field only', 'disabled password only']) {
test(`original school click with ${rejection} cannot claim submission or repeatedly click`, async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  const inputs = showPasswordForm();
  if (rejection === 'handler not bound') { state.bindSubmitHandler = false; }
  else {
    state.onCheckForm = () => {
      if (rejection === 'encrypted field only') { state.nodes.get('saltPassword').value = 'offline-encrypted-password'; }
      if (rejection === 'disabled password only') { inputs.password.disabled = true; }
      return false;
    };
  }
  state.onLoad = () => navigate(idsLogin);
  await model.run(() => model.enterCourses());
  assert.equal(auth.active, false);
  assert.equal(model.busy, false);
  assert.equal(model.screen, 'home');
  assert.notEqual(model.notice, '');
  assert.doesNotMatch(model.notice, /超时/);
  assert.equal(inputs.password.disabled, rejection === 'disabled password only');
  assert.equal(state.nodes.get('saltPassword').value, rejection === 'encrypted field only' ? 'offline-encrypted-password' : '');
  assert.equal(state.clicks, 1);
  assert.equal(state.submitted, 0);
  assert.ok(state.scriptResults.includes('blocked'));
  assert.equal(state.scriptResults.includes('submitted'), false);
  assert.equal(state.requests.length, 0);
});
}

test('school handler encrypting a password before opening its slider still requires manual verification', async t => {
  const { auth, state, model, navigate, showPasswordForm } = await homeFixture(t);
  const inputs = showPasswordForm();
  state.onCheckForm = () => { state.pageWindow.needCaptcha = true; return true; };
  state.onLoad = () => navigate(idsLogin);
  const entering = model.run(() => model.enterCourses());
  await settleUntil(() => auth.manual, 'Slider opened by the original school handler must expose verification');
  assert.equal(inputs.password.disabled, true);
  assert.equal(state.nodes.get('saltPassword').value, 'offline-encrypted-password');
  assert.equal(state.clicks, 1);
  assert.equal(state.submitted, 0);
  assert.equal(state.scriptResults.includes('submitted'), false);
  assert.equal(model.screen, 'home');
  state.ready = true;
  navigate(courseHome, { begin: false });
  await entering;
  assert.equal(model.notice, '');
  assert.equal(auth.active, false);
  assert.equal(model.screen, 'courses');
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
