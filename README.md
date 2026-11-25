# SC4 Muni Sender

SC4 저장 샷을 선택해 MuniGolf의 Open Connect 입력으로 보내는 macOS 앱입니다.
MySwingCaddie에서 내보낸 CSV와 SC4 Shot Collector의 CSV·JSON·JSONL을 가져올 수 있습니다.

## 사용하기

1. MuniGolf에서 연습장 또는 코스를 엽니다.
2. `SC4 Muni Sender.app`을 실행합니다.
3. **기록 가져오기**를 눌러 내보낸 파일을 선택합니다. 여러 파일을 함께 선택할 수 있습니다.
4. 게임 주소와 포트를 확인합니다. 같은 Mac에서 실행 중이면 `127.0.0.1:9210`입니다.
5. **연결 확인**을 누른 뒤, 샷을 선택하고 값을 확인합니다.
6. 빠진 값을 입력하고 **이 샷을 MuniGolf로 전송**을 누릅니다. `⌘Return`으로도 전송합니다.

거리 표시는 미터·야드 중 선택할 수 있습니다. 볼·클럽 속도 입력은 mph이며,
전송 데이터는 Open Connect의 `Yards` 규격을 사용합니다.

목록의 검색창 옆 **정렬**에서 **캐리 짧은 순**, **캐리 긴 순**, **최신순**을 선택합니다.
미터·야드가 섞인 기록도 같은 실제 거리로 비교하며, 거리 정보가 없으면 뒤에 표시합니다.
검색 결과에도 선택한 정렬을 적용하고, 다음 실행에도 선택을 유지합니다.

## 기록 가져오기

지원하는 CSV는 다음 두 형식입니다.

- MySwingCaddie: `No.`, `Date`, `EQ`, `Carry(yd)`, `Ball Speed(mph)`, `Launch Angle(deg)`, `Spin(rpm)` 등의 헤더
- SC4 Shot Collector: `id`, `shot_time`, `club`, `carry_distance`, `distance_unit`, `ball_speed`, `speed_unit`, `launch_angle_deg`, `spin_rpm` 등의 헤더

UTF-8 CSV의 BOM, 쉼표·세미콜론·탭 구분, 따옴표와 CRLF를 처리합니다.
헤더 또는 열에 명시된 거리·속도 단위를 변환하며 평균·요약 행은 제외합니다.
숫자나 단위가 잘못된 행은 건너뛰고 개수를 안내합니다. 파일당 최대 20MB입니다.
JSON은 SC4 Shot Collector의 샷 배열, JSONL은 한 줄에 샷 하나를 담은 기록 형식입니다.

가져온 샷은 다음 위치에 보관되어 앱을 다시 열어도 유지됩니다.

```text
~/Library/Application Support/SC4 Muni Sender/imported-shots.json
```

원본 내보내기 파일은 수정하지 않습니다. 같은 CSV를 다시 가져오면 기존 행은 중복 추가하지 않습니다.
JSON/JSONL과 Collector CSV는 샷 ID를 사용해 중복을 확인합니다.
기본 Collector 기록도 읽어 합쳐 보여 줍니다. Collector가 설치되어 있지 않아도 파일을 가져올 수 있습니다.

```text
~/Library/Application Support/SC4 Shot Collector/shots.jsonl
```

## 값 확인과 전송

내보내기에 없는 스핀·발사각·출발 방향은 자동으로 만들어 넣지 않습니다.
예를 들어 스핀이 `-`인 CSV 샷은 **스핀 필요**로 표시하며, 전송 전에 값을 입력해야 합니다.
오른쪽에서 수정한 입력값은 원본이나 가져온 기록을 덮어쓰지 않습니다.
스핀축 기본 0°는 휨이 없는 가정값이며 SC4 측정값이 아닙니다.
생성 샷 및 추정 발사각 표시는 해당 정보가 기록에 있을 때 유지합니다.
기록에 `spinAxis`가 있으면 해당 값을 선택 화면과 전송에 사용합니다.
페이드·드로우 생성 샷은 이 값으로 구질을 구분하며 입력창에서 조절할 수 있습니다.
CSV의 선택 열 `Spin Axis(deg)` 또는 `spin_axis`도 가져옵니다.
생성 샷에 `apex`와 `generationNote`가 있으면 최고 높이와 생성 안내도 표시합니다.
높이와 캐리는 참고·계산값이며 MuniGolf에서 실측 보정한 결과가 아닙니다.

스핀축의 부호는 +가 오른쪽, −가 왼쪽 휨을 뜻하는
[스핀축 정의](https://support.trackmangolf.com/hc/en-us/articles/39726408967323-Parameters-Spin-Axis-Tee-to-Green)를 따릅니다.
오른손 기준 연습용 페이드는 양수, 드로우는 음수로 설정합니다.

한 번 누르면 한 샷을 모의 입력(`IsMock=true`)으로 전송하며,
서버의 `Code: 200` 응답을 받아야 완료로 표시합니다.
샷 번호를 새로 부여하고 자동 재전송하지 않습니다.
연결 확인은 측정값 없는 하트비트만 보냅니다.
게임 환경·바람·클럽·지형에 따라 실제 시뮬레이션 거리는 저장된 캐리와 달라질 수 있습니다.

## 빌드와 검증

Apple Silicon Mac, macOS 13 이상과 Xcode Command Line Tools가 필요합니다.
별도 패키지 설치 없이 SwiftUI·AppKit·Network·CryptoKit을 사용합니다.

```sh
zsh build.sh
open "dist/SC4 Muni Sender.app"
```

```sh
zsh test.sh
zsh test.sh --network
```

검증은 가상 샷과 임시 저장소를 사용합니다. 네트워크 검증은 격리된 로컬 테스트 서버만 사용하며
실제 MuniGolf에 테스트 샷을 보내지 않습니다. 개인 샷 기록과 빌드 결과물은 저장소에서 제외합니다.
