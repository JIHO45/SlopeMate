#if TESTFLIGHT
import SwiftUI

/// R22 테스트 기록 내보내기. TESTFLIGHT 빌드 설정(Debug, TestFlight)에만 들어간다. Release에는 없다.
struct ExportSection: View {
    let recorder: Recorder
    @State private var askConsent = false
    @State private var files: [(Recording, URL)] = []
    @State private var error: String?

    var body: some View {
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
