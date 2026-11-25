import Foundation
import Network

@main
struct ReplayTests {
    static func main() async throws {
        try core()
        try imports()
        try sorting()
        try putting()
        try puttingMaker()
        try shotAdjustments()
        if CommandLine.arguments.contains("--network") { try await network() }
        print("PASS: SC4 units, packet validation, missing-value handling, original preservation, JSON framing" +
              ", CSV/JSON import, persistent deduplication, carry sorting, putting in feet, typed putt maker, practice adjustments" +
              (CommandLine.arguments.contains("--network") ? ", TCP acknowledgement/rejection/no-retry" : ""))
    }

    static func shotAdjustments() throws {
        func record(_ id: String) -> SavedShot {
            var shot = SavedShot(id: id)
            shot.club = "I7"
            shot.launchAngle = 20
            shot.launchDirection = -2
            shot.spinAxis = 10
            shot.spinRPM = 5000
            shot.ballSpeed = 44.704
            shot.speedUnit = "m/s"
            shot.carryDistance = 100
            shot.distanceUnit = "yd"
            return shot
        }
        let originals = [record("adjust-a"), record("adjust-b")]
        let adjustments = [
            LaunchAngleAdjustment(id: "adjust-a", club: "I7", originalAngle: 20, adjustedAngle: 20.4, percentChange: 2),
            LaunchAngleAdjustment(id: "adjust-b", club: "I7", originalAngle: 20, adjustedAngle: 19.6, percentChange: -2),
        ]
        let decoded = try LaunchAngleAdjustments.load(JSONEncoder().encode(adjustments))
        let result = LaunchAngleAdjustments.apply(decoded, to: originals)
        try expect(result.count == 2 && result.shots.map(\.launchAngle) == [20.4, 19.6] &&
                   originals.allSatisfy { $0.launchAngle == 20 }, "practice angles apply without editing original values")
        for shot in result.shots {
            try expect(shot.originalLaunchAngle == 20 && shot.launchAngleIsAdjusted == true &&
                       shot.launchDirection == -2 && shot.spinAxis == 10 && shot.spinRPM == 5000 && shot.carryYards == 100,
                       "adjustments retain original-angle provenance and all other shot metrics")
            let wire = try ShotInputs(shot: shot).payload(deviceID: "AngleTest", number: 1, carryYards: shot.carryYards)
            try expect(wire.BallData?.VLA == shot.launchAngle, "adjusted angle is used on the wire")
        }
        var stale = originals[0]
        stale.launchAngle = 21
        try expect(LaunchAngleAdjustments.apply(decoded, to: [stale]).count == 0, "stale overrides do not replace new source measurements")
        let tooLarge = LaunchAngleAdjustment(id: "adjust-a", club: "I7", originalAngle: 20, adjustedAngle: 21.2, percentChange: 6)
        try expectThrows("out-of-range angle change rejected") { _ = try LaunchAngleAdjustments.load(JSONEncoder().encode([tooLarge])) }
        try expectThrows("duplicate override IDs rejected") { _ = try LaunchAngleAdjustments.load(JSONEncoder().encode([adjustments[0], adjustments[0]])) }

        var driver = record("driver-boundary")
        driver.club = "W1"
        driver.carryDistance = 240
        driver.label = "드라이버 #1 · 출발 0°"
        driver.isSynthetic = true
        let converted = ShotClubRules.apply(to: [driver])
        try expect(converted.count == 1 && converted.shots[0].club == "W3" && converted.shots[0].originalClub == "W1" &&
                   converted.shots[0].label == "3번 우드 #1 · 출발 0°" && converted.shots[0].ballSpeed == driver.ballSpeed,
                   "240-yard driver becomes 3W with matching label and preserved metrics")
        var meters = driver
        meters.distanceUnit = "m"; meters.carryDistance = 219.456
        var feet = driver
        feet.distanceUnit = "ft"; feet.carryDistance = 720
        var longer = driver
        longer.carryDistance = 240.01
        var unknown = driver
        unknown.distanceUnit = "unknown"
        let boundaries = ShotClubRules.apply(to: [meters, feet, longer, unknown])
        try expect(boundaries.count == 2 && boundaries.shots.map(\.club) == ["W3", "W3", "W1", "W1"],
                   "classification respects physical units and the inclusive 240-yard boundary")
        try expect(ShotClubRules.apply(to: converted.shots).count == 0, "club conversion is idempotent")
    }

    static func puttingMaker() throws {
        for text in ["12.5", "80", " 125.25 "] {
            let made = try PuttingShotMaker.make(distanceFeet: text)
            let expected = Double(text.trimmingCharacters(in: .whitespaces))!
            try expect(made.isPutt && made.isGenerated && abs(made.puttFeet! - expected) < 1e-9,
                       "typed decimal feet become a putting roll target")
            try expect(made.missingMeasurement == nil && made.clubSpeed == nil && made.importSourceFile == nil,
                       "maker creates a complete temporary practice putt without invented club data")
            let message = try ShotInputs(shot: made).payload(deviceID: "TypedPuttTest", number: 51, carryYards: made.carryYards)
            let json = try JSONSerialization.jsonObject(with: message.encoded()) as! [String: Any]
            let ball = json["BallData"] as! [String: Any]
            try expect(ball["VLA"] as? Double == 0 && ball["HLA"] as? Double == 0 &&
                       ball["TotalSpin"] as? Double == 0 && ball["CarryDistance"] == nil,
                       "typed putt sends valid zero-angle ball data without using roll target as carry")
        }
        for invalid in ["", " ", "0", "-5", "NaN", "inf", "abc", "1e308"] {
            try expectThrows("invalid typed distance is refused before a shot can be sent") {
                _ = try PuttingShotMaker.make(distanceFeet: invalid)
            }
        }
    }

    static func putting() throws {
        var putt = SavedShot(id: "putting-fixture")
        putt.club = "PT"
        putt.carryDistance = 0
        putt.totalDistance = 3.048
        putt.distanceUnit = "m"
        putt.ballSpeed = 1.5
        putt.speedUnit = "m/s"
        putt.launchAngle = 0
        putt.launchDirection = 0
        putt.spinRPM = 0
        putt.spinAxis = 0
        try expect(putt.isPutt && putt.clubLabel == "퍼터" && putt.missingMeasurement == nil,
                   "putter with zero launch/spin remains a valid selectable input")
        for unit in DistanceDisplayUnit.allCases {
            try expect(abs(unit.listDistance(for: putt)! - 10) < 1e-9 && unit.label(for: putt) == "ft",
                       "putt target is always feet, independent of the full-shot carry unit")
        }
        let message = try ShotInputs(shot: putt).payload(deviceID: "PuttingTest", number: 5, carryYards: putt.carryYards)
        let object = try JSONSerialization.jsonObject(with: message.encoded()) as! [String: Any]
        let ball = object["BallData"] as! [String: Any]
        try expect(ball["VLA"] as? Double == 0 && ball["HLA"] as? Double == 0 && ball["TotalSpin"] as? Double == 0,
                   "putting zeros are sent as measurements, not treated as missing")
        try expect(ball["CarryDistance"] == nil && message.ClubData == nil && !message.ShotDataOptions.ContainsClubData,
                   "roll target is not sent as airborne carry or fabricated club data")
        try expect(abs(message.BallData!.Speed - 3.355) < 0.001 && message.ShotDataOptions.IsMock,
                   "low putt velocity converts to mph and remains a mock replay")
        var fullShot = SavedShot(id: "iron-distance-fixture")
        fullShot.club = "I7"
        fullShot.carryDistance = 2
        fullShot.distanceUnit = "m"
        try expect(ShotSortOrder.carryAscending.sorted([putt, fullShot]).first?.club == "I7" &&
                   ShotSortOrder.carryDescending.sorted([putt, fullShot]).first?.club == "PT",
                   "putt sorts by rolling target, not its zero airborne carry")
        var imperial = putt
        imperial.distanceUnit = "ft"
        imperial.totalDistance = 10
        try expect(abs(imperial.puttFeet! - 10) < 1e-9, "native foot-unit putting records display correctly")
        let reopened = try JSONDecoder().decode(SavedShot.self, from: JSONEncoder().encode(putt))
        try expect(reopened.isPutt && abs(reopened.puttFeet! - 10) < 1e-9, "putt identity and target survive persistence")
        let csv = "club,Carry(ft),Total(ft),Ball Speed(mph),Launch Angle(deg),Launch Direction(deg),Spin(rpm),Spin Axis(deg)\nPT,0,10,3.3,0,0,0,0"
        let imported = try ShotImporter.load(Data(csv.utf8), filename: "putting.csv").shots[0]
        try expect(imported.isPutt && abs(imported.puttFeet! - 10) < 1e-9 && imported.missingMeasurement == nil,
                   "foot-unit putting CSV retains zero values and roll target")
    }

    static func sorting() throws {
        func record(_ id: String, _ carry: Double?, _ unit: String, _ date: String) -> SavedShot {
            var shot = SavedShot(id: id)
            shot.carryDistance = carry
            shot.distanceUnit = unit
            shot.timestamp = date
            return shot
        }
        let records = [
            record("meters", 100, "m", "2026-01-02"),
            record("yards", 100, "yd", "2026-01-03"),
            record("missing", nil, "m", "2026-01-05"),
            record("zero", 0, "m", "2026-01-01"),
            record("tie-z", 100, "m", "2026-01-04"),
            record("tie-a", 100, "m", "2026-01-04"),
            record("unknown-unit", 200, "unknown", "2026-01-06"),
        ]
        try expect(ShotSortOrder.carryAscending.sorted(records).map(\.id) ==
                   ["zero", "yards", "tie-a", "tie-z", "meters", "unknown-unit", "missing"],
                   "ascending compares physical distance, treats zero as valid, and leaves missing units last")
        try expect(ShotSortOrder.carryDescending.sorted(records).map(\.id) ==
                   ["tie-a", "tie-z", "meters", "yards", "zero", "unknown-unit", "missing"],
                   "descending keeps missing distance last and equal-distance results stable")
        try expect(ShotSortOrder.newest.sorted(records).prefix(2).map(\.id) == ["unknown-unit", "missing"],
                   "newest sorting remains available independent of distance")
        try expect(records.first?.id == "meters", "display sorting never edits saved records")
    }

    static func imports() throws {
        // Invented measurements only. No personal shot records belong in this project.
        let csv = """
        No.,Date,EQ,Carry(yd),Total(yd),Swing Speed(mph),Ball Speed(mph),Launch Angle(deg),Launch Direction(deg),Smash Factor,Apex(ft),Spin(rpm)
        AVG,,,100,105,80,100,20,-3,1.25,30,-
        1,2026-01-01,SW,100,105,80,100,20,-3,1.25,30,-
        2,2026-01-01,"Club, \"\"A\"\"",50,55,40,50,30,0,1.25,20,4000
        3,2026-01-01,OFF,bad,55,40,50,30,0,1.25,20,4000
        """
        let imported = try ShotImporter.load(Data(("\u{FEFF}" + csv.replacingOccurrences(of: "\n", with: "\r\n")).utf8), filename: "practice.csv")
        try expect(imported.shots.count == 2 && imported.summaries == 1 && imported.skipped == 1, "BOM/CRLF CSV excludes averages and invalid rows")
        let shot = imported.shots[0]
        try expect(abs(shot.carryMeters! - 91.44) < 1e-9 && abs(shot.ballMPH! - 100) < 1e-9, "CSV yard and mph header units converted exactly")
        try expect(abs(shot.apex! - 9.144) < 1e-9 && shot.smashFactor == 1.25, "CSV apex feet and smash factor retained")
        try expect(shot.spinRPM == nil && shot.missingMeasurement == "스핀 필요" && ShotInputs(shot: shot).totalSpin.isEmpty, "missing spin remains missing and visibly blocks sending")
        try expectThrows("CSV without spin cannot send until edited") {
            _ = try ShotInputs(shot: shot).payload(deviceID: "Test", number: 1, carryYards: shot.carryYards)
        }
        var edited = ShotInputs(shot: shot)
        edited.totalSpin = "3000"
        _ = try edited.payload(deviceID: "Test", number: 1, carryYards: shot.carryYards)
        try expect(imported.shots[1].club == "Club, \"A\"", "escaped commas and quotes preserved")
        let renamed = try ShotImporter.load(Data(csv.utf8), filename: "renamed.csv")
        try expect(renamed.shots.map(\.id) == imported.shots.map(\.id), "renamed files keep stable IDs")
        let duplicateRows = "Ball Speed(mph),Carry(yd)\n100,50\n100,50\n"
        let identical = try ShotImporter.load(Data(duplicateRows.utf8), filename: "identical.csv")
        try expect(identical.shots.count == 2 && Set(identical.shots.map(\.id)).count == 2, "distinct identical rows in a session retained")

        let collector = """
        id,shot_time,club,carry_distance,total_distance,distance_unit,ball_speed,club_speed,speed_unit,launch_angle_deg,launch_direction_deg,apex,smash_factor,spin_rpm,source,raw_hex
        fixture-collector,2026-01-02T12:00:00Z,I7,80,90,m,40,30,m/s,18,-1,12,1.3,5000,sc4_history,
        """
        let record = try ShotImporter.load(Data(collector.utf8), filename: "collector.csv").shots[0]
        try expect(record.id == "fixture-collector" && record.carryMeters == 80 && record.club == "I7", "collector schema keeps original ID and SI units")
        try expect(record.ballSpeed == 40 && record.launchDirection == -1 && record.spinRPM == 5000, "collector measured data preserved")
        let shapedCSV = "Ball Speed(mph),Carry(yd),Spin Axis(deg)\n100,80,-10"
        let shape = try ShotImporter.load(Data(shapedCSV.utf8), filename: "shape.csv").shots[0]
        try expect(shape.spinAxis == -10, "CSV optional spin axis survives importing")
        let kph = "Ball Speed(km/h);Carry(m);Launch Angle(deg);Launch Direction(deg);Spin(rpm)\n144;70;20;0;0"
        let kphShot = try ShotImporter.load(Data(kph.utf8), filename: "metric.csv").shots[0]
        try expect(abs(kphShot.ballSpeed! - 40) < 1e-9 && kphShot.spinRPM == 0, "semicolon CSV, km/h and zero spin supported")
        try expectThrows("unknown numeric units refused") {
            _ = try ShotImporter.load(Data("ball_speed,carry_distance\n40,70".utf8), filename: "unknown.csv")
        }
        try expectThrows("unclosed quoted CSV refused") { _ = try CSVRows.parse("a,b\n1,\"broken") }
        let multiline = try CSVRows.parse("a,b\n1,\"line1\nline2\"\n")
        try expect(multiline[1][1] == "line1\nline2", "quoted multiline field parsed")
        let native = try JSONEncoder().encode([record])
        let jsonShot = try ShotImporter.load(native, filename: "export.json").shots[0]
        let jsonl = try JSONEncoder().encode(record) + Data("\n{broken\n".utf8)
        let jsonlResult = try ShotImporter.load(jsonl, filename: "export.jsonl")
        try expect(jsonShot.id == record.id && jsonlResult.shots.count == 1 && jsonlResult.skipped == 1, "native JSON and torn JSONL imports")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SC4ImportTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalURL = folder.appendingPathComponent("original.csv")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originalData = Data(csv.utf8)
        try originalData.write(to: originalURL)
        let store = ShotImportStore(url: folder.appendingPathComponent("library/imported.json"))
        try expect(try store.load().isEmpty, "imports start without an existing collector or import library")
        let first = try store.add(imported.shots + [record], originals: [record])
        try expect(first.added.count == 2 && first.duplicates == 1, "native IDs deduplicate against original journal")
        let second = try store.add(renamed.shots, originals: [])
        try expect(second.added.isEmpty && second.duplicates == 2, "reimport does not duplicate records")
        let reopened = ShotImportStore(url: store.url)
        let persisted = try reopened.load()
        try expect(persisted.count == 2 && persisted[0].importSourceFile == "practice.csv", "records and provenance survive reopening")
        try expect(ShotImportStore.merge(originals: [], imported: persisted).count == 2, "import library works with no collector installed")
        try expect(ShotImportStore.merge(originals: [persisted[0]], imported: persisted).count == 2, "merged display deduplicates")
        try expect(try Data(contentsOf: originalURL) == originalData, "source file is byte-for-byte unchanged")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: store.url)
        try expectThrows("damaged store must not be overwritten") { _ = try store.add([record], originals: []) }
        try expect(try Data(contentsOf: store.url) == corrupt, "failed import preserves damaged store for recovery")
    }

    static func core() throws {
        let json = #"{"id":"synthetic-1","ballSpeed":44.704,"clubSpeed":35.7632,"speedUnit":"m/s","carryDistance":91.44,"distanceUnit":"m","launchAngle":15,"launchDirection":-2.5,"spinRPM":3000}"#
        let original = Data(json.utf8)
        let shot = try JSONDecoder().decode(SavedShot.self, from: original)
        try expect(abs(shot.ballMPH! - 100) < 1e-10, "m/s to mph")
        try expect(abs(shot.clubMPH! - 80) < 1e-10, "club speed units")
        try expect(abs(shot.carryYards! - 100) < 1e-10, "meters to yards")
        try expect(abs(DistanceDisplayUnit.meters.carry(for: shot)! - 91.44) < 1e-10 &&
                   abs(DistanceDisplayUnit.yards.carry(for: shot)! - 100) < 1e-10,
                   "display unit selection converts the same physical distance")
        let inputs = ShotInputs(shot: shot)
        let message = try inputs.payload(deviceID: "SyntheticTest", number: 41, carryYards: shot.carryYards)
        let object = try JSONSerialization.jsonObject(with: message.encoded()) as! [String: Any]
        let options = object["ShotDataOptions"] as! [String: Any]
        try expect(options["IsMock"] as? Bool == true, "replay is always a mock input")
        try expect(options["ContainsClubData"] as? Bool == true, "measured club speed is optional but included")
        try expect(object["ShotNumber"] as? Int == 41, "fresh sequence passes to the wire")
        try expect(object["Units"] as? String == "Yards", "wire distance unit is declared")
        let generatedJSON = #"{"id":"generated-example","club":"SW","source":"synthetic_sw_distance_scaled","label":"SW 20%","isSynthetic":true,"distanceFraction":0.2,"baseShotID":"synthetic-1"}"#
        let generated = try JSONDecoder().decode(SavedShot.self, from: Data(generatedJSON.utf8))
        try expect(generated.isGenerated && generated.clubLabel == "SW 20%" && generated.club == "SW",
                   "generated shot is visibly labeled without changing its club identity")
        try expect(!shot.isGenerated, "measured records stay measured")
        try expect(ShotInputs(shot: shot).spinAxis == "0", "old records without spin axis keep their explicit zero assumption")
        for axis in [-10.0, 10.0] {
            var shaped = shot
            shaped.spinAxis = axis
            shaped.isSynthetic = true
            shaped.label = axis > 0 ? "7번 아이언 페이드" : "7번 아이언 드로우"
            shaped.generationNote = "오른손 기준 연습용 구질"
            shaped.apex = 12
            let reopened = try JSONDecoder().decode(SavedShot.self, from: JSONEncoder().encode(shaped))
            let wire = try ShotInputs(shot: reopened).payload(deviceID: "ShapeTest", number: 1, carryYards: reopened.carryYards)
            try expect(wire.BallData?.SpinAxis == axis && reopened.generationNote == shaped.generationNote,
                       "both fade and draw axes survive persistence, selection and transmission")
            try expect(reopened.apexMeters == 12 && reopened.clubLabel == shaped.label, "generated height and shape label retained")
        }
        var invalidAxis = shot
        invalidAxis.spinAxis = 91
        try expect(ShotInputs(shot: invalidAxis).spinAxis.isEmpty && invalidAxis.missingMeasurement == "스핀축 필요",
                   "invalid saved spin axis is not silently replaced with zero")
        try expectThrows("invalid axis cannot transmit") {
            _ = try ShotInputs(shot: invalidAxis).payload(deviceID: "Test", number: 1, carryYards: nil)
        }
        let estimatedJSON = #"{"id":"estimated-angle-example","club":"LW","launchAngle":36.55,"launchAngleIsEstimated":true,"launchAngleSource":"estimated_from_carry_and_apex"}"#
        let estimated = try JSONDecoder().decode(SavedShot.self, from: Data(estimatedJSON.utf8))
        try expect(estimated.launchAngleIsEstimated == true && !estimated.isGenerated &&
                   ShotInputs(shot: estimated).verticalAngle == "36.55",
                   "an estimated angle is preserved and distinguished from measured or synthetic shots")
        var missing = shot
        missing.launchAngle = nil
        var edited = ShotInputs(shot: missing)
        try expectThrows("missing angle must not become zero") {
            _ = try edited.payload(deviceID: "Test", number: 1, carryYards: nil)
        }
        edited.verticalAngle = "17.5"
        edited.clubSpeed = ""
        let repaired = try edited.payload(deviceID: "Test", number: 2, carryYards: nil)
        try expect(repaired.BallData!.VLA == 17.5 && missing.launchAngle == nil, "override does not edit original")
        try expect(repaired.ClubData == nil && !repaired.ShotDataOptions.ContainsClubData, "no invented club data")
        edited.spinAxis = "nan"
        try expectThrows("non-finite values refused") {
            _ = try edited.payload(deviceID: "Test", number: 3, carryYards: nil)
        }
        var unknownUnit = shot
        unknownUnit.speedUnit = "unknown"
        try expect(unknownUnit.ballMPH == nil, "unknown units are not guessed")
        var kph = shot
        kph.ballSpeed = 160.9344
        kph.speedUnit = "km/h"
        try expect(abs(kph.ballMPH! - 100) < 1e-10, "km/h conversion")
        try expect(ShotInputs.text(0) == "0", "zero remains a valid numeric string")
        let journal = original + Data("\n{broken\n".utf8) + original
        let loaded = try ShotLoader.load(journal)
        try expect(loaded.shots.count == 1 && loaded.skipped == 1, "duplicates and torn lines do not hide valid records")
        try expect(try ShotLoader.load(Data(("[" + json + "]").utf8)).shots.count == 1, "collector JSON exports load")
        try expect(original == Data(json.utf8), "input bytes preserved")

        var history = [UInt8](repeating: 0, count: 67)
        history[0] = 0x53; history[1] = 0x72; history[65] = 0x45
        putFloat(12.5, into: &history, offset: 53)
        history[66] = 0 &- history.dropLast().reduce(UInt8(0), &+)
        var recovered = shot
        recovered.launchDirection = nil
        recovered.rawHex = hex(history)
        try expect(recovered.resolvedDirection == 12.5, "historical raw HLA recovered after checksum")
        history[10] ^= 1
        recovered.rawHex = hex(history)
        try expect(recovered.resolvedDirection == nil, "damaged history packet refused")
        var frames: [[UInt8]] = []
        for index in 1...5 {
            var frame = [UInt8](repeating: 0, count: 20)
            frame[0] = 0x53; frame[1] = 0x73; frame[2] = 42; frame[4] = UInt8(index); frame[18] = 0x45
            if index == 5 { putFloat(-7.5, into: &frame, offset: 5) }
            frame[19] = 0 &- frame.dropLast().reduce(UInt8(0), &+)
            frames.append(frame)
        }
        recovered.rawHex = hex(frames.reversed().flatMap { $0 })
        try expect(recovered.resolvedDirection == -7.5, "live sequence ordering is handled")
        frames[0][2] = 43
        frames[0][19] = 0 &- frames[0].dropLast().reduce(UInt8(0), &+)
        recovered.rawHex = hex(frames.flatMap { $0 })
        try expect(recovered.resolvedDirection == nil, "mixed shot indices refused")

        let replies = Data(#"{"Code":201,"Player":{"Club":"I7"}}{"Code":200,"Message":"ok {\"x\"}"}"#.utf8)
        var framer = JSONReplyFramer()
        var output: [Data] = []
        for byte in replies { output += try framer.append(Data([byte])) }
        try expect(output.count == 2, "fragmented and joined JSON with escaped quotes frames correctly")
        try expect(try JSONDecoder().decode(APIReply.self, from: output[1]).Code == 200, "ACK decoded")
        let heartbeat = try JSONSerialization.jsonObject(with: OpenConnectMessage.heartbeat(deviceID: "Test").encoded()) as! [String: Any]
        try expect(heartbeat["BallData"] == nil && heartbeat["ClubData"] == nil, "connection check sends no measurements")
        try expect((heartbeat["ShotDataOptions"] as! [String: Any])["ContainsBallData"] as? Bool == false, "heartbeat cannot launch a ball")
    }

    static func network() async throws {
        for mode in [MockServer.Mode.accept, .reject, .close] {
            let server = try MockServer(mode: mode)
            let port = try await server.start()
            let message = OpenConnectMessage.heartbeat(deviceID: "SyntheticTCPTest")
            do {
                let reply = try await OpenConnectTransport.exchange(host: "127.0.0.1", port: port, data: message.encoded(), timeout: 2)
                try expect(mode == .accept && reply.Code == 200, "only explicit 200 is success")
            } catch {
                if mode == .accept { server.stop(); throw error }
                if mode == .reject {
                    guard case ConnectionError.rejected(501, _) = error else { throw error }
                }
                if mode == .close {
                    try expect(error.localizedDescription.contains("다시 보내기") || error.localizedDescription.contains("재전송"), "uncertain outcome explained")
                }
            }
            try expect(server.requestCount == 1, "no retry or duplicate transmission")
            server.stop()
        }
        let server = try MockServer(mode: .accept)
        let port = try await server.start()
        let made = try PuttingShotMaker.make(distanceFeet: "12.5")
        let payload = try ShotInputs(shot: made).payload(deviceID: "SyntheticPuttTCP", number: 9, carryYards: made.carryYards).encoded()
        do {
            _ = try await OpenConnectTransport.exchange(host: "127.0.0.1", port: port, data: payload, timeout: 2)
            try expect(server.requestCount == 1 && server.requestData == payload, "low-speed zero-angle putt reaches isolated TCP server unchanged")
            server.stop()
        } catch { server.stop(); throw error }
    }

    static func putFloat(_ value: Float, into bytes: inout [UInt8], offset: Int) {
        let bits = value.bitPattern
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: bits >> (8 * i)) }
    }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
    static func expect(_ value: @autoclosure () throws -> Bool, _ note: String) throws {
        if try !value() { throw NSError(domain: "ReplayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: note]) }
    }
    static func expectThrows(_ note: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw NSError(domain: "ReplayTests", code: 2, userInfo: [NSLocalizedDescriptionKey: note])
    }
}

private final class MockServer {
    enum Mode { case accept, reject, close }
    private let queue = DispatchQueue(label: "sc4muni.synthetic-server")
    private let listener: NWListener
    private let mode: Mode
    private var connections: [NWConnection] = []
    private var count = 0
    private var lastPayload = Data()
    var requestCount: Int { queue.sync { count } }
    var requestData: Data { queue.sync { lastPayload } }

    init(mode: Mode) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                } else if case .failed(let error) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                read(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, closed, error in
            var accumulated = buffer
            accumulated.append(data ?? Data())
            if accumulated.contains(10) {
                count += 1
                lastPayload = accumulated
                if mode == .close { connection.cancel(); return }
                let reply = mode == .accept
                    ? #"{"Code":201,"Player":{"Club":"I7"}}{"Code":200,"Message":"ok {\"shot\"}"}"#
                    : #"{"Code":501,"Message":"Synthetic rejection"}"#
                let bytes = Data(reply.utf8)
                connection.send(content: bytes.prefix(7), completion: .contentProcessed { _ in
                    connection.send(content: bytes.dropFirst(7), completion: .contentProcessed { _ in })
                })
            } else if error == nil && !closed { read(connection, buffer: accumulated) }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            listener.newConnectionHandler = nil
        }
    }
}
