import Foundation
import Metal

private func systemVRAMTotalGB() -> Double {
    let bytes = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? ProcessInfo.processInfo.physicalMemory
    return Double(bytes) / 1e9
}

// MARK: - Ollama

struct OllamaConnector: UsageConnector {
    let info = ProviderInfo(id: "ollama", name: "Ollama", kind: .local, iconURL: ProviderInfo.lobeIcon("ollama"), auth: .automatic)

    init() {}

    func fetch() async throws -> ProviderUsage? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/ps") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        guard let (data, response) = try? await HTTP.session.data(for: request, delegate: SameHostRedirects.shared),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let res = try? JSONDecoder().decode(OllamaResponse.self, from: data) else { return nil }

        let models = res.models ?? []
        let loaded = models.compactMap { $0.name?.isEmpty == false ? $0.name : nil }
        let loadedModel = loaded.isEmpty ? nil : loaded.joined(separator: ", ")
        let vramBytes = models.reduce(0.0) { $0 + Double($1.sizeVram ?? 0) }

        var usage = ProviderUsage(info: info)
        usage.local = LocalStats(vramUsedGB: vramBytes / 1e9, vramTotalGB: systemVRAMTotalGB(), tokensPerSecond: nil, loadedModel: loadedModel)
        usage.activity = loadedModel != nil ? .processing(task: nil) : .idle
        usage.summary = nil
        return usage
    }
}

private struct OllamaResponse: Decodable {
    struct Model: Decodable {
        let name: String?
        let sizeVram: Int64?
        enum CodingKeys: String, CodingKey { case name; case sizeVram = "size_vram" }
    }
    let models: [Model]?
}

// MARK: - LM Studio

struct LMStudioConnector: UsageConnector {
    let info = ProviderInfo(id: "lmstudio", name: "LM Studio", kind: .local, iconURL: ProviderInfo.lobeIcon("lmstudio"), auth: .automatic)

    init() {}

    func fetch() async throws -> ProviderUsage? {
        guard let url = URL(string: "http://127.0.0.1:1234/api/v0/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        guard let (data, response) = try? await HTTP.session.data(for: request, delegate: SameHostRedirects.shared),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lmstudio")
            guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
            var usage = ProviderUsage(info: info)
            usage.activity = .offline
            usage.summary = "Servidor local apagado"
            return usage
        }

        let res = try? JSONDecoder().decode(LMStudioResponse.self, from: data)
        let loaded = (res?.data ?? []).compactMap { $0.state == "loaded" ? $0.id : nil }
        let loadedModel = loaded.isEmpty ? nil : loaded.joined(separator: ", ")

        var usage = ProviderUsage(info: info)
        usage.local = LocalStats(vramUsedGB: await fetchLMSVRAM(), vramTotalGB: systemVRAMTotalGB(), tokensPerSecond: nil, loadedModel: loadedModel)
        usage.activity = loadedModel != nil ? .processing(task: nil) : .idle
        usage.summary = nil
        return usage
    }

    private func fetchLMSVRAM() async -> Double {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lmstudio/bin/lms")
        guard FileManager.default.isExecutableFile(atPath: bin.path),
              let out = await runProcess(bin, args: ["ps", "--json"], timeout: 3) else { return 0 }
        let items = (try? JSONDecoder().decode(LMSPSResponse.self, from: out))?.items ?? []
        return items.compactMap(\.sizeBytes).reduce(0, +) / 1e9
    }
}

private struct LMStudioResponse: Decodable {
    struct Model: Decodable { let id: String?; let state: String? }
    let data: [Model]?
}

private struct LMSPSResponse: Decodable {
    struct Item: Decodable { let sizeBytes: Double? }
    let items: [Item]

    init(from decoder: Decoder) throws {
        if let arr = try? decoder.singleValueContainer().decode([Item].self) {
            items = arr
        } else {
            struct Wrap: Decodable { let models: [Item]?; let data: [Item]?; let entries: [Item]? }
            let w = try? Wrap(from: decoder)
            items = w?.models ?? w?.data ?? w?.entries ?? []
        }
    }
}

// MARK: - Subprocess Helper

private func runProcess(_ url: URL, args: [String], timeout: TimeInterval) async -> Data? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: LocalFiles.processOutput(
                executable: url.path, arguments: args, timeout: timeout, limit: 1_048_576))
        }
    }
}
