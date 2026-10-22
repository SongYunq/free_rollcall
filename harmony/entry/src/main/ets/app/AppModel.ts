import { Attendance, AttendanceKind, Course, PageAccumulator } from '../core/Models';
import { RollcallError } from '../core/Errors';
import {
  AppData, AppStorage, AuthenticatedSession, AuthPort, AttendanceLog,
  SavedAccount, LogResult, displayDate
} from './Contracts';

export class AppModel {
  initialized: boolean = false;
  busy: boolean = false;
  notice: string = '';
  tab: number = 0;
  screen: string = 'home';
  accounts: SavedAccount[] = [];
  logs: AttendanceLog[] = [];
  courses: Course[] = [];
  records: Attendance[] = [];
  currentSession?: AuthenticatedSession;
  currentAccountID?: string;
  currentCourse?: Course;
  selectedRecord?: Attendance;
  historyNote: string = '';
  hasMore: boolean = false;
  onChange: () => void = (): void => {};
  private storage: AppStorage;
  private auth: AuthPort;
  private failures: Map<string, number> = new Map();
  private history: PageAccumulator<Attendance> = new PageAccumulator<Attendance>();
  private loginTask?: Promise<AuthenticatedSession>;
  private loginTarget?: string;

  constructor(storage: AppStorage, auth: AuthPort) {
    this.storage = storage;
    this.auth = auth;
  }

  get accountText(): string {
    const current = this.accounts.find((account: SavedAccount): boolean => account.id === this.currentAccountID);
    if (current !== undefined) {
      return `${this.currentSession === undefined ? '待重新登录' : '当前账号'} · ${current.username}`;
    }
    const fallback = this.accounts.find((account: SavedAccount): boolean => account.isDefault);
    return fallback === undefined ? '尚未设置账号' : `默认账号 · ${fallback.username}`;
  }

  async initialize(): Promise<void> {
    if (this.initialized) { return; }
    const data = await this.storage.load();
    let recovered = false;
    for (const log of data.logs) {
      if (log.result === LogResult.Processing) {
        log.result = LogResult.Uncertain;
        log.message = '上次操作中断，请使用原账号核对签到状态';
        recovered = true;
      }
    }
    if (recovered) { await this.storage.save(data); }
    this.accounts = data.accounts.sort((a: SavedAccount, b: SavedAccount): number => a.createdAt - b.createdAt);
    this.logs = data.logs.sort((a: AttendanceLog, b: AttendanceLog): number => b.createdAt - a.createdAt);
    this.initialized = true;
    this.onChange();
  }

  // All UI operations pass through this gate, preventing duplicate submissions and account mutations.
  async run(action: () => Promise<void>): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.notice = '';
    this.onChange();
    try {
      await action();
    } catch (error) {
      const failure = this.failure(error);
      if (failure.code !== 'cancelled') { this.notice = failure.message; }
    } finally {
      this.busy = false;
      this.onChange();
    }
  }

  clearNotice(): void { this.notice = ''; this.onChange(); }
  selectTab(index: number): void {
    if (index >= 0 && index <= 2) { this.tab = index; this.onChange(); }
  }

  back(): void {
    if (this.busy) { return; }
    if (this.screen === 'detail') { this.screen = 'attendance'; this.selectedRecord = undefined; }
    else if (this.screen === 'attendance') { this.screen = 'courses'; }
    else { this.screen = 'home'; }
    this.onChange();
  }

  private resetPages(): void {
    this.courses = [];
    this.records = [];
    this.currentCourse = undefined;
    this.selectedRecord = undefined;
    this.history = new PageAccumulator<Attendance>();
    this.historyNote = '';
    this.hasMore = false;
    this.screen = 'home';
  }

  logout(): void {
    if (this.busy) { return; }
    this.auth.cancel();
    this.currentSession = undefined;
    this.currentAccountID = undefined;
    this.resetPages();
    this.onChange();
  }

  private account(id: string): SavedAccount {
    const account = this.accounts.find((item: SavedAccount): boolean => item.id === id);
    if (account === undefined) { throw new RollcallError('message', '账号不存在，请重新选择'); }
    return account;
  }

  async password(id: string): Promise<string> {
    this.account(id);
    return await this.storage.readPassword(id);
  }

  private async persist(accounts: SavedAccount[], logs: AttendanceLog[]): Promise<void> {
    const data = new AppData();
    data.accounts = accounts;
    data.logs = logs;
    await this.storage.save(data);
    this.accounts = accounts;
    this.logs = logs.slice().sort((a: AttendanceLog, b: AttendanceLog): number => b.createdAt - a.createdAt);
    this.onChange();
  }

  async saveAccount(id: string | undefined, username: string, password: string, note: string): Promise<void> {
    const trimmed = username.trim();
    if (trimmed.length === 0 || password.length === 0) {
      throw new RollcallError('message', '账号和密码不能为空');
    }
    if (this.accounts.some((account: SavedAccount): boolean => account.username === trimmed && account.id !== id)) {
      throw new RollcallError('message', '这个账号已经存在，请修改已有账号');
    }
    const old = id === undefined ? undefined : this.account(id);
    const account = old === undefined ? new SavedAccount() : Object.assign(new SavedAccount(), old);
    let oldPassword: string | undefined;
    if (old !== undefined) {
      try { oldPassword = await this.storage.readPassword(old.id); } catch (_) { /* Allow repairing a missing vault entry. */ }
    }
    const usernameChanged = old !== undefined && old.username !== trimmed;
    const credentialsChanged = old !== undefined && (usernameChanged || oldPassword !== password);
    account.username = trimmed;
    account.note = note.trim();
    if (old === undefined) { account.isDefault = this.accounts.length === 0; }
    if (usernameChanged) { account.verifiedStudentID = undefined; }
    const accounts = old === undefined ? this.accounts.concat(account)
      : this.accounts.map((item: SavedAccount): SavedAccount => item.id === account.id ? account : item);
    await this.storage.writePassword(account.id, password);
    try {
      await this.persist(accounts, this.logs);
    } catch (_) {
      try {
        if (oldPassword !== undefined) { await this.storage.writePassword(account.id, oldPassword); }
        else { await this.storage.deletePassword(account.id); }
      } catch (_) { throw new RollcallError('message', '账号保存失败，密码恢复未完成，请重新编辑该账号'); }
      throw new RollcallError('message', '账号保存失败，请重试');
    }
    if (usernameChanged) { this.failures.delete(account.id); }
    if (credentialsChanged && this.currentAccountID === account.id) {
      this.currentSession = undefined;
      this.resetPages();
    }
    this.onChange();
  }

  async makeDefault(id: string): Promise<void> {
    this.account(id);
    const accounts = this.accounts.map((item: SavedAccount): SavedAccount => {
      const copy = Object.assign(new SavedAccount(), item);
      copy.isDefault = item.id === id;
      return copy;
    });
    await this.persist(accounts, this.logs);
  }

  async deleteAccount(id: string): Promise<void> {
    this.account(id);
    let password: string | undefined;
    try { password = await this.storage.readPassword(id); } catch (_) { /* Missing credentials do not prevent removal. */ }
    await this.storage.deletePassword(id);
    try { await this.persist(this.accounts.filter((item: SavedAccount): boolean => item.id !== id), this.logs); }
    catch (_) {
      if (password !== undefined) { await this.storage.writePassword(id, password); }
      throw new RollcallError('message', '账号删除失败，请重试');
    }
    this.failures.delete(id);
    if (this.currentAccountID === id) {
      this.currentSession = undefined;
      this.currentAccountID = undefined;
      this.resetPages();
    }
    this.onChange();
  }

  async login(id: string): Promise<void> { await this.authenticate(id); }

  private async authenticate(id: string): Promise<AuthenticatedSession> {
    if (this.loginTask !== undefined) {
      if (this.loginTarget !== id) { throw new RollcallError('message', '正在登录另一个账号，请稍候'); }
      return await this.loginTask;
    }
    const account = this.account(id);
    this.loginTarget = id;
    const task = this.performAuthentication(account);
    this.loginTask = task;
    try { return await task; }
    finally { this.loginTask = undefined; this.loginTarget = undefined; this.onChange(); }
  }

  private async performAuthentication(account: SavedAccount): Promise<AuthenticatedSession> {
    const password = await this.storage.readPassword(account.id);
    let result: AuthenticatedSession;
    try {
      result = await this.auth.authenticate(account, password, (this.failures.get(account.id) || 0) >= 3);
    } catch (error) {
      const failure = this.failure(error);
      if (failure.code !== 'invalidCredentials') { throw failure; }
      const count = (this.failures.get(account.id) || 0) + 1;
      this.failures.set(account.id, count);
      if (count < 3) {
        throw new RollcallError('message', `账号或密码错误，已连续失败 ${count} 次，请修改账号后重试`);
      }
      result = await this.auth.authenticate(account, password, true);
    }
    this.account(account.id);
    if (result.accountID !== account.id ||
      (account.verifiedStudentID !== undefined && account.verifiedStudentID !== result.profile.id)) {
      throw new RollcallError('identityMismatch');
    }
    const verified = Object.assign(new SavedAccount(), account);
    verified.verifiedStudentID = result.profile.id;
    await this.persist(this.accounts.map((item: SavedAccount): SavedAccount => item.id === verified.id ? verified : item), this.logs);
    const changed = this.currentAccountID !== account.id;
    this.currentSession = result;
    this.currentAccountID = account.id;
    this.failures.delete(account.id);
    if (changed) { this.resetPages(); }
    this.onChange();
    return result;
  }

  private async ensureSession(): Promise<AuthenticatedSession> {
    if (this.currentSession !== undefined) { return this.currentSession; }
    const id = this.currentAccountID || this.accounts.find((account: SavedAccount): boolean => account.isDefault)?.id;
    if (id === undefined) {
      this.selectTab(2);
      throw new RollcallError('noDefaultAccount');
    }
    return await this.authenticate(id);
  }

  private assertSession(session: AuthenticatedSession): void {
    if (this.currentSession?.generation !== session.generation) { throw new RollcallError('cancelled'); }
  }

  private async read<T>(operation: (session: AuthenticatedSession) => Promise<T>): Promise<T> {
    const session = await this.ensureSession();
    try {
      const result = await operation(session);
      this.assertSession(session);
      return result;
    } catch (error) {
      this.assertSession(session);
      if (this.failure(error).code !== 'expiredSession') { throw error; }
      this.currentSession = undefined;
      const renewed = await this.authenticate(session.accountID);
      const result = await operation(renewed);
      this.assertSession(renewed);
      return result;
    }
  }

  async enterCourses(): Promise<void> {
    await this.ensureSession();
    this.screen = 'courses';
    this.onChange();
    await this.loadCourses();
  }

  async loadCourses(): Promise<void> {
    const courses = await this.read((session: AuthenticatedSession): Promise<Course[]> => session.client.currentSemesterCourses());
    this.courses = courses;
    this.onChange();
  }

  async loadHistory(course: Course, reset: boolean = true): Promise<void> {
    const changed = this.currentCourse?.id !== course.id;
    if (changed) {
      this.records = [];
      this.history = new PageAccumulator<Attendance>();
      this.historyNote = '';
    }
    this.currentCourse = course;
    this.screen = 'attendance';
    this.onChange();
    if (!reset && !this.history.hasMore) { return; }
    const page = reset || changed ? 1 : this.history.nextPage;
    const data = await this.read((session: AuthenticatedSession) => session.client.history(course.id, session.profile.id, page));
    const previous = this.records;
    if (reset || changed) { this.history = new PageAccumulator<Attendance>(); }
    this.history.append(data);
    this.records = this.history.items.map((item: Attendance): Attendance => {
      const known = reset ? undefined : previous.find((old: Attendance): boolean => old.id === item.id);
      const record = known === undefined ? item.clone() : known.clone();
      record.courseID = course.id;
      record.courseName = course.name;
      return record;
    });
    const warnings: string[] = [];
    try {
      const active = await this.read((session: AuthenticatedSession): Promise<Attendance[]> => session.client.active());
      for (const item of active) {
        if (item.courseID !== undefined && item.courseID !== course.id) { continue; }
        const known = this.records.find((record: Attendance): boolean => record.id === item.id);
        if (known !== undefined) { known.merge(item); }
        else if (item.courseID === course.id) {
          const record = item.clone();
          record.courseName = course.name;
          this.records.push(record);
        }
      }
    } catch (_) { warnings.push('当前活动刷新失败，可刷新重试'); }
    const missing = this.records.filter((record: Attendance): boolean =>
      (record.kind === AttendanceKind.Number && !record.numberCode) || record.kind === AttendanceKind.Unknown);
    const days = new Map<string, number>();
    let incomplete = false;
    for (const record of missing) {
      if (record.date === undefined) { incomplete = true; continue; }
      days.set(displayDate(record.date).slice(0, 10), record.date);
    }
    for (const day of days.keys()) {
      try {
        const details = await this.read((session: AuthenticatedSession): Promise<Attendance[]> =>
          session.client.timetable(course.id, days.get(day)!, session.profile.id));
        for (const record of missing.filter((item: Attendance): boolean => displayDate(item.date).slice(0, 10) === day)) {
          const detail = details.find((item: Attendance): boolean => item.id === record.id);
          if (detail === undefined) { incomplete = true; continue; }
          // Code enrichment must not erase personal or activity status already known from history.
          record.numberCode = detail.numberCode || record.numberCode;
          if (record.kind === AttendanceKind.Unknown) { record.kind = detail.kind; }
          if (record.kind === AttendanceKind.Number && !record.numberCode) { incomplete = true; }
        }
      } catch (_) { incomplete = true; }
    }
    if (incomplete) { warnings.push('部分签到码未获取，可刷新重试'); }
    this.records.sort((a: Attendance, b: Attendance): number =>
      a.isActive !== b.isActive ? (a.isActive ? -1 : 1) : (b.date || 0) - (a.date || 0));
    this.hasMore = this.history.hasMore;
    this.historyNote = [this.history.note].concat(warnings).filter((text: string): boolean => text.length > 0).join('；');
    this.onChange();
  }

  private async queryDate(id: string, courseID: string, date: number | undefined, session: AuthenticatedSession): Promise<number> {
    if (date !== undefined && Number.isFinite(date)) { return date; }
    const history = new PageAccumulator<Attendance>();
    while (history.hasMore && history.nextPage <= 100) {
      const page = await session.client.history(courseID, session.profile.id, history.nextPage);
      this.assertSession(session);
      const record = page.items.find((item: Attendance): boolean => item.id === id);
      if (record !== undefined) {
        if (record.date !== undefined) { return record.date; }
        break;
      }
      history.append(page);
    }
    throw new RollcallError('message', '未能找到本次签到的原始日期，请刷新课程记录后重试');
  }

  private mergeRecord(detail: Attendance): Attendance {
    const old = this.records.find((item: Attendance): boolean => item.id === detail.id);
    const merged = old === undefined ? detail.clone() : old.clone();
    merged.merge(detail);
    this.records = this.records.map((item: Attendance): Attendance => item.id === merged.id ? merged : item);
    if (this.selectedRecord?.id === merged.id) { this.selectedRecord = merged; }
    this.onChange();
    return merged;
  }

  async showDetail(record: Attendance): Promise<void> {
    this.selectedRecord = record.clone();
    this.screen = 'detail';
    this.onChange();
    await this.refreshDetail();
  }

  async refreshDetail(): Promise<void> {
    const record = this.selectedRecord;
    const courseID = record?.courseID || this.currentCourse?.id;
    if (record === undefined || courseID === undefined) { throw new RollcallError('message', '请从课程重新打开签到'); }
    const detail = await this.read(async (session: AuthenticatedSession): Promise<Attendance> => {
      const date = await this.queryDate(record.id, courseID, record.date, session);
      return await session.client.detail(record.id, courseID, date, session.profile.id);
    });
    this.selectedRecord = this.mergeRecord(detail);
  }

  private async updateLog(id: string, result: LogResult, message: string, record?: Attendance): Promise<void> {
    const logs = this.logs.map((item: AttendanceLog): AttendanceLog => {
      if (item.id !== id) { return item; }
      const log = Object.assign(new AttendanceLog(), item);
      log.result = result;
      log.message = message;
      if (result !== LogResult.Processing) { log.completedAt = Date.now(); }
      if (record !== undefined) {
        log.code = record.numberCode;
        log.kind = record.kind;
        log.rollcallDate = record.date || log.rollcallDate;
      }
      return log;
    });
    await this.persist(this.accounts, logs);
  }

  async submit(record: Attendance): Promise<void> {
    const course = this.currentCourse;
    const id = this.currentAccountID || this.accounts.find((item: SavedAccount): boolean => item.isDefault)?.id;
    if (course === undefined || id === undefined) { throw new RollcallError('noDefaultAccount'); }
    const account = this.account(id);
    const log = new AttendanceLog();
    log.accountID = account.id;
    log.username = account.username;
    log.accountNote = account.note;
    log.studentID = account.verifiedStudentID || '';
    log.courseID = course.id;
    log.courseName = course.name;
    log.rollcallID = record.id;
    log.rollcallDate = record.date;
    log.kind = record.kind;
    log.code = record.numberCode;
    await this.persist(this.accounts, [log].concat(this.logs));
    let accepted = false;
    try {
      const session = await this.ensureSession();
      if (session.accountID !== account.id) { throw new RollcallError('identityMismatch'); }
      const date = await this.queryDate(record.id, course.id, record.date, session);
      const fresh = record.clone();
      fresh.merge(await session.client.detail(record.id, course.id, date, session.profile.id));
      fresh.date = date;
      this.assertSession(session);
      this.mergeRecord(fresh);
      const entry = this.logs.find((item: AttendanceLog): boolean => item.id === log.id)!;
      // Persist identity and original date before the first write to the school.
      const copy = Object.assign(new AttendanceLog(), entry);
      copy.studentID = session.profile.id;
      copy.rollcallDate = date;
      await this.persist(this.accounts, this.logs.map((item: AttendanceLog): AttendanceLog => item.id === log.id ? copy : item));
      if (fresh.isAnswered) {
        await this.updateLog(log.id, LogResult.Success, '该账号已签到，本次未重复提交', fresh);
        this.notice = '已签到，无需重复提交';
        return;
      }
      if (!fresh.isActive) { throw new RollcallError('message', '签到已结束或状态未确认，请刷新后重试'); }
      if (!fresh.canSubmit) { throw new RollcallError('message', '暂不支持此签到形式'); }
      await this.updateLog(log.id, LogResult.Processing, '正在提交签到', fresh);
      if (fresh.kind === AttendanceKind.Number) {
        if (!fresh.numberCode) { throw new RollcallError('message', '未能取得数字签到码'); }
        fresh.merge(await session.client.submitNumber(fresh.id, fresh.numberCode, course.id, date, session.profile.id));
      } else {
        if (!await session.client.submitRadar(fresh.id)) { throw new RollcallError('message', '雷达签到未完成，请稍后重试'); }
        fresh.personalStatus = 'on_call_fine';
      }
      accepted = true;
      this.assertSession(session);
      this.mergeRecord(fresh);
      await this.updateLog(log.id, LogResult.Success, '签到成功', fresh);
      this.notice = '签到成功';
      this.onChange();
    } catch (error) {
      const failure = this.failure(error);
      if (failure.code === 'expiredSession') { this.currentSession = undefined; }
      const result = accepted || failure.code === 'uncertain' ? LogResult.Uncertain : LogResult.Failure;
      try { await this.updateLog(log.id, result, failure.message); }
      catch (_) {
        this.notice = '本地记录保存失败，请先核对学校端结果，勿重复提交';
        this.onChange();
        return;
      }
      throw failure;
    }
  }

  async reconcile(id: string): Promise<void> {
    const log = this.logs.find((item: AttendanceLog): boolean => item.id === id);
    if (log === undefined) { throw new RollcallError('message', '记录不存在'); }
    const session = this.currentSession;
    if (session === undefined || this.currentAccountID !== log.accountID) {
      throw new RollcallError('message', '请先在账号管理登录这条记录对应的账号');
    }
    if (session.profile.id !== log.studentID) { throw new RollcallError('identityMismatch'); }
    try {
      const date = await this.queryDate(log.rollcallID, log.courseID, log.rollcallDate, session);
      const detail = await session.client.detail(log.rollcallID, log.courseID, date, log.studentID);
      this.assertSession(session);
      detail.date = date;
      if (detail.isAnswered) { await this.updateLog(log.id, LogResult.Success, '已核对：学校记录显示已签到', detail); }
      else if (detail.isAbsent) { await this.updateLog(log.id, LogResult.Failure, '签到已结束，未查到本人签到成功记录', detail); }
      else { await this.updateLog(log.id, LogResult.Uncertain, '暂未确认签到成功，可稍后再次核对', detail); }
    } catch (error) {
      if (this.failure(error).code === 'expiredSession') { this.currentSession = undefined; }
      throw error;
    }
  }

  private failure(error: unknown): RollcallError {
    // Do not include native errors, URLs, cookies or submitted credentials in user logs.
    if (error instanceof RollcallError) { return error; }
    return new RollcallError('message', '操作未完成，请检查网络或本机存储后重试');
  }
}
