import Foundation

/// The A–Z jump of a title-sorted library grid, built from Plex's
/// `firstCharacter` counts: where in the sorted list each letter starts.
struct LibraryLetterIndex: Equatable, Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let label: String
        /// Offset of the letter's first title in the grid's sort order; nil
        /// when no title starts with it (the letter is shown dimmed).
        let offset: Int?

        var id: String { label }
        var isAvailable: Bool { offset != nil }
    }

    /// In the grid's order, top to bottom.
    let entries: [Entry]
    let totalCount: Int

    private static let letters = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
        .compactMap { UnicodeScalar($0).map { String(Character($0)) } }

    /// - Parameter characters: Plex's rows, in ascending title-sort order.
    init(characters: [PlexFirstCharacter], descending: Bool) {
        let rows = characters.filter { $0.size > 0 }
        totalCount = rows.reduce(0) { $0 + $1.size }

        var ascendingOffsets: [String: Int] = [:]
        var running = 0
        for row in rows {
            ascendingOffsets[row.key] = running
            running += row.size
        }
        let sizes = Dictionary(rows.map { ($0.key, $0.size) }, uniquingKeysWith: +)

        // Plain Latin libraries get the full alphabet, absent letters dimmed,
        // with "#" wherever Plex sorts it; anything else lists Plex's own keys.
        let keys = rows.map(\.key)
        let ascendingLabels: [String]
        if keys.allSatisfy({ $0 == "#" || Self.letters.contains($0) }) {
            let numbersLast = keys.last == "#" && keys.count > 1
            ascendingLabels = numbersLast ? Self.letters + ["#"] : ["#"] + Self.letters
        } else {
            ascendingLabels = keys
        }

        let total = totalCount
        let ascending = ascendingLabels.map { label in
            Entry(label: label, offset: ascendingOffsets[label].map { offset in
                descending ? total - offset - (sizes[label] ?? 0) : offset
            })
        }
        entries = descending ? ascending.reversed() : ascending
    }

    /// Worth showing: more than one letter to jump between.
    var isUseful: Bool {
        entries.filter(\.isAvailable).count > 1
    }

    /// Where selecting `entry` lands: its own first title, or for a dimmed
    /// letter the next letter down that has titles (else the last one up).
    func targetOffset(for entry: Entry) -> Int? {
        if let offset = entry.offset { return offset }
        guard let index = entries.firstIndex(of: entry) else { return nil }
        return entries[index...].lazy.compactMap(\.offset).first
            ?? entries[..<index].reversed().lazy.compactMap(\.offset).first
    }

    /// The letter the title at `offset` belongs to.
    func entry(containing offset: Int) -> Entry? {
        entries.filter(\.isAvailable).last { ($0.offset ?? 0) <= offset }
    }
}
