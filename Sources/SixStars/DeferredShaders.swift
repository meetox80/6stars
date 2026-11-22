let deferredShaderSource = """

struct GBOut {
    float4 albedo [[color(0)]];
    float4 normal [[color(1)]];
    float4 material [[color(2)]];
    float4 emissive [[color(3)]];
};

constant bool gbDiscardValue [[function_constant(0)]];
constant bool gbDiscard = is_function_constant_defined(gbDiscardValue) ? gbDiscardValue : true;

fragment GBOut meshGBuffer(MeshOut in [[stage_in]], constant Uniforms& u [[buffer(1)]],
                           device const Material* mats [[buffer(3)]], device const TexTable& tt [[buffer(4)]],
                           constant Atmos& a [[buffer(6)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    Material m = mats[in.material];
    if (gbDiscard) lodFade(in.fade, in.position.xy, u.time);
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 N = normalize(in.normal);
    if (dot(N, V) < 0.0) N = -N;
    float2 gx = dfdx(in.uv), gy = dfdy(in.uv);
    float4 w = layerWeights(m.scheme, in.c1);
    w /= max(w.x + w.y + w.z + w.w, 1e-4);
    float4 albedo = float4(0.0);
    float3 tn = float3(0.0);
    bool useNormal = (m.flags & 16u) != 0u;
    uint layers = min(m.layers, 4u);
    for (uint k = 0; k < layers; k++) {
        float wk = w[k];
        if (wk < 0.004) continue;
        bool second = ((m.flags >> (6u + k)) & 1u) != 0u;
        float2 luv = second ? in.uv1 : in.uv;
        float2 lgx = second ? dfdx(in.uv1) : gx, lgy = second ? dfdy(in.uv1) : gy;
        albedo += tt.t[m.diffuse[k]].sample(s, luv, gradient2d(lgx, lgy)) * wk;
        if (useNormal) {
            float2 nxy = tt.t[m.normal[k]].sample(s, luv, gradient2d(lgx, lgy)).rg * 2.0 - 1.0;
            tn += float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy)))) * wk;
        }
    }
    float alpha = 1.0;
    if ((m.flags & 32u) != 0u) alpha = albedo.a;
    if ((m.flags & 256u) != 0u) {
        float dsd = tt.t[m.diffuse[1]].sample(s, in.uv).r;
        float fw = max(fwidth(dsd), 1e-3);
        alpha = smoothstep(0.5 - fw, 0.5 + fw, dsd);
    }
    if ((m.flags & 2u) != 0u) alpha *= in.c0.a;
    if ((m.flags & 8u) != 0u) {
        if (gbDiscard && albedo.a < 0.5) discard_fragment();
        alpha = 1.0;
    }
    if (gbDiscard && m.kind == 2u && alpha < 0.01) discard_fragment();
    if (useNormal && dot(tn, tn) > 1e-6) N = perturbNormal(N, in.world, in.uv, normalize(tn));
    float ao = (m.flags & 1u) != 0u ? mix(0.3, 1.0, in.c0.r) : 1.0;
    float4 sp = m.spec != 0u ? tt.t[m.spec].sample(s, in.uv, gradient2d(gx, gy)) : float4(0.0, 0.6, 1.0, 1.0);
    GBOut o;
    o.albedo = float4(albedo.rgb, alpha);
    o.normal = float4(N * 0.5 + 0.5, 1.0);
    o.material = float4(0.5 * sp.b, 1.0 - sp.g, sp.r, ao);
    o.emissive = float4((m.flags & 4u) != 0u ? albedo.rgb * a.misc.z : float3(0.0), alpha);
    return o;
}

static float3 worldFromDepth(float2 uv, float d, constant Atmos& a) {
    float3 rd = viewRay(uv, a);
    float fwd = a.misc.w / max(d, 1e-9);
    return a.camPos.xyz + rd * (fwd / max(dot(rd, a.camFwd.xyz), 1e-4));
}

struct IndirectParams {
    float4x4 prevVP;
    float4 info;
};

struct IndirectOut {
    float4 gi [[color(0)]];
    float4 refl [[color(1)]];
};

static float2 projectUV(float3 p, float4x4 vp, thread float& z, thread bool& front) {
    float4 c = vp * float4(p, 1.0);
    front = c.w > 1e-4;
    z = c.z / max(c.w, 1e-4);
    return float2(c.x / max(c.w, 1e-4) * 0.5 + 0.5, 0.5 - c.y / max(c.w, 1e-4) * 0.5);
}

static bool traceScreen(float3 P, float3 dir, float maxDist, int steps, float jitter, constant Atmos& a,
                        depth2d<float> depth, thread float3& hitP, thread float2& hitUV) {
    constexpr sampler ds(filter::nearest, address::clamp_to_edge);
    for (int i = 0; i < steps; i++) {
        float s = (float(i) + jitter) / float(steps);
        float t = maxDist * s * s;
        float3 q = P + dir * t;
        float zq;
        bool front;
        float2 uv = projectUV(q, a.viewProj, zq, front);
        if (!front || any(uv < float2(0.0)) || any(uv > float2(1.0))) return false;
        float zs = depth.sample(ds, uv);
        if (zs > zq && zs > 0.0) {
            float3 S = worldFromDepth(uv, zs, a);
            float behind = distance(a.camPos.xyz, q) - distance(a.camPos.xyz, S);
            if (behind < max(0.35, t * 0.12)) {
                float sp = float(max(i, 1) - 1) + jitter;
                float lo = maxDist * (sp / float(steps)) * (sp / float(steps)), hi = t;
                float2 buv = uv;
                float bz = zs;
                for (int k = 0; k < 5; k++) {
                    float tm = 0.5 * (lo + hi);
                    float3 qm = P + dir * tm;
                    float zm;
                    bool fm;
                    float2 um = projectUV(qm, a.viewProj, zm, fm);
                    float zsm = depth.sample(ds, um);
                    if (zsm > zm && zsm > 0.0) { hi = tm; buv = um; bz = zsm; } else { lo = tm; }
                }
                hitP = worldFromDepth(buv, bz, a);
                hitUV = buv;
                return true;
            }
        }
    }
    return false;
}

fragment IndirectOut indirectFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], constant IndirectParams& ip [[buffer(1)]],
                                      texture2d<float> prevHdr [[texture(7)]], texture2d<float> gb1 [[texture(9)]],
                                      texture2d<float> gb2 [[texture(10)]], depth2d<float> depth [[texture(11)]]) {
    IndirectOut o;
    o.gi = float4(0.0);
    o.refl = float4(0.0);
    constexpr sampler ns(filter::nearest, address::clamp_to_edge);
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float d = depth.sample(ns, in.uv);
    if (d <= 0.0 || ip.info.x < 0.5) return o;
    float3 P = worldFromDepth(in.uv, d, a);
    float3 N = normalize(gb1.sample(ns, in.uv).xyz * 2.0 - 1.0);
    float rough = 1.0 - gb2.sample(ns, in.uv).g;
    float3 V = normalize(a.camPos.xyz - P);
    if (dot(N, V) < 0.0) N = -N;
    float dist = distance(P, a.camPos.xyz);
    float3 Pb = P + N * max(0.03, dist * 0.003);
    float2 px = in.position.xy + float2(ip.info.y * 5.588238, ip.info.y * 3.191);
    float n0 = fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));
    float n1 = fract(n0 * 7.31 + 0.137);
    float jitter = fract(n0 * 13.7 + ip.info.y * 0.618034);
    float3 T = normalize(abs(N.z) < 0.999 ? cross(N, float3(0.0, 0.0, 1.0)) : cross(N, float3(1.0, 0.0, 0.0)));
    float3 B = cross(N, T);
    float lumCap = max(a.sunDir.w * dot(a.sunColor.rgb, float3(0.2126, 0.7152, 0.0722)) * 0.35, 1e-3);
    if (ip.info.z > 0.0) {
        float3 acc = float3(0.0);
        float hits = 0.0;
        float giDist = clamp(dist * 0.12, 2.0, 30.0);
        for (int r = 0; r < 4; r++) {
            float u1 = fract(n0 + float(r) * 0.618034), u2 = fract(n1 + float(r) * 0.381966);
            float phi = 2.0 * PI_F * u2, st = sqrt(u1), ct = sqrt(1.0 - u1);
            float3 dir = normalize(T * (cos(phi) * st) + B * (sin(phi) * st) + N * ct);
            float3 hp;
            float2 huv;
            if (traceScreen(Pb, dir, giDist, 10, jitter, a, depth, hp, huv)) {
                float zp;
                bool front;
                float2 puv = projectUV(hp, ip.prevVP, zp, front);
                if (front && all(puv >= float2(0.0)) && all(puv <= float2(1.0))) {
                    float3 L = prevHdr.sample(ls, puv).rgb;
                    float lum = dot(L, float3(0.2126, 0.7152, 0.0722));
                    acc += L / (1.0 + lum / lumCap);
                    hits += 1.0;
                }
            }
        }
        o.gi = float4(acc * (PI_F / 4.0) * ip.info.z, hits / 4.0);
    }
    if (ip.info.w > 0.0 && rough < 0.8) {
        float3 R = reflect(-V, N);
        float ar = rough * rough;
        R = normalize(R + (T * (n0 - 0.5) + B * (n1 - 0.5)) * ar * 0.9);
        float3 hp;
        float2 huv;
        if (dot(R, N) > 0.0 && traceScreen(Pb, R, clamp(dist * 1.5, 12.0, 400.0), 28, jitter, a, depth, hp, huv)) {
            float zp;
            bool front;
            float2 puv = projectUV(hp, ip.prevVP, zp, front);
            if (front && all(puv >= float2(0.0)) && all(puv <= float2(1.0))) {
                float2 e = min(puv, 1.0 - puv);
                float edge = saturate(min(e.x, e.y) * 12.0);
                float fade = edge * saturate((0.8 - rough) * 4.0) * ip.info.w;
                float3 L = prevHdr.sample(ls, puv).rgb;
                o.refl = float4(L, fade);
            }
        }
    }
    return o;
}

fragment float ssaoFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]],
                            texture2d<float> gb1 [[texture(9)]], depth2d<float> depth [[texture(11)]]) {
    uint2 px = uint2(in.position.xy);
    float d = depth.read(px);
    if (d <= 0.0) return 1.0;
    float3 P = worldFromDepth(in.uv, d, a);
    float3 N = normalize(gb1.read(px).xyz * 2.0 - 1.0);
    float dist = distance(P, a.camPos.xyz);
    float radius = clamp(dist * 0.03, 0.25, 3.0);
    float2 size = float2(depth.get_width(), depth.get_height());
    float rnd = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
    float3 up = abs(N.z) < 0.99 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 T = normalize(cross(up, N));
    float3 B = cross(N, T);
    float occ = 0.0;
    const int S = 12;
    for (int i = 0; i < S; i++) {
        float fi = (float(i) + rnd) / float(S);
        float ang = fi * 2.0 * PI_F * 7.0 + rnd * 6.2831;
        float r = sqrt(fi);
        float z = sqrt(max(1.0 - r * r, 0.0));
        float3 dir = T * (cos(ang) * r) + B * (sin(ang) * r) + N * z;
        float scale = mix(0.15, 1.0, fi * fi);
        float3 Q = P + N * (radius * 0.04) + dir * (radius * scale);
        float4 c = a.viewProj * float4(Q, 1.0);
        if (c.w <= 0.0) continue;
        float2 suv = float2(c.x / c.w * 0.5 + 0.5, 0.5 - c.y / c.w * 0.5);
        if (any(suv < float2(0.0)) || any(suv > float2(1.0))) continue;
        float sd = depth.read(uint2(min(suv * size, size - 1.0)));
        if (sd <= 0.0) continue;
        float sceneFwd = a.misc.w / sd;
        float diff = c.w - sceneFwd;
        if (diff > 0.03) occ += saturate(radius / diff);
    }
    return saturate(1.0 - occ / float(S) * 1.2);
}

fragment float ssaoBlurFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]],
                                texture2d<float> raw [[texture(12)]], depth2d<float> depth [[texture(11)]]) {
    int2 px = int2(in.position.xy);
    int2 sz = int2(raw.get_width(), raw.get_height());
    float d0 = depth.read(uint2(px));
    if (d0 <= 0.0) return 1.0;
    float f0 = a.misc.w / d0;
    float sum = 0.0, wsum = 0.0;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            int2 q = clamp(px + int2(x, y), int2(0), sz - 1);
            float dq = depth.read(uint2(q));
            float fq = dq > 0.0 ? a.misc.w / dq : 1e9;
            float w = exp(-abs(fq - f0) / max(f0 * 0.02, 0.05));
            sum += raw.read(uint2(q)).r * w;
            wsum += w;
        }
    }
    return sum / max(wsum, 1e-4);
}

static float2 envBRDFApprox(float rough, float ndv) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r = rough * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * ndv)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

static void upsampleIndirect(texture2d<float> giTex, texture2d<float> reflTex, depth2d<float> depth, uint2 px, float d,
                             thread float4& gi, thread float4& rf) {
    int2 hs = int2(giTex.get_width(), giTex.get_height());
    int2 fs = int2(depth.get_width(), depth.get_height());
    float2 h = (float2(px) + 0.5) * 0.5 - 0.5;
    int2 b = int2(floor(h));
    float2 f = h - float2(b);
    float lz = 1.0 / max(d, 1e-9);
    float4 ga = float4(0.0), ra = float4(0.0);
    float wsum = 0.0;
    for (int y = 0; y <= 1; y++) {
        for (int x = 0; x <= 1; x++) {
            int2 q = clamp(b + int2(x, y), int2(0), hs - 1);
            float dq = depth.read(uint2(clamp(q * 2 + 1, int2(0), fs - 1)));
            float lq = 1.0 / max(dq, 1e-9);
            float bw = (x == 0 ? 1.0 - f.x : f.x) * (y == 0 ? 1.0 - f.y : f.y);
            float w = bw * exp(-abs(lq - lz) / (lz * 0.04)) + 1e-5 * bw;
            ga += giTex.read(uint2(q)) * w;
            ra += reflTex.read(uint2(q)) * w;
            wsum += w;
        }
    }
    gi = ga / max(wsum, 1e-8);
    rf = ra / max(wsum, 1e-8);
}

struct AccumOut {
    float4 gi [[color(0)]];
    float4 refl [[color(1)]];
};

fragment AccumOut indirectAccumFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], constant IndirectParams& ip [[buffer(1)]],
                                        texture2d<float> curGi [[texture(0)]], texture2d<float> curRefl [[texture(1)]],
                                        texture2d<float> histGi [[texture(2)]], texture2d<float> histRefl [[texture(3)]],
                                        depth2d<float> depth [[texture(11)]]) {
    AccumOut o;
    int2 p = int2(in.position.xy);
    int2 sz = int2(curGi.get_width(), curGi.get_height());
    float4 g = curGi.read(uint2(p)), r = curRefl.read(uint2(p));
    float4 gmin = g, gmax = g, rmin = r, rmax = r, gm = float4(0.0), rm = float4(0.0), gm2 = float4(0.0), rm2 = float4(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            uint2 q = uint2(clamp(p + int2(x, y), int2(0), sz - 1));
            float4 gq = curGi.read(q), rq = curRefl.read(q);
            gm += gq; gm2 += gq * gq; rm += rq; rm2 += rq * rq;
        }
    }
    gm /= 9.0; rm /= 9.0;
    float4 gs = sqrt(max(gm2 / 9.0 - gm * gm, 0.0)), rs = sqrt(max(rm2 / 9.0 - rm * rm, 0.0));
    gmin = gm - gs * 1.5; gmax = gm + gs * 1.5;
    rmin = rm - rs * 1.5; rmax = rm + rs * 1.5;
    constexpr sampler ns(filter::nearest, address::clamp_to_edge);
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float d = depth.sample(ns, in.uv);
    o.gi = g;
    o.refl = r;
    if (d <= 0.0 || ip.info.x < 0.5) return o;
    float3 P = worldFromDepth(in.uv, d, a);
    float zp;
    bool front;
    float2 puv = projectUV(P, ip.prevVP, zp, front);
    if (!front || any(puv < float2(0.0)) || any(puv > float2(1.0))) return o;
    float4 hg = clamp(histGi.sample(ls, puv), gmin, gmax);
    float4 hr = clamp(histRefl.sample(ls, puv), rmin, rmax);
    float alpha = ip.info.y;
    o.gi = mix(hg, g, alpha);
    o.refl = mix(hr, r, alpha);
    return o;
}

fragment float4 lightFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], constant float4* sh [[buffer(1)]],
                              constant ShadowData& sd [[buffer(2)]],
                              texture2d<float> trans [[texture(0)]], depth2d_array<float> sm [[texture(3)]],
                              texture2d<float> gb0 [[texture(8)]], texture2d<float> gb1 [[texture(9)]], texture2d<float> gb2 [[texture(10)]],
                              depth2d<float> depth [[texture(11)]], texture2d<float> ao [[texture(12)]], texturecube<float> env [[texture(13)]],
                              texture2d<float> giTex [[texture(14)]], texture2d<float> reflTex [[texture(15)]]) {
    uint2 px = uint2(in.position.xy);
    float d = depth.read(px);
    if (d <= 0.0) discard_fragment();
    float3 P = worldFromDepth(in.uv, d, a);
    float4 g0 = gb0.read(px), g1 = gb1.read(px), g2 = gb2.read(px);
    float3 albedo = g0.rgb;
    float3 N = normalize(g1.xyz * 2.0 - 1.0);
    float f0 = g2.r * 0.08, rough = 1.0 - g2.g, metal = g2.b;
    float occl = g2.a * ao.read(px).r;
    float3 V = normalize(a.camPos.xyz - P);
    float dist = distance(P, a.camPos.xyz);
    float3 sun = a.sunDir.xyz;
    float ndl = saturate(dot(N, sun));
    float shadow = ndl > 0.0 ? shadowFactor(P, N, dist, sd, sm) : 0.0;
    float3 Esun = sunIrradiance(trans, P, a) * shadow;
    float ndv = max(dot(N, V), 1e-3);
    float3 F0 = mix(float3(f0), albedo, metal);
    float3 diff = albedo * (1.0 - metal);
    float3 H = normalize(sun + V);
    float ndh = saturate(dot(N, H));
    float al = rough * rough * rough * rough;
    float dd = ndh * ndh * (al - 1.0) + 1.0;
    float D = al / (PI_F * dd * dd);
    float3 Fs = F0 + (1.0 - F0) * pow(1.0 - saturate(dot(V, H)), 5.0);
    float kk = (rough + 1.0) * (rough + 1.0) / 8.0;
    float G = 1.0 / ((ndl * (1.0 - kk) + kk) * (ndv * (1.0 - kk) + kk));
    float3 spec = Esun * Fs * (D * G * ndl / 4.0);
    float4 gi, rf;
    upsampleIndirect(giTex, reflTex, depth, px, d, gi, rf);
    float3 Eamb = shIrradiance(sh, N) * a.ambient.rgb * (1.0 - gi.a) + gi.rgb;
    constexpr sampler es(filter::linear, mip_filter::linear);
    float3 R = reflect(-V, N);
    float lod = rough * float(env.get_num_mip_levels() - 1);
    float3 pre = mix(env.sample(es, R, level(lod)).rgb, rf.rgb, rf.a);
    float2 ab = envBRDFApprox(rough, ndv);
    float specOcc = saturate(pow(ndv + occl, exp2(-16.0 * rough - 1.0)) - 1.0 + occl);
    float3 c = diff / PI_F * (Esun * ndl + Eamb * occl) * (1.0 - Fs) + spec + pre * (F0 * ab.x + ab.y) * specOcc;
    return float4(min(c, float3(HDR_MAX)), 1.0);
}

fragment float linearDepthFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], depth2d<float> depth [[texture(11)]]) {
    float d = depth.read(uint2(in.position.xy));
    if (d <= 0.0) return 0.0;
    return distance(worldFromDepth(in.uv, d, a), a.camPos.xyz);
}

struct SeedOut {
    float dist [[color(1)]];
};

fragment SeedOut seedFragment(QuadOut in [[stage_in]], texture2d<float> distc [[texture(7)]]) {
    SeedOut o;
    o.dist = distc.read(uint2(in.position.xy)).r;
    return o;
}

struct CubeParams {
    uint face;
    float roughness;
    float srcMips;
    float srcSize;
};

static float3 cubeDir(uint face, float2 uv) {
    float u = uv.x * 2.0 - 1.0, v = uv.y * 2.0 - 1.0;
    switch (face) {
        case 0: return normalize(float3(1.0, -v, -u));
        case 1: return normalize(float3(-1.0, -v, u));
        case 2: return normalize(float3(u, 1.0, v));
        case 3: return normalize(float3(u, -1.0, -v));
        case 4: return normalize(float3(u, -v, 1.0));
        default: return normalize(float3(-u, -v, -1.0));
    }
}

fragment float4 envFaceFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], constant float4* sh [[buffer(1)]],
                                constant CubeParams& cp [[buffer(2)]],
                                texture2d<float> trans [[texture(0)]], texture2d<float> ms [[texture(1)]], texture2d<float> sky [[texture(2)]]) {
    float3 d = cubeDir(cp.face, in.uv);
    float3 L = sampleSky(sky, d) * a.sunDisc.w;
    float cd;
    float4 cl = cloudMarch(a.camPos.xyz, d, in.position.xy, 24, a, sh, trans, ms, cd);
    L = L * cl.a + cl.rgb;
    return float4(min(L, float3(HDR_MAX)), 1.0);
}

static float2 hammersley(uint i, uint n) {
    uint b = (i << 16u) | (i >> 16u);
    b = ((b & 0x55555555u) << 1u) | ((b & 0xAAAAAAAAu) >> 1u);
    b = ((b & 0x33333333u) << 2u) | ((b & 0xCCCCCCCCu) >> 2u);
    b = ((b & 0x0F0F0F0Fu) << 4u) | ((b & 0xF0F0F0F0u) >> 4u);
    b = ((b & 0x00FF00FFu) << 8u) | ((b & 0xFF00FF00u) >> 8u);
    return float2(float(i) / float(n), float(b) * 2.3283064365386963e-10);
}

fragment float4 envPrefilterFragment(QuadOut in [[stage_in]], constant CubeParams& cp [[buffer(2)]], texturecube<float> src [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear);
    float3 N = cubeDir(cp.face, in.uv);
    float r = cp.roughness;
    if (r < 0.02) return float4(src.sample(s, N, level(0.0)).rgb, 1.0);
    float alpha = r * r;
    float3 up = abs(N.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 T = normalize(cross(up, N));
    float3 B = cross(N, T);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    const uint S = 64u;
    float saTexel = 4.0 * PI_F / (6.0 * cp.srcSize * cp.srcSize);
    for (uint i = 0u; i < S; i++) {
        float2 xi = hammersley(i, S);
        float phi = 2.0 * PI_F * xi.x;
        float ct = sqrt((1.0 - xi.y) / (1.0 + (alpha * alpha - 1.0) * xi.y));
        float st = sqrt(1.0 - ct * ct);
        float3 H = T * (st * cos(phi)) + B * (st * sin(phi)) + N * ct;
        float3 L = 2.0 * dot(N, H) * H - N;
        float ndl = dot(N, L);
        if (ndl <= 0.0) continue;
        float a2 = alpha * alpha;
        float dd = ct * ct * (a2 - 1.0) + 1.0;
        float D = a2 / (PI_F * dd * dd);
        float pdf = D / 4.0;
        float saSample = 1.0 / (float(S) * pdf + 1e-4);
        float lod = clamp(0.5 * log2(saSample / saTexel) + 1.0, 0.0, cp.srcMips - 1.0);
        sum += src.sample(s, L, level(lod)).rgb * ndl;
        wsum += ndl;
    }
    return float4(sum / max(wsum, 1e-4), 1.0);
}

kernel void occlusionKernel(depth2d<float, access::read> depth [[texture(0)]], device float* out [[buffer(0)]],
                            constant uint2& dims [[buffer(1)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= dims.x || id.y >= dims.y) return;
    uint W = depth.get_width(), H = depth.get_height();
    uint x0 = id.x * W / dims.x, x1 = max((id.x + 1) * W / dims.x, x0 + 1);
    uint y0 = id.y * H / dims.y, y1 = max((id.y + 1) * H / dims.y, y0 + 1);
    float m = 1.0;
    for (uint y = y0; y < y1; y++) {
        for (uint x = x0; x < x1; x++) m = min(m, depth.read(uint2(x, y)));
    }
    out[id.y * dims.x + id.x] = m;
}
"""
