import SwiftUI
import AppKit

extension TimingGrade {
    var color:Color {
        switch self {
        case .perfect:return Color(red:0.12,green:0.62,blue:0.40)
        case .excellent:return Color(red:0.10,green:0.56,blue:0.58)
        case .good:return Color(red:0.74,green:0.58,blue:0.12)
        case .fair:return .orange
        case .miss:return Color(red:0.80,green:0.25,blue:0.23)
        }
    }
}

struct TimingSwingPanel:View {
    @ObservedObject var model:ControllerModel
    var body:some View {
        VStack(alignment:.leading,spacing:11) {
            HStack {
                Text("POWER & FACE CONTACT").font(.system(size:16,weight:.semibold,design:.rounded))
                Spacer()
                Text(model.timingState.title).font(.system(size:10,weight:.bold)).foregroundStyle(controllerGreen)
                    .padding(.horizontal,9).padding(.vertical,5).background(controllerGreen.opacity(0.06),in:Capsule())
            }
            Text("1 · 강도 1~110% 확정   →   2 · 힘이 클수록 빨라지는 페이스 타점 바").font(.system(size:11)).foregroundStyle(controllerMuted)
            TimingBar(model:model).frame(minHeight:300,maxHeight:.infinity)
            HStack(spacing:12) {
                Button {
                    if let event=NSApp.currentEvent,
                       (event.type == .leftMouseDown || event.type == .leftMouseUp),event.clickCount>1 { return }
                    if model.timingActive { model.timingSpace(at:NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime) }
                    else { _=model.startTiming() }
                } label: {
                    Text(model.timingState == .settingPower ? "강도 확정 · 클릭":model.timingActive ? "타점 확정 · 클릭":"START · Enter")
                        .font(.system(size:13,weight:.semibold)).frame(minWidth:165).padding(.vertical,6)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:[])
                    .disabled(model.busy)
                Spacer(minLength:3)
                Toggle("좌우 시작 방향 랜덤",isOn:$model.randomTimingDirection).font(.system(size:10))
                    .toggleStyle(.switch).controlSize(.small).disabled(model.busy || model.timingActive)
                Button { model.cancel("타이밍 스윙을 취소했습니다.") } label: { Image(systemName:"arrow.counterclockwise") }
                    .disabled(model.busy).help("타이밍 초기화 · Esc")
            }
            Text("Space 또는 바 클릭으로 멈추기 · 입력 전까지 계속 왕복 · Esc 취소")
                .font(.system(size:10)).foregroundStyle(controllerMuted).fixedSize(horizontal:false,vertical:true)
            if let first=model.history.first { Text(first).font(.system(size:10)).foregroundStyle(controllerMuted).lineLimit(1) }
        }.padding(15).background(.white,in:RoundedRectangle(cornerRadius:13))
    }
}

struct TimingBar:NSViewRepresentable {
    @ObservedObject var model:ControllerModel
    func makeNSView(context:Context)->TimingBarView { TimingBarView() }
    func updateNSView(_ view:TimingBarView,context:Context) {
        view.power=model.timingPower;view.session=model.timingSession;view.judgement=model.timingResult
        view.powerSession=model.powerSession
        view.state=model.timingState;view.blocked=model.busy
        view.onSpace={ model.timingSpace(at:$0) }
        view.onStart={ _=model.startTiming() }
        view.onCancel={ model.cancel("타이밍 스윙을 취소했습니다.") }
        view.configure();view.needsDisplay=true
    }
    static func dismantleNSView(_ view:TimingBarView,coordinator:()) { view.stopTimer() }
}

final class TimingBarView:NSView {
    var power:TimingPower = .p70
    var session:TimingSession?
    var powerSession:PowerMeterSession?
    var judgement:TimingJudgement?
    var state:TimingState = .ready
    var blocked=false
    var onSpace:((Double)->Void)?
    var onStart:(()->Void)?
    var onCancel:(()->Void)?
    private var timer:Timer?
    private var focusedSession:UUID?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true;layer?.cornerRadius=18;layer?.masksToBounds=true
        setAccessibilityElement(true);setAccessibilityRole(.group)
        setAccessibilityLabel("강도와 페이스 타점 바. 시작 후 Space 또는 클릭으로 먼저 강도를 정하고, 다시 Space 또는 클릭으로 힐·중앙·토 타점을 정합니다.")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unavailable") }
    deinit { timer?.invalidate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();configure() }
    func configure() {
        let activeID=state == .settingPower ? powerSession?.id:state == .running ? session?.id:nil
        if let activeID=activeID,window != nil {
            if timer==nil {
                let timer=Timer(timeInterval:1/120,repeats:true) { [weak self] _ in self?.needsDisplay=true }
                RunLoop.main.add(timer,forMode:.common);self.timer=timer
            }
            if focusedSession != activeID { focusedSession=activeID;window?.makeFirstResponder(self) }
        } else { stopTimer() }
    }
    func stopTimer() { timer?.invalidate();timer=nil }
    override func mouseDown(with event:NSEvent) {
        guard !blocked,event.clickCount<=1,event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return }
        window?.makeFirstResponder(self);onSpace?(event.timestamp)
    }
    override func keyDown(with event:NSEvent) {
        guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty else {
            super.keyDown(with:event);return
        }
        if event.keyCode==49 {
            if !event.isARepeat && !blocked { onSpace?(event.timestamp) }
            return
        }
        if event.keyCode==36 || event.keyCode==76 {
            if !event.isARepeat && !blocked && state != .running && state != .settingPower { onStart?() }
            return
        }
        if event.keyCode==53 { if !blocked { onCancel?() };return }
        super.keyDown(with:event)
    }
    private func text(_ text:String,rect:NSRect,size:CGFloat=11,weight:NSFont.Weight = .medium,color:NSColor = .white,alignment:NSTextAlignment = .center) {
        let paragraph=NSMutableParagraphStyle();paragraph.alignment=alignment
        (text as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color,.paragraphStyle:paragraph])
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedRed:0.045,green:0.22,blue:0.18,alpha:1).setFill();bounds.fill()
        let width=bounds.width,height=bounds.height
        let now=ProcessInfo.processInfo.systemUptime
        let powerValue=state == .settingPower ? (powerSession?.fraction(at:now) ?? TimingPower.minimumFraction):power.fraction
        let powerPosition=PowerMeterSession.position(for:powerValue)
        let activePower=state == .settingPower ? (TimingPower(fraction:powerValue) ?? power):(session?.power ?? power)
        let faded=NSColor.white.withAlphaComponent(0.58)
        let powerTitle=state == .settingPower ? "1 · SHOT POWER":state == .ready || state == .cancelled ? "SHOT POWER · READY":"SHOT POWER LOCKED"
        text(powerTitle+(powerValue>1 ? " · OVER SWING":""),rect:NSRect(x:0,y:16,width:width,height:15),size:10,color:faded)
        text(String(format:"%.1f%%",powerValue*100),rect:NSRect(x:0,y:34,width:width,height:44),size:35,weight:.semibold,color:powerValue>1 ? .systemOrange:.white)
        let powerBar=NSRect(x:32,y:max(93,height*0.30),width:max(1,width-64),height:19)
        NSColor.white.withAlphaComponent(0.1).setFill();NSBezierPath(roundedRect:powerBar,xRadius:9,yRadius:9).fill()
        let hundred=powerBar.minX+powerBar.width*CGFloat(PowerMeterSession.position(for:1))
        NSColor.systemOrange.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect:NSRect(x:hundred,y:powerBar.minY,width:powerBar.maxX-hundred,height:powerBar.height)).fill()
        NSColor(calibratedRed:0.90,green:0.74,blue:0.34,alpha:0.6).setFill()
        NSBezierPath(roundedRect:NSRect(x:powerBar.minX,y:powerBar.minY,width:powerBar.width*CGFloat(powerPosition),height:powerBar.height),xRadius:9,yRadius:9).fill()
        NSColor.white.setFill();NSBezierPath(ovalIn:NSRect(x:powerBar.minX+powerBar.width*CGFloat(powerPosition)-5,y:powerBar.midY-5,width:10,height:10)).fill()
        let tick=NSBezierPath();tick.move(to:NSPoint(x:hundred,y:powerBar.minY-4));tick.line(to:NSPoint(x:hundred,y:powerBar.maxY+4))
        NSColor.systemOrange.setStroke();tick.lineWidth=1;tick.stroke()
        text("100%",rect:NSRect(x:hundred-24,y:powerBar.minY-18,width:48,height:14),size:9,color:.systemOrange)
        text("1%",rect:NSRect(x:powerBar.minX,y:powerBar.maxY+8,width:50,height:14),size:9,color:faded,alignment:.left)
        text("110%",rect:NSRect(x:powerBar.maxX-50,y:powerBar.maxY+8,width:50,height:14),size:9,color:faded,alignment:.right)
        let bar=NSRect(x:32,y:max(178,height*0.64),width:max(1,width-64),height:24)
        text("2 · FACE CONTACT",rect:NSRect(x:bar.minX,y:bar.minY-25,width:140,height:15),size:9,color:faded,alignment:.left)
        text("SWEET SPOT",rect:NSRect(x:bar.midX-75,y:bar.minY-25,width:150,height:16),size:10,color:NSColor(calibratedRed:0.78,green:0.93,blue:0.62,alpha:1))
        NSColor.white.withAlphaComponent(0.09).setFill();NSBezierPath(roundedRect:bar,xRadius:12,yRadius:12).fill()
        for (radius,alpha) in [(0.20,0.10),(0.10,0.18),(0.05,0.28),(0.02,0.95)] {
            NSColor(calibratedRed:0.55,green:0.85,blue:0.48,alpha:alpha).setFill()
            NSBezierPath(rect:NSRect(x:bar.minX+bar.width*CGFloat(0.5-radius),y:bar.minY,width:bar.width*CGFloat(radius*2),height:bar.height)).fill()
        }
        let center=NSBezierPath();center.move(to:NSPoint(x:bar.midX,y:bar.minY-9));center.line(to:NSPoint(x:bar.midX,y:bar.maxY+9))
        NSColor.white.withAlphaComponent(0.9).setStroke();center.lineWidth=1.4;center.stroke()
        let direction=judgement?.direction ?? session?.direction(at:now) ?? .leftToRight
        let position:Double
        if let judgement=judgement { position=judgement.position }
        else if state == .running { position=session?.position(at:now) ?? 0.5 }
        else { position=0.5 }
        let x=bar.minX+bar.width*CGFloat(controllerClamp(position,0,1))
        let markerColor=judgement.map{NSColor($0.grade.color)} ?? (state == .settingPower ? NSColor.gray:NSColor.white)
        markerColor.setFill()
        NSBezierPath(roundedRect:NSRect(x:x-2,y:bar.minY-12,width:4,height:bar.height+24),xRadius:2,yRadius:2).fill()
        NSBezierPath(ovalIn:NSRect(x:x-7,y:bar.midY-7,width:14,height:14)).fill()
        text("HEEL · 힐",rect:NSRect(x:bar.minX-8,y:bar.maxY+12,width:100,height:15),size:9,color:faded,alignment:.left)
        text("TOE · 토",rect:NSRect(x:bar.maxX-92,y:bar.maxY+12,width:100,height:15),size:9,color:faded,alignment:.right)
        let target=judgement.map { "\($0.grade.title) · \($0.sideLabel)" } ?? "중앙 = 페이스 스위트스폿"
        text(target,rect:NSRect(x:75,y:bar.maxY+12,width:width-150,height:19),size:10,weight:.semibold,color:markerColor)
        text("극힐 → 슬라이스",rect:NSRect(x:bar.minX-8,y:bar.maxY+29,width:140,height:14),size:8,color:faded,alignment:.left)
        text("극토 → 훅",rect:NSRect(x:bar.maxX-132,y:bar.maxY+29,width:140,height:14),size:8,color:faded,alignment:.right)
        let third=width/3,y=height-39
        for (index,heading,value) in [(0,"FACE BAR SPEED","\(String(format:"%.2f",activePower.speed))×"),
                                       (1,"STOP INPUT","SPACE / CLICK"),(2,"MOVEMENT",state == .running ? (direction == .leftToRight ? "→":"←"):"↔")] {
            let origin=CGFloat(index)*third
            text(heading,rect:NSRect(x:origin,y:y,width:third,height:14),size:8,color:faded)
            text(value,rect:NSRect(x:origin,y:y+14,width:third,height:21),size:11,weight:.semibold)
        }
    }
}
