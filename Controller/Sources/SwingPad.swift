import SwiftUI
import AppKit

struct SwingPad: NSViewRepresentable {
    let enabled: Bool
    let resetToken: UUID
    let trajectory: [SwingPoint]
    let onBegin: () -> Bool
    let onUpdate: (Double) -> Void
    let onFinish: ([SwingPoint]) -> Void
    let onCancel: (String) -> Void
    func makeNSView(context: Context) -> SwingPadView { SwingPadView() }
    func updateNSView(_ view: SwingPadView, context: Context) {
        view.onBegin=onBegin;view.onUpdate=onUpdate;view.onFinish=onFinish;view.onCancel=onCancel
        if view.resetToken != resetToken {
            view.cancel(notify:false);view.resetToken=resetToken
        }
        view.inputEnabled=enabled
        if !enabled && view.active { view.cancel() }
        if !view.active { view.displayPath=trajectory }
        view.needsDisplay=true
    }
    static func dismantleNSView(_ view: SwingPadView, coordinator: ()) { view.cancel(notify:false) }
}

final class SwingPadView: NSView {
    var onBegin: (() -> Bool)?
    var onUpdate: ((Double) -> Void)?
    var onFinish: (([SwingPoint]) -> Void)?
    var onCancel: ((String) -> Void)?
    var inputEnabled=true
    var resetToken=UUID()
    private(set) var active=false
    var displayPath: [SwingPoint]=[]
    private var samples:[SwingPoint]=[]
    private var token:NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var scale: CGFloat { max(1,min(bounds.width*0.39,bounds.height*0.43)) }
    private var ball: NSPoint { NSPoint(x:bounds.midX,y:bounds.height*0.48) }
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true;layer?.cornerRadius=18;layer?.masksToBounds=true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("스윙 패드. 공에서 누르고 아래로 당긴 뒤 공 위에서 놓으세요. Escape로 취소합니다.")
        token=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.cancel() }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { if let token=token { NotificationCenter.default.removeObserver(token) } }
    override func resetCursorRects() { addCursorRect(bounds,cursor:inputEnabled ? .crosshair:.arrow) }
    private func sample(_ event:NSEvent) -> SwingPoint {
        let point=convert(event.locationInWindow,from:nil)
        return SwingPoint(x:Double((point.x-ball.x)/scale),y:Double((ball.y-point.y)/scale),time:event.timestamp)
    }
    override func mouseDown(with event:NSEvent) {
        guard inputEnabled,!active else { return }
        let point=sample(event)
        guard abs(point.x)<=0.24,abs(point.y)<=0.20 else {
            onCancel?("가운데 공에서 누르기 시작해 주세요.");return
        }
        guard onBegin?() == true else { return }
        window?.makeFirstResponder(self)
        active=true;samples=[point];displayPath=samples;needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent) {
        guard active else { return }
        let point=sample(event)
        if samples.count>=2400 || point.time-(samples.first?.time ?? point.time)>12 || abs(point.x)>5 || abs(point.y)>5 {
            cancel();return
        }
        samples.append(point);displayPath=samples
        onUpdate?((samples.first?.y ?? 0)-(samples.map(\.y).min() ?? 0))
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        guard active else { return }
        active=false;samples.append(sample(event));displayPath=samples;needsDisplay=true
        onFinish?(samples)
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode==53 { cancel() } else { super.keyDown(with:event) }
    }
    func cancel(notify:Bool=true) {
        let wasActive=active
        active=false;samples=[];displayPath=[];needsDisplay=true
        if notify && wasActive { onCancel?("스윙을 취소했습니다.") }
    }
    private func screen(_ point:SwingPoint) -> NSPoint {
        NSPoint(x:ball.x+CGFloat(point.x)*scale,y:ball.y-CGFloat(point.y)*scale)
    }
    private func text(_ text:String,x:CGFloat,y:CGFloat,size:CGFloat=11,color:NSColor=NSColor.white.withAlphaComponent(0.65),alignment:NSTextAlignment = .center,width:CGFloat=200) {
        let paragraph=NSMutableParagraphStyle();paragraph.alignment=alignment
        (text as NSString).draw(in:NSRect(x:x-width/2,y:y,width:width,height:40),withAttributes:[
            .font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:color,.paragraphStyle:paragraph])
    }
    override func draw(_ dirtyRect:NSRect) {
        let green=NSColor(calibratedRed:0.055,green:0.24,blue:0.20,alpha:1)
        green.setFill();bounds.fill()
        let white=NSColor.white
        for radius in stride(from:CGFloat(0.25),through:1.0,by:0.25) {
            let oval=NSBezierPath(ovalIn:NSRect(x:ball.x-scale*radius,y:ball.y-scale*radius,width:scale*radius*2,height:scale*radius*2))
            white.withAlphaComponent(0.055).setStroke();oval.lineWidth=1;oval.stroke()
        }
        let guide=NSBezierPath();guide.move(to:NSPoint(x:ball.x,y:35));guide.line(to:NSPoint(x:ball.x,y:bounds.height-32))
        guide.setLineDash([5,7],count:2,phase:0);guide.lineWidth=1;white.withAlphaComponent(0.18).setStroke();guide.stroke()
        let cross=NSBezierPath();cross.move(to:NSPoint(x:ball.x-scale*0.7,y:ball.y));cross.line(to:NSPoint(x:ball.x+scale*0.7,y:ball.y))
        cross.setLineDash([3,6],count:2,phase:0);white.withAlphaComponent(0.15).setStroke();cross.stroke()
        let ring=NSBezierPath(ovalIn:NSRect(x:ball.x-scale*0.14,y:ball.y-scale*0.12,width:scale*0.28,height:scale*0.24))
        NSColor(calibratedRed:0.68,green:0.90,blue:0.52,alpha:0.10).setFill();ring.fill()
        NSColor(calibratedRed:0.68,green:0.90,blue:0.52,alpha:0.70).setStroke();ring.lineWidth=1.5;ring.stroke()
        text("목표 방향 ↑",x:ball.x,y:22,size:12,color:white.withAlphaComponent(0.85))
        text("앞으로 · 얇은 타격",x:ball.x,y:43,size:11)
        text("뒤로 당기기",x:ball.x,y:bounds.height-46,size:12)
        text("힐",x:ball.x-scale*0.80,y:ball.y-8,width:55)
        text("토",x:ball.x+scale*0.80,y:ball.y-8,width:55)
        if let first=displayPath.first {
            let path=NSBezierPath();path.move(to:screen(first))
            for point in displayPath.dropFirst() { path.line(to:screen(point)) }
            NSColor(calibratedRed:0.93,green:0.78,blue:0.40,alpha:0.95).setStroke()
            path.lineWidth=3;path.lineCapStyle = .round;path.lineJoinStyle = .round;path.stroke()
            if let end=displayPath.last {
                let point=screen(end)
                let dot=NSBezierPath(ovalIn:NSRect(x:point.x-6,y:point.y-6,width:12,height:12))
                NSColor(calibratedRed:0.97,green:0.81,blue:0.39,alpha:1).setFill();dot.fill()
            }
        }
        let shadow=NSBezierPath(ovalIn:NSRect(x:ball.x-11,y:ball.y-9,width:25,height:25))
        NSColor.black.withAlphaComponent(0.22).setFill();shadow.fill()
        let sphere=NSBezierPath(ovalIn:NSRect(x:ball.x-12,y:ball.y-12,width:24,height:24))
        white.setFill();sphere.fill()
        for offset in [NSPoint(x:-4,y:-4),NSPoint(x:4,y:0),NSPoint(x:-3,y:5)] {
            NSColor.lightGray.withAlphaComponent(0.65).setFill()
            NSBezierPath(ovalIn:NSRect(x:ball.x+offset.x-1,y:ball.y+offset.y-1,width:2,height:2)).fill()
        }
        if !inputEnabled {
            NSColor.black.withAlphaComponent(0.12).setFill();bounds.fill()
            text("전송 처리 중",x:bounds.midX,y:bounds.height-70,size:13,color:white)
        }
    }
}
