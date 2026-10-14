import SwiftUI

/// Techninis žurnalas. Jei kas nors neveikia – spausk „Dalintis“ ir atsiųsk tekstą.
struct LogView: View {
    @EnvironmentObject private var appLog: AppLog

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(appLog.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .background(Theme.background)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: appLog.lines.count) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            .navigationTitle("Žurnalas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Išvalyti") {
                        appLog.clear()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: appLog.fullText) {
                        Label("Dalintis", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !appLog.lines.isEmpty else { return }
        proxy.scrollTo(appLog.lines.count - 1, anchor: .bottom)
    }
}
