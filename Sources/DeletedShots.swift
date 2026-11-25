import Foundation

enum DeletedShots {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SC4 Muni Sender/deleted-shot-ids.json")
    }

    static func load(_ data: Data) throws -> Set<String> {
        let ids = try JSONDecoder().decode([String].self, from: data)
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ReplayError.input("삭제된 샷 목록의 샷 번호를 확인해 주세요.")
        }
        return Set(ids)
    }

    static func apply(_ ids: Set<String>, to shots: [SavedShot]) -> [SavedShot] {
        shots.filter { !ids.contains($0.id) }
    }
}
