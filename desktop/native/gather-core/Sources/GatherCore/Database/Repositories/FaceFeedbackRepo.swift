import Foundation

/// Human decisions are durable facts, not members of a disposable automatic cluster.
public struct FaceIdentityFeedback: Sendable {
    public let photoId: String
    public let bbox: [Double]
    public let personId: String?
    public let decision: String
    public let keywords: [String]
}

public final class FaceFeedbackRepo {
    private let connection: DBConnection
    public init(connection: DBConnection) { self.connection = connection }

    public func list(sessionId: String) throws -> [FaceIdentityFeedback] {
        try connection.prepare("""
            SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, person_id, decision, keywords
            FROM face_identity_feedback WHERE session_id = ? ORDER BY updated_at, id
            """).query([.text(sessionId)]).map { row in
                FaceIdentityFeedback(photoId: row[0].textValue ?? "",
                                     bbox: (1...4).map { row[$0].doubleValue ?? 0 },
                                     personId: row[5].textValue, decision: row[6].textValue ?? "",
                                     keywords: (try? JSONValue.parse(row[7].textValue ?? "[]"))?.arrayElements?.compactMap(\.stringValue) ?? [])
            }
    }

    public func record(sessionId: String, photoId: String, bbox: [Double],
                       personId: String?, confirmed: Bool, keywords: [String] = []) throws {
        guard !confirmed || personId != nil else { throw DBError.message("Confirmed face identity requires a person") }
        guard bbox.count == 4, bbox.allSatisfy(\.isFinite), bbox[2] > 0, bbox[3] > 0 else {
            throw DBError.message("Invalid face correction geometry")
        }
        try connection.transaction {
            let rows = try connection.prepare("""
                SELECT id, bbox_x, bbox_y, bbox_w, bbox_h, person_id, decision
                FROM face_identity_feedback WHERE session_id = ? AND photo_id = ?
                """).query([.text(sessionId), .text(photoId)])
            for row in rows {
                let previous = (1...4).map { row[$0].doubleValue ?? 0 }
                guard FaceIdentityPolicy.overlap(previous, bbox) >= 0.5 else { continue }
                // Explicit assignment replaces previous confirmation and same-person rejection.
                // Rejections of other people remain useful negative evidence.
                if row[5].textValue == personId || (confirmed && row[6].textValue == "confirmed") {
                    _ = try connection.prepare("DELETE FROM face_identity_feedback WHERE id = ?")
                        .run([row[0]])
                }
            }
            _ = try connection.prepare("""
                INSERT INTO face_identity_feedback
                (session_id, photo_id, bbox_x, bbox_y, bbox_w, bbox_h, person_id, decision, updated_at, keywords)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """).run([.text(sessionId), .text(photoId)] + bbox.map(DBValue.real) + [
                    personId.map(DBValue.text) ?? .null,
                    .text(confirmed ? "confirmed" : "rejected"), .text(nowISOString()),
                    .text(try JSONValue.stringify(.array(keywords.map(JSONValue.string)))),
                ])
        }
    }

    public func forgetConfirmation(sessionId: String, photoId: String, bbox: [Double], personId: String?) throws {
        let rows = try connection.prepare("""
            SELECT id, bbox_x, bbox_y, bbox_w, bbox_h FROM face_identity_feedback
            WHERE session_id = ? AND photo_id = ? AND decision = 'confirmed' AND person_id IS ?
            """).query([.text(sessionId), .text(photoId), personId.map(DBValue.text) ?? .null])
        for row in rows where FaceIdentityPolicy.overlap((1...4).map { row[$0].doubleValue ?? 0 }, bbox) >= 0.5 {
            _ = try connection.prepare("DELETE FROM face_identity_feedback WHERE id = ?").run([row[0]])
        }
    }
}
