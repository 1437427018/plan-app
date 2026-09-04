// 端到端冒烟：真实抽取 index.html 里的 aiSend → callLLM → parseReply →
// applyActions → aiInsertAll → syncInsertMany 链路，验证「自动加计划真落库」。
// 做法：用 grab() 抠真实函数源码，只桩住 happy path 碰不到的东西
// （byId 返回 null → renderChat/scrollChat 直接 return；save/flushPending 空操作）。
const fs = require('fs');
const html = fs.readFileSync(__dirname + '/index.html', 'utf8');
const src = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function grab(name){
  // 先找 async function（含 async 前缀），找不到再退回普通 function
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

const TODAY = '2026-09-02';
// 本地时区格式化：不能用 toISOString()，UTC 在 GMT+8 下会把日期算成前一天
function fmtLocal(d){ return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; }
function addDays(s, n){ const d = new Date(s + 'T00:00:00'); d.setDate(d.getDate() + n); return fmtLocal(d); }
const FUTURE = addDays(TODAY, 8); // 未来 → 自动执行

// ---- 桩：状态 + 只供 happy path 用到的东西 ----
const head = `
const TODAY = ${JSON.stringify(TODAY)};
const todayStr = () => TODAY;
const addDays = (s,n)=>{ const d=new Date(s+'T00:00:00'); d.setDate(d.getDate()+n); return \`\${d.getFullYear()}-\${String(d.getMonth()+1).padStart(2,'0')}-\${String(d.getDate()).padStart(2,'0')}\`; };
let _u=0; const uid=()=>'u'+(++_u);
const streak=()=>3;
const CATS=[{id:'work',name:'工作'},{id:'life',name:'生活'},{id:'health',name:'健康'},{id:'heart',name:'情感'}];
const PERSONAS=[{id:'blunt',name:'直说',sys:'x',desc:'y'},{id:'butler',name:'总管事',sys:'z',desc:'w'}];
const S={tasks:[],habits:[],monthGoals:[],yearGoals:[],pendingDeletes:[]};
const AI={curId:'c1',configs:[{id:'c1',name:'测试',base:'https://api.example.com/v1',key:'k',model:'m'}],persona:'blunt',personaCustom:'',snap:{tasks:true,monthGoals:true,yearGoals:true,habits:true,stats:true},auto:{date:TODAY,count:0}};
let chat=[];
let chatSig='';
const AI_CHAT='planapp_ai_chat';
let aiBusy=false;
let aiUserAbort=false;
let aiAbort=null;
const esc=s=>String(s==null?'':s);
const isUuid=()=>true;
const save=()=>{};
const flushPending=async()=>{};
const aiSave=()=>{};
const toast=()=>{};
const byId=()=>null;
const svg=(d,w)=>'';
const localOpen=()=>false;
const ACTION_SPEC='ACTION_SPEC';
`;

const parts = [
  head,
  grabLine('const ACT_MAX ='),
  grab('normDate'),
  grabLine('const normCat ='),
  grab('applyActions'),
  grab('parseReply'),
  grab('buildSnapshot'),
  grabLine('const catName ='),
  grab('syncInsertMany'),
  grab('aiInsertAll'),
  grabLine('const curCfg ='),
  grabLine('const aiReady ='),
  grab('aiBuildBody'),
  grab('personaSys'),
  grabLine('const chatUrl ='),
  grab('callLLM'),
  grab('chatSave'),
  grab('renderChat'),
  grab('scrollChat'),
  grab('aiSend'),
  `return { aiSend, aiReady, applyActions, parseReply, buildSnapshot,
            getS:()=>S, getAI:()=>AI, getChat:()=>chat };`
].join('\n');

const T = new Function(parts)();

// ---- 全局桩 ----
global.AbortController = global.AbortController || class {
  constructor(){ this.signal = { aborted:false }; }
  abort(){ this.signal.aborted = true; }
};
global.navigator = { onLine: true };
global.location = { protocol: 'https:' };
const store = {};
global.localStorage = {
  getItem: k => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); },
  removeItem: k => { delete store[k]; },
};

function mkFetch(ok, status, content){
  return async () => ({
    ok, status,
    async text(){ return JSON.stringify({ choices:[{ message:{ content } }] }); }
  });
}
// 成功回复：正文 + 围栏 JSON，date 指向 FUTURE（未来 → 自动执行）
const okContent = (date) =>
  '好，我帮你排上。\n```json\n{"reply":"好，我帮你排上。","actions":' +
  '[{"type":"addTask","title":"倒垃圾","date":"' + date + '"}]}\n```';

let pass = 0, fail = 0;
function t(name, fn){
  return (async () => {
    try { await fn(); console.log('  PASS  ' + name); pass++; }
    catch(e){ console.log('  FAIL  ' + name + '\n        ' + e.message); fail++; }
  })();
}
function eq(a, b, hint){
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if(sa !== sb) throw new Error((hint ? hint + ': ' : '') + sa + ' !== ' + sb);
}
function reset(){
  const S = T.getS();
  S.tasks = []; S.habits = []; S.monthGoals = []; S.yearGoals = []; S.pendingDeletes = [];
  const AI = T.getAI();
  AI.auto = { date: TODAY, count: 0 };
  T.getChat().length = 0;
}

(async () => {
  console.log('\n== E2E：aiSend 全链路 ==');

  // 1) 未来日期 → 自动落库 + 配额 +1
  await t('明天的任务自动加进 S.tasks，且 AI.auto.count=1', async () => {
    reset();
    global.fetch = mkFetch(true, 200, okContent(FUTURE));
    const S = T.getS(), AI = T.getAI();
    eq(S.tasks.length, 0, '前置');
    eq(AI.auto.count, 0, '前置');
    await T.aiSend('帮我排明天倒垃圾');
    eq(S.tasks.length, 1, '应落 1 条');
    eq(S.tasks[0].title, '倒垃圾', '标题');
    eq(S.tasks[0].currentDate, FUTURE, '日期应为未来');
    eq(AI.auto.count, 1, '配额 +1');
    const last = T.getChat()[T.getChat().length - 1];
    eq(last.role, 'them', '最后一条是对方');
    eq(last.text, '好，我帮你排上。', '正文');
    eq(last.auto && last.auto.state, 'done', '自动条 state');
  });

  // 2) 今天的任务 → 走待确认，不落库
  await t('今天的任务走待确认（prop），不自动落库', async () => {
    reset();
    global.fetch = mkFetch(true, 200, okContent(TODAY));
    const S = T.getS();
    await T.aiSend('帮我排今天倒垃圾');
    eq(S.tasks.length, 0, '今天的不该自动落库');
    const last = T.getChat()[T.getChat().length - 1];
    eq(last.prop && last.prop.state, 'pending', '应为待确认');
    eq(last.prop.items.length, 1, '提案 1 条');
  });

  // 3) 401 → 渲染错误气泡，不崩
  await t('Key 错（401）→ 落错误消息，S 不受影响', async () => {
    reset();
    global.fetch = mkFetch(false, 401, JSON.stringify({ error:{ message:'invalid' } }));
    const S = T.getS();
    await T.aiSend('你好');
    eq(S.tasks.length, 0, '不应落库');
    const last = T.getChat()[T.getChat().length - 1];
    eq(last.err, 'auth', '应标记 auth');
  });

  // 4) 纯文本无 JSON → 只聊天，不动作
  await t('纯文本无动作 → 只回话，不落库', async () => {
    reset();
    global.fetch = mkFetch(true, 200, '今天排得有点满。');
    const S = T.getS();
    await T.aiSend('今天怎么排');
    eq(S.tasks.length, 0, '不应落库');
    const last = T.getChat()[T.getChat().length - 1];
    eq(last.text, '今天排得有点满。', '正文');
    eq(!!last.auto, false, '无自动条');
    eq(!!last.prop, false, '无提案');
  });

  // 5) aiReady 守卫
  await t('aiReady 在未配置时返回 false', async () => {
    const AI = T.getAI();
    const bak = AI.configs; AI.configs = [];
    eq(T.aiReady(), false, '无配置应 false');
    AI.configs = bak;
    eq(T.aiReady(), true, '有配置应 true');
  });

  console.log('\n结果: ' + pass + ' 通过, ' + fail + ' 失败\n');
  process.exit(fail ? 1 : 0);
})();
