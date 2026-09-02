// 问问 · AI 模块单元测试（Action 层 / 解析 / 快照）
// 做法：从 index.html 里抠出真实函数源码来跑，不是照抄一份 —— 抄的那份改了没人知道。
const fs = require('fs');
const src = fs.readFileSync(__dirname + '/index.html', 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];

function grab(name){
  const i = src.indexOf('function ' + name + '(');
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

// ---- 桩：只提供被测函数真正用到的东西 ----
const CATS = [
  { id:'work', name:'工作', color:'#5b8aa6' },
  { id:'life', name:'生活', color:'#c2774f' },
  { id:'health', name:'健康', color:'#6f9b6e' },
  { id:'heart', name:'情感', color:'#b07a93' },
];
let TODAY = '2026-09-02';
const todayStr = () => TODAY;
const addDays = (s, n) => { const d = new Date(s + 'T00:00:00'); d.setDate(d.getDate() + n);
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; };
let _uid = 0;
const uid = () => 'u' + (++_uid);
const streak = () => 3;
const S = { tasks:[], habits:[], monthGoals:[], yearGoals:[] };
const AI = { snap:{ tasks:true, monthGoals:true, yearGoals:true, habits:true, stats:true },
             auto:{ date:'', count:0 } };

const code = [
  grabLine('const ACT_MAX ='),
  grab('normDate'),
  grabLine('const normCat ='),
  grab('applyActions'),
  grab('parseReply'),
  grab('buildSnapshot'),
  grabLine('const catName ='),
  'return { normDate, normCat, applyActions, parseReply, buildSnapshot };'
].join('\n');

const M = new Function('CATS','todayStr','addDays','uid','streak','S','AI', code)
  (CATS, todayStr, addDays, uid, streak, S, AI);

// ---- 断言 ----
let pass = 0, fail = 0;
function t(name, fn){
  try { fn(); console.log('  PASS  ' + name); pass++; }
  catch(e){ console.log('  FAIL  ' + name + '\n        ' + e.message); fail++; }
}
function eq(a, b, hint){
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if(sa !== sb) throw new Error((hint ? hint + ': ' : '') + sa + ' !== ' + sb);
}
function reset(){ S.tasks = []; S.habits = []; S.monthGoals = []; S.yearGoals = [];
                  AI.auto = { date:TODAY, count:0 }; _uid = 0; }

console.log('\n== 归一化 ==');
t('日期非法 → 今天', () => {
  eq(M.normDate('不是日期'), '2026-09-02');
  eq(M.normDate(''), '2026-09-02');
  eq(M.normDate(undefined), '2026-09-02');
});
t('过去的日期拉回今天', () => eq(M.normDate('2026-08-01'), '2026-09-02'));
t('今天和未来的日期原样过', () => {
  eq(M.normDate('2026-09-02'), '2026-09-02');
  eq(M.normDate('2026-09-10'), '2026-09-10');
});
t('分类非法 → life', () => {
  eq(M.normCat('work'), 'work');
  eq(M.normCat('不存在'), 'life');
  eq(M.normCat(null), 'life');
});

console.log('\n== Action 层：白名单 ==');
t('只认四个 type，其他丢弃', () => {
  reset();
  const r = M.applyActions([
    { type:'addTask', title:'买菜', date:'2026-09-05' },
    { type:'deleteTask', id:'x' },
    { type:'updateTask', id:'x' },
    { type:'addHabit', name:'喝水' },
  ]);
  eq(r.autoRun.length, 2);
  eq(r.dropped.length, 2);
  eq(r.dropped.every(d => /不认识/.test(d.why)), true);
});
t('非数组输入安全返回空', () => {
  eq(M.applyActions(null).autoRun.length, 0);
  eq(M.applyActions('x').dropped.length, 0);
  eq(M.applyActions({}).pending.length, 0);
});

console.log('\n== Action 层：校验与归一化 ==');
t('空标题丢弃，超长标题截断到 60 字', () => {
  reset();
  const r = M.applyActions([
    { type:'addTask', title:'   ', date:'2026-09-05' },
    { type:'addTask', title:'啊'.repeat(80), date:'2026-09-05' },
  ]);
  eq(r.autoRun.length, 1);
  eq(r.autoRun[0].row.title.length, 60);
  eq(r.dropped.length, 1);
});
t('非法分类兜底成 life', () => {
  reset();
  const r = M.applyActions([{ type:'addTask', title:'写周报', date:'2026-09-05', category:'瞎写' }]);
  eq(r.autoRun[0].row.category, 'life');
});
t('过去的日期拉回今天，且因此要人工确认', () => {
  reset();
  const r = M.applyActions([{ type:'addTask', title:'补昨天的事', date:'2026-08-01' }]);
  eq(r.autoRun.length, 0);
  eq(r.pending.length, 1);
  eq(r.pending[0].row.currentDate, '2026-09-02');
});

console.log('\n== Action 层：自动 vs 待确认 ==');
t('明天的任务自动执行，今天的任务待确认', () => {
  reset();
  const r = M.applyActions([
    { type:'addTask', title:'洗窗帘', date:'2026-09-03' },
    { type:'addTask', title:'买菜',   date:'2026-09-02' },
  ]);
  eq(r.autoRun.map(x => x.row.title), ['洗窗帘']);
  eq(r.pending.map(x => x.row.title), ['买菜']);
});
t('习惯 / 月目标 / 年目标默认自动', () => {
  reset();
  const r = M.applyActions([
    { type:'addHabit', name:'冥想' },
    { type:'addMonthGoal', title:'读完一本书' },
    { type:'addYearGoal', title:'身体健康' },
  ]);
  eq(r.autoRun.length, 3);
  eq(r.pending.length, 0);
});

console.log('\n== Action 层：去重与限流 ==');
t('同一天同标题才去重，不同天的周期任务放行', () => {
  reset();
  // 同一天同标题 → 跳过
  S.tasks.push({ id:'a', title:'买菜', currentDate:'2026-09-02', status:'todo' });
  const r1 = M.applyActions([{ type:'addTask', title:'买菜', date:'2026-09-02' }]);
  eq(r1.autoRun.length, 0);
  eq(r1.dropped[0].why.includes('买菜'), true);
  // 不同天（周期任务：倒垃圾/喝水）→ 放行，这恰恰是 AI 最该帮忙的场景
  const r2 = M.applyActions([{ type:'addTask', title:'买菜', date:'2026-09-05' }]);
  eq(r2.autoRun.length, 1);
  // 已做完的当天同名不应拦（用户做完一次想再排）——落到待确认让用户点头
  S.tasks.push({ id:'b', title:'喝水', currentDate:'2026-09-02', status:'done' });
  const r3 = M.applyActions([{ type:'addTask', title:'喝水', date:'2026-09-02' }]);
  eq(r3.pending.length, 1);
});
t('一轮超过 8 条截断，并说明原因', () => {
  reset();
  const many = [];
  for(let i = 0; i < 12; i++) many.push({ type:'addTask', title:'事' + i, date:'2026-09-05' });
  const r = M.applyActions(many);
  eq(r.autoRun.length, 8);
  eq(r.dropped.some(d => /最多 8 条/.test(d.why)), true);
});
t('每日自动配额 20 条，溢出降级为待确认而非静默丢弃', () => {
  reset();
  AI.auto = { date:TODAY, count:18 };
  const many = [];
  for(let i = 0; i < 8; i++) many.push({ type:'addTask', title:'事' + i, date:'2026-09-05' });
  const r = M.applyActions(many);
  eq(r.autoRun.length, 2);
  eq(r.pending.length, 6);
  eq(r.dropped.some(d => /够多了/.test(d.why)), true);
});
t('跨天后自动配额重置', () => {
  reset();
  AI.auto = { date:'2026-09-01', count:20 };
  const r = M.applyActions([{ type:'addTask', title:'新的一天', date:'2026-09-05' }]);
  eq(r.autoRun.length, 1);
  eq(AI.auto.count, 0);
});

console.log('\n== 回复解析 ==');
t('纯正文，没有 JSON', () => {
  const r = M.parseReply('今天排得有点满。');
  eq(r.text, '今天排得有点满。');
  eq(r.actions.length, 0);
});
t('围栏 JSON：取 reply 作正文，不念 JSON 原文', () => {
  const raw = '建议拆成三步。\n```json\n{"reply":"建议拆成三步。","actions":[{"type":"addTask","title":"列提纲","date":"2026-09-05"}]}\n```';
  const r = M.parseReply(raw);
  eq(r.text, '建议拆成三步。');
  eq(r.actions.length, 1);
  eq(r.actions[0].title, '列提纲');
  eq(r.text.includes('json'), false);
});
t('裸 JSON（模型忘了围栏）也能解析', () => {
  const r = M.parseReply('{"reply":"好","actions":[{"type":"addHabit","name":"跑步"}]}');
  eq(r.text, '好');
  eq(r.actions.length, 1);
});
t('JSON 坏了就整段当正文，不抛异常', () => {
  const r = M.parseReply('正文在这 {"reply":"坏了"');
  eq(typeof r.text, 'string');
  eq(r.text.length > 0, true);
});
t('空回复有兜底文案', () => {
  eq(M.parseReply('').text, '（那边回了句空话）');
});
t('actions 不是数组时忽略', () => {
  const r = M.parseReply('{"reply":"好","actions":"不是数组"}');
  eq(r.actions.length, 0);
});

console.log('\n== 快照 ==');
t('空数据也出得来，不报错', () => {
  reset();
  eq(typeof M.buildSnapshot(), 'string');
  eq(M.buildSnapshot().includes('今天还没排事'), true);
});
t('只列未完成，已完成的进计数不占行', () => {
  reset();
  S.tasks = [
    { id:'1', title:'待办的事', currentDate:TODAY, status:'todo', category:'work' },
    { id:'2', title:'已完成的事', currentDate:TODAY, status:'done', category:'work' },
    { id:'3', title:'跳过的事', currentDate:TODAY, status:'skipped', category:'work' },
  ];
  const s = M.buildSnapshot();
  eq(s.includes('待办的事'), true);
  eq(s.includes('已完成的事'), false);
  eq(s.includes('共 3 件，已完成 1，待办 1'), true);
});
t('任务超过 15 条时截断并说明还有多少', () => {
  reset();
  for(let i = 0; i < 20; i++)
    S.tasks.push({ id:'x'+i, title:'事'+i, currentDate:TODAY, status:'todo', category:'life' });
  const s = M.buildSnapshot();
  eq(s.includes('还有 5 件没列'), true);
});
t('快照开关关掉后对应段落消失', () => {
  reset();
  S.habits = [{ id:'h', name:'喝水', doneDates:[], freezesLeft:1 }];
  AI.snap = { tasks:true, monthGoals:true, yearGoals:true, habits:false, stats:true };
  eq(M.buildSnapshot().includes('【习惯】'), false);
  AI.snap = { tasks:true, monthGoals:true, yearGoals:true, habits:true, stats:true };
  eq(M.buildSnapshot().includes('【习惯】'), true);
});
t('快照里带 t1/t2 短引用，为后续结构化改期留口子', () => {
  reset();
  S.tasks = [{ id:'a', title:'买菜', currentDate:TODAY, status:'todo', category:'life' }];
  eq(M.buildSnapshot().includes('[t1]'), true);
});

console.log('\n结果: ' + pass + ' 通过, ' + fail + ' 失败\n');
process.exit(fail ? 1 : 0);
