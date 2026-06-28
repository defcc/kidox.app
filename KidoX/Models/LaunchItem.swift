import Foundation

enum LaunchItemKind: String, Codable, CaseIterable, Identifiable {
    case application
    case folder
    case file
    case url

    var id: String { rawValue }
}

struct LaunchItem: Identifiable, Hashable, Codable {
    let id: UUID
    var kind: LaunchItemKind
    var displayName: String
    var subtitle: String
    var url: URL
    var bundleIdentifier: String?
    var bundleName: String?
    var localizedDisplayNames: [String]?
    var applicationCategory: String?
    var version: String?
    var customDisplayName: String?
    var sourcePath: String
    var isHidden: Bool
    var sortIndex: Int
    var addedAt: Date
    var lastOpenedAt: Date?
    var openCount: Int
    var parentID: UUID?

    init(
        id: UUID = UUID(),
        kind: LaunchItemKind,
        displayName: String,
        subtitle: String,
        url: URL,
        bundleIdentifier: String? = nil,
        bundleName: String? = nil,
        localizedDisplayNames: [String]? = nil,
        applicationCategory: String? = nil,
        version: String? = nil,
        customDisplayName: String? = nil,
        sourcePath: String,
        isHidden: Bool = false,
        sortIndex: Int = 0,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        openCount: Int = 0,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.subtitle = subtitle
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.localizedDisplayNames = localizedDisplayNames
        self.applicationCategory = applicationCategory
        self.version = version
        self.customDisplayName = customDisplayName
        self.sourcePath = sourcePath
        self.isHidden = isHidden
        self.sortIndex = sortIndex
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.openCount = openCount
        self.parentID = parentID
    }

    var effectiveDisplayName: String {
        customDisplayName ?? displayName
    }

}

struct LaunchItemSearchMatch: Comparable, Hashable {
    let score: Int

    static func < (lhs: LaunchItemSearchMatch, rhs: LaunchItemSearchMatch) -> Bool {
        lhs.score < rhs.score
    }
}

struct LaunchItemSearchQuery: Hashable {
    let normalized: String
    let tokens: [String]

    init?(_ value: String) {
        let normalized = value.kidoXSearchNormalized
        let tokens = normalized.kidoXSearchTokens
        guard !tokens.isEmpty else { return nil }

        self.normalized = normalized
        self.tokens = tokens
    }
}

extension LaunchItem {
    func searchMatch(for query: LaunchItemSearchQuery) -> LaunchItemSearchMatch? {
        if let nameMatch = match(
            query: query,
            in: primaryNameSearchTerms,
            scoreOffset: 0,
            allowsFuzzy: true,
            allowsSubstring: true
        ) {
            return nameMatch
        }

        if let localizedNameMatch = match(
            query: query,
            in: localizedNameSearchTerms,
            scoreOffset: 32,
            allowsFuzzy: false,
            allowsSubstring: false
        ) {
            return localizedNameMatch
        }

        guard query.normalized.count >= 3 else { return nil }
        return match(
            query: query,
            in: metadataSearchTerms,
            scoreOffset: 120,
            allowsFuzzy: false,
            allowsSubstring: false
        )
    }

    private func match(
        query: LaunchItemSearchQuery,
        in rawTerms: [String],
        scoreOffset: Int,
        allowsFuzzy: Bool,
        allowsSubstring: Bool
    ) -> LaunchItemSearchMatch? {
        let terms = rawTerms
            .map(\.kidoXSearchNormalized)
            .filter { !$0.isEmpty }
            .uniquedPreservingOrder()
        guard !terms.isEmpty else { return nil }

        var totalScore = 0
        for token in query.tokens {
            guard let bestTokenScore = terms.compactMap({
                $0.kidoXSearchScore(
                    for: token,
                    allowsFuzzy: allowsFuzzy,
                    allowsSubstring: allowsSubstring
                )
            }).min() else {
                return nil
            }
            totalScore += bestTokenScore
        }

        return LaunchItemSearchMatch(score: scoreOffset + totalScore)
    }

    private var primaryNameSearchTerms: [String] {
        [
            customDisplayName,
            displayName,
            bundleName
        ]
        .compactMap { $0 }
        .flatMap { term -> [String] in
            [term] + term.kidoXSearchTokens
        }
    }

    private var localizedNameSearchTerms: [String] {
        (localizedDisplayNames ?? [])
        .flatMap { term -> [String] in
            [term] + term.kidoXSearchTokens
        }
    }

    private var metadataSearchTerms: [String] {
        [
            bundleIdentifier
        ]
        .compactMap { $0 }
        .flatMap { term -> [String] in
            [term] + term.kidoXSearchTokens
        }
    }
}

private extension String {
    var kidoXSearchNormalized: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .localizedLowercase
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var kidoXSearchTokens: [String] {
        split { character in
            character.isWhitespace || character.isPunctuation || character.isSymbol
        }
        .map(String.init)
        .filter { !$0.isEmpty }
    }

    func kidoXSearchScore(for query: String, allowsFuzzy: Bool, allowsSubstring: Bool) -> Int? {
        guard !query.isEmpty else { return 0 }

        if self == query {
            return 0
        }
        if hasPrefix(query) {
            return 4 + min(count - query.count, 12)
        }

        let initials = kidoXSearchInitials
        if !initials.isEmpty, initials.hasPrefix(query) {
            let exactInitialsBonus = initials == query ? 0 : 4
            return 10 + exactInitialsBonus + min(initials.count - query.count, 8)
        }

        if allowsFuzzy {
            if query.count >= 2,
               first == query.first,
               let subsequenceScore = kidoXSubsequenceScore(for: query) {
                return 28 + subsequenceScore
            }
        }

        if allowsSubstring, let range = range(of: query) {
            let leadingDistance = distance(from: startIndex, to: range.lowerBound)
            return 56 + min(leadingDistance, 16) + min(count - query.count, 12)
        }

        if allowsFuzzy, query.count >= 3, count <= 40 {
            let distanceLimit = query.count >= 6 ? 2 : 1
            if let distance = kidoXEditDistance(to: query, limit: distanceLimit) {
                return 72 + distance * 8 + abs(count - query.count)
            }
        }

        return nil
    }

    var kidoXSearchInitials: String {
        kidoXSearchTokens.compactMap(\.first).map(String.init).joined()
    }

    func kidoXSubsequenceScore(for query: String) -> Int? {
        var haystackIndex = startIndex
        var previousMatch: String.Index?
        var gapPenalty = 0

        for needle in query {
            guard let matchIndex = self[haystackIndex...].firstIndex(of: needle) else {
                return nil
            }
            if let previousMatch {
                gapPenalty += distance(from: index(after: previousMatch), to: matchIndex)
            } else {
                gapPenalty += distance(from: startIndex, to: matchIndex)
            }
            haystackIndex = index(after: matchIndex)
            previousMatch = matchIndex
        }

        return min(gapPenalty, 24) + min(count - query.count, 12)
    }

    func kidoXEditDistance(to other: String, limit: Int) -> Int? {
        let source = Array(self)
        let target = Array(other)
        guard abs(source.count - target.count) <= limit else { return nil }
        if source.isEmpty { return target.count <= limit ? target.count : nil }
        if target.isEmpty { return source.count <= limit ? source.count : nil }

        var previous = Array(0...target.count)
        var current = Array(repeating: 0, count: target.count + 1)

        for sourceIndex in 1...source.count {
            current[0] = sourceIndex
            var rowMinimum = current[0]

            for targetIndex in 1...target.count {
                let substitutionCost = source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1
                current[targetIndex] = Swift.min(
                    previous[targetIndex] + 1,
                    current[targetIndex - 1] + 1,
                    previous[targetIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[targetIndex])
            }

            guard rowMinimum <= limit else { return nil }
            swap(&previous, &current)
        }

        let distance = previous[target.count]
        return distance <= limit ? distance : nil
    }
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
