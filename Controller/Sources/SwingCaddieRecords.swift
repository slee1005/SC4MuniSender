import Foundation

struct SC4LiveShot:Codable,Identifiable {
    var id=UUID()
    var deviceID:String
    var deviceName:String
    var receivedAt:Date
    var deviceRecordID:String?
    var timestamp:Date?
    var club:String?
    var carryDistance:Double?
    var totalDistance:Double?
    var ballSpeed:Double?
    var clubSpeed:Double?
    var launchAngle:Double?
    var launchDirection:Double?
    var apex:Double?
    var smashFactor:Double?
    var smashFactorSource:String?
    var spinRPM:Double?
    var distanceUnit:String
    var speedUnit:String
    var rawHex:String
    var source:String
    var deduplicationKey:String { deviceID.lowercased()+"|"+(deviceRecordID ?? id.uuidString) }
    static func calculatedSmash(ball:Double?,club:Double?)->Double? {
        guard let ball=ball,let club=club,club>0 else { return nil };return ball/club
    }
    func message(number:Int)->SC4LiveMessage? {
        guard number>0,let speed=ballSpeed,let angle=launchAngle,let direction=launchDirection,let spin=spinRPM,
              [speed,angle,direction,spin].allSatisfy(\.isFinite),(0.0001...150).contains(speed),
              (-10...80).contains(angle),abs(direction)<=90,(0...100000).contains(spin) else { return nil }
        let club=clubSpeed.flatMap { $0.isFinite && $0>0 && $0<=120 ? ClubPayload(Speed:$0/0.44704):nil }
        return SC4LiveMessage(DeviceID:"SC4-"+deviceID,ShotNumber:number,
            BallData:BallPayload(Speed:speed/0.44704,SpinAxis:0,TotalSpin:spin,HLA:direction,VLA:angle,CarryDistance:nil),
            ClubData:club,ShotDataOptions:SC4LiveOptions(ContainsClubData:club != nil))
    }
}

struct SC4LiveOptions:Encodable {
    let ContainsBallData=true
    let ContainsClubData:Bool
    let LaunchMonitorIsReady=true
    let LaunchMonitorBallDetected=true
    let IsHeartBeat=false
    let IsMock=false
}
struct SC4LiveMessage:Encodable {
    let DeviceID:String
    let Units="Yards"
    let ShotNumber:Int
    let APIversion="1"
    let BallData:BallPayload
    let ClubData:ClubPayload?
    let ShotDataOptions:SC4LiveOptions
    func encoded() throws->Data { var data=try JSONEncoder().encode(self);data.append(10);return data }
}

struct SC4Registration:Codable,Equatable,Identifiable {
    let id:UUID
    let name:String
}

enum SC4ConnectionRules {
    static let service="30300001-5365-6964-6461-63676E697773"
    static let write="30300002-5365-6964-6461-63676E697773"
    static let notify="30300003-5365-6964-6461-63676E697773"
    static func isCandidate(name:String,services:[String])->Bool {
        let normalized=name.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized.contains("sc4pro") { return false }
        return normalized.hasPrefix("sc4") || services.contains { $0.caseInsensitiveCompare(service) == .orderedSame }
    }
    static func allows(_ data:Data)->Bool {
        guard let frame=SC4Frame(raw:data) else { return false }
        if frame.command == 0x64 { return frame.payload.allSatisfy { $0==0 } }
        return frame.command == 0x73 && (1...5).contains(frame.sequence) && frame.payload.dropFirst(3).allSatisfy { $0==0 }
    }
}

/// Raw bytes and complete records are durable before acknowledging them to SC4.
final class SC4LiveReceiver {
    private let directory:URL
    private var decoder=SC4FrameDecoder()
    private var assembler=SC4ShotAssembler()
    private var keys=Set<String>()
    private var terminalFrames:[UInt16:SC4Frame]=[:]
    private var savedTerminals:[Data:Date]=[:]
    init(directory:URL) throws {
        self.directory=directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let path=directory.appendingPathComponent("shots.jsonl")
        if FileManager.default.fileExists(atPath:path.path) {
            let data=try Data(contentsOf:path)
            if !data.isEmpty && data.last != 10 { throw ReplayError.input("SC4 수신 기록 파일 끝을 확인해 주세요. 기존 기록은 보존했습니다.") }
            for line in data.split(separator:10) {
                let shot=try JSONDecoder().decode(SC4LiveShot.self,from:Data(line))
                keys.insert(shot.deduplicationKey)
            }
        }
    }
    func reset() { decoder.reset();assembler=SC4ShotAssembler();terminalFrames.removeAll();savedTerminals.removeAll() }
    private func append(_ data:Data,to filename:String) throws {
        let url=directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath:url.path) {
            guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw ReplayError.input("SC4 수신 기록을 저장할 수 없습니다.") }
        }
        let file=try FileHandle(forWritingTo:url);defer { try? file.close() }
        try file.seekToEnd();try file.write(contentsOf:data);try file.synchronize()
    }
    func receive(_ data:Data,deviceID:String,name:String) throws->(shots:[SC4LiveShot],replies:[Data]) {
        struct Packet:Encodable { let date:Date;let deviceID:String;let bytes:Data }
        var journal=try JSONEncoder().encode(Packet(date:Date(),deviceID:deviceID,bytes:data));journal.append(10)
        try append(journal,to:"packets.jsonl")
        var shots:[SC4LiveShot]=[],replies:[Data]=[]
        savedTerminals=savedTerminals.filter { Date().timeIntervalSince($0.value)<20 }
        for frame in decoder.append(data) where frame.command == 0x73 && (1...5).contains(frame.sequence) {
            if frame.sequence == 1 { savedTerminals=savedTerminals.filter { SC4Frame(raw:$0.key)?.shotIndex != frame.shotIndex } }
            if frame.sequence == 5, savedTerminals[frame.raw] != nil {
                if let ack=SC4Wire.shotSequenceACK(for:frame) { replies.append(ack) };continue
            }
            if frame.sequence == 5 { terminalFrames[frame.shotIndex]=frame }
            let record=assembler.ingest(frame:frame,deviceID:deviceID,deviceName:name)
            if let record=record,!keys.contains(record.deduplicationKey) {
                var encoded=try JSONEncoder().encode(record);encoded.append(10)
                try append(encoded,to:"shots.jsonl")
                keys.insert(record.deduplicationKey);shots.append(record)
            }
            if frame.sequence<5,let ack=SC4Wire.shotSequenceACK(for:frame) { replies.append(ack) }
            if let key=record?.deduplicationKey ?? assembler.lastCompletedIdentity,keys.contains(key),
               let terminal=terminalFrames.removeValue(forKey:frame.shotIndex),let ack=SC4Wire.shotSequenceACK(for:terminal) {
                replies.append(ack);savedTerminals[terminal.raw]=Date()
            }
            if terminalFrames.count>128 { terminalFrames.removeValue(forKey:terminalFrames.keys.first!) }
            if savedTerminals.count>128 { savedTerminals.removeValue(forKey:savedTerminals.keys.first!) }
        }
        return (shots,replies)
    }
}
