import SwiftUI
import UIKit

/// M1 최소 화면: 리조트 선택, 시작·종료, 오늘 기록 합계.
struct ContentView: View {
    @Bindable var recorder: Recorder
    @State private var resortId = Recorder.lastResortId ?? Resort.all[0].id
    @State private var confirmLowStorage = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let rec = recorder.recording {
                        LabeledContent("리조트", value: Resort.name(rec.resortId))
                        Text(recorder.status == .recording ? "기록 중" : "기록 멈춤").foregroundStyle(.secondary)
                    } else {
                        Picker("리조트", selection: $resortId) {
                            ForEach(Resort.all) { Text($0.name).tag($0.id) }
                        }
                    }
                    Button(recorder.recording == nil ? "기록 시작" : "기록 종료", action: toggle)
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                }

                if let gap = recorder.autoResumedGap, recorder.recording != nil {
                    Section {
                        Text("기록이 끊겼다가 자동으로 이어서 기록하고 있어요. 끊긴 \(max(1, Int(gap / 60)))분은 '기록 없음'으로 남아요.")
                        Button("기록 종료", role: .destructive) { recorder.stop() }
                        Button("확인") { recorder.autoResumedGap = nil }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                        if needsSettings {
                            Button("설정 열기") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                        }
                    }
                }

                Section("오늘") {
                    let s = recorder.today
                    LabeledContent("하강", value: "\(s.runs.count)회")
                    LabeledContent("거리", value: String(format: "%.1f km", s.distance / 1000))
                    LabeledContent("고도차", value: "\(Int(s.drop)) m")
                    LabeledContent("최고 속도", value: "\(Int(s.maxSpeed * 3.6)) km/h")
                    if s.usedGPSAltitude {
                        Text("고도 정확도 낮음: 동작 권한이 없거나 기압계를 쓸 수 없어 GPS 고도로 판정했어요.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                #if TESTFLIGHT
                ExportSection(recorder: recorder)
                #endif
            }
            .navigationTitle("SlopeMate")
            .alert("이어서 기록할까요?", isPresented: Binding(get: { recorder.pendingResume != nil }, set: { _ in })) {
                Button("이어서 기록") { recorder.answerResume(true) }
                Button("끝내기", role: .cancel) { recorder.answerResume(false) }
            } message: {
                Text("기록이 중간에 끊겼어요. 끊긴 동안은 '기록 없음'으로 남고 거리를 채워 넣지 않아요.")
            }
            .alert("저장 공간이 부족해요", isPresented: $confirmLowStorage) {
                Button("그래도 시작") { recorder.start(resortId: resortId) }
                Button("취소", role: .cancel) {}
            } message: {
                Text("남은 공간이 100MB보다 적어요. 기록 중 저장에 실패하면 기록이 멈춰요.")
            }
        }
    }

    private func toggle() {
        if recorder.recording != nil {
            recorder.stop()
        } else if Recorder.lowStorage {
            confirmLowStorage = true
        } else {
            recorder.start(resortId: resortId)
        }
    }

    private var blocked: Recorder.Blocked? {
        if case .paused(let b) = recorder.status { return b }
        return recorder.blocked
    }

    private var needsSettings: Bool { blocked != nil }

    private var message: String? {
        if case .failed(let msg) = recorder.status { return msg }
        let paused = recorder.recording != nil ? " 기록이 멈춰 있고, 권한을 다시 켜면 이어서 기록해요." : ""
        switch blocked {
        case .servicesOff: return "위치 서비스가 꺼져 있어요. 설정 > 개인정보 보호 및 보안 > 위치 서비스를 켜 주세요." + paused
        case .denied: return "위치 권한이 없어 기록할 수 없어요. 설정에서 위치를 '앱을 사용하는 동안'으로 바꿔 주세요. 위치 기록은 이 iPhone에만 저장돼요." + paused
        case .reducedAccuracy: return "정확한 위치가 꺼져 있어 기록할 수 없어요. 설정에서 '정확한 위치'를 켜 주세요." + paused
        case nil: return nil
        }
    }
}

extension Resort {
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}
