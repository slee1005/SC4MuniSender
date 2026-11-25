import Foundation
import CryptoKit

struct ShotImportResult {
    var shots: [SavedShot]
    var skipped: Int = 0
    var summaries: Int = 0
}

enum ShotImporter {
    static func load(_ data: Data, filename: String) throws -> ShotImportResult {
        guard data.count <= 20 * 1024 * 1024 else {
            throw ReplayError.input("파일이 너무 큽니다. 20MB 이하의 기록 파일을 선택해 주세요.")
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw ReplayError.input("UTF-8 형식의 CSV, JSON 또는 JSONL 파일을 선택해 주세요.")
        }
        let text = decoded.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        var result: ShotImportResult
        if text.hasPrefix("[") || text.hasPrefix("{") {
            let loaded = try ShotLoader.load(Data(text.utf8))
            result = ShotImportResult(shots: loaded.shots, skipped: loaded.skipped)
        } else {
            result = try csv(text)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        for index in result.shots.indices {
            result.shots[index].importSourceFile = filename
            result.shots[index].importedAt = now
        }
        return result
    }

    private static func key(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func csv(_ text: String) throws -> ShotImportResult {
        let rows = try CSVRows.parse(text)
        guard let header = rows.first else { throw ReplayError.input("비어 있는 기록 파일입니다.") }
        let keys = header.map(key)
        func column(_ aliases: [String]) -> Int? {
            keys.firstIndex { aliases.contains($0) }
        }
        let ball = column(["ballspeedmph", "ballspeedms", "ballspeedkmh", "ballspeed"])
        let clubSpeed = column(["swingspeedmph", "swingspeedms", "swingspeedkmh", "clubspeed", "clubspeedmph", "clubspeedms", "clubspeedkmh"])
        let carry = column(["carryyd", "carrym", "carryft", "carrydistance", "carry"])
        let total = column(["totalyd", "totalm", "totalft", "totaldistance", "total"])
        let angle = column(["launchangledeg", "launchangle", "vla"])
        let direction = column(["launchdirectiondeg", "launchdirection", "hla"])
        let spin = column(["spinrpm", "spin", "totalspin"])
        let axis = column(["spinaxis", "spinaxisdeg"])
        guard ball != nil, carry != nil || angle != nil || spin != nil else {
            throw ReplayError.input("SC4 샷 CSV의 헤더를 찾을 수 없습니다. MySwingCaddie 또는 SC4 Shot Collector에서 내보낸 파일을 선택해 주세요.")
        }
        let id = column(["id"]), date = column(["shottime", "timestamp", "date"])
        let received = column(["receivedat"]), club = column(["club", "eq"])
        let number = column(["no", "number"]), distanceUnit = column(["distanceunit"])
        let speedUnit = column(["speedunit"]), apex = column(["apexft", "apexm", "apex"])
        let smash = column(["smashfactor"]), source = column(["source"]), raw = column(["rawhex"])
        let summaries = Set(["avg", "average", "mean", "min", "max", "total", "평균", "최소", "최대", "합계"])
        var result = ShotImportResult(shots: [])
        var occurrences: [String: Int] = [:]
        for row in rows.dropFirst() {
            func value(_ index: Int?) -> String? {
                guard let index = index, index < row.count else { return nil }
                let text = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            if let first = value(number ?? 0), summaries.contains(first.lowercased()) {
                result.summaries += 1
                continue
            }
            guard row.count == header.count else { result.skipped += 1; continue }
            do {
                func numeric(_ index: Int?) throws -> Double? {
                    guard let text = value(index), !["-", "—", "n/a", "na", "null"].contains(text.lowercased()) else { return nil }
                    guard let number = Double(text), number.isFinite else { throw ReplayError.invalidFile }
                    return number
                }
                func distance(_ index: Int?) throws -> Double? {
                    guard let number = try numeric(index), let index = index else { return nil }
                    let unit = keys[index].hasSuffix("yd") ? "yd" : keys[index].hasSuffix("ft") ? "ft"
                        : keys[index].hasSuffix("m") ? "m" : (value(distanceUnit) ?? "").lowercased()
                    let factor: Double
                    switch unit {
                    case "m", "meter", "meters": factor = 1
                    case "yd", "yard", "yards": factor = 0.9144
                    case "ft", "feet": factor = 0.3048
                    default:
                        // Collector apex follows its declared distance unit; no unit is guessed.
                        throw ReplayError.input("거리 단위를 확인할 수 없습니다.")
                    }
                    return number * factor
                }
                func speed(_ index: Int?) throws -> Double? {
                    guard let number = try numeric(index), let index = index else { return nil }
                    let unit = keys[index].hasSuffix("mph") ? "mph" : keys[index].hasSuffix("kmh") ? "km/h"
                        : keys[index].hasSuffix("ms") ? "m/s" : (value(speedUnit) ?? "").lowercased()
                    switch unit {
                    case "mph": return number * 0.44704
                    case "m/s", "mps": return number
                    case "km/h", "kmh", "kph": return number / 3.6
                    default: throw ReplayError.input("속도 단위를 확인할 수 없습니다.")
                    }
                }
                let ballValue = try speed(ball)
                let carryValue = try distance(carry)
                let angleValue = try numeric(angle)
                let spinValue = try numeric(spin)
                guard ballValue != nil || carryValue != nil || angleValue != nil || spinValue != nil else {
                    result.skipped += 1; continue
                }
                // Stable across renames/reordered exports; occurrence distinguishes identical rows.
                let rowData = try JSONEncoder().encode(zip(keys, row).map { [$0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)] }.sorted { $0[0] < $1[0] })
                let digest = SHA256.hash(data: rowData).map { String(format: "%02x", $0) }.joined()
                let occurrence = occurrences[digest, default: 0]
                occurrences[digest] = occurrence + 1
                var shot = SavedShot(id: value(id) ?? "csv-\(digest)-\(occurrence)")
                shot.timestamp = value(date)
                shot.receivedAt = value(received)
                shot.club = value(club).flatMap { ["off", "-"].contains($0.lowercased()) ? nil : $0 }
                shot.carryDistance = carryValue
                shot.totalDistance = try distance(total)
                shot.ballSpeed = ballValue
                shot.clubSpeed = try speed(clubSpeed)
                shot.launchAngle = angleValue
                shot.launchDirection = try numeric(direction)
                shot.spinRPM = spinValue
                shot.spinAxis = try numeric(axis)
                shot.distanceUnit = "m"
                shot.speedUnit = "m/s"
                shot.apex = try distance(apex)
                shot.smashFactor = try numeric(smash)
                shot.source = value(source) ?? "csv_import"
                shot.rawHex = value(raw)
                result.shots.append(shot)
            } catch { result.skipped += 1 }
        }
        guard !result.shots.isEmpty else {
            throw ReplayError.input("가져올 샷이 없습니다. CSV의 숫자·단위와 평균 행 이외의 기록이 있는지 확인해 주세요.")
        }
        return result
    }
}

/// Quoted commas, doubled quotes, CRLF and multiline fields are supported.
enum CSVRows {
    static func parse(_ text: String) throws -> [[String]] {
        let chars = Array(text)
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        for char in chars {
            if char == "\"" { quoted.toggle() }
            if !quoted {
                if char == "\n" || char == "\r" || char == "\r\n" { break }
                if counts[char] != nil { counts[char, default: 0] += 1 }
            }
        }
        let delimiter = counts.max { $0.value < $1.value }?.key ?? ","
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inside = false, afterQuote = false, index = 0
        func finishRow() {
            row.append(field)
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []; field = ""; afterQuote = false
        }
        while index < chars.count {
            let char = chars[index]
            if inside {
                if char == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { inside = false; afterQuote = true }
                } else { field.append(char) }
            } else if char == delimiter {
                row.append(field); field = ""; afterQuote = false
            } else if char == "\n" || char == "\r" || char == "\r\n" {
                finishRow()
                if char == "\r" && index + 1 < chars.count && chars[index + 1] == "\n" { index += 1 }
            } else if char == "\"" && field.isEmpty && !afterQuote {
                inside = true
            } else if afterQuote {
                guard char == " " else { throw ReplayError.input("CSV의 따옴표 형식을 확인해 주세요.") }
            } else {
                guard char != "\"" else { throw ReplayError.input("CSV의 따옴표 형식을 확인해 주세요.") }
                field.append(char)
            }
            index += 1
        }
        guard !inside else { throw ReplayError.input("CSV의 닫히지 않은 따옴표를 확인해 주세요.") }
        if !field.isEmpty || !row.isEmpty || afterQuote { finishRow() }
        return rows
    }
}

struct ShotImportStore {
    var url: URL
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SC4 Muni Sender/imported-shots.json")
    }

    func load() throws -> [SavedShot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SavedShot].self, from: Data(contentsOf: url))
    }

    func add(_ incoming: [SavedShot], originals: [SavedShot]) throws -> (added: [SavedShot], duplicates: Int) {
        let existing = try load() // Fail closed rather than overwrite a damaged import library.
        var seen = Set((originals + existing).map(\.id))
        let added = incoming.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        if !added.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(existing + added)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return (added, incoming.count - added.count)
    }

    static func merge(originals: [SavedShot], imported: [SavedShot]) -> [SavedShot] {
        var seen = Set<String>()
        return (originals + imported).filter { seen.insert($0.id).inserted }
            .sorted { $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate }
    }
}
