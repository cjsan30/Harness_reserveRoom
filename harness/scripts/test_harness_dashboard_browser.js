// Run through playwright-cli run-code --filename. Use an isolated browser
// pointed at a real local dashboard server. Interactions use synthetic API
// responses only in this browser; project files and server state are untouched.
async page => {
  await page.unroute('**/api/snapshot');
  await page.reload();
  const errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  const assert=(condition,message)=>{if(!condition)throw new Error(message);};
  await page.locator('#project-name').filter({hasText:'Harness_Improvement'}).waitFor();
  await page.setViewportSize({width:1440,height:1100});
  await page.screenshot({path:'.test-output/dashboard-live-wide.png',fullPage:true});
  const emptyTitle=await page.locator('#project-name').innerText();
  assert(await page.locator('#attention').innerText().then(t=>t.includes('프로필')),'missing real empty state');
  const stamp=new Date().toISOString();
  const task={id:'task-01',owner:'tester',title:'<img src=x onerror=alert(1)> 스트리밍 구현',state:'in_progress',source_plan:'fixture.md',seed_task_key:'one',branch:'tester/stream',evidence:null,validated_at:null,attempts:2,known_tokens:120,unknown_usage_count:1};
  const fixture={schema_version:1,generated_at:stamp,collection_status:'ok',project:{name:'UI TEST DATA · 브라우저 검증용',configured:true,branch:'tester/stream',head:'abcdef0123456789'},summary:{total:3,passed:1,failed:1,queued:0,in_progress:1,unconfirmed:0,running_workers:1,approval_requests:1},tasks:[task,{...task,id:'task-02',title:'완료된 작업',state:'passed',evidence:'state/validation/example.json',validated_at:stamp},{...task,id:'task-03',title:'실패한 작업',state:'failed'}],workers:[{assignment_id:'task-01',provider:'codex',status:'running',started_at:stamp,observed_at:stamp}],approvals:[{id:'approval-1',source_branch:'test/candidate',source_head:'abcd',target_branch:'main',requested_at:stamp}],alerts:[{code:'usage_unknown',message:'미확정 사용량 1회',action:'완료 기록 확인'}],validation:{recorded_at:stamp,steps:[{name:'build',status:'pass'},{name:'unit',status:'pass'},{name:'integration',status:'fail'},{name:'benchmark_smoke',status:'not_run'}]},usage:{status:'ok',totals:{known_total_tokens:120,unknown_usage_count:1,invocation_count:2,completed_duration_seconds:4},input_tokens:100,output_tokens:20,policy:{max_total_tokens:5000},invocations:[{id:'fixture-call',assignment_id:'task-01',provider:'codex',attempt:1,usage_status:'known',input_tokens:100,output_tokens:20,reserved_at:stamp,completed_at:stamp}]}};
  await page.route('**/api/snapshot',route=>route.fulfill({json:{schema_version:1,snapshot:fixture,connection:{stale:false,error:null,age_seconds:0,refresh_seconds:10}}}));
  await page.locator('#refresh-button').click();
  await page.locator('#project-name').filter({hasText:'UI TEST DATA'}).waitFor();
  assert(await page.locator('#metric-tokens').innerText()==='120','usage total incorrect');
  assert(await page.locator('#tasks img').count()===0,'unsafe metadata became HTML');
  await page.locator('#tasks button').first().click();
  assert(await page.locator('#task-detail').isVisible(),'detail did not open');
  assert((await page.locator('#detail-fields').innerText()).includes('task-01'),'wrong task detail');
  await page.locator('#task-filter').selectOption('attention');
  assert(await page.locator('.task-row').count()===1,'attention filter incorrect');
  await page.locator('#task-filter').selectOption('all');
  if(!await page.locator('#invocations').isVisible())await page.locator('summary').click();
  assert(await page.locator('#invocations').isVisible(),'usage disclosure failed');
  await page.screenshot({path:'.test-output/dashboard-fixture-wide.png',fullPage:true});
  for(const width of [768,320]){
    await page.setViewportSize({width,height:950});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'horizontal overflow at '+width);
    await page.screenshot({path:'.test-output/dashboard-fixture-'+width+'.png',fullPage:true});
  }
  await page.locator('#auto-refresh').uncheck();
  assert((await page.locator('#connection').innerText()).includes('일시 중지'),'pause status missing');
  await page.unroute('**/api/snapshot');
  await page.route('**/api/snapshot',route=>route.abort());
  await page.locator('#refresh-button').click();
  await page.locator('#connection').filter({hasText:'연결 끊김'}).waitFor();
  assert((await page.locator('#project-name').innerText()).includes('UI TEST DATA'),'last snapshot lost');
  await page.unroute('**/api/snapshot');
  await page.locator('#refresh-button').click();
  await page.locator('#project-name').filter({hasText:emptyTitle}).waitFor();
  await page.locator('#auto-refresh').check();
  await page.setViewportSize({width:1440,height:1100});
  assert(errors.length===0,'browser runtime errors: '+errors.join('; '));
  return {passed:true,checks:['live empty state','task details','attention filter','XSS literal text','usage disclosure','768px layout','320px layout','pause','offline retention','reconnect','no runtime errors']};
}
