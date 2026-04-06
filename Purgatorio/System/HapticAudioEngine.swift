//
//  HapticAudioEngine.swift
//  Purgatorio
//
//  Singleton de feedback sensorial de baja latencia.
//
//  v2.0 — Latencia Cero e Integridad Atómica
//
//  Nuevas funcionalidades:
//    - prime(): pre-calienta CHHapticEngine y pre-schedula el primer pattern háptico
//      para respuesta sub-8ms. Llamado por IntentPredictor.
//    - Rugosidad háptica: modula intensity/sharpness de CHHapticEngine en el
//      onChanged del gesto según la calidad de la foto (resolución + ruido visual).
//    - Audio-reactividad lumínica: AVAudioUnitEQ en la cadena de audio mapea
//      el brillo medio de la textura a la frecuencia central del EQ.
//      Brillo alto → agudos (cristal). Brillo bajo → graves (piedra/metal).
//

import AVFoundation
import CoreHaptics
import Metal
import os.log

// MARK: - PhotoQualityProfile

/// Perfil de calidad de una foto, usado para modular el feedback háptico.
///
/// Calculado una vez al cargar la textura; consumido continuamente
/// durante el gesto de arrastre.
public struct PhotoQualityProfile: Sendable {
    /// Resolución normalizada 0…1. 1 = máxima del sensor; 0 = thumbnail ≤256px.
    public let resolutionScore: Float
    /// Ruido visual normalizado 0…1. 0 = limpia (ISO bajo, light). 1 = ruidosa (high ISO, noche).
    public let noiseScore: Float
    /// Brillo medio de la textura 0…1. Usado para el mapeo de EQ audio-reactiva.
    public let meanBrightness: Float

    /// Calidad compuesta: 0 = basura (rugosa), 1 = prístina (cristalina).
    public var compositeQuality: Float {
        let q = resolutionScore * 0.4 + (1 - noiseScore) * 0.6
        return max(0, min(1, q))
    }

    /// Calcula el perfil desde un `MTLTexture`.
    ///
    /// Lee una muestra de 4×4 píxeles del centro de la textura para estimar
    /// el brillo medio y la varianza (proxy de ruido).
    /// La resolución se normaliza contra un máximo razonable de 12MP (4000×3000).
    public static func from(cgImage: CGImage) -> PhotoQualityProfile {
        let width  = cgImage.width
        let height = cgImage.height

        // Resolución normalizada (12MP = 1.0)
        let totalPixels = Float(width * height)
        let resScore    = min(totalPixels / 12_000_000.0, 1.0)

        // Muestrea 4×4 píxeles del centro para brillo y varianza
        let sampleSize = 4
        let originX    = max(0, width / 2 - sampleSize / 2)
        let originY    = max(0, height / 2 - sampleSize / 2)
        
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        if let cropped = cgImage.cropping(to: CGRect(x: originX, y: originY, width: sampleSize, height: sampleSize)),
           let context = CGContext(data: &pixels, width: sampleSize, height: sampleSize, bitsPerComponent: 8, bytesPerRow: sampleSize * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        }

        // Calcular luminancia media y varianza
        var sum:     Float = 0
        var sumSq:   Float = 0
        let count  = sampleSize * sampleSize
        for i in 0 ..< count {
            let r = Float(pixels[i * 4])     / 255.0
            let g = Float(pixels[i * 4 + 1]) / 255.0
            let b = Float(pixels[i * 4 + 2]) / 255.0
            let luma = 0.299 * r + 0.587 * g + 0.114 * b  // Rec.601
            sum   += luma
            sumSq += luma * luma
        }
        let mean     = sum / Float(count)
        let variance = sumSq / Float(count) - mean * mean  // σ²
        // Varianza normalizada: valores > 0.05 indican ruido significativo
        let noiseScore = min(variance / 0.05, 1.0)

        return PhotoQualityProfile(
            resolutionScore: resScore,
            noiseScore: noiseScore,
            meanBrightness: mean
        )
    }
}

// MARK: - HapticAudioEngine

@MainActor
public final class HapticAudioEngine {

    // MARK: - Singleton
    public static let shared = HapticAudioEngine()

    // MARK: - AVAudio
    private let audioEngine    = AVAudioEngine()
    private let playerNode     = AVAudioPlayerNode()
    private let eqNode         = AVAudioUnitEQ(numberOfBands: 1)
    private var crunchBuffer:  AVAudioPCMBuffer?
    private var isAudioReady   = false

    // MARK: - CoreHaptics
    private var hapticEngine:  CHHapticEngine?
    private var isHapticReady  = false

    /// Pattern háptico pre-compilado por prime(). Listo para disparo instantáneo.
    private var primedPattern: CHHapticPattern?
    private var primedPlayer:  CHHapticPatternPlayer?

    // MARK: - Rugosity State

    /// Continuación háptica activa durante el gesto. Se alimenta con updateRugosity().
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "HapticAudioEngine")

    // MARK: - Init

    private init() {
        setupAudioSession()
        setupAudioEngineWithEQ()
        setupHaptics()
    }

    // MARK: - Public API: Lifecycle

    /// Pre-calienta motores (app launch / sesión de fotos).
    public func prepare() {
        if !isAudioReady  { startAudioEngine() }
        if !isHapticReady { startHapticEngine() }
    }

    /// Pre-carga háptica de latencia ultra-baja (~5ms response).
    ///
    /// Crea el `CHHapticPatternPlayer` y lo deja listo para `start()`.
    /// Llamado por `IntentPredictor` cuando detecta aceleración lateral.
    ///
    /// Diferencia con `prepare()`:
    ///   - `prepare()` arranca los motores (cold start: ~50ms).
    ///   - `prime()` pre-compila el pattern para el próximo disparo (hot: ~2ms).
    public func prime() {
        guard isHapticReady, let engine = hapticEngine else {
            prepare()
            return
        }
        do {
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85)
            let event     = CHHapticEvent(
                eventType: .hapticTransient, parameters: [intensity, sharpness],
                relativeTime: 0
            )
            let pattern   = try CHHapticPattern(events: [event], parameters: [])
            primedPattern = pattern
            primedPlayer  = try engine.makePlayer(with: pattern)
            logger.debug("HapticEngine primed — player listo para disparo instantáneo.")
        } catch {
            logger.error("Prime falló: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API: Destruction Trigger

    /// Dispara háptico + audio con EQ audio-reactiva basada en el brillo.
    ///
    /// Si `prime()` fue llamado previamente, usa el player pre-compilado
    /// para latencia < 8.33ms (1 frame a 120Hz).
    public func triggerDestruction(profile: PhotoQualityProfile? = nil) {
        guard ThermalGovernor.shared.isAudioEnabled else {
            logger.debug("HapticAudioEngine: desactivado por ThermalGovernor.")
            return
        }

        // Configurar EQ basada en brillo ANTES de reproducir
        if let profile { applyBrightnessEQ(brightness: profile.meanBrightness) }

        Task.detached(priority: .userInitiated) { [weak self] in
            self?.fireHaptic()
            self?.playCrunchSound()
        }
    }

    // MARK: - Public API: Rugosity Haptics (durante DragGesture.onChanged)

    /// Inicia la sesión de rugosidad háptica continua.
    ///
    /// Llamar en `DragGesture.onChanged` la primera vez que se detecta movimiento.
    /// Crea un `CHHapticAdvancedPatternPlayer` con un continuous event largo (~10s)
    /// cuya intensidad y sharpness se modulan vía `updateRugosity()`.
    public func startRugositySession(quality: PhotoQualityProfile) {
        guard isHapticReady, let engine = hapticEngine,
              ThermalGovernor.shared.isAudioEnabled else { return }

        do {
            // Evento continuo largo (10s): será interrumpido por endRugositySession()
            let intensity = CHHapticEventParameter(
                parameterID: .hapticIntensity,
                value: hapticIntensity(for: quality)
            )
            let sharpness = CHHapticEventParameter(
                parameterID: .hapticSharpness,
                value: hapticSharpness(for: quality)
            )
            let event = CHHapticEvent(
                eventType:    .hapticContinuous,
                parameters:   [intensity, sharpness],
                relativeTime: 0,
                duration: 10
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player  = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            continuousPlayer = player
        } catch {
            logger.error("startRugositySession falló: \(error.localizedDescription)")
        }
    }

    /// Modula la rugosidad en tiempo real durante el arrastre.
    ///
    /// - Parameters:
    ///   - dragProgress: Progreso del arrastre 0…1 (distancia / umbral).
    ///   - quality: Perfil de calidad de la foto.
    public func updateRugosity(dragProgress: Float, quality: PhotoQualityProfile) {
        guard let player = continuousPlayer else { return }

        // A medida que el drag progresa hacia el umbral de destrucción:
        //   - Fotos de baja calidad → intensidad y rugosidad AUMENTAN (feedback sucio)
        //   - Fotos de alta calidad → permanecen suaves (feedback cristalino)
        let progressBoost = dragProgress * (1 - quality.compositeQuality)

        let intensityVal = min(1.0, hapticIntensity(for: quality) + progressBoost * 0.5)
        let sharpnessVal = hapticSharpness(for: quality)

        do {
            try player.sendParameters([
                CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl,
                    value: intensityVal,
                    relativeTime: 0
                ),
                CHHapticDynamicParameter(
                    parameterID: .hapticSharpnessControl,
                    value: sharpnessVal,
                    relativeTime: 0
                )
            ], atTime: CHHapticTimeImmediate)
        } catch {
            // Expected: player puede estar stopped si el gesto terminó
        }
    }

    /// Detiene la sesión de rugosidad (en DragGesture.onEnded/cancelled).
    public func endRugositySession() {
        do {
            try continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
        } catch { /* expected if already stopped */ }
        continuousPlayer = nil
    }

    // MARK: - Private: Haptic Quality Mapping

    /// Intensidad háptica basada en calidad.
    /// Baja calidad → alta intensidad (más vibración = feedback "sucio").
    private func hapticIntensity(for quality: PhotoQualityProfile) -> Float {
        let base: Float = 0.15
        let range: Float = 0.75
        return base + range * (1 - quality.compositeQuality)
    }

    /// Sharpness háptica basada en calidad.
    /// Alta calidad → alta sharpness ("cristalino"). Baja → baja ("mate/rugoso").
    private func hapticSharpness(for quality: PhotoQualityProfile) -> Float {
        return 0.15 + 0.7 * quality.compositeQuality
    }

    // MARK: - Private: Audio-Reactive EQ

    /// Configura la frecuencia central del EQ paramétrico basándose en el brillo.
    ///
    /// Mapeo perceptual:
    ///   brightness 0.0 (oscuro)  → 120 Hz  (graves: piedra, metal)
    ///   brightness 0.5 (medio)   → 800 Hz  (neutro)
    ///   brightness 1.0 (claro)   → 4200 Hz (agudos: cristal, vidrio)
    ///
    /// El EQ usa ganancia 0: no amplifica. Solo filtra el paso de banda para
    /// colorear el sonido de crunch según la "personalidad" lumínica de la foto.
    private func applyBrightnessEQ(brightness: Float) {
        guard eqNode.bands.count > 0 else { return }
        let band = eqNode.bands[0]

        // Exponencial para mapeo perceptualmente lineal de frecuencia
        let minFreq: Float = 120
        let maxFreq: Float = 4200
        let freq = minFreq * pow(maxFreq / minFreq, brightness)

        band.filterType = .parametric
        band.frequency  = freq
        band.bandwidth  = 1.5      // Q=1.5: ancha → colorea sin destruir el crunch
        band.gain       = 6.0      // +6dB de boost en la banda → carácter audible
        band.bypass     = false

        logger.debug("EQ → brightness=\(brightness) freq=\(freq)Hz")
    }

    // MARK: - Private: Audio Session

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers, .duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("AVAudioSession setup falló: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: AVAudioEngine + EQ Chain

    private func setupAudioEngineWithEQ() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

        audioEngine.attach(playerNode)
        audioEngine.attach(eqNode)

        // Cadena: playerNode → EQ → mainMixerNode → output
        audioEngine.connect(playerNode, to: eqNode, format: format)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: format)

        crunchBuffer = generateCrunchPCM(sampleRate: 44100, durationSeconds: 0.32)
    }

    private func startAudioEngine() {
        do {
            try audioEngine.start()
            isAudioReady = true
            logger.info("AVAudioEngine iniciado.")
        } catch {
            logger.error("AVAudioEngine.start() falló: \(error.localizedDescription)")
        }
    }

    private func generateCrunchPCM(sampleRate: Double, durationSeconds: Double) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let format     = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let data  = buffer.floatChannelData![0]
        let invSR = Float(1.0 / sampleRate)
        let twoPi = Float.pi * 2

        for i in 0 ..< Int(frameCount) {
            let t = Float(i) * invSR
            let noise       = Float.random(in: -1...1)
            let noiseDecay  = exp(-t * 18.0)
            let paper       = sin(twoPi * 2400 * t) * 0.35
            let paperDecay  = exp(-t * 10.0)
            let thud        = sin(twoPi * 60 * t) * exp(-t * 25.0) * 0.9
            data[i] = (noise * noiseDecay * 0.65 + paper * paperDecay + thud) * 0.7
        }
        return buffer
    }

    private func playCrunchSound() {
        guard isAudioReady, let buffer = crunchBuffer else { return }
        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        playerNode.play()
    }

    // MARK: - Private: CoreHaptics

    private func setupHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.resetHandler = { [weak self] in self?.startHapticEngine() }
            hapticEngine?.stoppedHandler = { [weak self] _ in self?.isHapticReady = false }
        } catch {
            logger.error("CHHapticEngine init falló: \(error.localizedDescription)")
        }
    }

    private func startHapticEngine() {
        hapticEngine?.start { [weak self] error in
            if let error {
                self?.logger.error("CHHapticEngine.start falló: \(error.localizedDescription)")
            } else {
                self?.isHapticReady = true
            }
        }
    }

    /// Dispara el haptic transient. Usa el player pre-compilado si `prime()` fue llamado.
    private func fireHaptic() {
        guard isHapticReady, let engine = hapticEngine else { return }

        // Ruta rápida: player pre-primed por IntentPredictor
        if let primed = primedPlayer {
            do {
                try primed.start(atTime: CHHapticTimeImmediate)
                primedPlayer = nil  // Consumido; se re-crea en el próximo prime()
                return
            } catch { /* fallthrough a ruta normal */ }
        }

        // Ruta normal: compile + fire
        do {
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85)
            let event     = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
            let pattern   = try CHHapticPattern(events: [event], parameters: [])
            let player    = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            logger.error("CHHapticEvent falló: \(error.localizedDescription)")
        }
    }
}
