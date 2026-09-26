import Foundation

/// The SQL of every statement SQLite ran while a trace was on, in order.
///
/// A test's receipt for how many round trips a read costs: opening a
/// conversation used to run one `message_parts` query per message, and the
/// only honest guard against that coming back is to count what SQLite
/// actually executed, not what the source looks like.
///
/// Written only from SQLite's trace callback, which runs inside
/// `sqlite3_step` on the store actor, and read only through the actor,
/// so the actor serialises every access.
final class SQLiteStatementTrace: @unchecked Sendable {
    fileprivate(set) var statements: [String] = []
}

extension SQLiteStore {
    /// Starts recording the SQL of each statement the connection runs.
    /// Nothing is installed until a test asks, so the app's own reads and
    /// writes never pay for it.
    func startStatementTrace() {
        let trace = SQLiteStatementTrace()
        statementTrace = trace
        _ = sqlite3_trace_v2(
            requiredConnection(),
            sqliteTraceStatement,
            { _, context, _, sql in
                guard let context, let sql else { return 0 }
                let text = String(cString: sql.assumingMemoryBound(to: CChar.self))
                // A trigger subprogram reports as an SQL comment. It is
                // SQLite's own work inside a statement already counted.
                guard !text.hasPrefix("--") else { return 0 }
                Unmanaged<SQLiteStatementTrace>.fromOpaque(context).takeUnretainedValue().statements.append(text)
                return 0
            },
            Unmanaged.passUnretained(trace).toOpaque()
        )
    }

    /// Stops recording and returns everything run since the trace started.
    func stopStatementTrace() -> [String] {
        _ = sqlite3_trace_v2(requiredConnection(), 0, nil, nil)
        defer { statementTrace = nil }
        return statementTrace?.statements ?? []
    }
}
