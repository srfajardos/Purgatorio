import SwiftUI
import SwiftData

@main
struct PurgatorioApp: App {

    // MARK: - Root Dependencies

    private let oauth = GoogleOAuthService()
    private let provider: PhotoProviderActor
    private let predictor = IntentPredictor()

    @StateObject private var photoVM: PhotoLibraryViewModel
    @StateObject private var queueManager: PurgatorioQueueManager
    @StateObject private var similarityVM: SimilarityViewModel

    // MARK: - Init

    init() {
        // 1. Persistent container (SwiftData)
        let container: ModelContainer
        do {
            container = try PurgatorioQueueManager.makeContainer()
        } catch {
            fatalError("PurgatorioApp: no se pudo crear ModelContainer — \(error)")
        }

        // 2. Shared Data Provider (Actor)
        let newlyCreatedProvider = PhotoProviderActor(
            screenBounds: UIScreen.main.bounds.size,
            screenScale:  UIScreen.main.scale
        )
        self.provider = newlyCreatedProvider

        // 3. Global Managers
        let queue = PurgatorioQueueManager(container: container)

        // 4. ViewModels
        let photoVM = PhotoLibraryViewModel(
            provider: newlyCreatedProvider,
            queue:    queue,
            uploader: PurgatoryBatchUploader(oauth: oauth, queue: queue),
            oauth:    oauth
        )

        let similarityVM = SimilarityViewModel(
            engine:   SimilarityEngine(),
            provider: newlyCreatedProvider
        )

        // Assign to @StateObject backing storage
        _queueManager = StateObject(wrappedValue: queue)
        _photoVM      = StateObject(wrappedValue: photoVM)
        _similarityVM = StateObject(wrappedValue: similarityVM)
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack {
                    SourceSwitcherView()
                        .padding(.top)

                    Spacer()

                    if photoVM.isLoading {
                        ProgressView("Conectando con la galería...")
                            .tint(.white)
                            .foregroundStyle(.white)
                    } else if !photoVM.assets.isEmpty {
                        DestructiveSwipeView(provider: provider, predictor: predictor)
                            .padding()
                    } else {
                        Text("No hay fotos para triturar")
                            .font(.headline)
                            .foregroundStyle(.gray)
                    }

                    Spacer()
                }
            }
            .environmentObject(photoVM)
            .environmentObject(similarityVM)
            .task {
                await oauth.restoreSession()
                photoVM.start()
            }
        }
    }
}
