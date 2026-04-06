import SwiftUI
import SwiftData

@main
struct PurgatorioApp: App {

    // MARK: - Root Dependencies

    private let provider: PhotoProviderActor
    private let predictor = IntentPredictor()

    @StateObject private var photoVM: PhotoLibraryViewModel
    @StateObject private var queueManager: PurgatorioQueueManager
    
    @Environment(\.scenePhase) private var scenePhase

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

        // 4. ViewModels (MODO MVP: Sin dependencias de Google)
        let photoVM = PhotoLibraryViewModel(
            provider:  newlyCreatedProvider,
            queue:     queue,
            journaler: .shared
        )


        // Assign to @StateObject backing storage
        _queueManager = StateObject(wrappedValue: queue)
        _photoVM      = StateObject(wrappedValue: photoVM)
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack {
                    // MODO MVP: SourceSwitcherView eliminado. 
                    // El usuario opera directamente sobre la librería local.
                    
                    Spacer()

                    switch photoVM.state {
                    case .initializing, .loading:
                        ProgressView("Conectando con la galería...")
                            .tint(.white)
                            .foregroundStyle(.white)
                            
                    case .recoveringPendingShreds(let count):
                        VStack(spacing: 20) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.orange)
                            
                            VStack(spacing: 8) {
                                Text("Recuperación de Crashing")
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                                Text("Se encontraron \(count) fotos que quedaron a medias en la trituradora.")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal)

                            HStack(spacing: 16) {
                                Button(action: {
                                    photoVM.discardRecovery()
                                }) {
                                    Text("Descartar")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 24)
                                        .background(Capsule().stroke(Color.gray, lineWidth: 1))
                                }
                                
                                Button(action: {
                                    Task { await photoVM.resumeShredderRecovery() }
                                }) {
                                    Text("Triturar Ahora")
                                        .font(.headline.bold())
                                        .foregroundColor(.white)
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 24)
                                        .background(Capsule().fill(Color.orange))
                                }
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 25).fill(Color.white.opacity(0.05)))
                        .padding()
                        
                    case .active:
                        DestructiveSwipeView(provider: provider, predictor: predictor)
                            .padding()
                            
                    case .finished:
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.green)
                            Text("Mazo exhausto")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                            if !photoVM.shredderQueue.isEmpty {
                                Text("Aún tienes \(photoVM.shredderQueue.count) fotos esperando la trituradora.")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("No hay más fotos por revisar.")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding()
                    }

                    Spacer()

                    // Barra Inferior de Combate
                    if !photoVM.historyStack.isEmpty || !photoVM.shredderQueue.isEmpty {
                        HStack {
                            // Undo Button
                            Button(action: {
                                photoVM.undoLastSwipe()
                            }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.title2.weight(.medium))
                                    .foregroundColor(photoVM.historyStack.isEmpty ? .gray : .white)
                                    .frame(width: 50, height: 50)
                                    .background(Circle().fill(Color.white.opacity(0.1)))
                            }
                            .disabled(photoVM.historyStack.isEmpty)
    
                            Spacer()
    
                            // Shredder Button
                            if !photoVM.shredderQueue.isEmpty {
                                Button(action: {
                                    Task { await photoVM.executePurge() }
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "trash.fill")
                                        Text("Triturar (\(photoVM.shredderQueue.count))")
                                            .monospacedDigit()
                                    }
                                    .font(.headline.bold())
                                    .foregroundColor(.white)
                                    .padding(.vertical, 14)
                                    .padding(.horizontal, 28)
                                    .background(Capsule().fill(Color.red))
                                    .shadow(color: .red.opacity(0.4), radius: 8, y: 4)
                                }
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .cornerRadius(30)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: photoVM.shredderQueue.count)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: photoVM.historyStack.count)
                    }
                }
            }

            .task {
                // MODO MVP: Carga directa de librería local.
                photoVM.start()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active {
                    photoVM.refreshAppleGallery()
                }
            }
        }
    }
}
