import Foundation
import Combine
import CoreBluetooth
import AppKit

struct SC4DiscoveredDevice:Identifiable {
    let id:UUID
    let name:String
    let rssi:Int
}

/// Created without touching Bluetooth. Only a user search/connect action initializes the radio.
final class SwingCaddieBluetooth:NSObject,ObservableObject,CBCentralManagerDelegate,CBPeripheralDelegate {
    @Published private(set) var devices:[SC4DiscoveredDevice]=[]
    @Published private(set) var registered:SC4Registration?
    @Published private(set) var status="검색을 눌러 스윙캐디 SC4를 찾아 주세요."
    @Published private(set) var bluetoothStatus="사용 전"
    @Published private(set) var isScanning=false
    @Published private(set) var isConnecting=false
    @Published private(set) var isReady=false
    @Published private(set) var connectedName=""
    @Published private(set) var latest:SC4LiveShot?
    @Published private(set) var receivedCount=0
    @Published private(set) var isError=false
    var onShot:((SC4LiveShot)->Void)?
    private let defaults:UserDefaults?
    private let preview:Bool
    private let directory:URL
    private var central:CBCentralManager?
    private var peripherals:[UUID:CBPeripheral]=[:]
    private var target:CBPeripheral?
    private var writer:CBCharacteristic?
    private var receiver:SC4LiveReceiver?
    private var pendingRegistration:SC4Registration?
    private var requestedID:UUID?
    private var scanRequested=false
    private var scanTimer:Timer?
    private var connectionTimer:Timer?
    private var outgoing:[Data]=[]
    private var writeInFlight=false
    init(defaults:UserDefaults?,preview:Bool=false) {
        self.defaults=defaults;self.preview=preview
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Muni Controller/SC4",isDirectory:true)
        if let data=defaults?.data(forKey:"controllerSC4Registration") { registered=try? JSONDecoder().decode(SC4Registration.self,from:data) }
        super.init()
    }
    private func activate() {
        guard !preview,central==nil else { return }
        central=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:true])
    }
    func search() {
        guard !preview,!isReady,!isConnecting else { return }
        devices.removeAll();peripherals.removeAll();pendingRegistration=nil;isError=false;scanRequested=true
        activate();startRequestedAction()
    }
    func stopSearch() {
        if isScanning { status="검색을 중지했습니다. 발견된 기기를 선택하거나 다시 검색해 주세요." }
        scanRequested=false;central?.stopScan();scanTimer?.invalidate();isScanning=false
    }
    func connect(_ id:UUID) {
        guard !preview,!isReady,!isConnecting,let item=devices.first(where:{$0.id==id}) else { return }
        pendingRegistration=SC4Registration(id:id,name:item.name)
        activate();startRequestedAction()
    }
    func reconnect() {
        guard !preview,!isReady,!isConnecting,let registered=registered else { return }
        isError=false;pendingRegistration=registered
        activate();startRequestedAction()
    }
    func forget() {
        disconnect();registered=nil;defaults?.removeObject(forKey:"controllerSC4Registration")
        status="등록을 해제했습니다. 검색해서 다시 등록할 수 있습니다."
    }
    func disconnect() {
        stopSearch();pendingRegistration=nil;requestedID=nil
        if let target=target { central?.cancelPeripheralConnection(target) }
        clearTransport();isError=false;status="연결 해제 · 기기 등록은 유지됩니다."
    }
    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
    }
    private func startRequestedAction() {
        guard let central=central else { return }
        guard central.state == .poweredOn else {
            if central.state == .unauthorized { status="Bluetooth 접근을 허용한 후 다시 검색해 주세요.";isError=true }
            else if central.state == .poweredOff { status="Mac의 Bluetooth를 켠 후 다시 검색해 주세요." }
            else if central.state == .unsupported { status="이 Mac은 Bluetooth LE 연결을 지원하지 않습니다.";isError=true }
            else { status="Bluetooth 준비 중…" }
            return
        }
        if let registration=pendingRegistration {
            pendingRegistration=nil
            guard let target=peripherals[registration.id] ?? central.retrievePeripherals(withIdentifiers:[registration.id]).first else {
                status="등록한 기기가 보이지 않습니다. 전원을 켜고 다시 검색해 주세요.";isError=true;return
            }
            stopSearch();self.target=target;requestedID=target.identifier
            target.delegate=self;connectedName=registration.name;isConnecting=true;isError=false
            status="\(registration.name) 연결 중…"
            central.connect(target,options:nil)
            connectionTimer?.invalidate()
            connectionTimer=Timer.scheduledTimer(withTimeInterval:25,repeats:false) { [weak self] _ in
                guard let self=self,!self.isReady else { return }
                self.fail("연결 시간이 초과되었습니다. 다른 앱의 SC4 연결을 해제하고 다시 시도해 주세요.")
            }
        } else if scanRequested && !isScanning {
            central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])
            isScanning=true;status="주변 SC4 검색 중 · 기기를 선택하면 연결 후 등록합니다."
            scanTimer=Timer.scheduledTimer(withTimeInterval:15,repeats:false) { [weak self] _ in
                guard let self=self else { return };self.stopSearch()
                self.status=self.devices.isEmpty ? "SC4를 찾지 못했습니다. 전원·거리와 다른 앱의 연결을 확인해 주세요.":"기기를 선택해 연결·등록해 주세요."
            }
        }
    }
    private func clearTransport() {
        connectionTimer?.invalidate();target?.delegate=nil;target=nil;writer=nil
        isReady=false;isConnecting=false;connectedName="";outgoing.removeAll();writeInFlight=false
        receiver?.reset()
    }
    private func fail(_ message:String) {
        stopSearch();requestedID=nil;pendingRegistration=nil
        if let target=target { central?.cancelPeripheralConnection(target) }
        clearTransport();isError=true;status=message
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        switch central.state {
        case .poweredOn:bluetoothStatus="켜짐"
        case .poweredOff:bluetoothStatus="꺼짐"
        case .unauthorized:bluetoothStatus="접근 권한 필요"
        case .unsupported:bluetoothStatus="지원하지 않음"
        case .resetting:bluetoothStatus="재설정 중"
        default:bluetoothStatus="준비 중"
        }
        if central.state != .poweredOn {
            let waitingForRadio=central.state == .unknown || central.state == .resetting
            if waitingForRadio { central.stopScan();scanTimer?.invalidate();isScanning=false }
            else { stopSearch() }
            requestedID=nil;clearTransport()
            status=central.state == .unauthorized ? "시스템 설정의 Bluetooth 접근 권한을 허용해 주세요.":"Bluetooth가 준비되면 다시 검색해 주세요."
        } else { startRequestedAction() }
    }
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard isScanning else { return }
        let name=advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let services=(advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        guard SC4ConnectionRules.isCandidate(name:name,services:services) else { return }
        peripherals[peripheral.identifier]=peripheral
        let item=SC4DiscoveredDevice(id:peripheral.identifier,name:name.isEmpty ? "Swing Caddie SC4":name,rssi:RSSI.intValue)
        if let index=devices.firstIndex(where:{$0.id==item.id}) { devices[index]=item } else { devices.append(item) }
        devices.sort { ($0.rssi == 127 ? -127:$0.rssi)>($1.rssi == 127 ? -127:$1.rssi) }
    }
    func centralManager(_ central:CBCentralManager,didConnect peripheral:CBPeripheral) {
        guard requestedID == peripheral.identifier else { central.cancelPeripheralConnection(peripheral);return }
        status="샷 수신 채널 확인 중…"
        peripheral.discoverServices([CBUUID(string:SC4ConnectionRules.service)])
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect peripheral:CBPeripheral,error:Error?) {
        guard requestedID == peripheral.identifier else { return }
        fail("SC4 연결 실패 · "+(error?.localizedDescription ?? "기기 전원을 확인해 주세요."))
    }
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral peripheral:CBPeripheral,error:Error?) {
        guard requestedID == peripheral.identifier else { return }
        requestedID=nil;clearTransport();status="SC4 연결이 끊겼습니다. 등록된 기기 다시 연결을 눌러 주세요."
    }
    func peripheral(_ peripheral:CBPeripheral,didDiscoverServices error:Error?) {
        guard requestedID == peripheral.identifier else { return }
        if let error=error { fail(error.localizedDescription);return }
        guard let service=peripheral.services?.first(where:{$0.uuid == CBUUID(string:SC4ConnectionRules.service)}) else {
            fail("SC4 수신 서비스를 찾지 못했습니다. SC4 Pro는 이 연결 방식을 지원하지 않습니다.");return
        }
        peripheral.discoverCharacteristics([CBUUID(string:SC4ConnectionRules.write),CBUUID(string:SC4ConnectionRules.notify)],for:service)
    }
    func peripheral(_ peripheral:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard requestedID == peripheral.identifier else { return }
        if let error=error { fail(error.localizedDescription);return }
        writer=service.characteristics?.first(where:{$0.uuid == CBUUID(string:SC4ConnectionRules.write)})
        guard let writer=writer,writer.properties.contains(.write) || writer.properties.contains(.writeWithoutResponse),
              let notify=service.characteristics?.first(where:{$0.uuid == CBUUID(string:SC4ConnectionRules.notify)}),notify.properties.contains(.notify) else {
            fail("SC4의 샷 수신 채널을 열 수 없습니다.");return
        }
        peripheral.setNotifyValue(true,for:notify)
    }
    func peripheral(_ peripheral:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?) {
        guard requestedID == peripheral.identifier,characteristic.uuid == CBUUID(string:SC4ConnectionRules.notify) else { return }
        if let error=error { fail(error.localizedDescription);return }
        guard characteristic.isNotifying else { fail("SC4의 샷 알림이 꺼졌습니다.");return }
        do {
            if receiver == nil { receiver=try SC4LiveReceiver(directory:directory) }
            let registration=SC4Registration(id:peripheral.identifier,name:connectedName)
            let data=try JSONEncoder().encode(registration)
            defaults?.set(data,forKey:"controllerSC4Registration");registered=registration
            connectionTimer?.invalidate();isConnecting=false;isReady=true;isError=false
            status="연결·등록 완료 · SC4 샷 수신 대기"
            write(SC4Wire.deviceInfoRequest())
        } catch { fail("샷 저장 준비 실패 · "+error.localizedDescription) }
    }
    func peripheral(_ peripheral:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?) {
        guard isReady,requestedID == peripheral.identifier,characteristic.uuid == CBUUID(string:SC4ConnectionRules.notify) else { return }
        if let error=error { fail(error.localizedDescription);return }
        guard let data=characteristic.value,let receiver=receiver else { return }
        do {
            let result=try receiver.receive(data,deviceID:peripheral.identifier.uuidString,name:connectedName)
            for reply in result.replies { write(reply) }
            for shot in result.shots { latest=shot;receivedCount+=1;status="샷 수신·저장 완료";onShot?(shot) }
        } catch { fail("샷 원본 저장 실패 · "+error.localizedDescription) }
    }
    private func write(_ data:Data) {
        guard isReady,SC4ConnectionRules.allows(data) else { return }
        guard outgoing.count<64 else { fail("SC4 응답 대기열이 가득 찼습니다. 다시 연결해 주세요.");return }
        outgoing.append(data);flush()
    }
    private func flush() {
        guard isReady,!writeInFlight,!outgoing.isEmpty,let target=target,let writer=writer else { return }
        if writer.properties.contains(.write) {
            writeInFlight=true;target.writeValue(outgoing.removeFirst(),for:writer,type:.withResponse)
        } else if target.canSendWriteWithoutResponse {
            target.writeValue(outgoing.removeFirst(),for:writer,type:.withoutResponse)
            DispatchQueue.main.async { [weak self] in self?.flush() }
        }
    }
    func peripheral(_ peripheral:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?) {
        guard requestedID == peripheral.identifier else { return };writeInFlight=false
        if let error=error { fail(error.localizedDescription) } else { flush() }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral:CBPeripheral) { flush() }
}
