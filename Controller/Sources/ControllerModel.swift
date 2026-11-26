import Foundation
import SwiftUI

@MainActor final class ControllerModel: ObservableObject {
    @Published var clubs: [ControllerClub]
    @Published var selectedCode = "PW" { didSet { loadFields(); resetSwing() } }
    @Published var distanceUnit: DistanceDisplayUnit = .yards { didSet { loadFields(); persist() } }
    @Published var distanceText = ""
    @Published var angleText = ""
    @Published var spinText = ""
    @Published var host: String { didSet { connectionChanged() } }
    @Published var port: String { didSet { connectionChanged() } }
    @Published var aim = 0.0
    @Published var faceBias = 0.0
    @Published var sensitivity = 1.0
    @Published var serverReady = false
    @Published var busy = false
    @Published var capturing = false
    @Published var livePower = 0.0
    @Published var swing: ControllerSwing?
    @Published var attempted = false
    @Published var sent = false
    @Published private(set) var isExample = false
    @Published var message = "연습 모드입니다."
    @Published var isError = false
    @Published var resetToken = UUID()
    @Published var history: [String] = []
    @Published var inputMode:ControllerInputMode = .timing {
        didSet { resetSwing();defaults?.set(inputMode.rawValue,forKey:"controllerInputMode") }
    }
    @Published var timingPower:TimingPower = .p70 {
        didSet {
            if !capturing { resetSwing() }
            defaults?.set(timingPower.fraction,forKey:"controllerPowerFraction")
        }
    }
    @Published var randomTimingDirection=true {
        didSet { defaults?.set(randomTimingDirection,forKey:"controllerRandomTimingDirection") }
    }
    @Published var timingSession:TimingSession?
    @Published var powerSession:PowerMeterSession?
    @Published var timingResult:TimingJudgement?
    @Published var timingState:TimingState = .ready
    @Published var shotType:ControllerShotType = .straight {
        didSet { resetSwing();defaults?.set(shotType.rawValue,forKey:"controllerShotType") }
    }
    @Published var attackStyle:ControllerAttackStyle = .neutral {
        didSet { resetSwing();defaults?.set(attackStyle.rawValue,forKey:"controllerAttackStyle") }
    }
    var timingActive:Bool { capturing && (timingState == .settingPower || timingState == .running) }
    private var timingClub:ControllerClub?
    private var captureShotType:ControllerShotType = .straight
    private var captureAttackStyle:ControllerAttackStyle = .neutral
    private var timingDirection:TimingDirection = .leftToRight
    private var lastTimingInputAt:Double?
    private let defaults: UserDefaults?
    private var sequence: Int
    private let deviceID: String
    private let exchange: (String, UInt16, Data) async throws -> APIReply
    private var captureClub: ControllerClub?
    private var captureAim = 0.0
    private var captureFace = 0.0
    private var captureSensitivity = 1.0

    init(preview: Bool = false,
         exchange: @escaping (String, UInt16, Data) async throws -> APIReply = {
             try await OpenConnectTransport.exchange(host:$0,port:$1,data:$2)
         }) {
        self.exchange=exchange
        let prefs = preview ? nil : UserDefaults.standard
        defaults = prefs
        if let data = prefs?.data(forKey:"controllerClubs"),
           let saved = try? JSONDecoder().decode([ControllerClub].self,from:data),
           Set(saved.map(\.id)) == Set(ControllerClub.defaults.map(\.id)),
           saved.count == ControllerClub.defaults.count, saved.allSatisfy({ (try? $0.validated()) != nil }) {
            clubs = saved
        } else { clubs = ControllerClub.defaults }
        host = prefs?.string(forKey:"gameHost") ?? "127.0.0.1"
        port = prefs?.string(forKey:"gamePort") ?? "9210"
        sequence = max(0,prefs?.integer(forKey:"controllerShotNumber") ?? 0)
        deviceID = prefs?.string(forKey:"controllerDeviceID") ?? "MuniController-"+String(UUID().uuidString.prefix(8))
        if !preview { prefs?.set(deviceID,forKey:"controllerDeviceID") }
        distanceUnit = DistanceDisplayUnit(rawValue:prefs?.string(forKey:"controllerDistanceUnit") ?? "yd") ?? .yards
        inputMode=ControllerInputMode(rawValue:prefs?.string(forKey:"controllerInputMode") ?? "timing") ?? .timing
        let savedFraction=prefs?.object(forKey:"controllerPowerFraction") as? Double
        timingPower=savedFraction.flatMap{TimingPower(fraction:$0)} ?? TimingPower(rawValue:prefs?.integer(forKey:"controllerTimingPower") ?? 70) ?? .p70
        randomTimingDirection=prefs?.object(forKey:"controllerRandomTimingDirection") as? Bool ?? true
        shotType=ControllerShotType(rawValue:prefs?.string(forKey:"controllerShotType") ?? "straight") ?? .straight
        attackStyle=ControllerAttackStyle(rawValue:prefs?.string(forKey:"controllerAttackStyle") ?? "neutral") ?? .neutral
        loadFields()
        livePower=inputMode == .timing ? timingPower.fraction:0
        message = "START → Space/클릭으로 강도 확정 → Space/클릭으로 페이스 타점 확정"
        if preview { example(.center) }
    }
    var selectedClub: ControllerClub { clubs.first { $0.id == selectedCode } ?? clubs[0] }
    var displayUnit: String { selectedClub.isPutter ? "ft" : distanceUnit.rawValue }
    func displayedDistance(_ club: ControllerClub) -> Double {
        club.isPutter || distanceUnit == .yards ? club.baseDistance : club.baseDistance*0.9144
    }
    func swingDistance(_ swing: ControllerSwing) -> Double {
        swing.club.isPutter || distanceUnit == .yards ? swing.referenceDistance : swing.referenceDistance*0.9144
    }
    var configurationIssue: String? {
        do { _=try configuredClub();return nil } catch { return error.localizedDescription }
    }
    var canSend: Bool { serverReady && !busy && !capturing && !attempted && !isExample && swing?.canSend == true }
    var transmissionStatus: String {
        if busy { return attempted ? "전송 중…" : "연결 확인 중…" }
        if sent { return "전송 완료" }
        if attempted { return "전송 응답 확인 필요" }
        if isExample { return "연습 예시 · 전송 안 함" }
        if let swing=swing {
            if !swing.canSend { return "헛스윙 · 전송 안 함" }
            return serverReady ? "이 스윙은 전송 안 됨 · 다음 스윙부터 자동 전송" : "미연결 · 전송 안 함"
        }
        return serverReady ? "페이스 타점 확정 시 자동 전송" : "연결 확인 후 자동 전송"
    }
    private func configuredClub() throws -> ControllerClub {
        guard let distance=Double(distanceText),distance.isFinite,
              let angle=Double(angleText),let spin=Double(spinText) else {
            throw ReplayError.input("기준 거리·발사각·스핀에 숫자를 입력해 주세요.")
        }
        var club=selectedClub
        club.baseDistance=club.isPutter || distanceUnit == .yards ? distance : distance/0.9144
        club.launchAngle=angle;club.spin=spin
        return try club.validated()
    }
    private func loadFields() {
        distanceText=String(format:"%.1f",locale:Locale(identifier:"en_US_POSIX"),displayedDistance(selectedClub))
        angleText=ShotInputs.text(selectedClub.launchAngle)
        spinText=ShotInputs.text(selectedClub.spin)
    }
    func applySettings() {
        do {
            let club=try configuredClub()
            if let index=clubs.firstIndex(where:{$0.id==club.id}) { clubs[index]=club }
            persist();isError=false;message="\(club.name)의 기준 설정을 저장했습니다."
            resetSwing()
        } catch { fail(error.localizedDescription) }
    }
    func restoreClub() {
        if let original=ControllerClub.defaults.first(where:{$0.id==selectedCode}),
           let index=clubs.firstIndex(where:{$0.id==selectedCode}) { clubs[index]=original }
        loadFields();persist();resetSwing()
    }
    private func persist() {
        if let data=try? JSONEncoder().encode(clubs) { defaults?.set(data,forKey:"controllerClubs") }
        defaults?.set(distanceUnit.rawValue,forKey:"controllerDistanceUnit")
    }
    private func connectionChanged() {
        serverReady=false
        defaults?.set(host,forKey:"gameHost");defaults?.set(port,forKey:"gamePort")
    }
    func resetSwing() {
        timingSession=nil;powerSession=nil;timingResult=nil;timingState = .ready;timingClub=nil;lastTimingInputAt=nil
        resetToken=UUID();capturing=false;captureClub=nil;livePower=0
        swing=nil;attempted=false;sent=false;isExample=false
    }
    func begin() -> Bool {
        guard inputMode == .pad,!busy,!capturing else { return false }
        do {
            let club=try configuredClub()
            if let index=clubs.firstIndex(where:{$0.id==club.id}) { clubs[index]=club };persist()
            captureClub=club;captureAim=aim;captureFace=faceBias;captureSensitivity=sensitivity
            captureShotType=shotType;captureAttackStyle=attackStyle
            capturing=true;livePower=0;swing=nil;attempted=false;sent=false;isExample=false;isError=false
            message="뒤로 당겨 스윙 크기를 정한 뒤, 공 쪽으로 밀고 공 위에서 놓으세요."
            return true
        } catch {
            swing=nil;attempted=false;sent=false;isExample=false;livePower=0
            fail(error.localizedDescription);return false
        }
    }
    func update(depth: Double) { livePower=controllerClamp(depth/0.85*captureSensitivity,0,TimingPower.maximumFraction) }
    func cancel(_ reason: String) {
        timingSession=nil;powerSession=nil;timingResult=nil;timingState = .cancelled;timingClub=nil;lastTimingInputAt=nil
        capturing=false;captureClub=nil;livePower=0;swing=nil;attempted=false;sent=false;isExample=false
        message=reason;isError=false
    }
    func finish(_ points: [SwingPoint]) {
        finish(points,isExample:false)
    }
    private func finish(_ points: [SwingPoint],isExample:Bool) {
        guard inputMode == .pad,capturing,let club=captureClub else { return }
        capturing=false;captureClub=nil
        do {
            let result=try ControllerSwingEngine.analyze(points,club:club,aim:captureAim,faceBias:captureFace,sensitivity:captureSensitivity)
                .applying(type:captureShotType,attackStyle:captureAttackStyle)
            swing=result;livePower=result.power;attempted=false;sent=false;isError=false
            self.isExample=isExample
            message=result.contact.note
            if !result.canSend { addHistory("\(result.club.name) · 헛스윙 · 전송 안 함") }
            else { send() }
        } catch { livePower=0;fail(error.localizedDescription) }
    }
    func example(_ contact: SwingContact) {
        guard !busy,!capturing else { return }
        inputMode = .pad
        resetToken=UUID()
        if begin() { finish(ControllerSwingEngine.example(contact),isExample:true) }
        message="연습 예시 · \(contact.title). 게임에 전송하지 않았습니다."
    }
    @discardableResult func startTiming(at time:Double=ProcessInfo.processInfo.systemUptime,direction:TimingDirection?=nil)->Bool {
        guard inputMode == .timing,!busy,!capturing,time.isFinite,time>=0 else { return false }
        do {
            let club=try configuredClub()
            if let index=clubs.firstIndex(where:{$0.id==club.id}) { clubs[index]=club };persist()
            resetSwing()
            captureClub=club;captureAim=aim;captureFace=faceBias
            timingClub=club
            captureShotType=shotType;captureAttackStyle=attackStyle
            timingDirection=direction ?? (randomTimingDirection && Bool.random() ? .rightToLeft:.leftToRight)
            powerSession=PowerMeterSession(id:UUID(),startedAt:time)
            timingState = .settingPower;capturing=true;livePower=0
            isError=false;message="1단계 · 강도 바가 왕복합니다. Space 또는 바 클릭으로 강도를 확정하세요."
            return true
        } catch { resetSwing();fail(error.localizedDescription);return false }
    }
    func timingSpace(at time:Double=ProcessInfo.processInfo.systemUptime) {
        guard inputMode == .timing,!busy,time.isFinite else { return }
        if let last=lastTimingInputAt,time-last<0.12 { return }
        if timingState == .settingPower {
            guard let session=powerSession,time>=session.startedAt else { return }
            lockPower(at:time);lastTimingInputAt=time
        } else if timingState == .running {
            guard let session=timingSession,time>=session.startedAt else { return }
            hitTiming(at:time);lastTimingInputAt=time
        } else if startTiming(at:time) { lastTimingInputAt=time }
    }
    func lockPower(at time:Double=ProcessInfo.processInfo.systemUptime) {
        guard capturing,timingState == .settingPower,let session=powerSession else { return }
        do {
            let chosen=try session.capture(at:time)
            timingPower=chosen;livePower=chosen.fraction
            timingSession=TimingSession(id:UUID(),power:chosen,direction:timingDirection,startedAt:time)
            timingState = .running;isError=false
            message="2단계 · 페이스 타점 선택: 왼쪽 힐 / 중앙 스위트스폿 / 오른쪽 토. Space 또는 클릭으로 확정하세요."
        } catch { fail(error.localizedDescription) }
    }
    func hitTiming(at time:Double=ProcessInfo.processInfo.systemUptime) {
        guard capturing,timingState == .running,let session=timingSession,let club=timingClub else { return }
        do {
            let judgement=try session.judge(at:time)
            let result=TimingSwingEngine.shot(judgement,club:club,aim:captureAim,faceBias:captureFace)
                .applying(type:captureShotType,attackStyle:captureAttackStyle)
            _=try result.message(deviceID:deviceID,number:1).encoded()
            capturing=false;captureClub=nil;timingState = .hit;timingResult=judgement
            swing=result;livePower=judgement.power.fraction;attempted=false;sent=false;isError=false
            message=String(format:"%@ · 중앙 오차 %.1f%% · %@",judgement.grade.title,judgement.error*100,judgement.sideLabel)
            send()
        } catch { cancel("타이밍 스윙을 취소했습니다.");fail(error.localizedDescription) }
    }
    func cancelTimingForFocusLoss() {
        if timingActive { cancel("포커스를 벗어나 타이밍 스윙을 취소했습니다.") }
    }
    func checkConnection() {
        guard !busy,!capturing else { return }
        guard let port=UInt16(port),port>0,!host.trimmingCharacters(in:.whitespaces).isEmpty else {
            fail("게임 주소와 포트(1~65535)를 확인해 주세요.");return
        }
        let host=host.trimmingCharacters(in:.whitespacesAndNewlines)
        busy=true;message="MuniGolf 연결 확인 중…";isError=false
        Task {
            defer { busy=false }
            do {
                _=try await exchange(host,port,OpenConnectMessage.heartbeat(deviceID:deviceID).encoded())
                serverReady=true;message="연결 완료 · 다음 스윙부터 페이스 타점을 확정하면 자동 전송합니다."
            } catch { serverReady=false;fail(error.localizedDescription) }
        }
    }
    private func send() {
        guard canSend,let swing=swing else { return }
        guard let port=UInt16(port),port>0,!host.trimmingCharacters(in:.whitespaces).isEmpty else {
            fail("게임 주소와 포트를 확인해 주세요.");return
        }
        do {
            guard sequence<Int.max else { throw ReplayError.input("샷 번호를 초기화해야 합니다.") }
            let next=sequence+1
            let data=try swing.message(deviceID:deviceID,number:next).encoded()
            sequence=next;defaults?.set(next,forKey:"controllerShotNumber")
            attempted=true;busy=true;isError=false;message="\(swing.club.name) · \(swing.resultLabel) 전송 중…"
            let host=host.trimmingCharacters(in:.whitespacesAndNewlines)
            Task {
                defer { busy=false }
                do {
                    _=try await exchange(host,port,data)
                    sent=true;serverReady=true;message="전송 완료 · \(swing.club.name) · \(swing.resultLabel)"
                    addHistory("#\(next) · \(swing.club.name) · \(swing.resultLabel) · 전송 완료")
                } catch {
                    serverReady=false;fail(error.localizedDescription)
                    addHistory("#\(next) · \(swing.club.name) · 응답 확인 필요")
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func addHistory(_ text: String) { history.insert(text,at:0);history=Array(history.prefix(8)) }
    private func fail(_ text: String) { isError=true;message=text }
}
