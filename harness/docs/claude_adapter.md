# Claude adapter 운영 계약

2026-10-15 일곱 번째 구현. `provider_claude.ps1`을 공통 provider v1에 연결했습니다. 이 문서는 실제 유료 호출을 실행한 검증 기록이 아닙니다. 격리된 fake 실행기로 계약을 검증하며 실제 계정·CLI 환경 검증은 남아 있습니다.

## 선택과 실행

대상 프로젝트의 `project/configs/project_profile.json`에서 다음과 같이 선택합니다. 이식 배치는 `harness/project/configs/project_profile.json`입니다. 개발 checkout에는 활성 프로필을 생성하지 않습니다.

```json
"worker_provider": { "version": 1, "name": "claude" }
```

기존 `scripts/harness.ps1 run`, seed/retry 명령과 `invoke_assignment_codex.ps1` 이름을 그대로 사용합니다. 이름과 달리 invoke는 프로필로 provider를 선택합니다. 기본 템플릿 및 worker_provider가 없는 기존 프로젝트는 Codex입니다. 실행 중인 worker의 provider를 바꾸지 말고 종료·확인 후 다음 실행에 적용하세요.

- 실행 파일은 `HARNESS_CLAUDE_PATH` 또는 PATH의 `claude`입니다. 명시적 경로가 없거나 미지원 provider이면 실행을 거부하며 다른 provider를 시도하지 않습니다.
- 기본 인수는 `--print --input-format text --output-format stream-json --verbose --permission-mode acceptEdits --permission-prompts none`입니다. 새 invocation이며 resume/continue는 전달하지 않습니다.
- `-Model`은 `--model`의 단일 인수로 전달하며, 생략·공백이면 CLI 설정에 맡깁니다. 실제 사용 모델을 추정하지 않습니다.
- `-Ephemeral`은 `--no-session-persistence`에 대응합니다. Harness의 감사 로그·worker·usage 기록까지 삭제하는 옵션은 아닙니다.
- prompt는 UTF-8 stdin, cwd는 Harness가 만든 isolated worktree입니다. worker host는 네이티브 프로세스의 UTF-8 입력·출력 인코딩을 명시합니다.
- `-DryRun`/`-PreflightOnly`는 기존처럼 진단 파일을 쓰고 `--version`을 조회할 수 있지만 작업자·사용량 예약은 만들지 않습니다. 단일 CLI의 `-Preview`는 하위 명령 자체를 실행하지 않습니다.

이 인수 구성은 [공식 CLI reference](https://code.claude.com/docs/en/cli-reference)와 [programmatic 실행 문서](https://code.claude.com/docs/en/headless)를 기준으로 했습니다. `--permission-prompts none`은 문서상 Claude Code 2.1.259 이상이 필요합니다. 지원하지 않는 CLI의 오류를 옵션 제거·권한 완화로 재시도하지 않습니다.

## 권한 정책

`acceptEdits`를 명시하고 추가 승인이 필요한 호출은 거부합니다. 권한 우회, 무제한 Bash 허용, 자동 승인 응답을 추가하지 않습니다. 대상의 기존 사용자·프로젝트·조직 권한 규칙 및 hooks/plugins 설정은 CLI가 읽습니다.

따라서 파일 편집 외에 build/test 및 `complete_assignment.ps1` 실행이 필요한 프로젝트는 **운영자가 해당 명령을 허용한 Claude 권한 정책**을 갖춰야 합니다. adapter는 이 정책을 생성하거나 넓히지 않습니다. 거부가 보고되면 보수적으로 해당 실행을 실패 처리하고 기존 예약·증거를 보존합니다. 이 설정은 OS sandbox나 Codex의 workspace-write와 같은 격리 보장이 아닙니다. 실제 사용 전 대상 CLI의 권한 정책과 운영 환경을 확인해야 합니다.

## 응답과 사용량

print stream의 단일 최종 `result`를 사용합니다. event type/subtype은 문자열이어야 하며 `subtype: success` 및 boolean `is_error: false`가 필요합니다. init에 session ID가 있으면 result와 일치해야 합니다. 중복 result, 손상 JSON, 누락 result, 잘못된 타입 또는 알 수 없는 subtype은 `response_status: unknown`, `execution_status: failed`, `error_kind: provider_protocol`입니다. 명시적 실패는 다른 성공보다 우선합니다.

`is_error: true`, `error_*` subtype, error 이벤트, 권한 거부 목록/이벤트, errors 목록, 완료가 아닌 terminal_reason은 실패입니다. 비정상 종료 코드는 `process_exit`으로 기록합니다. 원본 오류 문자열·credential은 정규화된 provider_result에 복사하지 않습니다. 원본 로그 자체의 범용 비밀값 필터링은 별도 과제입니다.

형식은 Anthropic의 [공식 SDK ResultMessage 정의](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/types.py)를 참고했습니다. CLI가 새 필드/형식을 추가하더라도 모르는 상태를 성공으로 추정하지 않습니다.

사용량은 최종 result.usage의 invocation aggregate만 읽고 assistant/delta/modelUsage를 다시 더하지 않습니다.

| Harness usage | Claude result.usage에서 계산 |
| --- | --- |
| input_tokens | input_tokens + cache_read_input_tokens + cache_creation_input_tokens |
| cached_input_tokens | cache_read_input_tokens (이미 위 입력 합계에 포함) |
| output_tokens | output_tokens |
| completed_turns | 유효한 최종 result 1건이면 1. 내부 num_turns가 아님 |
| source | claude.print.stream-json |

캐시 합산은 [공식 토큰 구분](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#tracking-cache-performance)을 따릅니다. 필수 수치 누락·음수·문자열·소수·boolean·정수 범위 초과 또는 실패 실행이면 사용량은 unknown/null입니다. 유효한 성공 응답에 usage만 빠진 경우 응답 성공과 usage unknown을 구분합니다. 금액·실제 모델·구독 잔여량은 추정하지 않습니다.

최종 성공 result의 문자열은 기존 `__last_message.txt`로 내보냅니다. 실패·누락이면 빈 내용으로 덮어써 과거 메시지를 현재 결과로 보여주지 않습니다. ledger에는 이 문자열을 저장하지 않습니다.

## 완료·예산·복구

provider 성공만으로 assignment를 완료하지 않습니다. 실제 validation과 코드/Git/log/invocation에 연결된 증거가 유효해야 합니다. 작업자가 먼저 pass를 만들었어도 이후 실패 또는 불완전 응답이면 invoke·복구·재검증은 성공을 거부합니다. Codex의 기존 텍스트 로그 호환 동작은 그대로이며 새 Claude에는 명시적 최종 응답이 필요합니다.

Codex와 Claude는 같은 프로젝트 예산·시도 기록을 공유합니다. provider를 바꿔도 토큰·시도 상한 및 unknown usage 차단이 초기화되지 않습니다. 다른 provider의 결과로 예약을 완료하려 하면 원래 예약을 보존한 채 거부합니다.

구형 provider_contract 없는 worker는 계속 Codex로 읽습니다. 새 Claude 기록은 metadata를 제거해 구형처럼 복구하지 마세요. 이전 Codex 전용 엔진으로 Claude 기록을 열면 미지원 provider로 거부됩니다. common/contract/Claude adapter/host/invoke를 함께 배포해야 합니다.

## 로컬 검증

```powershell
pwsh -NoProfile -File scripts/test_provider_claude.ps1
pwsh -NoProfile -File scripts/test_harness.ps1
```

unit·integration·security 범주를 결과 JSON에 기록합니다. 자세한 최종 실행 근거는 Claude 검증 기록, 공통 규칙은 [Provider 계약](provider_contract.md)을 참고하세요. 실제 유료 AI, 인증 변경, 외부 전송, 원격 CI는 이번 테스트에 포함하지 않습니다.
