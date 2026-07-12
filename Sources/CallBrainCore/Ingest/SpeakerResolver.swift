import Foundation

/// Turns raw per-utterance speaker labels into clean, readable display names — applied at DISPLAY time so
/// it retroactively fixes an existing library without a re-import (founder: "who is talking is all so bad").
///
/// What it fixes:
/// - Raw diarization labels (`SPEAKER_00`, `Speaker_0`, `spk1`, `S2`) → `Speaker 1 / 2 / 3…` numbered by
///   first appearance (never the ugly raw token).
/// - Empty / `—` / `Unknown` / bare `Speaker` fallbacks (from imports with missing metadata) → the same
///   clean `Speaker N` numbering, so a partially-labelled transcript reads consistently.
/// - Real names (`Alex`, `Sam Lee`) are kept as-is.
public enum SpeakerResolver {
    /// A label carries no real identity — it's a RAW diarization placeholder we should renumber cleanly.
    /// NOTE: an already-clean "Speaker 1" / "Speaker 2" (the word + a SPACE + a number) is NOT generic — it
    /// passes through unchanged, so we never re-number and accidentally SWAP two speakers that happen to
    /// appear out of order (audit MED). Only underscore/no-separator raw tokens + bare/empty fallbacks match.
    static func isGeneric(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty || s == "—" || s == "-" || s == "?" || s == "unknown" || s == "speaker" { return true }
        if s.range(of: #"^speaker[_]?\d+$"#, options: .regularExpression) != nil { return true }  // SPEAKER_00, speaker00
        if s.range(of: #"^(spk|s)[ _]?\d+$"#, options: .regularExpression) != nil { return true }  // spk0, s2
        return false
    }

    /// Map each raw label → a clean display name, stable across the whole transcript. Generic placeholders
    /// are renumbered `Speaker N` in first-appearance order; real names pass through trimmed.
    public static func displayNames(for labelsInOrder: [String]) -> [String: String] {
        var map: [String: String] = [:]
        var genericCount = 0
        for raw in labelsInOrder where map[raw] == nil {
            if isGeneric(raw) {
                genericCount += 1
                map[raw] = "Speaker \(genericCount)"
            } else {
                map[raw] = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return map
    }

    /// Convenience: rewrite an ordered list of raw labels straight to display names.
    public static func resolve(_ labelsInOrder: [String]) -> [String] {
        let map = displayNames(for: labelsInOrder)
        return labelsInOrder.map { map[$0] ?? $0 }
    }
}
