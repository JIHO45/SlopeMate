import FirebaseAppCheck
import FirebaseCore
import SwiftUI
import UIKit

@main
struct SlopeMateApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            if let recorder = delegate.recorder, let deletion = delegate.deletion {
                RootView(recorder: recorder, account: delegate.account!, crews: delegate.crews, summary: delegate.summary!, deletion: deletion)
                    .environment(delegate.ticket)
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
    /// 시즌 이용권(R54). 결제 대기 승인·환불을 받도록 실행 때부터 Transaction.updates를 듣는다
    let ticket = SeasonTicket()
    var summary: SummarySync?
    var deletion: AccountDeletion?
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
        // App Check(R12 익명 표본): 기기는 App Attest, 시뮬레이터는 디버그 토큰(콘솔에 등록)
        #if targetEnvironment(simulator)
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AttestFactory())
        #endif
        FirebaseApp.configure()
        // 동의하지 않은 기기까지 미리 App Attest를 하지 않게 자동 갱신은 끈다(토큰은 쓸 때 받음)
        AppCheck.appCheck().isTokenAutoRefreshEnabled = false
        let account = Account()
        self.account = account
        if let recorder {
            let summary = SummarySync(db: recorder.db)
            self.summary = summary
            deletion = AccountDeletion(account: account, crews: crews, summary: summary, db: recorder.db)
        }
        return true
    }
}

/// App Attest 공급자. 익명 표본은 일회용 토큰(SampleSender)으로 쓰고, Firebase SDK가 크루 요청에도 일반 토큰을 붙일 수 있다
private nonisolated final class AttestFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? { AppAttestProvider(app: app) }
}
