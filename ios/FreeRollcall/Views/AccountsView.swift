import SwiftUI

struct AccountsView: View {
    @Bindable var state: AppState
    @State private var deleting: SavedAccount?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.accountText).font(.subheadline.weight(.medium))
                        Text("向左滑动账号可登录、修改、设为默认或删除\n未登录时，使用功能会自动登录默认账号")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 10).listRowSeparator(.hidden)
                }
                if state.store.accounts.isEmpty {
                    ContentUnavailableView("添加你的第一个账号", systemImage: "person.badge.plus",
                        description: Text("账号保存在本机，可随时修改或删除"))
                        .listRowSeparator(.hidden)
                }
                ForEach(state.store.accounts) { account in
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle").font(.system(size: 30)).frame(width: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.label).font(.body.weight(.medium)).lineLimit(2)
                            if !account.note.isEmpty { Text(account.username).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                            HStack(spacing: 8) {
                                if account.isDefault { Text("默认").font(.caption).foregroundStyle(.secondary) }
                                if state.currentAccountID == account.id { Text(state.session == nil ? "待登录" : "使用中").font(.caption.weight(.medium)) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12).contentShape(Rectangle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { Task { do { _ = try await state.login(account.id) } catch { state.report(error) } } }
                            label: { Label("登录", systemImage: "arrow.right.circle") }.tint(.black)
                        Button { state.editor = AccountEditorRoute(accountID: account.id) }
                            label: { Label("修改", systemImage: "pencil") }.tint(.gray)
                        Button { do { try state.store.makeDefault(account) } catch { state.report(error) } }
                            label: { Label("默认", systemImage: "star") }.tint(Color(white: 0.35))
                        Button { deleting = account }
                            label: { Label("删除", systemImage: "trash") }.tint(.red)
                    }
                    .disabled(state.busy)
                    .accessibilityIdentifier("account-\(account.username)")
                }
            }
            .pageList().navigationTitle("账号管理")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.editor = AccountEditorRoute(accountID: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加账号").disabled(state.busy)
                }
                if state.currentAccountID != nil {
                    ToolbarItem(placement: .topBarLeading) { Button("退出登录", action: state.logout).disabled(state.busy) }
                }
            }
            .alert("删除这个账号？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) {
                    if let deleting { do { try state.deleteAccount(deleting) } catch { state.report(error) } }
                    deleting = nil
                }
            } message: { Text("账号和密码将从本机删除，已有签到记录会保留") }
        }
    }
}

struct AccountEditor: View {
    @Bindable var state: AppState
    let accountID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var note = ""
    @State private var visiblePassword = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("登录信息") {
                    TextField("账号", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("username")
                    HStack {
                        Group {
                            if visiblePassword { TextField("密码", text: $password) }
                            else { SecureField("密码", text: $password) }
                        }.textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("password")
                        Button { visiblePassword.toggle() } label: { Image(systemName: visiblePassword ? "eye.slash" : "eye") }
                            .accessibilityLabel(visiblePassword ? "隐藏密码" : "显示密码").buttonStyle(.borderless)
                    }
                    TextField("备注（可选）", text: $note).accessibilityIdentifier("account-note")
                }
                Section {
                    Text("密码保存在此设备的钥匙串中\n第一个账号会自动设为默认账号")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden).background(.white)
            .navigationTitle(accountID == nil ? "添加账号" : "修改账号").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try state.saveAccount(id: accountID, username: username, password: password, note: note); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.fontWeight(.semibold).disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
            }
            .onAppear {
                if let accountID, let account = state.store.account(accountID) {
                    username = account.username; note = account.note
                    do { password = try state.store.password(accountID) } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
