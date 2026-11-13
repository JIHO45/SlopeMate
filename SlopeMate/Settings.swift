import Foundation

/// 기기에 두는 사용자 설정과 서버 설정 값. UserDefaults.
nonisolated enum Settings {
    private static var d: UserDefaults { .standard }

    /// 설질 질문 표시 (R11, S17). 기본 켜짐
    static var snowPromptOn: Bool {
        get { d.object(forKey: "snowPromptOn") as? Bool ?? true }
        set { d.set(newValue, forKey: "snowPromptOn") }
    }

    /// S5 종료 잊음 알림 카드(R49)에서 "괜찮아요"를 눌렀는지. 다시 켜는 길은 설정 S17 줄
    static var notifyCardDismissed: Bool {
        get { d.bool(forKey: "notifyCardDismissed") }
        set { d.set(newValue, forKey: "notifyCardDismissed") }
    }

    /// 첫 실행 홈 리조트 선택(S1)을 마쳤는지. 저장에 성공한 뒤에만 켠다.
    static var homeSetupDone: Bool {
        get { d.bool(forKey: "homeSetupDone") }
        set { d.set(newValue, forKey: "homeSetupDone") }
    }

    /// S1 저장: 홈 리조트를 고른 순서로 저장하고, 성공하면 첫 실행 완료로 남긴다
    static func saveHomeSetup(_ ids: [String], db: AppDatabase) throws {
        try db.setHomeResorts(ids)
        homeSetupDone = true
    }

    /// 첫 기록 시작 때 익명 표본 동의를 물었는지 (R12). consentSince가 nil이면 거절했는지 아직 안 물었는지 알 수 없어 따로 둔다.
    static var consentAsked: Bool {
        get { d.bool(forKey: "consentAsked") }
        set { d.set(newValue, forKey: "consentAsked") }
    }

    /// 동의 시트 답: 물었다고 남기고 동의를 켜거나 끈다. 거절해도 기록은 시작한다.
    static func answerConsent(_ on: Bool, db: AppDatabase, now: Date = .now) throws {
        consentAsked = true
        try setConsent(on, db: db, now: now)
    }

    /// 익명 표본 전송 동의를 켠 시각 (R12). 꺼져 있거나 아직 묻지 않았으면 nil.
    /// 이 시각 이후에 생긴 표본만 보낸다. 껐다 켜면 새 시각이 되어 그 전 표본은 살아나지 않는다.
    static var consentSince: Date? { d.object(forKey: "consentSince") as? Date }

    static func setConsent(_ on: Bool, db: AppDatabase, now: Date = .now) throws {
        if on {
            guard consentSince == nil else { return }
            // 끌 때 폐기에 실패해 남은 이전 표본을 먼저 버린다. 실패하면 켜지 않는다.
            try db.dropPendingSamples()
            d.set(now, forKey: "consentSince")
        } else {
            d.removeObject(forKey: "consentSince")
            try db.dropPendingSamples()
        }
    }

    /// 표본이 생긴 시각으로 보낼 상태를 정한다
    static func sendState(at t: Date, consentSince: Date? = consentSince) -> String {
        if let consentSince, t >= consentSince { return "pending" }
        return "dropped"
    }
}

/// 리조트별 슬로프 이름 표시 (R9). 서버 설정 파일(ServerConfig)이 `update`로 채운다. 받기 전에는 모두 꺼짐.
/// 슬로프 매칭은 표시와 관계없이 항상 한다(설질 칸·표본에 필요).
nonisolated enum SlopeNames {
    private static let key = "slopeNamesShown"

    static func isShown(_ resortId: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool])?[resortId] ?? false
    }

    static func update(_ shown: [String: Bool]) { UserDefaults.standard.set(shown, forKey: key) }
}
