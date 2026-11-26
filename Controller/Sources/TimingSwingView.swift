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
                Text("GOLF SWING TIMING").font(.system(size:16,weight:.semibold,design:.rounded))
                Spacer()
                Text(model.timingState.title).font(.system(size:10,weight:.bold)).foregroundStyle(controllerGreen)
                    .padding(.horizontal,9).padding(.vertical,5).background(controllerGreen.opacity(0.06),in:Capsule())
            }
            HStack(spacing:7) {
                ForEach(TimingPower.allCases) { power in
                    Button { model.timingPower=power } label: {
                        VStack(spacing:2) {
                            Text("\(power.rawValue)%").font(.system(size:19,weight:.semibold,design:.rounded))
                            Text("\(String(format:"%.2g",power.speed))× · \(power.difficulty)").font(.system(size:9))
                        }.frame(maxWidth:.infinity).padding(.vertical,7)
                            .foregroundStyle(model.timingPower==power ? Color.white:controllerGreen)
                            .background(model.timingPower==power ? controllerGreen:controllerGreen.opacity(0.05),in:RoundedRectangle(cornerRadius:9))
                    }.buttonStyle(.plain).accessibilityLabel("스윙 파워 \(power.rawValue)퍼센트")
                }
            }.disabled(model.busy || model.timingActive)
            TimingBar(model:model).frame(minHeight:245,maxHeight:.infinity)
            HStack(spacing:12) {
                Button {
                    _=model.startTiming()
                } label: {
                    Text(model.timingActive ? "SPACE로 타격":"START · Enter")
                        .font(.system(size:13,weight:.semibold)).frame(minWidth:165).padding(.vertical,6)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:[])
                    .disabled(model.busy || model.timingActive)
                Spacer(minLength:3)
                Toggle("좌우 시작 방향 랜덤",isOn:$model.randomTimingDirection).font(.system(size:10))
                    .toggleStyle(.switch).controlSize(.small).disabled(model.busy || model.timingActive)
                Button { model.cancel("타이밍 스윙을 취소했습니다.") } label: { Image(systemName:"arrow.counterclockwise") }
                    .disabled(model.busy).help("타이밍 초기화 · Esc")
            }
            Text("중앙에 도달하는 순간 SPACE · Esc 취소 · 판정 오차는 바 전체 너비 기준")
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
        setAccessibilityLabel("골프 타이밍 바. START 또는 Enter로 시작하고, 중앙에서 스페이스바를 누르세요. Esc로 취소합니다.")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unavailable") }
    deinit { timer?.invalidate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();configure() }
    func configure() {
        if state == .running,let session=session,window != nil {
            if timer==nil {
                let timer=Timer(timeInterval:1/120,repeats:true) { [weak self] _ in self?.needsDisplay=true }
                RunLoop.main.add(timer,forMode:.common);self.timer=timer
            }
            if focusedSession != session.id { focusedSession=session.id;window?.makeFirstResponder(self) }
        } else { stopTimer() }
    }
    func stopTimer() { timer?.invalidate();timer=nil }
    override func mouseDown(with event:NSEvent) { if !blocked { window?.makeFirstResponder(self) } }
    override func keyDown(with event:NSEvent) {
        guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty else {
            super.keyDown(with:event);return
        }
        if event.keyCode==49 {
            if !event.isARepeat && !blocked { onSpace?(event.timestamp) }
            return
        }
        if event.keyCode==36 || event.keyCode==76 {
            if !event.isARepeat && !blocked && state != .running { onStart?() }
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
        let activePower=session?.power ?? power
        let faded=NSColor.white.withAlphaComponent(0.58)
        text("SWING POWER",rect:NSRect(x:0,y:17,width:width,height:15),size:10,color:faded)
        text("\(activePower.rawValue)%",rect:NSRect(x:0,y:33,width:width,height:53),size:43,weight:.semibold)
        let bar=NSRect(x:32,y:max(114,height*0.48),width:max(1,width-64),height:24)
        text("TIMING BAR",rect:NSRect(x:bar.minX,y:bar.minY-26,width:110,height:15),size:9,color:faded,alignment:.left)
        text("IMPACT ZONE",rect:NSRect(x:bar.midX-80,y:bar.minY-26,width:160,height:16),size:10,color:NSColor(calibratedRed:0.78,green:0.93,blue:0.62,alpha:1))
        NSColor.white.withAlphaComponent(0.09).setFill();NSBezierPath(roundedRect:bar,xRadius:12,yRadius:12).fill()
        for (radius,alpha) in [(0.20,0.10),(0.10,0.18),(0.05,0.28),(0.02,0.95)] {
            NSColor(calibratedRed:0.55,green:0.85,blue:0.48,alpha:alpha).setFill()
            NSBezierPath(rect:NSRect(x:bar.minX+bar.width*CGFloat(0.5-radius),y:bar.minY,width:bar.width*CGFloat(radius*2),height:bar.height)).fill()
        }
        let center=NSBezierPath();center.move(to:NSPoint(x:bar.midX,y:bar.minY-9));center.line(to:NSPoint(x:bar.midX,y:bar.maxY+9))
        NSColor.white.withAlphaComponent(0.9).setStroke();center.lineWidth=1.4;center.stroke()
        let direction=session?.direction ?? .leftToRight
        let position:Double
        if let judgement=judgement { position=judgement.position }
        else if state == .running { position=session?.position(at:ProcessInfo.processInfo.systemUptime) ?? 0 }
        else if state == .expired { position=direction.endPosition }
        else { position=direction.startPosition }
        let x=bar.minX+bar.width*CGFloat(controllerClamp(position,0,1))
        let markerColor=judgement.map{NSColor($0.grade.color)} ?? (state == .expired ? NSColor.systemRed:NSColor.white)
        markerColor.setFill()
        NSBezierPath(roundedRect:NSRect(x:x-2,y:bar.minY-12,width:4,height:bar.height+24),xRadius:2,yRadius:2).fill()
        NSBezierPath(ovalIn:NSRect(x:x-7,y:bar.midY-7,width:14,height:14)).fill()
        text(direction == .leftToRight ? "START":"END",rect:NSRect(x:bar.minX-8,y:bar.maxY+16,width:70,height:15),size:9,color:faded,alignment:.left)
        text(direction == .leftToRight ? "END":"START",rect:NSRect(x:bar.maxX-62,y:bar.maxY+16,width:70,height:15),size:9,color:faded,alignment:.right)
        let target=judgement.map { "\($0.grade.title.uppercased()) · \($0.sideLabel)" } ?? (state == .expired ? "MISS · 시간 초과":"TARGET: CENTER")
        text(target,rect:NSRect(x:60,y:bar.maxY+16,width:width-120,height:20),size:11,weight:.semibold,color:markerColor)
        let third=width/3,y=height-48
        for (index,heading,value) in [(0,"SWING SPEED","\(activePower.speedLabel) · \(String(format:"%.2g",activePower.speed))×"),
                                       (1,"HIT KEY","SPACE"),(2,"DIRECTION",direction == .leftToRight ? "→":"←")] {
            let origin=CGFloat(index)*third
            text(heading,rect:NSRect(x:origin,y:y,width:third,height:14),size:8,color:faded)
            text(value,rect:NSRect(x:origin,y:y+16,width:third,height:21),size:index==1 ? 17:12,weight:.semibold)
        }
    }
}
