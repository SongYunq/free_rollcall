import { common } from '@kit.AbilityKit';
import { AppModel } from '../app/AppModel';
import { AttendanceLog, LogResult, SavedAccount, displayDate } from '../app/Contracts';
import { Attendance, AttendanceKind, Course, attendanceKindTitle } from '../core/Models';
import { AppRuntime, getRuntime } from '../platform/AppRuntime';

// The portable model is deliberately framework independent. Replacing this small
// snapshot makes every model notification visible to ArkUI's state system.
class ViewState {
  revision: number = 0;
  ready: boolean = false;
  busy: boolean = false;
  tab: number = 0;
  screen: string = 'home';
  notice: string = '';
  accountText: string = '尚未设置账号';
  currentAccountID: string = '';
  authenticated: boolean = false;
  accounts: SavedAccount[] = [];
  logs: AttendanceLog[] = [];
  courses: Course[] = [];
  records: Attendance[] = [];
  courseName: string = '';
  selectedRecord?: Attendance;
  historyNote: string = '';
  hasMore: boolean = false;
  authActive: boolean = false;
  authManual: boolean = false;
  authVerifying: boolean = false;
  authProgress: string = '';
  authAccount: string = '';
  authViewID: number = 0;

  static capture(runtime: AppRuntime, revision: number): ViewState {
    const result = new ViewState();
    const model = runtime.model;
    result.revision = revision;
    result.ready = model.initialized;
    result.busy = model.busy;
    result.tab = model.tab;
    result.screen = model.screen;
    result.notice = model.notice;
    result.accountText = model.accountText;
    result.currentAccountID = model.currentAccountID ?? '';
    result.authenticated = model.currentSession !== undefined;
    result.accounts = model.accounts.slice();
    result.logs = model.logs.slice();
    result.courses = model.courses.slice();
    result.records = model.records.slice();
    result.courseName = model.currentCourse?.name ?? '';
    result.selectedRecord = model.selectedRecord;
    result.historyNote = model.historyNote;
    result.hasMore = model.hasMore;
    result.authActive = runtime.authenticator.active;
    result.authManual = runtime.authenticator.manual;
    result.authVerifying = runtime.authenticator.verifying;
    result.authProgress = runtime.authenticator.progress;
    result.authAccount = runtime.authenticator.displayAccount;
    result.authViewID = runtime.authenticator.viewID;
    return result;
  }
}

@Entry
@Component
struct Index {
  @State private view: ViewState = new ViewState();
  @State private editing: boolean = false;
  @State private editingID: string = '';
  @State private username: string = '';
  @State private password: string = '';
  @State private note: string = '';
  @State private visiblePassword: boolean = true;
  @State private deletingID: string = '';
  @State private selectedLogID: string = '';
  @State private refreshing: boolean = false;
  private runtime?: AppRuntime;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      const view = new ViewState();
      view.notice = '页面尚未就绪，请重新打开应用';
      this.view = view;
      return;
    }
    this.runtime = getRuntime(context as common.UIAbilityContext);
    this.runtime.model.onChange = (): void => this.synchronize();
    this.runtime.authenticator.onChange = (): void => this.synchronize();
    this.synchronize();
    this.perform(async (): Promise<void> => { await this.model().initialize(); });
  }

  aboutToDisappear(): void {
    if (this.runtime !== undefined) {
      if (this.runtime.authenticator.active) { this.runtime.authenticator.cancel(); }
      this.runtime.model.onChange = (): void => {};
      this.runtime.authenticator.onChange = (): void => {};
    }
  }

  onBackPress(): boolean {
    if (this.view.authActive) { this.cancelAuthentication(); return true; }
    if (this.view.notice.length > 0) { this.dismissNotice(); return true; }
    if (this.deletingID.length > 0) { this.deletingID = ''; return true; }
    if (this.editing) { if (!this.view.busy) { this.closeEditor(); } return true; }
    if (this.selectedLogID.length > 0) { this.selectedLogID = ''; return true; }
    if (this.view.tab === 0 && this.view.screen !== 'home') {
      if (!this.view.busy) { this.model().back(); }
      return true;
    }
    return false;
  }

  private model(): AppModel {
    if (this.runtime === undefined) { throw new Error('应用尚未完成初始化'); }
    return this.runtime.model;
  }

  private dismissNotice(): void {
    if (this.runtime !== undefined) { this.runtime.model.clearNotice(); }
    else { this.aboutToAppear(); }
  }

  private synchronize(): void {
    if (this.runtime !== undefined) {
      this.view = ViewState.capture(this.runtime, this.view.revision + 1);
    }
  }

  private perform(action: () => Promise<void>): void {
    if (this.runtime === undefined) { return; }
    this.model().run(action);
  }

  private selectTab(index: number): void {
    if (this.editing || this.view.authActive) { return; }
    this.model().selectTab(index);
  }

  private openEditor(account?: SavedAccount): void {
    if (this.view.busy || !this.view.ready) { return; }
    this.editingID = account?.id ?? '';
    this.username = account?.username ?? '';
    this.password = '';
    this.note = account?.note ?? '';
    this.visiblePassword = true;
    this.editing = true;
    if (account !== undefined) {
      const accountID = account.id;
      this.perform(async (): Promise<void> => {
        const value = await this.model().password(accountID);
        if (this.editing && this.editingID === accountID) { this.password = value; }
      });
    }
  }

  private saveEditor(): void {
    this.perform(async (): Promise<void> => {
      await this.model().saveAccount(this.editingID.length > 0 ? this.editingID : undefined,
        this.username, this.password, this.note);
      this.closeEditor();
    });
  }

  private closeEditor(): void {
    this.editing = false;
    this.password = '';
  }

  private openAttendance(record: Attendance): void {
    this.perform(async (): Promise<void> => {
      if (record.canSubmit) { await this.model().submit(record); }
      else { await this.model().showDetail(record); }
    });
  }

  private refreshCurrent(): void {
    if (this.view.busy) { this.refreshing = false; return; }
    this.refreshing = true;
    this.perform(async (): Promise<void> => {
      try {
        if (this.view.screen === 'courses') { await this.model().loadCourses(); }
        else if (this.view.screen === 'detail') { await this.model().refreshDetail(); }
        else if (this.model().currentCourse !== undefined) {
          await this.model().loadHistory(this.model().currentCourse as Course, true);
        }
      } finally { this.refreshing = false; }
    });
  }

  private cancelAuthentication(): void {
    this.runtime?.authenticator.cancel();
  }

  private log(): AttendanceLog | undefined {
    return this.view.logs.find((item: AttendanceLog): boolean => item.id === this.selectedLogID);
  }

  private dateText(record: Attendance): string {
    return record.date !== undefined ? displayDate(record.date) : (record.rawDate ?? '时间未提供');
  }

  private title(): string {
    if (this.view.tab === 1) { return '本地日志'; }
    if (this.view.tab === 2) { return '账号管理'; }
    if (this.view.screen === 'courses') { return '本学期课程'; }
    if (this.view.screen === 'attendance') { return '课程签到'; }
    if (this.view.screen === 'detail') { return '签到详情'; }
    return '功能';
  }

  @Builder
  private icon(source: Resource, size: number = 24, opacity: number = 1) {
    Image(source).width(size).height(size).objectFit(ImageFit.Contain)
      .opacity(opacity)
      .accessibilityLevel('no')
  }

  @Builder
  private separator() {
    Divider().color('#EEEEEE').strokeWidth(0.5)
  }

  @Builder
  private message(text: string) {
    Text(text).fontSize(13).fontColor('#757575').lineHeight(20)
      .width('100%').padding({ top: 12, bottom: 12 }).textAlign(TextAlign.Start)
  }

  @Builder
  private emptyState(icon: Resource, title: string, description: string = '') {
    Column({ space: 12 }) {
      this.icon(icon, 42, 0.7)
      Text(title).fontSize(20).fontWeight(FontWeight.Medium).fontColor('#333333')
      if (description.length > 0) {
        Text(description).fontSize(14).fontColor('#777777').textAlign(TextAlign.Center).lineHeight(22)
      }
    }.width('100%').padding({ top: 80, bottom: 48, left: 24, right: 24 })
  }

  @Builder
  private pageHeader() {
    if (this.view.tab === 0 && this.view.screen !== 'home') {
      Row({ space: 10 }) {
        Button({ type: ButtonType.Circle }) { this.icon($r('app.media.icon_back'), 22) }
          .width(40).height(40).backgroundColor(Color.Transparent).accessibilityText('返回')
          .enabled(!this.view.busy).onClick((): void => this.model().back())
        Text(this.title()).fontSize(18).fontWeight(FontWeight.Medium).fontColor('#222222').layoutWeight(1).maxLines(1)
        Button({ type: ButtonType.Circle }) { this.icon($r('app.media.icon_refresh'), 21) }
          .width(40).height(40).backgroundColor(Color.Transparent).accessibilityText('刷新')
          .enabled(!this.view.busy).onClick((): void => this.refreshCurrent())
      }.height(58).width('100%').padding({ left: 12, right: 14 })
    } else {
      Column({ space: 6 }) {
        if (this.view.tab === 2 && this.view.currentAccountID.length > 0) {
          Row() {
            Button('退出登录').fontSize(14).fontColor('#555555').backgroundColor(Color.Transparent)
              .padding(0).height(32).enabled(!this.view.busy)
              .onClick((): void => this.model().logout())
            Blank()
          }.width('100%')
        }
        Row() {
          Text(this.title()).fontSize(34).fontWeight(FontWeight.Bold).fontColor('#111111').layoutWeight(1)
          if (this.view.tab === 2) {
            Button({ type: ButtonType.Circle }) { this.icon($r('app.media.icon_plus'), 23) }
              .width(42).height(42).backgroundColor(Color.Transparent).accessibilityText('添加账号')
              .enabled(!this.view.busy && this.view.ready).onClick((): void => this.openEditor())
          }
        }.width('100%')
      }.padding({ left: 24, right: 20, top: 20, bottom: 14 }).width('100%')
    }
  }

  @Builder
  private homePage() {
    List() {
      ListItem() {
        Column({ space: 8 }) {
          Text('free_rollcall').fontSize(12).fontFamily('monospace').fontColor('#868686')
          Text(this.view.accountText).fontSize(15).fontColor('#333333')
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 14, bottom: 28 })
      }
      ListItem() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 16 }) {
            this.icon($r('app.media.icon_books'), 30)
            Column({ space: 7 }) {
              Text('进入课程').fontSize(18).fontWeight(FontWeight.Medium).fontColor('#161616')
              Text('查看本学期课程与签到记录').fontSize(14).fontColor('#777777')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.view.busy) { LoadingProgress().width(22).height(22).color('#666666') }
            else { this.icon($r('app.media.icon_chevron'), 16, 0.7) }
          }.width('100%').padding({ top: 22, bottom: 26 })
        }.backgroundColor(Color.Transparent).padding(0).width('100%').enabled(!this.view.busy && this.view.ready)
          .onClick((): void => this.perform(async (): Promise<void> => { await this.model().enterCourses(); }))
          .id('enter-courses').accessibilityText('进入课程，查看本学期课程与签到记录')
      }
      ListItem() { this.separator() }
      if (!this.view.ready && !this.view.busy) {
        ListItem() {
          Column({ space: 8 }) {
            this.message('本地数据尚未加载，请重试后继续使用')
            Button('重新加载本地数据').width('100%').height(46).fontSize(15).fontColor(Color.White)
              .backgroundColor('#161616').borderRadius(12)
              .onClick((): void => this.perform(async (): Promise<void> => { await this.model().initialize(); }))
          }.width('100%').padding({ bottom: 20 })
        }
      }
    }.width('100%').height('100%').padding({ left: 24, right: 24 }).scrollBar(BarState.Off)
  }

  @Builder
  private coursesPage() {
    Refresh({ refreshing: $$this.refreshing }) {
      List() {
        ListItem() { this.message(this.view.accountText) }
        ForEach(this.view.courses, (course: Course) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Column() {
                Row({ space: 16 }) {
                  this.icon($r('app.media.icon_book'), 24, 0.7)
                  Text(course.name).fontSize(17).fontColor('#222222').lineHeight(25).layoutWeight(1)
                  this.icon($r('app.media.icon_chevron'), 16, 0.7)
                }.padding({ top: 24, bottom: 24 }).width('100%')
                this.separator()
              }
            }.backgroundColor(Color.Transparent).padding(0).width('100%').enabled(!this.view.busy)
              .onClick((): void => this.perform(async (): Promise<void> => { await this.model().loadHistory(course, true); }))
              .accessibilityText(course.name + '，查看签到记录')
          }
        }, (course: Course): string => course.id + '-' + this.view.revision)
        if (this.view.courses.length === 0 && !this.view.busy) {
          ListItem() { this.emptyState($r('app.media.icon_books'), '本学期暂无课程') }
        }
        if (this.view.busy) { ListItem() { this.loadingRow('正在加载课程') } }
      }.width('100%').height('100%').padding({ left: 24, right: 24 }).scrollBar(BarState.Off)
    }.onRefreshing((): void => this.refreshCurrent()).height('100%')
  }

  @Builder
  private loadingRow(text: string) {
    Row({ space: 10 }) {
      LoadingProgress().width(22).height(22).color('#777777')
      Text(text).fontSize(14).fontColor('#777777')
    }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 22, bottom: 22 })
  }

  @Builder
  private attendancePage() {
    Refresh({ refreshing: $$this.refreshing }) {
      List() {
        ListItem() {
          Column({ space: 10 }) {
            Text(this.view.courseName).fontSize(19).fontWeight(FontWeight.Medium).fontColor('#222222').lineHeight(27)
            Text(this.view.accountText).fontSize(12).fontColor('#808080')
          }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 14, bottom: 18 })
        }
        ForEach(this.view.records, (record: Attendance) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Column() {
                Row({ space: 14 }) {
                  this.icon(record.kind === AttendanceKind.Radar ? $r('app.media.icon_radar') : $r('app.media.icon_number'), 26)
                  Column({ space: 10 }) {
                    Row({ space: 8 }) {
                      Text(attendanceKindTitle(record.kind)).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#222222').layoutWeight(1)
                      Text(record.stateText).fontSize(12).fontColor(record.isAbsent ? '#C73535' : '#777777')
                    }.width('100%')
                    Text(this.dateText(record)).fontSize(12).fontFamily('monospace').fontColor('#777777')
                    if (record.kind === AttendanceKind.Number) {
                      Text('签到码  ' + (record.numberCode || (this.view.busy ? '正在获取…' : '未获取')))
                        .fontSize(17).fontFamily('monospace').fontWeight(FontWeight.Medium).fontColor('#222222')
                        .copyOption(CopyOptions.LocalDevice)
                    }
                    if (record.canSubmit) {
                      Text(this.view.busy ? '请等待当前操作完成' : '点击此条目签到').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#333333')
                    }
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.alignItems(VerticalAlign.Top).width('100%').padding({ top: 22, bottom: 22 })
                this.separator()
              }
            }.backgroundColor(Color.Transparent).fontColor('#222222').width('100%').padding(0)
              .enabled(!this.view.busy).onClick((): void => this.openAttendance(record))
              .id('attendance-' + record.id)
          }
        }, (record: Attendance): string => record.id + '-' + this.view.revision)
        if (this.view.records.length === 0 && !this.view.busy) {
          ListItem() { this.emptyState($r('app.media.icon_clock'), '暂无签到记录') }
        }
        if (this.view.busy) { ListItem() { this.loadingRow('正在处理，请稍候') } }
        if (this.view.hasMore && !this.view.busy) {
          ListItem() {
            Button('加载更多记录').fontSize(15).fontColor('#333333').backgroundColor(Color.Transparent)
              .width('100%').height(58).onClick((): void => this.perform(async (): Promise<void> => {
                const course = this.model().currentCourse;
                if (course !== undefined) { await this.model().loadHistory(course, false); }
              }))
          }
        }
        if (this.view.historyNote.length > 0) { ListItem() { this.message(this.view.historyNote) } }
      }.width('100%').height('100%').padding({ left: 24, right: 24 }).scrollBar(BarState.Off)
    }.onRefreshing((): void => this.refreshCurrent()).height('100%')
  }

  @Builder
  private field(title: string, value: string) {
    Column() {
      Row({ space: 20 }) {
        Text(title).fontSize(14).fontColor('#777777').width(72)
        Text(value).fontSize(15).fontColor('#222222').layoutWeight(1).textAlign(TextAlign.End)
          .lineHeight(23).copyOption(CopyOptions.LocalDevice)
      }.width('100%').padding({ top: 17, bottom: 17 }).alignItems(VerticalAlign.Top)
      this.separator()
    }
  }

  @Builder
  private attendanceDetail(record: Attendance) {
    Scroll() {
      Column() {
        this.field('课程', this.view.courseName)
        this.field('时间', this.dateText(record))
        this.field('形式', attendanceKindTitle(record.kind))
        this.field('状态', record.stateText)
        if (record.kind === AttendanceKind.Number) { this.field('签到码', record.numberCode || '未获取') }
        if (record.kind === AttendanceKind.Radar) { this.field('签到码', '雷达签到') }
        if (record.canSubmit) {
          Button('立即签到').width('100%').height(48).fontColor(Color.White).fontSize(16)
            .backgroundColor('#161616').borderRadius(12).margin({ top: 24 })
            .enabled(!this.view.busy && this.view.authenticated)
            .onClick((): void => this.perform(async (): Promise<void> => { await this.model().submit(record); }))
        }
        if (this.view.busy) { this.loadingRow('正在加载签到详情') }
        if (this.view.historyNote.length > 0) { this.message(this.view.historyNote) }
      }.width('100%').padding({ left: 24, right: 24, bottom: 24 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  @Builder
  private accountsPage() {
    List() {
      ListItem() {
        Column({ space: 10 }) {
          Text(this.view.accountText).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#333333')
          Text('向左滑动账号可登录、修改、设为默认或删除\n未登录时，使用功能会自动登录默认账号')
            .fontSize(13).fontColor('#777777').lineHeight(21)
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 12, bottom: 24 })
      }
      if (this.view.accounts.length === 0) {
        ListItem() {
          this.emptyState($r('app.media.icon_person'), '添加你的第一个账号', '账号保存在本机，可随时修改或删除')
        }
        ListItem() {
          Button('添加账号').width('100%').height(46).fontSize(16).fontColor(Color.White)
            .backgroundColor('#161616').borderRadius(12).enabled(!this.view.busy && this.view.ready)
            .onClick((): void => this.openEditor())
        }
      }
      ForEach(this.view.accounts, (account: SavedAccount) => {
        ListItem() {
          Column() {
            Row({ space: 16 }) {
              this.icon($r('app.media.icon_person'), 34)
              Column({ space: 6 }) {
                Text(account.label).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#222222').maxLines(2)
                if (account.note.length > 0) {
                  Text(account.username).fontSize(14).fontFamily('monospace').fontColor('#777777')
                }
                if (account.isDefault || this.view.currentAccountID === account.id) {
                  Row({ space: 10 }) {
                    if (account.isDefault) { Text('默认').fontSize(12).fontColor('#777777') }
                    if (this.view.currentAccountID === account.id) {
                      Text(this.view.authenticated ? '使用中' : '待登录').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#333333')
                    }
                  }
                }
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%').padding({ top: 20, bottom: 20 })
            this.separator()
          }.width('100%').enabled(!this.view.busy).id('account-' + account.username)
        }.swipeAction({ end: (): void => this.accountActions(account), edgeEffect: SwipeEdgeEffect.None })
      }, (account: SavedAccount): string => account.id + '-' + this.view.revision)
    }.width('100%').height('100%').padding({ left: 24, right: 24 }).scrollBar(BarState.Off)
  }

  @Builder
  private accountActions(account: SavedAccount) {
    Row() {
      Button('登录', { type: ButtonType.Normal }).height('100%').width(58).fontSize(14).padding(0)
        .fontColor(Color.White).backgroundColor('#181818').enabled(!this.view.busy)
        .onClick((): void => this.perform(async (): Promise<void> => { await this.model().login(account.id); }))
      Button('修改', { type: ButtonType.Normal }).height('100%').width(58).fontSize(14).padding(0)
        .fontColor(Color.White).backgroundColor('#7C7C7C').enabled(!this.view.busy)
        .onClick((): void => this.openEditor(account))
      Button('默认', { type: ButtonType.Normal }).height('100%').width(58).fontSize(14).padding(0)
        .fontColor(Color.White).backgroundColor('#525252').enabled(!this.view.busy)
        .onClick((): void => this.perform(async (): Promise<void> => { await this.model().makeDefault(account.id); }))
      Button('删除', { type: ButtonType.Normal }).height('100%').width(58).fontSize(14).padding(0)
        .fontColor(Color.White).backgroundColor('#CB3838').enabled(!this.view.busy)
        .onClick((): void => { this.deletingID = account.id; })
    }.height('100%')
  }

  @Builder
  private logsPage() {
    List() {
      if (this.view.logs.length === 0) {
        ListItem() {
          this.emptyState($r('app.media.icon_clock'), '还没有签到记录', '签到操作的结果会保存在本机，离线也能查看')
        }
      }
      ForEach(this.view.logs, (log: AttendanceLog) => {
        ListItem() {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 10 }) {
              Row({ space: 12 }) {
                Text(log.courseName).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#222222').layoutWeight(1).lineHeight(25)
                Text(log.resultTitle).fontSize(12).fontColor(log.result === LogResult.Failure ? '#BD3636' : '#555555')
              }.alignItems(VerticalAlign.Top).width('100%')
              Text(displayDate(log.createdAt)).fontSize(12).fontFamily('monospace').fontColor('#777777')
              Row({ space: 12 }) {
                Text(attendanceKindTitle(log.kind)).fontSize(14).fontColor('#222222')
                Blank()
                Text(log.codeText).fontSize(14).fontFamily('monospace').fontColor('#222222').textAlign(TextAlign.End)
              }.width('100%')
              Text(log.accountNote.length > 0 ? log.accountNote + ' · ' + log.username : log.username)
                .fontSize(12).fontColor('#777777')
              this.separator()
            }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 20, bottom: 8 })
          }.backgroundColor(Color.Transparent).fontColor('#222222').width('100%').padding(0)
            .onClick((): void => { this.selectedLogID = log.id; })
        }
      }, (log: AttendanceLog): string => log.id + '-' + this.view.revision)
    }.width('100%').height('100%').padding({ left: 24, right: 24 }).scrollBar(BarState.Off)
  }

  @Builder
  private dockButton(index: number, title: string, icon: Resource, activeIcon: Resource) {
    Button({ type: ButtonType.Capsule }) {
      Image(this.view.tab === index ? activeIcon : icon).width(24).height(24)
        .objectFit(ImageFit.Contain).opacity(this.view.tab === index ? 1 : 0.65).accessibilityLevel('no')
    }.height(50).layoutWeight(1).margin(3)
      .backgroundColor(this.view.tab === index ? '#111111' : Color.Transparent)
      .accessibilityText(title).accessibilityDescription(this.view.tab === index ? '当前标签页' : '切换到' + title)
      .onClick((): void => this.selectTab(index))
  }

  @Builder
  private dock() {
    Row() {
      this.dockButton(0, '功能', $r('app.media.icon_grid'), $r('app.media.icon_grid_active'))
      this.dockButton(1, '本地日志', $r('app.media.icon_clock'), $r('app.media.icon_clock_active'))
      this.dockButton(2, '账号管理', $r('app.media.icon_person'), $r('app.media.icon_person_active'))
    }.padding(4).height(64).width('80%').constraintSize({ maxWidth: 360 }).borderRadius(36)
      .backgroundColor('#F4F4F4').backgroundBlurStyle(BlurStyle.Thin)
      .border({ width: 0.5, color: '#E6E6E6' })
      .shadow({ radius: 14, color: '#11000000', offsetY: 5 })
      .margin({ top: 8, bottom: 12 })
  }

  @Builder
  private modalHeader(title: string, cancel: string, action: string = '') {
    Row({ space: 10 }) {
      Button(cancel).fontSize(16).fontColor('#444444').backgroundColor(Color.Transparent)
        .width(64).height(44).padding(0).enabled(!this.view.busy)
        .onClick((): void => { this.closeEditor(); this.selectedLogID = ''; })
      Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#222222').layoutWeight(1).textAlign(TextAlign.Center)
      if (action.length > 0) {
        Button(action).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#111111')
          .backgroundColor(Color.Transparent).width(64).height(44).padding(0)
          .enabled(!this.view.busy && this.username.trim().length > 0 && this.password.length > 0)
          .onClick((): void => this.saveEditor())
      } else { Blank().width(64) }
    }.width('100%').height(60).padding({ left: 14, right: 14 })
  }

  @Builder
  private editorPage() {
    Column() {
      this.modalHeader(this.editingID.length > 0 ? '修改账号' : '添加账号', '取消', '保存')
      Scroll() {
        Column() {
          Text('登录信息').fontSize(13).fontColor('#888888').width('100%').padding({ top: 28, bottom: 12 })
          TextInput({ placeholder: '账号', text: this.username }).fontSize(16).fontColor('#222222').height(56)
            .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).borderRadius(0)
            .enabled(!this.view.busy).onChange((value: string): void => { this.username = value; }).id('username')
          this.separator()
          Row({ space: 12 }) {
            TextInput({ placeholder: '密码', text: this.password })
              .type(this.visiblePassword ? InputType.Normal : InputType.Password).showPasswordIcon(false)
              .fontSize(16).fontColor('#222222').height(56).layoutWeight(1).backgroundColor(Color.Transparent)
              .padding({ left: 0, right: 0 }).borderRadius(0).enabled(!this.view.busy)
              .onChange((value: string): void => { this.password = value; }).id('password')
            Button({ type: ButtonType.Circle }) {
              this.icon(this.visiblePassword ? $r('app.media.icon_eye_off') : $r('app.media.icon_eye'), 22, 0.7)
            }.width(40).height(40).backgroundColor(Color.Transparent)
              .accessibilityText(this.visiblePassword ? '隐藏密码' : '显示密码')
              .onClick((): void => { this.visiblePassword = !this.visiblePassword; })
          }.width('100%')
          this.separator()
          TextInput({ placeholder: '备注（可选）', text: this.note }).fontSize(16).fontColor('#222222').height(56)
            .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).borderRadius(0)
            .enabled(!this.view.busy).onChange((value: string): void => { this.note = value; }).id('account-note')
          this.separator()
          this.message('账号保存在本机，可随时修改或删除\n第一个账号会自动设为默认账号')
          if (this.view.busy) { this.loadingRow('正在处理，请稍候') }
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 24, right: 24, bottom: 32 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(Color.White)
  }

  @Builder
  private logDetail(log: AttendanceLog) {
    Column() {
      this.modalHeader('签到记录', '完成')
      Scroll() {
        Column() {
          this.field('时间', displayDate(log.createdAt))
          this.field('课程', log.courseName)
          this.field('签到形式', attendanceKindTitle(log.kind))
          this.field('结果', log.resultTitle)
          this.field('账号', log.username)
          if (log.accountNote.length > 0) { this.field('备注', log.accountNote) }
          this.field('签到码', log.codeText)
          this.message(log.message)
          if (log.result === LogResult.Uncertain) {
            Button('核对学校端结果').height(48).width('100%').fontSize(16).fontColor(Color.White)
              .backgroundColor('#161616').borderRadius(12).enabled(!this.view.busy)
              .onClick((): void => this.perform(async (): Promise<void> => { await this.model().reconcile(log.id); }))
            this.message('使用本条记录对应的账号查询，不会再次提交签到')
          }
          if (this.view.busy) { this.loadingRow('正在核对，请稍候') }
        }.width('100%').padding({ left: 24, right: 24, bottom: 30 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(Color.White)
  }

  @Builder
  private authenticationPage() {
    Column() {
      Row() {
        Button('取消').fontSize(16).fontColor('#444444').backgroundColor(Color.Transparent)
          .height(44).width(64).onClick((): void => this.cancelAuthentication())
        Text(this.view.authVerifying ? '正在进入课程' : (this.view.authManual ? '完成学校认证' : '登录账号'))
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#222222')
          .layoutWeight(1).textAlign(TextAlign.Center)
        Blank().width(64)
      }.width('100%').height(60).padding({ left: 12, right: 12 })
      Stack({ alignContent: Alignment.Center }) {
        if (this.runtime !== undefined) {
          ForEach([this.view.authViewID], (id: number) => {
            Web({ src: 'about:blank', controller: this.runtime!.authenticator.controller, incognitoMode: true })
              .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
              .width('100%').height('100%').opacity(this.view.authManual && !this.view.authVerifying ? 1 : 0)
              .hitTestBehavior(this.view.authManual && !this.view.authVerifying ? HitTestMode.Default : HitTestMode.None)
              .accessibilityLevel(this.view.authManual && !this.view.authVerifying ? 'auto' : 'no-hide-descendants')
              .onControllerAttached((): void => {
                if (this.runtime?.authenticator.viewID === id) { this.runtime.authenticator.onControllerAttached(); }
              })
              .onPageBegin((event): void => {
                if (this.runtime?.authenticator.viewID === id) { this.runtime.authenticator.onPageBegin(event?.url ?? ''); }
              })
              .onPageEnd((event): void => {
                if (this.runtime?.authenticator.viewID === id) { this.runtime.authenticator.onPageEnd(event?.url ?? ''); }
              })
              .onErrorReceive((event): void => {
                if (this.runtime?.authenticator.viewID === id && event?.request.isMainFrame()) {
                  this.runtime.authenticator.onNavigationError(event.error.getErrorCode());
                }
              })
              .onLoadIntercept((event): boolean => {
                if (this.runtime?.authenticator.viewID !== id) { return true; }
                if (event?.data.isMainFrame() === false) { return false; }
                return this.runtime.authenticator.urlLoadIntercept(event?.data.getRequestUrl() ?? '');
              })
          }, (id: number): string => id.toString())
        }
        if (!this.view.authManual || this.view.authVerifying) {
          Column({ space: 20 }) {
            LoadingProgress().width(42).height(42).color('#777777')
            Text(this.view.authProgress).fontSize(18).fontWeight(FontWeight.Medium).fontColor('#222222').textAlign(TextAlign.Center)
            Text(this.view.authAccount).fontSize(14).fontFamily('monospace').fontColor('#777777')
          }.width('100%').padding(24)
        }
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(Color.White)
  }

  @Builder
  private confirmation() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 16 }) {
        Text('删除这个账号？').fontSize(20).fontWeight(FontWeight.Medium).fontColor('#222222')
        Text('账号和密码将从本机删除，已有签到记录会保留').fontSize(14).fontColor('#777777')
          .textAlign(TextAlign.Center).lineHeight(22)
        Row({ space: 12 }) {
          Button('取消').layoutWeight(1).height(44).fontColor('#333333').backgroundColor('#F0F0F0')
            .onClick((): void => { this.deletingID = ''; })
          Button('删除').layoutWeight(1).height(44).fontColor(Color.White).backgroundColor('#C63737')
            .onClick((): void => {
              const id = this.deletingID;
              this.deletingID = '';
              this.perform(async (): Promise<void> => { await this.model().deleteAccount(id); });
            })
        }.width('100%').margin({ top: 6 })
      }.padding(24).width('84%').constraintSize({ maxWidth: 360 }).borderRadius(24).backgroundColor(Color.White)
    }.width('100%').height('100%').backgroundColor('#55000000')
  }

  @Builder
  private notice() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 18 }) {
        Text('提示').fontSize(20).fontWeight(FontWeight.Medium).fontColor('#222222')
        Text(this.view.notice).fontSize(15).fontColor('#555555').textAlign(TextAlign.Center).lineHeight(24)
        Button('知道了').height(44).width('100%').fontColor(Color.White).backgroundColor('#161616')
          .onClick((): void => this.dismissNotice())
      }.padding(24).width('84%').constraintSize({ maxWidth: 360 }).borderRadius(24).backgroundColor(Color.White)
    }.width('100%').height('100%').backgroundColor('#55000000')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.pageHeader()
        Column() {
          if (this.view.tab === 2) { this.accountsPage() }
          else if (this.view.tab === 1) { this.logsPage() }
          else if (this.view.screen === 'courses') { this.coursesPage() }
          else if (this.view.screen === 'attendance') { this.attendancePage() }
          else if (this.view.screen === 'detail' && this.view.selectedRecord !== undefined) {
            this.attendanceDetail(this.view.selectedRecord as Attendance)
          } else { this.homePage() }
        }.width('100%').layoutWeight(1)
        this.dock()
      }.width('100%').height('100%').backgroundColor(Color.White)
      if (this.editing) { this.editorPage() }
      if (this.selectedLogID.length > 0 && this.log() !== undefined) { this.logDetail(this.log() as AttendanceLog) }
      if (this.view.authActive) { this.authenticationPage() }
      if (this.deletingID.length > 0) { this.confirmation() }
      if (this.view.notice.length > 0) { this.notice() }
    }.width('100%').height('100%').backgroundColor(Color.White)
  }
}
