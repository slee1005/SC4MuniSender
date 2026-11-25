import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class SenderModel: ObservableObject {
    @Published var shots: [SavedShot] = []
    @Published var selectedID: String? { didSet { selectionChanged() } }
    @Published var inputs = ShotInputs()
    @Published var search = ""
    @Published var host: String { didSet { serverResponded = false } }
    @Published var port: String { didSet { serverResponded = false } }
    @Published var distanceDisplayUnit: DistanceDisplayUnit {
        didSet { defaults.set(distanceDisplayUnit.rawValue, forKey: "distanceDisplayUnit") }
    }
    @Published var sourceURL = ShotLoader.defaultURL
    @Published var fileStatus = ""
    @Published var message = "MuniGolf에서 연습장이나 코스를 열어 주세요."
    @Published var isError = false
    @Published var isBusy = false
    @Published var serverResponded = false
    @Published var lastSentID: String?
    @Published var sentCount = 0
    private var loaded = false
    private let defaults = UserDefaults.standard
    private let deviceID: String
    private let importStore = ShotImportStore(url: ShotImportStore.defaultURL)

    init() {
        host = UserDefaults.standard.string(forKey: "gameHost") ?? "127.0.0.1"
        port = UserDefaults.standard.string(forKey: "gamePort") ?? "9210"
        distanceDisplayUnit = DistanceDisplayUnit(rawValue: UserDefaults.standard.string(forKey: "distanceDisplayUnit") ?? "m") ?? .meters
        if let saved = UserDefaults.standard.string(forKey: "senderDeviceID") { deviceID = saved }
        else {
            deviceID = "SC4-SavedShots-" + String(UUID().uuidString.prefix(8))
            UserDefaults.standard.set(deviceID, forKey: "senderDeviceID")
        }
    }

    var selected: SavedShot? { shots.first { $0.id == selectedID } }
    var filtered: [SavedShot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return shots }
        return shots.filter {
            [$0.clubLabel, $0.club ?? "", $0.dateLabel, $0.id, $0.importSourceFile ?? ""].joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }
    var inputIssue: String? {
        guard let selected = selected else { return "목록에서 샷을 선택해 주세요." }
        do { _ = try inputs.payload(deviceID: deviceID, number: 1, carryYards: selected.carryYards); return nil }
        catch { return error.localizedDescription }
    }

    func loadOnce() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        var originals: [SavedShot] = []
        var imported: [SavedShot] = []
        var notes: [String] = []
        var problems: [String] = []
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            do {
                let loaded = try ShotLoader.load(Data(contentsOf: sourceURL))
                originals = loaded.shots
                if loaded.skipped > 0 { notes.append("원본 \(loaded.skipped)개 줄 제외") }
            } catch { problems.append("Collector 기록: \(error.localizedDescription)") }
        }
        do {
            imported = try importStore.load()
        } catch { problems.append("가져온 기록 저장소: \(error.localizedDescription)") }
        shots = ShotImportStore.merge(originals: originals, imported: imported)
        if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
        fileStatus = "\(shots.count)개 샷 · 가져온 기록 \(imported.count)개"
        if !notes.isEmpty { fileStatus += " · " + notes.joined(separator: " · ") }
        if !problems.isEmpty {
            message = problems.joined(separator: " / ")
            isError = true
        } else {
            isError = false
            if shots.isEmpty { message = "‘기록 가져오기’에서 SC4의 CSV, JSON 또는 JSONL 파일을 선택해 주세요." }
        }
    }

    func importFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "SC4 내보내기 기록 가져오기"
        panel.message = "MySwingCaddie CSV 또는 SC4 Shot Collector의 CSV·JSON·JSONL을 선택하세요. 원본 파일은 변경하지 않습니다."
        panel.prompt = "가져오기"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText]
        if let jsonl = UTType(filenameExtension: "jsonl", conformingTo: .data) {
            panel.allowedContentTypes.append(jsonl)
        }
        if panel.runModal() == .OK { importFiles(at: panel.urls) }
    }

    func importFiles(at urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        var incoming: [SavedShot] = []
        var skipped = 0, summaries = 0
        var failures: [String] = []
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 20 * 1024 * 1024 else {
                    throw ReplayError.input("20MB 이하의 파일을 선택해 주세요.")
                }
                let result = try ShotImporter.load(Data(contentsOf: url), filename: url.lastPathComponent)
                incoming += result.shots
                skipped += result.skipped
                summaries += result.summaries
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        do {
            // Reload the original IDs just before adding, so CSV/JSON exports of existing shots deduplicate.
            let originals = (try? ShotLoader.load(Data(contentsOf: sourceURL)).shots) ?? []
            let saved = try importStore.add(incoming, originals: originals)
            search = ""
            reload()
            let reloadProblem = isError ? message : nil
            if let first = saved.added.first { selectedID = first.id }
            var details = ["\(saved.added.count)개 추가", "중복 \(saved.duplicates)개"]
            if summaries > 0 { details.append("평균·요약 \(summaries)개 제외") }
            if skipped > 0 { details.append("읽을 수 없는 \(skipped)개 행 제외") }
            if !failures.isEmpty { details.append(failures.joined(separator: " / ")) }
            if let reloadProblem = reloadProblem { details.append(reloadProblem) }
            message = details.joined(separator: " · ")
            isError = !failures.isEmpty || skipped > 0 || reloadProblem != nil
        } catch {
            message = "가져온 기록을 저장하지 못했습니다: \(error.localizedDescription)"
            isError = true
        }
    }

    func restoreValues() { selectionChanged() }

    private func selectionChanged() {
        if let shot = selected { inputs = ShotInputs(shot: shot) }
    }

    func checkConnection() { perform(sendShot: false) }
    func sendSelected() { perform(sendShot: true) }

    private func perform(sendShot: Bool) {
        guard !isBusy else { return }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let portNumber = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), portNumber > 0 else {
            message = "게임 주소와 포트 (1–65535)를 확인해 주세요."
            isError = true
            return
        }
        let payload: OpenConnectMessage
        let sendingID = selectedID
        let sequence: Int
        do {
            if sendShot {
                guard let shot = selected else { return }
                sequence = defaults.integer(forKey: "lastShotNumber") + 1
                payload = try inputs.payload(deviceID: deviceID, number: sequence, carryYards: shot.carryYards)
                // Never reuse a number after an uncertain network outcome, and never auto-retry a shot.
                defaults.set(sequence, forKey: "lastShotNumber")
            } else { sequence = 0; payload = .heartbeat(deviceID: deviceID) }
        } catch { message = error.localizedDescription; isError = true; return }
        defaults.set(address, forKey: "gameHost")
        defaults.set(port, forKey: "gamePort")
        isBusy = true
        isError = false
        message = sendShot ? "선택한 샷을 보내고 있습니다…" : "샷 없이 서버 응답을 확인하고 있습니다…"
        Task {
            defer { isBusy = false }
            do {
                _ = try await OpenConnectTransport.exchange(host: address, port: portNumber, data: payload.encoded())
                serverResponded = true
                if sendShot {
                    sentCount += 1
                    lastSentID = sendingID
                    message = "샷 #\(sequence) 전송 완료 · MuniGolf에서 시뮬레이션을 확인하세요."
                } else { message = "MuniGolf 응답 확인 (200) · 샷을 선택하고 전송하세요." }
            } catch {
                serverResponded = false
                isError = true
                message = error.localizedDescription
            }
        }
    }
}
