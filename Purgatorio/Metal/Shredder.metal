//
//  Shredder.metal
//  Purgatorio
//
//  Shader de destrucción física. Malla pre-triangulada de shards que vuelan,
//  rotan y se desvanecen durante 0.4 segundos.
//

#include <metal_stdlib>
using namespace metal;

struct ShredderVertex {
    float2 position;      // NDC original del vértice
    float2 texCoord;      // UV para muestrear la textura
    float2 shardCenter;   // Centro NDC del shard al que pertenece
    float  shardAngle;    // Ángulo único del shard (distribución dorada)
};

struct ShredderUniforms {
    float2 velocity;      // Dirección del swipe normalizada [-1…+1]
    float  progress;      // Progreso de la animación: 0.0 → 1.0
    float  _padding;
};

struct ShredderVaryings {
    float4 clipPosition [[position]];
    float2 texCoord;
    float  alpha;
};

// --- Easing ---

inline float easeOut3(float t) { return 1.0 - pow(1.0 - t, 3.0); }
inline float easeIn2(float t)  { return t * t; }
inline float smoothstep01(float t) { return t * t * (3.0 - 2.0 * t); }

// --- Vertex Shader ---

vertex ShredderVaryings shredder_vertex(
    const device ShredderVertex* vertices [[buffer(0)]],
    constant ShredderUniforms&   uniforms [[buffer(1)]],
    uint                         vid      [[vertex_id]]
) {
    ShredderVaryings out;
    ShredderVertex   v = vertices[vid];
    float            p = saturate(uniforms.progress);

    // 1. Dirección de vuelo: ángulo único del shard + sesgo del swipe
    float2 shardDir = float2(cos(v.shardAngle), sin(v.shardAngle));
    float2 flyDir   = normalize(shardDir + uniforms.velocity * 0.65);

    // 2. Desplazamiento translacional (burst + drift)
    float2 translate  = flyDir * easeOut3(p) * 1.8;
    translate.y      -= easeIn2(p) * 1.2;   // Gravedad (Y+ = arriba en NDC)

    // 3. Rotación alrededor del centro del shard
    float  rotAngle = v.shardAngle * 0.2 + p * (1.0 + abs(sin(v.shardAngle * 3.7))) * 4.0;
    float  cosA     = cos(rotAngle);
    float  sinA     = sin(rotAngle);
    float2 localPos = (v.position - v.shardCenter) * (1.0 - easeOut3(p) * 0.9);
    float2 rotated  = float2(localPos.x * cosA - localPos.y * sinA,
                              localPos.x * sinA + localPos.y * cosA);

    // 4. Posición final
    out.clipPosition = float4(v.shardCenter + translate + rotated, 0.0, 1.0);
    out.texCoord     = v.texCoord;

    // 5. Alpha: opaco los primeros 15%, fade-out hasta 0 en progress=1
    float fadeT      = saturate((p - 0.15) / 0.85);
    out.alpha        = 1.0 - smoothstep01(fadeT);
    return out;
}

// --- Fragment Shader ---

fragment float4 shredder_fragment(
    ShredderVaryings         in  [[stage_in]],
    texture2d<float>         tex [[texture(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    float4 color  = tex.sample(s, in.texCoord);
    color.a      *= in.alpha;
    color.rgb    *= in.alpha;   // Premultiplied alpha
    return color;
}
