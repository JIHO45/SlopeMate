#if TESTFLIGHT
import StoreKit
import SwiftUI

/// R22 테스트 기록 내보내기. TESTFLIGHT 빌드 설정(Debug, TestFlight)에만 들어간다. Release에는 없다.
/// 외부 테스트라 TestFlight 빌드를 앱스토어에 잘못 제출할 수 있으므로, 앱스토어에서 받은 앱이면 화면에 띄우지 않는다.
struct ExportSection: View {
    let recorder: Recorder
    @State private var allowed = false
    @State private var askConsent = false
    @State private var files: [(Recording, URL)] = []
    @State private var error: String?

    var body: some View {
        Group { if allowed { section } }
            .task { allowed = await Self.notAppStore() }
    }

    /// TestFlight(sandbox)나 Xcode에서 설치한 앱만 허용. 확인할 수 없으면 막는다.
    static func notAppStore() async -> Bool {
        #if DEBUG
        return true
        #else
        guard let t = try? await AppTransaction.shared else { return false }
        return t.unsafePayloadValue.environment != .production
        #endif
    }

    private var section: some View {
        Section("테스트 기록 내보내기") {
            if files.isEmpty {
                Button("오늘 기록 파일 만들기") { askConsent = true }
                    .disabled(recorder.todayRecordings.isEmpty)
            }
            ForEach(files, id: \.1) { rec, url in
                ShareLink(item: url) {
                    Text("\(Resort.name(rec.resortId)) \(rec.startedAt.formatted(date: .omitted, time: .shortened)) 공유")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .alert("위치 기록이 포함돼요", isPresented: $askConsent) {
            Button("동의하고 만들기") { makeFiles() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기록 파일에는 GPS 위치와 이동 경로 원본이 들어 있어요. 개발자에게만 보내 주세요. 받은 파일은 분석 후 30일 안에 삭제해요.")
        }
    }

    private func makeFiles() {
        do {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            files = try recorder.todayRecordings.map { rec in
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "SlopeMate-\(rec.resortId)-\(f.string(from: rec.startedAt)).json")
                try RecordingFile.encoder.encode(recorder.db.file(rec)).write(to: url, options: .completeFileProtection)
                return (rec, url)
            }
        } catch {
            self.error = "파일을 만들지 못했어요. \(error.localizedDescription)"
        }
    }
}
#endif
