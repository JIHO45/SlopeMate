import Foundation

/// 기기에 두는 사용자 설정과 서버 설정 값. UserDefaults.
nonisolated enum Settings {
    private static var d: UserDefaults { .standard }

    /// 설질 질문 표시 (R11, S17). 기본 켜짐
    static var snowPromptOn: Bool {
        get { d.object(forKey: "snowPromptOn") as? Bool ?? true }
        set { d.set(newValue, forKey: "snowPromptOn") }
    }

    /// 익명 표본 전송 동의를 켠 시각 (R12). 꺼져 있거나 아직 묻지 않았으면 nil.
    /// 이 시각 이후에 생긴 표본만 보낸다. 껐다 켜면 새 시각이 되어 그 전 표본은 살아나지 않는다.
    static var consentSince: Date? { d.object(forKey: "consentSince") as? Date }

    static func setConsent(_ on: Bool, db: AppDatabase, now: Date = .now) throws {
        if on {
            if consentSince == nil { d.set(now, forKey: "consentSince") }
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
