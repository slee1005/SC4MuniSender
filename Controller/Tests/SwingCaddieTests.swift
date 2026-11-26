import Foundation

extension ControllerTests {
    static func sc4Frames(index:UInt16=1,launch:Float=20)->[Data] {
        (1...5).map { sequence in
            var b=[UInt8](repeating:0,count:20)
            b[0]=0x53;b[1]=0x73;b[2]=UInt8(truncatingIfNeeded:index);b[3]=UInt8(truncatingIfNeeded:index>>8)
            b[4]=UInt8(sequence);b[18]=0x45
            func put(_ value:Float,_ offset:Int) {
                let bits=value.bitPattern
                for i in 0..<4 { b[offset+i]=UInt8(truncatingIfNeeded:bits >> (i*8)) }
            }
            switch sequence {
            case 1:b[5]=26;b[6]=11;b[7]=25;b[8]=10;b[9]=15;b[10]=20;b[12]=15
            case 2:put(50,13)
            case 3:put(37,5);put(launch,9);put(145,13)
            case 4:put(156,5);put(24,9);put(6500,13)
            default:put(2,5)
            }
            b[19]=0 &- b.reduce(UInt8(0),&+)
            return Data(b)
        }
    }
    static func sc4Receiver() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("MuniSC4Test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let receiver=try SC4LiveReceiver(directory:directory)
        let frames=sc4Frames()
        var shots:[SC4LiveShot]=[],acks:[Data]=[]
        for byte in frames.flatMap({[UInt8]($0)}) {
            let output=try receiver.receive(Data([byte]),deviceID:"TestSC4",name:"SC4 test")
            shots+=output.shots;acks+=output.replies
        }
        try expectController(shots.count==1 && acks.count==5,"fragmented BLE packets assemble one durable shot and five acknowledgements")
        let shot=shots[0],object=try JSONSerialization.jsonObject(with:shot.message(number:1)!.encoded()) as! [String:Any]
        let ball=object["BallData"] as! [String:Double],options=object["ShotDataOptions"] as! [String:Any]
        try expectController(abs(ball["Speed"]!-50/0.44704)<1e-8 && ball["VLA"]==20 && ball["HLA"]==2 && ball["TotalSpin"]==6500,"SC4 SI speed converted once; measured angles and spin unchanged")
        try expectController(ball["CarryDistance"]==nil && ball["SpinAxis"]==0 && options["IsMock"] as? Bool == false,"actual SC4 payload has no forced carry and marks real measurements; unmeasured spin axis is zero")
        try expectController(acks.allSatisfy(SC4ConnectionRules.allows),"all device replies satisfy command gate")
        let saved=try Data(contentsOf:directory.appendingPathComponent("shots.jsonl"))
        let terminal=try receiver.receive(frames[4],deviceID:"TestSC4",name:"SC4 test")
        try expectController(terminal.shots.isEmpty && terminal.replies.count==1,"terminal retransmission acknowledged without duplicating shot")
        receiver.reset()
        let duplicate=try receiver.receive(frames.reduce(Data(),+),deviceID:"TestSC4",name:"SC4 test")
        try expectController(duplicate.shots.isEmpty && duplicate.replies.count==5,"reconnection preserves durable deduplication")
        let reopened=try SC4LiveReceiver(directory:directory)
        let duplicateAfterRestart=try reopened.receive(frames.reduce(Data(),+),deviceID:"TestSC4",name:"SC4 test")
        try expectController(duplicateAfterRestart.shots.isEmpty,"restarting does not repeat stored shots")
        let afterDuplicate=try Data(contentsOf:directory.appendingPathComponent("shots.jsonl"))
        try expectController(afterDuplicate==saved,"duplicate reception never rewrites measured record")
        let invalid=try receiver.receive(sc4Frames(index:2,launch:136).reduce(Data(),+),deviceID:"TestSC4",name:"SC4 test")
        try expectController(invalid.shots.count==1 && invalid.shots[0].launchAngle==nil && invalid.shots[0].message(number:2)==nil,"out-of-range SC4 launch preserved in raw, never guessed or sent")
        let incomplete=try receiver.receive(sc4Frames(index:3)[4],deviceID:"TestSC4",name:"SC4 test")
        try expectController(incomplete.replies.isEmpty && incomplete.shots.isEmpty,"terminal fragment cannot be acknowledged before full durable record")
        var corrupt=frames[0];corrupt[6] ^= 1
        let corrupted=try receiver.receive(corrupt,deviceID:"TestSC4",name:"SC4 test")
        try expectController(corrupted.shots.isEmpty && corrupted.replies.isEmpty,"bad checksum produces no measurement or acknowledgement")
        try expectController(!SC4ConnectionRules.isCandidate(name:"",services:[]) && !SC4ConnectionRules.isCandidate(name:"Keyboard",services:[]) && !SC4ConnectionRules.isCandidate(name:"SC4 Pro",services:[SC4ConnectionRules.service]),"unrelated and Pro devices excluded")
        try expectController(SC4ConnectionRules.isCandidate(name:"SC4 1234",services:[]) && SC4ConnectionRules.isCandidate(name:"",services:[SC4ConnectionRules.service]),"SC4 discovery accepts legacy name or advertised service")
        var forbidden=[UInt8](SC4Wire.deviceInfoRequest());forbidden[1]=0x44;forbidden[19]=0
        forbidden[19]=0 &- forbidden.reduce(UInt8(0),&+)
        try expectController(!SC4ConnectionRules.allows(Data(forbidden)),"delete command cannot pass BLE write gate")
        print("PASS: SC4 fragmented receive, durable save/ACK, restart deduplication, real units, invalid-data hold and discovery filters")
    }
    @MainActor static func sc4Model() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("MuniSC4Model-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let receiver=try SC4LiveReceiver(directory:directory)
        let base=try receiver.receive(sc4Frames().reduce(Data(),+),deviceID:"TestSC4",name:"SC4 test").shots[0]
        let probe=ControllerProbe(),model=ControllerModel(preview:true,exchange:{try await probe.exchange($0,$1,$2)})
        model.inputMode = .swingCaddie
        try expectController(!model.startTiming() && !model.begin(),"SC4 tab cannot also produce a virtual shot")
        model.receiveSC4(base)
        let offline=try await probe.objects()
        try expectController(offline.isEmpty && model.sc4TransferStatus.contains("미연결"),"offline SC4 reception stays local")
        model.checkConnection();try await settle(model)
        model.receiveSC4(base)
        let checked=try await probe.objects()
        try expectController(checked.count==1,"connecting never sends an old SC4 measurement")
        var next=base;next.deviceRecordID="next"
        model.receiveSC4(next);model.receiveSC4(next)
        var burst=base;burst.deviceRecordID="burst"
        model.receiveSC4(burst);try await settle(model)
        let sent=try await probe.objects()
        try expectController(sent.count==2 && model.sent,"one new SC4 shot is automatically sent exactly once")
        try expectController(model.sc4TransferRecordID==burst.deduplicationKey && model.sc4TransferStatus.contains("건너뜀"),"a prior acknowledgement cannot label a later stored-only shot as sent")
        model.inputMode = .timing
        var other=base;other.deviceRecordID="other"
        model.receiveSC4(other)
        let inOtherTab=try await probe.objects()
        try expectController(inOtherTab.count==2,"SC4 receives locally without firing while a virtual input tab is active")
        model.inputMode = .swingCaddie
        var invalid=base;invalid.deviceRecordID="invalid";invalid.launchAngle=nil
        model.receiveSC4(invalid)
        let withheld=try await probe.objects()
        try expectController(withheld.count==2 && !model.attempted,"SC4 missing required angle never gets a synthetic replacement")
        model.loftText="35";model.applySettings()
        try expectController(model.selectedClub.loft==35 && model.selectedClub.launchAngle==ClubFlight.referenceLaunch(loft:35,code:model.selectedCode,attack:model.selectedClub.attack),"edited loft updates the launch reference")
        model.restoreClub()
        try expectController(model.loftText=="43","reset restores selected Callaway loft")
    }
    @MainActor static func clubMigration() throws {
        let suite="MuniControllerMigrationTest-"+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        var previous=ControllerClub.defaults
        let index=previous.firstIndex(where:{$0.id=="I7"})!
        previous[index].loft=34;previous[index].launchAngle=25
        previous[index].baseDistance=173;previous[index].spin=6555
        let original=try JSONEncoder().encode(previous)
        prefs.set(original,forKey:"controllerClubs")
        let registration=SC4Registration(id:UUID(),name:"SC4 test")
        prefs.set(try JSONEncoder().encode(registration),forKey:"controllerSC4Registration")
        let upgraded=ControllerModel(preview:true,preferences:prefs)
        upgraded.selectedCode="I7"
        try expectController(upgraded.selectedClub.loft==30 && upgraded.selectedClub.baseDistance==173 && upgraded.selectedClub.spin==6555,"upgrade applies Callaway loft while preserving personalized distance and spin")
        try expectController(prefs.data(forKey:"controllerClubsBeforeCallaway")==original,"pre-upgrade profile preserved for recovery")
        try expectController(upgraded.swingCaddie.registered==registration,"registration survives app creation without starting Bluetooth")
        upgraded.loftText="31";upgraded.applySettings()
        let reopened=ControllerModel(preview:true,preferences:prefs)
        reopened.selectedCode="I7"
        try expectController(reopened.selectedClub.loft==31 && prefs.data(forKey:"controllerClubsBeforeCallaway")==original,"subsequent launches retain custom loft and original backup")
        reopened.swingCaddie.forget()
        try expectController(prefs.data(forKey:"controllerSC4Registration")==nil && reopened.selectedClub.loft==31,"unregistering only removes Bluetooth registration")
    }
    static func clubFlight() throws {
        let expected:[String:Double] = ["W1":10.5,"W3":15,"U4":22,"I4":21,"I5":23,"I6":26,"I7":30,"I8":34,"I9":38,"PW":43,"GW":50,"SW":56,"LW":60,"PT":3]
        for club in ControllerClub.defaults {
            try expectController(club.loft==expected[club.id],"manufacturer loft table for \(club.id)")
            var previousHeight = -1.0
            for p in [0.01,0.05,0.1,0.3,0.5,0.7,1,1.1] {
                let session=TimingSession(id:UUID(),power:TimingPower(fraction:p)!,direction:.leftToRight,startedAt:1000)
                let shot=TimingSwingEngine.shot(try session.judge(at:1000+session.duration/2),club:club,aim:0,faceBias:0)
                let apex=shot.apexMeters
                try expectController(apex.isFinite && apex>=0 && apex>=previousHeight,"increasing power increases reference height at fixed loft")
                previousHeight=apex
                if club.isPutter { try expectController(apex==0 && shot.launchAngle==0,"putter stays on the ground despite static loft") }
            }
            if !club.isPutter {
                var higher=club;higher.loft+=3
                let low=ClubFlight.launch(club:club,power:0.7),high=ClubFlight.launch(club:higher,power:0.7)
                try expectController(high>low && ClubFlight.apexMeters(ballMPH:70,launch:high,spin:4000,axis:0)>ClubFlight.apexMeters(ballMPH:70,launch:low,spin:4000,axis:0),"loft raises launch and height at equal force/speed")
            }
        }
        let v=35.0,angle=30.0
        let vacuum=pow(v*sin(angle*Double.pi/180),2)/(2*9.80665)
        let drag=ClubFlight.apexMeters(ballMPH:v/0.44704,launch:angle,spin:0,axis:0)
        try expectController(drag>0 && drag<vacuum,"no-spin flight with air resistance stays below vacuum apex")
        print("PASS: official Callaway loft defaults; height increases with force/loft; drag bound and zero-height putts")
    }
}
