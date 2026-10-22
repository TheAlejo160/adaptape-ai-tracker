import Foundation

struct QuotaSample: Codable, Equatable, Identifiable, Sendable {
    var date: Date
    let providerID: String
    let providerName: String
    let window: String
    let duration: TimeInterval?
    var used: Double
    let unverified: Bool

    var id: String { "\(providerID)|\(window)|\(Int(date.timeIntervalSince1970 / 3600))" }
    var series: String { "\(providerName) · \(window)" }
    var windowKind: String {
        switch duration {
        case 18_000: "5h"
        case 604_800: "weekly"
        default: "other"
        }
    }
}

enum QuotaHistory {
    static let retention: TimeInterval = 35 * 86_400
    static let maxSamples = 20_000
    static let fileURL = LocalFiles.home("Library/Application Support/AdaptaPE AI Tracker/quota-history.json")

    static func visible(_ samples: [QuotaSample], providerID: String, days: Int, window: String, now: Date) -> [QuotaSample] {
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        return samples.filter { sample in
            sample.date >= start && sample.date <= now && (providerID.isEmpty || providerID == sample.providerID)
                && sample.windowKind == window
        }
    }

    static func recording(_ providers: [ProviderUsage], into existing: [QuotaSample], now: Date) -> [QuotaSample] {
        var samples = Dictionary(existing.filter { valid($0, now: now) }.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.date > b.date ? a : b })
        for provider in providers where !provider.id.hasPrefix("demo-") {
            guard provider.error == nil || provider.observedAt != nil else { continue }
            let date = provider.observedAt ?? now
            for window in provider.windows {
                let sample = QuotaSample(date: date, providerID: provider.id, providerName: provider.name, window: window.label,
                    duration: window.duration, used: window.used,
                    unverified: provider.quotaSource?.contains("sin verificar") == true || provider.error?.contains("sin verificar") == true)
                guard valid(sample, now: now), samples[sample.id].map({ $0.date <= sample.date }) ?? true else { continue }
                samples[sample.id] = sample
            }
        }
        return Array(samples.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.suffix(maxSamples))
    }

    static func load(from url: URL, now: Date) -> [QuotaSample] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 8_388_609), data.count <= 8_388_608,
              let samples = try? JSONDecoder().decode([QuotaSample].self, from: data) else { return [] }
        return recording([], into: samples, now: now)
    }

    static func save(_ samples: [QuotaSample], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var retained = Array(samples.suffix(maxSamples))
        var data = try JSONEncoder().encode(retained)
        while data.count > 8_388_608 {
            retained = Array(retained.suffix(retained.count / 2))
            data = try JSONEncoder().encode(retained)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func valid(_ sample: QuotaSample, now: Date) -> Bool {
        sample.date.timeIntervalSince1970.isFinite && (0...retention).contains(now.timeIntervalSince(sample.date))
            && sample.used.isFinite && (0...1).contains(sample.used)
            && (sample.duration.map { $0.isFinite && $0 > 0 } ?? true)
            && !sample.providerID.isEmpty && sample.providerID.count <= 160
            && !sample.providerName.isEmpty && sample.providerName.count <= 160
            && !sample.window.isEmpty && sample.window.count <= 240
    }
}
