import Foundation

extension ControllerTests {
    static func timingCore() throws {
        let speeds:[Double]=[0.5,0.75,1,1.5,1.75]
        let thresholds:[(Double,TimingGrade)]=[(0,.perfect),(0.02,.perfect),(0.020001,.excellent),(0.05,.excellent),
            (0.050001,.good),(0.1,.good),(0.100001,.fair),(0.199999,.fair),(0.2,.miss),(0.5,.miss)]
        let meter=PowerMeterSession(id:UUID(),startedAt:1000)
        for leg in [0.0,1.0,2.0,99.0,100.0] {
            let progress=leg.truncatingRemainder(dividingBy:2)==0 ? 0.683:0.317
            let power=try meter.capture(at:1000+PowerMeterSession.duration*(leg+progress))
            try expectController(abs(power.fraction-0.754)<1e-9,"power continuously captured on either sweep")
        }
        try expectController(tryPower(meter,1000)==0.01,"power minimum produces a valid shot")
        try expectController(tryPower(meter,1000+PowerMeterSession.duration)==1.1,"power peak reaches 110 percent")
        try expectController(TimingPower(fraction:1.101)==nil,"power above 110 percent rejected")
        let oversized=try ControllerSwingEngine.analyze(ControllerSwingEngine.example(.center,depth:1.2),club:ControllerClub.defaults[0])
        try expectController(oversized.power==1.1,"trackpad overswing shares the 110 percent cap")
        var previousSpeed=0.0
        for step in 10...1100 {
            let power=TimingPower(fraction:Double(step)/1000)!
            try expectController(power.speed>previousSpeed,"face bar speeds up continuously across the full power range")
            previousSpeed=power.speed
        }
        try expectController(TimingPower(fraction:.nan)==nil && TimingPower(fraction:0)==nil,"invalid strengths rejected")
        for (index,power) in TimingPower.allCases.enumerated() {
            try expectController(abs(power.speed-speeds[index])<1e-12,"continuous speed retains reference anchors")
            for direction in TimingDirection.allCases {
                let session=TimingSession(id:UUID(),power:power,direction:direction,startedAt:1000)
                try expectController(abs(session.position(at:1000+session.duration*2)-direction.startPosition)<1e-9,"returns to start after a round trip")
                try expectController(abs(session.position(at:1000+session.duration*1.5)-0.5)<1e-9,"center on the reverse pass")
                for (error,grade) in thresholds {
                    for leg in [0.0,1.0,100.0] {
                        let j=try session.judge(at:1000+session.duration*(leg+0.5+error))
                        try expectController(j.grade==grade,"grade bands unchanged after repeated sweeps")
                    }
                }
                for club in ControllerClub.defaults {
                    for p in [0.02,0.25,0.465,0.5,0.535,0.75,0.98] {
                        let j=try session.judge(at:1000+session.duration*p)
                        let shot=TimingSwingEngine.shot(j,club:club,aim:0,faceBias:0)
                        _=try shot.message(deviceID:"TimingTest",number:7).encoded()
                        try expectController(shot.canSend && shot.power==power.fraction,"valid continuous-power contact payload")
                        if club.isPutter { try expectController(shot.spin==0 && shot.launchAngle==0,"putt remains a roll") }
                    }
                }
            }
        }
        let left=TimingSession(id:UUID(),power:.p70,direction:.leftToRight,startedAt:1000)
        let reverse=TimingSession(id:UUID(),power:.p70,direction:.rightToLeft,startedAt:1000)
        let club=ControllerClub.defaults[0]
        let heel=TimingSwingEngine.shot(try left.judge(at:1000+left.duration*0.02),club:club,aim:0,faceBias:0)
        let heelReverse=TimingSwingEngine.shot(try reverse.judge(at:1000+reverse.duration*0.98),club:club,aim:0,faceBias:0)
        let toe=TimingSwingEngine.shot(try left.judge(at:1000+left.duration*0.98),club:club,aim:0,faceBias:0)
        try expectController(heel.horizontalImpactMM<0 && heel.spinAxis>30 && heel.timing!.sideLabel.contains("슬라이스"),"extreme heel means slice")
        try expectController(toe.horizontalImpactMM>0 && toe.spinAxis < -30 && toe.timing!.sideLabel.contains("훅"),"extreme toe means hook")
        try expectController(heel.spinAxis==heelReverse.spinAxis && heel.horizontalImpactMM==heelReverse.horizontalImpactMM,"face position, not motion direction, sets contact")
        let centered=try left.judge(at:1000+left.duration*0.5)
        for club in ControllerClub.defaults {
            let base=TimingSwingEngine.shot(centered,club:club,aim:0,faceBias:0)
            for type in ControllerShotType.allCases {
                for attack in ControllerAttackStyle.allCases {
                    let shot=base.applying(type:type,attackStyle:attack)
                    let object=try JSONSerialization.jsonObject(with:shot.message(deviceID:"Styles",number:1).encoded()) as! [String:Any]
                    let data=object["ClubData"] as! [String:Double]
                    try expectController(data["AngleOfAttack"]==shot.attack,"blow direction included in club delivery")
                    if club.isPutter { try expectController(shot.spin==0 && shot.shotType == .straight && shot.attackStyle == .neutral,"putt ignores spin/style modifiers") }
                }
            }
            if !club.isPutter {
                let down=base.applying(type:.straight,attackStyle:.down),up=base.applying(type:.straight,attackStyle:.up)
                try expectController(down.spin>base.spin && up.spin<base.spin && down.attack<0 && up.attack>0,"down/up changes spin and attack direction")
                let low=base.applying(type:.low,attackStyle:.neutral),high=base.applying(type:.high,attackStyle:.neutral),stinger=base.applying(type:.stinger,attackStyle:.neutral)
                try expectController(stinger.launchAngle<low.launchAngle && low.launchAngle<base.launchAngle && high.launchAngle>base.launchAngle,"low/high/stinger alter actual launch")
                try expectController(base.applying(type:.draw,attackStyle:.neutral).spinAxis<0 && base.applying(type:.fade,attackStyle:.neutral).spinAxis>0,"draw/fade spin signs")
            }
        }
        try expectController(heel.applying(type:.draw,attackStyle:.down).spinAxis>0 && toe.applying(type:.fade,attackStyle:.up).spinAxis<0,"extreme contact dominates intended curve")
        try refuseController("pre-start hit rejected") { _=try left.judge(at:999) }
        try refuseController("NaN clock rejected") { _=try left.judge(at:.nan) }
    }
    static func tryPower(_ meter:PowerMeterSession,_ time:Double)->Double { (try? meter.capture(at:time).fraction) ?? -1 }

    @MainActor static func timingModel() async throws {
        let probe=ControllerProbe()
        let model=ControllerModel(preview:true,exchange:{ try await probe.exchange($0,$1,$2) })
        model.inputMode = .timing;model.shotType = .lowDraw;model.attackStyle = .down
        model.randomTimingDirection=false
        try expectController(model.startTiming(),"starts power meter")
        let meter=model.powerSession!
        try expectController(model.timingState == .settingPower && model.timingSession==nil && !model.canSend,"power must be chosen first")
        model.timingSpace(at:meter.startedAt+PowerMeterSession.duration*0.683)
        let face=model.timingSession!
        try expectController(abs(face.power.fraction-0.754)<1e-9 && model.timingState == .running,"first input captures continuous power")
        model.timingSpace(at:face.startedAt+0.02)
        try expectController(model.swing==nil && model.capturing,"near-simultaneous second input is ignored")
        model.timingSpace(at:face.startedAt+face.duration*100.5)
        let id=model.swing?.id
        model.hitTiming(at:face.startedAt+face.duration*101.5)
        let none=try await probe.objects()
        try expectController(model.swing?.id==id && model.timingResult?.grade == .perfect && none.isEmpty,"many passes allowed, one practice result")
        try expectController(model.swing?.shotType == .lowDraw && model.swing?.attackStyle == .down,"selected style and blow applied")
        model.checkConnection();try await settle(model)
        let checked=try await probe.objects()
        try expectController(checked.count==1 && !model.attempted,"connection check does not send a previously confirmed offline face result")
        let now=ProcessInfo.processInfo.systemUptime
        try expectController(model.startTiming(at:now-2,direction:.rightToLeft),"new game power stage")
        model.timingSpace(at:now)
        let active=model.timingSession!
        try expectController(active.power.fraction==1.1 && abs(active.power.speed-1.75)<1e-9,"110 percent locks into the faster face meter")
        try await Task.sleep(nanoseconds:1_300_000_000)
        try expectController(model.timingActive && model.swing==nil,"contact meter does not expire at the first edge")
        model.timingSpace(at:active.startedAt+active.duration*2.5)
        model.hitTiming(at:active.startedAt+active.duration*3.5)
        try await settle(model)
        let messages=try await probe.objects()
        try expectController(messages.count==2 && model.sent && model.attempted,"confirming the face automatically sends exactly once without an extra send action")
        try expectController(model.startTiming(),"next round")
        model.cancelTimingForFocusLoss()
        try expectController(!model.capturing && model.powerSession==nil && model.timingSession==nil,"focus loss cancels either stage")
        try expectController(model.startTiming(),"round before mode change")
        model.inputMode = .pad
        try expectController(!model.capturing && model.powerSession==nil,"mode switch cancels power meter")
        model.inputMode = .timing;model.distanceText="NaN"
        try expectController(!model.startTiming() && model.isError,"invalid settings block two-stage start")
    }
}
