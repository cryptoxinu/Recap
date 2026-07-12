import Foundation

/// Pure builders + models for the Google Drive v3 REST API (list / download / export). No I/O — the
/// network calls live in `GoogleDriveClient`. Unit-tested for query/URL correctness.
public enum DriveAPI {
    static let base = "https://www.googleapis.com/drive/v3"
    public static let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let googleDocMime = "application/vnd.google-apps.document"
    static let folderMime = "application/vnd.google-apps.folder"

    public struct DriveFile: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let mimeType: String
        public let modifiedTime: String?
        public init(id: String, name: String, mimeType: String, modifiedTime: String? = nil) {
            self.id = id; self.name = name; self.mimeType = mimeType; self.modifiedTime = modifiedTime
        }
    }
    public struct FileList: Codable, Sendable, Equatable {
        public let files: [DriveFile]
        public let nextPageToken: String?
    }

    /// Drive's `q` is single-quoted; backslash and single-quote are both escape characters, so escape `\`
    /// FIRST, then `'` (SME: a name containing `\` before a quote would otherwise break the literal).
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// List non-trashed children of `folderID` (or all files if nil), newest first, one page.
    public static func listURL(folderID: String?, pageToken: String?) -> URL? {
        var q = "trashed = false"
        if let folderID, !folderID.isEmpty { q = "'\(esc(folderID))' in parents and " + q }
        var c = URLComponents(string: base + "/files")
        var items: [URLQueryItem] = [
            .init(name: "q", value: q),
            .init(name: "fields", value: "nextPageToken, files(id,name,mimeType,modifiedTime)"),
            .init(name: "pageSize", value: "200"),
            .init(name: "orderBy", value: "modifiedTime desc"),
            .init(name: "spaces", value: "drive"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "includeItemsFromAllDrives", value: "true"),
        ]
        if let pageToken, !pageToken.isEmpty { items.append(.init(name: "pageToken", value: pageToken)) }
        c?.queryItems = items
        return c?.url
    }

    /// Files **shared with** the user (Gemini notes / recordings a meeting HOST shared, which never land in
    /// the user's own folders), newest first. The query is narrowed at the API to recordings + docs/text so
    /// the user's whole shared corpus (sheets, slides, PDFs, images, …) is never pulled; `isLikelyMeeting`
    /// + `fetchPlan` narrow it further client-side (SME HIGH — don't import a random shared Google Doc as a
    /// fake "meeting").
    public static func sharedWithMeListURL(pageToken: String?) -> URL? {
        var c = URLComponents(string: base + "/files")
        let kinds = "(mimeType contains 'video/' or mimeType contains 'audio/' "
            + "or mimeType = '\(googleDocMime)' or mimeType = '\(docxMime)' "
            + "or mimeType = 'text/plain' or mimeType = 'text/markdown')"
        var items: [URLQueryItem] = [
            .init(name: "q", value: "sharedWithMe = true and trashed = false and \(kinds)"),
            .init(name: "fields", value: "nextPageToken, files(id,name,mimeType,modifiedTime)"),
            .init(name: "pageSize", value: "200"),
            .init(name: "orderBy", value: "modifiedTime desc"),
            .init(name: "spaces", value: "drive"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "includeItemsFromAllDrives", value: "true"),
        ]
        if let pageToken, !pageToken.isEmpty { items.append(.init(name: "pageToken", value: pageToken)) }
        c?.queryItems = items
        return c?.url
    }

    /// Whether a SHARED file looks like a meeting artifact rather than an arbitrary shared document. Any
    /// recording (video/audio) qualifies; a doc/text only qualifies when its name signals a meeting export
    /// (Gemini notes, transcript, recording). Conservative on purpose — better to miss an oddly-named notes
    /// doc than to import someone's shared budget spreadsheet as a call. (Folder-based sync skips this: the
    /// user explicitly chose that folder.)
    public static func isLikelyMeeting(_ f: DriveFile) -> Bool {
        if f.mimeType.hasPrefix("video/") || f.mimeType.hasPrefix("audio/") { return true }
        let n = f.name.lowercased()
        return ["gemini", "notes by", "transcript", "meeting notes", "recording", "- notes", "(notes)"]
            .contains { n.contains($0) }
    }

    /// Find folders by exact name (to locate e.g. "Meet Recordings").
    public static func folderSearchURL(name: String) -> URL? {
        let q = "mimeType = '\(folderMime)' and name = '\(esc(name))' and trashed = false"
        var c = URLComponents(string: base + "/files")
        c?.queryItems = [
            .init(name: "q", value: q),
            .init(name: "fields", value: "files(id,name,mimeType,modifiedTime)"),
            .init(name: "pageSize", value: "20"),
        ] + Self.allDrivesParams
        return c?.url
    }

    /// Include SHARED drives + shared-with-me, not just the user's My Drive — the founder's Meet
    /// recordings live on shared drives, and folder search/listing omitted these so they never
    /// appeared in the picker (audit D11).
    static let allDrivesParams: [URLQueryItem] = [
        .init(name: "supportsAllDrives", value: "true"),
        .init(name: "includeItemsFromAllDrives", value: "true"),
        .init(name: "corpora", value: "allDrives"),
    ]

    /// All non-trashed folders, name-ordered (for the folder picker).
    public static func foldersListURL() -> URL? {
        var c = URLComponents(string: base + "/files")
        c?.queryItems = [
            .init(name: "q", value: "mimeType = '\(folderMime)' and trashed = false"),
            .init(name: "fields", value: "files(id,name,mimeType,modifiedTime)"),
            .init(name: "pageSize", value: "200"),
            .init(name: "orderBy", value: "name"),
        ] + Self.allDrivesParams
        return c?.url
    }

    public static func downloadURL(fileID: String) -> URL? {
        URL(string: "\(base)/files/\(fileID)?alt=media&supportsAllDrives=true")
    }
    public static func exportURL(fileID: String, mime: String) -> URL? {
        var c = URLComponents(string: "\(base)/files/\(fileID)/export")
        c?.queryItems = [.init(name: "mimeType", value: mime)]
        return c?.url
    }

    /// How to fetch a file's content + the local extension to save it under, so the existing
    /// `IngestEngine`/`ImportCoordinator` can detect + parse it. Returns nil for files we don't import
    /// (e.g. images, folders). Gemini meeting notes are Google Docs → exported to `.docx`.
    public static func fetchPlan(for f: DriveFile, importable: Set<String>) -> (url: URL, ext: String)? {
        switch f.mimeType {
        case googleDocMime:
            return exportURL(fileID: f.id, mime: docxMime).map { ($0, "docx") }
        case docxMime:
            return downloadURL(fileID: f.id).map { ($0, "docx") }
        case "text/plain": return downloadURL(fileID: f.id).map { ($0, "txt") }
        case "text/markdown": return downloadURL(fileID: f.id).map { ($0, "md") }
        case folderMime: return nil
        default:
            // Drive recordings (esp. shared Google Meet videos) frequently have NO extension in their NAME —
            // the type lives only in the mimeType (e.g. "Alex <> Team" / video/mp4). Map video/* + audio/*
            // by mimeType FIRST so a shared recording isn't silently dropped (was the "connected + Up to
            // date but nothing imports" bug). Falls through to the name-extension only for other kinds.
            if let mediaExt = Self.mediaExtension(forMime: f.mimeType) {
                return downloadURL(fileID: f.id).map { ($0, mediaExt) }
            }
            // Fall back to the file-name extension if it's something we import (e.g. .vtt/.srt).
            let ext = (f.name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, importable.contains(ext) else { return nil }
            return downloadURL(fileID: f.id).map { ($0, ext) }
        }
    }

    /// Map an audio/video mimeType → a local extension the media pipeline transcribes (must stay in sync with
    /// ImportCoordinator.mediaExtensions). Unknown video/audio subtypes fall back to a safe container ext.
    static func mediaExtension(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "video/mp4", "video/mpeg", "video/mp4v-es": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "video/webm": return "webm"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac": return "m4a"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-caf": return "caf"
        default:
            if mime.hasPrefix("video/") { return "mp4" }   // unknown video container → default mp4
            if mime.hasPrefix("audio/") { return "m4a" }   // unknown audio → default m4a
            return nil
        }
    }
}
