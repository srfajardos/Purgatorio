//
//  PhotoProviderActor.swift
//  Purgatorio
//
//  v2.0 — Arquitectura de Carga Fantasma
//
//  Pipeline de renderizado:
//    PHImageManager (.fastFormat) → UIImage.cgImage → MTKTextureLoader → MTLTexture (GPU)
//
//  Cambios respecto a v1:
//  - Sin ImageIO manual (sin CGImageSourceCreateThumbnailAtIndex)
//  - Sin requestImageDataAndOrientation
//  - El actor retorna MTLTexture para el renderizador de Metal
//  - Cache LRU de texturas GPU (máx. 30 por defecto)
//  - userVelocity controla dinámicamente el lookahead y la resolución
//  - didAdvance(to:velocity:) acepta velocidad de swipe en assets/segundo
//  - loadDownsampledImage simplificado para el SimilarityEngine (usa .fastFormat)
//

import Photos
@preconcurrency import MetalKit
@preconcurrency import Metal
import UIKit
import os.log

// MARK: - Supporting Types

/// Estado de autorización de acceso a la biblioteca de fotos.
public enum PhotoLibraryAuthState: Sendable, Equatable {
    case notDetermined
    case authorized
    case limited
    /// El usuario denegó o restringió el acceso. `reason` describe el motivo.
    case denied(reason: String)
    case restricted
}

/// Wrapper ligero de un asset fotográfico con metadatos pre-calculados.
public struct PhotoAsset: Identifiable, Sendable, Hashable {
    public let id: String
    public let index: Int
    public let creationDate: Date?
    public let duration: TimeInterval
    public let mediaType: PHAssetMediaType
    public let pixelSize: CGSize
    /// Aislado al actor; consumidores de SwiftUI usan solo los campos primitivos.
    internal let localIdentifier: String

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Resultado de la carga de imagen downsampled (ruta de análisis, NO de renderizado).
public enum DownsampledImageResult: Sendable {
    case success(image: UIImage, assetID: String)
    case failure(assetID: String, error: DownsamplingError)
}

/// Errores del pipeline de carga de imagen.
public enum DownsamplingError: Error, Sendable {
    case assetNotFound
    case assetDataUnavailable
    case textureConversionFailed
    case requestCancelled
    case metalUnavailable
}

/// Par de imágenes UIImage para la ruta de análisis (pHash, SwiftUI preview).
/// Para renderizado Metal usa `TexturePair`.
public struct PhotoPair: Sendable {
    public let idA: String
    public let resultA: DownsampledImageResult
    public let idB: String
    public let resultB: DownsampledImageResult

    public var isComplete: Bool {
        guard case .success = resultA, case .success = resultB else { return false }
        return true
    }
    public var images: (UIImage, UIImage)? {
        guard case .success(let a, _) = resultA,
              case .success(let b, _) = resultB else { return nil }
        return (a, b)
    }
}

/// Par de texturas Metal — el doble buffer primario del pipeline de renderizado.
///
/// `@unchecked Sendable` es seguro: `MTLTexture` es thread-safe por diseño de Metal.
/// Las instancias son inmutables tras la creación.
public final class TexturePair: @unchecked Sendable {
    public let idA: String
    public let textureA: (any MTLTexture)?
    public let idB: String
    public let textureB: (any MTLTexture)?

    /// `true` cuando ambas texturas están en memoria GPU y listas para el shader.
    public var isComplete: Bool { textureA != nil && textureB != nil }

    init(idA: String, textureA: (any MTLTexture)?,
         idB: String, textureB: (any MTLTexture)?) {
        self.idA = idA; self.textureA = textureA
        self.idB = idB; self.textureB = textureB
    }
}

// MARK: - PhotoProviderActor

/// Actor central de Purgatorio para interacción con PhotoKit y entrega de texturas Metal.
///
/// ## Ciclo de Vida
/// ```swift
/// let provider = PhotoProviderActor()
/// // 1. Permisos
/// for await state in await provider.authorizationStateStream() { ... }
/// // 2. Carga catálogo
/// try await provider.loadLibrary()
/// // 3. Consume stream de assets
/// for await asset in await provider.assetStream() { ... }
/// // 4. Renderizado: double buffer de texturas Metal
/// let pair = await provider.fetchTexturePair(idA: a.id, idB: b.id)
/// // 5. Avance con velocidad
/// await provider.didAdvance(to: newIndex, velocity: swipeVelocity)
/// ```
public actor PhotoProviderActor {

    // MARK: - Metal Resources (init-time, inmutables)

    /// Dispositivo Metal del sistema. `nil` en simulador sin GPU.
    private let metalDevice: (any MTLDevice)?

    /// Loader que sube CGImage al buffer GPU. Hilo-seguro por diseño de MetalKit.
    private let textureLoader: MTKTextureLoader?

    // MARK: - Texture LRU Cache

    /// Texturas GPU residentes, indexadas por `localIdentifier`.
    private var textureCache: [String: any MTLTexture] = [:]

    /// Límite de texturas GPU en cache. Una textura 390×844 BGRA = ~1.3 MB.
    /// 30 texturas ≈ 40 MB — presupuesto conservador para dispositivos con 4 GB RAM.
    private let maxTextureCacheSize: Int

    /// Cola de acceso más reciente → frente = candidato a evición.
    private var textureLRUOrder: [String] = []

    // MARK: - Screen Metrics (inyectadas desde MainActor en init)

    /// Resolución de pantalla en puntos (ej. 393×852 en iPhone 15 Pro).
    private let screenBounds: CGSize

    /// Escala de pantalla (ej. 3.0 en dispositivos @3x).
    private let screenScale: CGFloat

    // MARK: - Velocity-Aware Dynamic State

    /// Velocidad de swipe en assets/segundo. Actualizada por `didAdvance(to:velocity:)`.
    private var userVelocity: Float = 0

    /// Número de assets a pre-cargar. Escala con la velocidad para anticipar el consumo.
    private var dynamicLookaheadCount: Int {
        switch userVelocity {
        case ..<1:   return lookaheadBase
        case 1..<3: return min(lookaheadBase * 2, 10)
        case 3..<6: return min(lookaheadBase * 3, 15)
        default:    return 20
        }
    }

    /// Tamaño de textura objetivo dinámico. Alta velocidad = menor resolución = mayor throughput.
    private var dynamicTextureSize: CGSize {
        switch userVelocity {
        case ..<1:
            return CGSize(width: screenBounds.width * screenScale,
                          height: screenBounds.height * screenScale)
        case 1..<3:
            return CGSize(width: screenBounds.width * screenScale * 0.7,
                          height: screenBounds.height * screenScale * 0.7)
        case 3..<6:
            return CGSize(width: 512, height: 768)
        default:
            return CGSize(width: 256, height: 384)
        }
    }

    // MARK: - PhotoKit State

    private let lookaheadBase: Int
    private let cachingManager: PHCachingImageManager
    private var fetchResult: PHFetchResult<PHAsset>?
    private var currentIndex: Int = 0
    private var cachedIdentifiers: Set<String> = []
    private var assetContinuation: AsyncStream<PhotoAsset>.Continuation?
    private var authContinuation: AsyncStream<PhotoLibraryAuthState>.Continuation?
    private let logger = Logger(subsystem: "com.purgatorio.app", category: "PhotoProviderActor")

    // MARK: - Request Options

    /// Opciones de renderizado: Apple fast-path (hardware decode VT/ISP).
    /// Elimina la necesidad de ImageIO manual — el sistema elige el decoder óptimo.
    private func makeRenderRequestOptions() -> PHImageRequestOptions {
        let opts = PHImageRequestOptions()
        opts.deliveryMode          = .fastFormat  // Hardware HEIC/JPEG decode
        opts.resizeMode            = .fast         // Memory-efficient system resize
        opts.isNetworkAccessAllowed = true         // iCloud
        opts.isSynchronous         = false
        opts.version               = .current
        return opts
    }

    /// Opciones de lookahead/PHCachingImageManager.
    private let lookaheadRequestOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode           = .fastFormat
        o.resizeMode             = .fast
        o.isNetworkAccessAllowed = true
        o.isSynchronous          = false
        return o
    }()

    // MARK: - Initializer

    /// - Parameters:
    ///   - lookaheadCount: Lookahead base (escala dinámica con velocidad). Default: 5.
    ///   - maxTextureCacheSize: Máximo de texturas GPU en cache LRU. Default: 30.
    ///   - screenBounds: Tamaño de pantalla en puntos. Pasar desde @MainActor.
    ///   - screenScale: Escala de pantalla (@1x, @2x, @3x). Pasar desde @MainActor.
    public init(
        lookaheadCount: Int = 5,
        maxTextureCacheSize: Int = 30,
        screenBounds: CGSize = CGSize(width: 393, height: 852),
        screenScale: CGFloat = 3.0
    ) {
        self.lookaheadBase       = max(1, lookaheadCount)
        self.maxTextureCacheSize = max(5, maxTextureCacheSize)
        self.screenBounds        = screenBounds
        self.screenScale         = screenScale
        self.cachingManager      = PHCachingImageManager()
        self.cachingManager.allowsCachingHighQualityImages = false

        let device = MTLCreateSystemDefaultDevice()
        self.metalDevice   = device
        self.textureLoader = device.map { MTKTextureLoader(device: $0) }

        if device == nil {
            Logger(subsystem: "com.purgatorio.app", category: "PhotoProviderActor")
                .critical("MTLCreateSystemDefaultDevice() retornó nil.")
        }
    }

    // MARK: - Public API: Authorization

    /// Stream de estado de autorización. Emite al menos un valor inmediatamente.
    public func authorizationStateStream() -> AsyncStream<PhotoLibraryAuthState> {
        AsyncStream { [weak self] continuation in
            guard let self = self else { continuation.finish(); return }
            Task { [weak self] in
                await self?.storeAuthContinuation(continuation)
                let state = await self?.currentAuthState() ?? .notDetermined
                continuation.yield(state)
                if state == .notDetermined {
                    if let new = await self?.requestAuthorization() {
                        continuation.yield(new)
                    }
                }
            }
        }
    }

    @discardableResult
    public func requestAuthorization() async -> PhotoLibraryAuthState {
        guard await currentAuthState() == .notDetermined else {
            return await currentAuthState()
        }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                let state = PhotoLibraryAuthState(from: status)
                Task { [weak self] in
                    guard let self = self else { return }
                    await self.authContinuation?.yield(state)
                }
                continuation.resume(returning: state)
            }
        }
    }

    // MARK: - Public API: Library Loading

    /// Carga el catálogo de fotos. Requiere estado `.authorized` o `.limited`.
    public func loadLibrary() async throws {
        let state = await currentAuthState()
        guard state == .authorized || state == .limited else {
            throw PhotoLibraryError.unauthorized(state: state)
        }
        cachingManager.stopCachingImagesForAllAssets()
        cachedIdentifiers.removeAll()

        logger.info("loadLibrary: iniciando fetch…")
        let result = PHAsset.fetchAssets(with: .image, options: Self.fetchOptions)
        self.fetchResult = result
        logger.info("loadLibrary: \(result.count) assets encontrados.")

        for i in 0 ..< result.count {
            autoreleasepool {
                let asset = result.object(at: i)
                self.assetContinuation?.yield(PhotoAsset(from: asset, index: i))
            }
        }
        await updateLookaheadCache(around: 0)
    }

    // MARK: - Public API: Asset Stream

    public func assetStream() -> AsyncStream<PhotoAsset> {
        AsyncStream { [weak self] continuation in
            guard let self = self else { continuation.finish(); return }
            Task { [weak self] in await self?.storeAssetContinuation(continuation) }
        }
    }

    // MARK: - Public API: Metal Texture Pipeline (ruta primaria de renderizado)

    /// Carga **dos** texturas Metal simultáneamente — el doble buffer del modo A/B.
    ///
    /// Garantiza que ambas texturas estén en la GPU antes de retornar el control a la UI.
    /// La resolución se ajusta dinámicamente a `userVelocity` para mantener 120fps.
    ///
    /// ## Concurrencia
    /// `async let` lanza ambas cargas en paralelo. Cada una suspende en
    /// `withCheckedContinuation` mientras PHImageManager decodifica en hardware,
    /// luego salta a un `Task.detached` para el upload GPU con `MTKTextureLoader`.
    /// El `return await TexturePair(...)` actúa como join point — control vuelve
    /// a la UI solo cuando **ambas** texturas están `MTLTexture`-residentes en GPU.
    ///
    /// - Returns: `TexturePair`. Verifica `pair.isComplete` antes de usarlo en shaders.
    public func fetchTexturePair(idA: String, idB: String) async -> TexturePair {
        let size = dynamicTextureSize
        async let texA = loadTexture(identifier: idA, targetSize: size)
        async let texB = loadTexture(identifier: idB, targetSize: size)
        return await TexturePair(idA: idA, textureA: texA, idB: idB, textureB: texB)
    }

    // MARK: - Public API: Single Texture (para DestructiveSwipeView)

    /// Carga una textura Metal para un asset concreto.
    ///
    /// Conveniente para `DestructiveSwipeView`: cuando el swipe supera el umbral
    /// de velocidad, solicita la textura del asset visible en ese instante para
    /// entregársela al `GlobalShredderManager` justo antes de ocultarla.
    ///
    /// La textura puede estar ya en el LRU cache (lookahead pre-warm) → latencia ~0.
    ///
    /// - Parameters:
    ///   - asset: El `PhotoAsset` cuya textura se requiere.
    ///   - targetSize: Resolución de la textura. Default: tamaño de pantalla.
    public func loadTexture(
        for asset: PhotoAsset,
        targetSize: CGSize? = nil
    ) async -> (any MTLTexture)? {
        let size = targetSize ?? CGSize(width: screenBounds.width * screenScale,
                                        height: screenBounds.height * screenScale)
        return await loadTexture(identifier: asset.localIdentifier, targetSize: size)
    }

    // MARK: - Public API: UIImage Pipeline (ruta de análisis — SimilarityEngine)

    /// Carga una imagen downsampled via PHImageManager `.fastFormat`.
    ///
    /// Esta ruta es para el `SimilarityEngine` (pHash, Vision). No produce MTLTexture.
    /// Para renderizado, usa `fetchTexturePair`.
    public func loadDownsampledImage(
        for asset: PhotoAsset,
        targetSize: CGSize,
        scale: CGFloat? = nil
    ) async -> DownsampledImageResult {
        let effectiveScale = scale ?? screenScale
        let pixelSize = CGSize(width: targetSize.width * effectiveScale,
                               height: targetSize.height * effectiveScale)

        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.localIdentifier], options: nil
        ).firstObject else {
            return .failure(assetID: asset.localIdentifier, error: .assetNotFound)
        }

        return await withCheckedContinuation { continuation in
            var resolved = false
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: pixelSize,
                contentMode: .aspectFill,
                options: makeRenderRequestOptions()
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                guard !resolved else { return }
                resolved = true

                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(returning: .failure(
                        assetID: asset.localIdentifier, error: .requestCancelled))
                    return
                }
                if let image {
                    continuation.resume(returning: .success(
                        image: image, assetID: asset.localIdentifier))
                } else {
                    continuation.resume(returning: .failure(
                        assetID: asset.localIdentifier, error: .assetDataUnavailable))
                }
            }
        }
    }

    /// Double buffer de UIImage (ruta de análisis). Mantiene compatibilidad con `SimilarityViewModel`.
    public func fetchPair(idA: String, idB: String, targetSize: CGSize,
                          scale: CGFloat? = nil) async -> PhotoPair {
        let effectiveScale = scale ?? screenScale
        let pixelSize = CGSize(width: targetSize.width * effectiveScale, height: targetSize.height * effectiveScale)

        async let resultA = loadUIImage(identifier: idA, targetSize: pixelSize)
        async let resultB = loadUIImage(identifier: idB, targetSize: pixelSize)
        return await PhotoPair(idA: idA, resultA: resultA, idB: idB, resultB: resultB)
    }

    // MARK: - Public API: Lookahead Cache Control

    /// Notifica al actor que el índice visible cambió con la velocidad de swipe actual.
    ///
    /// - Parameters:
    ///   - index: Nuevo índice visible.
    ///   - velocity: Velocidad de swipe en assets/segundo. 0 = parado.
    public func didAdvance(to index: Int, velocity: Float = 0) async {
        userVelocity = velocity
        guard index != currentIndex else { return }
        currentIndex = index
        await updateLookaheadCache(around: index)
    }

    // MARK: - Public API: Texture Cache Management

    /// Purga texturas GPU que no pertenecen a `keepingIDs`.
    /// Llama esto en eventos de memory pressure (`UIApplicationDidReceiveMemoryWarningNotification`).
    public func purgeTextureCache(keepingIDs ids: Set<String> = []) {
        let evicted = textureLRUOrder.filter { !ids.contains($0) }
        evicted.forEach { textureCache.removeValue(forKey: $0) }
        textureLRUOrder.removeAll { !ids.contains($0) }
        logger.info("TextureCache purgado. Evicted: \(evicted.count). Retenidos: \(ids.count).")
    }

    // MARK: - Private: MTLTexture Loading

    private func loadTexture(identifier: String, targetSize: CGSize) async -> (any MTLTexture)? {
        // 1. Cache hit LRU
        if let cached = textureCache[identifier] {
            touchLRU(identifier)
            return cached
        }

        guard let loader = textureLoader else {
            logger.error("MTKTextureLoader no disponible — Metal no inicializado correctamente.")
            return nil
        }

        // 2. Fetch via PHImageManager (Apple hardware decode path)
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else {
            logger.warning("Asset no encontrado en PhotoKit: \(identifier)")
            return nil
        }

        let cgImage: CGImage? = await withCheckedContinuation { continuation in
            var resolved = false
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: makeRenderRequestOptions()
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                guard !resolved else { return }
                resolved = true
                continuation.resume(returning: image?.cgImage)
            }
        }

        guard let cgImage else { return nil }

        // 3. GPU upload via MTKTextureLoader (Task.detached: bloqueante ~1-5ms, no bloquear el actor)
        let texture: (any MTLTexture)? = try? await Task.detached(priority: .userInitiated) {
            try loader.newTexture(cgImage: cgImage, options: [
                .SRGB              : false,                          // sRGB off: el shader aplica su propio color space
                .generateMipmaps   : false,                          // Sin mipmaps: scrolling plano, no 3D
                .textureUsage      : NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ])
        }.value

        if let texture { cacheTexture(texture, for: identifier) }
        return texture
    }

    // MARK: - Private: UIImage Loading (análisis)

    private func loadUIImage(identifier: String, targetSize: CGSize) async -> DownsampledImageResult {
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else {
            return .failure(assetID: identifier, error: .assetNotFound)
        }

        return await withCheckedContinuation { continuation in
            var resolved = false
            PHImageManager.default().requestImage(
                for: phAsset, targetSize: targetSize, contentMode: .aspectFill,
                options: makeRenderRequestOptions()
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                guard !resolved else { return }
                resolved = true
                if let image {
                    continuation.resume(returning: .success(image: image, assetID: identifier))
                } else {
                    continuation.resume(returning: .failure(assetID: identifier, error: .assetDataUnavailable))
                }
            }
        }
    }

    // MARK: - Private: Texture LRU Cache Helpers

    private func cacheTexture(_ texture: any MTLTexture, for id: String) {
        if textureCache[id] == nil, textureLRUOrder.count >= maxTextureCacheSize {
            let evictID = textureLRUOrder.removeFirst()
            textureCache.removeValue(forKey: evictID)
            logger.debug("TextureLRU evict: \(evictID)")
        }
        textureLRUOrder.removeAll { $0 == id }
        textureCache[id] = texture
        textureLRUOrder.append(id)
    }

    private func touchLRU(_ id: String) {
        textureLRUOrder.removeAll { $0 == id }
        textureLRUOrder.append(id)
    }

    // MARK: - Private: Lookahead Cache Engine

    private func updateLookaheadCache(around index: Int) async {
        guard let result = fetchResult, result.count > 0 else { return }

        let totalCount = result.count
        let windowEnd  = min(index + dynamicLookaheadCount, totalCount - 1)

        var newWindow: Set<String>   = []
        var assetsToStart: [PHAsset] = []

        for i in index ... windowEnd {
            let asset = result.object(at: i)
            newWindow.insert(asset.localIdentifier)
            if !cachedIdentifiers.contains(asset.localIdentifier) {
                assetsToStart.append(asset)
            }
        }

        let toStop       = cachedIdentifiers.subtracting(newWindow)
        let assetsToStop = toStop.compactMap {
            PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
        }

        if !assetsToStop.isEmpty {
            cachingManager.stopCachingImages(
                for: assetsToStop,
                targetSize: lookaheadThumbnailSize,
                contentMode: .aspectFill,
                options: lookaheadRequestOptions
            )
        }
        if !assetsToStart.isEmpty {
            cachingManager.startCachingImages(
                for: assetsToStart,
                targetSize: lookaheadThumbnailSize,
                contentMode: .aspectFill,
                options: lookaheadRequestOptions
            )
            logger.debug(
                "Lookahead [\(index)…\(windowEnd)] velocity=\(self.userVelocity) lookahead=\(self.dynamicLookaheadCount)"
            )
        }
        cachedIdentifiers = newWindow

        // Pre-warm texture cache para N+1…N+3 (alta prioridad independiente de velocidad)
        let priorityEnd     = min(index + 3, totalCount - 1)
        let capturedSize    = dynamicTextureSize
        let capturedResult  = fetchResult

        if priorityEnd > index {
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }
                for i in (index + 1) ... priorityEnd {
                    guard let id = capturedResult?.object(at: i).localIdentifier else { continue }
                    _ = await self.loadTexture(identifier: id, targetSize: capturedSize)
                }
            }
        }
    }

    // MARK: - Private: PHFetchOptions

    private static let fetchOptions: PHFetchOptions = {
        let o = PHFetchOptions()
        o.sortDescriptors         = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        o.includeHiddenAssets     = false
        return o
    }()

    private var lookaheadThumbnailSize: CGSize {
        CGSize(width: 400 * screenScale, height: 600 * screenScale)
    }

    // MARK: - Private: State Helpers

    private func storeAssetContinuation(_ c: AsyncStream<PhotoAsset>.Continuation) {
        assetContinuation = c
    }
    private func storeAuthContinuation(_ c: AsyncStream<PhotoLibraryAuthState>.Continuation) {
        authContinuation = c
    }
    private func currentAuthState() async -> PhotoLibraryAuthState {
        PhotoLibraryAuthState(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }
}

// MARK: - Error Types

public enum PhotoLibraryError: Error, LocalizedError {
    case unauthorized(state: PhotoLibraryAuthState)
    case fetchFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let s): return "Acceso no autorizado. Estado: \(s)"
        case .fetchFailed(let e):  return "Fetch falló: \(e.localizedDescription)"
        }
    }
}

// MARK: - Factory Extensions

extension PhotoLibraryAuthState {
    init(from status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined:   self = .notDetermined
        case .authorized:      self = .authorized
        case .limited:         self = .limited
        case .denied:          self = .denied(reason: "El usuario denegó el acceso en Configuración.")
        case .restricted:      self = .restricted
        @unknown default:      self = .denied(reason: "Estado desconocido (\(status.rawValue))")
        }
    }
}

extension PhotoAsset {
    init(from asset: PHAsset, index: Int) {
        self.id             = asset.localIdentifier
        self.localIdentifier = asset.localIdentifier
        self.index          = index
        self.creationDate   = asset.creationDate
        self.duration       = asset.duration
        self.mediaType      = asset.mediaType
        self.pixelSize      = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
    }
}
