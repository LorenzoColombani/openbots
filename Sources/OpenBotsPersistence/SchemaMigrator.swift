import Foundation

struct SchemaMigration: Sendable {
    let version: Int
    let name: String
    let sql: String

    var checksum: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in sql.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "fnv1a64:%016llx", hash)
    }
}

enum SchemaMigrator {
    static let migrations: [SchemaMigration] = [
        SchemaMigration(version: 1, name: "foundational-control-schema", sql: foundationalSchema),
        SchemaMigration(version: 2, name: "foundational-query-indexes", sql: foundationalIndexes),
        SchemaMigration(version: 3, name: "direct-chat-navigation-selection", sql: directChatNavigationSelection),
        SchemaMigration(version: 4, name: "conversational-hiring-drafts", sql: conversationalHiringDrafts),
        SchemaMigration(version: 5, name: "app-owned-markdown-authority", sql: appOwnedMarkdownAuthority),
        SchemaMigration(version: 6, name: "durable-direct-conversation-context", sql: directConversationContext),
        SchemaMigration(version: 7, name: "immutable-profile-photo-metadata", sql: profilePhotoMetadata),
        SchemaMigration(version: 8, name: "durable-conversation-composer-drafts", sql: conversationComposerDrafts),
        SchemaMigration(version: 9, name: "local-direct-conversation-search", sql: conversationSearch),
        SchemaMigration(version: 10, name: "durable-conversation-attachments", sql: conversationAttachments),
        SchemaMigration(version: 11, name: "durable-run-journal-and-input-receipts", sql: runJournal),
        SchemaMigration(version: 12, name: "durable-local-action-proposals", sql: actionProposals),
        SchemaMigration(version: 13, name: "optional-built-in-avatar-choice", sql: builtInAvatarChoice),
        SchemaMigration(version: 14, name: "stable-bot-sidebar-order", sql: botSidebarOrder),
        SchemaMigration(version: 15, name: "per-teammate-claude-model-choice", sql: teammateClaudeModelChoice),
        SchemaMigration(version: 16, name: "durable-memory-publication-intents", sql: memoryPublicationIntents),
        SchemaMigration(version: 17, name: "app-rendered-memory-conversation-publications", sql: memoryConversationPublications),
        SchemaMigration(version: 18, name: "durable-local-memory-corrections", sql: memoryLocalCorrections),
        SchemaMigration(version: 19, name: "durable-local-memory-clarifications", sql: memoryLocalCorrectionClarifications),
        SchemaMigration(version: 20, name: "controlled-memory-provider-publication", sql: controlledMemoryProviderPublication)
    ]

    static func migrate(connection: SQLiteConnection) throws {
        try SQLiteStore.execute(
            connection: connection,
            sql: """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                checksum TEXT NOT NULL,
                applied_at REAL NOT NULL
            ) STRICT;
            """
        )

        let applied = try appliedMigrations(connection: connection)
        if let newest = applied.keys.max(), newest > (migrations.last?.version ?? 0) {
            throw SQLiteStoreError.unsupportedSchemaVersion(newest)
        }

        for migration in migrations {
            if let existingChecksum = applied[migration.version] {
                guard existingChecksum == migration.checksum else {
                    throw SQLiteStoreError.migrationChecksumMismatch(version: migration.version)
                }
                continue
            }
            try SQLiteStore.execute(connection: connection, sql: "BEGIN IMMEDIATE;")
            do {
                try SQLiteStore.execute(connection: connection, sql: migration.sql)
                let escapedName = migration.name.replacingOccurrences(of: "'", with: "''")
                let escapedChecksum = migration.checksum.replacingOccurrences(of: "'", with: "''")
                try SQLiteStore.execute(
                    connection: connection,
                    sql: "INSERT INTO schema_migrations(version,name,checksum,applied_at) VALUES (\(migration.version),'\(escapedName)','\(escapedChecksum)',\(Date().timeIntervalSince1970));"
                )
                try SQLiteStore.execute(connection: connection, sql: "COMMIT;")
            } catch {
                try? SQLiteStore.execute(connection: connection, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    private static func appliedMigrations(connection: SQLiteConnection) throws -> [Int: String] {
        var statement: SQLiteStatement?
        let sql = "SELECT version, checksum FROM schema_migrations ORDER BY version;"
        let prepareResult = sql.withCString { sqlite3_prepare_v2(connection, $0, -1, &statement, nil) }
        guard prepareResult == sqliteOK, let statement else {
            throw SQLiteStore.error(connection: connection, code: prepareResult, operation: "prepare migration query")
        }
        defer { _ = sqlite3_finalize(statement) }
        var result: [Int: String] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == sqliteDone { return result }
            guard step == sqliteRow, let checksumPointer = sqlite3_column_text(statement, 1) else {
                throw SQLiteStore.error(connection: connection, code: step, operation: "read migration query")
            }
            result[Int(sqlite3_column_int64(statement, 0))] = String(cString: checksumPointer)
        }
    }

    private static let controlledMemoryProviderPublication = """
    CREATE TABLE controlled_memory_text_turns (
        run_id TEXT PRIMARY KEY REFERENCES work_runs(id),
        policy_version INTEGER NOT NULL CHECK(policy_version=1),
        admission_token TEXT NOT NULL,
        publication_id TEXT UNIQUE,
        publication_json TEXT CHECK(publication_json IS NULL OR length(CAST(publication_json AS BLOB)) BETWEEN 1 AND 131072),
        publication_digest TEXT CHECK(publication_digest IS NULL OR length(publication_digest)=64),
        finish_revision INTEGER CHECK(finish_revision IS NULL OR finish_revision>0),
        CHECK((publication_id IS NULL AND publication_json IS NULL AND publication_digest IS NULL AND finish_revision IS NULL)
            OR (publication_id IS NOT NULL AND publication_json IS NOT NULL AND publication_digest IS NOT NULL AND finish_revision IS NOT NULL))
    ) STRICT;
    CREATE TABLE claude_text_execution_evidence (
        run_id TEXT PRIMARY KEY REFERENCES work_runs(id),
        evidence_json TEXT NOT NULL CHECK(length(CAST(evidence_json AS BLOB)) BETWEEN 1 AND 4096),
        admission_token TEXT NOT NULL,
        terminal_revision INTEGER CHECK(terminal_revision IS NULL OR terminal_revision>0)
    ) STRICT;
    """

    private static let memoryConversationPublications = """
    CREATE TABLE memory_conversation_publications (
        id TEXT PRIMARY KEY,
        local_operation_id TEXT NOT NULL UNIQUE,
        conversation_id TEXT NOT NULL REFERENCES conversations(id),
        teammate_id TEXT NOT NULL REFERENCES teammates(id),
        user_message_id TEXT NOT NULL UNIQUE REFERENCES messages(id),
        reply_message_id TEXT NOT NULL UNIQUE REFERENCES messages(id),
        record_json TEXT NOT NULL CHECK(length(CAST(record_json AS BLOB)) BETWEEN 1 AND 131072),
        rendered_digest TEXT NOT NULL CHECK(length(rendered_digest)=64),
        created_at REAL NOT NULL,
        CHECK(user_message_id != reply_message_id)
    ) STRICT;
    CREATE INDEX memory_conversation_publications_conversation
        ON memory_conversation_publications(conversation_id,created_at,id);
    """

    private static let memoryPublicationIntents = """
    CREATE TABLE memory_publication_intents (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL UNIQUE,
        predecessor_id TEXT REFERENCES memory_documents(id),
        intent_json TEXT NOT NULL CHECK(length(CAST(intent_json AS BLOB)) BETWEEN 1 AND 131072),
        staging_relative_path TEXT NOT NULL UNIQUE,
        final_relative_path TEXT NOT NULL UNIQUE,
        content_digest TEXT NOT NULL CHECK(length(content_digest)=64),
        byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 16384),
        state TEXT NOT NULL CHECK(state IN ('pending','committed','aborted')),
        revision INTEGER NOT NULL CHECK(revision > 0),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at)
    ) STRICT;
    CREATE UNIQUE INDEX memory_publication_pending_predecessor
        ON memory_publication_intents(predecessor_id)
        WHERE predecessor_id IS NOT NULL AND state='pending';
    CREATE INDEX memory_publication_pending ON memory_publication_intents(state,created_at,id);
    """

    // Existing rows keep nil: launches retain their original Sonnet behavior.
    // History records the choice with the same optimistic profile revision.
    private static let teammateClaudeModelChoice = """
    ALTER TABLE teammates ADD COLUMN claude_model TEXT;
    ALTER TABLE teammates ADD COLUMN claude_effort TEXT;
    ALTER TABLE teammates ADD COLUMN claude_context_window TEXT;
    ALTER TABLE teammate_profile_revisions ADD COLUMN claude_model TEXT;
    ALTER TABLE teammate_profile_revisions ADD COLUMN claude_effort TEXT;
    ALTER TABLE teammate_profile_revisions ADD COLUMN claude_context_window TEXT;
    """

    // Seed exactly the formerly displayed active direct-chat sequence. Later
    // membership changes append/remove transactionally without using recency or
    // pin metadata to move existing rows. Participant hooks also cover ordinary
    // repository inserts, not just the atomic New Bot/hiring aggregate.
    private static let botSidebarOrder = """
    CREATE TABLE bot_sidebar_order_state (
        singleton_id INTEGER PRIMARY KEY CHECK(singleton_id=1),
        revision INTEGER NOT NULL CHECK(revision > 0)
    ) STRICT;
    INSERT INTO bot_sidebar_order_state(singleton_id,revision) VALUES (1,1);
    CREATE TABLE bot_sidebar_order (
        teammate_id TEXT PRIMARY KEY REFERENCES teammates(id),
        position INTEGER NOT NULL UNIQUE CHECK(position >= 0)
    ) STRICT;
    CREATE VIEW bot_sidebar_active_memberships AS
        SELECT t.id AS teammate_id, t.is_pinned, c.updated_at, c.id AS conversation_id
        FROM teammates t JOIN conversations c ON c.kind='direct' AND c.subject_id=t.id
        WHERE t.lifecycle='active' AND c.lifecycle='active'
        AND EXISTS (SELECT 1 FROM conversation_participants p
            WHERE p.conversation_id=c.id AND p.teammate_id=t.id AND p.left_at IS NULL);
    INSERT INTO bot_sidebar_order(teammate_id,position)
        SELECT teammate_id, ROW_NUMBER() OVER (ORDER BY is_pinned DESC,updated_at DESC,conversation_id)-1
        FROM bot_sidebar_active_memberships;
    """ + [
        ("teammate_lifecycle", "AFTER UPDATE OF lifecycle ON teammates"),
        ("conversation_lifecycle", "AFTER UPDATE OF lifecycle ON conversations"),
        ("participant_insert", "AFTER INSERT ON conversation_participants"),
        ("participant_update", "AFTER UPDATE OF conversation_id,teammate_id,left_at ON conversation_participants"),
        ("participant_delete", "AFTER DELETE ON conversation_participants")
    ].map { name, event in
        """

        CREATE TRIGGER bot_sidebar_order_\(name) \(event) BEGIN
            DELETE FROM bot_sidebar_order
                WHERE teammate_id NOT IN (SELECT teammate_id FROM bot_sidebar_active_memberships);
            UPDATE bot_sidebar_order_state SET revision=revision+1 WHERE singleton_id=1 AND changes()>0;
            INSERT INTO bot_sidebar_order(teammate_id,position)
                SELECT teammate_id,
                    (SELECT COALESCE(MAX(position),-1) FROM bot_sidebar_order)
                    + ROW_NUMBER() OVER (ORDER BY is_pinned DESC,updated_at DESC,conversation_id)
                FROM bot_sidebar_active_memberships a
                WHERE NOT EXISTS (SELECT 1 FROM bot_sidebar_order o WHERE o.teammate_id=a.teammate_id);
            UPDATE bot_sidebar_order_state SET revision=revision+1 WHERE singleton_id=1 AND changes()>0;
        END;
        """
    }.joined(separator: "\n")

    // Existing appearance rows retain every value and render as before.
    private static let builtInAvatarChoice = """
    ALTER TABLE agent_appearances ADD COLUMN built_in_avatar_id TEXT;
    """

    private static let actionProposals = """
    CREATE TABLE action_proposals (
        id TEXT PRIMARY KEY,
        teammate_id TEXT NOT NULL REFERENCES teammates(id),
        conversation_id TEXT NOT NULL REFERENCES conversations(id),
        run_id TEXT REFERENCES work_runs(id),
        envelope_json TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('pending','approved','denied','cancelled','expired')),
        revision INTEGER NOT NULL CHECK(revision > 0),
        updated_at REAL NOT NULL
    ) STRICT;
    CREATE INDEX action_proposals_conversation_updated ON action_proposals(conversation_id,updated_at DESC,id);
    CREATE TABLE action_proposal_events (
        proposal_id TEXT NOT NULL REFERENCES action_proposals(id),
        revision INTEGER NOT NULL CHECK(revision > 0),
        state TEXT NOT NULL CHECK(state IN ('pending','approved','denied','cancelled','expired')),
        recorded_at REAL NOT NULL,
        PRIMARY KEY(proposal_id,revision)
    ) STRICT;
    """

    private static let runJournal = """
    CREATE TABLE run_journal_metadata (
        run_id TEXT PRIMARY KEY REFERENCES work_runs(id) ON DELETE CASCADE,
        request_json TEXT NOT NULL CHECK(length(CAST(request_json AS BLOB)) BETWEEN 1 AND 8388608),
        origin TEXT NOT NULL CHECK(origin IN ('localFixture','executor')),
        revision INTEGER NOT NULL CHECK(revision > 0),
        lease_generation INTEGER NOT NULL DEFAULT 0 CHECK(lease_generation >= 0),
        lease_owner_id TEXT,
        lease_token TEXT,
        lease_expires_at REAL,
        CHECK((lease_owner_id IS NULL AND lease_token IS NULL AND lease_expires_at IS NULL)
           OR (lease_owner_id IS NOT NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL
               AND lease_generation > 0))
    ) STRICT;
    CREATE TABLE run_input_receipts (
        run_id TEXT NOT NULL REFERENCES run_journal_metadata(run_id) ON DELETE CASCADE,
        message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE RESTRICT,
        sequence INTEGER NOT NULL CHECK(sequence > 0),
        state TEXT NOT NULL CHECK(state IN ('queued','submitted','acknowledged','outcomeUnknown')),
        input_text TEXT NOT NULL CHECK(length(CAST(input_text AS BLOB)) <= 1048576),
        attachment_ids_json TEXT NOT NULL CHECK(length(CAST(attachment_ids_json AS BLOB)) BETWEEN 2 AND 2048),
        submitted_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= submitted_at),
        PRIMARY KEY(run_id,message_id),
        UNIQUE(run_id,sequence)
    ) STRICT;
    CREATE TABLE run_journal_entries (
        run_id TEXT NOT NULL REFERENCES run_journal_metadata(run_id) ON DELETE CASCADE,
        sequence INTEGER NOT NULL CHECK(sequence > 0),
        kind TEXT NOT NULL CHECK(kind IN ('enqueued','claimed','leaseRenewed','stateChanged','inputQueued','inputSubmitted','inputAcknowledged','recovered')),
        state TEXT NOT NULL CHECK(state IN ('queued','starting','running','waitingForUser','stopping','succeeded','failed','interrupted')),
        input_message_id TEXT REFERENCES messages(id) ON DELETE RESTRICT,
        recorded_at REAL NOT NULL,
        PRIMARY KEY(run_id,sequence)
    ) STRICT;
    CREATE INDEX run_journal_owner_active ON work_runs(teammate_id,state);
    """

    private static let conversationAttachments = """
    CREATE TABLE attachment_assets (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        display_name TEXT NOT NULL CHECK(length(CAST(display_name AS BLOB)) BETWEEN 1 AND 255),
        type_identifier TEXT NOT NULL CHECK(length(CAST(type_identifier AS BLOB)) BETWEEN 1 AND 255),
        byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 0 AND 104857600),
        sha256 TEXT NOT NULL CHECK(length(CAST(sha256 AS BLOB))=64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
        created_at REAL NOT NULL,
        UNIQUE(id,conversation_id)
    ) STRICT;
    CREATE TABLE conversation_attachment_drafts (
        conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
        revision INTEGER NOT NULL CHECK(revision > 0)
    ) STRICT;
    CREATE TABLE conversation_draft_attachment_links (
        conversation_id TEXT NOT NULL REFERENCES conversation_attachment_drafts(conversation_id) ON DELETE CASCADE,
        attachment_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        PRIMARY KEY(conversation_id,attachment_id),
        UNIQUE(conversation_id,ordinal),
        FOREIGN KEY(attachment_id,conversation_id) REFERENCES attachment_assets(id,conversation_id) ON DELETE RESTRICT
    ) STRICT;
    """

    private static let conversationSearch = """
    CREATE VIEW conversation_search_documents AS
    SELECT m.rowid AS source_rowid, m.id AS message_id,
        (SELECT group_concat(text_value, ' ') FROM
            (SELECT p.text_value FROM message_parts p
             WHERE p.message_id=m.id AND p.kind='text' ORDER BY p.ordinal)) AS body
    FROM messages m
    WHERE m.output_class='conversation' AND m.author_kind IN ('user','teammate')
      AND EXISTS (SELECT 1 FROM message_parts p WHERE p.message_id=m.id AND p.kind='text');

    CREATE VIRTUAL TABLE conversation_message_search USING fts5(
        message_id UNINDEXED, body, tokenize='unicode61 remove_diacritics 2'
    );
    INSERT INTO conversation_message_search(rowid,message_id,body)
        SELECT source_rowid,message_id,body FROM conversation_search_documents;

    CREATE TRIGGER conversation_search_message_insert AFTER INSERT ON messages BEGIN
        INSERT INTO conversation_message_search(rowid,message_id,body)
            SELECT source_rowid,message_id,body FROM conversation_search_documents WHERE message_id=NEW.id;
    END;
    CREATE TRIGGER conversation_search_message_delete AFTER DELETE ON messages BEGIN
        DELETE FROM conversation_message_search WHERE rowid=OLD.rowid;
    END;
    CREATE TRIGGER conversation_search_message_update AFTER UPDATE OF id,output_class,author_kind ON messages BEGIN
        DELETE FROM conversation_message_search WHERE rowid=OLD.rowid;
        INSERT INTO conversation_message_search(rowid,message_id,body)
            SELECT source_rowid,message_id,body FROM conversation_search_documents WHERE message_id=NEW.id;
    END;
    CREATE TRIGGER conversation_search_part_insert AFTER INSERT ON message_parts WHEN NEW.kind='text' BEGIN
        DELETE FROM conversation_message_search WHERE rowid IN (SELECT rowid FROM messages WHERE id=NEW.message_id);
        INSERT INTO conversation_message_search(rowid,message_id,body)
            SELECT source_rowid,message_id,body FROM conversation_search_documents WHERE message_id=NEW.message_id;
    END;
    CREATE TRIGGER conversation_search_part_delete AFTER DELETE ON message_parts WHEN OLD.kind='text' BEGIN
        DELETE FROM conversation_message_search WHERE rowid IN (SELECT rowid FROM messages WHERE id=OLD.message_id);
        INSERT INTO conversation_message_search(rowid,message_id,body)
            SELECT source_rowid,message_id,body FROM conversation_search_documents WHERE message_id=OLD.message_id;
    END;
    CREATE TRIGGER conversation_search_part_update AFTER UPDATE OF message_id,kind,text_value,ordinal ON message_parts
    WHEN OLD.kind='text' OR NEW.kind='text' BEGIN
        DELETE FROM conversation_message_search WHERE rowid IN (SELECT rowid FROM messages WHERE id IN (OLD.message_id,NEW.message_id));
        INSERT INTO conversation_message_search(rowid,message_id,body)
            SELECT source_rowid,message_id,body FROM conversation_search_documents
            WHERE message_id IN (OLD.message_id,NEW.message_id);
    END;
    """

    private static let conversationComposerDrafts = """
    CREATE TABLE conversation_drafts (
        conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
        text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) <= 1048576),
        revision INTEGER NOT NULL CHECK(revision > 0),
        updated_at REAL NOT NULL
    ) STRICT;
    """

    private static let profilePhotoMetadata = """
    CREATE TABLE profile_photo_assets (
        id TEXT PRIMARY KEY,
        width INTEGER NOT NULL CHECK(width BETWEEN 1 AND 512),
        height INTEGER NOT NULL CHECK(height BETWEEN 1 AND 512),
        byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 4194304),
        sha256 TEXT NOT NULL CHECK(length(sha256)=64 AND length(CAST(sha256 AS BLOB))=64 AND sha256 NOT GLOB '*[^0-9a-f]*')
    ) STRICT;
    """

    private static let directConversationContext = """
    CREATE TABLE conversation_context_selections (
        conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        project_id TEXT REFERENCES projects(id) ON DELETE RESTRICT,
        team_id TEXT REFERENCES teams(id) ON DELETE RESTRICT,
        revision INTEGER NOT NULL CHECK(revision > 0)
    ) STRICT;
    """

    private static let foundationalSchema = """
    CREATE TABLE app_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    ) STRICT;

    CREATE TABLE teammates (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        title TEXT,
        role TEXT NOT NULL,
        detailed_instructions TEXT,
        profile_revision INTEGER NOT NULL CHECK(profile_revision > 0),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active','archivePendingRunResolution','archived')),
        is_pinned INTEGER NOT NULL CHECK(is_pinned IN (0,1)),
        is_hidden INTEGER NOT NULL CHECK(is_hidden IN (0,1)),
        notification_preference TEXT NOT NULL CHECK(notification_preference IN ('inherit','disabled','enabled')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at)
    ) STRICT;

    CREATE TABLE teammate_profile_revisions (
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        revision INTEGER NOT NULL CHECK(revision > 0),
        display_name TEXT NOT NULL,
        title TEXT,
        role TEXT NOT NULL,
        detailed_instructions TEXT,
        recorded_at REAL NOT NULL,
        PRIMARY KEY(teammate_id, revision)
    ) STRICT;

    CREATE TABLE agent_appearances (
        teammate_id TEXT PRIMARY KEY REFERENCES teammates(id) ON DELETE CASCADE,
        mode TEXT NOT NULL CHECK(mode IN ('creature','photo')),
        grammar_version INTEGER NOT NULL CHECK(grammar_version > 0),
        deterministic_seed TEXT NOT NULL,
        silhouette TEXT NOT NULL,
        palette_token TEXT NOT NULL,
        eye_dialect TEXT NOT NULL,
        non_color_identity_cue TEXT NOT NULL,
        accessible_identity_description TEXT NOT NULL,
        profile_asset_id TEXT,
        revision INTEGER NOT NULL CHECK(revision > 0),
        CHECK((mode='creature' AND profile_asset_id IS NULL) OR (mode='photo' AND profile_asset_id IS NOT NULL))
    ) STRICT;

    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        summary TEXT,
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active','archived')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at)
    ) STRICT;

    CREATE TABLE project_memberships (
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        joined_at REAL NOT NULL,
        revoked_at REAL,
        CHECK(revoked_at IS NULL OR revoked_at >= joined_at),
        PRIMARY KEY(project_id, teammate_id, joined_at)
    ) STRICT;

    CREATE TABLE teams (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        summary TEXT,
        lead_teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE RESTRICT,
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active','archived')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at)
    ) STRICT;

    CREATE TABLE team_memberships (
        team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        joined_at REAL NOT NULL,
        revoked_at REAL,
        CHECK(revoked_at IS NULL OR revoked_at >= joined_at),
        PRIMARY KEY(team_id, teammate_id, joined_at)
    ) STRICT;

    CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL CHECK(kind IN ('direct','project','team')),
        subject_id TEXT NOT NULL,
        title TEXT,
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active','archived')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at),
        UNIQUE(kind, subject_id)
    ) STRICT;

    CREATE TABLE conversation_participants (
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        joined_at REAL NOT NULL,
        left_at REAL,
        CHECK(left_at IS NULL OR left_at >= joined_at),
        PRIMARY KEY(conversation_id, teammate_id, joined_at)
    ) STRICT;

    CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        sequence INTEGER NOT NULL CHECK(sequence > 0),
        author_kind TEXT NOT NULL CHECK(author_kind IN ('user','teammate','system')),
        author_teammate_id TEXT REFERENCES teammates(id) ON DELETE RESTRICT,
        output_class TEXT NOT NULL CHECK(output_class IN ('conversation','workAudit','artifact')),
        delivery_state TEXT NOT NULL CHECK(delivery_state IN ('pending','queued','submitted','acknowledged','outcomeUnknown','completed','failed')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at),
        UNIQUE(conversation_id, sequence),
        CHECK((author_kind='teammate' AND author_teammate_id IS NOT NULL) OR (author_kind!='teammate' AND author_teammate_id IS NULL))
    ) STRICT;

    CREATE TABLE message_parts (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        kind TEXT NOT NULL CHECK(kind IN ('text','attachment','artifact','status')),
        text_value TEXT,
        referenced_id TEXT,
        UNIQUE(message_id, ordinal),
        CHECK((kind IN ('text','status') AND text_value IS NOT NULL AND referenced_id IS NULL) OR (kind IN ('attachment','artifact') AND text_value IS NULL AND referenced_id IS NOT NULL))
    ) STRICT;

    CREATE TABLE memory_documents (
        id TEXT PRIMARY KEY,
        scope_kind TEXT NOT NULL CHECK(scope_kind IN ('user','teammate','project')),
        scope_id TEXT,
        author_kind TEXT NOT NULL CHECK(author_kind IN ('user','teammate','system')),
        author_teammate_id TEXT REFERENCES teammates(id) ON DELETE RESTRICT,
        title TEXT NOT NULL,
        relative_path TEXT NOT NULL UNIQUE,
        revision INTEGER NOT NULL CHECK(revision > 0),
        content_digest TEXT NOT NULL,
        supersedes_id TEXT REFERENCES memory_documents(id) ON DELETE SET NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at),
        CHECK((scope_kind='user' AND scope_id IS NULL) OR (scope_kind!='user' AND scope_id IS NOT NULL)),
        CHECK((author_kind='teammate' AND author_teammate_id IS NOT NULL) OR (author_kind!='teammate' AND author_teammate_id IS NULL))
    ) STRICT;

    CREATE TABLE capability_grants (
        id TEXT PRIMARY KEY,
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        capability TEXT NOT NULL,
        scope_json TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('active','revoked')),
        granted_at REAL NOT NULL,
        revoked_at REAL,
        CHECK(revoked_at IS NULL OR revoked_at >= granted_at)
    ) STRICT;

    CREATE TABLE approvals (
        id TEXT PRIMARY KEY,
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        action TEXT NOT NULL,
        exact_target_summary TEXT NOT NULL,
        consequence_summary TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('pending','approved','denied','expired','executing','succeeded','failed')),
        requested_at REAL NOT NULL,
        resolved_at REAL
    ) STRICT;

    CREATE TABLE work_runs (
        id TEXT PRIMARY KEY,
        teammate_id TEXT NOT NULL REFERENCES teammates(id) ON DELETE CASCADE,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        initiating_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE RESTRICT,
        selected_project_id TEXT REFERENCES projects(id) ON DELETE RESTRICT,
        profile_revision INTEGER NOT NULL CHECK(profile_revision > 0),
        state TEXT NOT NULL CHECK(state IN ('queued','starting','running','waitingForUser','stopping','succeeded','failed','interrupted')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at)
    ) STRICT;
    """

    private static let foundationalIndexes = """
    CREATE INDEX messages_conversation_sequence_desc ON messages(conversation_id, sequence DESC);
    CREATE INDEX messages_delivery_state_updated ON messages(delivery_state, updated_at);
    CREATE INDEX teammates_navigation ON teammates(lifecycle, is_hidden, is_pinned, updated_at DESC);
    CREATE INDEX project_memberships_active ON project_memberships(project_id, teammate_id) WHERE revoked_at IS NULL;
    CREATE INDEX team_memberships_active ON team_memberships(team_id, teammate_id) WHERE revoked_at IS NULL;
    CREATE INDEX conversations_updated ON conversations(lifecycle, updated_at DESC);
    CREATE INDEX memory_scope ON memory_documents(scope_kind, scope_id, updated_at DESC);
    CREATE INDEX capability_grants_active ON capability_grants(teammate_id, capability) WHERE status='active';
    CREATE INDEX approvals_state_requested ON approvals(state, requested_at);
    CREATE INDEX work_runs_state_updated ON work_runs(state, updated_at);
    """

    private static let directChatNavigationSelection = """
    CREATE TABLE chat_navigation_state (
        singleton_id INTEGER PRIMARY KEY CHECK(singleton_id=1),
        selected_conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
        updated_at REAL NOT NULL
    ) STRICT;

    INSERT INTO chat_navigation_state(singleton_id,selected_conversation_id,updated_at)
    VALUES (1,NULL,0);

    CREATE TRIGGER chat_navigation_selected_direct_insert
    BEFORE INSERT ON chat_navigation_state
    WHEN NEW.selected_conversation_id IS NOT NULL
    BEGIN
        SELECT RAISE(ABORT, 'selected conversation must be direct')
        WHERE NOT EXISTS (
            SELECT 1 FROM conversations
            WHERE id=NEW.selected_conversation_id AND kind='direct'
        );
    END;

    CREATE TRIGGER chat_navigation_selected_direct_update
    BEFORE UPDATE OF selected_conversation_id ON chat_navigation_state
    WHEN NEW.selected_conversation_id IS NOT NULL
    BEGIN
        SELECT RAISE(ABORT, 'selected conversation must be direct')
        WHERE NOT EXISTS (
            SELECT 1 FROM conversations
            WHERE id=NEW.selected_conversation_id AND kind='direct'
        );
    END;
    """

    private static let conversationalHiringDrafts = """
    CREATE TABLE hiring_drafts (
        id TEXT PRIMARY KEY,
        phase TEXT NOT NULL CHECK(phase IN ('collecting','readyForReview')),
        display_name TEXT CHECK(display_name IS NULL OR (
            length(trim(display_name, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 80
        )),
        role TEXT CHECK(role IS NULL OR (
            length(trim(role, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 240
        )),
        responsibilities TEXT CHECK(responsibilities IS NULL OR (
            length(trim(responsibilities, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 4000
        )),
        working_style TEXT CHECK(working_style IS NULL OR (
            length(trim(working_style, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 2000
        )),
        skills TEXT CHECK(skills IS NULL OR (
            length(trim(skills, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 4000
        )),
        permission_intent TEXT CHECK(permission_intent IS NULL OR (
            length(trim(permission_intent, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 4000
        )),
        project_placement TEXT CHECK(project_placement IS NULL OR (
            length(trim(project_placement, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 240
        )),
        team_placement TEXT CHECK(team_placement IS NULL OR (
            length(trim(team_placement, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 240
        )),
        revision INTEGER NOT NULL CHECK(revision > 0),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL CHECK(updated_at >= created_at),
        CHECK(phase!='readyForReview' OR (display_name IS NOT NULL AND role IS NOT NULL))
    ) STRICT;

    CREATE TABLE hiring_turns (
        id TEXT PRIMARY KEY,
        draft_id TEXT NOT NULL REFERENCES hiring_drafts(id) ON DELETE CASCADE,
        sequence INTEGER NOT NULL CHECK(sequence > 0),
        author TEXT NOT NULL CHECK(author IN ('user','guide')),
        text TEXT NOT NULL CHECK(
            length(trim(text, char(9) || char(10) || char(13) || ' ')) BETWEEN 1 AND 12000
        ),
        created_at REAL NOT NULL,
        UNIQUE(draft_id, sequence)
    ) STRICT;

    CREATE INDEX hiring_drafts_latest ON hiring_drafts(updated_at DESC, id);
    """

    private static let appOwnedMarkdownAuthority = """
    INSERT INTO app_metadata(key,value) VALUES
        ('memory_authority_kind','app-owned-markdown-tree'),
        ('memory_authority_format_version','1'),
        ('memory_authority_relative_root','HighChurn.noindex/Memory');

    CREATE UNIQUE INDEX memory_single_successor
    ON memory_documents(supersedes_id)
    WHERE supersedes_id IS NOT NULL;
    """
}
