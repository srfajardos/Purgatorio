//
//  PhotoLibraryViewModel.swift
//  Purgatorio
//
//  v2.0 — Dos Silos Independientes
//
//  ViewModel central que orquesta el flujo de destrucción fotográfica.
//  Soporta dos fuentes de datos aisladas (Apple Photos / Google Photos)
//  con pipelines de borrado diferentes pero UX visceral idéntica.
//
//  Rama Apple:  PHAssetChangeRequest.deleteAssets() → borrado real e inmediato.
//  Rama Google: PurgatoryBatchUploader → álbum "Purgatorio" en Google Photos.
//
//  Metal, IntentPredictor, HapticAudioEngine y ThermalGovernor son
//  compartidos por ambas ramas. La experiencia sensorial es idéntica.
//

import SwiftUI
import Photos
import os.log

// MARK: - PhotoSourceType

/// Silo de datos activo. Determina el pipeline de carga Y de destrucción.
public enum PhotoSourceType: String, CaseIterable, Identifiable, Sendable {
    case apple  = "iPhone / iCloud"
    case google = "Google Photos"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .apple:  return "apple.logo"
        case .google: return "globe"
        }
    }
}

// MARK: - DestructionAction

/// Resultado de la decisión del usuario sobre una foto.
public enum DestructionAction: Sendable {
    /// La foto debe ser destruida (borrada o enviada al álbum Purgatorio).
    case destroy
    /// La foto se salva — se ignora y se avanza sin consecuencias.
    case rescue
}

// MARK: - SessionStats

/// Estadísticas de la sesión actual de destrucción.
public struct SessionStats: Sendable {
    public var destroyed:       Int = 0
    public var rescued:         Int = 0
    public var total:           Int { destroyed + rescued }
    /// Bytes acumulados de assets destruidos (estimación vía PHAsset resource size).
    public var totalBytesQueued: Int64 = 0

    /// Bytes formateados para UI (ej: "128.4 MB", "1.2 GB").
    public var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytesQueued, countStyle: .file)
    }
}

// MARK: - MilestoneEvent

/// Evento de hito disparado cada 25 fotos encoladas en la rama Google.
public struct MilestoneEvent: Identifiable, Sendable {
    public let id = UUID()
    public let count: Int
    public let message: String
}

// MARK: - PhotoLibraryViewModel

@MainActor
public final class PhotoLibraryViewModel: ObservableObject {

    // MARK: - Published State

    /// Fuente de datos activa. Cambiarla resetea la sesión completa.
    @Published public var activeSource: PhotoSourceType = .apple

    /// Estado de permisos de la librería de fotos (solo aplica a Apple).
    @Published public private(set) var authState: PhotoLibraryAuthState = .notDetermined

    /// Cola de activos de Apple listos para ser eliminados en lote.
    @Published public var shredderQueue: Set<PHAsset> = []

    /// Historial de índices para funcionalidad de Deshacer (Undo).
    @Published public var historyStack: [Int] = []

    /// Lista de assets disponibles para la sesión actual.
    @Published public private(set) var assets: [PhotoAsset] = []

    /// Imagen del asset actualmente visible (downsampled para preview).
    @Published public private(set) var currentImage: UIImage?

    /// Imagen del siguiente asset (pre-cargada para transición sin latencia).
    @Published public private(set) var nextImage: UIImage?

    /// Estado de carga en progreso.
    @Published public private(set) var isLoading: Bool = false

    /// Error presentable al usuario.
    @Published public private(set) var errorMessage: String?

    /// Estadísticas de la sesión actual.
    @Published public private(set) var sessionStats: SessionStats = SessionStats()

    /// `true` cuando la sesión Google terminó y hay IDs pendientes de upload.
    @Published public private(set) var showGooglePurgeButton: Bool = false

    /// ID del álbum "Purgatorio" en Google Photos (restaurado del journaler).
    @Published public private(set) var googleAlbumID: String?

    /// Evento de hito activo (25, 50, 75…). nil = sin hito pendiente.
    /// El view lo consume para mostrar un toast/banner temporal.
    @Published public var activeMilestone: MilestoneEvent?

    /// `true` tras terminar la sesión → muestra pantalla de resumen.
    @Published public var showSessionSummary: Bool = false

    // MARK: - Dependencies

    private let provider:  PhotoProviderActor
    private let queue:     PurgatorioQueueManager
    private let journaler: AtomicJournaler
    private let uploader:  PurgatoryBatchUploader?
    private let oauth:     GoogleOAuthService?

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "PhotoLibraryViewModel")
    private var assetStreamTask: Task<Void, Never>?
    private var authStreamTask:  Task<Void, Never>?

    /// Índice del asset actualmente mostrado en pantalla.
    public private(set) var currentIndex: Int = 0

    /// IDs decididos en esta sesión (para no repetir). Aplica a ambas fuentes.
    private var decidedIDs: Set<String> = []

    /// Contador de Google-destroyed para milestones (no se resetea en rescue).
    private var googleDestroyedCount: Int = 0

    /// Intervalo de milestone (cada N fotos encoladas en Google).
    private let milestoneInterval: Int = 25

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - provider: Actor de datos (PhotoKit + Metal textures).
    ///   - queue: Persistencia SwiftData de la cola de destrucción.
    ///   - journaler: WAL binario crash-safe.
    ///   - uploader: Uploader de Google Photos (nil si no hay OAuth configurado).
    ///   - oauth: Servicio OAuth de Google (nil si no hay credenciales).
    public init(
        provider:  PhotoProviderActor?   = nil,
        queue:     PurgatorioQueueManager,
        journaler: AtomicJournaler       = .shared,
        uploader:  PurgatoryBatchUploader? = nil,
        oauth:     GoogleOAuthService?   = nil
    ) {
        // Inyectar PhotoProviderActor con métricas de pantalla (@MainActor)
        self.provider  = provider ?? PhotoProviderActor(
            screenBounds: UIScreen.main.bounds.size,
            screenScale:  UIScreen.main.scale
        )
        self.queue     = queue
        self.journaler = journaler
        self.uploader  = uploader
        self.oauth     = oauth

        // Restaurar albumID del journaler (sobrevive entre sesiones)
        Task {
            let restored = await journaler.loadAlbumID()
            await MainActor.run { self.googleAlbumID = restored }
        }
    }

    deinit {
        assetStreamTask?.cancel()
        authStreamTask?.cancel()
    }

    // MARK: - Public API: Session Lifecycle

    /// Punto de entrada. Llama en `.task {}` de la vista raíz.
    public func start() {
        switch activeSource {
        case .apple:  startAppleSession()
        case .google: startGoogleSession()
        }
    }

    /// Re-evalúa la galería si hubo cambios externos en background.
    public func refreshAppleGallery() {
        guard activeSource == .apple else { return }
        logger.info("Refrescando galería Apple por retorno al foreground")
        resetSession()
    }

    /// Reinicia la sesión para la fuente activa.
    public func resetSession() {
        assetStreamTask?.cancel()
        authStreamTask?.cancel()
        assetStreamTask = nil
        authStreamTask  = nil
        assets        = []
        currentImage  = nil
        nextImage     = nil
        currentIndex  = 0
        decidedIDs    = []
        historyStack  = []
        shredderQueue = []
        sessionStats  = SessionStats()
        errorMessage  = nil
        showGooglePurgeButton = false
        start()
    }

    /// Cambia la fuente activa y resetea la sesión. Evita el didSet de activeSource.
    public func switchSource(to newSource: PhotoSourceType) {
        guard activeSource != newSource else { return }
        let oldVal = activeSource
        activeSource = newSource
        resetSession()
        logger.info("Fuente cambiada: \(oldVal.rawValue) → \(self.activeSource.rawValue)")
    }

    // MARK: - Public API: Decision Routing

    /// Procesa la decisión del usuario sobre la foto actual.
    ///
    /// **Este es el punto central de bifurcación Apple/Google.**
    ///
    /// - `.destroy`:
    ///   - Apple → `PHAssetChangeRequest.deleteAssets()` (borrado real)
    ///   - Google → `PurgatoryBatchUploader` (envío al álbum Purgatorio)
    ///
    /// - `.rescue`:
    ///   - Ambas fuentes → ignora la foto, avanza al siguiente asset.
    ///
    /// La UX visceral (Metal shredder, haptics, audio) se ejecuta ANTES de esta
    /// llamada. Cuando llegamos aquí, la animación ya completó.
    public func processDecision(_ action: DestructionAction) async {
        guard let asset = assets[safe: currentIndex] else { return }
        let id = asset.localIdentifier

        // Registrar decisión e historial
        decidedIDs.insert(id)
        historyStack.append(currentIndex)

        switch action {
        case .destroy:
            sessionStats.destroyed += 1

            switch activeSource {
            case .apple:
                if let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                    shredderQueue.insert(phAsset)
                }
            case .google:
                await enqueueGoogleAsset(id: id)
            }

        case .rescue:
            sessionStats.rescued += 1
            logger.info("Rescue: \(id) salvada. Avanzando.")
        }

        // Avanzar al siguiente asset (ambas fuentes)
        await advanceToNext()
    }

    /// Shortcut: marca para destrucción (retrocompatible con DestructiveSwipeView).
    public func markForDeletion() async {
        await processDecision(.destroy)
    }

    /// Shortcut: salvar la foto actual.
    public func rescueCurrent() async {
        await processDecision(.rescue)
    }

    // MARK: - Public API: Undo & Batch Shredding

    /// Deshace la última acción retornando a la foto anterior y removiéndola de la cola si es necesario.
    public func undoLastSwipe() {
        guard let lastIndex = historyStack.popLast() else { return }
        guard let prevAsset = assets[safe: lastIndex] else { return }
        
        let id = prevAsset.localIdentifier
        decidedIDs.remove(id)
        
        if let phAsset = shredderQueue.first(where: { $0.localIdentifier == id }) {
            shredderQueue.remove(phAsset)
            sessionStats.destroyed = max(0, sessionStats.destroyed - 1)
        } else {
            // Asumimos rescue si no estaba en la cola de Apple
            sessionStats.rescued = max(0, sessionStats.rescued - 1)
        }
        
        // Retroceder el cursor visual y forzar la recarga
        currentIndex = lastIndex
        currentImage = nil // Invalidar inmediatamente para forzar el refresh
        let targetSize = UIScreen.main.bounds.size
        Task { [weak self] in
            guard let self else { return }
            await provider.didAdvance(to: lastIndex)
            
            // Forzamos explícitamente la recarga de la imagen actual
            let result = await provider.loadDownsampledImage(for: prevAsset, targetSize: targetSize)
            if case .success(let image, _) = result {
                await MainActor.run { self.currentImage = image }
            }
            
            // Pre-cargamos la siguiente respetando el nuevo estado
            await loadNext(from: lastIndex)
        }
    }

    /// Ejecuta el borrado masivo de la shredderQueue.
    public func executeShredder() async {
        guard !shredderQueue.isEmpty else { return }
        let assetsToDelete = Array(shredderQueue) as NSFastEnumeration
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete)
            }
            logger.info("Borrado por lote completado: \(self.shredderQueue.count) fotos")
            
            // Vaciar la cola tras éxito
            shredderQueue.removeAll()
            
        } catch {
            logger.error("Fallo al ejecutar shredder masivo: \(error.localizedDescription)")
            errorMessage = "No se pudieron borrar las fotos: \(error.localizedDescription)"
        }
    }

    // MARK: - Public API: Navigation

    /// Avanza al índice dado. Actualiza cache y carga imágenes.
    public func advance(to index: Int) {
        guard index < assets.count, index != currentIndex else { return }
        currentIndex = index
        Task { [weak self] in
            guard let self else { return }
            await provider.didAdvance(to: index)
            await loadCurrentAndNext(from: index)
        }
    }

    /// Carga la imagen de un asset a resolución específica.
    public func loadImage(for asset: PhotoAsset, targetSize: CGSize) async -> UIImage? {
        let result = await provider.loadDownsampledImage(for: asset, targetSize: targetSize)
        if case .success(let image, _) = result { return image }
        return nil
    }

    // MARK: - Public API: Google Session Finalization

    /// Lanza el upload masivo al álbum "Purgatorio" de Google Photos.
    /// Llamar cuando el usuario presiona "Ir a Google Photos para vaciar el Purgatorio".
    public func triggerGoogleUpload() async {
        guard let uploader else {
            errorMessage = "Uploader de Google Photos no configurado."
            return
        }
        await uploader.startUpload()
    }

    /// Abre Google Photos en el álbum "Purgatorio".
    public func openGooglePurgatory() {
        ExecutionRouter.openPurgatoryAlbum(albumID: googleAlbumID)
    }

    // MARK: - Private: Apple Session

    private func startAppleSession() {
        guard authStreamTask == nil else { return }

        authStreamTask = Task { [weak self] in
            guard let self else { return }
            for await state in await provider.authorizationStateStream() {
                await MainActor.run { self.authState = state }
                switch state {
                case .authorized, .limited:
                    await self.loadAppleLibrary()
                case .denied(let reason):
                    await MainActor.run { self.errorMessage = reason }
                case .restricted:
                    await MainActor.run { self.errorMessage = "Acceso restringido." }
                case .notDetermined:
                    break
                }
            }
        }
    }

    private func loadAppleLibrary() async {
        await MainActor.run { isLoading = true }

        assetStreamTask = Task { [weak self] in
            guard let self else { return }
            for await asset in await provider.assetStream() {
                await MainActor.run { self.assets.append(asset) }
            }
        }

        do {
            try await provider.loadLibrary()
            await MainActor.run { isLoading = false }
            await loadCurrentAndNext(from: 0)
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Private: Google Session

    private func startGoogleSession() {
        guard let oauth else {
            errorMessage = "Servicio OAuth de Google no configurado."
            return
        }

        Task {
            do {
                // Verificar autenticación
                let isAuth = await oauth.isAuthenticated
                guard isAuth else {
                    errorMessage = "Inicia sesión en Google primero."
                    return
                }

                await MainActor.run { isLoading = true }

                // TODO: Implementar GooglePhotosProvider que liste fotos desde la API
                // Por ahora, Google Photos usa los mismos assets de PhotoKit como proxy,
                // con la diferencia de que el pipeline de destrucción es upload en vez de delete.
                try await provider.loadLibrary()

                assetStreamTask = Task { [weak self] in
                    guard let self else { return }
                    for await asset in await provider.assetStream() {
                        await MainActor.run { self.assets.append(asset) }
                    }
                }

                await MainActor.run { isLoading = false }
                await loadCurrentAndNext(from: 0)

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    // MARK: - Private: Destruction Pipelines

    /// Rama Apple: borrado real e inmediato vía PhotoKit.
    private func destroyAppleAsset(id: String) async {
        // WAL primero (crash-safe)
        Task.detached { await AtomicJournaler.shared.append(id) }

        // Persistir en SwiftData
        queue.mark(localIdentifier: id)

        // Borrado real vía PhotoKit
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [id], options: nil
        ).firstObject else {
            logger.warning("Asset no encontrado para borrado: \(id)")
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([phAsset] as NSFastEnumeration)
            }
            logger.info("Apple asset borrado: \(id)")
        } catch {
            // El usuario canceló el diálogo de confirmación del sistema
            logger.warning("Borrado cancelado/fallido para \(id): \(error.localizedDescription)")
            // No es un error fatal — el ID queda en la cola para retry
        }
    }

    /// Rama Google: encolar para upload al álbum "Purgatorio".
    private func enqueueGoogleAsset(id: String) async {
        // WAL + SwiftData (idéntico a Apple, para crash-safety)
        Task.detached { await AtomicJournaler.shared.append(id) }
        queue.mark(localIdentifier: id)

        // Calcular tamaño del asset para estadísticas de sesión
        await accumulateAssetSize(id: id)

        logger.info("Google asset encolado para Purgatorio: \(id)")

        // Mostrar botón de finalización
        showGooglePurgeButton = true

        // Sistema de hitos: cada 25 fotos Google → toast
        googleDestroyedCount += 1
        if googleDestroyedCount % milestoneInterval == 0 {
            activeMilestone = MilestoneEvent(
                count: googleDestroyedCount,
                message: "¡Hito alcanzado! \(milestoneInterval) fotos más listas para el Purgatorio. Sigue triturando."
            )
            // Auto-dismiss después de 3s
            Task {
                try? await Task.sleep(for: .seconds(3))
                if activeMilestone?.count == googleDestroyedCount {
                    activeMilestone = nil
                }
            }
        }

        // Persistir albumID si el uploader lo tiene
        if let uploader {
            let albumID = await uploader.albumID
            if let albumID, albumID != googleAlbumID {
                googleAlbumID = albumID
                Task.detached { await AtomicJournaler.shared.saveAlbumID(albumID) }
            }
        }
    }

    /// Calcula y acumula el tamaño en bytes del asset para SessionStats.
    private func accumulateAssetSize(id: String) async {
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [id], options: nil
        ).firstObject else { return }

        let resources = PHAssetResource.assetResources(for: phAsset)
        if let resource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
            let size = resource.value(forKey: "fileSize") as? Int64 ?? 0
            sessionStats.totalBytesQueued += size
        }
    }

    // MARK: - Private: Navigation

    private func advanceToNext() async {
        // Buscar el siguiente asset no-decidido
        var nextIdx = currentIndex + 1
        while nextIdx < assets.count && decidedIDs.contains(assets[nextIdx].localIdentifier) {
            nextIdx += 1
        }

        if nextIdx < assets.count {
            currentIndex = nextIdx
            await MainActor.run {
                // Promover nextImage → currentImage para latencia cero
                currentImage = nextImage
                nextImage    = nil
            }
            await provider.didAdvance(to: nextIdx)
            // Cargar la siguiente en background
            await loadNext(from: nextIdx)
        } else {
            // Fin de la sesión
            logger.info("Sesión completada. Destroyed=\(self.sessionStats.destroyed) Rescued=\(self.sessionStats.rescued) Bytes=\(self.sessionStats.formattedBytes)")
            if activeSource == .google && sessionStats.destroyed > 0 {
                showGooglePurgeButton = true
            }
            // Mostrar pantalla de resumen
            showSessionSummary = true
        }
    }

    // MARK: - Private: Image Loading

    private func loadCurrentAndNext(from index: Int) async {
        guard !assets.isEmpty else { return }
        let screenSize = UIScreen.main.bounds.size

        if index < assets.count {
            let asset = assets[index]
            let result = await provider.loadDownsampledImage(for: asset, targetSize: screenSize)
            if case .success(let image, _) = result {
                await MainActor.run { currentImage = image }
            }
        }
        await loadNext(from: index)
    }

    private func loadNext(from index: Int) async {
        let screenSize = UIScreen.main.bounds.size
        // Encontrar el siguiente no-decidido
        var nextIdx = index + 1
        while nextIdx < assets.count && decidedIDs.contains(assets[nextIdx].localIdentifier) {
            nextIdx += 1
        }
        if nextIdx < assets.count {
            let asset = assets[nextIdx]
            let result = await provider.loadDownsampledImage(for: asset, targetSize: screenSize)
            if case .success(let image, _) = result {
                await MainActor.run { nextImage = image }
            }
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
