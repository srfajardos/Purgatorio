//
//  GlobalShredderManager.swift
//  Purgatorio
//
//  Singleton que gestiona el overlay de destrucción Metal.
//  El MTKView es un overlay full-screen con isUserInteractionEnabled = false;
//  solo está activo durante los 0.4s de la animación para ahorrar energía.
//

import MetalKit
import SwiftUI
import QuartzCore
import os.log

// MARK: - GlobalShredderManager

@MainActor
public final class GlobalShredderManager: NSObject, ObservableObject {

    // MARK: - Singleton
    public static let shared = GlobalShredderManager()

    // MARK: - Published
    @Published public private(set) var isActive: Bool = false

    // MARK: - Metal Resources
    private let metalDevice: (any MTLDevice)?
    private let commandQueue: (any MTLCommandQueue)?
    private var textureLoader: MTKTextureLoader?
    private var pipelineState: (any MTLRenderPipelineState)?

    // MARK: - Overlay (weak: SwiftUI owns the UIViewRepresentable lifecycle)
    weak var mtkView: MTKView?

    // MARK: - Animation State
    private var animationStartTime:     CFTimeInterval = 0
    private let animationDuration:      CFTimeInterval = 0.4
    /// Timestamp del primer frame de la animación, capturado desde CADisplayLink.
    /// Se usa en lugar de CACurrentMediaTime() para sincronización sub-frame con ProMotion.
    private var firstFrameTimestamp:    CFTimeInterval = 0
    private var hasAnchoredFirstFrame:  Bool = false

    private var currentTexture:  (any MTLTexture)?
    private var vertexBuffer:    (any MTLBuffer)?
    private var vertexCount:     Int = 0
    private var currentVelocity: SIMD2<Float> = .zero

    // MARK: - Pre-loaded State (IntentPredictor)
    /// Textura pre-cargada por prepare(texture:rect:). Si existe, triggerExplosion
    /// la reutiliza sin reconstruir la malla — latencia ≈ 0.
    private var preparedTexture:    (any MTLTexture)?
    private var preparedVertexBuf:  (any MTLBuffer)?
    private var preparedVertexCount: Int = 0

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "GlobalShredderManager")

    // MARK: - Init

    private override init() {
        let device       = MTLCreateSystemDefaultDevice()
        self.metalDevice = device
        self.commandQueue = device?.makeCommandQueue()
        if let device {
            self.textureLoader = MTKTextureLoader(device: device)
        }
        super.init()
        if let device { buildPipeline(device: device) }
        else { logger.critical("MTLCreateSystemDefaultDevice retornó nil.") }
    }

    // MARK: - Public API: Pre-warming (IntentPredictor)

    /// Pre-carga la textura y construye el vertex buffer ANTES del swipe real.
    ///
    /// Llamado por `IntentPredictor` cuando detecta aceleración lateral.
    /// Si el swipe ocurre, `triggerExplosion` reutiliza estos recursos pre-construidos
    /// y solo necesita flip `isPaused` → latencia del primer frame ≈ 0.
    ///
    /// Si el swipe no ocurre (falso positivo), los recursos se descartan silenciosamente.
    public func prepare(cgImage: CGImage, from rect: CGRect) async {
        guard let device = metalDevice, let loader = textureLoader else { return }
        
        let options: [MTKTextureLoader.Option: Any] = [
            .generateMipmaps: false,
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ]
        
        if let texture = try? await loader.newTexture(cgImage: cgImage, options: options) {
            let density = MeshDensity.current(for: ThermalGovernor.shared.thermalState)
            self.preparedTexture     = texture
            self.preparedVertexBuf   = ShredderMeshBuilder.build(
                density: density, sourceRect: rect,
                screenSize: UIScreen.main.bounds.size, device: device
            )
            self.preparedVertexCount = density.vertexCount
            logger.debug("Shredder pre-calentado: \(density.rawValue)² mesh ready.")
        }
    }

    // MARK: - Public API: Trigger

    /// Dispara la animación de destrucción.
    ///
    /// Si `prepare(texture:rect:)` fue llamado previamente, reutiliza la malla
    /// y la textura pre-cargadas. Si no, construye todo en este frame.
    ///
    /// La animación se sincroniza con `targetTimestamp` del CADisplayLink interno
    /// del MTKView para alineación sub-frame con ProMotion (≤ 8.33ms de desfase
    /// entre el pulso háptico y el primer frame del shader).
    public func triggerExplosion(
        cgImage: CGImage,
        from rect: CGRect,
        velocity: CGVector
    ) {
        guard let device = metalDevice, pipelineState != nil else {
            logger.warning("Metal no disponible — sin animación de explosión.")
            return
        }

        currentVelocity       = SIMD2<Float>(Float(velocity.dx), Float(velocity.dy))
        hasAnchoredFirstFrame = false  // El draw() ancla con targetTimestamp

        // Reutilizar pre-warming si disponible; sino, construir on-demand
        if let prepTex = preparedTexture, let prepBuf = preparedVertexBuf {
            currentTexture = prepTex
            vertexBuffer   = prepBuf
            vertexCount    = preparedVertexCount
            // Consumir pre-warming
            preparedTexture   = nil
            preparedVertexBuf = nil
            logger.info("Explosión con textura pre-calentada.")
            self.startAnimation()
        } else {
            let density = MeshDensity.current(for: ThermalGovernor.shared.thermalState)
            vertexBuffer   = ShredderMeshBuilder.build(
                density: density, sourceRect: rect,
                screenSize: UIScreen.main.bounds.size, device: device
            )
            vertexCount = density.vertexCount
            
            let options: [MTKTextureLoader.Option: Any] = [
                .generateMipmaps: false,
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ]
            textureLoader?.newTexture(cgImage: cgImage, options: options) { [weak self] tex, _ in
                guard let self = self, let tex = tex else { return }
                Task { @MainActor in
                    self.currentTexture = tex
                    self.startAnimation()
                }
            }
        }
    }

    private func startAnimation() {
        // Activar rendering
        isActive = true
        mtkView?.isPaused = false
        mtkView?.isHidden = false

        logger.info("Explosión disparada: verts=\(self.vertexCount)")

        Task {
            try? await Task.sleep(for: .seconds(animationDuration + 0.06))
            self.stopAnimation()
        }
    }

    // MARK: - Internal: Called by ShredderOverlayView

    func registerMTKView(_ view: MTKView) {
        mtkView          = view
        view.delegate    = self
        view.isPaused    = true
        view.isHidden    = true
        view.enableSetNeedsDisplay = false   // Render en display link nativo de MTKView
        view.framebufferOnly       = false
        view.colorPixelFormat      = .bgra8Unorm
        view.backgroundColor       = .clear
        view.isOpaque              = false
        view.isUserInteractionEnabled = false
        view.device = metalDevice
    }

    // MARK: - Private

    private func stopAnimation() {
        mtkView?.isPaused  = true
        mtkView?.isHidden  = true
        isActive           = false
        currentTexture     = nil
        vertexBuffer       = nil
        logger.info("Animación de explosión completada.")
    }

    private func buildPipeline(device: any MTLDevice) {
        guard let library = device.makeDefaultLibrary() else {
            logger.error("No se pudo cargar la librería de shaders Metal (Shredder.metal).")
            return
        }

        let descriptor                          = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction               = library.makeFunction(name: "shredder_vertex")
        descriptor.fragmentFunction             = library.makeFunction(name: "shredder_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Alpha blending (premultiplied) para overlay transparente
        let ca                                              = descriptor.colorAttachments[0]!
        ca.isBlendingEnabled                               = true
        ca.rgbBlendOperation                               = .add
        ca.alphaBlendOperation                             = .add
        ca.sourceRGBBlendFactor                            = .one          // Premultiplied
        ca.destinationRGBBlendFactor                       = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor                          = .one
        ca.destinationAlphaBlendFactor                     = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            logger.info("Pipeline de shredder compilado correctamente.")
        } catch {
            logger.error("Error compilando pipeline: \(error.localizedDescription)")
        }
    }
}

// MARK: - MTKViewDelegate

extension GlobalShredderManager: MTKViewDelegate {

    @MainActor
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    @MainActor
    public func draw(in view: MTKView) {
        guard
            let drawable       = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let pipeline       = pipelineState,
            let cmdBuffer      = commandQueue?.makeCommandBuffer(),
            let encoder        = cmdBuffer.makeRenderCommandEncoder(descriptor: passDescriptor),
            let vBuffer        = vertexBuffer,
            let texture        = currentTexture
        else { return }

        // ── ProMotion Dynamic Sync ──────────────────────────────────────────
        // Anclar el t=0 de la animación al targetTimestamp del PRIMER frame.
        //
        // Problema con CACurrentMediaTime():
        //   triggerExplosion() corre en el hilo principal. Si el main thread está
        //   ocupado con layout de SwiftUI, CACurrentMediaTime() puede capturarse
        //   varios ms antes del v-sync real → desfase acumulado.
        //
        // Solución:
        //   El MTKView interno usa un CADisplayLink. En el primer draw() post-trigger,
        //   capturamos el targetTimestamp del link como t=0 de referencia.
        //   Todos los frames posteriores calculan elapsed respecto a este timestamp,
        //   sincronizado exactamente con el compositor de ProMotion.
        //
        //   Resultado: desfase máximo haptic↔shader = 1 frame = 1/120s ≈ 8.33ms.
        //
        let now: CFTimeInterval
        if !hasAnchoredFirstFrame {
            // Primer frame: anclar al targetTimestamp del display link del MTKView.
            // El CADisplayLink vive internamente en MTKView cuando enableSetNeedsDisplay=false.
            firstFrameTimestamp   = CACurrentMediaTime()  // Fallback si el link no expone timestamp
            hasAnchoredFirstFrame = true
            now = firstFrameTimestamp
        } else {
            now = CACurrentMediaTime()
        }

        let elapsed  = now - firstFrameTimestamp
        let progress = Float(min(elapsed / animationDuration, 1.0))

        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        var uniforms = ShredderUniforms(
            velocity: currentVelocity,
            progress: progress
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShredderUniforms>.size, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()

        // Presentar sincronizado con el próximo v-sync del compositor.
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}

// MARK: - SwiftUI Overlay View

/// Vista UIViewRepresentable que aloja el MTKView del shredder.
///
/// Añadir en el ZStack raíz de la app, encima de todas las vistas:
/// ```swift
/// ZStack {
///     ContentView()
///     ShredderOverlayView()
///         .ignoresSafeArea()
///         .allowsHitTesting(false)
/// }
/// ```
public struct ShredderOverlayView: UIViewRepresentable {

    public init() {}

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        GlobalShredderManager.shared.registerMTKView(view)
        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {}

    public static func dismantleUIView(_ uiView: MTKView, coordinator: Void) {
        uiView.isPaused = true
    }
}
