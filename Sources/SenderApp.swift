import SwiftUI
import AppKit

@main
struct SC4MuniSenderApp: App {
    @StateObject private var model = SenderModel()
    var body: some Scene {
        WindowGroup {
            SenderView(model: model)
                .preferredColorScheme(.light)
                .onAppear { model.loadOnce() }
        }
        .defaultSize(width: 1210, height: 790)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private struct SenderView: View {
    @ObservedObject var model: SenderModel
    private let accent = Color(red: 0.04, green: 0.34, blue: 0.31)
    private let muted = Color(red: 0.43, green: 0.47, blue: 0.47)
    private let surface = Color(red: 0.96, green: 0.97, blue: 0.96)

    var body: some View {
        VStack(spacing: 17) {
            header
            connectionBar
            HStack(alignment: .top, spacing: 17) {
                records
                editor.frame(width: 345)
            }
            .disabled(model.isBusy)
            status
        }
        .padding(23)
        .background(surface)
        .tint(accent)
        .frame(minWidth: 1100, minHeight: 745)
        .onChange(of: model.search) { _ in
            if !model.filtered.contains(where: { $0.id == model.selectedID }) {
                model.selectedID = model.filtered.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 49, height: 49)
                .background(accent, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("SC4 → MuniGolf")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                Text("샷 선택 → 값 확인 → MuniGolf에서 시뮬레이션")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("거리 단위").font(.system(size: 10)).foregroundStyle(muted)
                Picker("거리 단위", selection: $model.distanceDisplayUnit) {
                    ForEach(DistanceDisplayUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 177)
            }
            Label("모의 샷으로 전송", systemImage: "flag.checkered")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(accent.opacity(0.07), in: Capsule())
                .foregroundStyle(accent)
        }
    }

    private var connectionBar: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MuniGolf 연결").font(.system(size: 13, weight: .semibold))
                Text("게임에서 연습장 또는 코스를 열어 두세요.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text("게임 주소").font(.system(size: 10)).foregroundStyle(muted)
                TextField("127.0.0.1", text: $model.host)
                    .textFieldStyle(.roundedBorder).frame(width: 155)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("포트").font(.system(size: 10)).foregroundStyle(muted)
                TextField("9210", text: $model.port)
                    .textFieldStyle(.roundedBorder).frame(width: 72)
            }
            Button { model.checkConnection() } label: {
                Label("연결 확인", systemImage: "network")
            }
            .controlSize(.large)
            .disabled(model.isBusy)
            HStack(spacing: 5) {
                Circle().fill(model.serverResponded ? accent : Color.gray.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(model.serverResponded ? "응답 확인" : "확인 전")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }.frame(width: 76)
        }
        .disabled(model.isBusy)
        .padding(15)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(accent.opacity(0.08)))
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("저장된 샷").font(.system(size: 17, weight: .semibold))
                    Text(model.fileStatus).font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Button { model.importFiles() } label: { Label("기록 가져오기", systemImage: "square.and.arrow.down") }
                    .help("SC4 내보내기 CSV·JSON·JSONL을 목록에 추가하고 보관")
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("저장된 샷 새로고침")
                    .accessibilityLabel("샷 새로고침")
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("클럽 또는 날짜로 검색", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(muted)
                }
            }
            .padding(9)
            .background(surface, in: RoundedRectangle(cornerRadius: 8))
            Table(model.filtered, selection: $model.selectedID) {
                TableColumn("샷 시각") { shot in
                    Text(shot.dateLabel).font(.system(size: 11)).monospacedDigit()
                }.width(min: 112, ideal: 119)
                TableColumn("클럽") { shot in
                    Text(shot.clubLabel).font(.system(size: 11)).help(shot.clubLabel)
                }.width(min: 80, ideal: 135)
                TableColumn("캐리 · \(model.distanceDisplayUnit.rawValue)") { shot in
                    Text(number(model.distanceDisplayUnit.carry(for: shot))).font(.system(size: 11)).monospacedDigit()
                }.width(min: 60, ideal: 66)
                TableColumn("볼 · mph") { shot in
                    Text(number(shot.ballMPH)).font(.system(size: 11)).monospacedDigit()
                }.width(min: 61, ideal: 67)
                TableColumn("발사각") { shot in
                    Text(number(shot.launchAngle)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(shot.launchAngle == nil ? Color.orange : Color.primary)
                }.width(min: 47, ideal: 53)
                TableColumn("상태") { shot in
                    if model.lastSentID == shot.id {
                        Label("전송됨", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(accent)
                    } else if let missing = shot.missingMeasurement {
                        Text(missing).font(.system(size: 10)).foregroundStyle(Color.orange)
                    } else if shot.isGenerated {
                        Text("생성 샷").font(.system(size: 10)).foregroundStyle(accent)
                    } else if shot.launchAngleIsEstimated == true {
                        Text("발사각 추정").font(.system(size: 10)).foregroundStyle(Color.orange)
                    } else {
                        Text(shot.importSourceFile == nil ? "선택 가능" : "가져온 샷")
                            .font(.system(size: 10)).foregroundStyle(muted)
                    }
                }.width(min: 70, ideal: 78)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if model.filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 25)).foregroundStyle(muted)
                        Text(model.shots.isEmpty ? "‘기록 가져오기’로 SC4 파일을 추가하세요." : "검색 결과가 없습니다.")
                            .font(.system(size: 12)).foregroundStyle(muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.95))
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                Text("Collector 원본 + 가져온 기록 · 원본 읽기 전용").lineLimit(1)
            }
            .font(.system(size: 10)).foregroundStyle(muted)
            .help("Collector: \(model.sourceURL.path)\n가져온 기록: \(ShotImportStore.defaultURL.path)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(accent.opacity(0.08)))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("선택한 샷").font(.system(size: 17, weight: .semibold))
                Spacer()
                if model.selected != nil {
                    Button("원래 값") { model.restoreValues() }.controlSize(.small)
                        .help("이 샷에서 읽은 값으로 되돌리기")
                }
            }
            if let selected = model.selected {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selected.clubLabel).font(.system(size: 21, weight: .semibold)).foregroundStyle(accent)
                    Spacer()
                    Text(selected.dateLabel).font(.system(size: 11)).foregroundStyle(muted)
                }
                Text("캐리 \(number(model.distanceDisplayUnit.carry(for: selected))) \(model.distanceDisplayUnit.rawValue)")
                    .font(.system(size: 12)).foregroundStyle(muted)
                if let filename = selected.importSourceFile {
                    Label("가져온 파일: \(filename)", systemImage: "doc.badge.plus")
                        .font(.system(size: 11)).foregroundStyle(muted)
                        .lineLimit(2).help(filename)
                }
                if selected.isGenerated {
                    Label("연습용 생성 데이터 · 실제 측정값 아님", systemImage: "wand.and.stars")
                        .font(.system(size: 11)).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let height = selected.apexMeters {
                        Text("\(selected.source == "synthetic_lw_lob_ballistic" ? "계산상" : "참고") 최고 높이 \(number(height)) m")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    if let note = selected.generationNote {
                        Text(note).font(.system(size: 11)).foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if selected.launchAngleIsEstimated == true {
                    Label("발사각은 캐리·최고 높이로 계산한 추정값입니다.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        input("볼 속도", unit: "mph", text: $model.inputs.ballSpeed, missing: selected.ballMPH == nil)
                        input("클럽 속도", unit: "mph · 선택", text: $model.inputs.clubSpeed)
                    }
                    GridRow {
                        input("수직 발사각", unit: selected.launchAngleIsEstimated == true ? "° · 추정" : "°", text: $model.inputs.verticalAngle, missing: selected.launchAngle == nil)
                        input("출발 방향", unit: "°", text: $model.inputs.horizontalAngle, missing: selected.resolvedDirection == nil)
                    }
                    GridRow {
                        input("총 스핀", unit: "rpm", text: $model.inputs.totalSpin, missing: selected.spinRPM == nil)
                        input("스핀축", unit: selected.spinAxis == nil ? "° · 가정값" : (selected.isGenerated ? "° · 생성값" : "° · 저장값"), text: $model.inputs.spinAxis, missing: model.inputs.spinAxis.isEmpty)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label(selected.spinAxis == nil ? "스핀축은 SC4에 기록되지 않습니다." : "이 샷에 저장된 스핀축을 사용합니다.", systemImage: "info.circle")
                    Text(selected.spinAxis == nil ? "기본 0°는 스핀에 의한 휨이 없는 가정입니다. 필요한 경우 값을 바꿔 주세요." : "스핀축 +는 오른쪽, −는 왼쪽 휨을 위한 값입니다. 생성 샷은 연습용 가정값이며 수정할 수 있습니다.")
                }
                .font(.system(size: 11)).foregroundStyle(muted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(surface, in: RoundedRectangle(cornerRadius: 9))
                if let issue = model.inputIssue {
                    Text(issue).font(.system(size: 11)).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    }
                    .padding(.bottom, 3)
                }
                .scrollIndicators(.hidden)
                Button { model.sendSelected() } label: {
                    Label(model.isBusy ? "응답 기다리는 중…" : "이 샷을 MuniGolf로 전송", systemImage: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isBusy || model.inputIssue != nil)
                Text("한 번 누르면 한 샷을 보냅니다. 입력 수정은 원본 기록에 저장되지 않습니다.")
                    .font(.system(size: 10)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
                Image(systemName: "cursorarrow.click").font(.system(size: 28)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity)
                Text("왼쪽 목록에서 샷을 선택하세요.")
                    .font(.system(size: 13)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(17)
        .frame(maxHeight: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(accent.opacity(0.08)))
    }

    private func input(_ title: String, unit: String, text: Binding<String>, missing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 1)
                Text(unit).font(.system(size: 9)).foregroundStyle(muted)
            }
            TextField(missing ? "직접 입력 필요" : "—", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .accessibilityLabel(title)
        }
    }

    private var status: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.isBusy { ProgressView().controlSize(.small) }
            else {
                Image(systemName: model.isError ? "exclamationmark.circle" : (model.serverResponded ? "checkmark.circle.fill" : "info.circle"))
                    .foregroundStyle(model.isError ? Color.orange : accent)
            }
            Text(model.message).font(.system(size: 12)).lineLimit(2)
                .foregroundStyle(model.isError ? Color.orange : accent)
            Spacer(minLength: 5)
            Text("이번 실행 \(model.sentCount)샷 전송")
                .font(.system(size: 11)).foregroundStyle(muted)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(minHeight: 43)
        .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func number(_ value: Double?) -> String {
        guard let value = value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }
}
