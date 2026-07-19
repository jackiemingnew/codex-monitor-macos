import AppKit
import SwiftUI
import WebKit

private struct RetainedAnalyticsWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct CodexWebAnalyticsBrowserView: View {
    @ObservedObject var viewModel: CodexWebAnalyticsViewModel
    let provider: CodexWebAnalyticsProvider
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Analytics 网页")
                        .font(.system(size: 14, weight: .semibold))
                    Text("登录后若停在主页，请点重新载入；会话由本应用 WebKit 保存")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(viewModel.state.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor)

                Button("重新载入网页") {
                    viewModel.reloadWebPage()
                }

                Button("清除登录") {
                    showsClearConfirmation = true
                }
                .disabled(viewModel.isClearingWebSession)

                Button("读取数据") {
                    viewModel.refresh(force: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !viewModel.isWebSessionReady
                        || viewModel.isRefreshing
                        || viewModel.isClearingWebSession
                )
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            RetainedAnalyticsWebView(webView: provider.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            viewModel.startBrowserSession()
        }
        .alert("清除网页登录数据？", isPresented: $showsClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                viewModel.clearWebSession()
            }
        } message: {
            Text("将删除本应用保存的 ChatGPT 登录会话和网站数据；不会影响 Chrome 或 Safari。")
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .ready:
            .green
        case .partial, .stale:
            .orange
        case .loading:
            .secondary
        case .loginRequired, .unavailable:
            .red
        }
    }
}

@MainActor
final class CodexWebAnalyticsBrowserWindowController: NSObject, NSWindowDelegate {
    private let provider: CodexWebAnalyticsProvider
    private let viewModel: CodexWebAnalyticsViewModel
    private var window: NSWindow?

    init(provider: CodexWebAnalyticsProvider, viewModel: CodexWebAnalyticsViewModel) {
        self.provider = provider
        self.viewModel = viewModel
        super.init()
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        provider.cancelIdleRelease()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let rootView = CodexWebAnalyticsBrowserView(viewModel: viewModel, provider: provider)
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Analytics 网页"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 900, height: 620)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        // Release the hosting hierarchy immediately. The provider keeps the
        // WebsiteDataStore-backed web view only until its idle grace period.
        closingWindow.contentView = nil
        closingWindow.delegate = nil
        window = nil
        provider.scheduleIdleRelease(after: 30 * 60)
    }
}
