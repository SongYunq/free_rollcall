import SwiftUI
import RollcallCore

struct HomeView: View {
    @Bindable var state: AppState
    var body: some View {
        NavigationStack(path: $state.homePath) {
            List {
                VStack(alignment: .leading, spacing: 8) {
                    Text("free_rollcall").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(state.accountText).font(.subheadline)
                }.padding(.vertical, 12).listRowSeparator(.hidden)
                Button { Task { await state.enterCourses() } } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "books.vertical").font(.title2).frame(width: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("进入课程").font(.headline)
                            Text("查看本学期课程与签到记录").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state.enteringCourses { ProgressView() }
                        else { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                    }.padding(.vertical, 18).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(state.busy || state.enteringCourses).accessibilityIdentifier("enter-courses")
            }
            .pageList().navigationTitle("功能")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .courses: CoursesView(state: state)
                case .history(let course): HistoryView(state: state, course: course)
                }
            }
        }
    }
}

struct CoursesView: View {
    @Bindable var state: AppState
    var body: some View {
        List {
            MessageRow(text: state.accountText).listRowSeparator(.hidden)
            if let error = state.coursesError { MessageRow(text: error) }
            ForEach(state.courses) { course in
                NavigationLink(value: HomeRoute.history(course)) {
                    HStack(spacing: 14) {
                        Image(systemName: "book.closed").frame(width: 28).foregroundStyle(.secondary)
                        Text(course.name).font(.body).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 16)
                }.disabled(state.isSubmitting)
            }
            if state.loadingCourses { ProgressView("正在加载课程").frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            else if state.courses.isEmpty && state.coursesError == nil {
                ContentUnavailableView("本学期暂无课程", systemImage: "books.vertical").listRowSeparator(.hidden)
            }
        }
        .pageList().navigationTitle("本学期课程").navigationBarTitleDisplayMode(.inline)
        .refreshable { await state.loadCourses() }
    }
}

struct HistoryView: View {
    @Bindable var state: AppState
    let course: Course
    @State private var selected: Attendance?
    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                Text(course.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(state.accountText).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 12).listRowSeparator(.hidden)
            if let error = state.historyError { MessageRow(text: error) }
            if let message = state.operationMessage { MessageRow(text: message) }
            ForEach(state.records) { record in
                Button {
                    if record.canSubmit { Task { await state.submit(record, course: course) } }
                    else { state.operationMessage = nil; selected = record }
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: record.kind == .radar ? "dot.radiowaves.left.and.right" : "number.square")
                            .font(.title3).frame(width: 28, height: 24)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(record.kind.title).fontWeight(.medium)
                                Spacer(minLength: 8)
                                Text(record.stateText).font(.caption)
                                    .foregroundStyle(record.isAbsent ? Color.red : Color.secondary)
                            }
                            Text(record.date.map(DisplayDate.string) ?? record.rawDate ?? "时间未提供")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if record.kind == .number {
                                let code = record.numberCode.flatMap { $0.isEmpty ? nil : $0 }
                                Text("签到码  \(code ?? (state.loadingHistory ? "正在获取…" : "未获取"))")
                                    .font(.body.monospacedDigit().weight(.semibold)).textSelection(.enabled)
                            }
                            if record.canSubmit {
                                Text(state.operationRecordID == record.id ? "正在签到…" : "点击此条目签到")
                                    .font(.caption.weight(.medium))
                            }
                        }
                        if state.operationRecordID == record.id { ProgressView() }
                    }.padding(.vertical, 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(state.busy)
                .accessibilityIdentifier("attendance-\(record.id)")
            }
            if state.loadingHistory { ProgressView("正在加载签到记录").frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            else if state.records.isEmpty && state.historyError == nil {
                ContentUnavailableView("暂无签到记录", systemImage: "list.bullet.rectangle").listRowSeparator(.hidden)
            }
            if state.historyPage.hasMore && !state.loadingHistory {
                Button("加载更多记录") { Task { await state.loadHistory(course: course, reset: false) } }
                    .frame(maxWidth: .infinity).disabled(state.busy)
            } else if !state.historyPage.note.isEmpty { MessageRow(text: state.historyPage.note) }
        }
        .pageList().navigationTitle("课程签到").navigationBarTitleDisplayMode(.inline)
        .task(id: course.id) { await state.loadHistory(course: course, reset: true) }
        .refreshable { await state.loadHistory(course: course, reset: true) }
        .sheet(item: $selected) { record in AttendanceDetail(state: state, course: course, initial: record) }
    }
}

private struct AttendanceDetail: View {
    @Bindable var state: AppState
    let course: Course
    let initial: Attendance
    @State private var fetched: Attendance?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var record: Attendance { state.records.first(where: { $0.id == initial.id }) ?? fetched ?? initial }
    var body: some View {
        NavigationStack {
            List {
                FieldLine(title: "课程", value: course.name)
                FieldLine(title: "时间", value: record.date.map(DisplayDate.string) ?? record.rawDate ?? "未提供")
                FieldLine(title: "形式", value: record.kind.title)
                FieldLine(title: "状态", value: record.stateText)
                if record.kind == .number { FieldLine(title: "签到码", value: record.numberCode ?? "未获取") }
                if record.kind == .radar { FieldLine(title: "签到码", value: "雷达签到") }
                if let error { MessageRow(text: error) }
                if record.canSubmit {
                    Button("立即签到") { Task { await state.submit(record, course: course) } }.disabled(state.busy || state.session == nil)
                }
                if let message = state.operationMessage { MessageRow(text: message) }
            }
            .pageList().navigationTitle("签到详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }
    private func refresh() async {
        error = nil
        do { fetched = try await state.detail(initial, allowAuthentication: false) }
        catch { if error as? RollcallError != .cancelled { self.error = error.localizedDescription } }
    }
}
