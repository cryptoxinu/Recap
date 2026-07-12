import Foundation

/// Resolves the bundled `cbtranscribe` helper at runtime (the crash-isolated transcription boundary
/// for both the post-call pass and the live serve child). The candidate ORDER is a pure, injectable
/// function so it can be unit-tested without a real app bundle.
public enum TranscriptionHelperLocator {
    public static let executableName = "cbtranscribe"

    public static func helperURL() -> URL? {
        firstExecutable(in: candidateURLs())
    }

    /// The ordered candidate paths for the given environment inputs (pure — testable). The bundled
    /// binary sits next to the app's main executable (Contents/MacOS); dev falls back to `.build`.
    public static func candidates(executableDir: URL?, resourceDir: URL?,
                                  cwd: URL, launchDir: URL?) -> [URL] {
        var urls: [URL] = []
        if let executableDir { urls.append(executableDir.appendingPathComponent(executableName)) }
        if let resourceDir { urls.append(resourceDir.appendingPathComponent(executableName)) }
        urls.append(cwd.appendingPathComponent(".build/debug/\(executableName)"))
        urls.append(cwd.appendingPathComponent(".build/release/\(executableName)"))
        if let launchDir { urls.append(launchDir.appendingPathComponent(executableName)) }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The first candidate that exists AND is executable.
    public static func firstExecutable(in candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func candidateURLs() -> [URL] {
        candidates(
            executableDir: Bundle.main.executableURL?.deletingLastPathComponent(),
            resourceDir: Bundle.main.resourceURL,
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            launchDir: CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
    }
}
