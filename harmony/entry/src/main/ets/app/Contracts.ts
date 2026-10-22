import { UserProfile, AttendanceKind } from '../core/Models';
import { TronclassClient } from '../core/TronclassClient';

export function newID(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
}

export class SavedAccount {
  id: string = newID();
  username: string = '';
  note: string = '';
  isDefault: boolean = false;
  verifiedStudentID?: string;
  createdAt: number = Date.now();

  get label(): string { return this.note.length > 0 ? this.note : this.username; }
}

export enum LogResult {
  Processing = 'processing',
  Success = 'success',
  Failure = 'failure',
  Uncertain = 'uncertain'
}

export class AttendanceLog {
  id: string = newID();
  createdAt: number = Date.now();
  completedAt?: number;
  accountID: string = '';
  username: string = '';
  accountNote: string = '';
  studentID: string = '';
  courseID: string = '';
  courseName: string = '';
  rollcallID: string = '';
  rollcallDate?: number;
  kind: AttendanceKind = AttendanceKind.Unknown;
  code?: string;
  result: LogResult = LogResult.Processing;
  message: string = '正在准备签到';

  get resultTitle(): string {
    if (this.result === LogResult.Success) { return '成功'; }
    if (this.result === LogResult.Failure) { return '失败'; }
    if (this.result === LogResult.Processing) { return '处理中'; }
    return '待确认';
  }

  get codeText(): string {
    return this.kind === AttendanceKind.Radar ? '雷达签到' : (this.code || '未获取');
  }
}

export class AppData {
  version: number = 1;
  accounts: SavedAccount[] = [];
  logs: AttendanceLog[] = [];
}

export interface AppStorage {
  load(): Promise<AppData>;
  save(data: AppData): Promise<void>;
  readPassword(id: string): Promise<string>;
  writePassword(id: string, password: string): Promise<void>;
  deletePassword(id: string): Promise<void>;
}

export class AuthenticatedSession {
  accountID: string;
  generation: string;
  profile: UserProfile;
  client: TronclassClient;

  constructor(accountID: string, generation: string, profile: UserProfile, client: TronclassClient) {
    this.accountID = accountID;
    this.generation = generation;
    this.profile = profile;
    this.client = client;
  }
}

export interface AuthPort {
  authenticate(account: SavedAccount, password: string, forceManual: boolean): Promise<AuthenticatedSession>;
  cancel(): void;
}

export function displayDate(timestamp?: number): string {
  if (timestamp === undefined || !Number.isFinite(timestamp)) { return '时间未知'; }
  const date = new Date(timestamp + 8 * 60 * 60 * 1000);
  const pad = (value: number): string => value.toString().padStart(2, '0');
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())}`;
}
