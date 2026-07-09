import Foundation

enum CommandRunner {
    /// Full PATH sourced from the user's login shell once at startup.
    /// This ensures tools installed via npm global, Homebrew, nvm, etc. are found
    /// even though menu bar apps inherit a minimal macOS session PATH.
    static let enrichedEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginShellPath()
        return env
    }()

    private static func loginShellPath() -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "echo $PATH"]
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else {
            return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" : path
    }

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
