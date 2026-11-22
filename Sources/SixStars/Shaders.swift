let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4 camPos;
    float2 viewport;
    float time;
    float debug;
};

struct LineIn {
    packed_float3 pos;
    uint color;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut lineVertex(uint vid [[vertex_id]],
                          const device LineIn* verts [[buffer(0)]],
                          constant Uniforms& u [[buffer(1)]]) {
    LineIn v = verts[vid];
    LineOut o;
    o.position = u.viewProj * float4(float3(v.pos), 1.0);
    float dist = distance(float3(v.pos), u.camPos.xyz);
    float4 c = unpack_unorm4x8_to_float(v.color);
    c.a *= clamp(1.0 - dist / 30000.0, 0.15, 1.0);
    o.color = c;
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    return in.color;
}

struct MeshVertexIn {
    packed_float3 pos;
    uint normal;
    float2 uv;
    uint uv1;
    uint c0;
    uint c1;
    uint material;
};

struct InstanceData {
    float4 r0;
    float4 r1;
    float4 r2;
    float4 fade;
};

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
    float2 uv1;
    float4 c0;
    float4 c1;
    uint material [[flat]];
    float2 fade [[flat]];
};

struct Material {
    uint diffuse[4];
    uint normal[4];
    uint kind;
    uint scheme;
    uint flags;
    uint layers;
    uint spec;
};

struct TexTable {
    array<texture2d<float>, 400000> t;
};

vertex MeshOut meshVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device MeshVertexIn* verts [[buffer(0)]],
                          constant Uniforms& u [[buffer(1)]],
                          const device InstanceData* inst [[buffer(2)]]) {
    MeshVertexIn v = verts[vid];
    InstanceData m = inst[iid];
    float4 p = float4(float3(v.pos), 1.0);
    float3 w = float3(dot(m.r0, p), dot(m.r1, p), dot(m.r2, p));
    float3 n = unpack_unorm10a2_to_float(v.normal).xyz * 2.0 - 1.0;
    float3 c0 = float3(m.r0.x, m.r1.x, m.r2.x), c1 = float3(m.r0.y, m.r1.y, m.r2.y), c2 = float3(m.r0.z, m.r1.z, m.r2.z);
    float3x3 cof = float3x3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
    float det = dot(c0, cross(c1, c2));
    MeshOut o;
    o.position = u.viewProj * float4(w, 1.0);
    o.world = w;
    o.normal = (cof * n) * (det < 0.0 ? -1.0 : 1.0);
    o.uv = v.uv;
    o.uv1 = float2(as_type<half2>(v.uv1));
    o.c0 = unpack_unorm4x8_to_float(v.c0);
    o.c1 = unpack_unorm4x8_to_float(v.c1);
    o.material = v.material;
    o.fade = m.fade.xy;
    return o;
}

static void lodFade(float2 fade, float2 pixel, float time) {
    if (fade.y == 0.0) return;
    float a = fade.y > 1.5 ? fade.x : saturate((time - fade.x) / 0.6);
    float nz = fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
    bool keep = fade.y < -0.5 ? nz >= a : nz < a;
    if (!keep) discard_fragment();
}

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    QuadOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 quadFragment(QuadOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float& lod [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, mip_filter::nearest, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv, level(lod));
    return float4(c.rgb, 1.0);
}

static float4 layerWeights(uint scheme, float4 c1) {
    if (scheme == 1) return float4(saturate(1.0 - c1.r - c1.g - c1.b), c1.r, c1.g, c1.b);
    if (scheme == 2) return float4(1.0 - c1.b, c1.b, 0.0, 0.0);
    if (scheme == 3) return float4(1.0 - c1.r, c1.r, 0.0, 0.0);
    return float4(1.0, 0.0, 0.0, 0.0);
}

static float3 perturbNormal(float3 N, float3 p, float2 uv, float3 tn) {
    float3 dp1 = dfdx(p), dp2 = dfdy(p);
    float2 duv1 = dfdx(uv), duv2 = dfdy(uv);
    float3 dp2perp = cross(dp2, N), dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;
    float m = max(dot(T, T), dot(B, B));
    if (m < 1e-20) return N;
    float invmax = rsqrt(m);
    return normalize(T * invmax * tn.x - B * invmax * tn.y + N * tn.z);
}

fragment float4 meshFragment(MeshOut in [[stage_in]], constant Uniforms& u [[buffer(1)]],
                             device const Material* mats [[buffer(3)]], device const TexTable& tt [[buffer(4)]],
                             constant uint& pickGroup [[buffer(5)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    Material m = mats[in.material];
    lodFade(in.fade, in.position.xy, u.time);
    if (u.debug > 1.5) {
        uint id = u.debug > 2.5 ? pickGroup : in.material;
        return float4(float(id & 63u) * 4.0 / 255.0, float((id >> 6) & 63u) * 4.0 / 255.0, float((id >> 12) & 63u) * 4.0 / 255.0, 1.0);
    }
    float2 gx = dfdx(in.uv), gy = dfdy(in.uv);
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 N = normalize(in.normal);
    if (dot(N, V) < 0.0) N = -N;
    float dist = distance(in.world, u.camPos.xyz);
    float3 skyColor = float3(0.237, 0.349, 0.516);
    float fog = 1.0 - exp(-dist / 9000.0);
    if (m.kind == 4) {
        float fr = pow(1.0 - saturate(dot(N, V)), 4.0);
        float3 c = mix(float3(0.02, 0.07, 0.10), skyColor * 1.1, 0.25 + 0.65 * fr);
        return float4(mix(c, skyColor, fog * 0.85), 0.75);
    }
    float4 w = layerWeights(m.scheme, in.c1);
    w /= max(w.x + w.y + w.z + w.w, 1e-4);
    float4 albedo = float4(0.0);
    float3 tn = float3(0.0);
    bool useNormal = (m.flags & 16u) != 0u;
    uint layers = min(m.layers, 4u);
    for (uint k = 0; k < layers; k++) {
        float wk = w[k];
        if (wk < 0.004) continue;
        albedo += tt.t[m.diffuse[k]].sample(s, in.uv, gradient2d(gx, gy)) * wk;
        if (useNormal) {
            float2 nxy = tt.t[m.normal[k]].sample(s, in.uv, gradient2d(gx, gy)).rg * 2.0 - 1.0;
            tn += float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy)))) * wk;
        }
    }
    float alpha = 1.0;
    if ((m.flags & 32u) != 0u) alpha = albedo.a;
    if ((m.flags & 2u) != 0u) alpha *= in.c0.a;
    if ((m.flags & 8u) != 0u) {
        if (albedo.a < 0.5) discard_fragment();
        alpha = 1.0;
    }
    if ((m.kind == 2u || m.kind == 3u) && alpha < 0.01) discard_fragment();
    if (u.debug > 0.5 && m.diffuse[0] == 0u) return float4(1.0, 1.0, 0.0, 1.0);
    if (useNormal && dot(tn, tn) > 1e-6) N = perturbNormal(N, in.world, in.uv, normalize(tn));
    float ao = (m.flags & 1u) != 0u ? mix(0.3, 1.0, in.c0.r) : 1.0;
    if (u.debug < -0.5) {
        float lum = 0.35 + 0.65 * dot(albedo.rgb, float3(0.3, 0.6, 0.1));
        if (u.debug < -5.5) {
            const float3 lc[7] = { float3(0.1, 0.9, 0.1), float3(1.0, 0.9, 0.1), float3(1.0, 0.5, 0.0), float3(1.0, 0.1, 0.1), float3(0.9, 0.1, 0.9), float3(0.1, 0.9, 0.9), float3(1.0, 1.0, 1.0) };
            return float4(lc[min(pickGroup, 6u)] * lum, 1.0);
        }
        if (u.debug < -4.5) {
            const float3 kc[6] = { float3(0.6), float3(0.1, 0.8, 0.1), float3(1.0, 0.5, 0.0), float3(0.1, 0.9, 0.9), float3(0.1, 0.2, 1.0), float3(1.0, 0.0, 0.0) };
            return float4(kc[min(m.kind, 5u)] * lum, 1.0);
        }
        if (u.debug > -1.5) return float4(albedo.rgb, 1.0);
        if (u.debug > -2.5) return float4(in.c0.rgb, 1.0);
        if (u.debug > -3.5) return float4(N * 0.5 + 0.5, 1.0);
        return float4(normalize(in.normal) * 0.5 + 0.5, 1.0);
    }
    float3 L = normalize(float3(0.45, 0.3, 0.75));
    float ndl = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 40.0) * 0.08 * ndl;
    float3 skyAmb = mix(float3(0.11, 0.10, 0.09), float3(0.22, 0.27, 0.35), 0.5 + 0.5 * N.z) * ao;
    float3 sunC = float3(1.0, 0.95, 0.86);
    float3 c = albedo.rgb * (skyAmb + sunC * ndl * mix(0.6, 1.0, ao)) + sunC * spec * ao;
    if ((m.flags & 4u) != 0u) c += albedo.rgb * 0.45;
    return float4(mix(c, skyColor, fog * 0.85), alpha);
}
"""
