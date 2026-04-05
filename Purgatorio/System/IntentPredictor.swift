//
//  IntentPredictor.swift
//  Purgatorio
//
//  CoreMotion Intent Predictor: anticipa el swipe destructivo y pre-calienta
//  los pipelines de Metal y audio ANTES del gesto real.
//
//  Algoritmo:
//    1. CMMotionManager muestrea el acelerómetro a 100Hz (0.01s).
//    2. Ventana deslizante de 10 muestras (0.1s) promedia el ruido del sensor.
//    3. Si la aceleración lateral filtrada supera el umbral → el usuario está
//       preparando un swipe.
//    4. Se llama GlobalShredderManager.prepare() y HapticAudioEngine.prime()
//       para que VRAM y buffer de audio estén listos ~5ms después del touchDown.
//
//  Concurrencia: actor Swift para serializar el acceso al ring buffer.
//  CMMotionManager corre en su propio OperationQueue de alta frecuencia.
//

import CoreMotion
import UIKit
import os.log

// MARK: - IntentPredictor

public actor IntentPredictor {

    // MARK: - Configuration

    /// Umbral de aceleración lateral filtrada (en G) para predecir un swipe.
    /// Default 0.25G — ajustar en testing de Hardware. Demasiado bajo → falsos positivos;
    /// demasiado alto → priming tardío.
    public let lateralThreshold: Double

    /// Tamaño de la ventana de filtrado (muestras). A 100Hz → 10 = 0.1 segundos.
    private let windowSize: Int

    /// Intervalo de muestreo del acelerómetro (segundos).
    private let sampleInterval: TimeInterval = 0.01  // 100Hz

    // MARK: - State

    /// Ring buffer de las últimas N muestras de aceleración lateral (eje X).
    private var ringBuffer: [Double]

    /// Puntero de escritura del ring buffer.
    private var ringIndex: Int = 0

    /// Si ya hemos primado en esta ventana de intento. Se resetea cuando
    /// la aceleración baja por debajo del umbral.
    private var isPrimed: Bool = false

    /// Timestamp del último priming. Usado para calcular la latencia real.
    private var lastPrimeTime: CFAbsoluteTime = 0

    // MARK: - CoreMotion

    /// Instancia propia del motion manager. No usar la singleton en code base compartido.
    private let motionManager = CMMotionManager()
    private let motionQueue   = OperationQueue()

    // MARK: - Callbacks

    /// Closure que se invoca al detectar intención de swipe (en el hilo del actor).
    /// El consumidor (DestructiveSwipeView) conecta aquí el priming de Metal/Audio.
    private var onIntentDetected: (@Sendable () async -> Void)?

    /// Closure que se invoca cuando la aceleración vuelve a neutro.
    private var onIntentCancelled: (@Sendable () async -> Void)?

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "IntentPredictor")

    // MARK: - Init

    /// - Parameters:
    ///   - lateralThreshold: Aceleración lateral (G) para disparar priming. Default: 0.25.
    ///   - windowSize: Muestras en la ventana de filtrado. Default: 10 (0.1s a 100Hz).
    public init(lateralThreshold: Double = 0.25, windowSize: Int = 10) {
        self.lateralThreshold = lateralThreshold
        self.windowSize       = max(3, windowSize)
        self.ringBuffer       = [Double](repeating: 0, count: self.windowSize)
        self.motionQueue.name = "com.purgatorio.motion"
        self.motionQueue.qualityOfService = .userInteractive
        self.motionQueue.maxConcurrentOperationCount = 1
    }

    // MARK: - Public API

    /// Configura los callbacks de resultado.
    /// Debe llamarse ANTES de `startMonitoring()`.
    public func configure(
        onIntentDetected:  @escaping @Sendable () async -> Void,
        onIntentCancelled: (@Sendable () async -> Void)? = nil
    ) {
        self.onIntentDetected  = onIntentDetected
        self.onIntentCancelled = onIntentCancelled
    }

    /// Arranca el muestreo del acelerómetro.
    ///
    /// Idempotente: si ya está activo, no hace nada.
    /// El muestreo corre en `motionQueue` (background).
    /// El procesamiento del ring buffer ocurre en el executor del actor.
    public func startMonitoring() {
        guard motionManager.isAccelerometerAvailable,
              !motionManager.isAccelerometerActive else {
            logger.info("Acelerómetro no disponible o ya activo.")
            return
        }

        motionManager.accelerometerUpdateInterval = sampleInterval

        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            // Saltar al executor del actor para escribir el ring buffer de forma segura
            Task { await self.processSample(data.acceleration) }
        }

        logger.info("IntentPredictor: muestreo iniciado a \(Int(1.0 / self.sampleInterval))Hz, " +
                     "ventana=\(self.windowSize) muestras, umbral=\(self.lateralThreshold)G")
    }

    /// Detiene el muestreo y libera el sensor.
    public func stopMonitoring() {
        motionManager.stopAccelerometerUpdates()
        ringBuffer = [Double](repeating: 0, count: windowSize)
        ringIndex  = 0
        isPrimed   = false
        logger.info("IntentPredictor detenido.")
    }

    /// Fuerza el priming inmediato (utilidad de testing / fallback).
    public func forcePrime() async {
        guard !isPrimed else { return }
        isPrimed      = true
        lastPrimeTime = CFAbsoluteTimeGetCurrent()
        await onIntentDetected?()
    }

    /// Latencia del último priming en milisegundos (para telemetría).
    public var lastPrimeLatencyMs: Double {
        guard lastPrimeTime > 0 else { return -1 }
        return (CFAbsoluteTimeGetCurrent() - lastPrimeTime) * 1000
    }

    // MARK: - Private: Signal Processing

    /// Procesa una muestra del acelerómetro en el contexto del actor.
    private func processSample(_ acceleration: CMAcceleration) async {
        // Escribir en el ring buffer (eje X = lateral en orientación portrait)
        ringBuffer[ringIndex] = abs(acceleration.x)
        ringIndex = (ringIndex + 1) % windowSize

        // Media móvil simple de la ventana
        let filteredLateral = ringBuffer.reduce(0, +) / Double(windowSize)

        if filteredLateral > lateralThreshold {
            if !isPrimed {
                isPrimed      = true
                lastPrimeTime = CFAbsoluteTimeGetCurrent()
                logger.debug("Intent detectado: lateral=\(filteredLateral, format: .fixed(precision: 3))G → priming")
                await onIntentDetected?()
            }
        } else {
            if isPrimed {
                isPrimed = false
                await onIntentCancelled?()
            }
        }
    }
}
