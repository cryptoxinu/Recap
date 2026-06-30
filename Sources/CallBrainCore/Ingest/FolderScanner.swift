import Foundation

/// Recursively finds importable files under a directory (Phase 7 archive migration). Pure + testable;
/// the app passes the union of readable + transcribable extensions, then enqueues the results into the
/// existing durable import queue.
public enum FolderScanner {
    public static func importableFiles(in folder: URL, recognized: Set<String>, max: Int = 5000) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { continue }
            if recognized.contains(url.pathExtension.lowercased()) {
                out.append(url)
                if out.count >= max { break }
            }
        }
        return out.sorted { $0.path < $1.path }
    }
}
