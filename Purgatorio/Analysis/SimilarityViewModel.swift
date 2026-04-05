//
//  SimilarityViewModel.swift
//  Purgatorio
//
//  Bridge @MainActor entre SimilarityEngine y SwiftUI.
//  Gestiona el ciclo de vida del análisis y expone los grupos
//  de fotos cuasi-idénticas para StroboscopicA_B_View y SurvivalTournamentView.
//

import SwiftUI

@MainActor
public final class SimilarityViewModel: ObservableObject {

    // MARK: - Published State

    /// Grupos de fotos cuasi-idénticas detectados. Vacío hasta que `analyzeLibrary()` completa.
    @Published public private(set) var similarGroups: [SimilarityGroup] = []

    /// Progreso del análisis 0.0 … 1.0.
    @Published public private(set) var analysisProgress: Double = 0

    /// `true` mientras el análisis está en curso.
    @Published public private(set) var isAnalyzing: Bool = false

    /// Error presentable si el análisis falla.
    @Published public private(set) var errorMessage: String?

    // MARK: - Double-Buffer State (Modo A/B)

    /// Par de imágenes actualmente cargadas en el double buffer.
    /// `nil` hasta que `loadPair(for:)` completa.
    @Published public private(set) var currentPair: PhotoPair?

    /// `true` si el `currentPair` tiene ambas imágenes decodificadas y listas.
    public var pairIsReady: Bool { currentPair?.isComplete ?? false }

    // MARK: - Private

    private let engine: SimilarityEngine
    private let provider: PhotoProviderActor
    private var analysisTask: Task<Void, Never>?

    // MARK: - Lifecycle

    public init(
        engine: SimilarityEngine = SimilarityEngine(),
        provider: PhotoProviderActor
    ) {
        self.engine   = engine
        self.provider = provider
    }

    deinit { analysisTask?.cancel() }

    // MARK: - Public API

    /// Lanza el análisis de similitud sobre los assets dados.
    ///
    /// El análisis corre en fondo; el progreso y los resultados se publican
    /// incrementalmente en los `@Published` de este ViewModel.
    ///
    /// - Parameter assets: Assets obtenidos del `PhotoLibraryViewModel`.
    public func analyzeLibrary(assets: [PhotoAsset]) {
        analysisTask?.cancel()
        similarGroups  = []
        errorMessage   = nil
        analysisProgress = 0

        analysisTask = Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run { self.isAnalyzing = true }

            do {
                let groups = try await engine.findSimilarGroups(in: assets) { @Sendable progress in
                    Task { @MainActor [weak self] in
                        self?.analysisProgress = progress
                    }
                }
                await MainActor.run {
                    self.similarGroups   = groups
                    self.isAnalyzing     = false
                    self.analysisProgress = 1.0
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isAnalyzing  = false
                }
            }
        }
    }

    /// Carga un par de imágenes para el modo A/B Estroboscópico.
    ///
    /// Garantiza que **ambas** imágenes estén decodificadas antes de publicar
    /// `currentPair`. La UI solo recibe el par cuando el double buffer está completo.
    ///
    /// - Parameter group: Grupo de similitud. Usa los dos primeros assets del grupo.
    public func loadPair(for group: SimilarityGroup) {
        guard group.assetIDs.count >= 2 else { return }
        let idA = group.assetIDs[0]
        let idB = group.assetIDs[1]

        Task { [weak self] in
            guard let self = self else { return }
            // fetchPair garantiza que PHImageManager procesa ambas solicitudes
            // en paralelo y retorna solo cuando ambas están en RAM.
            let pair = await provider.fetchPair(
                idA: idA,
                idB: idB,
                targetSize: UIScreen.main.bounds.size
            )
            await MainActor.run { self.currentPair = pair }
        }
    }

    /// Cancela el análisis en curso.
    public func cancelAnalysis() {
        analysisTask?.cancel()
        isAnalyzing = false
    }
}
