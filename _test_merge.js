// 从 index.html 里抽出真实的 mergeRows 实现来测，避免测的是副本
const fs = require('fs');
const html = fs.readFileSync('index.html', 'utf8');

// 需要 isUuid 定义
const isUuid = s => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s || '');

const head = html.match(/function mergeRows\(localRows, cloudRows\)\s*\{/);
if (!head) { console.error('没找到 mergeRows'); process.exit(1); }
let i = html.indexOf('{', head.index), depth = 0;
for (; i < html.length; i++) {
  if (html[i] === '{') depth++;
  else if (html[i] === '}') { depth--; if (depth === 0) { i++; break; } }
}
const src = html.slice(head.index, i);
eval(src);

let pass = 0, fail = 0;
function t(name, local, cloud, expectIds, expectWinner) {
  const out = mergeRows(local, cloud);
  const ids = out.map(r => r.id).sort().join(',');
  const okIds = ids === expectIds.slice().sort().join(',');
  let okWinner = true;
  if (expectWinner) {
    const row = out.find(r => r.id === expectWinner.id);
    okWinner = row && row.title === expectWinner.title;
  }
  if (okIds && okWinner) { pass++; console.log('  PASS  ' + name); }
  else {
    fail++;
    console.log('  FAIL  ' + name);
    console.log('        期望 ids=' + expectIds.slice().sort().join(',') + ' 实际=' + ids);
    if (!okWinner) console.log('        期望胜者=' + JSON.stringify(expectWinner) + ' 实际=' + JSON.stringify(out.find(r => expectWinner && r.id === expectWinner.id)));
  }
}

// 用 uuid 形状的长 id 模拟已上云记录，短 id 模拟只在本机的
const U1 = 'aaaaaaaa-0000-0000-0000-000000000001';
const U2 = 'aaaaaaaa-0000-0000-0000-000000000002';
const U3 = 'aaaaaaaa-0000-0000-0000-000000000003';

console.log('\n1. 本机有未上传改动 → 本机赢（不能被云端冲掉）');
t('本机改过但没传上去',
  [{ id: U1, title: '本机新值', updatedAt: 2000, cloudPending: true }],
  [{ id: U1, title: '云端旧值', updatedAt: 1000 }],
  [U1], { id: U1, title: '本机新值' });

console.log('\n2. 云端更新 → 云端赢');
t('云端比本机新',
  [{ id: U1, title: '本机旧值', updatedAt: 1000 }],
  [{ id: U1, title: '云端新值', updatedAt: 3000 }],
  [U1], { id: U1, title: '云端新值' });

console.log('\n3. 本机更新 → 本机赢');
t('本机比云端新',
  [{ id: U1, title: '本机新值', updatedAt: 3000 }],
  [{ id: U1, title: '云端旧值', updatedAt: 1000 }],
  [U1], { id: U1, title: '本机新值' });

console.log('\n4. 云端独有 → 补进本机');
t('别的设备加的',
  [{ id: U1, title: '本机值', updatedAt: 1000 }],
  [{ id: U1, title: '云端值', updatedAt: 1000 }, { id: U2, title: '别的设备加的', updatedAt: 2000 }],
  [U1, U2]);

console.log('\n5. 云端已删 → 本机跟着删（这条最关键，删不掉就会"复活"）');
t('云端没这条了',
  [{ id: U1, title: '本机值', updatedAt: 1000 }],
  [], []);

console.log('\n6. 本机待传的新增（短 id）→ 保留，等补传');
t('断网时加的',
  [{ id: 'm5x2k', title: '断网加的', updatedAt: 2000, cloudPending: true }],
  [], ['m5x2k']);

console.log('\n7. 云端删除 + 本机待传，两者同时存在 → 保住待传的');
t('删除与新增并存',
  [{ id: U1, title: '本机值', updatedAt: 1000 }, { id: 'm5x2k', title: '新加的', updatedAt: 2000, cloudPending: true }],
  [], ['m5x2k']);

console.log('\n8. 空对空');
t('两边都空', [], [], []);

console.log('\n9. 只有云端有');
t('本机空云端有', [], [{ id: U3, title: '云端值', updatedAt: 1000 }], [U3]);

console.log('\n结果: ' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail ? 1 : 0);
