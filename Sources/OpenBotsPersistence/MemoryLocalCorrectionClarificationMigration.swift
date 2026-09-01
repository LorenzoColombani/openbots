import Foundation

extension SchemaMigrator {
    static let memoryLocalCorrectionClarifications = """
    CREATE TABLE memory_local_correction_clarifications (
        user_message_id TEXT PRIMARY KEY REFERENCES memory_local_corrections(user_message_id),
        operation_id TEXT NOT NULL UNIQUE REFERENCES memory_local_corrections(operation_id),
        reply_message_id TEXT NOT NULL UNIQUE REFERENCES messages(id),
        reply_part_id TEXT NOT NULL UNIQUE REFERENCES message_parts(id),
        kind TEXT NOT NULL CHECK(kind IN ('targetRequired')),
        created_at REAL NOT NULL
    ) STRICT;
    """
}
