import Foundation

public struct ChildProcessOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

/// Public, narrow wrapper over the hardened internal subprocess runner used by CLI providers.
/// It preserves pipe draining, timeout, cancellation, PATH repair, and secret-bearing env scrubbing.
public enum ChildProcess {
    public static func run(executable: String,
                           args: [String],
                           cwd: String? = nil,
                           extraEnv: [String: String] = [:],
                           timeout: TimeInterval = 120) async throws -> ChildProcessOutput {
        let out = try await Subprocess.run(executable: executable,
                                           args: args,
                                           cwd: cwd,
                                           extraEnv: extraEnv,
                                           timeout: timeout)
        return ChildProcessOutput(stdout: out.stdout, stderr: out.stderr, exitCode: out.exitCode)
    }
}

