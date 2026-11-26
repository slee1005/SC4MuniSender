import Foundation
import Network

enum ControllerTestFailure:Error { case failed(String) }
func expectController(_ value:@autoclosure ()->Bool,_ reason:String) throws {
    if !value() { throw ControllerTestFailure.failed(reason) }
}
func refuseController(_ reason:String,_ body:() throws->Void) throws {
    do { try body() } catch { return }
    throw ControllerTestFailure.failed(reason)
}

actor ControllerProbe {
    var messages:[Data]=[]
    var reject=false
    func exchange(_ host:String,_ port:UInt16,_ data:Data) throws->APIReply {
        messages.append(data)
        if reject { throw ConnectionError.rejected(501,"test rejection") }
        return APIReply(Code:200,Message:"local model test")
    }
    func setReject() { reject=true }
    func objects() throws->[[String:Any]] { try messages.map { try JSONSerialization.jsonObject(with:$0) as! [String:Any] } }
}

@main struct ControllerTests {
    static func main() async {
        do {
            try core()
            try await model()
            try timingCore()
            try await timingModel()
            if CommandLine.arguments.contains("--network") { try await network() }
            print("PASS: 14 clubs; 6 gesture contacts; endless two-stage meters; continuous power; heel/sweet-spot/toe and slice/hook signs; 10 shot types; down/up spin; cancel/debounce/one-shot guards; valid payloads" + (CommandLine.arguments.contains("--network") ? "; isolated loopback acknowledgement":""))
        } catch { fputs("FAIL: \(error)\n",stderr);exit(1) }
    }
    static func core() throws {
        let clubs=ControllerClub.defaults
        try expectController(clubs.count==14 && Set(clubs.map(\.id)).count==14,"unique club set")
        for club in clubs {
            for contact in SwingContact.allCases {
                let result=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(contact),club:club)
                try expectController(result.contact==contact,"contact classification \(contact) \(club.id)")
                if contact == .miss {
                    try expectController(!result.canSend,"whiff cannot send")
                    try refuseController("whiff payload forbidden") { _=try result.message(deviceID:"Test",number:1) }
                    continue
                }
                let object=try JSONSerialization.jsonObject(with:result.message(deviceID:"Test",number:42).encoded()) as! [String:Any]
                let ball=object["BallData"] as! [String:Any], data=object["ClubData"] as! [String:Double]
                let opts=object["ShotDataOptions"] as! [String:Any]
                try expectController(object["Units"] as? String == "Yards" && object["ShotNumber"] as? Int == 42,"wire identity/units")
                try expectController(opts["ContainsClubData"] as? Bool == true && opts["IsMock"] as? Bool == true,"club data and mock indicators")
                try expectController(Set(data.keys)==Set(["Speed","SpeedAtImpact","AngleOfAttack","FaceToTarget","Loft","Path","VerticalFaceImpact","HorizontalFaceImpact"]),"only established club fields")
                try expectController(ball["CarryDistance"]==nil && ball["ContactType"]==nil && object["Club"]==nil,"no forced carry or undocumented club/label commands")
                if club.isPutter { try expectController(ball["VLA"] as? Double==0 && ball["TotalSpin"] as? Double==0,"putt sends zero loft and spin") }
                if contact == .toe { try expectController(data["HorizontalFaceImpact"]!>0,"toe mm sign") }
                if contact == .heel { try expectController(data["HorizontalFaceImpact"]!<0,"heel mm sign") }
                if contact == .thin { try expectController(data["VerticalFaceImpact"]!<0,"thin low-face mm sign") }
                if contact == .fat { try expectController(data["VerticalFaceImpact"]!>0,"fat high-face mm sign") }
            }
            let small=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(.center,depth:0.15),club:club)
            let full=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(.center,depth:0.85),club:club)
            try expectController(small.ballMPH<full.ballMPH && small.referenceDistance<full.referenceDistance,"continuous power controls distance")
            let fat=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(.fat),club:club)
            let clean=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(.center),club:club)
            try expectController(fat.ballMPH<clean.ballMPH,"contact changes actual transmitted ball speed")
            var doubled=club;doubled.baseDistance*=2
            let larger=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(.center),club:doubled)
            try expectController(larger.ballMPH>clean.ballMPH,"custom club anchor affects wire speed")
        }
        let club=clubs[0], points=ControllerSwingEngine.example(.center)
        let straight=try ControllerSwingEngine.analyze(points,club:club)
        let aimed=try ControllerSwingEngine.analyze(points,club:club,aim:8)
        try expectController(abs(aimed.launchDirection-straight.launchDirection-8)<0.001 && aimed.spinAxis==straight.spinAxis,"aim rotates whole shot without inventing curve")
        var right=points
        right[right.count-2].x = -0.15
        let rightSwing=try ControllerSwingEngine.analyze(right,club:club)
        try expectController(rightSwing.pathDegrees>0 && rightSwing.launchDirection>0 && rightSwing.spinAxis<0,"track direction changes launch and face-to-path draw")
        let changed=try ControllerSwingEngine.analyze(points,club:club,faceBias:5)
        try expectController(changed.spinAxis>0,"open face produces fade axis")
        var malformed=points;malformed[1].x = .nan
        try refuseController("NaN rejected") { _=try ControllerSwingEngine.analyze(malformed,club:club) }
        malformed=points;malformed[2].time = -1
        try refuseController("reversed clock rejected") { _=try ControllerSwingEngine.analyze(malformed,club:club) }
        try refuseController("click without backswing rejected") { _=try ControllerSwingEngine.analyze(Array(points.prefix(2)),club:club) }
        try refuseController("zero club distance rejected") { var invalid=club;invalid.baseDistance=0;_=try invalid.validated() }
        let encoded=try JSONEncoder().encode(clubs)
        let reopened=try JSONDecoder().decode([ControllerClub].self,from:encoded)
        try expectController(reopened==clubs,"club profiles persist")
    }
    @MainActor static func settle(_ model:ControllerModel) async throws {
        for _ in 0..<200 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds:5_000_000)
        }
        throw ControllerTestFailure.failed("model task timed out")
    }
    @MainActor static func model() async throws {
        let probe=ControllerProbe()
        let model=ControllerModel(preview:true,exchange:{ try await probe.exchange($0,$1,$2) })
        try expectController(!model.gameMode,"startup and examples are practice only")
        model.cancel("test cancellation")
        try expectController(model.swing==nil && !model.canSend,"cancel clears a previous pending shot")
        model.setGameMode(true)
        try expectController(!model.gameMode && model.isError,"auto mode requires prior acknowledgement")
        model.checkConnection();try await settle(model)
        try expectController(model.serverReady,"heartbeat enables game mode")
        model.setGameMode(true)
        try expectController(model.begin(),"can begin swing")
        model.finish(ControllerSwingEngine.example(.center));model.send()
        try await settle(model)
        let first=try await probe.objects()
        try expectController(first.count==2 && model.sent && model.attempted,"one heartbeat + exactly one shot despite duplicate send")
        let shotNumber=first[1]["ShotNumber"] as! Int
        try expectController(model.begin(),"next swing after acknowledgement")
        model.finish(ControllerSwingEngine.example(.miss));try await settle(model)
        let afterMiss=try await probe.objects()
        try expectController(afterMiss.count==2,"whiff causes no network request")
        model.example(.toe)
        try expectController(!model.gameMode,"example disarms auto sending")
        model.send();try await settle(model)
        let manual=try await probe.objects()
        try expectController(manual.count==3 && manual[2]["ShotNumber"] as! Int>shotNumber,"manual shot gets fresh number")
        await probe.setReject()
        model.example(.thin);model.send();try await settle(model)
        try expectController(model.isError && !model.gameMode && model.attempted && !model.canSend,"rejection prevents automatic retry and duplicate sending")
        let before=try await probe.objects();model.send()
        let after=try await probe.objects()
        try expectController(before.count==after.count,"failed shot is never automatically retried")
        model.example(.center);model.distanceText="NaN"
        try expectController(model.configurationIssue != nil && !model.begin() && model.swing==nil,"invalid new gesture clears the previous pending shot")
        model.restoreClub();model.distanceUnit = .meters;model.distanceText="100";model.applySettings()
        try expectController(abs(model.selectedClub.baseDistance-100/0.9144)<1e-8,"meter anchor stored as yards")
    }
    static func network() async throws {
        let server=try ControllerLoopbackServer()
        let port=try await server.start()
        defer { server.stop() }
        let swing=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(.heel),club:ControllerClub.defaults[0])
        let reply=try await OpenConnectTransport.exchange(host:"127.0.0.1",port:port,data:swing.message(deviceID:"IsolatedControllerTest",number:1).encoded(),timeout:2)
        try expectController(reply.Code==200,"loopback ACK")
        let captured=server.captured()
        let object=try JSONSerialization.jsonObject(with:captured) as! [String:Any]
        let club=object["ClubData"] as! [String:Double]
        try expectController(club["HorizontalFaceImpact"]!<0 && club["SpeedAtImpact"]!>0,"real TCP carries numeric heel impact fields")
    }
}

final class ControllerLoopbackServer:@unchecked Sendable {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"com.slee.controller.tests")
    private let lock=NSLock()
    private var bytes=Data()
    private var peers:[NWConnection]=[]
    // Listener callbacks and this completion flag are confined to queue.
    private var startCompleted=false
    init() throws {
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener=try NWListener(using:parameters)
    }
    func start() async throws->UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard !startCompleted else { return }
                if case .ready=state,let port=listener.port { startCompleted=true;continuation.resume(returning:port.rawValue) }
                if case .failed(let error)=state { startCompleted=true;continuation.resume(throwing:error) }
            }
            listener.newConnectionHandler = { [self] connection in
                peers.append(connection);connection.start(queue:queue)
                receive(connection)
            }
            listener.start(queue:queue)
        }
    }
    private func receive(_ connection:NWConnection) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [self] data,_,closed,error in
            lock.lock();if let data=data { bytes.append(data) };let snapshot=bytes;lock.unlock()
            if (try? JSONSerialization.jsonObject(with:snapshot)) != nil {
                connection.send(content:Data(#"{"Code":201,"Player":{"Club":"DR"}}{"Code":200,"Message":"local ACK"}"#.utf8),completion:.contentProcessed { _ in connection.cancel() })
            } else if !closed && error==nil { receive(connection) }
        }
    }
    func captured()->Data { lock.lock();defer{lock.unlock()};return bytes }
    func stop() { listener.cancel();queue.sync { peers.forEach{$0.cancel()} } }
}
