import Foundation

/// Whether text is being embedded as a stored document or a search query. nomic-embed-text uses
/// distinct task prefixes; the SAME model must embed both sides (docs/ARCHITECTURE.md §0 D7).
public enum EmbedKind: Sendable { case document, query }

public protocol Embedder: Sendable {
    var modelID: String { get }
    var dim: Int { get }
    func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]]
}

public enum EmbedError: Error, Sendable, Equatable {
    case http(Int)
    case decode(String)
    case empty
    case dimMismatch(expected: Int, got: Int)
}

/// Local embeddings via the Ollama HTTP API (no API key, no egress). Default model nomic-embed-text
/// (768-dim, 8192-ctx). In-process CoreML/ANE (`swift-embeddings`) is the always-warm V1 target; this
/// Ollama path is the zero-setup fallback and what the live test exercises.
public struct OllamaEmbedder: Embedder {
    public let modelID: String
    public let dim: Int
    public let baseURL: URL

    public init(modelID: String = "nomic-embed-text", dim: Int = 768,
                baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.modelID = modelID; self.dim = dim; self.baseURL = baseURL
    }

    public func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let prefix = kind == .document ? "search_document: " : "search_query: "
        let input = texts.map { prefix + $0 }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID, "input": input])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw EmbedError.decode("no HTTP response") }
        guard http.statusCode == 200 else { throw EmbedError.http(http.statusCode) }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arrs = obj["embeddings"] as? [[Any]] else {
            throw EmbedError.decode("missing embeddings[] in Ollama response")
        }
        let vectors = arrs.map { row in row.compactMap { ($0 as? NSNumber)?.floatValue } }
        if let first = vectors.first, first.count != dim {
            throw EmbedError.dimMismatch(expected: dim, got: first.count)
        }
        return vectors
    }
}
