import Foundation

/// Stock lofts only are manufacturer specifications; launch and flight are our estimates.
enum CallawayClubCatalog {
    static let revision=1
    static let lofts:[String:Double] = ["W1":10.5,"W3":15,"U4":22,"I4":21,"I5":23,"I6":26,
        "I7":30,"I8":34,"I9":38,"PW":43,"GW":50,"SW":56,"LW":60,"PT":3]
    static func model(_ code:String)->String {
        if ["W1","W3","U4"].contains(code) { return "Callaway Elyte" }
        if ["GW","SW","LW"].contains(code) { return "Callaway Opus" }
        return code == "PT" ? "Odyssey Ai-ONE #1 CH":"Callaway Apex Ai200"
    }
    static func source(_ code:String)->URL {
        let path:String
        switch code {
        case "W1":path="www.callawaygolf.com/golf-clubs/drivers/drivers-2025-elyte.html"
        case "W3":path="www.callawaygolf.com/golf-clubs/fairway-woods/fwoods-2025-elyte.html"
        case "U4":path="www.callawaygolf.com/golf-clubs/hybrids/hybrids-2025-elyte.html"
        case "GW","SW","LW":path="www.callawaygolf.com/cg/golf-clubs/wedges/wedges-2024-opus-black.html"
        case "PT":path="odyssey.callawaygolf.com/putters/ai-one/spr5714589.html"
        default:path="www.callawaygolf.com/golf-clubs/irons/irons-2024-apex-ai200.html"
        }
        return URL(string:"https://"+path)!
    }
    static func applyingDefaults(to club:ControllerClub)->ControllerClub {
        var copy=club
        copy.loft=lofts[club.id] ?? club.loft
        copy.launchAngle=ClubFlight.referenceLaunch(loft:copy.loft,code:copy.id,attack:copy.attack)
        return copy
    }
}

enum ClubFlight {
    /// Approximate delivery model, not a Callaway launch-angle specification.
    static func referenceLaunch(loft:Double,code:String,attack:Double)->Double {
        if code == "PT" { return 0 }
        if code == "W1" { return controllerClamp(loft*0.9+4.5,1,70) }
        if code == "W3" { return controllerClamp(loft*0.8+3,1,70) }
        if code == "U4" { return controllerClamp(loft*0.8+2,1,70) }
        return controllerClamp(loft*0.73+1.2+attack*0.15,1,70)
    }
    static func launch(club:ControllerClub,power:Double)->Double {
        if club.isPutter { return 0 }
        let full=referenceLaunch(loft:club.loft,code:club.id,attack:club.attack)
        return controllerClamp(full*(0.75+0.25*sqrt(controllerClamp(power,0.01,1.1))),1,70)
    }
    /// Still air, sea level: gravity, quadratic drag and approximate backspin lift.
    /// It supplies a reference apex; MuniGolf computes its own trajectory from launch data.
    static func apexMeters(ballMPH:Double,launch:Double,spin:Double,axis:Double)->Double {
        guard [ballMPH,launch,spin,axis].allSatisfy(\.isFinite),ballMPH>0,launch>0,launch<90 else { return 0 }
        let radians=launch*Double.pi/180,speed=ballMPH*0.44704
        var vx=speed*cos(radians),vz=speed*sin(radians),height=0.0,apex=0.0
        let dt=0.005,area=Double.pi*pow(0.021335,2),forceFactor=0.5*1.225*area/0.04593
        for step in 0..<8000 {
            let v=max(0.01,hypot(vx,vz))
            let omega=max(0,spin)*2*Double.pi/60*exp(-Double(step)*dt/20)
            let lift=min(0.28,0.6*omega*0.021335/v)*cos(axis*Double.pi/180)
            let ax=forceFactor*v*(-0.25*vx-lift*vz)
            let az=forceFactor*v*(-0.25*vz+lift*vx)-9.80665
            height += vz*dt+0.5*az*dt*dt
            vx += ax*dt;vz += az*dt
            apex=max(apex,height)
            if vz<=0 { break }
        }
        return apex
    }
}

extension ControllerSwing {
    var apexMeters:Double { club.isPutter ? 0:ClubFlight.apexMeters(ballMPH:ballMPH,launch:launchAngle,spin:spin,axis:spinAxis) }
}
