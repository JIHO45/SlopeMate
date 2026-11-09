import Foundation
import GRDB

// 익명 표본으로 보낼 기기 안 기록: 리프트 대기(R10). 보내기는 서버 기능(R12).
// sendState: pending(보낼 것), sent, dropped(동의 없음·철회).

nonisolated struct LiftWait: Codable, Hashable, FetchableRecord, PersistableRecord {
    var recordingId: UUID
    var boardAt: Date
    var resortId: String
    var liftId: String
    var waitSec: Double
    var sendState: String

    static let databaseTableName = "lift_wait"
}

nonisolated extension AppDatabase {
    func liftWaits(_ rec: Recording) throws -> [LiftWait] {
        try queue.read { try LiftWait.filter(Column("recordingId") == rec.id).order(Column("boardAt")).fetchAll($0) }
    }
}
