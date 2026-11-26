import SwiftUI

struct SwingCaddiePanel:View {
    @ObservedObject var bluetooth:SwingCaddieBluetooth
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:17) {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("스윙캐디 연결").font(.system(size:21,weight:.semibold))
                        Text("Swing Caddie SC4 · Bluetooth").font(.system(size:12)).foregroundStyle(controllerMuted)
                    }
                    Spacer()
                    Label(bluetooth.isReady ? "연결됨":bluetooth.bluetoothStatus,systemImage:bluetooth.isReady ? "checkmark.circle.fill":"antenna.radiowaves.left.and.right")
                        .font(.system(size:11,weight:.semibold)).foregroundStyle(controllerGreen)
                }
                VStack(alignment:.leading,spacing:10) {
                    step("1","SC4 전원 켜기","기기를 가까이 두고 MySwingCaddie·Shot Collector의 SC4 연결은 해제해 주세요.")
                    step("2","Bluetooth 검색","처음 표시되는 macOS Bluetooth 접근 요청을 허용해 주세요.")
                    step("3","기기 선택 → 연결·등록","샷 수신 준비가 끝나면 기기를 등록합니다. 다음에는 바로 다시 연결할 수 있습니다.")
                }.padding(13).frame(maxWidth:.infinity,alignment:.leading)
                    .background(controllerGreen.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
                if let registered=bluetooth.registered {
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text("등록된 스윙캐디").font(.system(size:10)).foregroundStyle(controllerMuted)
                            Text(registered.name).font(.system(size:14,weight:.semibold))
                        }
                        Spacer()
                        if bluetooth.isReady {
                            Button("연결 해제") { bluetooth.disconnect() }
                        } else {
                            Button("다시 연결") { bluetooth.reconnect() }.disabled(bluetooth.isConnecting)
                        }
                        Button("등록 해제") { bluetooth.forget() }.disabled(bluetooth.isConnecting)
                    }.padding(12).background(controllerGreen.opacity(0.05),in:RoundedRectangle(cornerRadius:10))
                }
                HStack {
                    Text("주변 기기").font(.system(size:14,weight:.semibold))
                    if bluetooth.isScanning || bluetooth.isConnecting { ProgressView().controlSize(.small) }
                    Spacer()
                    if bluetooth.isScanning { Button("검색 중지") { bluetooth.stopSearch() } }
                    else { Button("Bluetooth 검색") { bluetooth.search() }.buttonStyle(.borderedProminent).disabled(bluetooth.isReady || bluetooth.isConnecting) }
                }
                if bluetooth.devices.isEmpty {
                    VStack(spacing:9) {
                        Image(systemName:"antenna.radiowaves.left.and.right").font(.system(size:26))
                        Text(bluetooth.isScanning ? "주변의 SC4를 찾고 있습니다…":"검색된 SC4가 여기에 표시됩니다.")
                            .font(.system(size:12))
                    }.foregroundStyle(controllerMuted).frame(maxWidth:.infinity).padding(.vertical,22)
                        .background(Color.black.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
                } else {
                    ForEach(bluetooth.devices) { device in
                        HStack {
                            Image(systemName:"sensor.fill").foregroundStyle(controllerGreen)
                            VStack(alignment:.leading,spacing:4) {
                                Text(device.name).font(.system(size:13,weight:.semibold))
                                Text(device.rssi == 127 ? "신호 확인 중":device.rssi > -60 ? "신호 좋음":device.rssi > -80 ? "신호 보통":"기기를 더 가까이 놓아 주세요.")
                                    .font(.system(size:10)).foregroundStyle(controllerMuted)
                            }
                            Spacer()
                            Button("연결·등록") { bluetooth.connect(device.id) }.disabled(bluetooth.isReady || bluetooth.isConnecting)
                        }.padding(12).background(controllerGreen.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
                    }
                }
                Text(bluetooth.status).font(.system(size:12,weight:.medium))
                    .foregroundStyle(bluetooth.isError ? Color.orange:controllerGreen).fixedSize(horizontal:false,vertical:true)
                Divider()
                Text("MuniGolf 연결 확인 후 이 탭에서 수신한 새 샷을 자동 전송합니다. 다른 조작 탭에서는 SC4 샷을 저장만 합니다.")
                    .font(.system(size:11)).foregroundStyle(controllerMuted)
                Text("지원 기기: SC4. SC4 Pro는 다른 연결 방식을 사용합니다. SC4에서 측정하지 않는 스핀축은 0°로 보냅니다.")
                    .font(.system(size:10)).foregroundStyle(controllerMuted)
                HStack {
                    Button("Mac Bluetooth 설정") { bluetooth.openBluetoothSettings() }
                    Button("Bluetooth 접근 권한") { bluetooth.openPermissionSettings() }
                }.font(.system(size:10))
            }.padding(17)
        }.background(.white,in:RoundedRectangle(cornerRadius:13))
    }
    private func step(_ number:String,_ title:String,_ detail:String)->some View {
        HStack(alignment:.top,spacing:9) {
            Text(number).font(.system(size:11,weight:.semibold)).foregroundStyle(.white)
                .frame(width:22,height:22).background(controllerGreen,in:Circle())
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.system(size:12,weight:.semibold))
                Text(detail).font(.system(size:10)).foregroundStyle(controllerMuted).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}

struct SwingCaddieResultPanel:View {
    @ObservedObject var model:ControllerModel
    @ObservedObject var bluetooth:SwingCaddieBluetooth
    var body:some View {
        VStack(alignment:.leading,spacing:15) {
            Text("SC4 실측 샷").font(.system(size:16,weight:.semibold))
            Text("수신 \(bluetooth.receivedCount)개 · 이 앱 실행 중").font(.system(size:11)).foregroundStyle(controllerMuted)
            if let shot=bluetooth.latest {
                Text(shot.club ?? "클럽 미확인").font(.system(size:21,weight:.semibold)).foregroundStyle(controllerGreen)
                metric("실측 캐리",shot.carryDistance,unit:"m")
                metric("실측 최고높이",shot.apex,unit:"m")
                metric("볼 속도",shot.ballSpeed.map{$0/0.44704},unit:"mph")
                metric("발사각",shot.launchAngle,unit:"°")
                metric("출발 방향",shot.launchDirection,unit:"°")
                metric("스핀",shot.spinRPM,unit:"rpm")
                Text("SC4 측정값을 그대로 사용합니다. 가상 스윙의 힘·로프트·샷 타입으로 덮어쓰지 않습니다.")
                    .font(.system(size:10)).foregroundStyle(controllerMuted)
            } else {
                Image(systemName:"figure.golf").font(.system(size:36)).foregroundStyle(controllerGreen).padding(.top,18)
                Text("SC4를 연결하고 샷을 치면 측정값이 표시됩니다.").font(.system(size:12)).foregroundStyle(controllerMuted)
            }
            Spacer(minLength:10)
            Divider()
            if model.busy { ProgressView().controlSize(.small) }
            Text(bluetooth.latest.map { model.sc4TransferRecordID == $0.deduplicationKey ? model.sc4TransferStatus:"저장된 SC4 샷 · 자동 전송 안 함" } ?? model.sc4TransferStatus)
                .font(.system(size:12,weight:.semibold)).foregroundStyle(controllerGreen)
            Text("게임에서도 SC4와 같은 클럽을 선택하세요. 필수 측정값이 누락된 샷은 저장만 합니다.")
                .font(.system(size:10)).foregroundStyle(controllerMuted)
        }.padding(15).frame(maxHeight:.infinity,alignment:.topLeading).background(.white,in:RoundedRectangle(cornerRadius:13))
    }
    private func metric(_ name:String,_ value:Double?,unit:String)->some View {
        HStack {
            Text(name).foregroundStyle(controllerMuted);Spacer()
            Text(value.map { String(format:unit == "rpm" ? "%.0f %@":"%.1f %@",$0,unit) } ?? "측정값 없음").monospacedDigit()
        }.font(.system(size:12))
    }
}
