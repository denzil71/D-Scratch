import SwiftUI

/// Question field at the top of a page. Streams Claude's answer into a preview, then appends it to the page.
struct AskClaudeBar: View {
    @EnvironmentObject var store: Store
    let pageID: UUID

    @AppStorage(Prefs.claudeModel) private var model = Prefs.defaultModel
    @AppStorage(Prefs.claudeBackend) private var backend = "claudeCode"
    @AppStorage(Prefs.claudeCodeModel) private var claudeCodeModel = "default"
    @AppStorage(Prefs.claudeUseCaveman) private var useCaveman = false
    @AppStorage(Prefs.claudeIncludePage) private var includePage = true
    @State private var question = ""
    @State private var asked = ""
    @State private var answer = ""
    @State private var phase = Phase.idle
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable {
        case idle, waiting, streaming
        case failed(String)
    }

    private var isRunning: Bool { phase == .waiting || phase == .streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField("Ask Claude…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                    .disabled(isRunning)
                Toggle("Use page", isOn: $includePage)
                    .toggleStyle(.checkbox)
                    .help("Send this page's text to Claude as context")
                if isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: stop)
                } else {
                    Button("Ask", action: ask)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            switch phase {
            case .waiting:
                Text("Claude is thinking…").font(.callout).foregroundStyle(.secondary)
            case .streaming:
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(answer)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxHeight: 160)
                    .onChange(of: answer) { _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onDisappear { task?.cancel() }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isRunning else { return }
        let pageText = includePage
            ? store.activeTextView?.string.replacingOccurrences(of: "\u{FFFC}", with: "")
            : nil
        let stream: AsyncThrowingStream<String, Error>
        if backend == "api" {
            guard let apiKey = Keychain.get(Keychain.apiKeyAccount), !apiKey.isEmpty else {
                phase = .failed("Add your Claude API key in Settings (⌘,), or switch to your Claude account there.")
                return
            }
            stream = ClaudeClient.stream(apiKey: apiKey, model: model, question: q, pageText: pageText)
        } else {
            stream = ClaudeCodeClient.stream(
                model: claudeCodeModel, question: q, pageText: pageText, caveman: useCaveman)
        }
        asked = q
        answer = ""
        phase = .waiting
        task = Task {
            do {
                for try await chunk in stream {
                    answer += chunk
                    phase = .streaming
                    store.noteActivity()
                }
                finish()
            } catch {
                if Task.isCancelled {
                    phase = .idle
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        answer = ""
        phase = .idle
    }

    private func finish() {
        guard let textView = store.activeTextView, textView.pageID == pageID else {
            phase = .failed("The page closed before Claude's answer could be added.")
            return
        }
        textView.appendClaudeAnswer(question: asked, answer: answer)
        question = ""
        answer = ""
        phase = .idle
    }
}
