import Foundation

enum ControllerInputMode:String,CaseIterable,Identifiable {
    case timing, pad
    var id:String { rawValue }
    var title:String { self == .timing ? "파워 · 타이밍":"트랙패드 스윙" }
}

struct TimingPower:Equatable,Hashable,CaseIterable,Identifiable {
    let fraction:Double
    var id:Double { fraction }
    var rawValue:Int { Int((fraction*100).rounded()) }
    var label:String { ShotInputs.text(fraction*100)+"%" }
    init?(fraction:Double) {
        guard fraction.isFinite,(0.01...1).contains(fraction) else { return nil }
        self.fraction=fraction
    }
    init?(rawValue:Int) { self.init(fraction:Double(rawValue)/100) }
    static let p30=Self(fraction:0.3)!,p50=Self(fraction:0.5)!,p70=Self(fraction:0.7)!,p100=Self(fraction:1)!
    static let allCases:[Self]=[.p30,.p50,.p70,.p100]
    var speed:Double {
        let points:[(Double,Double)]=[(0.01,0.2),(0.3,0.5),(0.5,0.75),(0.7,1),(1,1.5)]
        for i in 1..<points.count where fraction<=points[i].0 {
            let a=points[i-1],b=points[i]
            return a.1+(b.1-a.1)*(fraction-a.0)/(b.0-a.0)
        }
        return 1.5
    }
    var difficulty:String { fraction<=0.3 ? "쉬움":fraction<=0.5 ? "보통":fraction<=0.7 ? "어려움":"매우 어려움" }
    var speedLabel:String { fraction<=0.3 ? "SLOW":fraction<=0.5 ? "NORMAL":fraction<=0.7 ? "FAST":"VERY FAST" }
}

enum TimingDirection:String,CaseIterable {
    case leftToRight,rightToLeft
    var title:String { self == .leftToRight ? "왼쪽 → 오른쪽":"오른쪽 → 왼쪽" }
    var startPosition:Double { self == .leftToRight ? 0:1 }
    var endPosition:Double { 1-startPosition }
    var opposite:Self { self == .leftToRight ? .rightToLeft:.leftToRight }
}

/// A triangle wave avoids frame counting and runs until a human stops it.
enum SwingBarWave {
    static func sample(elapsed:Double,duration:Double)->(position:Double,progress:Double,reversed:Bool) {
        guard elapsed.isFinite,duration.isFinite,duration>0 else { return (0,0,false) }
        let cycle=(max(0,elapsed)/duration).truncatingRemainder(dividingBy:2)
        let reversed=cycle>=1,progress=reversed ? cycle-1:cycle
        return (reversed ? 1-progress:progress,progress,reversed)
    }
}

struct PowerMeterSession {
    let id:UUID
    let startedAt:Double
    static let duration=2.0
    func position(at time:Double)->Double { SwingBarWave.sample(elapsed:time-startedAt,duration:Self.duration).position }
    func capture(at time:Double) throws->TimingPower {
        guard time.isFinite,startedAt.isFinite,time>=startedAt else { throw ReplayError.input("강도 바를 다시 시작해 주세요.") }
        let fraction=controllerClamp((position(at:time)*1000).rounded()/1000,0.01,1)
        return TimingPower(fraction:fraction)!
    }
}

enum TimingGrade:String,CaseIterable {
    case perfect="Perfect",excellent="Excellent",good="Good",fair="Fair",miss="Miss"
    var title:String { rawValue }
    var description:String {
        switch self {
        case .perfect:return "정타"
        case .excellent:return "거의 정타"
        case .good:return "약간 빗맞음"
        case .fair:return "거리 손실"
        case .miss:return "큰 거리·방향 손실"
        }
    }
    var rangeLabel:String {
        switch self {
        case .perfect:return "0~2%";case .excellent:return "2~5%";case .good:return "5~10%"
        case .fair:return "10~20%";case .miss:return "20% 이상"
        }
    }
    static func classify(error:Double)->Self {
        guard error.isFinite else { return .miss }
        let e=abs(error),epsilon=1e-12
        if e<=0.02+epsilon { return .perfect }
        if e<=0.05+epsilon { return .excellent }
        if e<=0.10+epsilon { return .good }
        if e<0.20-epsilon { return .fair }
        return .miss
    }
}

enum TimingState { case ready,settingPower,running,hit,cancelled
    var title:String {
        switch self { case .ready:return "READY";case .settingPower:return "1 · POWER";case .running:return "2 · FACE CONTACT";case .hit:return "RESULT";case .cancelled:return "CANCELLED" }
    }
}

struct TimingJudgement {
    let sessionID:UUID
    let power:TimingPower
    let direction:TimingDirection
    let position:Double
    let signedTimingError:Double
    let milliseconds:Double
    var error:Double { abs(position-0.5) }
    var grade:TimingGrade { TimingGrade.classify(error:error) }
    var faceError:Double { position-0.5 }
    var sideLabel:String {
        if position<=0.1 { return "극힐 · 슬라이스" }
        if position>=0.9 { return "극토 · 훅" }
        if grade == .perfect { return "스위트스폿" }
        return position<0.5 ? "힐 쪽":"토 쪽"
    }
    var distanceRetention:Double {
        let e=error
        let knots:[(Double,Double)]=[(0,1),(0.02,1),(0.05,0.97),(0.10,0.90),(0.20,0.70),(0.50,0.25)]
        for i in 1..<knots.count where e<=knots[i].0 {
            let a=knots[i-1],b=knots[i]
            return a.1+(b.1-a.1)*(e-a.0)/(b.0-a.0)
        }
        return 0.25
    }
}

struct TimingSession {
    let id:UUID
    let power:TimingPower
    let direction:TimingDirection
    let startedAt:Double
    /// One leg of an endless left/right movement; center bands are fixed.
    var duration:Double { 1.8/power.speed }
    func position(at time:Double)->Double {
        guard time.isFinite else { return direction.startPosition }
        let wave=SwingBarWave.sample(elapsed:time-startedAt,duration:duration)
        return direction == .leftToRight ? wave.position:1-wave.position
    }
    func direction(at time:Double)->TimingDirection {
        SwingBarWave.sample(elapsed:time-startedAt,duration:duration).reversed ? direction.opposite:direction
    }
    func judge(at time:Double) throws->TimingJudgement {
        guard startedAt.isFinite,startedAt>=0,time.isFinite,time>=startedAt else {
            throw ReplayError.input("타격 가능한 시간이 아닙니다. 새 스윙을 시작해 주세요.")
        }
        let wave=SwingBarWave.sample(elapsed:time-startedAt,duration:duration)
        let ms=(wave.progress-0.5)*duration*1000
        return TimingJudgement(sessionID:id,power:power,direction:direction(at:time),position:position(at:time),
                               signedTimingError:wave.progress-0.5,milliseconds:abs(ms)<0.0005 ? 0:ms)
    }
}

enum TimingSwingEngine {
    static func shot(_ judgement:TimingJudgement,club:ControllerClub,aim:Double,faceBias:Double)->ControllerSwing {
        let p=judgement.power.fraction,e=judgement.error,t=judgement.faceError
        let face=controllerClamp(aim+faceBias-t*35,-45,45)
        let horizontal=t*2*(club.isWood ? 40.0:25.0)
        let contact:SwingContact = judgement.grade == .perfect || judgement.grade == .excellent ? .center:t<0 ? .heel:.toe
        let ball=club.fullBallMPH*pow(p*judgement.distanceRetention,club.isPutter ? 0.5:1/1.8)
        let clubSpeed=club.fullBallMPH/club.smash*pow(p,club.isPutter ? 0.5:1/1.8)
        let angle=club.isPutter ? 0:club.launchAngle*(0.7+0.3*sqrt(p))*(1-0.2*e)
        let axis=club.isPutter ? 0:controllerClamp((face-aim)*2-horizontal*(club.isWood ? 0.3:0.18),-40,40)
        func r(_ n:Double)->Double { abs(n)<0.0005 ? 0:(n*1000).rounded()/1000 }
        return ControllerSwing(id:UUID(),club:club,points:[],power:p,pathDegrees:r(aim),faceDegrees:r(face),
            contact:contact,horizontalImpactMM:r(horizontal),verticalImpactMM:0,
            ballMPH:r(ball),clubMPH:r(clubSpeed),launchAngle:r(angle),launchDirection:r(controllerClamp(0.8*face+0.2*aim,-45,45)),
            spin:club.isPutter ? 0:(club.spin*pow(p,0.6)*(1-0.5*e)).rounded(),spinAxis:r(axis),attack:club.attack,
            referenceDistance:club.baseDistance*p*judgement.distanceRetention,timing:judgement,shotType:.straight,attackStyle:.neutral)
    }
}
