import Foundation

extension SchemaMigrator {
    static let memoryLocalCorrections = """
    CREATE TABLE memory_local_corrections (
        user_message_id TEXT PRIMARY KEY REFERENCES messages(id),
        operation_id TEXT NOT NULL UNIQUE,
        conversation_id TEXT NOT NULL REFERENCES conversations(id),
        acknowledgement_message_id TEXT NOT NULL UNIQUE,
        request_json TEXT NOT NULL CHECK(length(CAST(request_json AS BLOB)) BETWEEN 1 AND 65536),
        command_digest TEXT NOT NULL CHECK(length(command_digest)=64),
        state TEXT NOT NULL CHECK(state IN ('admitted','committedUnacknowledged','acknowledged','failed')),
        revision INTEGER NOT NULL CHECK(revision > 0),
        failure_code TEXT CHECK(failure_code IN ('cancelled','contextUnavailable','contextChanged','publicationFailed')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at),
        CHECK((state='failed' AND failure_code IS NOT NULL) OR (state!='failed' AND failure_code IS NULL))
    ) STRICT;
    CREATE INDEX memory_local_corrections_conversation ON memory_local_corrections(conversation_id,state);
    """
}
