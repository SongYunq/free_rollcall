import test from 'node:test';
import assert from 'node:assert/strict';
import { Attendance, AttendanceKind, Course, DataPage, PageAccumulator, PageParser, UserProfile } from '../.build/core/Models.js';
import { APIResponse, TronclassClient } from '../.build/core/TronclassClient.js';
import { JSONValue } from '../.build/core/JSONValue.js';
import { RadarSubmission } from '../.build/core/RadarSubmission.js';

class StubTransport {
  constructor(replies = []) { this.replies = replies; this.requests = []; }
  async send(request) {
    this.requests.push(request);
    const reply = this.replies.shift();
    if (!reply) { throw new Error('Unexpected request'); }
    if (reply instanceof Error) { throw reply; }
    return new APIResponse(reply[0], typeof reply[1] === 'string' ? reply[1] : JSON.stringify(reply[1]));
  }
}
const ownDate = Attendance.parseDate('2026-10-08T00:03:17Z');
const timetable = (rollcalls) => ({ rollcalls });
const attendance = (value) => Attendance.fromJSON(JSON.stringify(value));
const errorCode = (code) => (error) => error.code === code;

test('profile accepts email aliases but known ID remains authoritative', () => {
  const profile = UserProfile.fromJSON('{"id":123,"user_no":"00123","email":"alias@example.test","name":"Test"}');
  assert.equal(profile.id, '123');
  assert.equal(profile.account, '00123');
  assert.equal(profile.matches('ALIAS@example.test'), true);
  assert.equal(profile.matches('other'), false);
  assert.equal(profile.matches('alias', '123'), true);
  assert.equal(profile.matches('00123', '456'), false);
  assert.throws(() => UserProfile.fromJSON('{"id":1}'), errorCode('malformedResponse'));
});

test('course uses display name and requires an ID', () => {
  assert.equal(Course.fromJSON('{"id":1,"display_name":"A","name":"B"}').name, 'A');
  assert.equal(Course.fromJSON('{"id":1,"display_name":"","name":"B"}').name, 'B');
  assert.throws(() => Course.fromJSON('{}'), errorCode('malformedResponse'));
});

test('finished activity overrides stale flags and preserves answered state', () => {
  const record = attendance({ rollcall_id: 1, is_expired: false, rollcall_status: 'finished',
    is_number: true, status: 'on_call_fine', rollcall_time: '2026-09-01T08:00:00Z' });
  assert.equal(record.isActive, false);
  assert.equal(record.canSubmit, false);
  assert.equal(record.isAnswered, true);
  assert.equal(record.kind, AttendanceKind.Number);
  assert.ok(record.date);
});

test('radar wins both flags; unknown status and absent labels stay conservative', () => {
  const radar = attendance({ rollcall_id: 1, is_expired: false, is_number: true, is_radar: true, status: 'absent' });
  assert.equal(radar.kind, AttendanceKind.Radar);
  assert.equal(radar.canSubmit, true);
  assert.equal(radar.isAbsent, false);
  const unknown = attendance({ rollcall_id: 2 });
  assert.equal(unknown.canSubmit, false);
  assert.equal(unknown.stateText, '状态待确认');
  const ended = attendance({ rollcall_id: 3, rollcall_status: 'finished' });
  for (const status of [undefined, '', 'new_server_value', 'on_call_fine', 'on_call_late']) {
    ended.personalStatus = status;
    assert.equal(ended.isAbsent, false);
  }
  ended.personalStatus = 'absent';
  assert.equal(ended.stateText, '缺勤');
  const stale = attendance({ rollcall_id: 4, status: 'active', end_time: '2000-01-01T00:00:00Z' });
  assert.equal(stale.stateText, '已结束');
});

test('date parsing gives school plain timestamps a fixed Beijing offset', () => {
  assert.equal(Attendance.parseDate('2026-10-08 08:03:17'), ownDate);
  assert.equal(Attendance.parseDate('2026-10-08T08:03:17+08:00'), ownDate);
  assert.equal(Attendance.parseDate('2026-10-08T00:03:17.123Z'), ownDate + 123);
  assert.equal(Attendance.parseDate('bad date'), undefined);
  assert.equal(Attendance.parseDate('2026-10-08T08:03:17'), undefined);
});

test('merge ignores unknown personal status and preserves known lateness until explicit correction', () => {
  const history = attendance({ rollcall_id: 7, status: 'on_call_late', rollcall_status: 'finished' });
  for (const status of [undefined, '', 'active', 'finished', 'on_call', 'present', 'attended']) {
    const detail = attendance({ id: 7, status, number_code: '0012' });
    history.merge(detail);
    assert.equal(history.stateText, '已签到 · 迟到');
  }
  assert.equal(history.numberCode, '0012');
  history.merge(attendance({ id: 7, status: 'on_call_fine' }));
  assert.equal(history.stateText, '已签到');
  history.merge(attendance({ id: 7, status: 'absent' }));
  assert.equal(history.stateText, '缺勤');
  history.merge(attendance({ id: 8, status: 'on_call' }));
  assert.equal(history.stateText, '缺勤');
  assert.notEqual(history.clone(), history);
  assert.equal(history.clone().stateText, history.stateText);
});

test('page parser handles wrappers, deduplicates pages, and stops repeated responses', () => {
  const json = JSONValue.decode('{"data":{"courses":[{"id":1,"name":"A"},{"id":2,"name":"B"},{"id":2}],"pages":2,"total":4}}');
  const pages = new PageAccumulator();
  pages.append(PageParser.parse(json, 'courses', 1, 2, Course.fromValue));
  assert.equal(pages.items.length, 2);
  assert.equal(pages.hasMore, true);
  pages.append(PageParser.parse(json, 'courses', 2, 2, Course.fromValue));
  assert.equal(pages.items.length, 2);
  assert.equal(pages.hasMore, false);
  assert.match(pages.note, /重复/);
});

test('unknown pagination keeps fetching through server caps and does not claim completeness', () => {
  const pages = new PageAccumulator();
  for (let page = 1; page <= 4; page += 1) {
    const rollcalls = Array.from({ length: Math.min(30, 105 - (page - 1) * 30) }, (_, index) =>
      ({ rollcall_id: (page - 1) * 30 + index }));
    const parsed = PageParser.parse(JSONValue.decode(JSON.stringify({ rollcalls })), 'rollcalls', page, 99, Attendance.fromValue);
    pages.append(parsed);
    assert.equal(pages.hasMore, true);
  }
  assert.equal(pages.items.length, 105);
  pages.append(new DataPage([], 5, undefined, undefined, false, false));
  assert.equal(pages.hasMore, false);
  assert.notEqual(pages.note, '已全部加载');
});

test('courses use fresh current-semester filters for every page and refresh', async () => {
  const transport = new StubTransport([
    [200, { semester: { id: 7 }, academic_year: { id: 2026 } }],
    [200, { courses: [{ id: 1, name: 'A' }, { id: 2, name: 'B' }], pages: 2 }],
    [200, { courses: [{ id: 2, name: 'B' }, { id: 3, name: 'C' }], pages: 2 }],
    [200, { semester: { id: 8 }, academic_year: { id: 2027 } }],
    [200, { courses: [], pages: 1 }]
  ]);
  const client = new TronclassClient(transport);
  assert.deepEqual((await client.currentSemesterCourses()).map((value) => value.id), ['1', '2', '3']);
  await client.currentSemesterCourses();
  const bodies = [transport.requests[1], transport.requests[2], transport.requests[4]].map((value) => JSON.parse(value.body));
  assert.deepEqual(bodies[0].conditions, { semester_id: ['7'], academic_year_id: ['2026'], keyword: '',
    classify_type: 'recently_started', display_studio_list: false });
  assert.deepEqual(bodies[1].conditions, bodies[0].conditions);
  assert.equal(bodies[1].page, 2);
  assert.deepEqual(bodies[2].conditions.semester_id, ['8']);
  assert.deepEqual(bodies[2].conditions.academic_year_id, ['2027']);
});

test('semester errors never fall back to unfiltered courses', async () => {
  for (const reply of [[500, {}], [200, { semester: null, academic_year: { id: 2026 } }]]) {
    const transport = new StubTransport([reply]);
    await assert.rejects(new TronclassClient(transport).currentSemesterCourses());
    assert.equal(transport.requests.length, 1);
  }
});

test('history uses the student-scoped endpoint and retains pagination metadata', async () => {
  const transport = new StubTransport([[200, { rollcalls: [{ rollcall_id: 7 }], pages: 3, total: 200 }]]);
  const page = await new TronclassClient(transport).history('11', '9', 2);
  assert.equal(transport.requests[0].path, '/api/course/11/student/9/rollcalls?page=2&page_size=99');
  assert.equal(page.hasMore, true);
  assert.equal(page.completenessKnown, true);
});

test('timetable uses Beijing date across UTC midnight and preserves leading-zero code', async () => {
  const transport = new StubTransport([[200, timetable([{ id: 7, course: { id: 11 }, status: 'active',
    is_number: true, number_code: '0012', student_rollcalls: [{ student_id: 8, status: 'on_call' }, { student_id: 9, status: 'absent' }] }])]]);
  const result = await new TronclassClient(transport).detail('7', '11', Attendance.parseDate('2026-10-07T16:03:17Z'), '9');
  assert.equal(result.numberCode, '0012');
  assert.equal(result.isAnswered, false);
  assert.equal(result.canSubmit, true);
  assert.equal(transport.requests[0].path, '/api/timetable_rollcalls?course_ids=11&rollcall_date=2026-10-08');
});

test('detail matches both course and rollcall instead of using the first row', async () => {
  const transport = new StubTransport([[200, timetable([
    { id: 7, course: { id: 12 }, number_code: '9999' },
    { id: 8, course: { id: 11 }, number_code: '2222' },
    { id: 7, course: { id: 11 }, number_code: '0012', status: 'finished', student_rollcalls: [{ student_id: 9, status: 'on_call' }] }
  ])]]);
  const record = await new TronclassClient(transport).detail('7', '11', ownDate, '9');
  assert.equal(record.numberCode, '0012');
  assert.equal(record.isAnswered, true);
  assert.equal(record.courseID, '11');
});

test('missing target never falls back to another course, record, or endpoint', async () => {
  for (const rows of [[], [{ id: 8, course_id: 11 }], [{ id: 7, course_id: 12 }], [{ id: 7, course: { id: 11 }, course_id: 12 }]]) {
    const transport = new StubTransport([[200, timetable(rows)]]);
    await assert.rejects(new TronclassClient(transport).detail('7', '11', ownDate, '9'), /未找到/);
    assert.equal(transport.requests.length, 1);
  }
});

test('timetable rejects malformed containers, duplicate IDs and conflicting identifiers', async () => {
  const malformed = [{}, [], { data: { rollcalls: [] } }, { rollcalls: null },
    timetable([{ id: '7/8' }]), timetable([{ id: 7, rollcall_id: 8 }]), timetable([{ id: false, rollcall_id: 7 }]),
    timetable([{ id: 7, course: { id: false } }]), timetable([{ id: 7 }, { id: 7 }]),
    timetable([{ id: 7, student_rollcalls: {} }])];
  for (const response of malformed) {
    const transport = new StubTransport([[200, response]]);
    await assert.rejects(new TronclassClient(transport).timetable('11', ownDate, '9'), errorCode('malformedResponse'));
  }
});

test('only matching student rows and recognized unambiguous statuses prove attendance', async () => {
  const cases = [
    [[{ student_id: 8, status: 'on_call' }], undefined],
    [[{ student_id: 9, status: 'on_call' }], 'on_call'],
    [[{ student_id: 9, status: 'active' }], undefined],
    [[{ student_id: 9, status: 'finished' }], undefined],
    [[{ student_id: 9, status: 'new_server_value' }], undefined],
    [[{ student_id: 9, rollcall_status: 'on_call_fine' }], 'on_call_fine'],
    [[{ student_id: 9, status: 'absent', rollcall_status: 'on_call_fine' }], 'absent'],
    [[{ student_id: 9, status: '', rollcall_status: 'on_call' }], 'on_call'],
    [[{ student_id: 9, status: 'on_call' }, { student_id: 9, status: 'on_call' }], 'on_call'],
    [[{ student_id: 9, status: 'on_call' }, { student_id: 9, status: 'absent' }], undefined],
    [[{ student_id: 9, status: 'on_call' }, { student_id: 9 }], undefined]
  ];
  for (const [students, expected] of cases) {
    const transport = new StubTransport([[200, timetable([{ id: 7, status: 'finished', student_rollcalls: students }])]]);
    const record = await new TronclassClient(transport).detail('7', '11', ownDate, '9');
    assert.equal(record.personalStatus, expected);
    assert.equal(record.isAnswered, expected === 'on_call' || expected === 'on_call_fine');
  }
});

test('timetable without course takes requested context, but missing own status cannot erase signed history', async () => {
  const transport = new StubTransport([[200, timetable([{ id: 7, status: 'finished', number_code: '0012',
    student_rollcalls: [{ student_id: 8, status: 'absent' }] }])]]);
  const detail = await new TronclassClient(transport).detail('7', '11', ownDate, '9');
  assert.equal(detail.courseID, '11');
  assert.equal(detail.personalStatus, undefined);
  const history = attendance({ rollcall_id: 7, status: 'on_call_late', rollcall_status: 'finished' });
  history.merge(detail);
  assert.equal(history.stateText, '已签到 · 迟到');
});

test('number submission confirms own status using timetable and never retries the write', async () => {
  const transport = new StubTransport([[200, {}], [200, timetable([{ id: 7, course_id: 11,
    student_rollcalls: [{ student_id: 9, status: 'on_call' }] }])]]);
  const result = await new TronclassClient(transport).submitNumber('7', '0012', '11', ownDate, '9');
  assert.equal(result.isAnswered, true);
  assert.deepEqual(transport.requests.map((value) => value.method), ['PUT', 'GET']);
  assert.equal(transport.requests[0].path, '/api/rollcall/7/answer_number_rollcall');
  const body = JSON.parse(transport.requests[0].body);
  assert.equal(body.numberCode, '0012');
  assert.match(body.deviceId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test('unconfirmed numeric writes and disconnected submissions remain uncertain with one PUT', async () => {
  for (const rows of [[], [{ id: 7, student_rollcalls: [{ student_id: 8, status: 'on_call' }] }],
    [{ id: 7, student_rollcalls: [{ student_id: 9, status: 'absent' }] }]]) {
    const transport = new StubTransport([[200, {}], [200, timetable(rows)]]);
    await assert.rejects(new TronclassClient(transport).submitNumber('7', '0000', '11', ownDate, '9'), errorCode('uncertain'));
    assert.equal(transport.requests.filter((value) => value.method === 'PUT').length, 1);
  }
  const disconnected = new StubTransport([new Error('Disconnected')]);
  await assert.rejects(new TronclassClient(disconnected).submitNumber('7', '0000', '11', ownDate, '9'), errorCode('uncertain'));
  assert.equal(disconnected.requests.length, 1);
});

test('invalid numeric context never writes; explicit school rejection stops before read-back', async () => {
  for (const args of [['7/8', '0012', '11', ownDate, '9'], ['7', '0012', '11&extra=1', ownDate, '9'],
    ['7', '0012', '11', ownDate, ''], ['7', '', '11', ownDate, '9'], ['7', '0012', '11', NaN, '9']]) {
    const transport = new StubTransport();
    await assert.rejects(new TronclassClient(transport).submitNumber(...args));
    assert.equal(transport.requests.length, 0);
  }
  const transport = new StubTransport([[200, { success: false }]]);
  await assert.rejects(new TronclassClient(transport).submitNumber('7', '0012', '11', ownDate, '9'), /未接受/);
  assert.equal(transport.requests.length, 1);
});

test('expired redirects and HTML login pages are identified', async () => {
  for (const reply of [[302, ''], [401, '{}'], [403, '{}'], [200, '<!DOCTYPE html><html>Login</html>']]) {
    await assert.rejects(new TronclassClient(new StubTransport([reply])).profile(), errorCode('expiredSession'));
  }
});

test('radar math matches existing Python and iOS reference values', () => {
  const cases = [
    [25000, 22000, [[24.524828396473676, 117.99895695280263], [24.402952407177416, 118.21956358296477]]],
    [35000, 25000, [[24.61188675779247, 117.95336665988438], [24.406329427956848, 118.32544413061515]]],
    [20000, 20000, [[24.470519762573105, 118.06285736264282], [24.429480237426898, 118.13714263735719]]]
  ];
  for (const [distance1, distance2, expected] of cases) {
    const actual = RadarSubmission.solve(distance1, distance2);
    for (let index = 0; index < 2; index += 1) {
      assert.ok(Math.abs(actual[index].latitude - expected[index][0]) < 1e-11);
      assert.ok(Math.abs(actual[index].longitude - expected[index][1]) < 1e-11);
    }
  }
  assert.equal(RadarSubmission.solve(1, 1), undefined);
  assert.equal(RadarSubmission.solve(NaN, 1), undefined);
  assert.equal(RadarSubmission.solve(-1, 20000), undefined);
});

test('radar probes both anchors then candidates in original order with fresh identifiers', async () => {
  const transport = new StubTransport([[400, { distance: 25000 }], [400, { distance: 22000 }], [400, {}], [200, '']]);
  assert.equal(await new TronclassClient(transport).submitRadar('7'), true);
  assert.equal(transport.requests.length, 4);
  const expected = [RadarSubmission.first, RadarSubmission.second, ...RadarSubmission.solve(25000, 22000)];
  const ids = new Set();
  for (const [index, request] of transport.requests.entries()) {
    assert.equal(request.path, '/api/rollcall/7/answer');
    assert.equal(request.method, 'PUT');
    assert.equal(request.radarHeaders, true);
    const body = JSON.parse(request.body);
    assert.deepEqual(Object.keys(body).sort(), ['accuracy', 'altitude', 'altitudeAccuracy', 'deviceId', 'heading', 'latitude', 'longitude', 'speed'].sort());
    assert.equal(body.latitude, expected[index].latitude);
    assert.equal(body.longitude, expected[index].longitude);
    assert.equal(body.accuracy, 35);
    assert.equal(body.altitude, 0);
    for (const key of ['altitudeAccuracy', 'heading', 'speed']) { assert.equal(body[key], null); }
    ids.add(body.deviceId);
  }
  assert.equal(ids.size, 4);
});

test('radar stops on each successful probe and preserves first JSON decode order', async () => {
  const cases = [[[200, '{}']], [[400, '{}'], [200, '{}']],
    [[400, { distance: 25000 }], [400, { distance: 22000 }], [200, '']]];
  for (const replies of cases) {
    const expected = replies.length;
    const transport = new StubTransport(replies);
    assert.equal(await RadarSubmission.run(transport, '7'), true);
    assert.equal(transport.requests.length, expected);
  }
  await assert.rejects(RadarSubmission.run(new StubTransport([[200, '']]), '7'), errorCode('malformedResponse'));
  const failures = new StubTransport([[400, { distance: 25000 }], [400, { distance: 22000 }], [400, '{}'], [400, '']]);
  assert.equal(await RadarSubmission.run(failures, '7'), false);
});
