//
//  AtomicJournaler.swift
//  Purgatorio
//
//  Write-Ahead Log (WAL) binario para crash-safety de la cola de destrucción.
//
//  Problema:
//    SwiftData usa SQLite (WAL mode). Un OOM Kill durante el save() puede corromper
//    el checkpoint. Peor: si el kill ocurre DESPUÉS de que el shader haya confirmado
//    la destrucción visual pero ANTES del save(), el usuario ve la foto destruida
//    pero el ID no se persistió — estado incoherente.
//
//  Solución:
//    AtomicJournaler escribe un log binario ligero ANTES de que el shader arranque.
//    Si la app crashea en cualquier punto, la próxima ejecución encuentra IDs en el
//    log y los sincroniza con SwiftData de forma idempotente.
//
//  Formato binario:
//    [UInt32 byteCount][UTF-8 bytes del localIdentifier]\n
//    El newline es delimitador de recoveriibilidad legible en hexdumps.
//
//  Concurrencia:
//    Actor Swift: escritura serializada, lectura exclusiva.
//    La escritura usa FileHandle con synchronizeFile() para flush a disco.
//

import Foundation
import os.log

// MARK: - AtomicJournaler

public actor AtomicJournaler {

    // MARK: - Configuration

    /// Ruta del archivo de log binario.
    private let logURL: URL

    /// Ruta del archivo de persistencia del albumID de Google Photos.
    private let albumIDURL: URL

    /// Handle de escritura persistente (abierto durante toda la sesión).
    private var writeHandle: FileHandle?

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "AtomicJournaler")

    // MARK: - Init

    /// Crea el journaler con una ruta de log.
    /// Default: `Application Support/purgatorio_wal.bin`.
    public init(logURL: URL? = nil) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        if let logURL {
            self.logURL = logURL
        } else {
            self.logURL = appSupport.appendingPathComponent("purgatorio_wal.bin")
        }
        self.albumIDURL = appSupport.appendingPathComponent("purgatorio_album_id.txt")
    }

    // MARK: - Public API: Write (Fire-and-Forget en el hilo de la animación)

    /// Escribe un localIdentifier al WAL de forma no bloqueante.
    ///
    /// Diseñado para ser llamado con `Task.detached { await journaler.append(id) }`
    /// desde el hilo de la animación. La escritura es serializada por el actor,
    /// pero la `Task.detached` la desacopla del frame de renderizado.
    ///
    /// ## Formato de cada entrada
    /// ```
    /// [4 bytes: UInt32 little-endian = longitud UTF-8][N bytes: UTF-8 del ID][1 byte: 0x0A newline]
    /// ```
    public func append(_ localIdentifier: String) {
        let data = localIdentifier.data(using: .utf8)!
        var length = UInt32(data.count).littleEndian

        let handle = getOrCreateHandle()

        // Escribir longitud + payload + newline
        handle.write(Data(bytes: &length, count: 4))
        handle.write(data)
        handle.write(Data([0x0A]))  // \n

        // Flush a disco: sincrónico pero < 0.1ms en flash NAND moderno.
        handle.synchronizeFile()
    }

    /// Escribe múltiples IDs en una sola pasada (batch).
    /// Útil para el SurvivalTournamentView (grupo completo de perdedores).
    public func appendBatch(_ identifiers: [String]) {
        let handle = getOrCreateHandle()
        for id in identifiers {
            let data = id.data(using: .utf8)!
            var length = UInt32(data.count).littleEndian
            handle.write(Data(bytes: &length, count: 4))
            handle.write(data)
            handle.write(Data([0x0A]))
        }
        handle.synchronizeFile()
    }

    // MARK: - Public API: Recovery

    /// Lee todos los IDs pendientes del WAL.
    ///
    /// Llamar al inicio de la app para obtener IDs que no se sincronizaron
    /// con SwiftData antes de un crash/OOM kill.
    ///
    /// - Returns: Array de localIdentifiers. Vacío si no hay entradas pendientes.
    public func readPendingEntries() -> [String] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }

        guard let data = try? Data(contentsOf: logURL) else {
            logger.error("No se pudo leer el WAL: \(self.logURL.path)")
            return []
        }

        guard !data.isEmpty else { return [] }

        var entries: [String] = []
        var offset = 0

        while offset + 4 < data.count {
            // Leer longitud (UInt32 LE)
            let lengthData = data[offset ..< offset + 4]
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            offset += 4

            let end = offset + Int(length)
            guard end < data.count else { break }  // Entrada truncada → parar

            // Leer payload UTF-8
            let payload = data[offset ..< end]
            if let id = String(data: payload, encoding: .utf8) {
                entries.append(id)
            }
            offset = end + 1  // +1 por el newline
        }

        logger.info("WAL recovery: \(entries.count) entradas pendientes.")
        return entries
    }

    /// Sincroniza las entradas pendientes del WAL con PurgatorioQueueManager,
    /// luego vacía el log.
    ///
    /// Debe llamarse en el `@main` app init, ANTES de presentar la UI.
    ///
    /// ```swift
    /// @main struct PurgatorioApp: App {
    ///     init() {
    ///         Task {
    ///             await AtomicJournaler.shared.recoverAndSync(into: queueManager)
    ///         }
    ///     }
    /// }
    /// ```
    @MainActor
    public func recoverAndSync(into queue: PurgatorioQueueManager) async {
        let pending = readPendingEntries()
        guard !pending.isEmpty else { return }

        logger.warning("WAL contiene \(pending.count) IDs no sincronizados. Recuperando…")
        for id in pending {
            queue.mark(localIdentifier: id)
        }

        await clearLog()
        logger.info("WAL sincronizado con SwiftData y vaciado.")
    }

    /// Vacía el WAL (post-sync exitoso o al completar un batch de borrado).
    public func clearLog() {
        closeHandle()
        do {
            try Data().write(to: logURL, options: .atomic)
            logger.info("WAL vaciado.")
        } catch {
            logger.error("Error vaciando WAL: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API: Album ID Persistence

    /// Guarda el albumID de Google Photos para sobrevivir entre sesiones.
    /// Archivo sidecar ligero: solo una línea de texto.
    public func saveAlbumID(_ albumID: String) {
        do {
            try albumID.write(to: albumIDURL, atomically: true, encoding: .utf8)
            logger.info("AlbumID persistido en journaler: \(albumID)")
        } catch {
            logger.error("Error guardando albumID: \(error.localizedDescription)")
        }
    }

    /// Carga el albumID persistido.
    /// Retorna `nil` si no hay albumID guardado.
    public func loadAlbumID() -> String? {
        guard FileManager.default.fileExists(atPath: albumIDURL.path) else { return nil }
        let id = try? String(contentsOf: albumIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, !id.isEmpty {
            logger.info("AlbumID restaurado del journaler: \(id)")
            return id
        }
        return nil
    }

    /// Borra el albumID persistido.
    public func clearAlbumID() {
        try? FileManager.default.removeItem(at: albumIDURL)
    }

    // MARK: - Public: Singleton

    /// Instancia compartida con ruta default.
    public static let shared = AtomicJournaler()

    // MARK: - Private

    private func getOrCreateHandle() -> FileHandle {
        if let handle = writeHandle { return handle }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let handle = try! FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        writeHandle = handle
        return handle
    }

    private func closeHandle() {
        try? writeHandle?.close()
        writeHandle = nil
    }
}
