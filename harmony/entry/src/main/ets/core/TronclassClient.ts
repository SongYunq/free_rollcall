import { Attendance, Course, DataPage, PageAccumulator, PageParser, UserProfile } from './Models';
import { RollcallError } from './Errors';
import { JSONValue } from './JSONValue';
import { RadarSubmission, randomDeviceID } from './RadarSubmission';

export class APIRequest {
  constructor(public path: string, public method: string = 'GET', public body?: string,
    public radarHeaders: boolean = false) {}
}

export class APIResponse {
  constructor(public status: number, public body: string) {}
  json(): JSONValue { return JSONValue.decode(this.body); }
}

export interface HTTPTransport { send(request: APIRequest): Promise<APIResponse>; }

export class TronclassClient {
  constructor(public transport: HTTPTransport) {}

  private async read(request: APIRequest): Promise<JSONValue> {
    const response = await this.transport.send(request);
    if (response.status === 401 || response.status === 403 || (response.status >= 300 && response.status < 400)) {
      throw new RollcallError('expiredSession');
    }
    if (response.status !== 200) {
      throw new RollcallError('message', `学校服务暂时不可用（${response.status}）`);
    }
    if (response.body.substring(0, 200).toLowerCase().includes('<html')) {
      throw new RollcallError('expiredSession');
    }
    return response.json();
  }

  async profile(): Promise<UserProfile> {
    return UserProfile.fromValue(await this.read(new APIRequest('/api/profile')));
  }

  async currentSemesterCourses(): Promise<Course[]> {
    const semester = await this.read(new APIRequest('/api/current-semester-info'));
    const semesterID = semester.field('semester').field('id').string;
    const yearID = semester.field('academic_year').field('id').string;
    if (!semesterID || !yearID) { throw new RollcallError('message', '未能获取当前学期，请稍后重试'); }
    const conditions = {
      semester_id: [semesterID], academic_year_id: [yearID], keyword: '',
      classify_type: 'recently_started', display_studio_list: false
    };
    const courses = new PageAccumulator<Course>();
    do {
      const page = courses.nextPage;
      const body = JSON.stringify({ conditions: conditions, fields: 'id,name,display_name',
        page: page, page_size: 30, showScorePassedStatus: false });
      const response = await this.read(new APIRequest('/api/my-courses', 'POST', body));
      courses.append(PageParser.parse<Course>(response, 'courses', page, 30,
        (value: JSONValue): Course => Course.fromValue(value)));
    } while (courses.hasMore);
    return courses.items;
  }

  async history(courseID: string, studentID: string, page: number, size: number = 99): Promise<DataPage<Attendance>> {
    this.validateID(courseID);
    this.validateID(studentID);
    if (!Number.isSafeInteger(page) || page < 1 || !Number.isSafeInteger(size) || size < 1) {
      throw new RollcallError('malformedResponse');
    }
    const path = `/api/course/${courseID}/student/${studentID}/rollcalls?page=${page}&page_size=${size}`;
    return PageParser.parse<Attendance>(await this.read(new APIRequest(path)), 'rollcalls', page, size,
      (value: JSONValue): Attendance => Attendance.fromValue(value));
  }

  async active(): Promise<Attendance[]> {
    const json = await this.read(new APIRequest('/api/radar/rollcalls'));
    const rows = json.field('rollcalls').array ?? json.array;
    if (rows === undefined) { throw new RollcallError('malformedResponse'); }
    return rows.map((row: JSONValue): Attendance => Attendance.fromValue(row));
  }

  async timetable(courseID: string, date: number, studentID: string): Promise<Attendance[]> {
    const path = this.timetablePath(courseID, date, studentID);
    const json = await this.read(new APIRequest(path));
    const rows = json.field('rollcalls').array;
    if (rows === undefined) { throw new RollcallError('malformedResponse'); }
    const records: Attendance[] = [];
    const ids = new Set<string>();
    rows.forEach((row: JSONValue): void => {
      if (!row.isObject) { throw new RollcallError('malformedResponse'); }
      const courseValues = [row.field('course').field('id'), row.field('course_id')]
        .filter((value: JSONValue): boolean => !value.isNull);
      courseValues.forEach((value: JSONValue): void => {
        const id = value.string;
        if (id === undefined) { throw new RollcallError('malformedResponse'); }
        this.validateID(id);
      });
      if (courseValues.some((value: JSONValue): boolean => value.string !== courseID)) { return; }
      const identifier = !row.field('id').isNull ? row.field('id') : row.field('rollcall_id');
      const id = identifier.string;
      if (id === undefined) { throw new RollcallError('malformedResponse'); }
      this.validateID(id);
      if ((!row.field('rollcall_id').isNull && row.field('rollcall_id').string !== id) || ids.has(id)) {
        throw new RollcallError('malformedResponse');
      }
      ids.add(id);
      const record = Attendance.fromValue(row);
      record.courseID = courseID;
      const studentsValue = row.field('student_rollcalls');
      if (!studentsValue.isNull && studentsValue.array === undefined) { throw new RollcallError('malformedResponse'); }
      const ownRows = (studentsValue.array ?? []).filter((student: JSONValue): boolean =>
        student.field('student_id').string === studentID);
      const ownStatuses = ownRows.map((student: JSONValue): string | undefined =>
        Attendance.recognizedPersonalStatus(student.field('status').string) ??
        Attendance.recognizedPersonalStatus(student.field('rollcall_status').string));
      // Top-level status belongs to the activity. Only this student's unambiguous rows prove attendance.
      const first = ownStatuses[0];
      record.personalStatus = ownStatuses.length > 0 &&
        ownStatuses.every((status: string | undefined): boolean => status === first) ? first : undefined;
      records.push(record);
    });
    return records;
  }

  async detail(id: string, courseID: string, date: number, studentID: string): Promise<Attendance> {
    this.validateID(id);
    const records = await this.timetable(courseID, date, studentID);
    const record = records.find((item: Attendance): boolean => item.id === id);
    if (record === undefined) {
      throw new RollcallError('message', '未找到对应签到记录，请刷新课程签到列表后重试');
    }
    return record;
  }

  async submitNumber(id: string, code: string, courseID: string, date: number, studentID: string): Promise<Attendance> {
    this.validateID(id);
    this.timetablePath(courseID, date, studentID);
    if (code.length === 0) { throw new RollcallError('message', '未获取到签到码，请刷新后重试'); }
    const request = new APIRequest(`/api/rollcall/${id}/answer_number_rollcall`, 'PUT',
      JSON.stringify({ deviceId: randomDeviceID(), numberCode: code }));
    let response: APIResponse;
    try { response = await this.transport.send(request); }
    catch (_) { throw new RollcallError('uncertain', '提交连接中断，结果待确认，请先核对签到状态'); }
    if (response.status === 401 || response.status === 403) { throw new RollcallError('expiredSession'); }
    if (response.status >= 500) { throw new RollcallError('uncertain', '学校服务响应异常，签到结果待确认'); }
    if (response.status !== 200) { throw new RollcallError('message', `签到未通过（${response.status}），请刷新后重试`); }
    let accepted: boolean | undefined;
    try { accepted = response.json().field('success').boolean; } catch (_) { /* Some successful responses have no JSON body. */ }
    if (accepted === false) { throw new RollcallError('message', '学校未接受本次签到，请刷新后重试'); }
    try {
      const record = await this.detail(id, courseID, date, studentID);
      if (!record.isAnswered) { throw new RollcallError('uncertain'); }
      return record;
    } catch (_) { throw new RollcallError('uncertain', '已提交，结果待确认，请稍后核对签到状态'); }
  }

  async submitRadar(id: string): Promise<boolean> {
    this.validateID(id);
    return RadarSubmission.run(this.transport, id);
  }

  private timetablePath(courseID: string, date: number, studentID: string): string {
    this.validateID(courseID);
    this.validateID(studentID);
    if (!Number.isFinite(date)) { throw new RollcallError('malformedResponse'); }
    const beijing = new Date(date + 8 * 60 * 60 * 1000);
    const year = beijing.getUTCFullYear();
    if (!Number.isFinite(beijing.getTime()) || year < 0 || year > 9999) { throw new RollcallError('malformedResponse'); }
    const day = `${String(year).padStart(4, '0')}-${String(beijing.getUTCMonth() + 1).padStart(2, '0')}-${String(beijing.getUTCDate()).padStart(2, '0')}`;
    return `/api/timetable_rollcalls?course_ids=${courseID}&rollcall_date=${day}`;
  }

  private validateID(id: string): void {
    if (!/^[0-9]+$/.test(id)) { throw new RollcallError('malformedResponse'); }
  }
}
