import Foundation

enum ControllerInputMode:String,CaseIterable,Identifiable {
    case timing, pad
    var id:String { rawValue }
    var title:String { self == .timing ? "파워 · 타이밍":"트랙패드 스윙" }
}

enum TimingPower:Int,CaseIterable,Identifiable {
    case p30=30,p50=50,p70=70,p100=100
    var id:Int { rawValue }
    var fraction:Double { Double(rawValue)/100 }
    var speed:Double {
        switch self { case .p30:return 0.5;case .p50:return 0.75;case .p70:return 1;case .p100:return 1.5 }
    }
    var difficulty:String {
        switch self { case .p30:return "쉬움";case .p50:return "보통";case .p70:return "어려움";case .p100:return "매우 어려움" }
    }
    var speedLabel:String {
        switch self { case .p30:return "SLOW";case .p50:return "NORMAL";case .p70:return "FAST";case .p100:return "VERY FAST" }
    }
}

enum TimingDirection:String,CaseIterable {
    case leftToRight,rightToLeft
    var title:String { self == .leftToRight ? "왼쪽 → 오른쪽":"오른쪽 → 왼쪽" }
    var startPosition:Double { self == .leftToRight ? 0:1 }
    var endPosition:Double { 1-startPosition }
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

enum TimingState { case ready,running,hit,expired,cancelled
    var title:String {
        switch self { case .ready:return "READY";case .running:return "PRESS SPACE";case .hit:return "RESULT";case .expired:return "MISS";case .cancelled:return "CANCELLED" }
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
    var sideLabel:String { grade == .perfect ? "중앙 타격":signedTimingError<0 ? "너무 빠름":"너무 늦음" }
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
    /// One whole-bar pass. The Perfect region remains +/-2% of bar width.
    var duration:Double { 1.8/power.speed }
    var endsAt:Double { startedAt+duration }
    func position(at time:Double)->Double {
        guard time.isFinite else { return direction.startPosition }
        let progress=controllerClamp((time-startedAt)/duration,0,1)
        return direction == .leftToRight ? progress:1-progress
    }
    func judge(at time:Double) throws->TimingJudgement {
        guard startedAt.isFinite,startedAt>=0,time.isFinite,time>=startedAt,time<=endsAt else {
            throw ReplayError.input("타격 가능한 시간이 아닙니다. 새 스윙을 시작해 주세요.")
        }
        let progress=(time-startedAt)/duration
        let ms=(time-startedAt-duration*0.5)*1000
        return TimingJudgement(sessionID:id,power:power,direction:direction,position:position(at:time),
                               signedTimingError:progress-0.5,milliseconds:abs(ms)<0.0005 ? 0:ms)
    }
}

enum TimingSwingEngine {
    static func shot(_ judgement:TimingJudgement,club:ControllerClub,aim:Double,faceBias:Double)->ControllerSwing {
        let p=judgement.power.fraction,e=judgement.error,t=judgement.signedTimingError
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
            referenceDistance:club.baseDistance*p*judgement.distanceRetention,timing:judgement)
    }
}
