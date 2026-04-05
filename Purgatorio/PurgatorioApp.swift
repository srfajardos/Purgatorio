import SwiftUI
import SwiftData

@main
struct PurgatorioApp: App {

    // MARK: - Root Dependencies

    private let oauth = GoogleOAuthService()

    @StateObject private var photoVM: PhotoLibraryViewModel
    @StateObject private var queueManager: PurgatorioQueueManager

    // MARK: - Init

    init() {
        // 1. Persistent container (SwiftData)
        let container: ModelContainer
        do {
            container = try PurgatorioQueueManager.makeContainer()
        } catch {
            fatalError("PurgatorioApp: no se pudo crear ModelContainer — \(error)")
        }

        // 2. Queue manager (persiste la cola de destrucción)
        let queue = PurgatorioQueueManager(container: container)

        // 3. Batch uploader (Google Photos pipeline)
        let uploader = PurgatoryBatchUploader(
            oauth: oauth,
            queue: queue
        )

        // 4. Main ViewModel
        let vm = PhotoLibraryViewModel(
            queue:    queue,
            uploader: uploader,
            oauth:    oauth
        )

        // Assign to @StateObject backing storage
        _queueManager = StateObject(wrappedValue: queue)
        _photoVM      = StateObject(wrappedValue: vm)
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            SourceSwitcherView()
                .environmentObject(photoVM)
                .task {
                    await oauth.restoreSession()
                    photoVM.start()
                }
        }
    }
}
