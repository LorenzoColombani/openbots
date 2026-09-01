import Foundation
import OpenBotsDomain

extension SQLiteStore: ProjectProvisioningRepository {
    public func provisionProject(
        _ project: Project,
        initialMemberIDs: Set<TeammateID>
    ) async throws {
        try transaction {
            let orderedMemberIDs = initialMemberIDs.sorted {
                $0.persistedValue < $1.persistedValue
            }

            // Revalidate membership authority inside the same database
            // transaction that publishes the project. The application service
            // performs the same validation for useful typed errors, while this
            // check closes the inter-actor race before the first write.
            for teammateID in orderedMemberIDs {
                guard let row = try query(
                    sql: "SELECT lifecycle FROM teammates WHERE id=?;",
                    bindings: [.text(teammateID.persistedValue)]
                ).first else {
                    throw RepositoryError.notFound(
                        entity: "teammate",
                        id: teammateID.persistedValue
                    )
                }
                guard try row.text("lifecycle") == TeammateLifecycle.active.rawValue else {
                    throw RepositoryError.unavailable(
                        reason: "Project members must be active teammates."
                    )
                }
            }

            try insertProjectRow(project)
            for teammateID in orderedMemberIDs {
                _ = try execute(
                    sql: """
                    INSERT INTO project_memberships(project_id,teammate_id,joined_at,revoked_at)
                    VALUES (?,?,?,NULL);
                    """,
                    bindings: [
                        .text(project.id.persistedValue),
                        .text(teammateID.persistedValue),
                        .real(project.createdAt.timeIntervalSince1970)
                    ]
                )
            }
        }
    }
}
