import SwiftUI
import AppKit

let controllerGreen = Color(red:0.055,green:0.29,blue:0.23)
let controllerMuted = Color(red:0.43,green:0.49,blue:0.46)

@main @MainActor struct MuniControllerMain {
    static func main() {
        let app=NSApplication.shared
        let previewIndex=CommandLine.arguments.firstIndex(of:"--render-preview")
        let delegate=ControllerDelegate(preview:previewIndex != nil)
        app.delegate=delegate
        app.setActivationPolicy(previewIndex == nil ? .regular:.accessory)
        if let index=previewIndex,index+1<CommandLine.arguments.count {
            delegate.makeWindow(show:false)
            RunLoop.main.run(until:Date().addingTimeInterval(0.35))
            guard delegate.verifyPad() else { exit(1) }
            delegate.model.inputMode = .timing
            delegate.model.resetSwing()
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            guard delegate.verifyTiming() else { exit(1) }
            delegate.model.timingPower = .p70
            delegate.model.resetSwing()
            delegate.model.randomTimingDirection=true
            delegate.model.message="START → Space/클릭으로 강도 확정 → Space/클릭으로 페이스 타점 확정"
            if CommandLine.arguments.contains("--preview-stinger") { delegate.model.shotType = .stinger;delegate.model.attackStyle = .down }
            if CommandLine.arguments.contains("--preview-result"),delegate.model.startTiming(direction:.leftToRight),let power=delegate.model.powerSession {
                let target=CommandLine.arguments.contains("--preview-over") ? TimingPower.maximumFraction:0.7
                delegate.model.timingSpace(at:power.startedAt+PowerMeterSession.duration*PowerMeterSession.position(for:target))
                if let session=delegate.model.timingSession { delegate.model.hitTiming(at:session.startedAt+session.duration*0.5) }
            }
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            if let view=delegate.window?.contentView,
               let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.layoutSubtreeIfNeeded();view.cacheDisplay(in:view.bounds,to:bitmap)
                if let png=bitmap.representation(using:.png,properties:[:]) {
                    do { try png.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Rendered controller preview");exit(0) }
                    catch { fputs("Preview write failed: \(error)\n",stderr) }
                }
            }
            exit(1)
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class ControllerDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow?
    let model:ControllerModel
    init(preview:Bool) { model=ControllerModel(preview:preview);super.init() }
    func applicationDidFinishLaunching(_ notification:Notification) { makeMenu();makeWindow(show:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationDidResignActive(_ notification:Notification) { model.cancelTimingForFocusLoss() }
    func makeWindow(show:Bool) {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1360,height:870),
                            styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Muni Controller";window.minSize=NSSize(width:1180,height:810)
        window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:ControllerView(model:model).preferredColorScheme(.light))
        window.center();self.window=window
        if show { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    }
    func verifyPad()->Bool {
        func find(_ view:NSView)->SwingPadView? {
            if let pad=view as? SwingPadView { return pad }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let window=window,let root=window.contentView,let pad=find(root) else {
            fputs("Native swing pad was not found\n",stderr);return false
        }
        model.resetSwing()
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        let scale=min(pad.bounds.width*0.39,pad.bounds.height*0.43)
        func event(_ type:NSEvent.EventType,_ x:Double,_ y:Double,_ time:Double)->NSEvent {
            let local=NSPoint(x:pad.bounds.midX+CGFloat(x)*scale,y:pad.bounds.height*0.48-CGFloat(y)*scale)
            return NSEvent.mouseEvent(with:type,location:pad.convert(local,to:nil),modifierFlags:[],timestamp:time,
                                     windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0.5)!
        }
        pad.mouseDown(with:event(.leftMouseDown,0,0,1))
        guard model.capturing else { fputs("Native press did not begin capture\n",stderr);return false }
        pad.mouseDragged(with:event(.leftMouseDragged,0,-0.36,1.2))
        pad.mouseDragged(with:event(.leftMouseDragged,0,-0.72,1.5))
        pad.mouseDragged(with:event(.leftMouseDragged,0,-0.30,1.6))
        pad.mouseDragged(with:event(.leftMouseDragged,0,-0.08,1.67))
        pad.mouseUp(with:event(.leftMouseUp,0,0,1.7))
        guard !model.capturing,model.swing?.contact == .center,model.swing?.canSend == true,!model.attempted else {
            fputs("Native drag/release did not produce a practice shot\n",stderr);return false
        }
        let id=model.swing?.id
        pad.mouseUp(with:event(.leftMouseUp,0,0,1.71))
        guard model.swing?.id==id else { fputs("Duplicate release created another swing\n",stderr);return false }
        pad.mouseDown(with:event(.leftMouseDown,0,0,2))
        guard model.capturing else { return false }
        guard let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:2.1,
                windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) else { return false }
        pad.keyDown(with:escape)
        guard !model.capturing else { fputs("Escape failed to cancel capture\n",stderr);return false }
        print("PASS: native AppKit press/drag/release, duplicate release guard and Escape cancellation; practice only")
        return true
    }
    func verifyTiming()->Bool {
        func find(_ view:NSView)->TimingBarView? {
            if let bar=view as? TimingBarView { return bar }
            return view.subviews.lazy.compactMap{find($0)}.first
        }
        guard let window=window,let root=window.contentView,let bar=find(root) else {
            fputs("Native timing bar was not found\n",stderr);return false
        }
        model.timingPower = .p70
        guard model.startTiming(direction:.leftToRight),let power=model.powerSession else { return false }
        RunLoop.main.run(until:Date().addingTimeInterval(0.04))
        guard window.firstResponder === bar else { fputs("Timing keyboard focus was not acquired\n",stderr);return false }
        func key(_ code:UInt16,_ timestamp:Double,_ repeated:Bool=false)->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:timestamp,windowNumber:window.windowNumber,
                context:nil,characters:code==49 ? " ":"\u{1b}",charactersIgnoringModifiers:code==49 ? " ":"\u{1b}",isARepeat:repeated,keyCode:code)!
        }
        bar.keyDown(with:key(49,power.startedAt+PowerMeterSession.duration*0.7))
        guard let first=model.timingSession,model.timingState == .running,abs(model.timingPower.fraction-0.773)<0.001 else { return false }
        bar.keyDown(with:key(49,first.startedAt+0.01,true))
        guard model.timingState == .running,model.swing==nil else { return false }
        let click=NSEvent.mouseEvent(with:.leftMouseDown,location:bar.convert(NSPoint(x:bar.bounds.midX,y:bar.bounds.midY),to:nil),modifierFlags:[],timestamp:first.startedAt+first.duration*0.5,
            windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0.5)!
        bar.mouseDown(with:click)
        guard model.timingResult?.grade == .perfect,!model.capturing,model.swing?.canSend == true,!model.attempted else {
            fputs("Space was not judged at the keyboard event timestamp\n",stderr);return false
        }
        let id=model.swing?.id
        bar.keyDown(with:key(49,first.startedAt+first.duration*0.5+0.01,true))
        guard model.swing?.id==id,!model.capturing else { fputs("Held Space created another round\n",stderr);return false }
        let doubleClick=NSEvent.mouseEvent(with:.leftMouseDown,location:click.locationInWindow,modifierFlags:[],timestamp:click.timestamp+0.02,
            windowNumber:window.windowNumber,context:nil,eventNumber:3,clickCount:2,pressure:0.5)!
        bar.mouseDown(with:doubleClick)
        guard model.swing?.id==id,!model.capturing else { return false }
        guard model.startTiming(direction:.rightToLeft),let second=model.powerSession else { return false }
        let powerClick=NSEvent.mouseEvent(with:.leftMouseDown,location:click.locationInWindow,modifierFlags:[],timestamp:second.startedAt+PowerMeterSession.duration*0.5,
            windowNumber:window.windowNumber,context:nil,eventNumber:4,clickCount:1,pressure:0.5)!
        bar.mouseDown(with:powerClick)
        guard let returning=model.timingSession,abs(returning.power.fraction-0.555)<0.001 else { return false }
        bar.keyDown(with:key(49,returning.startedAt+returning.duration*1.5))
        guard model.timingResult?.grade == .perfect,!model.capturing else { return false }
        guard model.startTiming(),let third=model.powerSession else { return false }
        RunLoop.main.run(until:Date().addingTimeInterval(0.04))
        bar.keyDown(with:key(53,third.startedAt+0.05))
        guard !model.capturing,model.swing==nil,model.timingSession==nil else { fputs("Timing Escape did not cancel\n",stderr);return false }
        print("PASS: native two-stage keyboard/click flow, captured power, repeat/double-click suppression and Escape; practice only")
        return true
    }
    private func makeMenu() {
        let menu=NSMenu();let appItem=NSMenuItem();let appMenu=NSMenu()
        appMenu.addItem(withTitle:"Muni Controller 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu;menu.addItem(appItem)
        let edit=NSMenuItem();edit.title="편집";let editMenu=NSMenu(title:"편집")
        for (title,action,key) in [("실행 취소","undo:","z"),("잘라내기","cut:","x"),("복사","copy:","c"),("붙여넣기","paste:","v"),("전체 선택","selectAll:","a")] {
            editMenu.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)
        }
        edit.submenu=editMenu;menu.addItem(edit);NSApp.mainMenu=menu
    }
}

struct ControllerView:View {
    @ObservedObject var model:ControllerModel
    private var locked:Bool { model.busy || model.capturing }
    var body:some View {
        VStack(spacing:12) {
            header
            connection
            HStack(alignment:.top,spacing:12) {
                clubPanel.frame(width:235)
                VStack(spacing:9) {
                    Picker("스윙 조작",selection:$model.inputMode) {
                        ForEach(ControllerInputMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented).disabled(locked)
                    shotControls
                    if model.inputMode == .timing { TimingSwingPanel(model:model) }
                    else { padPanel }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                resultPanel.frame(width:292)
            }
            HStack(alignment:.center,spacing:10) {
                Image(systemName:model.isError ? "exclamationmark.circle.fill":"info.circle")
                    .foregroundStyle(model.isError ? Color.orange:controllerGreen)
                Text(model.message).font(.system(size:12)).foregroundStyle(model.isError ? Color.orange:controllerGreen)
                    .frame(maxWidth:.infinity,alignment:.leading).lineLimit(2)
                Text("Muni Controller 1.2.2").font(.system(size:10)).foregroundStyle(controllerMuted)
            }.frame(height:34)
        }
        .padding(20).tint(controllerGreen)
        .background(Color(red:0.95,green:0.97,blue:0.95))
        .frame(minWidth:1180,minHeight:780)
    }
    private var header:some View {
        HStack(spacing:12) {
            Image(systemName:"figure.golf").font(.system(size:27)).foregroundStyle(.white)
                .frame(width:48,height:48).background(controllerGreen,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:3) {
                Text("Muni Controller").font(.system(size:26,weight:.semibold,design:.rounded)).foregroundStyle(controllerGreen)
                Text(model.inputMode == .timing ? "강도 바 정지 · 페이스 타점 정지 · Space / 클릭":"당기고 · 밀고 · 공 위에서 놓기").font(.system(size:12)).foregroundStyle(controllerMuted)
            }
            Spacer()
            Picker("거리 단위",selection:$model.distanceUnit) {
                Text("야드 yd").tag(DistanceDisplayUnit.yards)
                Text("미터 m").tag(DistanceDisplayUnit.meters)
            }.pickerStyle(.segmented).frame(width:180).disabled(locked)
            Text(model.inputMode == .timing ? "오른손 기준 · Power & Timing":"오른손 기준 · 트랙패드 / 마우스").font(.system(size:11,weight:.medium))
                .foregroundStyle(controllerGreen).padding(10)
                .background(controllerGreen.opacity(0.06),in:Capsule())
        }
    }
    private var shotControls:some View {
        VStack(alignment:.leading,spacing:5) {
            if model.selectedClub.isPutter {
                Text("퍼팅 · 스트레이트 / 스핀 0").font(.system(size:12,weight:.medium)).foregroundStyle(controllerGreen)
            } else {
                HStack(spacing:12) {
                    Picker("샷 타입",selection:$model.shotType) {
                        ForEach(ControllerShotType.allCases) { type in Text(type.title).tag(type) }
                    }.frame(maxWidth:.infinity)
                    Picker("블로",selection:$model.attackStyle) {
                        ForEach(ControllerAttackStyle.allCases) { attack in Text(attack.title).tag(attack) }
                    }.frame(maxWidth:.infinity)
                }.font(.system(size:12)).disabled(locked)
                Text(model.attackStyle.note+" · 선택한 샷 타입과 함께 적용").font(.system(size:10)).foregroundStyle(controllerMuted)
            }
        }.padding(.horizontal,12).padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading)
            .background(.white,in:RoundedRectangle(cornerRadius:10))
    }
    private var connection:some View {
        HStack(spacing:10) {
            VStack(alignment:.leading,spacing:3) {
                Text("MuniGolf").font(.system(size:13,weight:.semibold))
                Text("연습장 또는 코스를 열어 두세요.").font(.system(size:10)).foregroundStyle(controllerMuted)
            }.frame(width:190,alignment:.leading)
            TextField("게임 주소",text:$model.host).textFieldStyle(.roundedBorder).frame(width:155)
                .accessibilityLabel("MuniGolf 게임 주소").disabled(locked)
            TextField("9210",text:$model.port).textFieldStyle(.roundedBorder).frame(width:62)
                .accessibilityLabel("MuniGolf 게임 포트").disabled(locked)
            Button("연결 확인") { model.checkConnection() }.disabled(locked)
            Circle().fill(model.serverReady ? Color.green:Color.gray.opacity(0.4)).frame(width:7,height:7)
            Text(model.serverReady ? "응답 확인":"확인 전").font(.system(size:10)).foregroundStyle(controllerMuted)
            Spacer(minLength:5)
            Label(model.serverReady ? "타점 확정 시 자동 전송":"미연결 · 전송 안 함",systemImage:model.serverReady ? "paperplane.fill":"circle")
                .font(.system(size:11,weight:.semibold)).foregroundStyle(model.serverReady ? controllerGreen:controllerMuted)
                .padding(10).background(controllerGreen.opacity(0.04),in:RoundedRectangle(cornerRadius:9))
        }.padding(13).background(.white,in:RoundedRectangle(cornerRadius:13))
    }
    private var clubPanel:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Text("클럽 선택").font(.system(size:16,weight:.semibold))
                Text("게임에서도 같은 클럽을 선택하세요.").font(.system(size:10)).foregroundStyle(controllerMuted)
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:6) {
                    ForEach(model.clubs) { club in
                        Button { model.selectedCode=club.id } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(club.id).font(.system(size:13,weight:.semibold))
                                Text("\(number(model.displayedDistance(club),0)) \(club.isPutter ? "ft":model.distanceUnit.rawValue)")
                                    .font(.system(size:10)).monospacedDigit()
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,11).padding(.vertical,7)
                                .foregroundStyle(model.selectedCode==club.id ? Color.white:controllerGreen)
                                .background(model.selectedCode==club.id ? controllerGreen:controllerGreen.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).accessibilityLabel("\(club.name) 선택")
                    }
                }
                Divider()
                Text(model.selectedClub.name).font(.system(size:14,weight:.semibold)).foregroundStyle(controllerGreen)
                Text(model.selectedClub.isPutter ? "100% 스윙 기준 굴림 거리":"100% 스윙 기준 캐리")
                    .font(.system(size:11)).foregroundStyle(controllerMuted)
                HStack {
                    TextField("거리",text:$model.distanceText).textFieldStyle(.roundedBorder)
                        .font(.system(size:20,weight:.medium,design:.rounded)).accessibilityLabel("클럽 기준 거리")
                    Text(model.displayUnit).font(.system(size:14,weight:.medium)).foregroundStyle(controllerGreen)
                }
                if let issue=model.configurationIssue { Text(issue).font(.system(size:10)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
                HStack { Button("설정 저장") { model.applySettings() };Spacer();Button("기본값") { model.restoreClub() }.foregroundStyle(controllerMuted) }
                    .font(.system(size:11))
                Divider()
                HStack { Text("목표 방향");Spacer();Text("\(number(model.aim,1))°").monospacedDigit() }.font(.system(size:11))
                Slider(value:$model.aim,in:-20...20,step:0.5).accessibilityLabel("목표 방향 각도")
                DisclosureGroup("스윙 설정") {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            VStack(alignment:.leading) { Text("발사각 °");TextField("발사각",text:$model.angleText).textFieldStyle(.roundedBorder) }
                            VStack(alignment:.leading) { Text("스핀 rpm");TextField("스핀",text:$model.spinText).textFieldStyle(.roundedBorder) }
                        }
                        Text("페이스 방향 \(number(model.faceBias,1))°")
                        Slider(value:$model.faceBias,in:-12...12,step:0.5)
                        Text("스윙 길이 민감도 \(number(model.sensitivity,1))×")
                        Slider(value:$model.sensitivity,in:0.5...1.8,step:0.1)
                    }.font(.system(size:10)).padding(.top,7)
                }.font(.system(size:11))
                Text("게임에서도 같은 클럽을 선택하세요.\n기준 거리는 참고값이며 실제 게임 결과와 다를 수 있습니다.")
                    .font(.system(size:10)).foregroundStyle(controllerMuted).fixedSize(horizontal:false,vertical:true)
            }.padding(15)
        }.background(.white,in:RoundedRectangle(cornerRadius:13)).disabled(locked)
    }
    private var padPanel:some View {
        VStack(alignment:.leading,spacing:11) {
            HStack {
                Text("스윙 패드").font(.system(size:16,weight:.semibold))
                Spacer()
                Text(model.capturing ? "스윙 중":model.serverReady ? "공을 맞히면 자동 전송":"미연결 · 전송 안 함")
                    .font(.system(size:11,weight:.medium)).foregroundStyle(controllerGreen)
                Button { model.resetSwing() } label: { Image(systemName:"arrow.counterclockwise") }.disabled(model.busy).help("패드 초기화")
            }
            SwingPad(enabled:!model.busy,resetToken:model.resetToken,trajectory:model.swing?.points ?? [],
                     onBegin:{ model.begin() },onUpdate:{ model.update(depth:$0) },
                     onFinish:{ model.finish($0) },onCancel:{ model.cancel($0) })
                .frame(minHeight:280,maxHeight:.infinity)
            HStack { Text("스윙 크기").font(.system(size:12));Spacer();Text("\(number(model.livePower*100,0))%").font(.system(size:17,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(controllerGreen) }
            GeometryReader { geo in
                Capsule().fill(controllerGreen.opacity(0.08))
                    .overlay(alignment:.leading) {
                        Capsule().fill(controllerGreen).frame(width:geo.size.width*min(1,max(0,model.livePower)))
                    }
            }.frame(height:7)
            Text("① 공에서 누르기   ② 아래로 당기기   ③ 공 쪽으로 밀고 공 위에서 놓기")
                .font(.system(size:11)).foregroundStyle(controllerMuted).fixedSize(horizontal:false,vertical:true)
            HStack {
                Menu("컨택 연습 예시") {
                    ForEach(SwingContact.allCases,id:\.self) { contact in
                        Button(contact.title) { model.example(contact) }
                    }
                }.font(.system(size:11)).disabled(locked)
                Spacer()
                Text("Esc로 취소 · 놓는 위치로 컨택 판정").font(.system(size:10)).foregroundStyle(controllerMuted)
            }
            if let first=model.history.first {
                Text(first).font(.system(size:10)).foregroundStyle(controllerMuted).lineLimit(1)
            }
        }.padding(15).background(.white,in:RoundedRectangle(cornerRadius:13))
    }
    private var resultPanel:some View {
        VStack(spacing:0) {
        ScrollView {
            VStack(alignment:.leading,spacing:13) {
                Text("이번 스윙").font(.system(size:16,weight:.semibold))
                if let swing=model.swing {
                    HStack {
                        Text(swing.club.name).font(.system(size:13,weight:.medium)).foregroundStyle(controllerMuted)
                        Spacer()
                        Text(swing.timing?.grade.title ?? swing.contact.title).font(.system(size:12,weight:.semibold))
                            .foregroundStyle(swing.timing?.grade.color ?? (swing.contact == .center ? controllerGreen:Color.orange))
                            .padding(.horizontal,9).padding(.vertical,6)
                            .background((swing.contact == .center ? controllerGreen:Color.orange).opacity(0.08),in:Capsule())
                    }
                    Text("\(swing.shotType.title) · \(swing.attackStyle.title)").font(.system(size:11,weight:.medium)).foregroundStyle(controllerGreen)
                    if let timing=swing.timing {
                        VStack(alignment:.leading,spacing:5) {
                            Text("\(timing.power.label) · \(timing.sideLabel)").font(.system(size:13,weight:.semibold))
                            Text("중앙 오차 \(number(timing.error*100,1))% · \(timing.sideLabel)")
                            Text("클럽 페이스의 힐 / 중앙 / 토 기준 · \(timing.direction.title)")
                        }.font(.system(size:10)).foregroundStyle(timing.grade.color)
                    }
                    FaceImpactView(swing:swing).frame(height:143)
                    Text("가로 \(number(swing.horizontalImpactMM,1)) / 세로 \(number(swing.verticalImpactMM,1)) mm")
                        .font(.system(size:10)).monospacedDigit().foregroundStyle(controllerMuted)
                    Divider()
                    VStack(alignment:.leading,spacing:3) {
                        Text(swing.club.isPutter ? "참고 굴림 거리":"참고 캐리").font(.system(size:11)).foregroundStyle(controllerMuted)
                        HStack(alignment:.firstTextBaseline,spacing:5) {
                            Text(number(model.swingDistance(swing),1)).font(.system(size:35,weight:.semibold,design:.rounded)).monospacedDigit()
                            Text(swing.club.isPutter ? "ft":model.distanceUnit.rawValue).font(.system(size:16))
                        }.foregroundStyle(controllerGreen)
                    }
                    Group {
                        metric("볼 속도",number(swing.ballMPH,1)+" mph")
                        metric("스핀",number(swing.spin,0)+" rpm")
                        metric("스핀축",number(swing.spinAxis,1)+"°")
                        metric("발사각",number(swing.launchAngle,1)+"°")
                        metric("출발 방향",number(swing.launchDirection,1)+"°")
                        metric("클럽 속도",number(swing.clubMPH,1)+" mph")
                    }
                    Text(swing.timing.map { "\($0.grade.description). 정확도와 파워를 볼 속도·방향·스핀·타점에 반영합니다." } ?? swing.contact.note)
                        .font(.system(size:11)).foregroundStyle(controllerMuted).fixedSize(horizontal:false,vertical:true)
                } else {
                    if model.inputMode == .timing {
                        VStack(alignment:.leading,spacing:13) {
                            Text("POWER → FACE CONTACT").font(.system(size:16,weight:.semibold,design:.rounded)).foregroundStyle(controllerGreen)
                            Text("1차 Space/클릭으로 강도, 2차 Space/클릭으로 클럽 페이스 타점을 정합니다.").font(.system(size:12)).foregroundStyle(controllerMuted)
                            Divider()
                            ForEach(TimingGrade.allCases,id:\.self) { grade in
                                HStack {
                                    Circle().fill(grade.color).frame(width:7,height:7)
                                    Text(grade.title).fontWeight(.semibold)
                                    Spacer();Text(grade.rangeLabel).monospacedDigit()
                                }.font(.system(size:12)).foregroundStyle(grade.color)
                            }
                            Text("중앙과의 거리는 바 전체 너비 기준입니다. Perfect 구간은 모든 파워에서 동일합니다.")
                                .font(.system(size:10)).foregroundStyle(controllerMuted)
                            Text("왼쪽은 힐, 오른쪽은 토입니다. 극힐은 슬라이스, 극토는 훅입니다. 입력 전까지 바가 계속 왕복합니다.")
                                .font(.system(size:10)).foregroundStyle(controllerMuted)
                        }
                    } else {
                    RoundedRectangle(cornerRadius:12).fill(controllerGreen.opacity(0.04))
                        .frame(height:150).overlay(VStack(spacing:10) {
                            Image(systemName:"hand.draw").font(.system(size:30)).foregroundStyle(controllerGreen)
                            Text("스윙하면 컨택과 샷 정보를 보여 줍니다.").font(.system(size:11)).foregroundStyle(controllerMuted)
                        })
                    Text("공 위에 가까이 놓으면 정타, 좌우로 벗어나면 토·힐, 앞뒤로 벗어나면 얇은 타격·뒤땅으로 판정합니다.")
                        .font(.system(size:12)).foregroundStyle(controllerMuted).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }.padding(15)
        }
        VStack(alignment:.leading,spacing:10) {
                Divider()
                HStack(spacing:8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName:model.sent ? "checkmark.circle.fill":"paperplane") }
                    Text(model.transmissionStatus).font(.system(size:12,weight:.semibold))
                        .fixedSize(horizontal:false,vertical:true)
                }.foregroundStyle(model.isError ? Color.orange:controllerGreen)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
                Text("조작에서 계산한 가상 컨택입니다. 게임에서도 같은 클럽을 선택하세요. 헛스윙은 전송하지 않습니다.")
                    .font(.system(size:10)).foregroundStyle(controllerMuted).fixedSize(horizontal:false,vertical:true)
            }.padding(.horizontal,15).padding(.bottom,15)
        }.background(.white,in:RoundedRectangle(cornerRadius:13))
    }
    private func metric(_ title:String,_ value:String)->some View {
        HStack { Text(title).foregroundStyle(controllerMuted);Spacer();Text(value).monospacedDigit().foregroundStyle(controllerGreen) }.font(.system(size:12))
    }
    private func number(_ n:Double,_ digits:Int=1)->String {
        String(format:"%.*f",locale:Locale(identifier:"en_US_POSIX"),digits,n)
    }
}

private struct FaceImpactView:View {
    let swing:ControllerSwing
    var body:some View {
        VStack(spacing:4) {
            Text("페이스 타격 위치 · 추정").font(.system(size:10)).foregroundStyle(controllerMuted)
            GeometryReader { geo in
                let width=geo.size.width,height=geo.size.height
                let x=swing.horizontalImpactMM/(swing.club.isWood ? 40:25)
                let y=swing.verticalImpactMM/(swing.club.isWood ? 22:16)
                ZStack {
                    RoundedRectangle(cornerRadius:22).fill(controllerGreen.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius:22).stroke(controllerGreen.opacity(0.22),lineWidth:1))
                    Path { path in
                        for p in [0.25,0.5,0.75] { path.move(to:CGPoint(x:10,y:height*p));path.addLine(to:CGPoint(x:width-10,y:height*p)) }
                        path.move(to:CGPoint(x:width/2,y:8));path.addLine(to:CGPoint(x:width/2,y:height-8))
                    }.stroke(controllerGreen.opacity(0.16),style:StrokeStyle(lineWidth:1,dash:[3,4]))
                    Circle().stroke(controllerGreen.opacity(0.5),lineWidth:1).frame(width:28,height:28)
                    Circle().fill(swing.contact == .center ? controllerGreen:Color.orange).frame(width:14,height:14)
                        .position(x:width/2+width*0.40*x,y:height/2-height*0.36*y)
                }
            }.frame(height:104)
            HStack { Text("힐 −");Spacer();Text("+ 토") }.font(.system(size:10)).foregroundStyle(controllerMuted)
        }
    }
}
