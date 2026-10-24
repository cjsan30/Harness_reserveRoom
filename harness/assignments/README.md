# Assignments

이 디렉터리는 owner별 작업 큐다.

구조:

```text
assignments/
  agent-runtime/
    inbox/
    in_progress/
    done/
  agent-query/
    inbox/
    in_progress/
    done/
  agent-storage/
    inbox/
    in_progress/
    done/
  agent-index/
    inbox/
    in_progress/
    done/
  agent-tests/
    inbox/
    in_progress/
    done/
  manager-main/
    inbox/
    in_progress/
    done/
  manager-harness/
    inbox/
    in_progress/
    done/
```

흐름:

1. dispatch가 `inbox/`에 assignment를 생성
2. owner가 claim하면 `in_progress/`로 이동
3. owner가 complete하면 `done/`으로 이동
