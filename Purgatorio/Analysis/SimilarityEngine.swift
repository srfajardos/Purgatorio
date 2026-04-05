//
//  SimilarityEngine.swift
//  Purgatorio
//
//  Motor de detección de fotos cuasi-idénticas. Dos fases de análisis:
//
//  Fase 1 — pHash (Perceptual Hashing)
//  ─────────────────────────────────────
//  Rápido y sin red. Detecta duplicados exactos y disparos en ráfaga.
//  Algoritmo: DCT-II 2D sobre miniatura 32×32 en escala de grises → hash UInt64.
//  Comparación: distancia Hamming ≤ umbral configurable.
//
//  Fase 2 — Vision Feature Print
//  ─────────────────────────────────────
//  Más lento. Detecta similitud semántica: misma escena, mismo sujeto, misma
//  ubicación fotográfica aunque la composición difiera ligeramente.
//  Usa VNGenerateImageFeaturePrintRequest (red neuronal de Apple, on-device).
//  Comparación: VNFeaturePrintObservation.computeDistance(_:to:) ≤ umbral.
//
//  Estrategia de clustering: Union-Find con path compression + union by rank.
//  Solo los assets que NO quedaron agrupados en pHash pasan a Fase 2,
//  minimizando el tiempo total de análisis.
//

import Photos
import Vision
import UIKit
import os.log

// MARK: - Domain Types

/// Grupo de assets fotográficos que el motor consideró cuasi-idénticos.
public struct SimilarityGroup: Identifiable, Sendable {
    public let id: UUID
    /// `localIdentifier`s de los assets agrupados. Siempre ≥ 2 elementos.
    public let assetIDs: [String]
    /// Puntuación de similitud del grupo (distancia máxima interna).
    /// Closer to 0.0 = más idénticos. Útil para ordenar grupos por "urgencia de revisión".
    public let score: Float
    /// Método que detectó este grupo.
    public let detectionMethod: DetectionMethod

    public enum DetectionMethod: String, Sendable {
        /// Duplicado exacto o casi-exacto detectado por pHash (ráfaga, screenshot duplicado, etc.)
        case perceptualHash    = "pHash"
        /// Similitud semántica detectada por Vision (misma escena con variación ligera).
        case visionFeaturePrint = "Vision"
    }
}

/// Errores del motor de similitud.
public enum SimilarityError: Error, Sendable, LocalizedError {
    case noAssetsProvided
    case imageLoadFailed(assetID: String)
    case pixelExtractionFailed(assetID: String)
    case featurePrintFailed(assetID: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .noAssetsProvided:
            return "No se proporcionaron assets para analizar."
        case .imageLoadFailed(let id):
            return "No se pudo cargar imagen para análisis: \(id)"
        case .pixelExtractionFailed(let id):
            return "No se pudo extraer matriz de píxeles: \(id)"
        case .featurePrintFailed(let id, let err):
            return "Vision Feature Print falló para \(id): \(err.localizedDescription)"
        }
    }
}

// MARK: - SimilarityEngine

/// Actor de análisis de similitud fotográfica para Purgatorio.
///
/// Diseñado para galerías grandes (1k-50k fotos): la Fase 1 (pHash) es O(n²) en
/// comparaciones pero lineal en carga de imágenes. La Fase 2 (Vision) solo procesa
/// los assets que no quedaron agrupados en pHash, reduciendo la carga computacional
/// en galerías con muchas ráfagas.
///
/// ## Uso Típico
/// ```swift
/// let engine = SimilarityEngine()
/// let groups = try await engine.findSimilarGroups(in: assets) { progress in
///     print("Análisis: \(Int(progress * 100))%")
/// }
/// // groups contiene arrays de IDs para presentar en SurvivalTournamentView
/// ```
public actor SimilarityEngine {

    // MARK: - Configuration

    /// Distancia Hamming máxima para considerar dos pHash duplicados.
    /// - `0`: idénticos al píxel
    /// - `≤ 5`: duplicados exactos o con compresión diferente
    /// - `≤ 10`: mismo disparo con variación mínima (crop, brillo)
    /// - `≤ 15`: cuasi-duplicados obvios (burst mode, screenshots similares)
    public let pHashThreshold: Int

    /// Distancia de Vision Feature Print para similitud semántica.
    /// Rango observable en la práctica: 0.0 (idéntico) … ~0.8 (muy diferente).
    /// Default 0.15 es conservador; aumentar a 0.25 para agrupar variaciones más amplias.
    public let visionDistanceThreshold: Float

    // MARK: - Constants

    /// Tamaño de análisis para pHash. DCT necesita potencia de 2; 32 es el estándar pHash clásico.
    private static let pHashImageSize = 32
    /// Tamaño del bloque DCT de baja frecuencia (top-left). 8×8 = 64 bits de hash.
    private static let dctSubSize = 8
    /// Tamaño de imagen para Vision. 224×224 = input size de FeaturePrint model.
    private static let visionImageSize = CGSize(width: 224, height: 224)

    // MARK: - Caches (keyed by localIdentifier)

    private var pHashCache: [String: UInt64] = [:]
    private var featurePrintCache: [String: VNFeaturePrintObservation] = [:]

    // MARK: - Internal

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "SimilarityEngine")

    private let analysisRequestOptions: PHImageRequestOptions = {
        let opt = PHImageRequestOptions()
        opt.deliveryMode    = .fastFormat   // Velocidad prioritaria en análisis masivo
        opt.resizeMode      = .fast
        opt.isNetworkAccessAllowed = false  // Sin red → solo fotos locales en análisis batch
        opt.isSynchronous   = false
        return opt
    }()

    // MARK: - Initializer

    /// - Parameters:
    ///   - pHashThreshold: Distancia Hamming máxima para agrupar. Default: 8.
    ///   - visionDistanceThreshold: Distancia Vision máxima para agrupar. Default: 0.15.
    public init(pHashThreshold: Int = 8, visionDistanceThreshold: Float = 0.15) {
        self.pHashThreshold           = max(0, pHashThreshold)
        self.visionDistanceThreshold  = max(0, visionDistanceThreshold)
    }

    // MARK: - Public API

    /// Analiza un array de assets en busca de fotos cuasi-idénticas.
    ///
    /// Retorna solo grupos con ≥ 2 assets. Assets únicos son ignorados.
    ///
    /// - Parameters:
    ///   - assets: Lista de `PhotoAsset` a analizar.
    ///   - onProgress: Closure llamado en el caller's actor con progreso 0.0 … 1.0.
    ///                 Llamado desde el TaskGroup interno (puede ser en cualquier thread).
    /// - Returns: Array de `SimilarityGroup` ordenados por `score` ascendente (más idénticos primero).
    /// - Throws: `SimilarityError.noAssetsProvided` si el array está vacío.
    public func findSimilarGroups(
        in assets: [PhotoAsset],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SimilarityGroup] {

        guard !assets.isEmpty else { throw SimilarityError.noAssetsProvided }

        logger.info("SimilarityEngine: inicio análisis de \(assets.count) assets.")
        let totalDouble = Double(assets.count)

        // ── Fase 1: pHash ─────────────────────────────────────────────────────
        logger.info("Fase 1 pHash: cargando \(assets.count) miniaturas 32×32…")

        var hashes: [String: UInt64] = [:]
        var phase1Done = 0.0

        try await withThrowingTaskGroup(of: (String, UInt64)?.self) { group in
            for asset in assets {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    // computePHash puede fallar si PHImageManager no entrega datos.
                    // Usamos try? para no abortar el análisis completo por un asset fallido.
                    if let hash = try? await self.computePHash(for: asset) {
                        return (asset.localIdentifier, hash)
                    }
                    return nil
                }
            }
            for try await result in group {
                if let (id, hash) = result {
                    hashes[id] = hash
                }
                phase1Done += 1
                onProgress?(phase1Done / (totalDouble * 2.0)) // Fase 1 = 0%…50%
            }
        }

        let pHashGroups = clusterByPHash(assets: assets, hashes: hashes)
        logger.info("Fase 1 completada: \(pHashGroups.count) grupos pHash, \(hashes.count) hashes calculados.")

        // ── Fase 2: Vision Feature Print (solo assets no agrupados en pHash) ──
        let groupedInPhase1 = Set(pHashGroups.flatMap(\.assetIDs))
        let ungroupedAssets  = assets.filter { !groupedInPhase1.contains($0.localIdentifier) }

        logger.info("Fase 2 Vision: procesando \(ungroupedAssets.count) assets no agrupados en pHash…")

        var featurePrints: [String: VNFeaturePrintObservation] = [:]
        var phase2Done = 0.0

        if !ungroupedAssets.isEmpty {
            // Vision requests son CPU-intensivos: usamos TaskGroup con concurrencia
            // limitada a ProcessInfo.processInfo.activeProcessorCount para no
            // saturar los núcleos de eficiencia en dispositivos con pocos núcleos P.
            let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount)
            var semaphoreCount = 0

            try await withThrowingTaskGroup(of: (String, VNFeaturePrintObservation)?.self) { group in
                for asset in ungroupedAssets {
                    // Límite de concurrencia: espera si hay demasiadas tasks activas.
                    if semaphoreCount >= maxConcurrency {
                        if let result = try await group.next() {
                            if let (id, print) = result {
                                featurePrints[id] = print
                            }
                            phase2Done += 1
                            onProgress?(0.5 + phase2Done / (totalDouble * 2.0))
                            semaphoreCount -= 1
                        }
                    }
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        if let fp = try? await self.computeFeaturePrint(for: asset) {
                            return (asset.localIdentifier, fp)
                        }
                        return nil
                    }
                    semaphoreCount += 1
                }
                // Drenar tasks restantes
                for try await result in group {
                    if let (id, print) = result {
                        featurePrints[id] = print
                    }
                    phase2Done += 1
                    onProgress?(0.5 + phase2Done / (totalDouble * 2.0))
                }
            }
        }

        let visionGroups = clusterByVision(assets: ungroupedAssets, prints: featurePrints)
        logger.info("Fase 2 completada: \(visionGroups.count) grupos Vision.")

        onProgress?(1.0)

        let allGroups = (pHashGroups + visionGroups)
            .sorted { $0.score < $1.score }  // Más idénticos primero (mayor urgencia de destrucción)

        logger.info("Análisis terminado: \(allGroups.count) grupos totales.")
        return allGroups
    }

    // MARK: - Public: pHash

    /// Calcula el Perceptual Hash de un asset. Cachea el resultado.
    ///
    /// ## Algoritmo (pHash clásico)
    /// 1. Carga imagen a 32×32 en escala de grises via `PHImageManager`.
    /// 2. Aplica DCT-II 2D separable (filas → columnas).
    /// 3. Extrae coeficientes de baja frecuencia: sub-matriz top-left 8×8 (64 valores).
    /// 4. Calcula la media aritmética de los 64 coeficientes.
    /// 5. Genera hash de 64 bits: bit[i] = 1 si coef[i] > media, 0 si no.
    ///
    /// La DCT convierte la imagen al dominio de frecuencias; la sub-matriz top-left
    /// contiene las frecuencias bajas (estructura global), ignorando ruido de compresión.
    public func computePHash(for asset: PhotoAsset) async throws -> UInt64 {
        if let cached = pHashCache[asset.localIdentifier] { return cached }

        guard let cgImage = await loadSmallCGImage(
            localIdentifier: asset.localIdentifier,
            targetSize: CGSize(width: Self.pHashImageSize, height: Self.pHashImageSize)
        ) else {
            throw SimilarityError.imageLoadFailed(assetID: asset.localIdentifier)
        }

        guard let matrix = Self.grayscaleMatrix(from: cgImage, size: Self.pHashImageSize) else {
            throw SimilarityError.pixelExtractionFailed(assetID: asset.localIdentifier)
        }

        let dct  = Self.dct2D(matrix)
        let hash = Self.buildHash(from: dct, subSize: Self.dctSubSize)

        pHashCache[asset.localIdentifier] = hash
        return hash
    }

    /// Calcula la distancia Hamming entre dos pHashes.
    /// `nonisolated` para poder llamarla sin saltar al executor del actor.
    public nonisolated func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - Public: Vision Feature Print

    /// Calcula el Vision Feature Print de un asset. Cachea el resultado.
    ///
    /// `VNGenerateImageFeaturePrintRequest` extrae un vector de embedding que codifica
    /// el contenido visual semántico using la red neuronal on-device de Apple.
    /// Dos fotos de la misma escena tendrán embeddings con distancia pequeña.
    ///
    /// El request corre en `Task.detached(priority: .userInitiated)` para no bloquear
    /// el executor del actor durante la inferencia de la red neuronal.
    public func computeFeaturePrint(for asset: PhotoAsset) async throws -> VNFeaturePrintObservation {
        if let cached = featurePrintCache[asset.localIdentifier] { return cached }

        guard let cgImage = await loadSmallCGImage(
            localIdentifier: asset.localIdentifier,
            targetSize: Self.visionImageSize
        ) else {
            throw SimilarityError.imageLoadFailed(assetID: asset.localIdentifier)
        }

        // Detach: la inferencia de Vision puede bloquear el thread hasta ~50ms por imagen.
        // Correr en el executor del actor bloquearía todos los demás awaits del sistema.
        let observation = try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNGenerateImageFeaturePrintRequest()
            request.imageCropAndScaleOption = .scaleFit
            do {
                try handler.perform([request])
            } catch {
                throw SimilarityError.featurePrintFailed(assetID: "unknown", underlying: error)
            }
            guard let obs = request.results?.first as? VNFeaturePrintObservation else {
                throw SimilarityError.featurePrintFailed(
                    assetID: "unknown",
                    underlying: NSError(domain: "SimilarityEngine", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "No VNFeaturePrintObservation producido."])
                )
            }
            return obs
        }.value

        featurePrintCache[asset.localIdentifier] = observation
        return observation
    }

    // MARK: - Public: Cache Management

    /// Purga caches de hashes y feature prints. Útil al cambiar de sesión de análisis.
    /// - Parameter keepingIDs: IDs a conservar (e.g., los del par actual en el torneo).
    public func clearCache(keepingIDs ids: Set<String> = []) {
        let beforeCount = pHashCache.count + featurePrintCache.count
        pHashCache        = pHashCache.filter { ids.contains($0.key) }
        featurePrintCache = featurePrintCache.filter { ids.contains($0.key) }
        logger.debug("Cache purgado. Antes: \(beforeCount) entradas. Conservadas: \(ids.count).")
    }

    // MARK: - Private: Image Loading

    /// Carga un CGImage pequeño via PHImageManager para análisis.
    /// Retorna `nil` si el asset no está disponible localmente.
    private func loadSmallCGImage(localIdentifier: String, targetSize: CGSize) async -> CGImage? {
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier], options: nil
        ).firstObject else {
            logger.warning("Asset no encontrado en PhotoKit: \(localIdentifier)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            var didResume = false
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: analysisRequestOptions
            ) { image, info in
                // PHImageManager puede llamar el handler varias veces (degraded → final).
                // Solo respondemos a la entrega final (no degradada).
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    // MARK: - Private: pHash Internals

    /// Rasteriza un `CGImage` a una matriz `[[Float]]` de luminancia.
    /// Usa un `CGContext` en espacio DeviceGray (8 bpc) para máxima eficiencia.
    private static func grayscaleMatrix(from cgImage: CGImage, size: Int) -> [[Float]]? {
        var rawPixels = [UInt8](repeating: 0, count: size * size)
        guard let ctx = CGContext(
            data: &rawPixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Dibuja escalando al tamaño objetivo (el ImageManager ya hizo el resize;
        // este draw es final y solo ajusta si hay diferencia residual).
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        return (0 ..< size).map { row in
            (0 ..< size).map { col in Float(rawPixels[row * size + col]) }
        }
    }

    /// DCT-II unidimensional.
    ///
    /// Fórmula: `X[k] = Σ x[n] · cos(π·k·(2n+1) / 2N)` para k = 0…N-1.
    /// Complejidad: O(N²). Para N=32 → 1024 ops por vector. Negligible.
    private static func dct1D(_ v: [Float]) -> [Float] {
        let n = v.count
        let piOverTwoN = Float.pi / Float(2 * n)
        return (0 ..< n).map { k in
            v.enumerated().reduce(Float(0)) { acc, pair in
                acc + pair.element * cos(Float(k) * Float(2 * pair.offset + 1) * piOverTwoN)
            }
        }
    }

    /// DCT-II bidimensional separable.
    /// Aplica DCT-II en filas y luego en columnas del resultado intermedio.
    private static func dct2D(_ matrix: [[Float]]) -> [[Float]] {
        let n = matrix.count
        // Paso 1: DCT por filas
        let rowDCT = matrix.map { dct1D($0) }
        // Paso 2: DCT por columnas sobre el resultado de paso 1
        var result = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for col in 0 ..< n {
            let column = rowDCT.map { $0[col] }
            let colDCT = dct1D(column)
            for row in 0 ..< n {
                result[row][col] = colDCT[row]
            }
        }
        return result
    }

    /// Genera el hash de 64 bits desde los coeficientes de baja frecuencia.
    ///
    /// Toma la sub-matriz `[0..<subSize][0..<subSize]` del resultado DCT,
    /// calcula la media aritmética y asigna bit[i] = (coef[i] > media).
    private static func buildHash(from dct: [[Float]], subSize: Int) -> UInt64 {
        // Extrae los subSize² coeficientes de baja frecuencia
        var coefficients = [Float]()
        coefficients.reserveCapacity(subSize * subSize)
        for r in 0 ..< subSize {
            for c in 0 ..< subSize {
                coefficients.append(dct[r][c])
            }
        }
        let mean = coefficients.reduce(Float(0), +) / Float(coefficients.count)
        // Genera hash: bit i = 1 si coef[i] > media
        return coefficients.enumerated().reduce(UInt64(0)) { hash, pair in
            pair.element > mean ? hash | (UInt64(1) << pair.offset) : hash
        }
    }

    // MARK: - Private: Clustering

    /// Agrupa assets usando distancia Hamming entre pHashes.
    /// Complejidad: O(n²) en comparaciones. Para n=1000 → ~500k comps (< 10ms en A-series).
    private func clusterByPHash(assets: [PhotoAsset], hashes: [String: UInt64]) -> [SimilarityGroup] {
        let ids = assets.map(\.localIdentifier)
        var uf  = UnionFind(count: ids.count)
        var groupMaxDistance: [Int: Float] = [:]

        for i in 0 ..< ids.count {
            for j in (i + 1) ..< ids.count {
                guard let ha = hashes[ids[i]], let hb = hashes[ids[j]] else { continue }
                let dist = hammingDistance(ha, hb)
                if dist <= pHashThreshold {
                    let ri = uf.find(i)
                    groupMaxDistance[ri] = max(groupMaxDistance[ri] ?? 0, Float(dist))
                    uf.union(i, j)
                }
            }
        }
        return buildGroups(ids: ids, uf: &uf, groupMaxDistance: groupMaxDistance, method: .perceptualHash)
    }

    /// Agrupa assets usando distancia de VNFeaturePrintObservation.
    /// Complejidad: O(n²). Para n grande y sets no agrupados en pHash, considerar ANN.
    private func clusterByVision(
        assets: [PhotoAsset],
        prints: [String: VNFeaturePrintObservation]
    ) -> [SimilarityGroup] {
        let ids = assets.map(\.localIdentifier)
        var uf  = UnionFind(count: ids.count)
        var groupMaxDistance: [Int: Float] = [:]

        for i in 0 ..< ids.count {
            for j in (i + 1) ..< ids.count {
                guard let pa = prints[ids[i]], let pb = prints[ids[j]] else { continue }
                var dist: Float = 0
                guard (try? pa.computeDistance(&dist, to: pb)) != nil else { continue }
                if dist <= visionDistanceThreshold {
                    let ri = uf.find(i)
                    groupMaxDistance[ri] = max(groupMaxDistance[ri] ?? 0, dist)
                    uf.union(i, j)
                }
            }
        }
        return buildGroups(ids: ids, uf: &uf, groupMaxDistance: groupMaxDistance, method: .visionFeaturePrint)
    }

    /// Convierte el estado de Union-Find en `[SimilarityGroup]`.
    private func buildGroups(
        ids: [String],
        uf: inout UnionFind,
        groupMaxDistance: [Int: Float],
        method: SimilarityGroup.DetectionMethod
    ) -> [SimilarityGroup] {
        var buckets: [Int: [String]] = [:]
        for i in 0 ..< ids.count {
            let root = uf.find(i)
            buckets[root, default: []].append(ids[i])
        }
        return buckets.compactMap { root, members in
            guard members.count >= 2 else { return nil }
            return SimilarityGroup(
                id: UUID(),
                assetIDs: members,
                score: groupMaxDistance[root] ?? 0,
                detectionMethod: method
            )
        }
    }
}

// MARK: - Metal Texture Bridge (SimilarityEngine → PhotoProviderActor)

extension SimilarityEngine {

    /// Prepara un array de `TexturePair` GPU-residentes a partir de los grupos detectados.
    ///
    /// Convierte cada `SimilarityGroup` en un doble buffer de texturas Metal listo para
    /// el renderizador de `StroboscopicA_B_View` y `SurvivalTournamentView`.
    ///
    /// ## Flujo sin UIImage en la ruta caliente
    /// ```
    /// SimilarityGroup.assetIDs[0,1]
    ///   ↓
    /// PhotoProviderActor.fetchTexturePair(idA:idB:)  ← PHImageManager(.fastFormat) + MTKTextureLoader
    ///   ↓
    /// TexturePair { textureA, textureB }             ← GPU-resident, .shaderRead
    ///   ↓
    /// StroboscopicA_B_View / Metal shader             ← 0 latencia I/O, 120fps
    /// ```
    ///
    /// - Parameters:
    ///   - groups: Resultado de `findSimilarGroups(in:)`.
    ///   - provider: `PhotoProviderActor` que gestiona las texturas y el cache LRU.
    ///   - thermalGovernor: Válvula de presión. Si `isMLEnabled == false`, se limita a
    ///                      los primeros 10 grupos para no saturar la GPU en estado crítico.
    /// - Returns: Array de `TexturePair` ordenados por posición de grupo (mismo orden que `groups`).
    public func prepareTournamentTextures(
        from groups: [SimilarityGroup],
        using provider: PhotoProviderActor,
        thermalGovernor: ThermalGovernor = .shared
    ) async -> [TexturePair] {

        // Respetar el presupuesto térmico: en estado crítico limitamos el número de grupos
        // para evitar saturar el bus de memoria GPU durante la carga masiva de texturas.
        let effectiveGroups: [SimilarityGroup]
        switch thermalGovernor.textureBudget {
        case .full:    effectiveGroups = groups
        case .reduced: effectiveGroups = Array(groups.prefix(50))
        case .minimal: effectiveGroups = Array(groups.prefix(10))
        }

        // Carga paralela de TexturePairs con TaskGroup.
        // Cada par suspende en fetchTexturePair (double buffer concurrente).
        return await withTaskGroup(of: (Int, TexturePair).self) { group in
            for (index, similarityGroup) in effectiveGroups.enumerated() {
                guard similarityGroup.assetIDs.count >= 2 else { continue }
                let idA = similarityGroup.assetIDs[0]
                let idB = similarityGroup.assetIDs[1]

                group.addTask {
                    let pair = await provider.fetchTexturePair(idA: idA, idB: idB)
                    return (index, pair)
                }
            }

            // Reensamblar en orden original (TaskGroup no garantiza orden de llegada)
            var indexed: [(Int, TexturePair)] = []
            for await result in group { indexed.append(result) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Prepara un único `TexturePair` para un grupo concreto.
    ///
    /// Atajo conveniente para cargar el par del torneo actual
    /// sin iterar sobre toda la lista de grupos.
    public func prepareTexturePair(
        for group: SimilarityGroup,
        using provider: PhotoProviderActor
    ) async -> TexturePair? {
        guard group.assetIDs.count >= 2 else { return nil }
        return await provider.fetchTexturePair(idA: group.assetIDs[0], idB: group.assetIDs[1])
    }
}

// MARK: - Union-Find (Disjoint Set Union con Path Compression + Union by Rank)

/// Implementación clásica de Union-Find para clustering eficiente.
/// Complejidad amortizada casi-lineal: O(n · α(n)) donde α es la inversa de Ackermann.
private struct UnionFind {
    var parent: [Int]
    var rank:   [Int]  // Union by rank minimiza la profundidad del árbol

    init(count: Int) {
        parent = Array(0 ..< count)
        rank   = [Int](repeating: 0, count: count)
    }

    /// Path compression: aplana el árbol en cada find.
    mutating func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x])  // Recursión con compresión de camino
        }
        return parent[x]
    }

    /// Union by rank: el árbol de menor rank se convierte en hijo del mayor.
    mutating func union(_ x: Int, _ y: Int) {
        let px = find(x), py = find(y)
        guard px != py else { return }
        if rank[px] < rank[py] {
            parent[px] = py
        } else if rank[px] > rank[py] {
            parent[py] = px
        } else {
            parent[py] = px
            rank[px] += 1
        }
    }
}
