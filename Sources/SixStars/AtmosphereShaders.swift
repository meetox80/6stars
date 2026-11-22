let atmosphereShaderSource = """

struct Atmos {
    float4 sunDir;
    float4 sunColor;
    float4 rayleigh;
    float4 mieScat;
    float4 mieAbs;
    float4 ozone;
    float4 ozoneLin;
    float4 planet;
    float4 ambient;
    float4 waterExt;
    float4 waterScat;
    float4 filmic0;
    float4 filmic1;
    float4 expo;
    float4 sunDisc;
    float4 misc;
    float4 cloud0;
    float4 cloud1;
    float4 cloud2;
    float4 fog0;
    float4 fog1;
    float4 fog2;
    float4 fog3;
    float4 post0;
    float4 taa;
    float4 grade;
    float4 waterLook;
    float4 sharpen;
    float4x4 viewProj;
    float4 camRight;
    float4 camUp;
    float4 camFwd;
    float4 camPos;
};

struct GOut {
    float4 color [[color(0)]];
    float dist [[color(1)]];
};

struct OceanOut {
    float4 color [[color(0)]];
    float dist [[color(1)]];
    float depth [[depth(any)]];
};

constant float PI_F = 3.14159265;
constant float HDR_MAX = 60000.0;

static float2 raySphere(float3 ro, float3 rd, float r) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - r * r;
    float d = b * b - c;
    if (d < 0.0) return float2(-1.0);
    float s = sqrt(d);
    return float2(-b - s, -b + s);
}

struct Medium {
    float3 scatR;
    float3 scatM;
    float3 ext;
};

static Medium medium(float h, constant Atmos& a) {
    float dR = exp(-max(h, 0.0) / a.rayleigh.w);
    float dM = exp(-max(h, 0.0) / a.mieScat.w);
    float dO = h < a.ozone.w ? saturate(a.ozoneLin.x * h + a.ozoneLin.y) : saturate(a.ozoneLin.z * h + a.ozoneLin.w);
    Medium m;
    m.scatR = a.rayleigh.rgb * dR;
    m.scatM = a.mieScat.rgb * dM;
    m.ext = m.scatR + m.scatM + a.mieAbs.rgb * dM + a.ozone.rgb * dO;
    return m;
}

static float2 transUV(float r, float mu, constant Atmos& a) {
    float R = a.planet.x, top = a.planet.y;
    float H = sqrt(max(top * top - R * R, 0.0));
    float rho = sqrt(max(r * r - R * R, 0.0));
    float disc = r * r * (mu * mu - 1.0) + top * top;
    float d = max(0.0, -r * mu + sqrt(max(disc, 0.0)));
    float dmin = top - r, dmax = rho + H;
    return float2((d - dmin) / max(dmax - dmin, 1e-6), rho / H);
}

static float3 sampleTrans(texture2d<float> t, float r, float mu, constant Atmos& a) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, transUV(r, mu, a)).rgb;
}

static float3 sunTrans(texture2d<float> t, float r, float mu, constant Atmos& a) {
    float R = a.planet.x;
    float horizon = -sqrt(max(1.0 - (R * R) / (r * r), 0.0));
    float vis = smoothstep(horizon - 0.01, horizon + 0.01, mu);
    return sampleTrans(t, r, mu, a) * vis;
}

static float phaseRayleigh(float c) { return 3.0 / (16.0 * PI_F) * (1.0 + c * c); }

static float phaseMie(float c, float g) {
    float k = 3.0 / (8.0 * PI_F) * (1.0 - g * g) / (2.0 + g * g);
    return k * (1.0 + c * c) / pow(max(1.0 + g * g - 2.0 * g * c, 1e-4), 1.5);
}

static float2 skyUV(float3 d) {
    float e = asin(clamp(d.z, -1.0, 1.0));
    float s = sign(e) * sqrt(abs(e) / (0.5 * PI_F));
    float u = atan2(d.y, d.x) / (2.0 * PI_F);
    return float2(fract(u), 0.5 - 0.5 * s);
}

static float3 skyDirFromUV(float2 uv) {
    float s = 1.0 - 2.0 * uv.y;
    float e = sign(s) * s * s * 0.5 * PI_F;
    float ph = uv.x * 2.0 * PI_F;
    return float3(cos(e) * cos(ph), cos(e) * sin(ph), sin(e));
}

static float3 sampleSky(texture2d<float> sky, float3 d) {
    constexpr sampler s(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    return sky.sample(s, skyUV(d)).rgb;
}

static float3 viewRay(float2 uv, constant Atmos& a) {
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0) - a.taa.xy;
    return normalize(a.camFwd.xyz + a.camRight.xyz * (ndc.x * a.camRight.w) + a.camUp.xyz * (ndc.y * a.camUp.w));
}

static float hash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float vnoise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = hash13(i), b = hash13(i + float3(1, 0, 0)), c = hash13(i + float3(0, 1, 0)), d = hash13(i + float3(1, 1, 0));
    float e = hash13(i + float3(0, 0, 1)), g = hash13(i + float3(1, 0, 1)), h = hash13(i + float3(0, 1, 1)), k = hash13(i + float3(1, 1, 1));
    return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y), mix(mix(e, g, u.x), mix(h, k, u.x), u.y), u.z);
}

static float vnoise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + float2(1, 0)), u.x), mix(hash12(i + float2(0, 1)), hash12(i + float2(1, 1)), u.x), u.y);
}

static float fbm3(float3 p, int oct) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * vnoise3(p);
        n += a;
        p = p * 2.03 + float3(1.7, 9.2, 3.1);
        a *= 0.5;
    }
    return s / n;
}

static float fbm2(float2 p, int oct) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * vnoise2(p);
        n += a;
        p = p * 2.07 + float2(5.3, 1.9);
        a *= 0.5;
    }
    return s / n;
}

static float2 windOffset(constant Atmos& a) {
    return a.cloud2.xy * (a.cloud1.z * a.expo.w);
}

static float cloudCoverage(float2 xy, constant Atmos& a) {
    float n = fbm2((xy - windOffset(a)) / 5200.0, 5);
    float t = 0.5 + (0.5 - a.cloud0.z) * 0.55;
    return saturate((n - t) / (1.0 - t) * 2.2);
}

static float cloudDensity(float3 p, constant Atmos& a, int detail) {
    float base = a.cloud0.x, top = a.cloud0.y;
    float h = (p.z - base) / (top - base);
    if (h <= 0.0 || h >= 1.0) return 0.0;
    float cov = cloudCoverage(p.xy, a);
    if (cov <= 0.001) return 0.0;
    float profile = saturate(h * 7.0) * saturate((1.0 - h) * (1.2 + cov));
    float3 q = p - float3(windOffset(a), 0.0);
    float shape = fbm3(q / 650.0, 3);
    float d = saturate(cov * profile * 1.4 - (1.0 - shape) * 0.85);
    if (detail > 0 && d > 0.0) d = saturate(d - fbm3(q / 120.0, 2) * 0.28 * (1.0 - d));
    return d * a.cloud0.w;
}

static float cloudShadow(float3 p, constant Atmos& a) {
    if (a.sunDir.z < 0.03) return 1.0;
    float mid = mix(a.cloud0.x, a.cloud0.y, 0.3);
    float3 q = p + a.sunDir.xyz * ((mid - p.z) / a.sunDir.z);
    return 1.0 - a.cloud1.w * saturate(cloudCoverage(q.xy, a) * 2.0);
}

static float hgPhase(float c, float g) {
    return (1.0 - g * g) / (4.0 * PI_F * pow(max(1.0 + g * g - 2.0 * g * c, 1e-4), 1.5));
}

static float3 integrateScattering(float3 ro, float3 rd, float tmax, int n, constant Atmos& a,
                                  texture2d<float> trans, texture2d<float> ms, thread float3& tout) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float R = a.planet.x, top = a.planet.y;
    float3 sun = a.sunDir.xyz;
    float3 E = a.sunDir.w * a.sunColor.rgb;
    float c = dot(rd, sun);
    float pR = phaseRayleigh(c), pM = phaseMie(c, a.mieAbs.w);
    float3 T = float3(1.0), L = float3(0.0);
    float fn = float(n);
    for (int k = 0; k < n; k++) {
        float t0 = tmax * (float(k) / fn) * (float(k) / fn);
        float t1 = tmax * (float(k + 1) / fn) * (float(k + 1) / fn);
        float dt = t1 - t0;
        float3 p = ro + rd * (0.5 * (t0 + t1));
        float pr = length(p);
        float3 up = p / pr;
        Medium m = medium(pr - R, a);
        float3 sT = exp(-m.ext * dt);
        float muS = dot(up, sun);
        float3 ts = sunTrans(trans, pr, muS, a);
        float3 msv = ms.sample(s, float2(muS * 0.5 + 0.5, saturate((pr - R) / (top - R)))).rgb * a.ambient.w;
        float3 S = E * ((m.scatR * pR + m.scatM * pM) * ts + (m.scatR + m.scatM) * msv);
        float3 se = max(m.ext, float3(1e-7));
        L += T * (S - S * sT) / se;
        T *= sT;
    }
    tout = T;
    return L;
}

fragment float4 transLUTFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]]) {
    float2 uv = in.position.xy / float2(256.0, 64.0);
    float R = a.planet.x, top = a.planet.y;
    float H = sqrt(top * top - R * R);
    float rho = H * uv.y;
    float r = sqrt(rho * rho + R * R);
    float dmin = top - r, dmax = rho + H;
    float d = dmin + uv.x * (dmax - dmin);
    float mu = d <= 0.0 ? 1.0 : clamp((H * H - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0);
    float3 ro = float3(0.0, 0.0, r);
    float3 rd = float3(sqrt(max(1.0 - mu * mu, 0.0)), 0.0, mu);
    float t = raySphere(ro, rd, top).y;
    float3 depth = float3(0.0);
    const int N = 40;
    float dt = max(t, 0.0) / float(N);
    for (int i = 0; i < N; i++) {
        float3 p = ro + rd * ((float(i) + 0.5) * dt);
        depth += medium(length(p) - R, a).ext * dt;
    }
    return float4(exp(-depth), 1.0);
}

fragment float4 msLUTFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], texture2d<float> trans [[texture(0)]]) {
    float2 uv = in.position.xy / 32.0;
    float R = a.planet.x, top = a.planet.y;
    float muS = uv.x * 2.0 - 1.0;
    float r = R + uv.y * (top - R) + 0.0005;
    float3 ro = float3(0.0, 0.0, r);
    float3 sun = float3(sqrt(max(1.0 - muS * muS, 0.0)), 0.0, muS);
    float3 lum = float3(0.0), fms = float3(0.0);
    const int SQ = 8;
    const int N = 20;
    for (int i = 0; i < SQ; i++) {
        for (int j = 0; j < SQ; j++) {
            float z = 1.0 - 2.0 * (float(j) + 0.5) / float(SQ);
            float ph = 2.0 * PI_F * (float(i) + 0.5) / float(SQ);
            float rxy = sqrt(max(1.0 - z * z, 0.0));
            float3 rd = float3(rxy * cos(ph), rxy * sin(ph), z);
            float2 tg = raySphere(ro, rd, R);
            float2 tt = raySphere(ro, rd, top);
            bool ground = tg.x > 0.0;
            float tmax = ground ? tg.x : max(tt.y, 0.0);
            float dt = tmax / float(N);
            float3 T = float3(1.0), L = float3(0.0), F = float3(0.0);
            for (int k = 0; k < N; k++) {
                float3 p = ro + rd * ((float(k) + 0.5) * dt);
                float pr = length(p);
                Medium m = medium(pr - R, a);
                float3 sT = exp(-m.ext * dt);
                float3 ts = sunTrans(trans, pr, dot(p / pr, sun), a);
                float3 sc = m.scatR + m.scatM;
                float3 S = sc * (1.0 / (4.0 * PI_F)) * ts;
                float3 se = max(m.ext, float3(1e-7));
                L += T * (S - S * sT) / se;
                F += T * (sc - sc * sT) / se;
                T *= sT;
            }
            if (ground) {
                float3 p = ro + rd * tg.x;
                float pr = length(p);
                float mu = dot(p / pr, sun);
                L += T * sunTrans(trans, pr, mu, a) * saturate(mu) * a.planet.w / PI_F;
            }
            lum += L;
            fms += F;
        }
    }
    float inv = 1.0 / float(SQ * SQ);
    lum *= inv;
    fms *= inv;
    return float4(lum / max(1.0 - fms, float3(1e-3)), 1.0);
}

fragment float4 skyLUTFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]],
                               texture2d<float> trans [[texture(0)]], texture2d<float> ms [[texture(1)]]) {
    float2 uv = in.position.xy / float2(192.0, 108.0);
    float3 rd = skyDirFromUV(uv);
    float R = a.planet.x, top = a.planet.y;
    float3 ro = float3(0.0, 0.0, a.planet.z);
    float2 tg = raySphere(ro, rd, R);
    float2 tt = raySphere(ro, rd, top);
    if (tt.y <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    bool ground = tg.x > 0.0;
    float tmax = ground ? tg.x : tt.y;
    float3 T;
    float3 L = integrateScattering(ro, rd, tmax, 32, a, trans, ms, T);
    if (ground) {
        float3 p = ro + rd * tg.x;
        float pr = length(p);
        float mu = dot(p / pr, a.sunDir.xyz);
        L += T * a.sunDir.w * a.sunColor.rgb * sunTrans(trans, pr, mu, a) * saturate(mu) * a.planet.w / PI_F;
    }
    return float4(min(L, float3(HDR_MAX)), 1.0);
}

kernel void skySHKernel(texture2d<float> sky [[texture(0)]], device float4* sh [[buffer(0)]], uint tid [[thread_position_in_grid]]) {
    if (tid != 0) return;
    float3 c0 = float3(0.0), c1 = float3(0.0), c2 = float3(0.0), c3 = float3(0.0);
    const int NU = 64, NV = 32;
    for (int j = 0; j < NV; j++) {
        float z = 1.0 - 2.0 * (float(j) + 0.5) / float(NV);
        float rxy = sqrt(max(1.0 - z * z, 0.0));
        for (int i = 0; i < NU; i++) {
            float ph = 2.0 * PI_F * (float(i) + 0.5) / float(NU);
            float3 d = float3(rxy * cos(ph), rxy * sin(ph), z);
            float3 L = sampleSky(sky, d);
            c0 += L * 0.282095;
            c1 += L * 0.488603 * d.y;
            c2 += L * 0.488603 * d.z;
            c3 += L * 0.488603 * d.x;
        }
    }
    float w = 4.0 * PI_F / float(NU * NV);
    sh[0] = float4(c0 * w, 0.0);
    sh[1] = float4(c1 * w, 0.0);
    sh[2] = float4(c2 * w, 0.0);
    sh[3] = float4(c3 * w, 0.0);
}

static float3 shIrradiance(constant float4* sh, float3 n) {
    float3 e = PI_F * 0.282095 * sh[0].rgb + (2.0 * PI_F / 3.0) * 0.488603 * (sh[1].rgb * n.y + sh[2].rgb * n.z + sh[3].rgb * n.x);
    return max(e, float3(0.0));
}

static float3 sunIrradiance(texture2d<float> trans, float3 p, constant Atmos& a) {
    float r = a.planet.x + max(p.z, 0.0) * 0.001;
    return a.sunDir.w * a.sunColor.rgb * sunTrans(trans, r, a.sunDir.z, a) * cloudShadow(p, a);
}

struct CloudOut {
    float4 color [[color(0)]];
    float dist [[color(1)]];
};

static float4 cloudMarch(float3 ro, float3 rd, float2 pixel, int N, constant Atmos& a, constant float4* sh,
                         texture2d<float> trans, texture2d<float> ms, thread float& outDist) {
    outDist = 1.0e9;
    float base = a.cloud0.x, top = a.cloud0.y;
    float t0 = -1.0, t1 = -1.0;
    if (ro.z < base) {
        if (rd.z > 0.002) { t0 = (base - ro.z) / rd.z; t1 = (top - ro.z) / rd.z; }
    } else if (ro.z > top) {
        if (rd.z < -0.002) { t0 = (top - ro.z) / rd.z; t1 = (base - ro.z) / rd.z; }
    } else {
        t0 = 0.0;
        t1 = rd.z > 0.002 ? (top - ro.z) / rd.z : (rd.z < -0.002 ? (base - ro.z) / rd.z : 15000.0);
    }
    float3 sun = a.sunDir.xyz;
    float3 Es = a.sunDir.w * a.sunColor.rgb * sunTrans(trans, a.planet.x + 0.8, sun.z, a);
    float3 Eamb = shIrradiance(sh, float3(0.0, 0.0, 1.0));
    float c = dot(rd, sun);
    float phase = mix(hgPhase(c, 0.8), hgPhase(c, -0.25), 0.35);
    float3 L = float3(0.0);
    float T = 1.0;
    float first = -1.0;
    if (t0 >= 0.0 && t0 < 45000.0) {
        t1 = min(t1, t0 + 9000.0);
        float jitter = fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
        float dt = (t1 - t0) / float(N);
        float fadeFar = saturate(1.0 - t0 / 45000.0);
        for (int i = 0; i < N; i++) {
            float t = t0 + (float(i) + jitter) * dt;
            float3 p = ro + rd * t;
            float d = cloudDensity(p, a, 1) * fadeFar;
            if (d <= 0.002) continue;
            if (first < 0.0) first = t;
            float sigma = d * 0.02;
            float od = 0.0, tl = 0.0;
            for (int j = 0; j < 4; j++) {
                float st = 60.0 * float(j + 1);
                tl += st;
                od += cloudDensity(p + sun * tl, a, 0) * 0.02 * st;
            }
            float h = saturate((p.z - base) / (top - base));
            float ms = 0.0, oa = 1.0, ob = 1.0, oc = 1.0;
            for (int k = 0; k < 4; k++) {
                ms += oa * exp(-od * ob) * mix(hgPhase(c, 0.8 * oc), hgPhase(c, -0.25 * oc), 0.35);
                oa *= 0.55;
                ob *= 0.4;
                oc *= 0.5;
            }
            float powder = 1.0 - exp(-sigma * 200.0);
            float3 S = sigma * (Es * ms * mix(0.7, 1.0, powder) + Eamb * (0.5 + 0.5 * h) * a.cloud2.w / (4.0 * PI_F));
            float Ts = exp(-sigma * dt);
            L += T * S * (1.0 - Ts) / sigma;
            (void)phase;
            T *= Ts;
            if (T < 0.01) break;
        }
    }
    if (rd.z > 0.01 && ro.z < a.cloud1.x && a.cloud1.y > 0.0) {
        float tc = (a.cloud1.x - ro.z) / rd.z;
        float2 q = (ro + rd * tc).xy - windOffset(a) * 3.0;
        float2 w = a.cloud2.xy;
        float2 sq = float2(dot(q, w), dot(q, float2(-w.y, w.x)) * 6.0) / 9000.0;
        float streak = saturate((fbm2(sq, 5) - 0.52) * 3.0) * a.cloud1.y * saturate(1.0 - tc / 90000.0);
        float3 Lc = streak * (Es * hgPhase(c, 0.6) * 0.5 + Eamb / (4.0 * PI_F) * 0.6);
        L += T * Lc;
        T *= 1.0 - streak * 0.5;
        if (first < 0.0 && streak > 0.01) first = tc;
    }
    if (first > 0.0) {
        float3 Ta;
        float3 La = integrateScattering(float3(0.0, 0.0, a.planet.z), rd, first * 0.001, 8, a, trans, ms, Ta);
        L = L * Ta + La * (1.0 - T);
        outDist = first;
    }
    return float4(min(L, float3(HDR_MAX)), T);
}

fragment CloudOut cloudFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], constant float4* sh [[buffer(1)]],
                                texture2d<float> trans [[texture(0)]], texture2d<float> ms [[texture(1)]]) {
    CloudOut o;
    o.color = cloudMarch(a.camPos.xyz, viewRay(in.uv, a), in.position.xy, 44, a, sh, trans, ms, o.dist);
    return o;
}

static float2 waveHash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453);
}

static float3 gradNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float2 ga = waveHash(i), gb = waveHash(i + float2(1.0, 0.0)), gc = waveHash(i + float2(0.0, 1.0)), gd = waveHash(i + float2(1.0, 1.0));
    float va = dot(ga, f), vb = dot(gb, f - float2(1.0, 0.0)), vc = dot(gc, f - float2(0.0, 1.0)), vd = dot(gd, f - float2(1.0, 1.0));
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
    float2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * (va - vb - vc + vd) + float2(vb, vc) - va);
    return float3(v, d);
}

static float3 waveNormal(float2 p, float t, float beaufort, float footprint, float2 wind) {
    float2 g = float2(0.0);
    float steep = 0.03 * max(beaufort, 0.3);
    float lambda = 45.0;
    float ang = atan2(wind.y, wind.x);
    for (int i = 0; i < 10; i++) {
        float2 w = float2(cos(ang), sin(ang));
        float2 pp = float2(-w.y, w.x);
        float freq = 1.0 / lambda;
        float speed = sqrt(9.81 * lambda / (2.0 * PI_F));
        float2 uv = float2(dot(p, w) * freq - speed * t * freq, dot(p, pp) * freq * 0.45) + float2(float(i) * 17.3, float(i) * 5.1);
        float3 n = gradNoise(uv);
        float fade = saturate(lambda / max(footprint * 6.0, 1e-3) - 1.0);
        float amp = steep * lambda / (2.0 * PI_F);
        g += amp * (n.y * w * freq + n.z * pp * freq * 0.45) * fade * 2.0 * PI_F;
        lambda *= 0.52;
        ang += (i % 2 == 0 ? 0.45 : -0.6);
    }
    return normalize(float3(-g, 1.0));
}

static float3 waterShade(float3 N, float3 V, float3 behind, float thickness, float3 pos, float footprint, constant Atmos& a,
                         texture2d<float> trans, texturecube<float> env, constant float4* sh, float4 ssr) {
    float3 sun = a.sunDir.xyz;
    float3 Esun = sunIrradiance(trans, pos, a);
    float ndv = max(dot(N, V), 1e-3);
    float F = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
    float3 rd = reflect(-V, N);
    rd.z = abs(rd.z);
    constexpr sampler es(filter::linear, mip_filter::linear);
    float3 refl = mix(env.sample(es, rd, level(1.0)).rgb, ssr.rgb, ssr.a) * a.waterLook.x;
    float3 H = normalize(V + sun);
    float ndh = saturate(dot(N, H));
    float ndl = saturate(dot(N, sun));
    float alpha = mix(0.05, 0.35, saturate(footprint * 0.4));
    float al = alpha * alpha;
    float dd = ndh * ndh * (al - 1.0) + 1.0;
    float D = al / (PI_F * dd * dd);
    float Fs = 0.02 + 0.98 * pow(1.0 - saturate(dot(V, H)), 5.0);
    float3 spec = Esun * D * Fs * step(0.0, ndl) / (4.0 * ndv) * (1.0 - ssr.a);
    float3 ext = a.waterExt.rgb;
    float3 T = exp(-ext * thickness);
    float3 Edown = Esun * saturate(sun.z) + shIrradiance(sh, float3(0.0, 0.0, 1.0));
    float3 deep = a.waterScat.rgb / max(ext, float3(1e-5)) * Edown / PI_F;
    float3 refr = behind * T + deep * (1.0 - T);
    return min(mix(refr, refl, F) + spec, float3(HDR_MAX));
}

struct SkyOut {
    float4 color [[color(3)]];
};

fragment SkyOut skyFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]],
                          texture2d<float> trans [[texture(0)]], texture2d<float> sky [[texture(2)]], texture2d<float> clouds [[texture(4)]]) {
    float3 rd = viewRay(in.uv, a);
    float3 L = sampleSky(sky, rd) * a.sunDisc.w;
    float c = dot(rd, a.sunDir.xyz);
    float rad = a.sunDisc.x;
    if (c > cos(rad * 1.05)) {
        float omega = 2.0 * PI_F * (1.0 - cos(rad));
        float edge = smoothstep(cos(rad * 1.05), cos(rad * 0.95), c);
        L += a.sunDir.w * a.sunColor.rgb * sunTrans(trans, a.planet.z, rd.z, a) / omega * edge;
    }
    constexpr sampler cs(filter::linear, address::clamp_to_edge);
    float4 cl = clouds.sample(cs, in.uv);
    L = L * cl.a + cl.rgb;
    SkyOut o;
    o.color = float4(min(L, float3(HDR_MAX)), 1.0);
    return o;
}

static float4 screenReflect(float3 p, float3 dir, constant Atmos& a, texture2d<float> hdrc, texture2d<float> distc) {
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float2 size = float2(distc.get_width(), distc.get_height());
    float t = 0.5, step = 1.5;
    float prevQd = 0.0, prevSd = 0.0;
    for (int i = 0; i < 48; i++) {
        float3 q = p + dir * t;
        float4 c = a.viewProj * float4(q, 1.0);
        if (c.w <= 0.0) break;
        float2 uv = float2(c.x / c.w * 0.5 + 0.5, 0.5 - c.y / c.w * 0.5);
        if (any(uv < float2(0.0)) || any(uv > float2(1.0))) break;
        float sd = distc.read(uint2(min(uv * size, size - 1.0))).r;
        float qd = distance(q, a.camPos.xyz);
        if (sd > 0.0 && qd > sd && qd - sd < step * 1.5 + qd * 0.02) {
            float2 e = min(uv, 1.0 - uv);
            float w = saturate(min(e.x, e.y) * 12.0) * saturate(1.0 - float(i) / 48.0);
            return float4(hdrc.sample(ls, uv).rgb, w);
        }
        prevQd = qd;
        prevSd = sd;
        t += step;
        step *= 1.13;
    }
    return float4(0.0);
}

fragment OceanOut oceanFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], constant float4* sh [[buffer(1)]],
                                texture2d<float> trans [[texture(0)]], texture2d<float> sky [[texture(2)]],
                                texture2d<float> hdrc [[texture(6)]], texture2d<float> distc [[texture(7)]], texturecube<float> env [[texture(13)]],
                                float4 dst0 [[color(0)]], float dst1 [[color(1)]]) {
    float3 rd = viewRay(in.uv, a);
    float3 ro = a.camPos.xyz;
    float wh = a.waterExt.w;
    if (ro.z <= wh + 0.05 || rd.z > -1e-5) discard_fragment();
    float t = (wh - ro.z) / rd.z;
    if (dst1 > 0.0 && dst1 <= t) discard_fragment();
    float3 p = ro + rd * t;
    float4 clip = a.viewProj * float4(p, 1.0);
    float footprint = t * a.misc.y / max(-rd.z, 0.02);
    float3 N = waveNormal(p.xy, a.expo.w, a.waterScat.w, footprint, a.cloud2.xy);
    float thick = dst1 > 0.0 ? dst1 - t : 1.0e4;
    float2 size = float2(distc.get_width(), distc.get_height());
    float2 ruv = in.uv + N.xy * (0.03 * saturate(thick * 0.3)) / max(t * 0.02, 1.0);
    float3 behind = dst0.rgb;
    float rsd = distc.read(uint2(clamp(ruv, float2(0.0), float2(1.0)) * (size - 1.0))).r;
    if (rsd > t || rsd <= 0.0) {
        constexpr sampler ls(filter::linear, address::clamp_to_edge);
        behind = hdrc.sample(ls, ruv).rgb;
        thick = rsd > 0.0 ? rsd - t : 1.0e4;
    }
    float3 V = -rd;
    float3 rdir = reflect(rd, N);
    rdir.z = abs(rdir.z);
    float4 ssr = screenReflect(p, rdir, a, hdrc, distc);
    float3 col = waterShade(N, V, behind, thick, p, footprint, a, trans, env, sh, ssr);
    float depthV = thick * max(-rd.z, 0.05);
    float shore = saturate(1.0 - depthV / 0.9);
    if (shore > 0.0) {
        float2 fp = p.xy * 0.35 - a.cloud2.xy * a.expo.w * 0.6;
        float bands = 0.5 + 0.5 * sin(depthV * 9.0 - a.expo.w * 1.4 + fbm2(p.xy * 0.08, 2) * 6.0);
        float foam = saturate((fbm2(fp, 4) * (0.6 + 0.6 * bands) - (1.0 - shore) * 0.9 - 0.25) * 3.0) * a.cloud2.z;
        float3 Esun = sunIrradiance(trans, p, a);
        float3 foamCol = 0.8 / PI_F * (Esun * saturate(a.sunDir.z) + shIrradiance(sh, float3(0.0, 0.0, 1.0)));
        col = mix(col, foamCol, foam);
    }
    OceanOut o;
    o.color = float4(min(col, float3(HDR_MAX)), 1.0);
    o.dist = t;
    o.depth = clip.z / clip.w;
    return o;
}

static float4 applyFog(float3 c, float d, float2 uv, constant Atmos& a, texture3d<float> fogv) {
    constexpr sampler fs(filter::linear, address::clamp_to_edge);
    float w = d > 0.0 ? saturate(log(max(d, 0.5) / 0.5) / log(a.fog3.w / 0.5)) : 1.0;
    float4 f = fogv.sample(fs, float3(uv, w));
    return float4(c * f.a + f.rgb, f.a);
}

fragment GOut compositeFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]],
                                texture2d<float> trans [[texture(0)]], texture2d<float> ms [[texture(1)]],
                                texture2d<float> clouds [[texture(4)]], texture2d<float> cloudDist [[texture(5)]],
                                texture3d<float> fogv [[texture(14)]],
                                float4 dst0 [[color(0)]], float dst1 [[color(1)]]) {
    GOut o;
    o.color = dst0;
    o.dist = dst1;
    if (dst1 <= 0.0) return o;
    float3 rd = viewRay(in.uv, a);
    float3 ro = float3(0.0, 0.0, a.planet.z);
    float3 T;
    float3 L = integrateScattering(ro, rd, dst1 * 0.001, 12, a, trans, ms, T);
    float3 c = dst0.rgb * T + L * a.sunDisc.z;
    constexpr sampler cs(filter::linear, address::clamp_to_edge);
    constexpr sampler ns(filter::nearest, address::clamp_to_edge);
    if (cloudDist.sample(ns, in.uv).r < dst1) {
        float4 cl = clouds.sample(cs, in.uv);
        c = c * cl.a + cl.rgb;
    }
    c = applyFog(c, dst1, in.uv, a, fogv).rgb;
    o.color = float4(min(c, float3(HDR_MAX)), dst0.a);
    return o;
}

struct ShadowData {
    float4x4 vp[4];
    float4 splits;
    float4 texel;
    float4 zinv;
    float4 info;
};

struct ShadowVOut {
    float4 position [[position]];
    float2 uv;
    uint material [[flat]];
    float2 fade [[flat]];
};

vertex ShadowVOut shadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device MeshVertexIn* verts [[buffer(0)]],
                               constant float4x4& vp [[buffer(1)]],
                               const device InstanceData* inst [[buffer(2)]]) {
    MeshVertexIn v = verts[vid];
    InstanceData m = inst[iid];
    float4 p = float4(float3(v.pos), 1.0);
    float3 w = float3(dot(m.r0, p), dot(m.r1, p), dot(m.r2, p));
    ShadowVOut o;
    o.position = vp * float4(w, 1.0);
    o.uv = v.uv;
    o.material = v.material;
    o.fade = m.fade.xy;
    return o;
}

fragment void shadowFragment(ShadowVOut in [[stage_in]], device const Material* mats [[buffer(3)]], device const TexTable& tt [[buffer(4)]],
                             constant float& time [[buffer(5)]]) {
    lodFade(in.fade, in.position.xy, time);
    Material m = mats[in.material];
    if (m.kind >= 2u) discard_fragment();
    if ((m.flags & 8u) != 0u) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
        if (tt.t[m.diffuse[0]].sample(s, in.uv).a < 0.5) discard_fragment();
    }
}

static float shadowFactor(float3 wpos, float3 N, float dist, constant ShadowData& sd, depth2d_array<float> sm) {
    if (sd.info.x < 0.5) return 1.0;
    int c = 0;
    while (c < 4 && dist > sd.splits[c]) c++;
    if (c >= 4) return 1.0;
    float texel = sd.texel[c];
    float3 p = wpos + N * (texel * 1.5);
    float4 lp = sd.vp[c] * float4(p, 1.0);
    float2 uv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
    if (any(uv < float2(0.0)) || any(uv > float2(1.0))) return 1.0;
    float z = lp.z - texel * sd.zinv[c];
    constexpr sampler cs(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
    float ts = sd.info.y;
    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            sum += sm.sample_compare(cs, uv + float2(float(x), float(y)) * ts, uint(c), z);
        }
    }
    sum /= 9.0;
    float fade = c == 3 ? saturate((dist - sd.splits[3] * 0.85) / (sd.splits[3] * 0.15)) : 0.0;
    return mix(sum, 1.0, fade);
}

fragment GOut meshFragmentHDR(MeshOut in [[stage_in]], constant Uniforms& u [[buffer(1)]],
                              device const Material* mats [[buffer(3)]], device const TexTable& tt [[buffer(4)]],
                              constant Atmos& a [[buffer(6)]], constant float4* sh [[buffer(7)]], constant ShadowData& sd [[buffer(8)]],
                              texture2d<float> trans [[texture(0)]], texture2d<float> sky [[texture(2)]], depth2d_array<float> sm [[texture(3)]],
                              texturecube<float> env [[texture(13)]], float4 dst0 [[color(0)]], float dst1 [[color(1)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    Material m = mats[in.material];
    lodFade(in.fade, in.position.xy, u.time);
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 N = normalize(in.normal);
    if (dot(N, V) < 0.0) N = -N;
    float dist = distance(in.world, u.camPos.xyz);
    GOut o;
    if (m.kind == 4u) {
        float thick = dst1 > 0.0 ? max(dst1 - dist, 0.0) : 1.0e4;
        float footprint = dist * a.misc.y / max(abs(dot(N, V)), 0.02);
        float3 w = waveNormal(in.world.xy, a.expo.w, 0.4, footprint, a.cloud2.xy);
        float3 Nw = normalize(N + float3(w.xy, 0.0));
        o.color = float4(waterShade(Nw, V, dst0.rgb, thick, in.world, footprint, a, trans, env, sh, float4(0.0)), 1.0);
        o.dist = dist;
        return o;
    }
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
    if (useNormal && dot(tn, tn) > 1e-6) N = perturbNormal(N, in.world, in.uv, normalize(tn));
    float ao = (m.flags & 1u) != 0u ? mix(0.3, 1.0, in.c0.r) : 1.0;
    float3 sun = a.sunDir.xyz;
    float3 Ng = normalize(in.normal);
    if (dot(Ng, V) < 0.0) Ng = -Ng;
    float3 Esun = sunIrradiance(trans, in.world, a) * (dot(Ng, sun) > 0.0 ? shadowFactor(in.world, Ng, dist, sd, sm) : 0.0);
    float ndl = saturate(dot(N, sun));
    float ndv = max(dot(N, V), 1e-3);
    float3 Eamb = shIrradiance(sh, N) * a.ambient.rgb;
    float3 H = normalize(sun + V);
    float ndh = saturate(dot(N, H));
    float rough = 0.6;
    float al = rough * rough * rough * rough;
    float dd = ndh * ndh * (al - 1.0) + 1.0;
    float D = al / (PI_F * dd * dd);
    float Fs = 0.04 + 0.96 * pow(1.0 - saturate(dot(V, H)), 5.0);
    float kk = (rough + 1.0) * (rough + 1.0) / 8.0;
    float G = 1.0 / ((ndl * (1.0 - kk) + kk) * (ndv * (1.0 - kk) + kk));
    float3 spec = Esun * (D * Fs * G * ndl / 4.0);
    float3 c = albedo.rgb / PI_F * (Esun * ndl + Eamb * ao) * (1.0 - Fs) + spec * ao;
    if ((m.flags & 4u) != 0u) c += albedo.rgb * a.misc.z;
    o.color = float4(min(c, float3(HDR_MAX)), alpha);
    o.dist = m.kind == 2u ? dst1 : (m.kind == 3u ? (alpha > 0.3 ? dist : dst1) : dist);
    return o;
}

fragment float lumFragment(QuadOut in [[stage_in]], texture2d<float> hdr [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = hdr.sample(s, in.uv).rgb;
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    return log(max(l, 1e-2));
}

constant float meterMin = -5.0;
constant float meterMax = 13.0;

kernel void adaptKernel(texture2d<float, access::read> lum [[texture(0)]], device float* state [[buffer(0)]],
                        constant float4& params [[buffer(1)]], uint tid [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint bins[64];
    if (tid < 64) atomic_store_explicit(&bins[tid], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint level = uint(params.x);
    uint w = lum.get_width(level), h = lum.get_height(level), n = w * h;
    for (uint i = tid; i < n; i += 256) {
        float v = lum.read(uint2(i % w, i / w), level).r;
        int b = clamp(int((v - meterMin) / (meterMax - meterMin) * 64.0), 0, 63);
        atomic_fetch_add_explicit(&bins[b], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid != 0) return;
    float total = float(n), lo = total * params.z, hi = total * (1.0 - params.w);
    float acc = 0.0, wsum = 0.0, run = 0.0;
    for (int b = 0; b < 64; b++) {
        float c = float(atomic_load_explicit(&bins[b], memory_order_relaxed));
        float a0 = max(run, lo), a1 = min(run + c, hi);
        if (a1 > a0) {
            acc += (meterMin + (float(b) + 0.5) * (meterMax - meterMin) / 64.0) * (a1 - a0);
            wsum += a1 - a0;
        }
        run += c;
    }
    float prev = state[0];
    float v = wsum > 0.0 ? acc / wsum : prev;
    state[0] = (isnan(prev) || params.y >= 1.0) ? v : mix(prev, v, params.y);
}

static float3 hable(float3 x, float A, float B, float C, float D, float E, float F) {
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

static float3 gradeTonemap(float3 c, constant Atmos& a, device const float* state) {
    float ev100 = clamp(log2(exp(state[0]) * 100.0 / 12.5), a.expo.y, a.expo.z);
    float avg = exp2(ev100) * 12.5 / 100.0;
    float exposure = a.expo.x / avg * exp2(a.sunColor.w + a.grade.x);
    float A = a.filmic0.x, B = a.filmic0.y, C = a.filmic0.z, D = a.filmic0.w, E = a.filmic1.x, F = a.filmic1.y;
    float3 t = hable(c * exposure, A, B, C, D, E, F) / hable(float3(a.filmic1.z), A, B, C, D, E, F);
    t = saturate(t);
    float pivot = a.misc.x;
    t = saturate(pivot * pow(max(t / pivot, float3(0.0)), float3(a.filmic1.w * a.grade.z)));
    float luma = dot(t, float3(0.2126, 0.7152, 0.0722));
    float hi = max(t.r, max(t.g, t.b)), lo = min(t.r, min(t.g, t.b));
    float chroma = (hi - lo) / max(hi, 1e-4);
    t = max(mix(float3(luma), t, 1.0 + (a.grade.y - 1.0) * (1.0 - chroma)), float3(0.0));
    float w = a.grade.w;
    float3 warm = float3(1.0 + 0.10 * w, 1.0 + 0.03 * w, 1.0 - 0.10 * w);
    float3 cool = float3(1.0 - 0.06 * w, 1.0 + 0.01 * w, 1.0 + 0.05 * w);
    t *= mix(cool, warm, smoothstep(0.05, 0.5, luma));
    return saturate(t);
}

static float3 tonemapAt(texture2d<float, access::read> hdr, int2 p, float3 b, constant Atmos& a, device const float* state) {
    int2 sz = int2(hdr.get_width(), hdr.get_height());
    return gradeTonemap(mix(hdr.read(uint2(clamp(p, int2(0), sz - 1))).rgb, b, a.post0.x), a, state);
}

fragment float4 tonemapFragment(QuadOut in [[stage_in]], texture2d<float, access::read> hdr [[texture(0)]],
                                constant Atmos& a [[buffer(0)]], device const float* state [[buffer(1)]],
                                texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler bs(filter::linear, address::clamp_to_edge);
    int2 p = int2(in.position.xy);
    float3 b = bloom.sample(bs, in.uv, level(0.0)).rgb / max(a.post0.y, 1.0);
    float3 c = tonemapAt(hdr, p, b, a, state);
    if (a.sharpen.x <= 0.0) return float4(c, 1.0);
    float3 n = tonemapAt(hdr, p + int2(0, -1), b, a, state), s = tonemapAt(hdr, p + int2(0, 1), b, a, state);
    float3 e = tonemapAt(hdr, p + int2(1, 0), b, a, state), w = tonemapAt(hdr, p + int2(-1, 0), b, a, state);
    float3 mn = min(c, min(min(n, s), min(e, w))), mx = max(c, max(max(n, s), max(e, w)));
    float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, float3(1e-4))));
    float3 wgt = amp * (-1.0 / mix(8.0, 5.0, saturate(a.sharpen.x)));
    return float4(saturate((c + (n + s + e + w) * wgt) / (1.0 + 4.0 * wgt)), 1.0);
}

static float3 sampleCatmullRom(texture2d<float> tex, float2 uv) {
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 sp = uv * size;
    float2 t1 = floor(sp - 0.5) + 0.5;
    float2 f = sp - t1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (t1 - 1.0) / size, t3 = (t1 + 2.0) / size, t12 = (t1 + w2 / w12) / size;
    float3 r = tex.sample(ls, float2(t12.x, t0.y)).rgb * (w12.x * w0.y)
             + tex.sample(ls, float2(t0.x, t12.y)).rgb * (w0.x * w12.y)
             + tex.sample(ls, t12).rgb * (w12.x * w12.y)
             + tex.sample(ls, float2(t3.x, t12.y)).rgb * (w3.x * w12.y)
             + tex.sample(ls, float2(t12.x, t3.y)).rgb * (w12.x * w3.y);
    float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(r / wsum, float3(0.0));
}
"""

let volumetricShaderSource = """

static float fogDensity(float3 p, constant Atmos& a) {
    float d0 = a.fog0.x * exp(-max(p.z - a.fog0.y, 0.0) / max(a.fog0.z, 1.0));
    float d1 = a.fog0.w * exp(-max(p.z - a.fog1.x, 0.0) / max(a.fog1.y, 1.0));
    float n = vnoise3((p - float3(windOffset(a), 0.0)) / 40.0);
    return (d0 + d1) * mix(a.post0.z, a.post0.w, n);
}

static float froxelDistance(float k, constant Atmos& a) {
    return 0.5 * pow(a.fog3.w / 0.5, k / 64.0);
}

kernel void fogInjectKernel(texture3d<half, access::write> outv [[texture(0)]], texture2d<float> trans [[texture(1)]],
                            depth2d_array<float> sm [[texture(2)]], constant Atmos& a [[buffer(0)]], constant float4* sh [[buffer(1)]],
                            constant ShadowData& sd [[buffer(2)]], uint3 id [[thread_position_in_grid]]) {
    if (id.x >= 160 || id.y >= 90 || id.z >= 64) return;
    float2 uv = (float2(id.xy) + 0.5) / float2(160.0, 90.0);
    float3 rd = viewRay(uv, a);
    float d = 0.5 * (froxelDistance(float(id.z), a) + froxelDistance(float(id.z) + 1.0, a));
    float3 p = a.camPos.xyz + rd * d;
    float sigma = fogDensity(p, a);
    float3 sun = a.sunDir.xyz;
    float shadow = mix(1.0, shadowFactor(p, sun, d * dot(rd, a.camFwd.xyz), sd, sm), a.fog1.w);
    float3 Esun = sunIrradiance(trans, p, a) * shadow * a.fog2.rgb;
    float c = dot(rd, sun);
    float phase = hgPhase(c, a.fog1.z);
    float3 Esky = shIrradiance(sh, float3(0.0, 0.0, 1.0)) * a.fog3.rgb;
    float3 S = sigma * (Esun * phase + Esky * a.fog2.w / (4.0 * PI_F));
    outv.write(half4(half3(min(S, float3(HDR_MAX))), half(sigma)), id);
}

kernel void fogIntegrateKernel(texture3d<half, access::read> inv [[texture(0)]], texture3d<half, access::write> outv [[texture(1)]],
                               constant Atmos& a [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= 160 || id.y >= 90) return;
    float3 L = float3(0.0);
    float T = 1.0;
    for (uint z = 0; z < 64; z++) {
        float4 v = float4(inv.read(uint3(id, z)));
        float ds = froxelDistance(float(z) + 1.0, a) - froxelDistance(float(z), a);
        float sigma = max(v.a, 1e-7);
        float st = exp(-sigma * ds);
        L += T * (v.rgb - v.rgb * st) / sigma;
        T *= st;
        outv.write(half4(half3(min(L, float3(HDR_MAX))), half(T)), uint3(id, z));
    }
}

fragment float4 bloomDownFragment(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2& info [[buffer(0)]],
                                  device const float* state [[buffer(1)]], constant Atmos& a [[buffer(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float lvl = info.x;
    float2 t = 1.0 / float2(src.get_width(uint(lvl)), src.get_height(uint(lvl)));
    float2 uv = in.uv;
    float3 a0 = src.sample(s, uv + t * float2(-2, -2), level(lvl)).rgb, b0 = src.sample(s, uv + t * float2(0, -2), level(lvl)).rgb, c0 = src.sample(s, uv + t * float2(2, -2), level(lvl)).rgb;
    float3 d0 = src.sample(s, uv + t * float2(-2, 0), level(lvl)).rgb, e0 = src.sample(s, uv, level(lvl)).rgb, f0 = src.sample(s, uv + t * float2(2, 0), level(lvl)).rgb;
    float3 g0 = src.sample(s, uv + t * float2(-2, 2), level(lvl)).rgb, h0 = src.sample(s, uv + t * float2(0, 2), level(lvl)).rgb, i0 = src.sample(s, uv + t * float2(2, 2), level(lvl)).rgb;
    float3 j0 = src.sample(s, uv + t * float2(-1, -1), level(lvl)).rgb, k0 = src.sample(s, uv + t * float2(1, -1), level(lvl)).rgb;
    float3 l0 = src.sample(s, uv + t * float2(-1, 1), level(lvl)).rgb, m0 = src.sample(s, uv + t * float2(1, 1), level(lvl)).rgb;
    float3 r;
    if (info.y > 0.5) {
        float exposure = a.expo.x / max(exp(state[0]), 1e-4);
        float3 g[5] = { (j0 + k0 + l0 + m0) * 0.25, (a0 + b0 + d0 + e0) * 0.25, (b0 + c0 + e0 + f0) * 0.25, (d0 + e0 + g0 + h0) * 0.25, (e0 + f0 + h0 + i0) * 0.25 };
        float wt[5] = { 0.5, 0.125, 0.125, 0.125, 0.125 };
        r = float3(0.0);
        float ws = 0.0;
        for (int k = 0; k < 5; k++) {
            float w = wt[k] / (1.0 + dot(g[k], float3(0.2126, 0.7152, 0.0722)) * exposure);
            r += g[k] * w;
            ws += w;
        }
        r /= ws;
    } else {
        r = e0 * 0.125 + (a0 + c0 + g0 + i0) * 0.03125 + (b0 + d0 + f0 + h0) * 0.0625 + (j0 + k0 + l0 + m0) * 0.125;
    }
    return float4(min(r, float3(HDR_MAX)), 1.0);
}

fragment float4 bloomUpFragment(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2& info [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float lvl = info.x;
    float2 t = 1.0 / float2(src.get_width(uint(lvl)), src.get_height(uint(lvl)));
    float2 uv = in.uv;
    float3 r = src.sample(s, uv, level(lvl)).rgb * 4.0;
    r += (src.sample(s, uv + t * float2(0, -1), level(lvl)).rgb + src.sample(s, uv + t * float2(-1, 0), level(lvl)).rgb +
          src.sample(s, uv + t * float2(1, 0), level(lvl)).rgb + src.sample(s, uv + t * float2(0, 1), level(lvl)).rgb) * 2.0;
    r += src.sample(s, uv + t * float2(-1, -1), level(lvl)).rgb + src.sample(s, uv + t * float2(1, -1), level(lvl)).rgb +
         src.sample(s, uv + t * float2(-1, 1), level(lvl)).rgb + src.sample(s, uv + t * float2(1, 1), level(lvl)).rgb;
    return float4(r / 16.0, 1.0);
}

static float3 taaToYCoCg(float3 c) {
    c = c / (1.0 + dot(c, float3(0.2126, 0.7152, 0.0722)));
    return float3(dot(c, float3(0.25, 0.5, 0.25)), dot(c, float3(0.5, 0.0, -0.5)), dot(c, float3(-0.25, 0.5, -0.25)));
}

static float3 taaFromYCoCg(float3 y) {
    float3 c = max(float3(y.x + y.y - y.z, y.x + y.z, y.x - y.y - y.z), float3(0.0));
    return c / max(1.0 - min(dot(c, float3(0.2126, 0.7152, 0.0722)), 0.999), 1e-3);
}

fragment float4 taaFragment(QuadOut in [[stage_in]], constant Atmos& a [[buffer(0)]], constant float4x4& prevVP [[buffer(1)]],
                            device const float* state [[buffer(2)]],
                            texture2d<float> cur [[texture(0)]], texture2d<float> hist [[texture(1)]], texture2d<float> dist [[texture(2)]]) {
    int2 px = int2(in.position.xy);
    int2 sz = int2(cur.get_width(), cur.get_height());
    float3 c = cur.read(uint2(px)).rgb;
    if (a.taa.z >= 1.0 || isnan(state[0])) return float4(c, 1.0);
    float ex = a.expo.x / max(exp(state[0]), 1e-6);
    float3 m1 = float3(0.0), m2 = float3(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float3 v = taaToYCoCg(cur.read(uint2(clamp(px + int2(x, y), int2(0), sz - 1))).rgb * ex);
            m1 += v;
            m2 += v * v;
        }
    }
    float3 mean = m1 / 9.0;
    float3 sigma = sqrt(max(m2 / 9.0 - mean * mean, float3(0.0)));
    float d = dist.read(uint2(px)).r;
    float3 rd = viewRay(in.uv, a);
    float4 pc = d > 0.0 ? prevVP * float4(a.camPos.xyz + rd * d, 1.0) : prevVP * float4(rd, 0.0);
    if (pc.w <= 0.0) return float4(c, 1.0);
    float2 puv = float2(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);
    if (any(puv < float2(0.0)) || any(puv > float2(1.0))) return float4(c, 1.0);
    float3 hy = taaToYCoCg(sampleCatmullRom(hist, puv) * ex);
    float3 lo = mean - sigma * 1.25, hi = mean + sigma * 1.25;
    float3 center = 0.5 * (hi + lo), ext = max(0.5 * (hi - lo), float3(1e-5));
    float3 off = hy - center;
    float3 r = abs(off / ext);
    float m = max(r.x, max(r.y, r.z));
    if (m > 1.0) hy = center + off / m;
    float3 cy = taaToYCoCg(c * ex);
    float3 o = mix(hy, cy, a.taa.z);
    return float4(min(taaFromYCoCg(o) / ex, float3(HDR_MAX)), 1.0);
}
"""
