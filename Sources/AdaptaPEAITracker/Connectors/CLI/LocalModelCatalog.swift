import Foundation

enum LocalModelCatalog {
    static func codex(at url: URL, now: Date, notBefore: Date) -> [String] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 4_194_305), data.count <= 4_194_304 else { return [] }
        return (try? codex(data, now: now, notBefore: notBefore)) ?? []
    }

    static func codex(_ data: Data, now: Date, notBefore: Date) throws -> [String] {
        let root = try LocalFiles.json(data)
        guard let fetched = LocalFiles.date(root["fetched_at"]), fetched >= notBefore,
              (0..<86_400).contains(now.timeIntervalSince(fetched)), let models = root["models"] as? [[String: Any]] else { return [] }
        return Array(Set(models.compactMap { model -> String? in
            guard model["visibility"] as? String == "list",
                  let id = model["slug"] as? String, !id.isEmpty, id.count <= 160 else { return nil }
            return id
        })).sorted()
    }
}
