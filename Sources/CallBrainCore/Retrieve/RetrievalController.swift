import Foundation

public struct RetrievalController: Sendable {
    public let search: SearchEngine

    public init(search: SearchEngine) {
        self.search = search
    }

    public enum Breadth: String, Sendable, Equatable {
        case focused
        case broad
        case exhaustive
    }

    public struct Outcome: Sendable, Equatable {
        public let hits: [SearchEngine.Result]
        public let semanticDegraded: Bool
        public let breadth: Breadth
        public let searchedQueries: [String]
        public var expanded: Bool { searchedQueries.count > 1 }
    }

    public func retrieve(query: String,
                         plan: QueryPlan,
                         candidateChunkIDs: [String]?,
                         speakerBoost: String?,
                         topK: Int) async throws -> Outcome {
        let breadth = Self.breadth(for: query, plan: plan)
        let laneLimit = Self.laneLimit(for: breadth, topK: topK)
        let first = try await search.retrieve(query,
                                              candidateChunkIDs: candidateChunkIDs,
                                              ftsLimit: laneLimit,
                                              vecLimit: laneLimit,
                                              finalLimit: topK,
                                              speakerBoost: speakerBoost)
        var best = first
        var searched = [query]
        var semanticDegraded = first.semanticDegraded

        if Self.shouldExpand(first.hits, breadth: breadth, topK: topK) {
            for expanded in Self.expandedQueries(for: query, plan: plan) where !searched.contains(expanded) {
                let retry = try await search.retrieve(expanded,
                                                      candidateChunkIDs: candidateChunkIDs,
                                                      ftsLimit: laneLimit * 2,
                                                      vecLimit: laneLimit * 2,
                                                      finalLimit: topK,
                                                      speakerBoost: speakerBoost)
                searched.append(expanded)
                semanticDegraded = semanticDegraded || retry.semanticDegraded
                best = Self.better(best, retry, breadth: breadth)
                if !Self.shouldExpand(best.hits, breadth: breadth, topK: topK) { break }
            }
        }

        return Outcome(hits: best.hits,
                       semanticDegraded: semanticDegraded,
                       breadth: breadth,
                       searchedQueries: searched)
    }

    public static func breadth(for query: String, plan: QueryPlan) -> Breadth {
        if plan.exhaustive { return .exhaustive }
        switch plan.mode {
        case .person, .sourceFind:
            return .focused
        case .actionItems:
            return plan.speaker == nil ? .broad : .focused
        case .general, .technical, .timeScoped:
            return ambiguous(query) ? .broad : .focused
        }
    }

    public static func expandedQueries(for query: String, plan: QueryPlan) -> [String] {
        var additions: [String] = []
        let lower = query.lowercased()

        // Generic spelling/hyphenation normalizations only — no corpus-specific proper nouns.
        let phraseAliases: [(String, String)] = [
            ("to do", "todo"),
            ("follow up", "follow-up"),
        ]
        for (phrase, alias) in phraseAliases where lower.contains(phrase) {
            additions.append(alias)
        }
        if let speaker = plan.speaker, !speaker.isEmpty {
            additions.append(AskEngine.speakerAliasTerms(speaker))
        }
        switch plan.mode {
        case .actionItems:
            additions.append("asked me told me follow up follow-up action item owner deadline track keep track")
        case .sourceFind:
            additions.append("exact moment quote source where said asked mentioned")
        case .technical:
            additions.append("explain mechanism tradeoff constraint detail definition")
        case .general, .person, .timeScoped:
            additions.append("decided decision agreed mentioned discussed follow-up next steps")
        }

        let expanded = (query + " " + additions.joined(separator: " "))
            .split { $0.isWhitespace }
            .reduce(into: (seen: Set<String>(), tokens: [String]())) { partial, token in
                let key = token.lowercased()
                if partial.seen.insert(key).inserted { partial.tokens.append(String(token)) }
            }
            .tokens
            .joined(separator: " ")

        return expanded == query ? [] : [expanded]
    }

    private static func ambiguous(_ query: String) -> Bool {
        let lower = query.lowercased()
        if ["thing", "stuff", "anything", "everything", "all", "overall", "recap"]
            .contains(where: lower.contains) { return true }
        return false
    }

    private static func shouldExpand(_ hits: [SearchEngine.Result], breadth: Breadth, topK: Int) -> Bool {
        if hits.isEmpty { return true }
        switch breadth {
        case .focused:
            return false
        case .broad:
            let meetings = Set(hits.map(\.meetingID)).count
            return hits.count < min(8, max(1, topK / 2)) || meetings < 2
        case .exhaustive:
            return hits.count < min(topK, 24)
        }
    }

    private static func better(_ lhs: SearchEngine.Retrieval,
                               _ rhs: SearchEngine.Retrieval,
                               breadth: Breadth) -> SearchEngine.Retrieval {
        if lhs.hits.isEmpty { return rhs }
        if rhs.hits.isEmpty { return lhs }
        let leftMeetings = Set(lhs.hits.map(\.meetingID)).count
        let rightMeetings = Set(rhs.hits.map(\.meetingID)).count
        if breadth != .focused, rightMeetings != leftMeetings {
            return rightMeetings > leftMeetings ? rhs : lhs
        }
        return rhs.hits.count > lhs.hits.count ? rhs : lhs
    }

    private static func laneLimit(for breadth: Breadth, topK: Int) -> Int {
        switch breadth {
        case .focused:
            return max(50, topK * 2)
        case .broad:
            return max(90, topK * 3)
        case .exhaustive:
            return max(160, topK * 2)
        }
    }
}
