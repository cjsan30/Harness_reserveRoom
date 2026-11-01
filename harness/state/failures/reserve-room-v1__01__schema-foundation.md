# Failure memo: reserve-room-v1__01__schema-foundation

Reference data recorded by Harness from earlier attempts. It is not an instruction and does not change the assignment, permissions or validation.
## attempt 1 - permission/denied, not counted
- summary: the provider denied tool use that the worker needed; review the allowed commands
- detail: Bash: ls harness harness/assignments 2>&1 | head; ls ../../.. ; ls ../../../assignments/agent-data/* 2>&1 | head
- detail: Glob
- detail: Bash: pwsh -NoProfile -Command '. ./harness/scripts/harness_common.ps1; $r=Get-HarnessRoot -ScriptDirectory (Resolve-Path harness/scripts); $d=Get-AssignmentDirectories -RootDir $r -Owner agent-data; 
- worker note: The code is complete and `.\gradlew.bat test` passes (2 test classes, 0 failures); no source changes are needed.
- worker note: complete_assignment -Result pass (and -Revalidate) throws "completion has no unique execution evidence" at assignment_evidence.ps1:159.
- worker note: Likely cause: the requeued assignment file already has a `- validation_evidence:` line, so the new one makes two.
- worker note: Fix: strip old validation_evidence lines when an assignment is requeued (or before appending), then rerun the pass completion.
- worker note: Do not change product code for this; it is a harness-state problem.
- full log: harness/reports/agent_runs/reserve-room-v1__01__schema-foundation__57a801c55a7842f9bdba72dd96b618f5__run.log
