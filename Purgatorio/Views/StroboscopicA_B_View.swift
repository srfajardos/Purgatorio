//
//  StroboscopicA_B_View.swift
//  Purgatorio
//
//  Vista de comparación estroboscópica A/B.
//
//  Motor: CADisplayLink anclado al hardware refresh rate (ProMotion 120Hz).
//  Política térmica: ThermalGovernor.stateStream() actualiza preferredFrameRateRange
//  en caliente — sin invalidar ni recrear el display link, sin glitch visual.
//
//  Frecuencia de alternancia: 4 Hz (configurable).
//  A 120fps del display link: swap cada 30 frames.
//  A  60fps del display link: swap cada 15 frames.
//  → Alternancia visual siempre ≈4Hz, exacta, sin micro-stuttering.
//

import SwiftUI
import UIKit
import QuartzCore
import os.log

// MARK: - DisplayLinkProxy

/// Proxy de referencia débil para el target del CADisplayLink.
///
/// `CADisplayLink(target:selector:)` retiene fuertemente a su target.
/// Sin proxy, el `StroboscopicDisplayCoordinator` nunca sería deallocado
/// mientras el link esté activo, causando un retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var coordinator: StroboscopicDisplayCoordinator?

    @objc func tick(_ link: CADisplayLink) {
        coordinator?.handleTick(link)
    }
}

// MARK: - StroboscopicDisplayCoordinator

/// Coordinador central del modo A/B Estroboscópico.
///
/// ## Responsabilidades
/// 1. Gestionar el ciclo de vida del `CADisplayLink` (start / stop).
/// 2. Observar `ThermalGovernor.stateStream()` y aplicar los cambios de
///    frame rate **en caliente** — solo `preferredFrameRateRange` cambia;
///    el link nunca se invalida ni se recrea.
/// 3. Calcular cuándo hacer el swap A/B según el frame rate activo.
///
/// ## Concurrencia
/// - Todos los métodos públicos deben llamarse desde el hilo principal.
/// - `CADisplayLink` garantiza callbacks en el main RunLoop.
/// - `thermalObservationTask` usa `@MainActor` para saltar al hilo principal
///   antes de invocar `updateFrameRate(_:)`.
///
/// ## Uso
/// ```swift
/// let coordinator = StroboscopicDisplayCoordinator(strobeSwapRate: 4)
/// coordinator.onStrobe = { showingA in /* swap imageView */ }
/// coordinator.start()
/// // …
/// coordinator.stop()
/// ```
public final class StroboscopicDisplayCoordinator {

    // MARK: - Configuration

    /// Frecuencia de alternancia A/B en Hz. 4 = 4 swaps por segundo.
    public let strobeSwapRate: Int

    // MARK: - Callbacks

    /// Invocado en cada swap visual. `true` = slot A visible, `false` = slot B.
    /// **Garantizado en el hilo principal** (CADisplayLink corre en el main RunLoop).
    public var onStrobe: ((Bool) -> Void)?

    // MARK: - Observable State

    /// Frame rate actual del display link. Solo cambia vía `updateFrameRate(_:)`.
    public private(set) var currentFrameRate: Int = 120

    // MARK: - Private: Display Link

    private var displayLink: CADisplayLink?
    private let proxy = DisplayLinkProxy()   // Rompe el retain cycle

    // MARK: - Private: Strobe State

    private var frameCount: Int = 0          // Contador de frames desde el último swap
    private var showingA:   Bool = true      // Slot actualmente visible

    // MARK: - Private: Thermal Observation

    private var thermalObservationTask: Task<Void, Never>?

    // MARK: - Private: Logging

    private let logger = Logger(
        subsystem: "com.purgatorio.app",
        category: "StroboscopicCoordinator"
    )

    // MARK: - Lifecycle

    public init(strobeSwapRate: Int = 4) {
        self.strobeSwapRate = max(1, strobeSwapRate)
        proxy.coordinator = self
    }

    deinit {
        // `invalidate()` es seguro en deinit: si self se dealoca, el proxy
        // ya tiene `coordinator = nil` y no habrá más callbacks.
        displayLink?.invalidate()
        thermalObservationTask?.cancel()
    }

    /// Inicia el CADisplayLink con el frame rate actual del ThermalGovernor.
    ///
    /// Idempotente: llamar `start()` cuando ya está activo no hace nada.
    /// Llama desde el hilo principal.
    public func start() {
        guard displayLink == nil else { return }

        // Frame rate inicial: respeta el estado térmico al momento de start().
        let initialRate = ThermalGovernor.shared.targetStrobeRate
        currentFrameRate = initialRate

        let link         = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = makeFrameRateRange(for: initialRate)
        link.add(to: .main, forMode: .common)
        displayLink = link

        startThermalObservation()

        logger.info(
            "DisplayLink iniciado @ \(initialRate)fps, strobeSwapRate=\(self.strobeSwapRate)Hz"
        )
    }

    /// Detiene el display link y cancela la observación térmica.
    ///
    /// Seguro para llamar múltiples veces. Llama desde el hilo principal al
    /// desmontar la vista (`dismantleUIView`).
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        thermalObservationTask?.cancel()
        thermalObservationTask = nil
        logger.info("DisplayLink detenido.")
    }

    // MARK: - Public: In-Place Frame Rate Update

    /// Actualiza `preferredFrameRateRange` del display link existente.
    ///
    /// ## No-Destructivo
    /// - El link **no se invalida** ni se recrea.
    /// - `frameCount` **no se resetea** → la alternancia continúa sin salto visual.
    /// - El sistema aplica el nuevo rango en el próximo v-sync del compositor.
    ///
    /// - Parameter fps: Frame rate objetivo. Típicamente 120 (normal) o 60 (térmico).
    public func updateFrameRate(_ fps: Int) {
        guard fps != currentFrameRate else { return }
        let previous      = currentFrameRate
        currentFrameRate  = fps
        // ← Única línea que cambia en el display link existente:
        displayLink?.preferredFrameRateRange = makeFrameRateRange(for: fps)
        logger.warning("preferredFrameRateRange actualizado en caliente: \(previous)fps → \(fps)fps")
    }

    // MARK: - Internal: Display Link Callback

    /// Llamado por `DisplayLinkProxy.tick(_:)` en cada frame del hardware.
    internal func handleTick(_ link: CADisplayLink) {
        // Frames del display link necesarios para cada swap visual.
        //
        //   currentFrameRate = 120, strobeSwapRate = 4  →  framesPerSwap = 30
        //   currentFrameRate =  60, strobeSwapRate = 4  →  framesPerSwap = 15
        //
        // En ambos casos: 1 swap cada 1/4 de segundo ≈ 4Hz visuales exactos.
        let framesPerSwap = max(1, currentFrameRate / strobeSwapRate)

        frameCount += 1
        guard frameCount >= framesPerSwap else { return }

        frameCount = 0
        showingA.toggle()
        onStrobe?(showingA)
    }

    // MARK: - Private: Thermal Observation

    /// Suscribe al `AsyncStream` del ThermalGovernor.
    ///
    /// El `Task { @MainActor in }` garantiza que `updateFrameRate(_:)` siempre
    /// se llama en el hilo principal — requisito de `CADisplayLink`.
    ///
    /// `stateStream()` emite el estado actual como **primer valor inmediato**,
    /// confirmando (o corrigiendo) el frame rate tras el `start()`.
    private func startThermalObservation() {
        thermalObservationTask = Task { @MainActor [weak self] in
            for await _ in ThermalGovernor.shared.stateStream() {
                guard let self else { break }
                // Leer targetStrobeRate DESPUÉS de que el stream emita:
                // ThermalGovernor actualiza thermalState antes de yield → sin race.
                self.updateFrameRate(ThermalGovernor.shared.targetStrobeRate)
            }
        }
    }

    // MARK: - Private: CAFrameRateRange Factory

    /// Mapea un frame rate entero a un `CAFrameRateRange` con márgenes apropiados.
    ///
    /// El mínimo da flexibilidad al compositor bajo carga puntual elevada;
    /// el preferido es el objetivo real del sistema bajo condiciones normales.
    private func makeFrameRateRange(for fps: Int) -> CAFrameRateRange {
        switch fps {
        case 120...:
            // ProMotion full: preferred 120, margen hasta 80 para el compositor.
            return CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        case 60:
            // Throttle térmico .serious/.critical: preferred 60, mínimo 30.
            return CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        default:
            // Caso genérico (posibles valores intermedios futuros).
            let f = Float(max(1, fps))
            return CAFrameRateRange(minimum: f * 0.5, maximum: f, preferred: f)
        }
    }
}

// MARK: - StroboscopicA_B_View

/// Vista SwiftUI de comparación estroboscópica A/B.
///
/// Presenta dos imágenes alternando a `strobeSwapRate` Hz usando un
/// `CADisplayLink` atado al ProMotion (120Hz).
///
/// El frame rate se adapta automáticamente al estado térmico sin reiniciar la vista:
/// `.serious` → 60Hz, `.nominal`/`.fair` → 120Hz.
///
/// ## Modo Metal (futuro)
/// Reemplazar `StroboscopicHostView` por un `MTKView` que consuma
/// `TexturePair.textureA`/`.textureB` directamente. El `coordinator` permanece
/// igual — solo cambia la implementación de `onStrobe`.
///
/// ## Uso
/// ```swift
/// StroboscopicA_B_View(
///     imageA: viewModel.currentPair?.images?.0,
///     imageB: viewModel.currentPair?.images?.1
/// ) { showingA in
///     votingLabel = showingA ? "Foto A" : "Foto B"
/// }
/// ```
public struct StroboscopicA_B_View: UIViewRepresentable {

    // MARK: - Inputs

    public let imageA: UIImage?
    public let imageB: UIImage?
    public let strobeSwapRate: Int
    /// Callback opcional: informa qué slot está activo en cada swap.
    public var onSlotChanged: ((Bool) -> Void)?

    public init(
        imageA: UIImage?,
        imageB: UIImage?,
        strobeSwapRate: Int = 4,
        onSlotChanged: ((Bool) -> Void)? = nil
    ) {
        self.imageA         = imageA
        self.imageB         = imageB
        self.strobeSwapRate = strobeSwapRate
        self.onSlotChanged  = onSlotChanged
    }

    // MARK: - UIViewRepresentable

    public typealias Coordinator = StroboscopicDisplayCoordinator

    public func makeCoordinator() -> StroboscopicDisplayCoordinator {
        StroboscopicDisplayCoordinator(strobeSwapRate: strobeSwapRate)
    }

    public func makeUIView(context: Context) -> StroboscopicHostView {
        let hostView    = StroboscopicHostView()
        let coordinator = context.coordinator

        // Conectar el callback del display link al swap visual de la host view.
        // `weak hostView` evita retener la vista desde el coordinator.
        coordinator.onStrobe = { [weak hostView] showingA in
            hostView?.showSlot(a: showingA)
        }

        coordinator.start()
        return hostView
    }

    public func updateUIView(_ uiView: StroboscopicHostView, context: Context) {
        // Actualizar imágenes cuando cambien los bindings de SwiftUI.
        // El display link NO se toca — sigue corriendo al ritmo actual.
        uiView.imageA = imageA
        uiView.imageB = imageB

        // Refrescar el callback para capturar la última versión de `onSlotChanged`
        // (SwiftUI puede recrear la struct en cada render, actualizando la closure).
        let externalCallback = onSlotChanged
        context.coordinator.onStrobe = { [weak uiView] showingA in
            uiView?.showSlot(a: showingA)
            externalCallback?(showingA)
        }
    }

    public static func dismantleUIView(
        _ uiView: StroboscopicHostView,
        coordinator: StroboscopicDisplayCoordinator
    ) {
        // Al desmontar: detener el link y cancelar la observación térmica.
        // La vista puede desmontarse por: navegación, memory pressure, o SwiftUI rebuild.
        coordinator.stop()
    }
}

// MARK: - StroboscopicHostView

/// UIView interna que gestiona dos `UIImageView` superpuestas.
///
/// El swap visual se ejecuta asignando `alpha` directamente — sin animación,
/// sin `UIView.animate`, sin interpolación. Cualquier transición suavizada
/// destruiría la percepción estroboscópica que necesita el usuario para detectar
/// diferencias entre fotos cuasi-idénticas.
public final class StroboscopicHostView: UIView {

    // MARK: - Bindable Properties

    var imageA: UIImage? { didSet { slotViewA.image = imageA } }
    var imageB: UIImage? { didSet { slotViewB.image = imageB } }

    // MARK: - Subviews

    private let slotViewA: UIImageView = {
        let v = UIImageView()
        v.contentMode                                  = .scaleAspectFill
        v.clipsToBounds                                = true
        v.translatesAutoresizingMaskIntoConstraints    = false
        v.accessibilityIdentifier                      = "strobe_slot_a"
        return v
    }()

    private let slotViewB: UIImageView = {
        let v = UIImageView()
        v.contentMode                                  = .scaleAspectFill
        v.clipsToBounds                                = true
        v.translatesAutoresizingMaskIntoConstraints    = false
        v.accessibilityIdentifier                      = "strobe_slot_b"
        v.alpha                                        = 0  // B inicia oculto
        return v
    }()

    // MARK: - Thermal Badge (debug overlay)

    private let thermalBadge: UILabel = {
        let l = UILabel()
        l.font                                         = .monospacedSystemFont(ofSize: 11, weight: .medium)
        l.textColor                                    = .white.withAlphaComponent(0.7)
        l.backgroundColor                              = .black.withAlphaComponent(0.45)
        l.layer.cornerRadius                           = 4
        l.layer.masksToBounds                          = true
        l.translatesAutoresizingMaskIntoConstraints    = false
        l.textAlignment                                = .center
        l.isHidden                                     = true  // Solo visible en DEBUG
        return l
    }()

    // MARK: - Init

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    private func setupSubviews() {
        backgroundColor = .black
        addSubview(slotViewA)
        addSubview(slotViewB)
        addSubview(thermalBadge)

        NSLayoutConstraint.activate([
            // A y B ocupan todo el frame
            slotViewA.leadingAnchor.constraint(equalTo: leadingAnchor),
            slotViewA.trailingAnchor.constraint(equalTo: trailingAnchor),
            slotViewA.topAnchor.constraint(equalTo: topAnchor),
            slotViewA.bottomAnchor.constraint(equalTo: bottomAnchor),

            slotViewB.leadingAnchor.constraint(equalTo: leadingAnchor),
            slotViewB.trailingAnchor.constraint(equalTo: trailingAnchor),
            slotViewB.topAnchor.constraint(equalTo: topAnchor),
            slotViewB.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Badge en esquina superior derecha
            thermalBadge.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            thermalBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            thermalBadge.heightAnchor.constraint(equalToConstant: 22),
            thermalBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])

        #if DEBUG
        thermalBadge.isHidden = false
        startThermalBadgeUpdates()
        #endif
    }

    // MARK: - Strobe Swap

    /// Intercambia el slot visible sin animación (0 latencia).
    ///
    /// La asignación directa de `alpha` garantiza que el swap ocurra exactamente
    /// en el frame del CADisplayLink — sin que Core Animation interpole ni difiera.
    func showSlot(a: Bool) {
        slotViewA.alpha = a ? 1 : 0
        slotViewB.alpha = a ? 0 : 1
    }

    // MARK: - Debug: Thermal Badge

    #if DEBUG
    private func startThermalBadgeUpdates() {
        Task { @MainActor [weak self] in
            for await _ in ThermalGovernor.shared.stateStream() {
                guard let self else { break }
                let rate  = ThermalGovernor.shared.targetStrobeRate
                let state = ThermalGovernor.shared.thermalState.debugDescription
                self.thermalBadge.text = " \(rate)Hz · \(state) "
            }
        }
    }
    #endif
}

// MARK: - SwiftUI Preview

#Preview {
    StroboscopicA_B_View(
        imageA: UIImage(systemName: "photo.fill"),
        imageB: UIImage(systemName: "photo"),
        strobeSwapRate: 4
    ) { showingA in
        print("Slot activo: \(showingA ? "A" : "B")")
    }
    .ignoresSafeArea()
    .background(.black)
}
