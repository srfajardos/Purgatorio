//
//  PurgatoryBatchUploader.swift
//  Purgatorio
//
//  Sube fotos marcadas al álbum "Purgatorio" de Google Photos en lotes de 50.
//
//  Pipeline:
//    1. Busca o crea el álbum "Purgatorio" en Google Photos.
//    2. Lee los IDs pendientes del AtomicJournaler y PurgatorioQueue.
//    3. Para cada asset: exporta los bytes originales vía PHAssetResource,
//       sube a Google Photos (POST /v1/uploads), obtiene un upload token.
//    4. Cada 50 tokens, ejecuta batchCreate para añadirlos al álbum.
//    5. Los IDs subidos exitosamente se registran en un set de "uploaded"
//       para no re-subir si la conexión se interrumpe.
//
//  Resiliencia:
//    - Exponential backoff con jitter para rate limiting (429/5xx).
//    - Checkpointing: los IDs subidos se persisten en UserDefaults.
//    - Reanudación: al reiniciar, compara WAL vs. checkpoint para saber
//      qué queda pendiente.
//

import Photos
import Foundation
import os.log

// MARK: - Upload State

public enum UploadState: Sendable, Equatable {
    case idle
    case preparingAlbum
    case uploading(completed: Int, total: Int)
    case completed(successCount: Int, failCount: Int)
    case failed(error: String)
}

// MARK: - Errors

public enum BatchUploadError: Error, LocalizedError {
    case notAuthenticated
    case albumCreationFailed(String)
    case assetExportFailed(String)
    case uploadFailed(statusCode: Int, body: String)
    case batchCreateFailed(statusCode: Int, body: String)
    case rateLimited(retryAfter: TimeInterval)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "No hay sesión activa de Google."
        case .albumCreationFailed(let m): return "Error creando álbum: \(m)"
        case .assetExportFailed(let id):  return "No se pudo exportar asset: \(id)"
        case .uploadFailed(let c, let b): return "Upload falló (HTTP \(c)): \(b)"
        case .batchCreateFailed(let c, let b): return "batchCreate falló (HTTP \(c)): \(b)"
        case .rateLimited(let t):     return "Rate limited. Retry en \(Int(t))s."
        case .cancelled:              return "Upload cancelado."
        }
    }
}

// MARK: - PurgatoryBatchUploader

/// Actor que gestiona el upload masivo de fotos al álbum "Purgatorio" de Google Photos.
///
/// ## Resiliencia
/// - **Exponential Backoff**: base 1s, factor ×2, máx 64s, con jitter aleatorio.
/// - **Checkpointing**: los IDs subidos se guardan en UserDefaults tras cada batch.
///   Si la app crashea o pierde conexión, al reiniciar solo sube los pendientes.
/// - **Reanudación**: `resumeUpload()` compara WAL/SwiftData vs. checkpoint.
///
/// ```swift
/// let uploader = PurgatoryBatchUploader(oauth: oauthService, queue: queueManager)
/// await uploader.startUpload()
/// for await state in await uploader.stateStream() { ... }
/// ```
public actor PurgatoryBatchUploader {

    // MARK: - Configuration
    private let batchSize:        Int = 50  // Límite de la API de Google Photos
    private let baseBackoff:      TimeInterval = 1.0
    private let maxBackoff:       TimeInterval = 64.0
    private let maxRetries:       Int = 6

    private let apiBaseURL = "https://photoslibrary.googleapis.com"

    // MARK: - Dependencies
    private let oauth:     GoogleOAuthService
    private let queue:     PurgatorioQueueManager
    private let journaler: AtomicJournaler

    // MARK: - Constants
    private let albumTitle = "Purgatorio: Seleccionadas para borrar"

    // MARK: - State
    public private(set) var albumID: String?
    private var uploadedIDs:   Set<String>
    private var currentState:  UploadState = .idle
    private var uploadTask:    Task<Void, Never>?

    // MARK: - Checkpointing
    private let checkpointKey  = "com.purgatorio.uploadedIDs"
    private let albumIDKey     = "com.purgatorio.googleAlbumID"

    // MARK: - Stream
    private var stateContinuation: AsyncStream<UploadState>.Continuation?

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "BatchUploader")

    // MARK: - Init

    public init(
        oauth:     GoogleOAuthService,
        queue:     PurgatorioQueueManager,
        journaler: AtomicJournaler = .shared
    ) {
        self.oauth     = oauth
        self.queue     = queue
        self.journaler = journaler

        // Restaurar checkpoint de IDs ya subidos
        let saved = UserDefaults.standard.stringArray(forKey: checkpointKey) ?? []
        self.uploadedIDs = Set(saved)

        // Restaurar albumID persistido de sesiones anteriores
        self.albumID = UserDefaults.standard.string(forKey: albumIDKey)
    }

    // MARK: - Public API

    /// Stream de estados del uploader.
    public func stateStream() -> AsyncStream<UploadState> {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in 
                guard let self = self else { return }
                await self.storeStateContinuation(continuation) 
            }
        }
    }

    /// Inicia el upload de todas las fotos pendientes.
    ///
    /// Flujo:
    /// 1. Busca/crea álbum "Purgatorio".
    /// 2. Calcula pendientes = (WAL ∪ SwiftData) - checkpoint.
    /// 3. Sube en batches de 50 con exponential backoff.
    public func startUpload() {
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.performUpload()
            } catch is CancellationError {
                await self.updateState(.failed(error: "Cancelado"))
            } catch {
                await self.updateState(.failed(error: error.localizedDescription))
            }
        }
    }

    /// Cancela el upload en curso.
    public func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
        updateState(.idle)
    }

    /// Limpia el checkpoint de IDs subidos.
    /// Llamar después de confirmar el borrado exitoso en el dispositivo.
    public func clearCheckpoint() {
        uploadedIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: checkpointKey)
        logger.info("Checkpoint limpiado.")
    }

    /// Número de IDs pendientes de subir.
    public func pendingCount() async -> Int {
        let allIDs = await collectPendingIDs()
        return allIDs.count
    }

    // MARK: - Private: Core Upload Flow

    private func performUpload() async throws {
        let token = try await oauth.validAccessToken()

        // 1. Álbum
        updateState(.preparingAlbum)
        let albumID = try await findOrCreateAlbum(token: token)
        self.albumID = albumID
        logger.info("Álbum listo: \(albumID)")

        // 2. Pendientes
        let pendingIDs = await collectPendingIDs()
        guard !pendingIDs.isEmpty else {
            updateState(.completed(successCount: 0, failCount: 0))
            return
        }
        logger.info("Pendientes: \(pendingIDs.count) assets.")

        // 3. Upload en batches
        var successCount = 0
        var failCount    = 0
        let batches      = pendingIDs.chunked(into: batchSize)

        for (batchIdx, batch) in batches.enumerated() {
            try Task.checkCancellation()

            var uploadTokens: [(localID: String, uploadToken: String)] = []

            // 3a. Subir bytes de cada asset
            for id in batch {
                try Task.checkCancellation()
                updateState(.uploading(
                    completed: successCount + failCount,
                    total: pendingIDs.count
                ))

                do {
                    let freshToken = try await oauth.validAccessToken()
                    let upToken = try await uploadAssetBytes(localIdentifier: id, accessToken: freshToken)
                    uploadTokens.append((localID: id, uploadToken: upToken))
                } catch {
                    logger.warning("Upload falló para \(id): \(error.localizedDescription)")
                    failCount += 1
                }
            }

            // 3b. batchCreate para añadir al álbum
            if !uploadTokens.isEmpty {
                do {
                    let freshToken = try await oauth.validAccessToken()
                    try await batchCreateMediaItems(
                        uploadTokens: uploadTokens.map(\.uploadToken),
                        albumID: albumID,
                        accessToken: freshToken
                    )
                    // Marcar como subidos
                    for (localID, _) in uploadTokens {
                        uploadedIDs.insert(localID)
                    }
                    successCount += uploadTokens.count
                    saveCheckpoint()
                } catch {
                    logger.error("batchCreate falló batch \(batchIdx): \(error.localizedDescription)")
                    failCount += uploadTokens.count
                }
            }
        }

        updateState(.completed(successCount: successCount, failCount: failCount))
        logger.info("Upload terminado: \(successCount) OK, \(failCount) fallidos.")
    }

    // MARK: - Private: Pending IDs (WAL ∪ SwiftData) − Checkpoint

    private func collectPendingIDs() async -> [String] {
        let walIDs      = await journaler.readPendingEntries()
        let swiftDataIDs = await MainActor.run { queue.allMarkedIdentifiers }
        let allIDs      = Set(walIDs).union(Set(swiftDataIDs))
        return Array(allIDs.subtracting(uploadedIDs))
    }

    // MARK: - Private: Album Management

    private func findOrCreateAlbum(token: String) async throws -> String {
        // 1. Si tenemos un albumID persistido, verificar que siga existiendo
        if let cached = albumID {
            if let _ = try? await findAlbumByID(cached, token: token) {
                return cached
            }
            // El álbum fue borrado externamente → buscar por nombre o crear
            logger.warning("AlbumID persistido no existe. Buscando por nombre…")
        }

        // 2. Buscar por nombre
        if let id = try await findAlbum(named: albumTitle, token: token) {
            persistAlbumID(id)
            return id
        }

        // 3. Crear nuevo
        let id = try await createAlbum(named: albumTitle, token: token)
        persistAlbumID(id)
        return id
    }

    /// Verifica que un álbum con ID dado sigue existiendo.
    private func findAlbumByID(_ albumID: String, token: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/v1/albums/\(albumID)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func persistAlbumID(_ id: String) {
        albumID = id
        UserDefaults.standard.set(id, forKey: albumIDKey)
        logger.info("AlbumID persistido: \(id)")
    }

    private func findAlbum(named title: String, token: String) async throws -> String? {
        var nextPageToken: String? = nil

        repeat {
            var urlString = "\(apiBaseURL)/v1/albums?pageSize=50"
            if let npt = nextPageToken {
                urlString += "&pageToken=\(npt)"
            }
            var request = URLRequest(url: URL(string: urlString)!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await performRequestWithBackoff(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let albums = json?["albums"] as? [[String: Any]] {
                for album in albums {
                    if let t = album["title"] as? String, t == title,
                       let id = album["id"] as? String {
                        return id
                    }
                }
            }
            nextPageToken = json?["nextPageToken"] as? String
        } while nextPageToken != nil

        return nil
    }

    private func createAlbum(named title: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/v1/albums")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "album": ["title": title]
        ])

        let (data, response) = try await performRequestWithBackoff(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BatchUploadError.albumCreationFailed(
                String(data: data, encoding: .utf8) ?? "unknown"
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String else {
            throw BatchUploadError.albumCreationFailed("Respuesta sin ID de álbum.")
        }
        return id
    }

    // MARK: - Private: Asset Upload (2-step: bytes → batchCreate)

    /// Paso 1: Sube los bytes raw del asset a Google Photos.
    /// Retorna un upload token que se usa en batchCreate.
    private func uploadAssetBytes(localIdentifier: String, accessToken: String) async throws -> String {
        // Obtener los bytes originales del asset vía PHAssetResource
        let assetData = try await exportAssetData(localIdentifier: localIdentifier)

        var request = URLRequest(url: URL(string: "\(apiBaseURL)/v1/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(localIdentifier, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        request.httpBody = assetData

        let (data, response) = try await performRequestWithBackoff(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let uploadToken = String(data: data, encoding: .utf8), !uploadToken.isEmpty
        else {
            throw BatchUploadError.uploadFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return uploadToken
    }

    /// Paso 2: Asocia upload tokens con el álbum.
    private func batchCreateMediaItems(
        uploadTokens: [String],
        albumID: String,
        accessToken: String
    ) async throws {
        let items = uploadTokens.map { token -> [String: Any] in
            ["simpleMediaItem": ["uploadToken": token]]
        }

        let body: [String: Any] = [
            "albumId": albumID,
            "newMediaItems": items
        ]

        var request = URLRequest(url: URL(string: "\(apiBaseURL)/v1/mediaItems:batchCreate")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequestWithBackoff(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BatchUploadError.batchCreateFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        logger.info("batchCreate OK: \(uploadTokens.count) items añadidos al álbum.")
    }

    // MARK: - Private: PHAsset Data Export

    private func exportAssetData(localIdentifier: String) async throws -> Data {
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier], options: nil
        ).firstObject else {
            throw BatchUploadError.assetExportFailed(localIdentifier)
        }

        guard let resource = PHAssetResource.assetResources(for: phAsset)
            .first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
        else {
            throw BatchUploadError.assetExportFailed(localIdentifier)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(
                for: resource, options: options
            ) { chunk in
                buffer.append(chunk)
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: BatchUploadError.assetExportFailed(
                        "\(localIdentifier): \(error.localizedDescription)"
                    ))
                } else {
                    continuation.resume(returning: buffer)
                }
            }
        }
    }

    // MARK: - Private: Exponential Backoff

    /// Ejecuta una URLRequest con retry automático y exponential backoff con jitter.
    ///
    /// Retries en: 429 (rate limited), 500, 502, 503, 504.
    private func performRequestWithBackoff(
        _ request: URLRequest
    ) async throws -> (Data, URLResponse) {
        var attempt: Int = 0
        var delay   = baseBackoff

        while true {
            try Task.checkCancellation()

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return (data, response)
            }

            let retryable = [429, 500, 502, 503, 504]
            if retryable.contains(http.statusCode) && attempt < maxRetries {
                attempt += 1

                // Respetar Retry-After si presente
                if let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = TimeInterval(retryAfter) {
                    delay = seconds
                }

                let jitter = Double.random(in: 0...0.5)
                let wait   = min(delay + jitter, maxBackoff)
                logger.warning(
                    "HTTP \(http.statusCode) — retry \(attempt)/\(self.maxRetries) en \(wait, format: .fixed(precision: 1))s"
                )
                try await Task.sleep(for: .seconds(wait))
                delay *= 2  // Exponential
                continue
            }

            return (data, response)
        }
    }

    // MARK: - Private: Checkpoint Persistence

    private func saveCheckpoint() {
        UserDefaults.standard.set(Array(uploadedIDs), forKey: checkpointKey)
    }

    // MARK: - Private: State Management

    private func updateState(_ state: UploadState) {
        currentState = state
        stateContinuation?.yield(state)
    }

    private func storeStateContinuation(_ c: AsyncStream<UploadState>.Continuation) {
        stateContinuation = c
    }
}

// MARK: - Array Chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
