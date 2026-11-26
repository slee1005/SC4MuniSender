# Muni Controller

트랙패드나 마우스로 스윙을 만들어 MuniGolf에 보내는 Mac 앱입니다.
클럽별 기준 거리에서 스윙 크기·템포·방향·컨택에 따라 연속적으로 샷 값을 계산합니다.
기존 SC4 Muni Sender와 별도 앱이며, Sender의 개인 샷 파일을 읽거나 변경하지 않습니다.

## 실행과 조작

1. MuniGolf에서 연습장 또는 코스를 엽니다.
2. `dist/Muni Controller.app`을 실행합니다. 기본 주소는 `127.0.0.1:9210`입니다.
3. 클럽을 선택합니다. 게임에서도 같은 클럽을 선택합니다.
4. 가운데 공에서 누른 채 아래로 당겨 스윙 크기를 정합니다.
5. 공 쪽으로 밀고 공 위에서 놓습니다. 정확히 돌아오면 정타, 좌우는 토·힐, 앞뒤는 얇은 타격·뒤땅으로 판정합니다.
6. 연습 모드에서는 패드의 결과만 확인합니다. ‘이번 스윙을 MuniGolf로 전송’으로 한 샷을 보낼 수 있습니다.
7. ‘연결 확인’ 후 ‘게임 모드’를 선택하면 **다음 스윙부터** 컨택한 샷을 자동으로 한 번 보냅니다.

공을 크게 벗어나면 헛스윙입니다. 헛스윙은 공의 비행 데이터로 보내지 않습니다.
Esc, 패드 초기화 또는 앱 전환으로 진행 중인 스윙을 취소합니다.
‘컨택 연습 예시’는 연습 모드로 전환하며 자동 전송하지 않습니다.
앱은 실행할 때마다 연습 모드로 시작합니다.

## 클럽과 거리

드라이버·3W·4H·4~9번 아이언·PW·GW·SW·LW·퍼터를 제공합니다.
클럽별 100% 스윙 기준 거리, 발사각과 스핀을 바꾸고 저장할 수 있습니다.
거리 표시는 yd/m 선택, 퍼팅은 항상 ft입니다.
목표 방향, 페이스 방향, 스윙 길이 민감도도 조절할 수 있습니다.

표시 거리는 컨트롤러의 힘 곡선으로 계산한 **참고값**입니다. MuniGolf의 기상·지형·볼 물리와 일치하도록 보정한 값이 아닙니다.
실제 샷의 거리는 게임이 전송된 볼 속도·발사각·스핀으로 계산합니다. Controller는 계산한 참고 거리를 `CarryDistance`로 강제하지 않습니다.
컨택 및 타격 위치는 패드 동작을 골프 컨택으로 대응시킨 가상 값이며, 실제 클럽·공 센서의 측정값이 아닙니다.

## 전송 항목과 범위

TCP Open Connect JSON을 사용합니다.

| 객체 | 전송 항목 |
|---|---|
| BallData | Speed(mph), HLA, VLA, TotalSpin(rpm), SpinAxis |
| ClubData | Speed, SpeedAtImpact(mph), AngleOfAttack, FaceToTarget, Loft, Path, HorizontalFaceImpact, VerticalFaceImpact |
| ShotDataOptions | ContainsBallData/ContainsClubData=true, IsMock=true |

컨택은 볼 속도·탄도·스핀축에 반영합니다. 페이스 타격 위치도 수치로 함께 보냅니다.
설치된 LaunchMonitorConnect 2026.11.2.0의 정적 확인에 따라 타격 위치는 mm이며, 가로 음수=힐/양수=토, 세로 음수=낮은 타점/양수=높은 타점입니다.
패드에서 앞에 놓으면 얇은 타격(낮은 타점), 뒤에 놓으면 뒤땅(높은 타점)으로 대응시킵니다.
`Lie`와 `ClosureRate`처럼 이 조작으로 정하지 않은 값은 보내지 않습니다.

‘정타/뒤땅’ 같은 문자 라벨은 Controller 화면에서 보여 줍니다. 게임에는 지원된 숫자 항목으로 표현합니다.
MuniGolf가 추가 클럽/타점 정보를 화면이나 내부 물리에 사용하는지는 실제 게임에서 확인하지 않았습니다.
클럽 종류를 게임에 설정하는 클라이언트 명령은 공개 Open Connect v1 문서에 없으므로 게임 클럽 선택은 직접 합니다.

서버의 Code 200 응답을 받아야 전송 완료로 표시합니다.
샷 번호는 시도마다 증가하며 같은 스윙을 중복 전송하거나 자동 재시도하지 않습니다.
응답이 없거나 연결이 끊기면 게임에서 결과를 확인하세요. ‘연결 확인’은 샷 없는 하트비트만 전송합니다.

공식 자료: [Open Connect v1](https://gsprogolf.com/GSProConnectV1.html), [MuniGolf](https://munigolfsim.com/), [AppKit 마우스 이벤트](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingMouseEvents/HandlingMouseEvents.html).
설치된 브리지는 실행 없이 정적으로 확인했으며, 그 프로그램의 코드를 포함하거나 변경하지 않습니다.

## 빌드와 검증

Apple Silicon Mac, macOS 13 이상에서 별도 패키지 없이 빌드합니다.

```sh
zsh build-controller.sh
zsh test-controller.sh
zsh test-controller.sh --network
```

검증은 가상 궤적, 임시 설정과 격리된 로컬 테스트 서버를 사용합니다. 실제 MuniGolf에는 테스트 샷을 보내지 않습니다.
설정은 앱의 전용 UserDefaults에 저장하며, 스윙 궤적과 최근 전송 기록은 세션 동안만 유지합니다.
