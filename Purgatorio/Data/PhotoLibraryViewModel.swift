//
//  PhotoLibraryViewModel.swift
//  Purgatorio
//
//  v4.0 — Prevención de OOM + Two-Phase Commit
//
//  - Memoria: Solo almacenamos [String] de localIdentifiers en RAM.
//  - Atomicidad: Implementación de executePurge con 2PC (WAL -> PhotoKit -> Clear).
//

import SwiftUI
import Photos
import os.log

// MARK: - PhotoLibraryViewModel

@MainActor
public final class PhotoLibraryViewModel: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var state: SessionState = .initializing
    @Published public private(set) var authState: PhotoLibraryAuthState = .notDetermined
    
    /// COLA OOM-SAFE: Solo identificadores para minimizar la huella de RAM.
    @Published public var shredderQueue: Set<String> = []
    
    @Published public var historyStack: [Int] = []
    
    /// LOTE OOM-SAFE: Solo identificadores. [PHAsset] es demasiado pesado para librerías grandes.
    @Published public private(set) var assets: [String] = []
    
    @Published public private(set) var currentImage: UIImage?
    @Published public private(set) var nextImage: UIImage?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var sessionStats: SessionStats = SessionStats()

    // MARK: - Dependencies

    private let provider:  PhotoProviderActor
    private let queue:     PurgatorioQueueManager
    private let journaler: AtomicJournaler

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "PhotoLibraryViewModel")
    private var assetStreamTask: Task<Void, Never>?
    private var authStreamTask:  Task<Void, Never>?

    public private(set) var currentIndex: Int = 0
    private var decidedIDs: Set<String> = []

    // MARK: - Lifecycle

    public init(
        provider:  PhotoProviderActor?   = nil,
        queue:     PurgatorioQueueManager,
        journaler: AtomicJournaler       = .shared
    ) {
        self.provider  = provider ?? PhotoProviderActor(
            screenBounds: UIScreen.main.bounds.size,
            screenScale:  UIScreen.main.scale
        )
        self.queue     = queue
        self.journaler = journaler
    }

    // MARK: - Public API: Session Lifecycle

    public func start() {
        startAppleSession()
    }

    public func resetSession() {
        assetStreamTask?.cancel()
        authStreamTask?.cancel()
        assets        = []
        currentImage  = nil
        nextImage     = nil
        currentIndex  = 0
        state         = .initializing
        decidedIDs    = []
        historyStack  = []
        shredderQueue = []
        sessionStats  = SessionStats()
        errorMessage  = nil
        start()
    }

    // MARK: - Public API: Decision Routing

    public func processDecision(_ action: DestructionAction) async {
        guard assets.indices.contains(currentIndex) else { return }
        let id = assets[currentIndex]

        decidedIDs.insert(id)
        historyStack.append(currentIndex)

        switch action {
        case .destroy:
            sessionStats.destroyed += 1
            shredderQueue.insert(id)
            // [SYNC WAL] Persistencia inmediata antes de avanzar
            await journaler.appendRecord(identifier: id)

        case .rescue:
            sessionStats.rescued += 1
        }

        await advanceToNext()
    }

    // MARK: - Public API: Two-Phase Commit Purge

    /// Ejecuta el borrado masivo garantizando la consistencia del WAL (2PC).
    public func executePurge() async {
        // Fase 1: Leer IDs pendientes del WAL
        let walIDs = await journaler.recoverState()
        guard !walIDs.isEmpty else { 
            // Si el WAL está vacío, usamos la cola en RAM (caso backup)
            if !shredderQueue.isEmpty {
                await performDelete(ids: Array(shredderQueue))
            }
            return 
        }
        
        // Fase 2: Borrado real y limpieza de WAL solo en éxito
        await performDelete(ids: walIDs)
    }

    private func performDelete(ids: [String]) async {
        do {
            try await Self.deleteAssets(withIDs: ids)
            
            // ÉXITO: Limpiar WAL y Resetar colas
            await journaler.clearWAL()
            shredderQueue.removeAll()
            
            if case .recoveringPendingShreds = state {
                await MainActor.run { self.state = .loading }
                start()
            }
            logger.info("Purga 2PC completada para \(ids.count) assets.")
            
        } catch {
            logger.error("Fallo en PHPhotoLibrary: \(error.localizedDescription). WAL intacto.")
            errorMessage = "No se pudieron borrar las fotos: \(error.localizedDescription)"
        }
    }

    nonisolated private static func deleteAssets(withIDs ids: [String]) async throws {
        let assetsToDelete = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        
        try await PHPhotoLibrary.shared().performChanges {
            // Cero copias a Swift Arrays. Consumo O(1) de memoria transitoria.
            PHAssetChangeRequest.deleteAssets(assetsToDelete)
        }
    }

    // MARK: - Public API: Recovery helpers

    public func resumeShredderRecovery() async {
        await executePurge()
    }

    public func discardRecovery() {
        Task {
            await journaler.clearWAL()
            await MainActor.run {
                self.shredderQueue.removeAll()
                self.sessionStats.destroyed = 0
                self.state = .loading
                self.start()
            }
        }
    }

    // MARK: - Private: Apple Session

    private func startAppleSession() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited {
            authState = (status == .authorized) ? .authorized : .limited
            Task { await self.loadAppleLibrary() }
        } else {
            guard authStreamTask == nil else { return }
            authStreamTask = Task { [weak self] in
                guard let self else { return }
                for await state in await provider.authorizationStateStream() {
                    await MainActor.run { self.authState = state }
                    if state == .authorized || state == .limited { await self.loadAppleLibrary() }
                }
            }
        }
    }

    private func loadAppleLibrary() async {
        await MainActor.run { state = .initializing }
        
        // Fase 1 del Arranque: Recuperación
        let recoveredIDs = await journaler.recoverState()
        if !recoveredIDs.isEmpty {
            await MainActor.run {
                self.shredderQueue = Set(recoveredIDs)
                self.sessionStats.destroyed = recoveredIDs.count
                self.state = .recoveringPendingShreds(count: recoveredIDs.count)
            }
            return
        }
        
        await MainActor.run { self.state = .loading }
        do {
            // OOM-SAFE: Solo recuperamos los identificadores
            let result = PHAsset.fetchAssets(with: .image, options: Self.fetchOptions())
            var ids: [String] = []
            result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
            
            await MainActor.run { 
                self.assets = ids 
                if ids.isEmpty {
                    self.state = .finished
                } else {
                    self.state = .active(currentIndex: 0)
                }
            }
            if !ids.isEmpty {
                await loadCurrentAndNext(from: 0)
            }
        }
    }

    // MARK: - Private: Navigation & Window Loading

    // MARK: - Public API: Navigation

    public func advance(to index: Int) {
        guard assets.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        Task { [weak self] in
            guard let self else { return }
            await provider.didAdvance(to: index)
            await loadCurrentAndNext(from: index)
        }
    }

    private func advanceToNext() async {
        var nextIdx = currentIndex + 1
        while nextIdx < assets.count && decidedIDs.contains(assets[nextIdx]) {
            nextIdx += 1
        }

        if nextIdx < assets.count {
            currentIndex = nextIdx
            await MainActor.run {
                currentImage = nextImage
                nextImage    = nil
                self.state = .active(currentIndex: nextIdx)
            }
            await provider.didAdvance(to: nextIdx)
            await loadNext(from: nextIdx)
        } else {
            await MainActor.run {
                currentImage = nil
                nextImage = nil
                self.state = .finished
            }
        }
    }

    /// CARGA BAJO DEMANDA: Solo instanciamos PHAsset para la ventana visible (N, N+1).
    private func loadCurrentAndNext(from index: Int) async {
        guard assets.indices.contains(index) else { return }
        
        let id = assets[index]
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
            let result = await provider.loadDownsampledImage(for: PhotoAsset(from: asset, index: index), targetSize: UIScreen.main.bounds.size)
            if case .success(let image, _) = result {
                await MainActor.run { self.currentImage = image }
            }
        }
        await loadNext(from: index)
    }

    private func loadNext(from index: Int) async {
        var nextIdx = index + 1
        while nextIdx < assets.count && decidedIDs.contains(assets[nextIdx]) {
            nextIdx += 1
        }
        if nextIdx < assets.count {
            let id = assets[nextIdx]
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                let result = await provider.loadDownsampledImage(for: PhotoAsset(from: asset, index: nextIdx), targetSize: UIScreen.main.bounds.size)
                if case .success(let image, _) = result {
                    await MainActor.run { self.nextImage = image }
                }
            }
        }
    }

    private static func fetchOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return o
    }
}
