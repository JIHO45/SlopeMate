import SwiftUI

@main
struct SlopeMateApp: App {
    var body: some Scene {
        WindowGroup {
            // ponytail: placeholder until M1 recording screens
            NavigationStack {
                List(Resort.all) { Text($0.name) }
                    .navigationTitle("SlopeMate")
            }
        }
    }
}
