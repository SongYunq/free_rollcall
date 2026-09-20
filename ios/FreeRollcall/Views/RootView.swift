import SwiftUI
import WebKit

struct RootView: View {
    @Bindable var state: AppState
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                SystemTabs(state: state)
            } else {
                legacyTabs
            }
        }
        .sheet(isPresented: $state.showingLogin) {
            if let auth = state.authenticator { AuthenticationView(auth: auth, cancel: state.cancelLogin) }
        }
        .sheet(item: $state.editor) { route in AccountEditor(state: state, accountID: route.accountID) }
        .alert("提示", isPresented: Binding(get: { state.notice != nil }, set: { if !$0 { state.notice = nil } })) {
            Button("知道了", role: .cancel) { state.notice = nil }
        } message: { Text(state.notice?.text ?? "") }
    }

    private var legacyTabs: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            HomeView(state: state).opacity(state.tab == .home ? 1 : 0).allowsHitTesting(state.tab == .home)
                .accessibilityHidden(state.tab != .home)
            LogsView(state: state).opacity(state.tab == .logs ? 1 : 0).allowsHitTesting(state.tab == .logs)
                .accessibilityHidden(state.tab != .logs)
            AccountsView(state: state).opacity(state.tab == .accounts ? 1 : 0).allowsHitTesting(state.tab == .accounts)
                .accessibilityHidden(state.tab != .accounts)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LegacyDock(selection: $state.tab).padding(.horizontal, 40).padding(.top, 8).padding(.bottom, 8)
        }
    }
}

@available(iOS 26.0, *)
private struct SystemTabs: View {
    @Bindable var state: AppState

    var body: some View {
        TabView(selection: $state.tab) {
            Tab(value: AppTab.home) {
                HomeView(state: state)
            } label: {
                Image(systemName: AppTab.home.symbol)
            }
            .accessibilityLabel(AppTab.home.title)

            Tab(value: AppTab.logs) {
                LogsView(state: state)
            } label: {
                Image(systemName: AppTab.logs.symbol)
            }
            .accessibilityLabel(AppTab.logs.title)

            Tab(value: AppTab.accounts) {
                AccountsView(state: state)
            } label: {
                Image(systemName: AppTab.accounts.symbol)
            }
            .accessibilityLabel(AppTab.accounts.title)
        }
        .tabViewStyle(.tabBarOnly)
        .tabBarMinimizeBehavior(.never)
        // Let the system own the glass, selection indicator and scroll-edge treatment.
        // A custom opaque selection capsule or bar background would cover those effects.
    }
}

private struct LegacyDock: View {
    @Binding var selection: AppTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = tab }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 22, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.white : Color.black.opacity(0.55))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background { if selection == tab { Capsule().fill(.black).padding(3) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title).accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }.padding(5)
    }
    var body: some View {
        if reduceTransparency {
            buttons.background(.white, in: Capsule()).overlay(Capsule().stroke(.gray.opacity(0.4), lineWidth: 1))
        } else {
            buttons.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.black.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        }
    }
}

struct PageListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.plain).scrollContentBackground(.hidden).background(.white)
    }
}
extension View { func pageList() -> some View { modifier(PageListStyle()) } }

struct FieldLine: View {
    let title: String
    let value: String
    var body: some View {
        LabeledContent(title) { Text(value).foregroundStyle(.primary).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .font(.subheadline).padding(.vertical, 3)
    }
}
struct MessageRow: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8) }
}
enum DisplayDate {
    static func string(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

private struct SchoolWebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct AuthenticationView: View {
    @Bindable var auth: WebAuthenticator
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            ZStack {
                SchoolWebView(view: auth.webView).opacity(auth.manual ? 1 : 0)
                    .accessibilityHidden(!auth.manual)
                if !auth.manual {
                    VStack(spacing: 20) {
                        ProgressView().controlSize(.large)
                        Text(auth.progress).font(.headline)
                        Text(auth.displayAccount).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
                }
            }
            .navigationTitle(auth.manual ? "网页登录" : "登录账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) } }
        }
        .interactiveDismissDisabled()
    }
}
