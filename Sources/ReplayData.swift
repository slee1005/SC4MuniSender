import Foundation

enum DistanceDisplayUnit: String, CaseIterable, Identifiable {
    case meters = "m"
    case yards = "yd"
    var id: String { rawValue }
    var title: String { self == .meters ? "미터 (m)" : "야드 (yd)" }
    func carry(for shot: SavedShot) -> Double? {
        self == .meters ? shot.carryMeters : shot.carryYards
    }
}

struct SavedShot: Codable, Identifiable, Hashable {
    let id: String
    var timestamp: String?
    var receivedAt: String?
    var club: String?
    var carryDistance: Double?
    var totalDistance: Double?
    var ballSpeed: Double?
    var clubSpeed: Double?
    var launchAngle: Double?
    var launchDirection: Double?
    var spinRPM: Double?
    var spinAxis: Double?
    var distanceUnit: String?
    var speedUnit: String?
    var rawHex: String?
    var source: String?
    var label: String?
    var isSynthetic: Bool?
    var distanceFraction: Double?
    var baseShotID: String?
    var launchAngleIsEstimated: Bool?
    var launchAngleSource: String?
    var apex: Double?
    var smashFactor: Double?
    var importSourceFile: String?
    var importedAt: String?
    var generationNote: String?

    var missingMeasurement: String? {
        guard let ball = ballMPH, (0.01...350).contains(ball) else { return "볼 속도 필요" }
        guard let angle = launchAngle, angle.isFinite, abs(angle) <= 90 else { return "발사각 필요" }
        if resolvedDirection == nil { return "방향 필요" }
        guard let spin = spinRPM, spin.isFinite, (0...100000).contains(spin) else { return "스핀 필요" }
        if let axis = spinAxis, !axis.isFinite || abs(axis) > 90 { return "스핀축 필요" }
        return nil
    }

    var isGenerated: Bool { isSynthetic == true || source?.hasPrefix("synthetic") == true }

    var sortDate: String { timestamp ?? receivedAt ?? "" }
    var dateLabel: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: sortDate)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: sortDate)
        }
        guard let date = date else { return sortDate.isEmpty ? "시각 없음" : sortDate }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }

    var clubLabel: String {
        if isGenerated, let label = label, !label.isEmpty { return label }
        switch club ?? "" {
        case "W1": return "드라이버"
        case "W3": return "3번 우드"
        case "U4": return "4번 유틸리티"
        case "PW": return "PW"
        case "GW": return "GW"
        case "SW": return "SW"
        case "LW": return "LW"
        default:
            if let club = club, club.hasPrefix("I") { return String(club.dropFirst()) + "번 아이언" }
            return club ?? "미지정"
        }
    }

    var ballMPH: Double? { speedToMPH(ballSpeed) }
    var clubMPH: Double? { speedToMPH(clubSpeed) }
    var carryYards: Double? {
        guard let value = carryDistance, value.isFinite, value >= 0 else { return nil }
        switch (distanceUnit ?? "").lowercased() {
        case "m", "meter", "meters": return value / 0.9144
        case "yd", "yard", "yards": return value
        default: return nil
        }
    }
    var carryMeters: Double? { carryYards.map { $0 * 0.9144 } }
    var apexMeters: Double? {
        guard let value = apex, value.isFinite, value >= 0 else { return nil }
        switch (distanceUnit ?? "").lowercased() {
        case "m", "meter", "meters": return value
        case "yd", "yard", "yards": return value * 0.9144
        default: return nil
        }
    }

    private func speedToMPH(_ value: Double?) -> Double? {
        guard let value = value, value.isFinite, value > 0 else { return nil }
        switch (speedUnit ?? "").lowercased() {
        case "m/s", "mps": return value / 0.44704
        case "mph": return value
        case "km/h", "kph", "kmh": return value / 1.609344
        default: return nil
        }
    }

    var resolvedDirection: Double? {
        if let value = launchDirection, value.isFinite, abs(value) <= 90 { return value }
        guard let raw = rawHex else { return nil }
        let parts = raw.split(whereSeparator: { $0.isWhitespace })
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == parts.count else { return nil }
        func valid(_ frame: [UInt8], _ command: UInt8) -> Bool {
            frame.count >= 20 && frame[0] == 0x53 && frame[1] == command
                && frame[frame.count - 2] == 0x45 && frame.reduce(UInt8(0), &+) == 0
        }
        let offset: Int
        if bytes.count == 100 {
            let frames = stride(from: 0, to: 100, by: 20).map { Array(bytes[$0..<($0 + 20)]) }
            guard frames.allSatisfy({ valid($0, 0x73) }),
                  Set(frames.map { $0[4] }) == Set(UInt8(1)...UInt8(5)),
                  Set(frames.map { UInt16($0[2]) | UInt16($0[3]) << 8 }).count == 1,
                  let fifth = frames.firstIndex(where: { $0[4] == 5 }) else { return nil }
            offset = fifth * 20 + 5
        } else if (bytes.count == 67 || bytes.count == 80) && valid(bytes, 0x72) {
            offset = 53
        } else { return nil }
        let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        let value = Double(Float(bitPattern: bits))
        return value.isFinite && abs(value) <= 90 ? value : nil
    }
}

struct LoadedShots {
    let shots: [SavedShot]
    let skipped: Int
}

enum ShotLoader {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SC4 Shot Collector/shots.jsonl")
    }

    static func load(_ data: Data) throws -> LoadedShots {
        let decoder = JSONDecoder()
        var records: [SavedShot] = []
        var skipped = 0
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        if text.hasPrefix("[") {
            records = try decoder.decode([SavedShot].self, from: Data(text.utf8))
        } else {
            for line in text.split(whereSeparator: { $0.isNewline }) {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                do { records.append(try decoder.decode(SavedShot.self, from: Data(line.utf8))) }
                catch { skipped += 1 }
            }
            if records.isEmpty && !text.isEmpty { throw ReplayError.invalidFile }
        }
        var seen = Set<String>()
        records = records.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        return LoadedShots(shots: records.sorted { $0.sortDate > $1.sortDate }, skipped: skipped)
    }
}

enum ReplayError: LocalizedError {
    case invalidFile
    case input(String)
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "SC4 Shot Collector의 JSON 또는 JSONL 기록을 선택해 주세요."
        case .input(let message): return message
        }
    }
}

struct ShotInputs {
    var ballSpeed = ""
    var verticalAngle = ""
    var horizontalAngle = ""
    var totalSpin = ""
    var spinAxis = "0"
    var clubSpeed = ""

    init() {}
    init(shot: SavedShot) {
        ballSpeed = Self.text(shot.ballMPH)
        verticalAngle = Self.text(shot.launchAngle.flatMap { $0.isFinite && abs($0) <= 90 ? $0 : nil })
        horizontalAngle = Self.text(shot.resolvedDirection)
        totalSpin = Self.text(shot.spinRPM)
        spinAxis = shot.spinAxis.map { Self.text($0.isFinite && abs($0) <= 90 ? $0 : nil) } ?? "0"
        clubSpeed = Self.text(shot.clubMPH)
    }

    static func text(_ value: Double?) -> String {
        guard let value = value, value.isFinite else { return "" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private func number(_ text: String, name: String, range: ClosedRange<Double>) throws -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, range.contains(value) else {
            throw ReplayError.input("\(name) 값을 확인해 주세요 (\(range.lowerBound)–\(range.upperBound)).")
        }
        return value
    }

    func payload(deviceID: String, number: Int, carryYards: Double?) throws -> OpenConnectMessage {
        let ball = try self.number(ballSpeed, name: "볼 속도", range: 0.01...350)
        let vla = try self.number(verticalAngle, name: "수직 발사각", range: -90...90)
        let hla = try self.number(horizontalAngle, name: "출발 방향", range: -90...90)
        let spin = try self.number(totalSpin, name: "총 스핀", range: 0...100000)
        let axis = try self.number(spinAxis, name: "스핀축", range: -90...90)
        let club = clubSpeed.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : try self.number(clubSpeed, name: "클럽 속도", range: 0.01...300)
        let carry = carryYards.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return OpenConnectMessage(DeviceID: deviceID, ShotNumber: number,
            BallData: BallPayload(Speed: ball, SpinAxis: axis, TotalSpin: spin, HLA: hla, VLA: vla, CarryDistance: carry),
            ClubData: club.map { ClubPayload(Speed: $0) },
            ShotDataOptions: ShotOptions(ContainsBallData: true, ContainsClubData: club != nil,
                LaunchMonitorIsReady: true, LaunchMonitorBallDetected: true, IsHeartBeat: false))
    }
}

struct BallPayload: Encodable {
    let Speed: Double
    let SpinAxis: Double
    let TotalSpin: Double
    let HLA: Double
    let VLA: Double
    let CarryDistance: Double?
}

struct ClubPayload: Encodable { let Speed: Double }

struct ShotOptions: Encodable {
    let ContainsBallData: Bool
    let ContainsClubData: Bool
    let LaunchMonitorIsReady: Bool
    let LaunchMonitorBallDetected: Bool
    let IsHeartBeat: Bool
    let IsMock = true
}

struct OpenConnectMessage: Encodable {
    let DeviceID: String
    let Units = "Yards"
    let ShotNumber: Int
    let APIversion = "1"
    let BallData: BallPayload?
    let ClubData: ClubPayload?
    let ShotDataOptions: ShotOptions

    static func heartbeat(deviceID: String) -> Self {
        Self(DeviceID: deviceID, ShotNumber: 0, BallData: nil, ClubData: nil,
             ShotDataOptions: ShotOptions(ContainsBallData: false, ContainsClubData: false,
                LaunchMonitorIsReady: false, LaunchMonitorBallDetected: false, IsHeartBeat: true))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        data.append(10)
        return data
    }
}
