//
//  ThermalGovernor.swift
//  Purgatorio
//
//  Válvula de presión térmica del sistema.
//
//  Monitorea ProcessInfo.thermalState y ajusta automáticamente:
//  - Frecuencia de refresco del modo Estroboscópico (120Hz → 60Hz)
//  - Estado del motor de audio ASMR (HapticAudioEngine)
//  - Presupuesto de texturas Metal (resolución máxima → reducida → mínima)
//  - Motor de Machine Learning del SimilarityEngine (on/off)
//
//  Uso:
//      ThermalGovernor.shared.targetStrobeRate   // 120 o 60
//      ThermalGovernor.shared.isAudioEnabled     // false en .serious+
//
//  Para observar cambios en un actor:
//      for await state in ThermalGovernor.shared.stateStream() { ... }
//

import Foundation
import Observation
import os.log

// MARK: - ThermalGovernor

/// Singleton observable que publica el estado térmico del dispositivo
/// y políticas derivadas para todos los componentes del sistema.
///
/// Usa el macro `@Observable` (iOS 17+) para integración nativa con SwiftUI.
/// Para observers en actores de Swift usa `stateStream()`.

public final class ThermalGovernor: NSObject, ObservableObject {

    // MARK: - Singleton

    public static let shared = ThermalGovernor()

    // MARK: - Published State

    /// Estado térmico actual del dispositivo.
    /// `.nominal` → `.fair` → `.serious` → `.critical`
    @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    // MARK: - Derived Policies (computed; SwiftUI observa automáticamente)

    /// Frecuencia de refresco objetivo del modo Estroboscópico.
    /// `.serious` o `.critical` → 60 Hz para proteger la CPU/GPU.
    public var targetStrobeRate: Int {
        thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 60 : 120
    }

    /// Indica si el motor de audio ASMR (HapticAudioEngine) debe estar activo.
    /// AVAudioEngine es una fuente significativa de carga de CPU.
    public var isAudioEnabled: Bool {
        thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    /// Indica si el SimilarityEngine puede ejecutar inferencia Vision/CoreML.
    /// Desactivado en `.critical` para evitar throttling agresivo del SoC.
    public var isMLEnabled: Bool {
        thermalState.rawValue < ProcessInfo.ThermalState.critical.rawValue
    }

    /// Presupuesto de resolución de texturas Metal para el PhotoProviderActor.
    public var textureBudget: TextureBudget {
        switch thermalState {
        case .nominal:  return .full
        case .fair:     return .full
        case .serious:  return .reduced
        case .critical: return .minimal
        @unknown default: return .reduced
        }
    }

    /// Multiplicador de resolución de textura basado en presupuesto térmico.
    /// Multiplica por el `dynamicTextureSize` del PhotoProviderActor.
    public var textureResolutionMultiplier: CGFloat {
        switch textureBudget {
        case .full:    return 1.0
        case .reduced: return 0.6
        case .minimal: return 0.35
        }
    }

    // MARK: - Types

    public enum TextureBudget: Sendable {
        case full       /// Resolución nativa de pantalla
        case reduced    /// ~60% — calidad visible pero sin presión térmica
        case minimal    /// ~35% — supervivencia: evita throttling del SoC
    }

    // MARK: - AsyncStream Support (para actores Swift)

    private var stateStreamContinuations: [UUID: AsyncStream<ProcessInfo.ThermalState>.Continuation] = [:]

    /// Stream de cambios de estado térmico para consumo en actores Swift.
    ///
    /// El stream emite inmediatamente el estado actual y luego cada cambio.
    /// Cancela la `Task` que lo consume para liberarlo.
    ///
    /// ```swift
    /// Task {
    ///     for await state in ThermalGovernor.shared.stateStream() {
    ///         await myActor.applyThermalConstraints(state)
    ///     }
    /// }
    /// ```
    public func stateStream() -> AsyncStream<ProcessInfo.ThermalState> {
        let currentState = thermalState
        return AsyncStream { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            let id = UUID()
            continuation.yield(currentState)
            continuation.onTermination = { [weak self] _ in
                self?.removeStreamContinuation(id: id)
            }
            Task { @MainActor [weak self] in
                self?.stateStreamContinuations[id] = continuation
            }
        }
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "ThermalGovernor")
    private var observerTask: Task<Void, Never>?

    private override init() {
        super.init()
        self.thermalState = ProcessInfo.processInfo.thermalState
        startObserving()
        logger.info("ThermalGovernor inicializado. Estado inicial: \(self.thermalState.debugDescription)")
    }

    /// Observa la notificación del sistema en un Task de larga vida.
    private func startObserving() {
        observerTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: ProcessInfo.thermalStateDidChangeNotification
            ) {
                let newState = ProcessInfo.processInfo.thermalState
                await MainActor.run { [weak self] in
                    self?.applyNewThermalState(newState)
                }
            }
        }
    }

    @MainActor
    private func applyNewThermalState(_ newState: ProcessInfo.ThermalState) {
        guard newState != thermalState else { return }
        let previous = thermalState
        thermalState = newState

        logger.warning(
            "Cambio térmico: \(previous.debugDescription) → \(newState.debugDescription). StrobeRate=\(self.targetStrobeRate)Hz Audio=\(self.isAudioEnabled) ML=\(self.isMLEnabled)"
        )

        // Notificar a todos los observers AsyncStream
        for continuation in stateStreamContinuations.values {
            continuation.yield(newState)
        }
    }

    private func removeStreamContinuation(id: UUID) {
        Task { @MainActor [weak self] in
            self?.stateStreamContinuations.removeValue(forKey: id)
        }
    }
}

// MARK: - Debug Helpers

extension ProcessInfo.ThermalState {
    var debugDescription: String {
        switch self {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious ⚠️"
        case .critical: return "critical 🔴"
        @unknown default: return "unknown(\(rawValue))"
        }
    }

    var localizedDescription: String {
        switch self {
        case .nominal:  return "Normal"
        case .fair:     return "Moderado"
        case .serious:  return "Caliente — rendimiento reducido"
        case .critical: return "Crítico — funciones desactivadas"
        @unknown default: return "Desconocido"
        }
    }
}

// MARK: - SwiftUI Integration Helper

extension ThermalGovernor {
    /// Advertencia textual para mostrar a la UI si el estado es degradado.
    public var userFacingWarning: String? {
        switch thermalState {
        case .nominal, .fair: return nil
        case .serious: return "El dispositivo está caliente. Velocidad reducida."
        case .critical: return "Temperatura crítica. Funciones avanzadas desactivadas."
        @unknown default: return nil
        }
    }
}
