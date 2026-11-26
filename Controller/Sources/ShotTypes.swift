import Foundation

enum ControllerShotType:String,CaseIterable,Identifiable {
    case straight,draw,fade,low,high,stinger,lowDraw,lowFade,highDraw,highFade
    var id:String { rawValue }
    var title:String {
        switch self {
        case .straight:return "스트레이트";case .draw:return "드로우";case .fade:return "페이드"
        case .low:return "로우";case .high:return "하이";case .stinger:return "스팅어"
        case .lowDraw:return "로우 드로우";case .lowFade:return "로우 페이드"
        case .highDraw:return "하이 드로우";case .highFade:return "하이 페이드"
        }
    }
    var curve:Double {
        switch self { case .draw,.lowDraw,.highDraw:return -8;case .fade,.lowFade,.highFade:return 8;default:return 0 }
    }
    var loftScale:Double {
        switch self { case .low,.lowDraw,.lowFade:return 0.72;case .high,.highDraw,.highFade:return 1.28;case .stinger:return 0.45;default:return 1 }
    }
    var spinScale:Double {
        switch self { case .low,.lowDraw,.lowFade:return 0.8;case .high,.highDraw,.highFade:return 1.15;case .stinger:return 0.55;default:return 1 }
    }
    var distanceScale:Double { loftScale<0.5 ? 0.88:loftScale<1 ? 0.96:loftScale>1 ? 0.90:1 }
}

enum ControllerAttackStyle:String,CaseIterable,Identifiable {
    case neutral,down,up
    var id:String { rawValue }
    var title:String { self == .down ? "다운블로":self == .up ? "어퍼블로":"기본 블로" }
    var spinScale:Double { self == .down ? 1.2:self == .up ? 0.8:1 }
    var note:String { self == .down ? "기준 스핀 +20%":self == .up ? "기준 스핀 −20%":"기준 스핀 유지" }
}

extension ControllerSwing {
    func applying(type:ControllerShotType,attackStyle selectedAttack:ControllerAttackStyle)->Self {
        let type=club.isPutter ? .straight:type,selectedAttack=club.isPutter ? .neutral:selectedAttack
        let launchShift=type.curve<0 ? 1.5:type.curve>0 ? -1.5:0
        let pathShift=type.curve<0 ? 5.5:type.curve>0 ? -5.5:0
        let newAttack=selectedAttack == .down ? min(-5,attack-3):selectedAttack == .up ? max(3,attack+5):attack
        func r(_ n:Double)->Double { abs(n)<0.0005 ? 0:(n*1000).rounded()/1000 }
        return Self(id:id,club:club,points:points,power:power,pathDegrees:r(pathDegrees+pathShift),faceDegrees:r(faceDegrees+launchShift),
            contact:contact,horizontalImpactMM:horizontalImpactMM,verticalImpactMM:verticalImpactMM,
            ballMPH:ballMPH,clubMPH:clubMPH,launchAngle:club.isPutter ? 0:r(controllerClamp(launchAngle*type.loftScale,1,70)),
            launchDirection:r(controllerClamp(launchDirection+launchShift,-45,45)),
            spin:club.isPutter ? 0:(spin*type.spinScale*selectedAttack.spinScale).rounded(),
            spinAxis:club.isPutter ? 0:r(controllerClamp(spinAxis+type.curve,-45,45)),attack:r(controllerClamp(newAttack,-15,12)),
            referenceDistance:referenceDistance*type.distanceScale,timing:timing,shotType:type,attackStyle:selectedAttack)
    }
}
