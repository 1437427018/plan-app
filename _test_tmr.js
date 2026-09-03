// 明日计划单元测试：从 index.html 抠真实函数来跑（沿用 _test_ai.js 的做法）。
// 覆盖：tomorrows() 筛选、卡片计数/空态、日期徽标、折叠、展开全部。
const fs = require('fs');
const src = fs.readFileSync(__dirname + '/index.html', 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];

function grab(name){
  let i = src.indexOf('async function ' + name + '(');
  if(i < 0) i = src.indexOf('function ' + name + '(');
  if(i < 0) throw new Error('找不到函数: ' + name);
  let d = 0;
  for(let k = src.indexOf('{', i); k < src.length; k++){
    if(src[k] === '{') d++;
    else if(src[k] === '}' && --d === 0) return src.slice(i, k + 1);
  }
  throw new Error('括号没配平: ' + name);
}
function grabLine(prefix){
  const i = src.indexOf(prefix);
  if(i < 0) throw new Error('找不到: ' + prefix);
  return src.slice(i, src.indexOf('\n', i));
}

// ---- 桩：被测函数真正用到的东西 ----
const TODAY = '2026-09-03';
const head = `
const TODAY = ${JSON.stringify(TODAY)};
const todayStr = () => TODAY;
// 注意：addDays 必须用本地时区（getFullYear/getMonth/getDate），
// 不能用 toISOString() —— 后者按 UTC 算，GMT+8 下会把日期算成前一天。
const addDays = (s,n)=>{ const d=new Date(s+'T00:00:00'); d.setDate(d.getDate()+n); return \`\${d.getFullYear()}-\${String(d.getMonth()+1).padStart(2,'0')}-\${String(d.getDate()).padStart(2,'0')}\`; };
const esc = s => String(s==null?'':s);
let _u = 0; const uid = () => 'u' + (++_u);
const CATS = [{id:'work',name:'工作',color:'#5b8aa6'},{id:'life',name:'生活',color:'#c2774f'}];
const S = { tasks:[], cleared:{} };
let tmrOpen = null;
let tmrAll  = false;
`;

const code = [
  head,
  grabLine('const weekday ='),
  grab('tomorrows'),
  grab('taskRow'),
  grab('viewTomorrowCard'),
  `return { tomorrows, taskRow, viewTomorrowCard, weekday,
            getS:()=>S, setTmr:(o,a)=>{ tmrOpen=o; tmrAll=a; },
            tomorrowDate:()=>addDays(todayStr(),1) };`
].join('\n');

const M = new Function(code)();

let pass = 0, fail = 0;
function t(name, fn){
  try { fn(); console.log('  PASS  ' + name); pass++; }
  catch(e){ console.log('  FAIL  ' + name + '\n        ' + e.message); fail++; }
}
function eq(a, b, hint){
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if(sa !== sb) throw new Error((hint ? hint + ': ' : '') + sa + ' !== ' + sb);
}
function ok(v, msg){ if(!v) throw new Error(msg || '期望为真'); }
const count = (s, sub) => s.split(sub).length - 1;

// 本地时区格式化（不能用 toISOString，UTC 差一天）
const fmtLocal = d => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
const tmr = M.tomorrowDate();
const dayAfter = (() => { const d = new Date(TODAY + 'T00:00:00'); d.setDate(d.getDate() + 2);
  return fmtLocal(d); })();

function reset(){
  const S = M.getS();
  S.tasks = []; S.cleared = {};
  M.setTmr(null, false);
}
// 造一条 task
function mk(title, date, status){
  return { id:'t' + Math.random().toString(36).slice(2,7), title, status,
           category:'life', createdDate:TODAY, currentDate:date, originalDate:date,
           doneTime:null, delayCount:0 };
}

console.log('\n== tomorrows() 筛选 ==');
t('只认明天，且只认 todo/delayed', () => {
  reset();
  const S = M.getS();
  S.tasks.push(
    mk('明天的待办', tmr, 'todo'),
    mk('明天的延期', tmr, 'delayed'),
    mk('明天的已完成', tmr, 'done'),
    mk('明天的偷懒', tmr, 'skipped'),
    mk('今天的待办', TODAY, 'todo'),
    mk('后天的待办', dayAfter, 'todo'),
  );
  const r = M.tomorrows().map(x => x.title);
  // 用包含判断而不是比数组：中文字面排序随码点走，写死顺序反而脆
  eq(r.length, 2, '只应有 2 条');
  ok(r.includes('明天的待办'), '应含明天的待办');
  ok(r.includes('明天的延期'), '应含明天的延期（延期也是还没交代的明天）');
  ok(!r.includes('今天的待办'), '不该含今天的');
  ok(!r.includes('后天的待办'), '不该含后天的');
  ok(!r.includes('明天的已完成'), '不该含已完成的');
  ok(!r.includes('明天的偷懒'), '不该含偷懒的');
});
t('空数据返回空数组', () => { reset(); eq(M.tomorrows().length, 0); });

console.log('\n== 卡片渲染 ==');
t('明天没安排：露空态引导 + 添加框，header 写「还没安排」', () => {
  reset(); M.setTmr(true, false);
  const h = M.viewTomorrowCard();
  ok(h.includes('明天的计划 · 还没安排'), 'header 应写还没安排');
  ok(h.includes('睡前想好明天做哪几件'), '应有引导文案');
  ok(h.includes('id="newTaskTmr"'), '应露出添加框');
  ok(h.includes('加一件明天要做的事'), 'placeholder 应为明天');
  ok(!h.includes('class="task '), '空态不该渲染任务行');
});
t('有安排：header 写件数，每行带「明天 · 周X」徽标', () => {
  reset();
  const S = M.getS();
  S.tasks.push(mk('买菜', tmr, 'todo'), mk('洗窗帘', tmr, 'todo'));
  M.setTmr(true, false);
  const h = M.viewTomorrowCard();
  ok(h.includes('明天的计划 · 2 件'), 'header 应写 2 件');
  eq(count(h, 'class="task '), 2, '应渲染 2 行');
  eq(count(h, 'class="date-badge"'), 2, '每行一个徽标');
  ok(/明天 · 周[日一二三四五六]/.test(h), '徽标文案格式');
});
t('徽标里的周X算对了', () => {
  reset();
  const S = M.getS();
  S.tasks.push(mk('买菜', tmr, 'todo'));
  M.setTmr(true, false);
  const h = M.viewTomorrowCard();
  const expect = M.weekday(tmr);
  ok(h.includes('明天 · 周' + expect), '徽标周X应为 ' + expect);
});

console.log('\n== 折叠 / 展开全部 ==');
t('折叠时不渲染内容区，只留 header', () => {
  reset();
  const S = M.getS();
  S.tasks.push(mk('买菜', tmr, 'todo'));
  M.setTmr(false, false);
  const h = M.viewTomorrowCard();
  ok(h.includes('tmr-head'), '应有 header');
  ok(!h.includes('tmr-body'), '折叠时不该有内容区');
  ok(!h.includes('newTaskTmr'), '折叠时不该有添加框');
});
t('超过 3 条：默认只看 3 条 + 「展开全部 N 件」', () => {
  reset();
  const S = M.getS();
  for(let i = 1; i <= 5; i++) S.tasks.push(mk('事' + i, tmr, 'todo'));
  M.setTmr(true, false);
  const h = M.viewTomorrowCard();
  eq(count(h, 'class="task '), 3, '默认只渲染 3 条');
  ok(h.includes('展开全部 5 件'), '应给出展开入口');
});
t('展开全部后：5 条全出，不再有展开按钮', () => {
  reset();
  const S = M.getS();
  for(let i = 1; i <= 5; i++) S.tasks.push(mk('事' + i, tmr, 'todo'));
  M.setTmr(true, true);
  const h = M.viewTomorrowCard();
  eq(count(h, 'class="task '), 5, '应渲染全部 5 条');
  ok(!h.includes('展开全部'), '不该再有展开按钮');
});

console.log('\n== 复用既有体系（不新增存储）==');
t('卡片里的行就是 taskRow，带 data-id 供既有 .task 绑定', () => {
  reset();
  const S = M.getS();
  S.tasks.push(mk('买菜', tmr, 'todo'));
  M.setTmr(true, false);
  const h = M.viewTomorrowCard();
  ok(h.includes('data-id="' + S.tasks[0].id + '"'), '应带上真实 task id');
  ok(h.includes('data-act="toggle"'), '应有状态圆圈（走既有绑定）');
  ok(h.includes('data-act="del"'), '应有删除（走既有绑定）');
});

console.log('\n结果: ' + pass + ' 通过, ' + fail + ' 失败\n');
process.exit(fail ? 1 : 0);
