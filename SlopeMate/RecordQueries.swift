import Foundation
import GRDB

/// 하루 기록(S6)·기록 목록(S8)·시즌 기록(S9)이 읽고 지우는 쿼리 (B4; R5, R6).
nonisolated extension AppDatabase {
    /// 끝난 기록 전부, 오래된 순. 진행 중인 기록은 판정 결과를 저장하지 않아 뺀다.
    func finishedRecordings() throws -> [Recording] {
        try queue.read { try Recording.filter(Column("endedAt") != nil).order(Column("startedAt")).fetchAll($0) }
    }

    /// 끝난 기록과 저장된 판정 결과. maps는 리조트별 지도(캐시 열쇠에 지도 시각이 들어가므로 앱과 같은 것을 넘긴다).
    func summaries(_ recs: [Recording], maps: [String: SlopeMap]) throws -> [(Recording, RunDetector.Summary)] {
        try recs.map { ($0, try cache($0, map: maps[$0.resortId]).summary) }
    }

    /// 하루 기록(영업일 × 리조트)에 속한 끝난 기록. 기록은 영업일 끝에 닫히므로 시작 시각의 영업일로 정한다.
    func recordings(of day: Stats.Day) throws -> [Recording] {
        try queue.read { db in
            try Recording.filter(Column("resortId") == day.resortId && Column("endedAt") != nil)
                .order(Column("startedAt")).fetchAll(db)
                .filter { BusinessDay.start(of: $0.startedAt) == day.date }
        }
    }

    /// 닫힌 "기록 없음" 구간
    func gaps(_ recs: [Recording]) throws -> [Gap] {
        try queue.read { db in
            try Gap.filter(recs.map(\.id).contains(Column("recordingId")) && Column("toT") != nil)
                .order(Column("fromT")).fetchAll(db)
        }
    }

    /// 하루 기록 삭제(S8): 그 날 그 리조트의 끝난 기록과 딸린 행을 한 트랜잭션으로 지운다.
    /// 위치점·재시작·기록 없음·차량 구간은 FK에 cascade가 없어 직접 지우고, 리프트 대기·설질·판정 결과는 cascade로 지워진다.
    func delete(_ day: Stats.Day) throws {
        let ids = try recordings(of: day).map(\.id)
        try queue.write { db in
            for t in ["point", "restart", "gap", "vehicle"] {
                for id in ids { try db.execute(sql: "DELETE FROM \(t) WHERE recordingId = ?", arguments: [id]) }
            }
            _ = try Recording.deleteAll(db, keys: ids)
        }
    }
}
