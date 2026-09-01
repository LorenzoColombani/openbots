import Foundation

enum MemoryPersistenceTimestamp {
    /// SQLite stores Unix seconds, while Date's Codable representation uses the
    /// Foundation reference epoch. Freeze host times in the persisted precision
    /// before they enter both JSON intents and database rows. Exact comparisons
    /// remain exact; artifact timestamps and evidence supplied by sources are
    /// never rewritten or accepted with a tolerance.
    static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970)
    }
}
