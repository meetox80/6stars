let hudShaderSource = """

struct HudRectOut {
    float4 position [[position]];
    float2 uv;
    float2 pix;
};

struct HudRect {
    float4 rect;
    float2 viewport;
    float rotation;
    float pad;
};

vertex HudRectOut hudRectVertex(uint vid [[vertex_id]], constant HudRect& r [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 extent = r.rect.zw * 0.5;
    float2 centre = r.rect.xy + extent;
    float2 local = (corner - 0.5) * r.rect.zw;
    float s = sin(r.rotation), c = cos(r.rotation);
    float2 pix = centre + float2(local.x * c - local.y * s, local.x * s + local.y * c);
    HudRectOut o;
    o.position = float4(pix.x / r.viewport.x * 2.0 - 1.0, 1.0 - pix.y / r.viewport.y * 2.0, 0.0, 1.0);
    o.uv = corner;
    o.pix = pix;
    return o;
}

fragment float4 hudDown(QuadOut in [[stage_in]], texture2d<float> hdr [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(hdr.sample(s, in.uv).rgb, 1.0);
}

static float3 hudTonemap(float3 c, float2 uv, constant Atmos& a, device const float* state, texture2d<float> bloom) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 b = bloom.sample(s, uv, level(0.0)).rgb / max(a.post0.y, 1.0);
    return gradeTonemap(mix(c, b, a.post0.x), a, state);
}

fragment float4 hudBlur(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2& step [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    const float w[5] = { 0.2270270270, 0.1945945946, 0.1216216216, 0.0540540541, 0.0162162162 };
    float3 c = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        c += src.sample(s, in.uv + step * float(i)).rgb * w[i];
        c += src.sample(s, in.uv - step * float(i)).rgb * w[i];
    }
    return float4(c, 1.0);
}

struct HudMapVertex {
    packed_float2 p;
    uint surface;
};

struct HudMapView {
    float4 camera;
    float4 viewForward;
    float4 viewUp;
    float4 proj;
    float4 haze;
};

struct HudMapParams {
    float2 offset;
    float2 forward;
    float2 right;
    HudMapView view;
    float4 colors[4];
};

struct HudMapOut {
    float4 position [[position]];
    float4 color;
};

static float4 hudMapClip(float2 local, constant HudMapView& v, thread float& depth) {
    float3 q = float3(local, 0.0) - v.camera.xyz;
    depth = dot(q, v.viewForward.xyz);
    return float4(q.x / v.proj.x, dot(q, v.viewUp.xyz) / v.proj.y, depth * 0.5, depth);
}

static float3 hudMapHaze(float3 c, float depth, constant HudMapView& v) {
    return mix(c, v.haze.rgb, saturate((depth - v.proj.z) / v.proj.w) * v.haze.a);
}

vertex HudMapOut hudMapVertex(uint vid [[vertex_id]], const device HudMapVertex* v [[buffer(0)]], constant HudMapParams& m [[buffer(1)]]) {
    float2 d = float2(v[vid].p) + m.offset;
    float depth;
    HudMapOut o;
    o.position = hudMapClip(float2(dot(d, m.right), dot(d, m.forward)), m.view, depth);
    float4 c = m.colors[v[vid].surface & 3u];
    o.color = float4(hudMapHaze(c.rgb, depth, m.view), c.a);
    return o;
}

fragment float4 hudMapFragment(HudMapOut in [[stage_in]]) {
    return in.color;
}

struct HudMapGround {
    float4 player;
    float4 basis;
    float4 field;
    float4 size;
    float4 water;
    float4 land;
};

fragment float4 hudMapGroundFragment(QuadOut in [[stage_in]], constant HudMapView& v [[buffer(0)]], constant HudMapGround& g [[buffer(1)]],
                                     texture2d<float> heights [[texture(0)]]) {
    constexpr sampler hs(filter::linear, address::clamp_to_edge);
    float2 ndc = float2(in.position.x / g.size.x * 2.0 - 1.0, 1.0 - in.position.y / g.size.y * 2.0);
    float3 dir = v.viewForward.xyz + float3(ndc.x * g.size.z, 0.0, 0.0) + v.viewUp.xyz * (ndc.y * g.size.w);
    if (dir.z >= -1e-4) return float4(g.land.rgb, g.land.a);
    float3 hit = v.camera.xyz + dir * (-v.camera.z / dir.z);
    float2 world = g.player.xy + float2(g.basis.x, g.basis.y) * hit.x + float2(g.basis.z, g.basis.w) * hit.y;
    float2 uv = (world - g.field.xy) * g.field.z / float2(heights.get_width(), heights.get_height());
    float2 h = heights.sample(hs, uv).rg;
    bool outside = any(uv < float2(0.0)) || any(uv > float2(1.0));
    float depth = dot(hit - v.camera.xyz, v.viewForward.xyz);
    float4 c = (outside || (h.x < g.player.z && h.y < g.player.w)) ? g.water : g.land;
    return float4(hudMapHaze(c.rgb, depth, v), c.a);
}

struct HudPanel {
    float4 rect;
    float2 viewport;
    float radius;
    float borderWidth;
    float4 border;
};

fragment float4 hudMinimapFragment(HudRectOut in [[stage_in]], constant HudPanel& p [[buffer(0)]],
                                   constant Atmos& a [[buffer(1)]], device const float* state [[buffer(2)]],
                                   texture2d<float> blur [[texture(0)]], texture2d<float> map [[texture(1)]], texture2d<float> bloom [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 q = in.pix - p.rect.xy - p.rect.zw * 0.5;
    float2 inner = p.rect.zw * 0.5 - p.radius;
    float d = length(max(abs(q) - inner, 0.0)) + min(max(abs(q).x - inner.x, abs(q).y - inner.y), 0.0) - p.radius;
    float coverage = saturate(0.5 - d);
    float2 uv = in.pix / p.viewport;
    float3 background = hudTonemap(blur.sample(s, uv).rgb, uv, a, state, bloom);
    float2 texel = 0.6 / float2(map.get_width(), map.get_height());
    float4 m = 0.25 * (map.sample(s, in.uv + texel) + map.sample(s, in.uv - texel) +
                       map.sample(s, in.uv + float2(texel.x, -texel.y)) + map.sample(s, in.uv + float2(-texel.x, texel.y)));
    float3 c = mix(background, m.rgb, m.a);
    float half_w = p.borderWidth * 0.5;
    float ring = saturate(half_w + 0.5 - abs(d + half_w));
    c = mix(c, p.border.rgb, ring * p.border.a);
    return float4(c, coverage);
}

fragment float4 hudDiscFragment(HudRectOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4* colours [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, mip_filter::linear);
    float4 t = tex.sample(s, in.uv);
    float lum = dot(t.rgb, float3(0.2126, 0.7152, 0.0722));
    float4 c = mix(colours[1], colours[0], smoothstep(0.55, 0.9, lum));
    return float4(c.rgb, c.a * t.a);
}

static float3 hudLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}

fragment float4 hudSpriteFragment(HudRectOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4& tint [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, mip_filter::linear);
    float4 c = tex.sample(s, in.uv);
    return float4(hudLinear(c.rgb) * tint.rgb, c.a * tint.a);
}
"""
