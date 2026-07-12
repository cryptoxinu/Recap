import Foundation

/// The ONE shared stopword set for retrieval (perfection plan Task 1.1). `Store.sanitizeFTS`
/// strips these before OR-joining content tokens into the FTS5 MATCH expression.
///
/// NOTE (deliberate, judge-reviewed): `AskEngine.searchTerms` keeps its own tiny display list
/// (it picks a few *showable* keywords for the "Searching for …" step) and `TaskIntelligence`
/// keeps its dedupe-normalization list. Those serve different purposes — do NOT merge them here
/// blindly, and do NOT fork a fourth list; new retrieval-path callers use this one.
public enum Stopwords {
    public static let fts: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "of", "in", "on", "at",
        "to", "for", "with", "about", "from", "by", "as", "is", "are", "was", "were",
        "be", "been", "being", "do", "does", "did", "have", "has", "had", "will",
        "would", "can", "could", "should", "may", "might",
        "what", "which", "who", "whom", "when", "where", "why", "how",
        "me", "my", "mine", "our", "ours", "your", "yours", "their", "theirs",
        "i", "we", "you", "they", "he", "she", "it", "its", "him", "her", "his",
        "this", "that", "these", "those", "there", "here",
        "say", "said", "says", "tell", "told", "talk", "talked", "get", "got",
        "go", "went", "gone", "up", "out", "so", "just", "like", "any", "some",
    ]
}
