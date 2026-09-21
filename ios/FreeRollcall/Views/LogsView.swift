import SwiftUI

struct LogsView: View {
    @Bindable var state: AppState
    @State private var selected: AttendanceLog?
    var body: some View {
        NavigationStack {
            List {
                if state.store.logs.isEmpty {
                    ContentUnavailableView("还没有签到记录", systemImage: "clock.arrow.circlepath",
                        description: Text("签到操作的结果会保存在本机，离线也能查看"))
                        .listRowSeparator(.hidden)
                }
                ForEach(state.store.logs) { log in
                    Button { selected = log } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                Text(log.courseName).font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                                Label(log.result.title, systemImage: log.result.symbol).labelStyle(.titleAndIcon).font(.caption).fixedSize()
                            }
                            Text(DisplayDate.string(log.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            HStack(alignment: .top) {
                                Text(log.kind.title)
                                Spacer(minLength: 12)
                                Text(log.codeText).monospacedDigit().multilineTextAlignment(.trailing)
                            }.font(.subheadline)
                            Text(log.accountNote.isEmpty ? log.username : "\(log.accountNote) · \(log.username)")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .pageList().navigationTitle("本地日志")
            .sheet(item: $selected) { log in LogDetail(state: state, log: log) }
        }
    }
}

private struct LogDetail: View {
    @Bindable var state: AppState
    let log: AttendanceLog
    @State private var checking = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                FieldLine(title: "时间", value: DisplayDate.string(log.createdAt))
                FieldLine(title: "课程", value: log.courseName)
                FieldLine(title: "签到形式", value: log.kind.title)
                FieldLine(title: "结果", value: log.result.title)
                FieldLine(title: "账号", value: log.username)
                if !log.accountNote.isEmpty { FieldLine(title: "备注", value: log.accountNote) }
                FieldLine(title: "签到码", value: log.codeText)
                MessageRow(text: log.message)
                if let error { MessageRow(text: error) }
                if log.result == .uncertain {
                    Button {
                        checking = true
                        error = nil
                        Task {
                            do { try await state.reconcile(log) } catch { self.error = error.localizedDescription }
                            checking = false
                        }
                    } label: {
                        HStack { Text("核对学校端结果"); Spacer(); if checking { ProgressView() } }
                    }.disabled(checking || state.busy)
                    MessageRow(text: "使用本条记录对应的账号查询，不会再次提交签到")
                }
            }
            .pageList().navigationTitle("签到记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
