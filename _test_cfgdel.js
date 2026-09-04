// 配置面板「删掉这套」按钮的复现测试
// 做法同其它套件：从 index.html 抠真实函数源码来跑，不照抄。
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
// AI_PROVIDERS 是多行数组，grab 的括号匹配不适用，单独用方括号匹配
function grabBracket(prefix){
  const i = src.indexOf(prefix);
  if(i < 0) throw new Error('找不到: ' + prefix);
  const s = src.indexOf('[', i);
  let d = 0;
  for(let k = s; k < src.length; k++){
    if(src[k] === '[') d++;
    else if(src[k] === ']' && --d === 0) return src.slice(i, k + 1) + ';';
  }
  throw new Error('方括号没配平: ' + prefix);
}

// ---- 桩 ----
let _uid = 0;
const uid = () => 'id' + (++_uid);
const esc = s => String(s == null ? '' : s);
const svg = () => '<svg/>';
const I_EYE = 'eye';
const toast = () => {};
const closeSheet = () => {};
const render = () => {};
let saved = 0;
const aiSave = () => { saved++; };
const testConn = async () => ({ ok:true, ms:1, sample:'在' });
const aiTestHtml = r => (r.ok ? '通了' : '不通');

let lastHtml = '';
const els = {};
function mkEl(id){
  return { id, value:'', type:'', innerHTML:'', onclick:null,
           selectedOptions:[{ textContent:'智谱 GLM · 免费', value:'zhipu' }],
           classList:{ add(){}, remove(){}, toggle(){} } };
}
function openSheet(html){
  lastHtml = html;
  // 模拟浏览器：innerHTML 注入后，这些 id 就可通过 getElementById 拿到
  for(const m of html.matchAll(/id="([^"]+)"/g)){
    const id = m[1];
    if(!els[id]) els[id] = mkEl(id);
    els[id].onclick = null;      // 每次重开都是全新元素
  }
}
const byId = id => els[id] || null;

const code = [
  grabBracket('const AI_PROVIDERS ='),
  grab('aiCfgSheet'),
  'return { aiCfgSheet };'
].join('\n');

const M = new Function('uid','esc','svg','I_EYE','toast','closeSheet','render','aiSave',
                       'testConn','aiTestHtml','byId','openSheet','AI', code)
  (uid, esc, svg, I_EYE, toast, closeSheet, render, aiSave,
   testConn, aiTestHtml, byId, openSheet, null);

// AI 是 aiCfgSheet 闭包里会直接改写的对象，必须外面传进去
const AI = { configs:[], curId:null, persona:'blunt' };
const run = new Function('uid','esc','svg','I_EYE','toast','closeSheet','render','aiSave',
                         'testConn','aiTestHtml','byId','openSheet','AI', code)
  (uid, esc, svg, I_EYE, toast, closeSheet, render, aiSave,
   testConn, aiTestHtml, byId, openSheet, AI);

let pass = 0, fail = 0;
function t(name, fn){
  try { fn(); console.log('  PASS  ' + name); pass++; }
  catch(e){ console.log('  FAIL  ' + name + '\n        ' + e.message); fail++; }
}
function reset(){
  _uid = 0; saved = 0; lastHtml = '';
  AI.configs = []; AI.curId = null;
  Object.keys(els).forEach(k => delete els[k]);
}
function mkCfg(name, model){
  const c = { id: uid(), name, provider:'zhipu',
              base:'https://open.bigmodel.cn/api/paas/v4', key:'sk-test', model };
  AI.configs.push(c);
  return c;
}

console.log('\n== 删除按钮：正常路径 ==');

t('编辑已有配置时，按钮确实渲染出来了', () => {
  reset();
  const a = mkCfg('智谱', 'glm-4.7-flash');
  run.aiCfgSheet(a.id);
  if(!lastHtml.includes('cfDel')) throw new Error('HTML 里没有 cfDel 按钮');
  if(lastHtml.includes('cfCancel')) throw new Error('不该出现「取消」（那是新建态的按钮）');
});

t('点删除 → 这套真的没了', () => {
  reset();
  const a = mkCfg('智谱', 'glm-4.7-flash');
  const b = mkCfg('备用', 'glm-4-flash-250414');
  AI.curId = a.id;
  run.aiCfgSheet(a.id);
  els.cfDel.onclick();
  if(AI.configs.length !== 1) throw new Error('期望剩 1 套，实际 ' + AI.configs.length);
  if(AI.configs[0].id !== b.id) throw new Error('删错了，剩下的不是 b');
  if(AI.curId !== b.id) throw new Error('删掉在用的那套后，curId 没切到剩下的');
  if(saved !== 1) throw new Error('没落盘（aiSave 没被调用）');
});

t('删掉最后一套 → curId 归零，列表空', () => {
  reset();
  const a = mkCfg('智谱', 'glm-4.7-flash');
  AI.curId = a.id;
  run.aiCfgSheet(a.id);
  els.cfDel.onclick();
  if(AI.configs.length !== 0) throw new Error('应该全空');
  if(AI.curId !== null) throw new Error('curId 应该变 null，实际 ' + AI.curId);
});

console.log('\n== 删除按钮：可疑路径 ==');

t('传进来的 id 在 configs 里找不到时 → 退化成新建，不能出现"点了删不掉"的按钮', () => {
  reset();
  const a = mkCfg('智谱', 'glm-4.7-flash');
  AI.curId = a.id;
  run.aiCfgSheet('undefined');        // 模拟 data-cfg 塞了个对不上的值
  if(lastHtml.includes('cfDel')) throw new Error('对不上 id 时不该给删除按钮（点了删不掉）');
  if(!lastHtml.includes('cfCancel')) throw new Error('应退化成新建态，给「取消」按钮');
  // 并且不能误伤现有配置
  if(AI.configs.length !== 1) throw new Error('不该动到已有配置');
});

t('脏 id（带引号）同样安全退化', () => {
  reset();
  const a = mkCfg('智谱', 'glm-4.7-flash');
  AI.curId = a.id;
  run.aiCfgSheet(a.id + '"');
  if(lastHtml.includes('cfDel')) throw new Error('脏 id 不该给删除按钮');
  if(AI.configs.length !== 1) throw new Error('不该动到已有配置');
});

t('新建态不显示删除按钮，只显示取消', () => {
  reset();
  run.aiCfgSheet(null);
  if(lastHtml.includes('cfDel')) throw new Error('新建态不该有删除按钮');
  if(!lastHtml.includes('cfCancel')) throw new Error('新建态应有取消按钮');
});

console.log('\n结果: ' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail ? 1 : 0);
