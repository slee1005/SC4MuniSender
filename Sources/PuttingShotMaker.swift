import Foundation

enum SenderInputMode: String, CaseIterable, Identifiable {
    case savedShots
    case puttingMaker

    var id: String { rawValue }
    var title: String { self == .savedShots ? "저장된 샷" : "퍼팅 샷메이커" }
}

enum PuttingShotMaker {
    // A practice assumption, not a measured green-speed calibration.
    static let assumedDeceleration = 0.6

    static func make(distanceFeet: String) throws -> SavedShot {
        guard let feet = Double(distanceFeet.trimmingCharacters(in: .whitespacesAndNewlines)),
              feet.isFinite, feet > 0 else {
            throw ReplayError.input("퍼팅 거리에 0보다 큰 피트(ft) 숫자를 입력해 주세요. 예: 12.5")
        }
        let meters = feet * 0.3048
        let speed = sqrt(2 * assumedDeceleration * meters)
        guard speed.isFinite, (0.01...350).contains(speed / 0.44704) else {
            throw ReplayError.input("전송 가능한 볼 속도 범위의 퍼팅 거리를 입력해 주세요.")
        }
        var shot = SavedShot(id: "putting-maker-preview")
        shot.club = "PT"
        shot.label = "퍼팅 \(ShotInputs.text(feet))ft"
        shot.source = "synthetic_putting_maker"
        shot.isSynthetic = true
        shot.carryDistance = 0
        shot.totalDistance = meters
        shot.distanceUnit = "m"
        shot.ballSpeed = speed
        shot.speedUnit = "m/s"
        shot.launchAngle = 0
        shot.launchDirection = 0
        shot.spinRPM = 0
        shot.spinAxis = 0
        shot.apex = 0
        shot.generationNote = "평지 가정으로 계산한 연습값입니다. 그린 빠르기와 경사에 따라 볼 속도를 조절하세요."
        return shot
    }
}
