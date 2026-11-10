import FirebaseCore
import SwiftUI
import UIKit

@main
struct SlopeMateApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            if let recorder = delegate.recorder {
                RootView(recorder: recorder, account: delegate.account!, crews: delegate.crews, summary: delegate.summary!)
            } else {
                ContentUnavailableView("기록 저장소를 열지 못했어요", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("저장된 기록은 지우지 않았어요. 앱을 업데이트하거나 다시 실행해 주세요.\n\(delegate.dbError ?? "")"))
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    var recorder: Recorder?
    var account: Account?
    let crews = Crews()
    var summary: SummarySync?
    var dbError: String?

    /// 시스템이 종료한 앱을 위치 이벤트로 다시 실행하면, 여기서 바로 세션과 수신을 복원해야 한다(WWDC23 10180).
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        do {
            let recorder = Recorder(db: try AppDatabase(path: AppDatabase.defaultPath()))
            recorder.handleLaunch(locationRelaunch: launchOptions?[.location] != nil)
            self.recorder = recorder
        } catch {
            dbError = error.localizedDescription
        }
        // 크루용 Firebase는 기록 복원 뒤에 켠다(위치 재실행 때 복원이 먼저)
        FirebaseApp.configure()
        account = Account()
        if let recorder { summary = SummarySync(db: recorder.db) }
        return true
    }
}
