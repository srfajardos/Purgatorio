//
//  ShredderMeshBuilder.swift
//  Purgatorio
//
//  Construye el vertex buffer de la malla de triángulos para el shader de destrucción.
//  La densidad se selecciona en función del ThermalGovernor para proteger la CPU/GPU.
//

import Metal
import UIKit

// MARK: - Vertex Layout (debe coincidir byte-a-byte con ShredderVertex en Shredder.metal)

struct ShredderVertex {
    var position:    SIMD2<Float>  // NDC (-1…+1)
    var texCoord:    SIMD2<Float>  // UV  (0…1)
    var shardCenter: SIMD2<Float>  // Centro NDC del shard
    var shardAngle:  Float         // Ángulo pseudo-aleatorio del shard
}

struct ShredderUniforms {
    var velocity: SIMD2<Float>     // Dirección del swipe normalizada
    var progress: Float            // 0.0 → 1.0
    var _padding: Float = 0        // Alineación a 16 bytes
}

// MARK: - MeshDensity

enum MeshDensity: Int {
    case high   = 100   // nominal / fair:   100×100 = 20,000 triángulos
    case medium = 40    // serious:           40×40  =  3,200 triángulos
    case low    = 10    // critical / SwiftUI fallback: 10×10 = 200

    static func current(for thermalState: ProcessInfo.ThermalState) -> MeshDensity {
        switch thermalState {
        case .nominal, .fair: return .high
        case .serious:        return .medium
        case .critical:       return .low
        @unknown default:     return .medium
        }
    }

    var vertexCount: Int { rawValue * rawValue * 6 }
}

// MARK: - ShredderMeshBuilder

enum ShredderMeshBuilder {

    /// Construye un `MTLBuffer` con la malla de triángulos de la foto destruida.
    ///
    /// - Parameters:
    ///   - density: Densidad de la malla (filas × columnas de celdas).
    ///   - sourceRect: Frame global de la carta en coordenadas de pantalla.
    ///   - screenSize: Tamaño total de la pantalla.
    ///   - device: `MTLDevice` del sistema.
    static func build(
        density: MeshDensity,
        sourceRect: CGRect,
        screenSize: CGSize,
        device: MTLDevice
    ) -> MTLBuffer? {
        let verts = buildVertices(n: density.rawValue, rect: sourceRect, screen: screenSize)
        let byteCount = verts.count * MemoryLayout<ShredderVertex>.stride
        return device.makeBuffer(bytes: verts, length: byteCount, options: .storageModeShared)
    }

    // MARK: - Private

    private static func buildVertices(n: Int, rect: CGRect, screen: CGSize) -> [ShredderVertex] {
        var vertices: [ShredderVertex] = []
        vertices.reserveCapacity(n * n * 6)

        let cellW = rect.width  / CGFloat(n)
        let cellH = rect.height / CGFloat(n)

        // Distribución de ángulos: espiral dorada → ningún par de shards vuela igual
        let goldenAngle: Float = 2.399963  // radianes

        for row in 0 ..< n {
            for col in 0 ..< n {
                let shardID = row * n + col

                // Esquinas del quad en coordenadas de pantalla
                let x0 = rect.minX + CGFloat(col) * cellW
                let y0 = rect.minY + CGFloat(row) * cellH
                let x1 = x0 + cellW
                let y1 = y0 + cellH

                let tl = CGPoint(x: x0, y: y0)
                let tr = CGPoint(x: x1, y: y0)
                let bl = CGPoint(x: x0, y: y1)
                let br = CGPoint(x: x1, y: y1)

                let center     = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                let centerNDC  = toNDC(center, screen: screen)
                let angle      = Float(shardID) * goldenAngle

                // Tri 1: TL-TR-BL
                vertices.append(makeVertex(tl, center: centerNDC, angle: angle, rect: rect, screen: screen))
                vertices.append(makeVertex(tr, center: centerNDC, angle: angle, rect: rect, screen: screen))
                vertices.append(makeVertex(bl, center: centerNDC, angle: angle, rect: rect, screen: screen))
                // Tri 2: TR-BR-BL
                vertices.append(makeVertex(tr, center: centerNDC, angle: angle, rect: rect, screen: screen))
                vertices.append(makeVertex(br, center: centerNDC, angle: angle, rect: rect, screen: screen))
                vertices.append(makeVertex(bl, center: centerNDC, angle: angle, rect: rect, screen: screen))
            }
        }
        return vertices
    }

    private static func makeVertex(
        _ p: CGPoint,
        center: SIMD2<Float>,
        angle: Float,
        rect: CGRect,
        screen: CGSize
    ) -> ShredderVertex {
        ShredderVertex(
            position:    toNDC(p, screen: screen),
            texCoord:    toUV(p, rect: rect),
            shardCenter: center,
            shardAngle:  angle
        )
    }

    /// Pantalla → NDC Metal. Y se invierte: arriba en pantalla = +1 en NDC.
    private static func toNDC(_ p: CGPoint, screen: CGSize) -> SIMD2<Float> {
        SIMD2<Float>(
            Float(p.x / screen.width  * 2.0 - 1.0),
            Float(1.0 - p.y / screen.height * 2.0)
        )
    }

    /// Pantalla → coordenadas UV relativas al rect de la carta.
    private static func toUV(_ p: CGPoint, rect: CGRect) -> SIMD2<Float> {
        SIMD2<Float>(
            Float((p.x - rect.minX) / rect.width),
            Float((p.y - rect.minY) / rect.height)
        )
    }
}
