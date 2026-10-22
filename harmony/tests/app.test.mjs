import test from 'node:test';
import assert from 'node:assert/strict';
import { AppModel } from '../.build/app/AppModel.js';
import { AppData, AuthenticatedSession, AttendanceLog, LogResult, SavedAccount } from '../.build/app/Contracts.js';
import { Attendance, Course, UserProfile } from '../.build/core/Models.js';
import { APIResponse, TronclassClient } from '../.build/core/TronclassClient.js';
import { RollcallError } from '../.build/core/Errors.js';

function cloneData(source) {
  const data = new AppData();
  data.accounts = source.accounts.map(item => Object.assign(new SavedAccount(), item));
  data.logs = source.logs.map(item => Object.assign(new AttendanceLog(), item));
  return data;
}

class MemoryStore {
  data = new AppData();
  passwords = new Map();
  saves = 0;
  failOn = 0;
  async load() { return cloneData(this.data); }
  async save(data) {
    this.saves++;
    if (this.saves === this.failOn) { throw new Error('disk full'); }
    this.data = cloneData(data);
  }
  async readPassword(id) {
    if (!this.passwords.has(id)) { throw new Error('missing credential'); }
    return this.passwords.get(id);
  }
  async writePassword(id, password) { this.passwords.set(id, password); }
  async deletePassword(id) { this.passwords.delete(id); }
}

const time = Date.parse('2026-10-22T08:00:00+08:00');
function row(id = '90', extra = {}) {
  return { id, course_id: '10', rollcall_time: '2026-10-22T08:00:00+08:00',
    rollcall_status: 'active', is_expired: false, is_number: true, number_code: '0031',
    student_rollcalls: [{ student_id: '101', status: 'absent' }], ...extra };
}

class School {
  requests = [];
  historyRows = [row('90', { number_code: undefined, status: 'absent' })];
  activeRows = [];
  timetableRows = [row()];
  writeFailure;
  confirm = true;
  delay;
  failNextRead = false;
  async send(request) {
    this.requests.push(request);
    if (this.failNextRead && request.method !== 'PUT') {
      this.failNextRead = false;
      return new APIResponse(401, '{}');
    }
    if (this.delay && request.path === '/api/current-semester-info') { await this.delay; }
    let value;
    if (request.path === '/api/current-semester-info') {
      value = { semester: { id: 1 }, academic_year: { id: 2 } };
    } else if (request.path === '/api/my-courses') {
      value = { courses: [{ id: 10, display_name: '离线测试课程' }], has_more: false };
    } else if (request.path.startsWith('/api/course/')) {
      value = { rollcalls: this.historyRows, has_more: false };
    } else if (request.path === '/api/radar/rollcalls') {
      value = { rollcalls: this.activeRows };
    } else if (request.path.startsWith('/api/timetable_rollcalls?')) {
      value = { rollcalls: this.timetableRows };
    } else if (request.method === 'PUT') {
      if (this.writeFailure) { throw this.writeFailure; }
      if (this.confirm) { this.timetableRows = [row('90', { student_rollcalls: [{ student_id: '101', status: 'on_call' }] })]; }
      value = { success: true };
    } else { throw new Error('unexpected offline request ' + request.path); }
    return new APIResponse(200, JSON.stringify(value));
  }
}

class Authentication {
  calls = [];
  errors = [];
  delay;
  generation = 0;
  constructor(school) { this.school = school; }
  async authenticate(account, password, forceManual) {
    this.calls.push({ id: account.id, password, forceManual });
    if (this.delay) { await this.delay; }
    if (this.errors.length > 0) { throw this.errors.shift(); }
    return new AuthenticatedSession(account.id, `session-${++this.generation}`,
      new UserProfile('101', account.username, '离线用户'), new TronclassClient(this.school));
  }
  cancel() {}
}

async function fixture({ login = true } = {}) {
  const store = new MemoryStore();
  const school = new School();
  const auth = new Authentication(school);
  const model = new AppModel(store, auth);
  await model.initialize();
  await model.saveAccount(undefined, 'student-a', ' secret ', '测试账号');
  const id = model.accounts[0].id;
  if (login) { await model.login(id); }
  return { store, school, auth, model, id };
}

test('startup loads metadata and recovers interrupted writes without logging in', async () => {
  const store = new MemoryStore();
  const log = new AttendanceLog();
  store.data.logs = [log];
  const auth = new Authentication(new School());
  const model = new AppModel(store, auth);
  await model.initialize();
  assert.equal(auth.calls.length, 0);
  assert.equal(model.logs[0].result, LogResult.Uncertain);
  assert.equal(store.data.logs[0].result, LogResult.Uncertain);
  assert.equal(model.currentSession, undefined);
});

test('account editor trims labels and usernames, keeps password bytes and first default', async () => {
  const { model, store, id } = await fixture({ login: false });
  await model.saveAccount(undefined, ' student-b ', '  pass  ', ' second ');
  assert.equal(model.accounts[1].username, 'student-b');
  assert.equal(model.accounts[1].note, 'second');
  assert.equal(await model.password(model.accounts[1].id), '  pass  ');
  assert.equal(model.accounts.find(item => item.isDefault).id, id);
  assert(!JSON.stringify(store.data).includes('  pass  '));
});

test('duplicate and empty accounts fail before credential writes', async () => {
  const { model, store } = await fixture({ login: false });
  await assert.rejects(model.saveAccount(undefined, ' student-a ', 'x', ''), /已经存在/);
  await assert.rejects(model.saveAccount(undefined, ' ', 'x', ''), /不能为空/);
  await assert.rejects(model.saveAccount(undefined, 'other', '', ''), /不能为空/);
  assert.equal(store.passwords.size, 1);
});

test('changing default never switches an already logged-in account', async () => {
  const { model, id } = await fixture();
  await model.saveAccount(undefined, 'student-b', 'pw', '');
  const second = model.accounts[1].id;
  await model.makeDefault(second);
  assert.equal(model.currentSession.accountID, id);
  assert.equal(model.accounts.find(item => item.isDefault).id, second);
});

test('failed manual account switch retains the prior session and course data', async () => {
  const { model, auth, id } = await fixture();
  await model.saveAccount(undefined, 'student-b', 'pw', '');
  model.courses = [new Course('10', '保留课程')];
  const session = model.currentSession;
  auth.errors = [new RollcallError('message', 'offline')];
  await assert.rejects(model.login(model.accounts[1].id));
  assert.equal(model.currentSession, session);
  assert.equal(model.currentAccountID, id);
  assert.equal(model.courses[0].name, '保留课程');
});

test('session expiry reauthenticates the current account instead of the default', async () => {
  const { model, auth, school } = await fixture();
  await model.saveAccount(undefined, 'student-b', 'pw', '');
  const second = model.accounts[1].id;
  await model.login(second);
  school.failNextRead = true;
  await model.loadCourses();
  assert.equal(auth.calls.at(-1).id, second);
  assert.equal(model.currentAccountID, second);
  assert.equal(model.courses.length, 1);
});

test('only credential changes invalidate the current session and username changes clear verified ID', async () => {
  const { model, id } = await fixture();
  const session = model.currentSession;
  await model.saveAccount(id, 'student-a', ' secret ', '新备注');
  assert.equal(model.currentSession, session);
  await model.saveAccount(id, 'renamed', 'new', '新备注');
  assert.equal(model.currentSession, undefined);
  assert.equal(model.currentAccountID, id);
  assert.equal(model.accounts[0].verifiedStudentID, undefined);
});

test('metadata save failure rolls the password vault back', async () => {
  const { model, store, id } = await fixture();
  store.failOn = store.saves + 1;
  await assert.rejects(model.saveAccount(id, 'renamed', 'new secret', ''));
  assert.equal(await model.password(id), ' secret ');
  assert.equal(model.accounts[0].username, 'student-a');
  assert.equal(model.currentSession.accountID, id);
});

test('failed deletion restores credential and account; successful deletion retains logs without picking a default', async () => {
  const { model, store, id } = await fixture();
  await model.saveAccount(undefined, 'student-b', 'pw', '');
  model.logs = [Object.assign(new AttendanceLog(), { accountID: id })];
  store.failOn = store.saves + 1;
  await assert.rejects(model.deleteAccount(id));
  assert.equal(await model.password(id), ' secret ');
  await model.deleteAccount(id);
  assert.equal(model.accounts.length, 1);
  assert.equal(model.accounts.some(item => item.isDefault), false);
  assert.equal(model.logs.length, 1);
  assert.equal(model.currentSession, undefined);
});

test('three explicit credential errors switch to manual mode; network errors do not count', async () => {
  const { model, auth, id } = await fixture({ login: false });
  auth.errors = [new RollcallError('message', 'network'), new RollcallError('invalidCredentials'),
    new RollcallError('invalidCredentials'), new RollcallError('invalidCredentials')];
  await assert.rejects(model.login(id));
  await assert.rejects(model.login(id));
  await assert.rejects(model.login(id));
  await model.login(id);
  assert.deepEqual(auth.calls.map(item => item.forceManual), [false, false, false, false, true]);
});

test('concurrent login requests for the same account share a single authentication', async () => {
  const { model, auth, id } = await fixture({ login: false });
  let finish;
  auth.delay = new Promise(resolve => { finish = resolve; });
  const first = model.login(id);
  const second = model.login(id);
  await Promise.resolve();
  finish();
  await Promise.all([first, second]);
  assert.equal(auth.calls.length, 1);
});

test('UI operation gate prevents repeated clicks from executing a second mutation', async () => {
  const { model } = await fixture();
  let finish;
  let calls = 0;
  const first = model.run(async () => { calls++; await new Promise(resolve => { finish = resolve; }); });
  await model.run(async () => { calls++; });
  assert.equal(model.busy, true);
  assert.equal(calls, 1);
  finish();
  await first;
  assert.equal(model.busy, false);
});

test('missing default routes to account management without any network request', async () => {
  const { model, school, id } = await fixture({ login: false });
  await model.deleteAccount(id);
  await assert.rejects(model.enterCourses(), error => error.code === 'noDefaultAccount');
  assert.equal(model.tab, 2);
  assert.equal(school.requests.length, 0);
});

test('history groups code enrichment by course/date and preserves late/ended status', async () => {
  const { model, school } = await fixture();
  school.historyRows = [row('90', { number_code: undefined, status: 'on_call_late', rollcall_status: 'finished' }),
    row('91', { number_code: undefined, status: 'on_call', rollcall_status: 'finished' })];
  school.timetableRows = [row('90'), row('91', { number_code: '0099' })];
  await model.loadHistory(new Course('10', '离线测试课程'));
  assert.equal(model.currentCourse.id, '10');
  assert.equal(model.screen, 'attendance');
  assert.equal(model.records[0].stateText, '已签到 · 迟到');
  assert.equal(model.records[0].numberCode, '0031');
  assert.equal(model.records[1].numberCode, '0099');
  assert.equal(school.requests.filter(item => item.path.startsWith('/api/timetable_rollcalls')).length, 1);
});

test('failed refresh keeps existing history and does not replace it with another course', async () => {
  const { model, school } = await fixture();
  await model.loadHistory(new Course('10', '离线测试课程'));
  school.send = async () => { throw new RollcallError('message', 'network'); };
  await assert.rejects(model.loadHistory(new Course('10', '离线测试课程')));
  assert.equal(model.records[0].id, '90');
});

test('successful numeric submission persists identity/date and confirms only the current student', async () => {
  const { model, school, store, id } = await fixture();
  await model.loadHistory(new Course('10', '离线测试课程'));
  await model.submit(model.records[0]);
  assert.equal(model.logs[0].result, LogResult.Success);
  assert.equal(model.logs[0].accountID, id);
  assert.equal(model.logs[0].studentID, '101');
  assert.equal(model.logs[0].rollcallDate, time);
  assert.equal(model.logs[0].code, '0031');
  assert.equal(store.data.logs[0].result, LogResult.Success);
  assert.equal(school.requests.filter(item => item.method === 'PUT').length, 1);
});

test('already answered records produce a success log without a second submission', async () => {
  const { model, school } = await fixture();
  await model.loadHistory(new Course('10', '离线测试课程'));
  school.timetableRows = [row('90', { student_rollcalls: [{ student_id: '101', status: 'on_call' }] })];
  await model.submit(model.records[0]);
  assert.equal(model.logs[0].result, LogResult.Success);
  assert.match(model.logs[0].message, /未重复提交/);
  assert.equal(school.requests.filter(item => item.method === 'PUT').length, 0);
});

test('interrupted or unconfirmed number submission remains uncertain and is never retried', async () => {
  for (const disconnected of [false, true]) {
    const { model, school } = await fixture();
    await model.loadHistory(new Course('10', '离线测试课程'));
    school.confirm = false;
    if (disconnected) { school.writeFailure = new Error('offline'); }
    await assert.rejects(model.submit(model.records[0]), error => error.code === 'uncertain');
    assert.equal(model.logs[0].result, LogResult.Uncertain);
    assert.equal(school.requests.filter(item => item.method === 'PUT').length, 1);
  }
});

test('failure to persist the processing log prevents any school write', async () => {
  const { model, school, store } = await fixture();
  await model.loadHistory(new Course('10', '离线测试课程'));
  store.failOn = store.saves + 1;
  await assert.rejects(model.submit(model.records[0]));
  assert.equal(school.requests.filter(item => item.method === 'PUT').length, 0);
});

test('accepted submission followed by final disk error is recorded as uncertain', async () => {
  const { model, school, store } = await fixture();
  await model.loadHistory(new Course('10', '离线测试课程'));
  store.failOn = store.saves + 4; // begin, identity/date, processing, final success
  await assert.rejects(model.submit(model.records[0]));
  assert.equal(model.logs[0].result, LogResult.Uncertain);
  assert.equal(store.data.logs[0].result, LogResult.Uncertain);
  assert.equal(school.requests.filter(item => item.method === 'PUT').length, 1);
});

test('reconcile requires original account and student, and never submits a write', async () => {
  const { model, school } = await fixture();
  await model.loadHistory(new Course('10', '离线测试课程'));
  school.confirm = false;
  await assert.rejects(model.submit(model.records[0]));
  const logID = model.logs[0].id;
  const writes = school.requests.filter(item => item.method === 'PUT').length;
  model.logs[0].studentID = 'other';
  await assert.rejects(model.reconcile(logID), error => error.code === 'identityMismatch');
  model.logs[0].studentID = '101';
  school.timetableRows = [row('90', { student_rollcalls: [{ student_id: '101', status: 'on_call' }] })];
  await model.reconcile(logID);
  assert.equal(model.logs[0].result, LogResult.Success);
  assert.equal(school.requests.filter(item => item.method === 'PUT').length, writes);
  model.logout();
  await assert.rejects(model.reconcile(logID), /登录这条记录对应的账号/);
});

test('missing log date resolves exact rollcall history rather than using today', async () => {
  const { model, school, id } = await fixture();
  const log = Object.assign(new AttendanceLog(), { accountID: id, studentID: '101', courseID: '10',
    rollcallID: '90', rollcallDate: undefined, result: LogResult.Uncertain });
  model.logs = [log];
  school.historyRows = [row('90', { rollcall_time: '2026-09-01T23:30:00Z' })];
  await model.reconcile(log.id);
  assert(school.requests.some(item => item.path.includes('rollcall_date=2026-09-02')));
  assert.equal(model.logs[0].rollcallDate, Date.parse('2026-09-01T23:30:00Z'));
});

test('late read responses from an old session never update the visible course list', async () => {
  const { model, school } = await fixture();
  let finish;
  school.delay = new Promise(resolve => { finish = resolve; });
  const pending = model.loadCourses();
  await Promise.resolve();
  model.currentSession = undefined;
  finish();
  await assert.rejects(pending, error => error.code === 'cancelled');
  assert.equal(model.courses.length, 0);
});

test('finished activity cannot submit even if its stale expiry flag says active', async () => {
  const { model, school } = await fixture();
  await model.loadHistory(new Course('10', '离线测试课程'));
  school.timetableRows = [row('90', { rollcall_status: 'finished', is_expired: false })];
  await assert.rejects(model.submit(model.records[0]), /签到已结束/);
  assert.equal(model.logs[0].result, LogResult.Failure);
  assert.equal(school.requests.filter(item => item.method === 'PUT').length, 0);
});
