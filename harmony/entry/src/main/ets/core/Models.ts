import { RollcallError } from './Errors';
import { JSONValue } from './JSONValue';

export interface Identified { id: string; }

export class UserProfile {
  constructor(public id: string, public account: string, public name: string, public email?: string) {}

  static fromJSON(text: string): UserProfile { return UserProfile.fromValue(JSONValue.decode(text)); }

  static fromValue(json: JSONValue): UserProfile {
    const id = json.field('id').string;
    const account = json.field('user_no').string;
    if (!id || !account) { throw new RollcallError('malformedResponse'); }
    return new UserProfile(id, account, json.field('name').string ?? account, json.field('email').string);
  }

  matches(username: string, knownID?: string): boolean {
    if (knownID !== undefined) { return this.id === knownID; }
    return this.account === username || this.email?.toLowerCase() === username.toLowerCase();
  }
}

export class Course implements Identified {
  constructor(public id: string, public name: string) {}

  static fromJSON(text: string): Course { return Course.fromValue(JSONValue.decode(text)); }

  static fromValue(json: JSONValue): Course {
    const id = json.field('id').string;
    if (!id) { throw new RollcallError('malformedResponse'); }
    const displayName = json.field('display_name').string;
    return new Course(id, displayName || json.field('name').string || '未命名课程');
  }
}

export enum AttendanceKind { Number = 'number', Radar = 'radar', Other = 'other', Unknown = 'unknown' }

export function attendanceKindTitle(kind: AttendanceKind): string {
  switch (kind) {
    case AttendanceKind.Number: return '数字签到';
    case AttendanceKind.Radar: return '雷达签到';
    case AttendanceKind.Other: return '其他签到';
    default: return '未知形式';
  }
}

export class Attendance implements Identified {
  courseID?: string;
  courseName?: string;
  date?: number;
  rawDate?: string;
  kind: AttendanceKind = AttendanceKind.Unknown;
  activityStatus?: string;
  personalStatus?: string;
  isExpired?: boolean;
  numberCode?: string;
  endDate?: number;

  constructor(public id: string) {}

  static fromJSON(text: string): Attendance { return Attendance.fromValue(JSONValue.decode(text)); }

  static fromValue(json: JSONValue): Attendance {
    const id = json.field('rollcall_id').string ?? json.field('id').string;
    if (!id) { throw new RollcallError('malformedResponse'); }
    const result = new Attendance(id);
    result.courseID = json.field('course_id').string ?? json.field('course').field('id').string;
    result.courseName = json.field('course_title').string ?? json.field('course').field('name').string;
    result.rawDate = json.field('rollcall_time').string ?? json.field('created_at').string;
    result.date = Attendance.parseDate(result.rawDate);
    result.kind = Attendance.kindFromValue(json);
    const status = json.field('status').string;
    result.activityStatus = json.field('rollcall_status').string ??
      (status !== undefined && ['active', 'finished', 'ended', 'closed'].includes(status) ? status : undefined);
    result.personalStatus = Attendance.recognizedPersonalStatus(status);
    result.isExpired = json.field('is_expired').boolean;
    result.numberCode = json.field('number_code').string;
    result.endDate = Attendance.parseDate(json.field('end_time').string);
    return result;
  }

  static recognizedPersonalStatus(value?: string): string | undefined {
    const normalized = value?.trim().toLowerCase();
    return normalized !== undefined &&
      ['on_call', 'on_call_fine', 'on_call_late', 'present', 'attended', 'late', 'absent'].includes(normalized)
      ? normalized : undefined;
  }

  static kindFromValue(json: JSONValue): AttendanceKind {
    if (json.field('is_radar').boolean === true) { return AttendanceKind.Radar; }
    if (json.field('is_number').boolean === true) { return AttendanceKind.Number; }
    if (json.field('is_radar').boolean === false && json.field('is_number').boolean === false) {
      return AttendanceKind.Other;
    }
    if (json.field('number_code').string !== undefined) { return AttendanceKind.Number; }
    return AttendanceKind.Unknown;
  }

  /** School timestamps without a timezone are Beijing time, independent of device timezone. */
  static parseDate(text?: string): number | undefined {
    if (!text) { return undefined; }
    const normalized = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(text)
      ? text.replace(' ', 'T') + '+08:00' : text;
    // Reject timezone-free ISO strings rather than silently applying the device timezone.
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$/.test(normalized)) {
      return undefined;
    }
    const timestamp = Date.parse(normalized);
    return Number.isFinite(timestamp) ? timestamp : undefined;
  }

  get isAnswered(): boolean {
    return ['on_call', 'on_call_fine', 'on_call_late', 'present', 'attended', 'late'].includes(this.personalStatus ?? '');
  }

  get hasEnded(): boolean {
    return this.isExpired === true || ['finished', 'ended', 'closed'].includes(this.activityStatus ?? '') ||
      (this.endDate !== undefined && this.endDate <= Date.now());
  }

  get isActive(): boolean {
    return !this.hasEnded && (this.activityStatus === 'active' || this.isExpired === false);
  }

  get canSubmit(): boolean {
    return this.isActive && !this.isAnswered &&
      (this.kind === AttendanceKind.Number || this.kind === AttendanceKind.Radar);
  }

  get isAbsent(): boolean { return this.hasEnded && this.personalStatus === 'absent'; }

  get stateText(): string {
    if (this.isAnswered) { return ['on_call_late', 'late'].includes(this.personalStatus ?? '') ? '已签到 · 迟到' : '已签到'; }
    if (this.isActive) { return '正在签到'; }
    if (this.isAbsent) { return '缺勤'; }
    if (this.hasEnded) { return '已结束'; }
    return '状态待确认';
  }

  merge(other: Attendance): void {
    if (this.id !== other.id) { return; }
    this.courseID = other.courseID ?? this.courseID;
    this.courseName = other.courseName ?? this.courseName;
    this.date = other.date ?? this.date;
    this.rawDate = other.rawDate ?? this.rawDate;
    if (other.kind !== AttendanceKind.Unknown) { this.kind = other.kind; }
    this.activityStatus = other.activityStatus ?? this.activityStatus;
    const status = Attendance.recognizedPersonalStatus(other.personalStatus);
    if (status !== undefined && !(['on_call_late', 'late'].includes(this.personalStatus ?? '') &&
      ['on_call', 'present', 'attended'].includes(status))) {
      this.personalStatus = status;
    }
    this.isExpired = other.isExpired ?? this.isExpired;
    this.numberCode = other.numberCode ?? this.numberCode;
    this.endDate = other.endDate ?? this.endDate;
  }

  clone(): Attendance {
    const copy = new Attendance(this.id);
    copy.merge(this);
    return copy;
  }
}

export class DataPage<T> {
  constructor(public items: T[], public page: number, public pages?: number, public total?: number,
    public hasMore: boolean = true, public completenessKnown: boolean = false) {}
}

export class PageParser {
  static parse<T>(json: JSONValue, key: string, page: number, size: number,
    transform: (value: JSONValue) => T): DataPage<T> {
    const container = json.field('data').isObject ? json.field('data') : json;
    const raw = container.array ?? container.field(key).array ?? container.field('data').array;
    if (raw === undefined) { throw new RollcallError('malformedResponse'); }
    const pages = container.field('pages').integer ?? json.field('pages').integer;
    const total = container.field('total').integer ?? json.field('total').integer;
    const flag = container.field('has_more').boolean ?? json.field('has_more').boolean;
    const known = pages !== undefined || total !== undefined || flag !== undefined;
    // A short page does not prove completion: the school may cap its actual page size.
    const more = flag ?? (pages !== undefined ? page < pages :
      (total !== undefined ? page * size < total : raw.length > 0));
    return new DataPage<T>(raw.map(transform), page, pages, total, more && raw.length > 0, known);
  }
}

export class PageAccumulator<T extends Identified> {
  items: T[] = [];
  nextPage: number = 1;
  hasMore: boolean = true;
  note: string = '';

  append(page: DataPage<T>): void {
    const seen = new Set<string>(this.items.map((item: T): string => item.id));
    let added = 0;
    page.items.forEach((item: T): void => {
      if (!seen.has(item.id)) { this.items.push(item); seen.add(item.id); added += 1; }
    });
    if (page.items.length > 0 && added === 0) {
      this.hasMore = false;
      this.note = '学校返回重复记录，当前显示已取得的记录';
    } else {
      this.hasMore = page.hasMore;
      this.note = this.hasMore ? '' : (page.completenessKnown ? '已全部加载' : '已加载当前可获取的记录');
    }
    this.nextPage = page.page + 1;
  }
}
