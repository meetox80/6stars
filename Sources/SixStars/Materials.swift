import Foundation
import Metal
import RPFKit

enum MaterialKind: UInt32 {
    case opaque = 0
    case cutout = 1
    case decal = 2
    case alpha = 3
    case water = 4
    case hidden = 5
}

enum WeightScheme: UInt32 {
    case single = 0
    case baseRGB = 1
    case baseB = 2
    case baseR = 3
}

struct MaterialFlags {
    static let aoFromColor0: UInt32 = 1
    static let alphaFromColor0: UInt32 = 2
    static let emissive: UInt32 = 4
    static let alphaTest: UInt32 = 8
    static let normalMap: UInt32 = 16
    static let textureAlpha: UInt32 = 32
}

struct GPUMaterial {
    var diffuse: (UInt32, UInt32, UInt32, UInt32)
    var normal: (UInt32, UInt32, UInt32, UInt32)
    var kind: UInt32
    var scheme: UInt32
    var flags: UInt32
    var layers: UInt32
    var spec: UInt32 = 0
}

struct MaterialDesc {
    var kind: MaterialKind
    var scheme: WeightScheme
    var diffuse: [UInt64]
    var normal: [UInt64]
    var flags: UInt32
    var spec: UInt64 = 0
}

enum ShaderTable {
    static let knownNames: [String] = [
        "cable",
        "distance_map",
        "grass_batch",
        "grass_batch_floating_veg",
        "grass_batch_floating_veg_no_bump",
        "grass_batch_lod",
        "grass_batch_lod_wind",
        "grass_batch_wind",
        "minimap",
        "minimap_hd_buildings",
        "minimap_interior",
        "ped_standard_lod_muv",
        "ped_standard_muv",
        "ped_standard_muv_alpha",
        "ped_standard_muv_secmo",
        "prop_2lyr_batch",
        "prop_batch",
        "prop_batch_2lyr_roadsign",
        "prop_batch_alpha_wind",
        "prop_batch_anisotropy",
        "prop_batch_decal",
        "prop_batch_decal_blend",
        "prop_batch_decal_blend_text",
        "prop_batch_decal_blend_um_wind",
        "prop_batch_decal_um_wind",
        "prop_batch_dirt",
        "prop_batch_dirt_cutout",
        "prop_batch_dirt_decal",
        "prop_batch_dirt_um_wind",
        "prop_batch_lod",
        "prop_batch_retroreflection",
        "prop_batch_retroreflection_dirt",
        "prop_batch_slod",
        "prop_batch_slod_regiontint",
        "prop_batch_slod_regiontint_cpv",
        "prop_batch_standard_2lyr_decal",
        "prop_batch_standard_2lyr_pxm",
        "prop_batch_standard_alpha",
        "prop_batch_standard_fabric_dirt",
        "prop_batch_um_wind",
        "radar",
        "signs",
        "signs_emissive",
        "standard",
        "standard_2lyr",
        "standard_2lyr_anisotropy",
        "standard_2lyr_curved_interior",
        "standard_2lyr_cutout_hbb",
        "standard_2lyr_cutout_hbb_ground",
        "standard_2lyr_cutout_hbb_secmo",
        "standard_2lyr_decal",
        "standard_2lyr_decal_blend",
        "standard_2lyr_decal_blend_ground",
        "standard_2lyr_decal_ground",
        "standard_2lyr_decal_hbb",
        "standard_2lyr_decal_hbb_ground",
        "standard_2lyr_doublesided",
        "standard_2lyr_doublesided_secmo",
        "standard_2lyr_fabric",
        "standard_2lyr_fabric_anisotropy",
        "standard_2lyr_fabric_anisotropy_secmo",
        "standard_2lyr_fabric_pxm",
        "standard_2lyr_fabric_secmo",
        "standard_2lyr_ground",
        "standard_2lyr_interior",
        "standard_2lyr_pxm",
        "standard_2lyr_pxm_decal",
        "standard_2lyr_pxm_decal_ground",
        "standard_2lyr_pxm_decal_hbb",
        "standard_2lyr_pxm_decal_hbb_ground",
        "standard_2lyr_pxm_ground",
        "standard_2lyr_pxm_interior",
        "standard_2lyr_retroreflection_decal_blend",
        "standard_2lyr_roadsign",
        "standard_2lyr_secmo",
        "standard_2lyr_terrain_decal_ground",
        "standard_3lyr",
        "standard_3lyr_ground",
        "standard_3lyr_pxm",
        "standard_3lyr_pxm_ground",
        "standard_3lyr_secmo",
        "standard_4lyr",
        "standard_4lyr_ground",
        "standard_4lyr_pxm",
        "standard_4lyr_pxm_ground",
        "standard_alpha",
        "standard_alpha_inst",
        "standard_alpha_liquid",
        "standard_alpha_liquid_opaque_liquid",
        "standard_alpha_liquid_open_vessel",
        "standard_alpha_secmo",
        "standard_alpha_water",
        "standard_alpha_waterfall",
        "standard_anisotropy",
        "standard_anisotropy_dirt",
        "standard_anisotropy_dirt_alpha",
        "standard_anisotropy_dirt_plus_normal",
        "standard_batch",
        "standard_blur_transmission",
        "standard_clearcoat",
        "standard_clearcoat_flakes",
        "standard_clearcoat_glints",
        "standard_cloth",
        "standard_cutout_hbb",
        "standard_cutout_hbb_ground",
        "standard_cutout_hbb_secmo",
        "standard_decal",
        "standard_decal_blend",
        "standard_decal_blend_ground",
        "standard_decal_blend_secmo",
        "standard_decal_blend_text",
        "standard_decal_grass",
        "standard_decal_ground",
        "standard_decal_hbb",
        "standard_decal_hbb_ground",
        "standard_decal_heightmap",
        "standard_decal_normal_only",
        "standard_decal_normal_only_ground",
        "standard_decal_secmo",
        "standard_diffraction",
        "standard_dirt",
        "standard_dirt_alpha",
        "standard_dirt_alpha_no_spec",
        "standard_dirt_alpha_secmo",
        "standard_dirt_cutout",
        "standard_dirt_cutout_ground",
        "standard_dirt_cutout_secmo",
        "standard_dirt_decal",
        "standard_dirt_ground",
        "standard_dirt_plus_normal",
        "standard_dirt_pxm",
        "standard_dirt_pxm_ground",
        "standard_dirt_secmo",
        "standard_doublesided",
        "standard_doublesided_cutout",
        "standard_doublesided_cutout_secmo",
        "standard_doublesided_dirt",
        "standard_doublesided_dirt_secmo",
        "standard_doublesided_secmo",
        "standard_dynamictint",
        "standard_emissive",
        "standard_emissive_animated",
        "standard_emissive_animated_bones",
        "standard_emissive_animated_inst",
        "standard_emissive_layer",
        "standard_emissive_layer_alpha",
        "standard_emissive_layer_batch",
        "standard_emissive_layer_dirt",
        "standard_emissive_layer_inst",
        "standard_emissive_layer_pxm_inst",
        "standard_emissive_layer_wind_batch",
        "standard_emissive_lightmap_v2",
        "standard_fabric",
        "standard_fabric_anisotropy",
        "standard_fabric_anisotropy_dirt",
        "standard_fabric_anisotropy_dirt_secmo",
        "standard_fabric_anisotropy_secmo",
        "standard_fabric_dirt",
        "standard_fabric_dirt_secmo",
        "standard_fabric_pxm_dirt",
        "standard_fabric_secmo",
        "standard_fur",
        "standard_fur_ground",
        "standard_glass_breakable",
        "standard_glass_breakable_dirt",
        "standard_ground",
        "standard_hair_accessory",
        "standard_haze",
        "standard_inst",
        "standard_interior",
        "standard_iridescence",
        "standard_iridescence_alpha",
        "standard_iridescence_decal",
        "standard_iridescence_decal_hbb_ground",
        "standard_lod",
        "standard_pv_v2",
        "standard_pxm",
        "standard_pxm_decal",
        "standard_pxm_decal_ground",
        "standard_pxm_ground",
        "standard_rdp",
        "standard_retroreflection",
        "standard_retroreflection_batch",
        "standard_retroreflection_decal_blend",
        "standard_retroreflection_decal_hbb",
        "standard_retroreflection_dirt",
        "standard_secmo",
        "standard_uber_4lyr",
        "standard_uber_4lyr_dfm_dm_hbb",
        "standard_uber_4lyr_dfm_dm_hbb_uv3",
        "standard_uber_4lyr_dpm_dfm_dm_hbb",
        "standard_uber_4lyr_dpm_dfm_dm_hbb_uv3",
        "standard_uber_4lyr_dpm_dm_hbb",
        "standard_uber_4lyr_dpm_dm_hbb_uv3",
        "standard_uber_4lyr_mud_dm_hbb",
        "standard_uber_4lyr_mud_dm_hbb_uv3",
        "standard_uber_4lyr_pxm",
        "standard_uber_4lyr_pxm_hbb",
        "standard_uber_4lyr_pxm_hbb_fixuv1",
        "standard_uber_4lyr_pxm_hbb_uv3",
        "standard_uber_4lyr_spx_dm_hbb",
        "standard_uber_4lyr_spx_dm_hbb_uv3",
        "standard_uber_4lyr_uv3",
        "standard_vehicle",
        "standard_vehicle_2lyr",
        "standard_vehicle_2lyr_alpha",
        "standard_vehicle_2lyr_cutout",
        "standard_vehicle_2lyr_decal",
        "standard_vehicle_2lyr_decal_prop",
        "standard_vehicle_2lyr_emissive_brakedisc_inst",
        "standard_vehicle_2lyr_licenseplate",
        "standard_vehicle_2lyr_lod",
        "standard_vehicle_2lyr_prop",
        "standard_vehicle_2lyr_reflector",
        "standard_vehicle_2lyr_reflector_prop",
        "standard_vehicle_2lyr_secmo",
        "standard_vehicle_2lyr_signs",
        "standard_vehicle_2lyr_tyre_inst",
        "standard_vehicle_2lyr_tyre_inst_lod",
        "standard_vehicle_2lyr_wheel_inst",
        "standard_vehicle_adverts",
        "standard_vehicle_alpha",
        "standard_vehicle_decal",
        "standard_vehicle_emissive_animated_bones",
        "standard_vehicle_emissive_layer",
        "standard_vehicle_glass",
        "standard_with_fur",
        "structure_lod_wetness",
        "terrain_decal",
        "terrain_decal_ground",
        "terrain_lod_2lyr_grass_wetness",
        "terrain_lod_grass_wetness",
        "trees_camera_facing_wind",
        "trees_standard",
        "trees_standard_underwater",
        "trees_standard_vehicle_clip_wind",
        "trees_standard_wind",
        "trunk",
        "trunk_nodpm_decal_blend_wind",
        "trunk_um_wind",
        "trunk_wind",
        "vehicle_water_stencil",
        "water_bucket",
        "water_micro_geom",
        "weapon_standard",
        "windshield_wipermask"
    ]

    static let byHash: [UInt32: String] = {
        var d: [UInt32: String] = [:]
        for n in knownNames { d[Hash.joaat(n)] = n }
        return d
    }()

    static let diffuseParam: UInt32 = 0xC8E8_C282
    static let specularParam: UInt32 = 0xC6F4_6E79
    static let normalParam: UInt32 = 0x1E77_BF4C
    static let uberDiffuse: [UInt32] = [0x3D10_F3B7, 0xCE7B_968E, 0xD883_AA9E, 0x32B9_DF09]
    static let uberNormal: [UInt32] = [0xDE84_C011, 0x27DB_D2BE, 0x7E1F_7F44, 0x4C75_9BF1]
    static let layerBase: UInt32 = 0x7485_DAFB
    static let layerDiffuse: [UInt32] = [0x7D4F_12E2]
    static let layerNormal: [UInt32] = [0x58B6_E707]
    static let overlayDiffuse: UInt32 = 0x3463_94EA

    static func describe(_ s: ShaderInfo, exists: (UInt64) -> Bool) -> MaterialDesc {
        let n = byHash[s.name] ?? ""
        func tex(_ p: UInt32) -> UInt64 { s.textures.first(where: { $0.param == p })?.hash ?? 0 }
        var kind = MaterialKind.opaque
        var flags: UInt32 = 0
        if n.contains("minimap") || n == "distance_map" || n.contains("water_stencil") || n.contains("wipermask") || n.contains("normal_only") || n == "water_bucket" {
            kind = .hidden
        } else if n.hasPrefix("water") || n.contains("_water") {
            kind = .water
        } else if n.contains("decal") {
            kind = .decal
            flags |= MaterialFlags.alphaFromColor0 | MaterialFlags.textureAlpha
        } else if n.contains("alpha") || n.contains("glass") || n.contains("_haze") || n.contains("blur_transmission") || n.contains("liquid") {
            kind = .alpha
            flags |= MaterialFlags.textureAlpha
        } else if n.contains("cutout") || n.hasPrefix("trees") || n.hasPrefix("grass") || n.contains("fur") || n.contains("hair") || n.contains("doublesided") || n.contains("signs") {
            kind = .cutout
            flags |= MaterialFlags.alphaTest
        }
        if n.contains("emissive") || n.hasPrefix("signs") { flags |= MaterialFlags.emissive }
        var scheme = WeightScheme.single
        var diffuse: [UInt64] = []
        var normal: [UInt64] = []
        if n.contains("uber_4lyr") {
            scheme = .baseRGB
            diffuse = uberDiffuse.map(tex)
            normal = uberNormal.map(tex)
        } else if (n.contains("_2lyr") || n.contains("_3lyr") || n.contains("_4lyr") || n.hasPrefix("prop_2lyr")) && !n.hasPrefix("terrain") && tex(diffuseParam) == 0 {
            let base = tex(layerBase), over = tex(layerDiffuse[0])
            if base != 0 && exists(base) {
                scheme = .baseB
                diffuse = [base, over]
                normal = [0, tex(layerNormal[0])]
            } else {
                diffuse = [tex(overlayDiffuse) != 0 ? tex(overlayDiffuse) : over]
                normal = [tex(0x84C6_9350)]
            }
            flags |= MaterialFlags.aoFromColor0
        } else {
            var d = tex(diffuseParam)
            if d == 0 || !exists(d) {
                for p in [overlayDiffuse, layerDiffuse[0], layerBase] where tex(p) != 0 && exists(tex(p)) { d = tex(p); break }
            }
            diffuse = [d]
            normal = [tex(normalParam)]
            if !n.hasPrefix("terrain") && !n.hasPrefix("structure_lod") && !n.hasPrefix("cable") { flags |= MaterialFlags.aoFromColor0 }
        }
        if normal.contains(where: { $0 != 0 && exists($0) }) { flags |= MaterialFlags.normalMap }
        let spec = tex(specularParam)
        return MaterialDesc(kind: kind, scheme: scheme, diffuse: diffuse, normal: normal, flags: flags, spec: exists(spec) ? spec : 0)
    }
}

final class MaterialRegistry {
    let buffer: MTLBuffer
    let capacity: Int
    let lock = NSLock()
    var count = 0
    var ids: [String: UInt32] = [:]
    var keys: [String] = []

    init(device: MTLDevice, capacity: Int = 1 << 20) {
        self.capacity = capacity
        buffer = device.makeBuffer(length: capacity * MemoryLayout<GPUMaterial>.stride, options: .storageModeShared)!
        _ = add(GPUMaterial(diffuse: (0, 0, 0, 0), normal: (1, 1, 1, 1), kind: 0, scheme: 0, flags: 0, layers: 1), key: "default")
    }

    func add(_ m: GPUMaterial, key: String) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        if let id = ids[key] { return id }
        guard count < capacity else { return 0 }
        let id = UInt32(count)
        buffer.contents().advanced(by: count * MemoryLayout<GPUMaterial>.stride).storeBytes(of: m, as: GPUMaterial.self)
        count += 1
        ids[key] = id
        keys.append(key)
        return id
    }
}
