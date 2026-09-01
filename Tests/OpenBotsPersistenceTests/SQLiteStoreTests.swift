import Foundation
import XCTest
import OpenBotsDomain
@testable import OpenBotsPersistence

final class SQLiteStoreTests: XCTestCase {
    private let receipt = try! ProtectionDecisionReceipt(
        decisionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        selectedAt: Date(timeIntervalSince1970: 1_750_000_000),
        rationaleVersion: 1
    )

    func testOnlineBackupSQLiteReopenRefusesFinalComponentSymlinks() {
        XCTAssertNotEqual(sqliteBackupDestinationOpenFlags & sqliteOpenNoFollow, 0)
    }

    func testTextBindingsAndReadsPreserveEmbeddedNULUnicodeAndWhitespace() async throws {
        try await withStore { store, _ in
            for text in ["", "\0", "before\0after", "  café 🐙\n\0résumé\t  "] {
                let rows = try await store.query(sql: "SELECT ? AS value, length(CAST(? AS BLOB)) AS bytes;",
                                                 bindings: [.text(text), .text(text)])
                let row = try XCTUnwrap(rows.first)
                XCTAssertEqual(try row.text("value"), text)
                XCTAssertEqual(try row.integer("bytes"), Int64(text.utf8.count))
            }
        }
    }

    func testMalformedUTF8FailsRatherThanRepairingStoredUserText() async throws {
        try await withStore { store, _ in
            do {
                _ = try await store.query(sql: "SELECT CAST(X'80FF' AS TEXT) AS invalid;")
                XCTFail("Malformed stored text must not decode by replacement.")
            } catch {
                XCTAssertEqual(error as? SQLiteStoreError, .invalidRow(reason: "stored text is not valid UTF-8"))
            }
        }
    }

    func testMainSQLiteOpenRefusesFinalComponentSymlinks() throws {
        XCTAssertNotEqual(sqliteStoreOpenFlags & sqliteOpenNoFollow, 0)

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinelURL = directory.appendingPathComponent("sentinel")
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        let sentinel = Data("must-not-be-opened-as-sqlite".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(
            atPath: databaseURL.path,
            withDestinationPath: sentinelURL.path
        )

        XCTAssertThrowsError(try SQLiteStore(configuration: configuration(databaseURL))) { error in
            XCTAssertEqual(
                error as? SQLiteStoreError,
                .unexpectedFileType(file: .database)
            )
        }
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
    }

    func testMainDatabaseAndLiveSidecarsAreMode0600AndReopenNarrowsBroaderModes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        let store = try SQLiteStore(configuration: configuration(databaseURL))
        try await store.insert(try makeTeammate(at: Date(timeIntervalSince1970: 1_750_000_000)))

        let liveFiles = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        for url in liveFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Expected live SQLite file \(url.lastPathComponent)")
            try assertMode0600(at: url)
            XCTAssertEqual(chmod(url.path, 0o666), 0)
        }

        _ = try SQLiteStore(configuration: configuration(databaseURL))
        for url in liveFiles {
            try assertMode0600(at: url)
        }
    }

    func testExistingSidecarWithUnexpectedFileTypeFailsClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        do {
            let store = try SQLiteStore(configuration: configuration(databaseURL))
            let integrityOK = try await store.integrityCheck()
            XCTAssertTrue(integrityOK)
        }

        let sentinelURL = directory.appendingPathComponent("sentinel")
        try Data("must-not-be-used-as-a-wal".utf8).write(to: sentinelURL)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            try FileManager.default.removeItem(at: walURL)
        }
        try FileManager.default.createSymbolicLink(
            atPath: walURL.path,
            withDestinationPath: sentinelURL.path
        )

        XCTAssertThrowsError(try SQLiteStore(configuration: configuration(databaseURL))) { error in
            XCTAssertEqual(
                error as? SQLiteStoreError,
                .unexpectedFileType(file: .writeAheadLog)
            )
        }
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("must-not-be-used-as-a-wal".utf8))
    }

    func testExplicitOrdinarySQLitePlanConfiguresWALForeignKeysAndMigrations() async throws {
        try await withStore { store, databaseURL in
            let facts = try await store.runtimeFacts()
            XCTAssertEqual(facts.protectionMode, .ordinarySQLite)
            XCTAssertEqual(facts.journalMode.lowercased(), "wal")
            XCTAssertTrue(facts.foreignKeysEnabled)
            XCTAssertEqual(facts.migrationCount, SQLiteStore.expectedMigrationCount)
            let integrityOK = try await store.integrityCheck()
            XCTAssertTrue(integrityOK)
            XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        }
    }

    func testSystemAdapterRejectsSQLCipherWithoutCreatingDatabaseOrRequestingKeyMaterial() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        let configuration = try SQLiteStoreConfiguration(
            fileURL: databaseURL,
            protection: .sqlCipher(decision: receipt, keyID: .previewControlDatabaseV1)
        )
        XCTAssertThrowsError(try SQLiteStore(configuration: configuration)) { error in
            XCTAssertEqual(
                error as? DatabaseProtectionError,
                .adapterUnavailable(requested: .sqlCipher)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testExistingDatabaseRejectsDifferentDecisionReceipt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        _ = try SQLiteStore(configuration: configuration(databaseURL))
        let different = try ProtectionDecisionReceipt(
            decisionID: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
            selectedAt: receipt.selectedAt,
            rationaleVersion: 1
        )
        XCTAssertThrowsError(
            try SQLiteStore(
                configuration: SQLiteStoreConfiguration(
                    fileURL: databaseURL,
                    protection: .ordinarySQLite(decision: different)
                )
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseProtectionError, .decisionReceiptMismatch)
        }
    }

    func testExistingDatabaseAcceptsExactFullDecisionReceipt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")

        _ = try SQLiteStore(configuration: configuration(databaseURL))
        XCTAssertNoThrow(try SQLiteStore(configuration: configuration(databaseURL)))
    }

    func testExistingDatabaseRejectsSameDecisionIDWithChangedSelectedAt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        _ = try SQLiteStore(configuration: configuration(databaseURL))
        let changedTimestamp = try ProtectionDecisionReceipt(
            decisionID: receipt.decisionID,
            selectedAt: receipt.selectedAt.addingTimeInterval(1),
            rationaleVersion: receipt.rationaleVersion
        )

        XCTAssertThrowsError(
            try SQLiteStore(
                configuration: SQLiteStoreConfiguration(
                    fileURL: databaseURL,
                    protection: .ordinarySQLite(decision: changedTimestamp)
                )
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseProtectionError, .decisionReceiptMismatch)
        }
    }

    func testExistingDatabaseRejectsSameDecisionIDWithChangedRationaleVersion() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        _ = try SQLiteStore(configuration: configuration(databaseURL))
        let changedRationale = try ProtectionDecisionReceipt(
            decisionID: receipt.decisionID,
            selectedAt: receipt.selectedAt,
            rationaleVersion: receipt.rationaleVersion + 1
        )

        XCTAssertThrowsError(
            try SQLiteStore(
                configuration: SQLiteStoreConfiguration(
                    fileURL: databaseURL,
                    protection: .ordinarySQLite(decision: changedRationale)
                )
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseProtectionError, .decisionReceiptMismatch)
        }
    }

    func testPreexistingUnmarkedDatabaseFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        let original = Data()
        XCTAssertTrue(FileManager.default.createFile(atPath: databaseURL.path, contents: original))
        XCTAssertThrowsError(try SQLiteStore(configuration: configuration(databaseURL))) { error in
            XCTAssertEqual(error as? DatabaseProtectionError, .storedModeMissing)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
    }

    func testFoundationalModelsRoundTripAndMessageSequenceIsAtomic() async throws {
        try await withStore { store, _ in
            let instant = Date(timeIntervalSince1970: 1_750_000_000)
            let teammate = try makeTeammate(at: instant)
            try await store.insert(teammate)
            let loadedTeammate = try await store.teammate(id: teammate.id)
            XCTAssertEqual(loadedTeammate, teammate)

            let conversation = try Conversation(
                id: ConversationID(UUID(uuidString: "30000000-0000-0000-0000-000000000001")!),
                kind: .direct(teammateID: teammate.id),
                createdAt: instant,
                updatedAt: instant
            )
            try await store.insert(conversation, participantIDs: [teammate.id])
            let message = try Message(
                id: MessageID(UUID(uuidString: "40000000-0000-0000-0000-000000000001")!),
                conversationID: conversation.id,
                sequence: 1,
                author: .user,
                deliveryState: .pending,
                parts: [
                    try MessagePart(
                        id: MessagePartID(UUID(uuidString: "50000000-0000-0000-0000-000000000001")!),
                        ordinal: 0,
                        content: .text("Start the work")
                    )
                ],
                createdAt: instant,
                updatedAt: instant
            )
            try await store.append(message, expectedPreviousSequence: 0)
            await XCTAssertThrowsErrorAsync {
                try await store.append(message, expectedPreviousSequence: 0)
            }
            try await store.updateDeliveryState(
                messageID: message.id,
                from: .pending,
                to: .submitted,
                updatedAt: instant.addingTimeInterval(1)
            )
            let page = try await store.page(
                conversationID: conversation.id,
                request: PageRequest(limit: 50)
            )
            XCTAssertEqual(page.elements.count, 1)
            XCTAssertEqual(page.elements[0].deliveryState, .submitted)
            XCTAssertFalse(page.hasMore)
        }
    }

    func testProjectMembershipAndScopedMemoryRoundTrip() async throws {
        try await withStore { store, _ in
            let instant = Date(timeIntervalSince1970: 1_750_000_000)
            let teammate = try makeTeammate(at: instant)
            try await store.insert(teammate)
            let project = try Project(
                id: ProjectID(UUID(uuidString: "60000000-0000-0000-0000-000000000001")!),
                name: "Atlas",
                createdAt: instant,
                updatedAt: instant
            )
            try await store.insert(project)
            try await store.setMembership(
                ProjectMembership(projectID: project.id, teammateID: teammate.id, joinedAt: instant)
            )
            let activeMemberIDs = try await store.activeMemberIDs(projectID: project.id)
            XCTAssertEqual(activeMemberIDs, [teammate.id])
            let memory = try MemoryDocument(
                id: MemoryDocumentID(UUID(uuidString: "70000000-0000-0000-0000-000000000001")!),
                scope: .project(project.id),
                author: .teammate(teammate.id),
                title: "Decision",
                relativePath: "Projects/60000000-0000-0000-0000-000000000001/decision.md",
                revision: 1,
                contentDigest: "sha256:test",
                createdAt: instant,
                updatedAt: instant
            )
            try await store.insert(memory)
            let loadedMemory = try await store.document(id: memory.id)
            XCTAssertEqual(loadedMemory, memory)
        }
    }

    func testTeamMembershipLeadAndLifecycleRoundTripAcrossReopen() async throws {
        try await withStore { store, databaseURL in
            let instant = Date(timeIntervalSince1970: 1_750_000_000)
            let first = try makeTeammate(
                id: TeammateID(UUID(uuidString: "21000000-0000-0000-0000-000000000001")!),
                name: "Nova",
                seed: 1,
                at: instant
            )
            let second = try makeTeammate(
                id: TeammateID(UUID(uuidString: "21000000-0000-0000-0000-000000000002")!),
                name: "Mica",
                seed: 2,
                at: instant
            )
            try await store.insert(first)
            try await store.insert(second)
            var team = try Team(
                id: TeamID(UUID(uuidString: "22000000-0000-0000-0000-000000000001")!),
                name: "Research Studio",
                leadID: first.id,
                memberIDs: [first.id, second.id],
                createdAt: instant,
                updatedAt: instant
            )
            try await store.insert(team)
            let insertedTeam = try await store.team(id: team.id)
            XCTAssertEqual(insertedTeam, team)

            try team.assignLead(second.id)
            try team.removeMember(first.id)
            team.lifecycle = try team.lifecycle.applying(.archive, entity: "team")
            team.updatedAt = instant.addingTimeInterval(10)
            try await store.update(team)

            let reopened = try SQLiteStore(configuration: configuration(databaseURL))
            let reloaded = try await reopened.team(id: team.id)
            XCTAssertEqual(reloaded, team)
            let activeTeams = try await reopened.listTeams(includingArchived: false)
            XCTAssertTrue(activeTeams.isEmpty)
        }
    }

    func testCapabilityGrantRevocationIsExactAndCannotReplay() async throws {
        try await withStore { store, _ in
            let instant = Date(timeIntervalSince1970: 1_750_000_000)
            let teammate = try makeTeammate(at: instant)
            try await store.insert(teammate)
            var grant = CapabilityGrant(
                id: CapabilityGrantID(UUID(uuidString: "23000000-0000-0000-0000-000000000001")!),
                teammateID: teammate.id,
                capability: .userSelectedRead,
                scope: .userSelectedRead(reference: "bookmark-ref-7"),
                grantedAt: instant
            )
            try await store.insert(grant)
            let activeBeforeRevocation = try await store.activeGrants(teammateID: teammate.id)
            XCTAssertEqual(activeBeforeRevocation, [grant])

            try grant.revoke(at: instant.addingTimeInterval(2))
            try await store.update(grant)
            let activeAfterRevocation = try await store.activeGrants(teammateID: teammate.id)
            XCTAssertTrue(activeAfterRevocation.isEmpty)
            await XCTAssertThrowsErrorAsync {
                try await store.update(grant)
            }
        }
    }

    func testApprovalTransitionsAreOptimisticAndSurviveReopen() async throws {
        try await withStore { store, databaseURL in
            let instant = Date(timeIntervalSince1970: 1_750_000_000)
            let teammate = try makeTeammate(at: instant)
            try await store.insert(teammate)
            let conversation = try Conversation(
                id: ConversationID(UUID(uuidString: "24000000-0000-0000-0000-000000000001")!),
                kind: .direct(teammateID: teammate.id),
                createdAt: instant,
                updatedAt: instant
            )
            try await store.insert(conversation, participantIDs: [teammate.id])
            var approval = try ApprovalRequest(
                id: ApprovalID(UUID(uuidString: "25000000-0000-0000-0000-000000000001")!),
                teammateID: teammate.id,
                conversationID: conversation.id,
                action: .overwrite,
                exactTargetSummary: "/exact/report.pdf",
                consequenceSummary: "Replace one exact user-approved item.",
                fingerprint: ApprovalFingerprint("sha256:frozen-operation-and-target"),
                requestedAt: instant
            )
            try await store.insert(approval)
            try approval.apply(.resolve(.approve), at: instant.addingTimeInterval(1))
            try await store.update(approval, expectedState: .pending)
            await XCTAssertThrowsErrorAsync {
                try await store.update(approval, expectedState: .pending)
            }
            try approval.apply(.beginExecution, at: instant.addingTimeInterval(2))
            try await store.update(approval, expectedState: .approved)

            let reopened = try SQLiteStore(configuration: configuration(databaseURL))
            let reloadedApproval = try await reopened.approval(id: approval.id)
            XCTAssertEqual(reloadedApproval, approval)
        }
    }

    func testOnlineBackupCapturesCommittedWALStateAndReopensWithIntegrity() async throws {
        try await withStore { store, sourceURL in
            let instant = Date(timeIntervalSince1970: 1_750_000_000)
            let teammate = try makeTeammate(at: instant)
            try await store.insert(teammate)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path + "-wal"))

            let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("Snapshot.sqlite")
            let destination = try ExclusiveSQLiteBackupDestination(exactFileURL: destinationURL)
            let receipt = try await store.createOnlineBackup(at: destination, protection: protectionPlan)
            let receiptIdentity = try FileManager.default.attributesOfItem(
                atPath: receipt.destinationFileURL.path
            )
            let requestedIdentity = try FileManager.default.attributesOfItem(
                atPath: destinationURL.path
            )
            XCTAssertEqual(receiptIdentity[.systemNumber] as? NSNumber, requestedIdentity[.systemNumber] as? NSNumber)
            XCTAssertEqual(
                receiptIdentity[.systemFileNumber] as? NSNumber,
                requestedIdentity[.systemFileNumber] as? NSNumber
            )
            XCTAssertGreaterThan(receipt.databasePageCount, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path + "-wal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path + "-shm"))
            let permissions = try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)

            let backupStore = try SQLiteStore(configuration: configuration(destinationURL))
            let backupIntegrity = try await backupStore.integrityCheck()
            let backedUpTeammate = try await backupStore.teammate(id: teammate.id)
            XCTAssertTrue(backupIntegrity)
            XCTAssertEqual(backedUpTeammate, teammate)
        }
    }

    func testOnlineBackupCollisionAndPlanMismatchLeaveTargetsAndSourceCoherent() async throws {
        try await withStore { store, sourceURL in
            let parent = sourceURL.deletingLastPathComponent()
            let collisionURL = parent.appendingPathComponent("Existing.sqlite")
            let sentinel = Data("do-not-replace".utf8)
            XCTAssertTrue(FileManager.default.createFile(atPath: collisionURL.path, contents: sentinel))
            let collision = try ExclusiveSQLiteBackupDestination(exactFileURL: collisionURL)
            await XCTAssertThrowsErrorAsync(expected: SQLiteOnlineBackupError.destinationCollision) {
                _ = try await store.createOnlineBackup(at: collision, protection: protectionPlan)
            }
            XCTAssertEqual(try Data(contentsOf: collisionURL), sentinel)

            let sourceDestination = try ExclusiveSQLiteBackupDestination(exactFileURL: sourceURL)
            await XCTAssertThrowsErrorAsync(expected: SQLiteOnlineBackupError.destinationAliasesSource) {
                _ = try await store.createOnlineBackup(at: sourceDestination, protection: protectionPlan)
            }

            let mismatchedURL = parent.appendingPathComponent("WrongPlan.sqlite")
            let mismatchedDestination = try ExclusiveSQLiteBackupDestination(exactFileURL: mismatchedURL)
            let otherReceipt = try ProtectionDecisionReceipt(
                decisionID: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
                selectedAt: receipt.selectedAt,
                rationaleVersion: 1
            )
            await XCTAssertThrowsErrorAsync(expected: SQLiteOnlineBackupError.protectionPlanMismatch) {
                _ = try await store.createOnlineBackup(
                    at: mismatchedDestination,
                    protection: .ordinarySQLite(decision: otherReceipt)
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: mismatchedURL.path))
            let sourceIntegrity = try await store.integrityCheck()
            XCTAssertTrue(sourceIntegrity)

            let reopened = try SQLiteStore(configuration: configuration(sourceURL))
            let reopenedIntegrity = try await reopened.integrityCheck()
            XCTAssertTrue(reopenedIntegrity)
        }
    }

    // MARK: - Schema trust vs. the linked SQLite version

    /// SQLite refuses virtual tables inside triggers under `trusted_schema=OFF` unless the module is
    /// tagged SQLITE_VTAB_INNOCUOUS. FTS5 received that tag in 3.44.0. The message search index is
    /// maintained by triggers, so every message insert fails on older system libraries
    /// (macOS 14 ships 3.39.x, macOS 15 ships 3.43.2) with "unsafe use of virtual table".
    func testSchemaIsTrustedOnlyOnSQLiteOlderThanInnocuousFTS5() {
        XCTAssertTrue(SQLiteSchemaTrust.requiresTrustedSchema(libraryVersionNumber: 3_039_005))   // macOS 14
        XCTAssertTrue(SQLiteSchemaTrust.requiresTrustedSchema(libraryVersionNumber: 3_043_002))   // macOS 15
        XCTAssertTrue(SQLiteSchemaTrust.requiresTrustedSchema(libraryVersionNumber: 3_043_999))
        XCTAssertFalse(SQLiteSchemaTrust.requiresTrustedSchema(libraryVersionNumber: 3_044_000))  // first innocuous FTS5
        XCTAssertFalse(SQLiteSchemaTrust.requiresTrustedSchema(libraryVersionNumber: 3_051_000))  // macOS 26
        XCTAssertEqual(SQLiteSchemaTrust.firstVersionWithInnocuousFTS5, 3_044_000)
    }

    func testOpenedConnectionTrustsSchemaExactlyWhenTheLinkedSQLiteNeedsIt() async throws {
        let linked = SQLiteSchemaTrust.linkedLibraryVersionNumber
        XCTAssertGreaterThan(linked, 3_000_000, "libversion_number must read the real linked library")
        let expected: Int64 = SQLiteSchemaTrust.requiresTrustedSchema(libraryVersionNumber: linked) ? 1 : 0
        try await withStore { store, _ in
            let rows = try await store.query(sql: "PRAGMA trusted_schema;")
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(try row.integer("trusted_schema"), expected)
        }
    }

    /// Whatever the trust decision, the trigger-maintained search index must accept a message on the
    /// linked library. This is the exact statement shape that failed on the macOS 15 runner.
    func testTriggerMaintainedSearchIndexAcceptsInsertsOnTheLinkedSQLite() async throws {
        try await withStore { store, _ in
            _ = try await store.execute(sql: "CREATE VIRTUAL TABLE trust_probe_search USING fts5(body, tokenize='unicode61 remove_diacritics 2');")
            _ = try await store.execute(sql: "CREATE TABLE trust_probe(id INTEGER PRIMARY KEY, body TEXT NOT NULL);")
            _ = try await store.execute(sql: """
                CREATE TRIGGER trust_probe_insert AFTER INSERT ON trust_probe BEGIN
                    INSERT INTO trust_probe_search(rowid, body) VALUES (NEW.id, NEW.body);
                END;
                """)
            _ = try await store.execute(sql: "INSERT INTO trust_probe(body) VALUES ('café résumé');")
            let rows = try await store.query(sql: "SELECT COUNT(*) AS n FROM trust_probe_search WHERE trust_probe_search MATCH 'cafe';")
            XCTAssertEqual(try XCTUnwrap(rows.first).integer("n"), 1)
        }
    }

    private func withStore(
        _ body: (SQLiteStore, URL) async throws -> Void
    ) async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        let store = try SQLiteStore(configuration: configuration(databaseURL))
        try await body(store, databaseURL)
    }

    private func configuration(_ databaseURL: URL) -> SQLiteStoreConfiguration {
        try! SQLiteStoreConfiguration(
            fileURL: databaseURL,
            protection: protectionPlan
        )
    }

    private var protectionPlan: PersistenceProtectionPlan {
        .ordinarySQLite(decision: receipt)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openbots-persistence-tests-\(UUID().uuidString).noindex", isDirectory: true)
    }

    private func assertMode0600(
        at url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(mode, 0o600, "Unexpected mode for \(url.lastPathComponent)", file: file, line: line)
    }

    private func makeTeammate(at instant: Date) throws -> Teammate {
        try makeTeammate(
            id: TeammateID(UUID(uuidString: "20000000-0000-0000-0000-000000000001")!),
            name: "Nova",
            seed: UInt64.max,
            at: instant
        )
    }

    private func makeTeammate(
        id: TeammateID,
        name: String,
        seed: UInt64,
        at instant: Date
    ) throws -> Teammate {
        try Teammate(
            id: id,
            profile: TeammateProfile(displayName: name, role: "Researcher"),
            appearance: AgentAppearance(
                mode: .creature,
                grammarVersion: 1,
                deterministicSeed: seed,
                silhouette: "round",
                paletteToken: "blue",
                eyeDialect: "wide",
                nonColorIdentityCue: "two crown notches",
                accessibleIdentityDescription: "Round creature with wide eyes and two crown notches"
            ),
            createdAt: instant,
            updatedAt: instant
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

private func XCTAssertThrowsErrorAsync<Expected: Error & Equatable>(
    expected: Expected,
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch let error as Expected {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(Expected.self), received \(error)", file: file, line: line)
    }
}
