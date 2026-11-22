import Foundation
import simd
import RPFKit

struct Timecycle {
    let cycle: String
    let hours: [Float]
    let vars: [String: [Float]]
    let weather: [String: Float]

    func value(_ name: String, at hour: Float) -> Float? {
        guard let a = vars[name] else { return nil }
        guard a.count == hours.count, a.count > 1 else { return a.first }
        var h = hour.truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        var i = hours.count - 1
        for k in 0..<hours.count where hours[k] <= h { i = k }
        let j = (i + 1) % hours.count
        let h0 = hours[i]
        var h1 = hours[j]
        if j == 0 { h1 += 24 }
        if h < h0 { h += 24 }
        let t = (h - h0) / max(h1 - h0, 1e-3)
        return a[i] + (a[j] - a[i]) * t
    }

    static func load(archive: String, indexPath: String, cycle: String, region: String = "GLOBAL") throws -> Timecycle {
        let f = try MappedFile(path: archive)
        let idx: ArchiveIndex
        if let i = try? ArchiveIndex.read(from: indexPath) {
            idx = i
        } else {
            idx = ArchiveIndex.scan(f)
            try? idx.write(to: indexPath)
        }
        let all = idx.entries.filter { $0.kind == .zlib }.sorted { $0.offset < $1.offset }
        let cycleTag = "<cycle name=\"\(cycle)\""
        var cycleText: String?
        var timeText: String?
        var weatherText: String?
        let weatherTag = "<Name>\(cycle.uppercased())</Name>"
        var i = 0
        while i < all.count, cycleText == nil || timeText == nil || weatherText == nil {
            let e = all[i]
            i += 1
            guard var b = try? idx.load(e, from: f), b.count > 16 else { continue }
            var last = b.count
            while last == 0x10000, i < all.count, let nb = try? idx.load(all[i], from: f) {
                b += nb
                last = nb.count
                i += 1
            }
            let s = String(decoding: b, as: UTF8.self)
            if cycleText == nil, s.contains(cycleTag) { cycleText = s }
            if timeText == nil, s.contains("<time_data") { timeText = s }
            if weatherText == nil, s.contains(weatherTag), s.contains("<WindAngle") { weatherText = s }
        }
        guard let ct = cycleText, let cr = ct.range(of: cycleTag) else { throw RPFError.format("timecycle \(cycle) not found in \(archive)") }
        guard let tt = timeText else { throw RPFError.format("timecycle time_data not found in \(archive)") }
        var hours: [Float] = []
        var rest = tt[...]
        while let r = rest.range(of: "hour=\"") {
            let tail = rest[r.upperBound...]
            guard let q = tail.firstIndex(of: "\""), let h = Float(tail[..<q]) else { break }
            hours.append(h)
            rest = tail[q...]
        }
        let body = ct[cr.upperBound...]
        guard let rr = body.range(of: "<region name=\"\(region)\""), let end = body[rr.upperBound...].range(of: "</region>") else {
            throw RPFError.format("timecycle \(cycle) has no \(region) region")
        }
        var vars: [String: [Float]] = [:]
        for raw in body[rr.upperBound..<end.lowerBound].split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("<"), !line.hasPrefix("</"), let close = line.firstIndex(of: ">"), let endTag = line.range(of: "</") else { continue }
            let name = String(line[line.index(after: line.startIndex)..<close])
            guard close < endTag.lowerBound else { continue }
            let nums = line[line.index(after: close)..<endTag.lowerBound].split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
            if !nums.isEmpty { vars[name] = nums }
        }
        var weather: [String: Float] = [:]
        if let wt = weatherText, let wr = wt.range(of: weatherTag), let we = wt[wr.upperBound...].range(of: "</Item>") {
            for raw in wt[wr.upperBound..<we.lowerBound].split(whereSeparator: { $0.isNewline }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("<"), let sp = line.firstIndex(of: " "), let vr = line.range(of: "value=\"") else { continue }
                let tail = line[vr.upperBound...]
                guard let q = tail.firstIndex(of: "\""), let v = Float(tail[..<q]) else { continue }
                weather[String(line[line.index(after: line.startIndex)..<sp])] = v
            }
        }
        guard !hours.isEmpty, !vars.isEmpty else { throw RPFError.format("timecycle \(cycle) is empty: \(hours.count) hours, \(vars.count) values") }
        return Timecycle(cycle: cycle, hours: hours, vars: vars, weather: weather)
    }

    static func sunDirection(hour: Float, dayOfYear: Int, latitude: Float) -> SIMD3<Float> {
        let decl = -23.44 * Float.pi / 180 * cos(2 * Float.pi / 365 * Float(dayOfYear + 10))
        let ha = (hour - 12) * 15 * Float.pi / 180
        let lat = latitude * Float.pi / 180
        let east = -cos(decl) * sin(ha)
        let north = cos(lat) * sin(decl) - sin(lat) * cos(decl) * cos(ha)
        let up = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha)
        return simd_normalize(SIMD3(east, north, up))
    }
}
