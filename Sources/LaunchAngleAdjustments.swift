import Foundation

struct LaunchAngleAdjustment: Codable {
    let id: String
    let club: String
    let originalAngle: Double
    let adjustedAngle: Double
    let percentChange: Double
}

enum LaunchAngleAdjustments {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SC4 Muni Sender/launch-angle-adjustments.json")
    }

    static func load(_ data: Data) throws -> [LaunchAngleAdjustment] {
        let adjustments = try JSONDecoder().decode([LaunchAngleAdjustment].self, from: data)
        var seen = Set<String>()
        for entry in adjustments {
            guard !entry.id.isEmpty, seen.insert(entry.id).inserted,
                  entry.originalAngle.isFinite, entry.originalAngle != 0,
                  entry.adjustedAngle.isFinite, abs(entry.adjustedAngle) <= 90,
                  entry.percentChange.isFinite else {
                throw ReplayError.input("발사각 조정 파일의 샷 번호와 각도 범위를 확인해 주세요.")
            }
            let actual = (entry.adjustedAngle / entry.originalAngle - 1) * 100
            guard abs(actual) >= 1 - 1e-8, abs(actual) <= 5 + 1e-8,
                  abs(actual - entry.percentChange) < 1e-6 else {
                throw ReplayError.input("발사각 조정은 기준값의 1~5% 범위여야 합니다.")
            }
        }
        return adjustments
    }

    static func apply(_ adjustments: [LaunchAngleAdjustment], to shots: [SavedShot]) -> (shots: [SavedShot], count: Int) {
        let byID = Dictionary(adjustments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var count = 0
        let result = shots.map { original -> SavedShot in
            guard original.preserveRecordedValues != true,
                  let change = byID[original.id], original.club == change.club, !original.isPutt,
                  let angle = original.launchAngle, abs(angle - change.originalAngle) < 1e-9 else { return original }
            var adjusted = original
            adjusted.launchAngle = change.adjustedAngle
            adjusted.originalLaunchAngle = change.originalAngle
            adjusted.launchAngleIsAdjusted = true
            adjusted.launchAngleAdjustmentPercent = change.percentChange
            count += 1
            return adjusted
        }
        return (result, count)
    }
}
