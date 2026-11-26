import Foundation

func controllerClamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(high, max(low, value))
}

struct ControllerClub: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var referenceDistance: Double
    var referenceBallMPH: Double
    var launchAngle: Double
    var spin: Double
    var smash: Double
    var loft: Double
    var attack: Double
    var baseDistance: Double
    var isPutter: Bool { id == "PT" }
    var isWood: Bool { ["W1", "W3", "U4"].contains(id) }
    var fullBallMPH: Double { referenceBallMPH * sqrt(baseDistance / referenceDistance) }

    static let defaults: [Self] = [
        make("W1", "드라이버", 265, 155, 14, 2500, 1.48, 10.5, 3),
        make("W3", "3번 우드", 240, 147, 16, 3500, 1.45, 15, 0),
        make("U4", "4번 하이브리드", 210, 130, 19, 4500, 1.40, 22, -2),
        make("I4", "4번 아이언", 200, 125, 19, 4800, 1.37, 24, -4),
        make("I5", "5번 아이언", 185, 120, 21, 5300, 1.35, 27, -4),
        make("I6", "6번 아이언", 175, 115, 23, 5800, 1.33, 30, -4),
        make("I7", "7번 아이언", 160, 110, 25, 6500, 1.31, 34, -4),
        make("I8", "8번 아이언", 145, 102, 28, 7300, 1.28, 38, -4),
        make("I9", "9번 아이언", 130, 94, 31, 8000, 1.25, 42, -4),
        make("PW", "PW 피칭 웨지", 115, 86, 35, 8500, 1.22, 46, -5),
        make("GW", "GW 갭 웨지", 100, 78, 37, 9000, 1.18, 50, -5),
        make("SW", "SW 샌드 웨지", 85, 70, 40, 9500, 1.12, 56, -5),
        make("LW", "LW 로브 웨지", 65, 58, 44, 9000, 1.04, 60, -5),
        make("PT", "퍼터", 20, 6.25, 0, 0, 1.0, 3, 0),
    ]
    private static func make(_ id: String, _ name: String, _ distance: Double, _ mph: Double,
                             _ angle: Double, _ spin: Double, _ smash: Double, _ loft: Double, _ attack: Double) -> Self {
        Self(id: id, name: name, referenceDistance: distance, referenceBallMPH: mph,
             launchAngle: angle, spin: spin, smash: smash, loft: loft, attack: attack, baseDistance: distance)
    }
    func validated() throws -> Self {
        let values = [referenceDistance, referenceBallMPH, launchAngle, spin, smash, loft, attack, baseDistance]
        guard values.allSatisfy(\.isFinite), referenceDistance > 0, (0.1...600).contains(baseDistance),
              (0.1...220).contains(referenceBallMPH), (0.5...1.6).contains(smash),
              (0...70).contains(launchAngle), (0...20000).contains(spin),
              isPutter || launchAngle >= 1 else { throw ReplayError.input("클럽 기준 거리·발사각·스핀을 확인해 주세요.") }
        guard fullBallMPH.isFinite, (0.01...270).contains(fullBallMPH) else {
            throw ReplayError.input("기준 거리가 너무 큽니다. 클럽 기준 거리를 줄여 주세요.")
        }
        return self
    }
}

struct SwingPoint: Equatable, Codable {
    var x: Double
    var y: Double
    var time: Double
}

enum SwingContact: String, CaseIterable, Codable {
    case center, toe, heel, fat, thin, miss
    var title: String {
        switch self {
        case .center: return "정타"
        case .toe: return "토"
        case .heel: return "힐"
        case .fat: return "뒤땅"
        case .thin: return "얇은 타격"
        case .miss: return "헛스윙"
        }
    }
    var note: String {
        switch self {
        case .center: return "페이스 중앙에 가까운 컨택입니다."
        case .toe: return "토 쪽 컨택으로 속도와 스핀축이 달라집니다."
        case .heel: return "힐 쪽 컨택으로 속도와 스핀축이 달라집니다."
        case .fat: return "공 뒤쪽에서 놓았습니다. 속도와 탄도가 낮아집니다."
        case .thin: return "공 앞쪽에서 놓았습니다. 낮은 탄도로 출발합니다."
        case .miss: return "공을 벗어났습니다. 공의 샷 정보는 전송하지 않습니다."
        }
    }
}

struct ControllerSwing: Identifiable {
    let id: UUID
    let club: ControllerClub
    let points: [SwingPoint]
    let power: Double
    let pathDegrees: Double
    let faceDegrees: Double
    let contact: SwingContact
    let horizontalImpactMM: Double
    let verticalImpactMM: Double
    let ballMPH: Double
    let clubMPH: Double
    let launchAngle: Double
    let launchDirection: Double
    let spin: Double
    let spinAxis: Double
    let attack: Double
    /// Reference distance from the controller's power curve, not a calibrated game result.
    let referenceDistance: Double
    let timing: TimingJudgement?
    var canSend: Bool { contact != .miss && ballMPH >= 0.01 }
    var resultLabel:String { timing.map { "\($0.grade.title) · \(contact.title)" } ?? contact.title }

    func message(deviceID: String, number: Int) throws -> ControllerMessage {
        guard canSend, number > 0 else { throw ReplayError.input("헛스윙은 샷으로 전송하지 않습니다.") }
        let values = [ballMPH, clubMPH, launchAngle, launchDirection, spin, spinAxis, attack,
                      horizontalImpactMM, verticalImpactMM, pathDegrees, faceDegrees]
        guard values.allSatisfy(\.isFinite), (0.01...350).contains(ballMPH), (0.01...300).contains(clubMPH),
              abs(launchAngle) <= 90, abs(launchDirection) <= 90, abs(spinAxis) <= 90,
              (0...100000).contains(spin) else { throw ReplayError.input("스윙 값의 범위를 확인해 주세요.") }
        return ControllerMessage(DeviceID: deviceID, ShotNumber: number,
            BallData: BallPayload(Speed: ballMPH, SpinAxis: spinAxis, TotalSpin: spin,
                                  HLA: launchDirection, VLA: launchAngle, CarryDistance: nil),
            ClubData: ControllerClubPayload(Speed: clubMPH, AngleOfAttack: attack,
                FaceToTarget: faceDegrees, Loft: club.loft, Path: pathDegrees, SpeedAtImpact: clubMPH,
                VerticalFaceImpact: verticalImpactMM, HorizontalFaceImpact: horizontalImpactMM),
            ShotDataOptions: ShotOptions(ContainsBallData: true, ContainsClubData: true,
                LaunchMonitorIsReady: true, LaunchMonitorBallDetected: true, IsHeartBeat: false))
    }
}

struct ControllerClubPayload: Encodable {
    let Speed: Double
    let AngleOfAttack: Double
    let FaceToTarget: Double
    let Loft: Double
    let Path: Double
    let SpeedAtImpact: Double
    let VerticalFaceImpact: Double
    let HorizontalFaceImpact: Double
}

struct ControllerMessage: Encodable {
    let DeviceID: String
    let Units = "Yards"
    let ShotNumber: Int
    let APIversion = "1"
    let BallData: BallPayload
    let ClubData: ControllerClubPayload
    let ShotDataOptions: ShotOptions
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        data.append(10)
        return data
    }
}

enum ControllerSwingEngine {
    static func analyze(_ points: [SwingPoint], club: ControllerClub, aim: Double = 0,
                        faceBias: Double = 0, sensitivity: Double = 1) throws -> ControllerSwing {
        let club = try club.validated()
        guard points.count >= 4, points.count <= 2500,
              points.allSatisfy({ [$0.x,$0.y,$0.time].allSatisfy(\.isFinite) && abs($0.x) <= 5 && abs($0.y) <= 5 }),
              aim.isFinite, faceBias.isFinite, sensitivity.isFinite,
              abs(aim) <= 30, abs(faceBias) <= 15, (0.5...1.8).contains(sensitivity),
              let start = points.first, let end = points.last,
              abs(start.x) <= 0.24, abs(start.y) <= 0.2,
              (0.06...12).contains(end.time-start.time),
              zip(points,points.dropFirst()).allSatisfy({ $0.0.time <= $0.1.time })
        else { throw ReplayError.input("공에서 누르고, 뒤로 당겼다가 공 쪽으로 밀고 놓아 주세요.") }
        let bottomIndex = points.indices.min { points[$0].y < points[$1].y }!
        let bottom = points[bottomIndex]
        let depth = start.y-bottom.y
        guard bottomIndex > 0, bottomIndex < points.count-1, depth >= 0.055,
              end.y-bottom.y >= max(0.04,depth*0.30) else {
            throw ReplayError.input("스윙 취소 · 뒤로 당긴 뒤 공 쪽으로 돌아와 주세요.")
        }
        let backTime = max(0.03,bottom.time-start.time), downTime = max(0.025,end.time-bottom.time)
        let tempo = controllerClamp(0.85 + 0.15 * (backTime/downTime/2.5),0.80,1.08)
        let power = controllerClamp(depth/0.85*sensitivity*tempo,0.025,1.15)
        let before = points[(bottomIndex..<points.count-1).last(where: {
            hypot(end.x-points[$0].x,end.y-points[$0].y) >= 0.025
        }) ?? bottomIndex]
        let dx = end.x-before.x, dy = end.y-before.y
        let path = controllerClamp(atan2(dx,max(0.015,dy))*180/Double.pi,-40,40) + aim
        let face = controllerClamp(aim+faceBias+end.x*18,-45,45)
        let contact: SwingContact
        if abs(end.x)>0.68 || abs(end.y)>0.55 { contact = .miss }
        else if end.y < -0.12 { contact = .fat }
        else if end.y > 0.12 { contact = .thin }
        else if end.x > 0.14 { contact = .toe }
        else if end.x < -0.14 { contact = .heel }
        else { contact = .center }
        var efficiency = 1.0, loftScale = 1.0, spinScale = 1.0, gear = 0.0
        switch contact {
        case .center: efficiency = 1-0.035*pow(end.x/0.14,2)-0.025*pow(end.y/0.12,2)
        case .toe: efficiency = controllerClamp(0.90-abs(end.x)*0.30,0.65,0.88); gear = -abs(end.x)*16; spinScale = 0.92
        case .heel: efficiency = controllerClamp(0.89-abs(end.x)*0.30,0.65,0.87); gear = abs(end.x)*16; spinScale = 0.92
        case .fat: efficiency = controllerClamp(0.72-abs(end.y)*0.65,0.30,0.65); loftScale = 0.8; spinScale = 0.65
        case .thin: efficiency = controllerClamp(0.91-abs(end.y)*0.35,0.60,0.86); loftScale = 0.45; spinScale = 0.4
        case .miss: efficiency = 0
        }
        let movementScale = pow(power,0.72)
        let ball = club.fullBallMPH*movementScale*efficiency
        let clubSpeed = club.fullBallMPH/club.smash*movementScale
        let angle = club.isPutter ? 0 : controllerClamp(club.launchAngle*(0.65+0.35*sqrt(min(power,1.15)))*loftScale,1,70)
        let axis = club.isPutter ? 0 : controllerClamp((face-path)*2+gear,-40,40)
        let spin = club.isPutter ? 0 : club.spin*pow(power,0.60)*spinScale
        let direction = controllerClamp(0.8*face+0.2*path,-45,45)
        let distanceRatio = max(0,ball/club.fullBallMPH)
        let loftRatio = club.isPutter ? 1 : pow(max(0.1,sin(2*angle*Double.pi/180)/max(0.05,sin(2*club.launchAngle*Double.pi/180))),0.35)
        let distance = club.baseDistance*pow(distanceRatio,club.isPutter ? 2 : 1.8)*loftRatio
        func r(_ n: Double) -> Double { abs(n)<0.0005 ? 0 : (n*1000).rounded()/1000 }
        return ControllerSwing(id: UUID(), club: club, points: points, power: power,
            pathDegrees: r(path), faceDegrees: r(face), contact: contact,
            horizontalImpactMM: r(controllerClamp(end.x/0.68,-1,1)*(club.isWood ? 40:25)),
            verticalImpactMM: r(-controllerClamp(end.y/0.55,-1,1)*(club.isWood ? 22:16)),
            ballMPH: r(ball), clubMPH: r(clubSpeed), launchAngle: r(angle), launchDirection: r(direction),
            spin: spin.rounded(), spinAxis: r(axis), attack: r(controllerClamp(club.attack+end.y*10,-15,12)),
            referenceDistance: distance,timing:nil)
    }

    static func example(_ contact: SwingContact, depth: Double = 0.72) -> [SwingPoint] {
        let end: (Double,Double)
        switch contact {
        case .center: end=(0,0)
        case .toe: end=(0.27,0)
        case .heel: end=(-0.27,0)
        case .fat: end=(0,-0.24)
        case .thin: end=(0,0.24)
        case .miss: end=(0.8,0)
        }
        return [SwingPoint(x:0,y:0,time:0),SwingPoint(x:0,y:-depth*0.5,time:0.22),
                SwingPoint(x:0,y:-depth,time:0.5),SwingPoint(x:end.0*0.3,y:-depth*0.5,time:0.59),
                SwingPoint(x:end.0*0.7,y:(-depth*0.15+end.1*0.5),time:0.65),
                SwingPoint(x:end.0,y:end.1,time:0.7)]
    }
}
