import SwiftUI

@main
struct PurgatorioApp: App {
    let oauth = GoogleOAuthService()

    var body: some Scene {
        WindowGroup {
            SourceSwitcherView()
                .task {
                    await oauth.restoreSession()
                }
        }
    }
}
