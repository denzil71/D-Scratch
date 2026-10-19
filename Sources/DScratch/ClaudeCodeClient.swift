import Foundation

/// Asks Claude through the locally installed Claude Code CLI (`claude -p`), which uses the
/// Claude account the user logged in with there (e.g. a Pro plan) instead of an API key.
/// Runs with no tools, no user/project settings, no MCP servers and no saved session,
/// from an empty working directory, so it only answers the question.
enum ClaudeCodeClient {
    static let models = [
        ClaudeModel(id: "default", name: "Default for your plan"),
        ClaudeModel(id: "opus", name: "Opus"),
        ClaudeModel(id: "sonnet", name: "Sonnet"),
        ClaudeModel(id: "haiku", name: "Haiku"),
    ]

    struct Status {
        let loggedIn: Bool
        let email: String?
        let plan: String?
    }

    enum Failure: LocalizedError {
        case notInstalled
        case notLoggedIn
        case cavemanMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Claude Code isn't installed. Install it from claude.com/claude-code, or use an API key in Settings."
            case .cavemanMissing:
                return "The caveman plugin isn't installed in Claude Code. Install it, or turn off \"Use caveman\" in Settings."
            case .notLoggedIn:
                return "Claude Code isn't logged in. Run `claude` in Terminal and log in with your Claude account."
            case .failed(let message):
                return message
            }
        }
    }

    /// GUI apps get a minimal PATH, so look in the usual install locations.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// The caveman plugin, if installed in Claude Code (looked up in its installed_plugins.json so
    /// plugin updates are followed). Returns its install folder and version.
    static var cavemanPlugin: (path: String, version: String?)? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let plugins = json["plugins"] as? [String: Any] ?? json
        for (name, value) in plugins where name.hasPrefix("caveman@") {
            let installs = value as? [[String: Any]] ?? []
            for install in installs {
                if let path = install["installPath"] as? String,
                   FileManager.default.fileExists(atPath: "\(path)/.claude-plugin/plugin.json") {
                    return (path, install["version"] as? String)
                }
            }
        }
        return nil
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        // Never let a stray key in the environment override the account login.
        env["ANTHROPIC_API_KEY"] = nil
        return env
    }

    private static let workingDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("D-Scratch-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `claude auth status`, for Settings.
    static func status() async -> Status? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = (try? await output.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }) ?? Data()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Status(loggedIn: false, email: nil, plan: nil)
        }
        return Status(
            loggedIn: json["loggedIn"] as? Bool ?? false,
            email: json["email"] as? String,
            plan: json["subscriptionType"] as? String)
    }

    /// Yields answer text as it streams in.
    /// `caveman` loads the locally installed caveman plugin for this one run and switches it on,
    /// so answers come back in its compressed style.
    static func stream(
        model: String, question: String, pageText: String?, caveman: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let executable else {
                continuation.finish(throwing: Failure.notInstalled)
                return
            }
            var plugin: String?
            if caveman {
                guard let found = cavemanPlugin else {
                    continuation.finish(throwing: Failure.cavemanMissing)
                    return
                }
                plugin = found.path
            }
            let process = Process()
            process.executableURL = executable
            var arguments = [
                "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
                "--system-prompt", ClaudeClient.systemPrompt,
            ]
            if model != "default" { arguments += ["--model", model] }
            var env = environment
            if let plugin {
                arguments += ["--plugin-dir", plugin]
                // The plugin's hook stays off in non-interactive runs unless a default mode is given.
                env["CAVEMAN_DEFAULT_MODE"] = "caveman"
            }
            process.arguments = arguments
            process.environment = env
            process.currentDirectoryURL = workingDirectory
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            let task = Task {
                do {
                    try process.run()
                    // The question goes in on stdin, so long pages don't hit argument limits.
                    input.fileHandleForWriting.write(Data(ClaudeClient.userContent(question: question, pageText: pageText).utf8))
                    try input.fileHandleForWriting.close()

                    var finished = false
                    for try await line in output.fileHandleForReading.bytes.lines {
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              let type = event["type"] as? String else { continue }
                        if type == "stream_event", let inner = event["event"] as? [String: Any] {
                            let delta = inner["delta"] as? [String: Any]
                            if inner["type"] as? String == "content_block_delta", delta?["type"] as? String == "text_delta",
                               let text = delta?["text"] as? String {
                                continuation.yield(text)
                            }
                            if inner["type"] as? String == "message_delta", delta?["stop_reason"] as? String == "refusal" {
                                throw ClaudeError.refusal
                            }
                        } else if type == "result" {
                            finished = true
                            if event["is_error"] as? Bool == true {
                                throw failure(from: event["result"] as? String ?? "Claude Code reported an error.")
                            }
                        }
                    }
                    process.waitUntilExit()
                    if !finished {
                        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        throw failure(from: stderr.isEmpty ? "Claude Code exited without an answer." : stderr)
                    }
                    continuation.finish()
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    private static func failure(from message: String) -> Error {
        let lower = message.lowercased()
        if lower.contains("login") || lower.contains("log in") || lower.contains("not logged in")
            || lower.contains("invalid api key") {
            return Failure.notLoggedIn
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return Failure.failed(String(trimmed.suffix(300)))
    }
}
