# 로컬 조회 현황판

Harness의 작업·worker·완료 증거·사용량·승인 요청·최근 검증 결과를 브라우저에 표시합니다. 실제 프로젝트 기록만 읽으며 예시 데이터를 삽입하지 않습니다. 활성 프로젝트가 없는 개발 checkout에서는 프로필 미설정과 빈 작업 목록이 정상입니다.

## 시작

프로젝트 루트에서 실행합니다. 중첩 설치는 아래 `scripts/`를 `harness/scripts/`로 바꿉니다.

```powershell
pwsh -NoProfile -File scripts/harness.ps1 dashboard
pwsh -NoProfile -File scripts/harness.ps1 dashboard -NoOpen -Port 8768
pwsh -NoProfile -File scripts/harness.ps1 dashboard -Snapshot -Json
pwsh -NoProfile -File scripts/harness.ps1 dashboard -Preview -Json
```

Windows PowerShell 5.1은 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`로 동일하게 호출합니다. WSL/Linux는 native `pwsh`와 native Python을 사용합니다. CMD와 Bash에서도 이 PowerShell `-File` 진입점을 사용하며 별도 문자열 평가나 셸별 서버 명령을 만들지 않습니다.

- 서버는 Python 3.9 이상 표준 라이브러리만 사용합니다. pip/npm 설치가 필요 없습니다.
- `-PythonExecutable <실행파일 경로>`로 Python을 명시할 수 있습니다. 경로와 옵션은 개별 인수로 전달합니다.
- `-Port` 기본값 0은 사용 가능한 임의 포트를 선택합니다. 출력된 `http://127.0.0.1:<port>/`를 엽니다.
- `-NoOpen`은 브라우저 자동 열기를 생략합니다. Ctrl+C로 서버를 종료합니다.
- `-RefreshSeconds`는 서버 수집 간격이며 기본 10초, 범위 5~300초입니다. 수집 소요 시간만큼 실제 간격이 늘어날 수 있습니다.
- 화면은 5초마다 최신 캐시를 조회합니다. 자동 갱신 중지는 브라우저 조회만 중지하며 worker나 서버 수집을 중단하지 않습니다.
- `-Snapshot`은 Python/서버 없이 한 번 조회합니다. 조회 성공은 작업 성공이 아니며 `collection_status`, 작업 상태, alerts를 확인해야 합니다.
- `-Json`은 `-Snapshot` 또는 `-Preview`와 함께 사용합니다. 서버 실행은 URL을 바로 출력하는 장기 실행 명령입니다.
- 개별 진입점: `scripts/start_harness_dashboard.ps1`, `scripts/get_harness_dashboard.ps1 -Root <프로젝트>`.

## 지표 계약

| 지표 | 계산과 한계 |
| --- | --- |
| 등록 작업 | 보존된 큐의 고유 assignment ID. 아직 배정되지 않은 seed 계획 작업은 포함하지 않음. 프로젝트 전체 계획 진행률이나 시간 예측이 아님 |
| 완료 | 기존 완료 증거 계약으로 명령·로그·assignment·worker·현재 HEAD/branch/index/source를 재검사한 pass. legacy pass/변경된 소스는 미검증 |
| 읽기 전용 증거 | `Assert-AssignmentCompletionEvidence -ReadOnly`가 기록된 tree와 현재 index를 `git diff-index --cached --quiet`로 비교. 새 `write-tree` 객체를 생성하거나 검증 명령을 실행하지 않음 |
| 가동 worker | running 기록의 host와 PID를 대조한 worker host 수. Windows는 시작 시각, 새 Linux 기록은 커널 boot ID·PID·시작 tick을 대조. in_progress 파일 수나 reserved 수와 다름. 다른 OS/host의 worker는 확인 불가 |
| 경과 시간 | 실행 확인된 worker의 시작부터 관측 시점까지. 작업의 실제 진척이나 provider 자식 프로세스 상태를 보증하지 않음 |
| 사용량 | 기존 provider/ledger 계약을 검사한 프로젝트 전체 보존 호출. 입력은 캐시 포함, 합계는 입력+출력. reserved/unknown은 별도 표시, 0으로 대체하지 않음 |
| 호출별/작업별 | 재시도 포함. 최근 100개 호출 표시, 총계는 전체 보존 기록. 브라우저에서 호출 ID·시각·provider·토큰 확인 |
| 한도 | 현재 정책과 다음 실행 제한 이유. 실제 비용·구독 잔여량 추정 및 실행 중 강제 종료 없음 |
| 검증 사이클 | latest_report의 마지막 완료 사이클 결과와 파일 갱신 시각. 실시간 단계 이벤트가 없으므로 현재 실행 단계로 표시하지 않음 |
| 승인 | status=requested인 요청 기록. 현재 HEAD와 승인 범위의 유효성은 기존 CLI에서 확인. 현황판에서 승인/병합 불가 |
| 최신성 | 수집 시각, 부분 수집, 실패/연결 끊김/일시 중지 표시. 수집 실패 시 이전 화면을 유지하며 오래된 상태임을 표시 |

## 보안·조회 범위

- 기존 `status` 명령의 보고서 저장/알림 기능을 호출하지 않습니다. 큐 복구, lease 획득, hook 설치, worker 실행, AI 호출, 승인 또는 Git 변경을 수행하지 않습니다.
- `127.0.0.1`에만 바인딩하고 정확한 Host/Origin, Fetch Metadata를 검사합니다. CORS를 허용하지 않으며 변경 메서드는 405입니다. 공개 서버나 사용자 인증 서비스가 아닙니다. 같은 OS 사용자의 다른 프로그램으로부터의 격리는 제공하지 않습니다.
- 정적 화면 3개와 고정 snapshot API만 제공하며 파일 다운로드/임의 경로/명령 실행 API는 없습니다. CSP와 `textContent`로 메타데이터를 코드로 해석하지 않습니다.
- 설정 경로의 프로젝트 경계와 symlink/junction을 검사합니다. raw prompt/provider 로그·실행 인수·환경 변수·credential은 반환하지 않습니다. 검증 로그는 로컬 해시 확인에만 사용합니다. 메타데이터의 흔한 토큰 형식만 마스킹하며 임의의 모든 비밀 문자열 탐지를 보장하지 않습니다.
- 파일당 2MiB, 수집 메타데이터 합계 32MiB, 디렉터리 목록당 2,000개·전체 열거 5,000개 제한입니다. 초과/손상/모호한 기록은 확인 불가 또는 부분 수집으로 표시합니다. 대규모 프로젝트용 증분 수집·페이지네이션은 후속입니다.
- 파일/디렉터리 변경과 queue journal을 검사하지만 전체 저장소의 트랜잭션 스냅샷은 아닙니다. 조회와 실제 실행 사이 상태는 바뀔 수 있으므로 이 화면은 실행/승인 권한의 근거가 아닙니다.
- Linux worker의 선택 필드 `worker_process_identity`는 벽시계 보정과 무관한 커널 식별자입니다. 구형 기록에는 기존 시작 시각 대조를 사용하며, 시계 변동으로 일치하지 않으면 확인 불가로 표시합니다. 이 필드는 실행·복구 권한이나 기존 worker 상태 전이를 변경하지 않습니다.

## 검증

```powershell
pwsh -NoProfile -File scripts/test_harness_dashboard.ps1
python -B scripts/test_harness_dashboard_server.py
```

첫 명령은 전체 `test_harness.ps1`에도 포함됩니다. HTTP 검사에는 로컬 소켓 사용 권한이 필요하며 제한된 sandbox 실패는 실제 OS 검증과 구분합니다. 브라우저 회귀 스크립트 `scripts/test_harness_dashboard_browser.js`는 실제 서버에 연결한 별도 Playwright CLI 브라우저에서 `run-code --filename`으로 실행합니다. 테스트 데이터는 그 브라우저의 응답만 대체하고 서버·프로젝트에 쓰지 않습니다.

후속: 명시적 실행/계획 범위 선택, 미배정 작업 분모, 실시간 단계 이벤트, 대규모 증분 수집. 작업 schema/DAG와 프로젝트별 검증 어댑터 개선은 별도 과제입니다.
