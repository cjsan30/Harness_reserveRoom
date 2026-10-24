'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const labels = {passed:'증거 확인 완료', failed:'실패', queued:'대기', in_progress:'진행 중', unconfirmed:'상태 확인 필요', unverified:'완료 미검증', running:'실행 확인', exited:'종료 기록', pass:'통과', fail:'실패', skipped:'건너뜀', not_run:'미실행', unknown:'확인 불가', known:'확정', pending:'집계 대기'};
  const stages = {build:'빌드', unit:'유닛 테스트', integration:'통합 테스트', benchmark_smoke:'스모크 테스트'};
  let snapshot=null, selected=null, busy=false, timer=null, lastReceived=0, requestFailed=false;
  const number = value => typeof value==='number' && Number.isFinite(value) ? value.toLocaleString('ko-KR') : '—';
  const date = value => { if (!value) return '—'; const d=new Date(value); return Number.isNaN(d.getTime())?'—':d.toLocaleString('ko-KR'); };
  function node(tag,text,className){const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(className)n.className=className;return n;}
  function badge(value){const kind=['passed','pass','known'].includes(value)?'good':['running','in_progress'].includes(value)?'active':['fail','failed'].includes(value)?'bad':'warn';return node('span',labels[value]||'확인 불가','badge '+kind);}
  function empty(container,text){container.replaceChildren(node(['OL','UL'].includes(container.tagName)?'li':'p',text,'empty'));}
  function detail(task){
    selected=task.id;$('task-detail').hidden=false;$('detail-title').textContent=task.title||task.id;
    const fields=[['작업 ID',task.id],['상태',labels[task.state]],['담당',task.owner],['브랜치',task.branch||'기록 없음'],['계획',task.source_plan||'기록 없음'],['호출 ID',task.worker?.invocation_id||'기록 없음'],['관측 시점 경과',task.worker?.elapsed_seconds!=null?number(task.worker.elapsed_seconds)+'초':'—'],['호출 횟수',number(task.attempts)],['확인된 토큰',number(task.known_tokens)],['미확정 호출',number(task.unknown_usage_count)],['검증 시각',date(task.validated_at)],['증거 파일',task.evidence||'유효한 완료 증거 없음']];
    $('detail-fields').replaceChildren(...fields.flatMap(([key,value])=>[node('dt',key),node('dd',value)]));
  }
  function renderTasks(){
    if(!snapshot)return;
    const mode=$('task-filter').value;
    const tasks=snapshot.tasks.filter(task=>mode==='all'||(mode==='attention'?['failed','unconfirmed','unverified'].includes(task.state):task.state===mode));
    const container=$('tasks');container.replaceChildren();
    if(!tasks.length)empty(container,snapshot.tasks.length?'선택한 상태의 작업이 없습니다.':'등록된 작업이 없습니다. 대상 프로젝트에서 작업을 배정하면 여기에 표시됩니다.');
    tasks.forEach(task=>{
      const row=node('div',undefined,'task-row'),body=node('div'),button=node('button',task.title||task.id);
      button.type='button';button.setAttribute('aria-controls','task-detail');button.addEventListener('click',()=>detail(task));
      body.append(button,node('small',task.owner+' · '+task.id));row.append(body,badge(task.state));container.append(row);
    });
    const task=snapshot.tasks.find(t=>t.id===selected);if(task)detail(task);else $('task-detail').hidden=true;
  }
  function render(data){
    snapshot=data;const s=data.summary,p=data.project;
    $('project-name').textContent=p?.name||'프로젝트 상태 확인 필요';
    $('project-meta').textContent=[p?.configured?'프로필 연결됨':'프로필 미설정',p?.branch||'브랜치 미확인',p?.head?.slice(0,10)||'커밋 미확인'].join(' · ');
    const complete=data.collection_status==='ok';
    $('metric-progress').textContent=number(s.passed)+' / '+number(s.total)+(complete?'':' · 일부 기록');
    $('progress').value=complete&&s.total?s.passed/s.total*100:0;
    $('progress-note').textContent=complete?'계획 전체가 아닌 보존된 작업 큐 기준':'수집이 불완전하여 완료율을 계산하지 않습니다.';
    $('metric-workers').textContent=number(s.running_workers)+(complete?'':' · 일부 기록');
    $('metric-approvals').textContent=data.alerts.some(a=>a.code==='approvals_invalid'||a.code==='collection_failed')?'—':number(s.approval_requests);
    const u=data.usage,valid=u?.status==='ok';
    $('metric-tokens').textContent=valid?number(u.totals.known_total_tokens):'확인 불가';
    $('usage-note').textContent=valid?'미확정 '+number(u.totals.unknown_usage_count)+'회 · 총 '+number(u.totals.invocation_count)+'회 호출':'사용량 기록을 집계하지 못했습니다.';
    $('task-summary').textContent='완료 '+s.passed+' · 진행 '+s.in_progress+' · 대기 '+s.queued+' · 실패 '+s.failed+' · 확인 필요 '+s.unconfirmed;
    renderTasks();
    const attention=$('attention');attention.replaceChildren();
    const messages=[...data.alerts,...data.approvals.map(a=>({message:'승인 요청: '+a.source_branch+' → '+a.target_branch,action:'요청 '+a.id+' · '+date(a.requested_at)+'. 현재 변경과 승인 범위를 CLI에서 확인하세요.'})),...data.tasks.filter(t=>['failed','unconfirmed','unverified'].includes(t.state)).map(t=>({message:(t.title||t.id)+' · '+labels[t.state],action:'작업 상세와 로컬 실행 증거를 확인하세요.'}))];
    if(!messages.length)empty(attention,'현재 기록에서 확인할 항목이 발견되지 않았습니다.');
    messages.forEach(item=>{const row=node('div',undefined,'alert');row.append(node('strong',item.message),node('p',item.action,'muted'));attention.append(row);});
    const validation=$('validation');validation.replaceChildren();
    if(data.validation){data.validation.steps.forEach(step=>{const row=node('li');row.append(node('span',stages[step.name]||step.name),badge(step.status));validation.append(row);});$('validation-time').textContent='기록 갱신: '+date(data.validation.recorded_at);}
    else{empty(validation,'검증 사이클 기록이 없습니다.');$('validation-time').textContent='';}
    const usage=$('usage-summary');usage.replaceChildren();
    const values=[['입력 · 캐시 포함',valid?number(u.input_tokens):'—'],['출력',valid?number(u.output_tokens):'—'],['누적 worker 실행 시간',valid?number(Math.round(u.totals.completed_duration_seconds))+'초':'—'],['토큰 시작 제한',valid&&u.policy?.max_total_tokens!==null&&u.policy?.max_total_tokens!==undefined?number(u.policy.max_total_tokens):'설정 없음 / 확인 불가'],['구독 잔여량 / 청구액','조회하지 않음']];
    values.forEach(([label,value])=>{const el=node('div');el.append(node('small',label),node('div',value,'usage-value'));usage.append(el);});
    const calls=$('invocations');calls.replaceChildren();
    if(valid)u.invocations.slice().sort((a,b)=>String(b.reserved_at).localeCompare(String(a.reserved_at))).slice(0,100).forEach(call=>{const row=node('tr'),id=node('td',call.assignment_id);id.append(node('small',call.id));row.append(id,node('td',call.provider),node('td',number(call.attempt)),node('td',labels[call.usage_status]||'확인 불가'),node('td',number(call.input_tokens)),node('td',number(call.output_tokens)),node('td',date(call.completed_at||call.reserved_at)));calls.append(row);});
    if(!calls.children.length){const row=node('tr'),cell=node('td',valid?'호출 기록이 없습니다.':'호출 내역을 읽을 수 없습니다.');cell.colSpan=7;row.append(cell);calls.append(row);}
    const workers=$('workers');workers.replaceChildren();
    if(!data.workers.length)empty(workers,'worker 실행 기록이 없습니다. 진행 중인 작업 파일만으로 가동 중이라고 표시하지 않습니다.');
    data.workers.forEach(worker=>{const row=node('div',undefined,'worker-row'),text=node('div',worker.assignment_id+' · '+worker.provider);text.append(node('small','시작 '+date(worker.started_at)+' · 관측 '+date(worker.observed_at)));row.append(text,badge(worker.status));workers.append(row);});
  }
  async function refresh(){
    if(busy)return;busy=true;$('refresh-button').disabled=true;
    const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),8000);
    try{
      const response=await fetch('/api/snapshot',{cache:'no-store',signal:controller.signal});
      if(!response.ok)throw new Error('fetch failed');
      const result=await response.json();lastReceived=Date.now();requestFailed=false;
      if(result.snapshot)render(result.snapshot);
      const c=result.connection;
      $('connection').className='connection'+(c.stale||snapshot?.collection_status==='partial'?' error':'');
      $('connection').textContent=c.error||(result.snapshot?('마지막 수집 '+date(result.snapshot.generated_at)+(c.stale?' · 오래된 기록':'')+(result.snapshot.collection_status==='partial'?' · 일부 기록 확인 필요':'')):'첫 번째 상태 수집을 기다리고 있습니다.');
    }catch{requestFailed=true;$('connection').className='connection error';$('connection').textContent='연결 끊김 · 마지막 수집 화면을 유지합니다. 서버 실행 상태를 확인하세요.';}
    finally{clearTimeout(timeout);busy=false;$('refresh-button').disabled=false;}
  }
  function schedule(){clearInterval(timer);timer=null;if($('auto-refresh').checked)timer=setInterval(refresh,5000);}
  $('task-filter').addEventListener('change',renderTasks);
  $('refresh-button').addEventListener('click',refresh);
  $('auto-refresh').addEventListener('change',()=>{schedule();if($('auto-refresh').checked)refresh();else{$('connection').textContent='자동 갱신 일시 중지 · 마지막 수집 '+date(snapshot?.generated_at);$('connection').className='connection error';}});
  document.addEventListener('visibilitychange',()=>{if(!document.hidden&&$('auto-refresh').checked)refresh();});
  setInterval(()=>{if(!requestFailed&&lastReceived&&Date.now()-lastReceived>65000){$('connection').className='connection error';$('connection').textContent='갱신되지 않은 화면 · 마지막 수집 '+date(snapshot?.generated_at);}},5000);
  schedule();refresh();
})();
