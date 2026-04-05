//
//  PurgatorioQueue.swift
//  Purgatorio
//
//  Persistencia inmediata de la cola de destrucción fotográfica.
//
//  Problema resuelto:
//  iOS puede matar la app por OOM (Out Of Memory) durante el análisis de galerías
//  grandes sin emitir ninguna notificación al proceso. Si el mapeo de fotos marcadas
//  viviera solo en memoria, el usuario perdería todo su trabajo al reiniciar.
//
//  Solución:
//  Cada vez que un asset se marca para borrar, se persiste INMEDIATAMENTE en
//  SwiftData (SQLite en disco). Al relanzar la app, PurgatorioQueueManager restaura
//  el estado sin pérdida de datos.
//
//  Modelo:
//    MarkedAsset — un registro por foto marcada, con su localIdentifier único.
//
//  Uso:
//    let container = try PurgatorioQueueManager.makeContainer()
//    let queue = PurgatorioQueueManager(container: container)
//    queue.mark(localIdentifier: asset.localIdentifier, groupID: group.id.uuidString)
//    print(queue.markedCount)   // → 1
//

import SwiftData
import Foundation
import os.log

// MARK: - MarkedAsset Model

/// Registro de un asset fotográfico marcado para destrucción en Purgatorio.
///
/// `localIdentifier` es único — marcar el mismo asset dos veces es idempotente.
/// `groupID` enlaza el asset al `SimilarityGroup.id` que lo originó (si aplica),
/// permitiendo operaciones de borrado por grupo completo.
@Model
public final class MarkedAsset {

    /// Identificador estable del `PHAsset`. Único en el modelo.
    @Attribute(.unique)
    public var localIdentifier: String

    /// Momento en que el asset fue marcado. Útil para ordenar la cola.
    public var markedAt: Date

    /// UUID del `SimilarityGroup` al que pertenece este asset (opcional).
    /// `nil` si fue marcado manualmente, sin análisis de similitud.
    public var groupID: String?

    /// Indica si este asset está programado para borrado masivo (`true`)
    /// o para envío al álbum de Purgatorio en Google Photos (`false`).
    public var isScheduledForDeletion: Bool

    public init(
        localIdentifier: String,
        groupID: String? = nil,
        isScheduledForDeletion: Bool = true
    ) {
        self.localIdentifier       = localIdentifier
        self.markedAt              = Date()
        self.groupID               = groupID
        self.isScheduledForDeletion = isScheduledForDeletion
    }
}

// MARK: - PurgatorioQueueManager

/// Manager @MainActor de la cola de destrucción persistida en SwiftData.
///
/// Todas las operaciones son síncronos respecto al `ModelContext` del hilo principal,
/// garantizando escritura-en-disco inmediata y sin latencia de I/O observable.
@MainActor
public final class PurgatorioQueueManager: ObservableObject {

    // MARK: - Published State

    /// Número de assets marcados actualmente.
    @Published public private(set) var markedCount: Int = 0

    /// Lista completa de assets marcados, ordenados por `markedAt` descendente.
    @Published public private(set) var markedAssets: [MarkedAsset] = []

    // MARK: - Private

    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.purgatorio.app", category: "PurgatorioQueue")

    // MARK: - Factory

    /// Crea el `ModelContainer` de SwiftData.
    ///
    /// El store se persiste en el directorio de soporte de la app.
    /// - Parameter inMemoryOnly: `true` para tests unitarios; `false` en producción.
    public static func makeContainer(inMemoryOnly: Bool = false) throws -> ModelContainer {
        let schema = Schema([MarkedAsset.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemoryOnly,
            allowsSave: true
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    // MARK: - Initializer

    public init(container: ModelContainer) {
        self.modelContext = container.mainContext
        // Habilitar autosave: cada cambio al context se persiste automáticamente.
        // Para Purgatorio necesitamos además save() explícito post-mark para
        // garantizar durabilidad ante OOM kill inmediato.
        self.modelContext.autosaveEnabled = true
        fetchAll()
    }

    // MARK: - Public API

    /// Marca un asset para destrucción y lo persiste inmediatamente en disco.
    ///
    /// Operación idempotente: marcar el mismo `localIdentifier` dos veces
    /// actualiza `groupID` pero no duplica el registro.
    ///
    /// - Parameters:
    ///   - localIdentifier: `PHAsset.localIdentifier` del asset a marcar.
    ///   - groupID: UUID string del `SimilarityGroup` (si aplica).
    ///   - isScheduledForDeletion: `true` = borrado; `false` = mover a álbum Purgatorio.
    public func mark(
        localIdentifier: String,
        groupID: String? = nil,
        isScheduledForDeletion: Bool = true
    ) {
        // Idempotencia: busca si ya existe antes de insertar.
        if let existing = fetchAsset(localIdentifier: localIdentifier) {
            existing.groupID                = groupID
            existing.isScheduledForDeletion = isScheduledForDeletion
            existing.markedAt              = Date()
        } else {
            let asset = MarkedAsset(
                localIdentifier: localIdentifier,
                groupID: groupID,
                isScheduledForDeletion: isScheduledForDeletion
            )
            modelContext.insert(asset)
        }

        // Persistencia inmediata: crítica para sobrevivir OOM Kill.
        forceSave()
        fetchAll()
        logger.info("Marcado: \(localIdentifier). Total en cola: \(self.markedCount)")
    }

    /// Marca un grupo completo de similitud para destrucción.
    ///
    /// Conveniente para el flujo del SurvivalTournamentView donde el perdedor
    /// de un torneo (grupo completo) se destruye de una vez.
    public func markGroup(assetIDs: [String], groupID: String, isScheduledForDeletion: Bool = true) {
        for id in assetIDs {
            mark(localIdentifier: id, groupID: groupID, isScheduledForDeletion: isScheduledForDeletion)
        }
        logger.info("Grupo marcado: \(groupID) — \(assetIDs.count) assets.")
    }

    /// Desmarca un asset (lo saca de la cola sin borrarlo de la galería).
    public func unmark(localIdentifier: String) {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else { return }
        modelContext.delete(asset)
        forceSave()
        fetchAll()
        logger.info("Desmarcado: \(localIdentifier). Total en cola: \(self.markedCount)")
    }

    /// Desmarca todos los assets de un grupo.
    public func unmarkGroup(groupID: String) {
        let descriptor = FetchDescriptor<MarkedAsset>(
            predicate: #Predicate { $0.groupID == groupID }
        )
        if let assets = try? modelContext.fetch(descriptor) {
            assets.forEach { modelContext.delete($0) }
            forceSave()
            fetchAll()
        }
    }

    /// Comprueba si un asset está en la cola.
    public func isMarked(localIdentifier: String) -> Bool {
        fetchAsset(localIdentifier: localIdentifier) != nil
    }

    /// Retorna todos los IDs de la cola para construir el batch de borrado con PhotoKit.
    public var allMarkedIdentifiers: [String] {
        markedAssets.map(\.localIdentifier)
    }

    /// Retorna IDs agrupados por `groupID` para el batch upload de Google Photos.
    public var identifiersByGroup: [String: [String]] {
        Dictionary(grouping: markedAssets.compactMap { asset -> (String, String)? in
            guard let gid = asset.groupID else { return nil }
            return (gid, asset.localIdentifier)
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    /// Limpia toda la cola de persistencia.
    /// Llama esto DESPUÉS de que el borrado masivo con PhotoKit haya completado con éxito.
    public func clearAll() {
        markedAssets.forEach { modelContext.delete($0) }
        forceSave()
        fetchAll()
        logger.info("Cola limpiada. Todos los assets removidos del Purgatorio.")
    }

    // MARK: - Private

    private func fetchAll() {
        let descriptor = FetchDescriptor<MarkedAsset>(
            sortBy: [SortDescriptor(\.markedAt, order: .reverse)]
        )
        markedAssets = (try? modelContext.fetch(descriptor)) ?? []
        markedCount  = markedAssets.count
    }

    private func fetchAsset(localIdentifier: String) -> MarkedAsset? {
        let descriptor = FetchDescriptor<MarkedAsset>(
            predicate: #Predicate { $0.localIdentifier == localIdentifier }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Save explícito + sincrónico para garantizar durabilidad inmediata.
    private func forceSave() {
        do {
            try modelContext.save()
        } catch {
            logger.error("PurgatorioQueue save falló: \(error.localizedDescription)")
        }
    }
}
