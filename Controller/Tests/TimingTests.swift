import Foundation

extension ControllerTests {
    static func timingCore() throws {
        let speeds:[Double]=[0.5,0.75,1,1.5],durations:[Double]=[3.6,2.4,1.8,1.2]
        let thresholds:[(Double,TimingGrade)]=[(0,.perfect),(0.02,.perfect),(0.020001,.excellent),
            (0.05,.excellent),(0.050001,.good),(0.1,.good),(0.100001,.fair),(0.199999,.fair),(0.2,.miss),(0.5,.miss)]
        for (error,grade) in thresholds {
            try expectController(TimingGrade.classify(error:error)==grade,"exact judgement boundary \(error)")
        }
        for (index,power) in TimingPower.allCases.enumerated() {
            try expectController(power.speed==speeds[index],"specified power-speed mapping")
            for direction in TimingDirection.allCases {
                let session=TimingSession(id:UUID(),power:power,direction:direction,startedAt:1000)
                try expectController(abs(session.duration-durations[index])<1e-12,"one-pass speed")
                try expectController(session.position(at:999)==direction.startPosition && session.position(at:1009)==direction.endPosition,"bar endpoint clamping")
                for (error,grade) in thresholds {
                    let time=session.startedAt+session.duration*(0.5+error)
                    let judgement=try session.judge(at:time)
                    try expectController(judgement.grade==grade,"fixed grade band for every speed and direction")
                }
                for club in ControllerClub.defaults {
                    for progress in [0.05,0.25,0.425,0.465,0.49,0.5,0.51,0.535,0.575,0.75,0.95] {
                        let judgement=try session.judge(at:session.startedAt+session.duration*progress)
                        let shot=TimingSwingEngine.shot(judgement,club:club,aim:0,faceBias:0)
                        let object=try JSONSerialization.jsonObject(with:shot.message(deviceID:"TimingTest",number:7).encoded()) as! [String:Any]
                        let ball=object["BallData"] as! [String:Any]
                        try expectController(shot.canSend && shot.power==power.fraction && shot.timing?.grade==judgement.grade,"power and grade retained in valid shot")
                        try expectController(ball["CarryDistance"]==nil && object["TimingGrade"]==nil,"wire uses supported ball/club data only")
                        if club.isPutter { try expectController(shot.spin==0 && shot.launchAngle==0 && shot.spinAxis==0,"timed putt remains a roll") }
                        if abs(progress-0.5)<1e-10 {
                            try expectController(abs(shot.referenceDistance-club.baseDistance*power.fraction)<1e-8 && shot.launchDirection==0,"Perfect combines exact selected power and club anchor")
                        }
                    }
                }
            }
        }
        let a=TimingSession(id:UUID(),power:.p70,direction:.leftToRight,startedAt:10)
        let b=TimingSession(id:UUID(),power:.p70,direction:.rightToLeft,startedAt:10)
        let earlyA=try a.judge(at:10+a.duration*0.42),earlyB=try b.judge(at:10+b.duration*0.42)
        let club=ControllerClub.defaults[0]
        let shotA=TimingSwingEngine.shot(earlyA,club:club,aim:0,faceBias:0)
        let shotB=TimingSwingEngine.shot(earlyB,club:club,aim:0,faceBias:0)
        let late=TimingSwingEngine.shot(try a.judge(at:10+a.duration*0.58),club:club,aim:0,faceBias:0)
        try expectController(earlyA.position<0.5 && earlyB.position>0.5 && earlyA.grade==earlyB.grade,"random direction mirrors motion without changing accuracy rules")
        try expectController(shotA.ballMPH==shotB.ballMPH && shotA.spinAxis==shotB.spinAxis && shotA.launchDirection==shotB.launchDirection,"early/late shape is independent of bar direction")
        try expectController(shotA.launchDirection>0 && shotA.spinAxis>0 && late.launchDirection<0 && late.spinAxis<0,"early fade and late draw")
        let miss=TimingSwingEngine.shot(try a.judge(at:10+a.duration*0.85),club:club,aim:0,faceBias:0)
        try expectController(miss.canSend && miss.timing?.grade == .miss && miss.referenceDistance<shotA.referenceDistance,"pressed Miss is a reduced mishit rather than a whiff")
        try refuseController("pre-start hit rejected") { _=try a.judge(at:9.9) }
        try refuseController("late hit rejected") { _=try a.judge(at:a.endsAt+0.001) }
        try refuseController("NaN clock rejected") { _=try a.judge(at:.nan) }
    }

    @MainActor static func timingModel() async throws {
        let probe=ControllerProbe()
        let model=ControllerModel(preview:true,exchange:{ try await probe.exchange($0,$1,$2) })
        model.inputMode = .timing;model.timingPower = .p70
        model.randomTimingDirection=false
        try expectController(model.startTiming(),"timing starts in practice")
        let first=model.timingSession!
        try expectController(first.direction == .leftToRight && model.capturing && !model.canSend,"fixed direction and active guard")
        model.hitTiming(at:first.startedAt+first.duration*0.5)
        let shotID=model.swing?.id
        model.hitTiming(at:first.startedAt+first.duration*0.6)
        let noShots=try await probe.objects()
        try expectController(model.timingState == .hit && model.timingResult?.grade == .perfect && model.swing?.id==shotID && noShots.isEmpty,"practice hit freezes once without automatic network traffic")
        try expectController(model.startTiming(direction:.rightToLeft),"start next round")
        let second=model.timingSession!
        model.expireTiming(sessionID:first.id,at:first.endsAt+1)
        try expectController(model.timingActive && model.timingSession?.id==second.id,"stale timeout cannot expire next round")
        model.cancelTimingForFocusLoss()
        try expectController(!model.capturing && model.swing==nil && model.timingState == .cancelled,"focus loss cancels without a pending shot")
        model.checkConnection();try await settle(model);model.setGameMode(true)
        try expectController(model.startTiming(direction:.leftToRight),"game timing start")
        let game=model.timingSession!
        model.hitTiming(at:game.startedAt+game.duration*0.75);model.send()
        try await settle(model)
        let messages=try await probe.objects()
        try expectController(messages.count==2 && model.sent && model.timingResult?.grade == .miss,"one heartbeat and exactly one reduced Miss shot")
        model.timingPower = .p100
        try expectController(model.startTiming(direction:.rightToLeft),"automatic timeout start")
        let timeout=model.timingSession!
        for _ in 0..<150 {
            if !model.timingActive { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let afterTimeout=try await probe.objects()
        try expectController(model.timingState == .expired && !model.canSend && afterTimeout.count==2,"deadline with no Space causes no shot")
        // Simulate a keyboard event queued before deadline but delivered after
        // the main actor processed its timeout. Event time is authoritative.
        model.timingSpace(at:timeout.startedAt+timeout.duration*0.5)
        try await settle(model)
        let recovered=try await probe.objects()
        try expectController(model.timingResult?.grade == .perfect && recovered.count==3,"queued pre-deadline Space judged at actual timestamp")
        model.setGameMode(false)
        try expectController(model.startTiming(),"round before switching input")
        model.inputMode = .pad
        try expectController(!model.capturing && model.timingSession==nil && model.swing==nil,"switching mode cancels active round")
        model.inputMode = .timing;model.distanceText="NaN"
        try expectController(!model.startTiming() && model.isError && !model.canSend,"invalid anchor blocks timing too")
    }
}
