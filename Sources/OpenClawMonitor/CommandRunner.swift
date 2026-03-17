import Foundation

enum CommandRunner {
    /// PATH prepended to every subprocess environment so that tools installed
    /// via Homebrew or /usr/local are found even when launched from a menu bar app.
    static let enrichedEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        return env
    }()

    /// Runs *command* in `/bin/sh -c` on a background thread.
    /// stdout and stderr are merged into a single string.
    /// Returns on the caller's actor after the process exits or times out.
    static func run(_ command: String, timeout: TimeInterval = 60) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.environment = enrichedEnvironment
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "Failed to launch: \(error.localizedDescription)"))
                    return
                }

                // Kill the process if it exceeds the timeout
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                process.waitUntilExit()
                killer.cancel()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                continuation.resume(returning: (process.terminationStatus, output))
            }
        }
    }
}
