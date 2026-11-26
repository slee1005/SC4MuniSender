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
    @Published var gameMode = false
    @Published var serverReady = false
    @Published var busy = false
    @Published var capturing = false
    @Published var livePower = 0.0
    @Published var swing: ControllerSwing?
    @Published var attempted = false
    @Published var sent = false
    @Published var message = "연습 모드입니다."
    @Published var isError = false
    @Published var resetToken = UUID()
    @Published var history: [String] = []
    @Published var inputMode:ControllerInputMode = .timing {
        didSet { resetSwing();defaults?.set(inputMode.rawValue,forKey:"controllerInputMode") }
    }
    @Published var timingPower:TimingPower = .p70 {
        didSet { resetSwing();defaults?.set(timingPower.rawValue,forKey:"controllerTimingPower") }
    }
    @Published var randomTimingDirection=true {
        didSet { defaults?.set(randomTimingDirection,forKey:"controllerRandomTimingDirection") }
    }
    @Published var timingSession:TimingSession?
    @Published var timingResult:TimingJudgement?
    @Published var timingState:TimingState = .ready
    var timingActive:Bool { capturing && timingState == .running && timingSession != nil }
    private var timingExpiryTask:Task<Void,Never>?
    private var timingClub:ControllerClub?
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
        timingPower=TimingPower(rawValue:prefs?.integer(forKey:"controllerTimingPower") ?? 70) ?? .p70
        randomTimingDirection=prefs?.object(forKey:"controllerRandomTimingDirection") as? Bool ?? true
        loadFields()
        livePower=inputMode == .timing ? timingPower.fraction:0
        message = "연습 모드입니다. 파워를 고르고 START로 시작한 뒤 중앙에서 SPACE를 누르세요."
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
    var canSend: Bool { !busy && !capturing && !attempted && swing?.canSend == true }
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
        serverReady=false;gameMode=false
        defaults?.set(host,forKey:"gameHost");defaults?.set(port,forKey:"gamePort")
    }
    func resetSwing() {
        timingExpiryTask?.cancel();timingExpiryTask=nil
        timingSession=nil;timingResult=nil;timingState = .ready;timingClub=nil
        resetToken=UUID();capturing=false;captureClub=nil;livePower=0
        swing=nil;attempted=false;sent=false
    }
    func begin() -> Bool {
        guard inputMode == .pad,!busy,!capturing else { return false }
        do {
            let club=try configuredClub()
            if let index=clubs.firstIndex(where:{$0.id==club.id}) { clubs[index]=club };persist()
            captureClub=club;captureAim=aim;captureFace=faceBias;captureSensitivity=sensitivity
            capturing=true;livePower=0;swing=nil;attempted=false;sent=false;isError=false
            message="뒤로 당겨 스윙 크기를 정한 뒤, 공 쪽으로 밀고 공 위에서 놓으세요."
            return true
        } catch {
            swing=nil;attempted=false;sent=false;livePower=0
            fail(error.localizedDescription);return false
        }
    }
    func update(depth: Double) { livePower=controllerClamp(depth/0.85*captureSensitivity,0,1.15) }
    func cancel(_ reason: String) {
        timingExpiryTask?.cancel();timingExpiryTask=nil;timingSession=nil;timingResult=nil;timingState = .cancelled;timingClub=nil
        capturing=false;captureClub=nil;livePower=0;swing=nil;attempted=false;sent=false
        message=reason;isError=false
    }
    func finish(_ points: [SwingPoint]) {
        guard inputMode == .pad,capturing,let club=captureClub else { return }
        capturing=false;captureClub=nil
        do {
            let result=try ControllerSwingEngine.analyze(points,club:club,aim:captureAim,faceBias:captureFace,sensitivity:captureSensitivity)
            swing=result;livePower=result.power;attempted=false;sent=false;isError=false
            message=result.contact.note
            if !result.canSend { addHistory("\(result.club.name) · 헛스윙 · 전송 안 함") }
            else if gameMode && serverReady { send() }
        } catch { livePower=0;fail(error.localizedDescription) }
    }
    func example(_ contact: SwingContact) {
        guard !busy,!capturing else { return }
        inputMode = .pad
        gameMode=false;resetToken=UUID()
        if begin() { finish(ControllerSwingEngine.example(contact)) }
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
            let chosen=direction ?? (randomTimingDirection && Bool.random() ? .rightToLeft:.leftToRight)
            let session=TimingSession(id:UUID(),power:timingPower,direction:chosen,startedAt:time)
            timingSession=session;timingState = .running;capturing=true;livePower=timingPower.fraction
            isError=false;message="중앙 임팩트 지점에서 SPACE를 누르세요. · \(chosen.title)"
            timingExpiryTask=Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let remaining=session.endsAt-ProcessInfo.processInfo.systemUptime
                        if remaining<=0 { self?.expireTiming(sessionID:session.id,at:ProcessInfo.processInfo.systemUptime);return }
                        try await Task.sleep(nanoseconds:UInt64(min(remaining,10)*1_000_000_000)+1)
                    }
                } catch { return }
            }
            return true
        } catch { resetSwing();fail(error.localizedDescription);return false }
    }
    func timingSpace(at time:Double=ProcessInfo.processInfo.systemUptime) {
        guard inputMode == .timing,!busy else { return }
        if timingActive { hitTiming(at:time) }
        else if timingState == .expired,let session=timingSession,time>=session.startedAt,time<=session.endsAt {
            // An event queued before the deadline remains valid even if the UI
            // processed its timeout first. Judge the event's actual timestamp.
            hitTiming(at:time)
        } else { _=startTiming() }
    }
    func hitTiming(at time:Double=ProcessInfo.processInfo.systemUptime) {
        guard let session=timingSession,let club=timingClub,
              timingActive || (timingState == .expired && time>=session.startedAt && time<=session.endsAt) else { return }
        if time>session.endsAt { expireTiming(sessionID:session.id,at:time);return }
        do {
            let judgement=try session.judge(at:time)
            let result=TimingSwingEngine.shot(judgement,club:club,aim:captureAim,faceBias:captureFace)
            _=try result.message(deviceID:deviceID,number:1).encoded()
            if timingState == .expired,history.first == "\(club.name) · 타이밍 시간 초과 · 전송 안 함" { history.removeFirst() }
            timingExpiryTask?.cancel();timingExpiryTask=nil
            capturing=false;captureClub=nil;timingState = .hit;timingResult=judgement
            swing=result;livePower=judgement.power.fraction;attempted=false;sent=false;isError=false
            message=String(format:"%@ · 중앙 오차 %.1f%% · %@",judgement.grade.title,judgement.error*100,judgement.sideLabel)
            if gameMode && serverReady { send() }
        } catch { cancel("타이밍 스윙을 취소했습니다.");fail(error.localizedDescription) }
    }
    func expireTiming(sessionID:UUID,at time:Double) {
        guard timingActive,let session=timingSession,session.id==sessionID,time>=session.endsAt else { return }
        timingExpiryTask?.cancel();timingExpiryTask=nil
        capturing=false;captureClub=nil;timingState = .expired;swing=nil;timingResult=nil
        attempted=false;sent=false;isError=false
        message="Miss · 끝까지 SPACE를 누르지 않았습니다. 헛스윙으로 처리하며 샷을 전송하지 않습니다."
        addHistory("\(selectedClub.name) · 타이밍 시간 초과 · 전송 안 함")
    }
    func cancelTimingForFocusLoss() {
        if timingActive { cancel("포커스를 벗어나 타이밍 스윙을 취소했습니다.") }
    }
    func setGameMode(_ enabled: Bool) {
        guard !busy,!capturing else { return }
        if enabled && !serverReady { fail("먼저 ‘연결 확인’을 눌러 주세요.");return }
        gameMode=enabled;isError=false
            message=enabled ? "게임 모드 · 다음 스윙부터 타격하면 자동 전송합니다." : "연습 모드 · 스윙을 해도 게임에 자동 전송하지 않습니다."
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
                serverReady=true;message="서버 응답을 확인했습니다. 게임 모드에서 스윙하거나 이번 스윙을 직접 전송하세요."
            } catch { serverReady=false;gameMode=false;fail(error.localizedDescription) }
        }
    }
    func send() {
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
                    serverReady=false;gameMode=false;fail(error.localizedDescription)
                    addHistory("#\(next) · \(swing.club.name) · 응답 확인 필요")
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func addHistory(_ text: String) { history.insert(text,at:0);history=Array(history.prefix(8)) }
    private func fail(_ text: String) { isError=true;message=text }
}
