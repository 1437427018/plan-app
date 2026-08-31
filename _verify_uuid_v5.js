// 独立验证：JS 实现的 UUID v5 是否与 RFC 4122 权威实现一致
// 期望值由 Python uuid.uuid5 生成（见 verify_uuid_v5.py）
'use strict';

const HABIT_NS = '6f5a1c8e-0d2b-5f47-9a3e-1c7d2b8e4a10';

function utf8Bytes(str){
  const out = [];
  for(let i=0;i<str.length;i++){
    let c = str.charCodeAt(i);
    if(c < 0x80) out.push(c);
    else if(c < 0x800){ out.push(0xC0|(c>>6), 0x80|(c&0x3F)); }
    else if(c >= 0xD800 && c <= 0xDBFF && i+1 < str.length){
      const c2 = str.charCodeAt(i+1);
      const cp = 0x10000 + ((c-0xD800)<<10) + (c2-0xDC00);
      i++;
      out.push(0xF0|(cp>>18), 0x80|((cp>>12)&0x3F), 0x80|((cp>>6)&0x3F), 0x80|(cp&0x3F));
    } else {
      out.push(0xE0|(c>>12), 0x80|((c>>6)&0x3F), 0x80|(c&0x3F));
    }
  }
  return new Uint8Array(out);
}

function sha1Bytes(msg){
  const ml = msg.length;
  const blocks = Math.ceil((ml + 1 + 8) / 64);
  const total = blocks * 64;
  const buf = new Uint8Array(total);
  buf.set(msg);
  buf[ml] = 0x80;
  const bitLen = ml * 8;
  const dv = new DataView(buf.buffer);
  dv.setUint32(total - 8, Math.floor(bitLen / 0x100000000));
  dv.setUint32(total - 4, bitLen >>> 0);

  let h0=0x67452301, h1=0xEFCDAB89, h2=0x98BADCFE, h3=0x10325476, h4=0xC3D2E1F0;
  const w = new Uint32Array(80);
  for(let b=0;b<blocks;b++){
    const off = b*64;
    for(let i=0;i<16;i++) w[i] = dv.getUint32(off + i*4);
    for(let i=16;i<80;i++){
      const x = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16];
      w[i] = (x << 1) | (x >>> 31);
    }
    let a=h0, bb=h1, c=h2, d=h3, e=h4;
    for(let i=0;i<80;i++){
      let f, k;
      if(i<20)      { f = (bb & c) | ((~bb) & d);          k = 0x5A827999; }
      else if(i<40) { f = bb ^ c ^ d;                      k = 0x6ED9EBA1; }
      else if(i<60) { f = (bb & c) | (bb & d) | (c & d);   k = 0x8F1BBCDC; }
      else          { f = bb ^ c ^ d;                      k = 0xCA62C1D6; }
      const t = (((a<<5)|(a>>>27)) + f + e + k + w[i]) >>> 0;
      e = d; d = c; c = ((bb<<30)|(bb>>>2)) >>> 0; bb = a; a = t;
    }
    h0=(h0+a)>>>0; h1=(h1+bb)>>>0; h2=(h2+c)>>>0; h3=(h3+d)>>>0; h4=(h4+e)>>>0;
  }
  const out = new Uint8Array(20);
  const odv = new DataView(out.buffer);
  odv.setUint32(0,h0); odv.setUint32(4,h1); odv.setUint32(8,h2);
  odv.setUint32(12,h3); odv.setUint32(16,h4);
  return out;
}

function uuidToBytes(u){
  const h = String(u).replace(/-/g,'');
  const b = new Uint8Array(16);
  for(let i=0;i<16;i++) b[i] = parseInt(h.substr(i*2,2),16);
  return b;
}

function uuidV5(nsUuid, name){
  const ns = uuidToBytes(nsUuid);
  const nm = utf8Bytes(name);
  const msg = new Uint8Array(ns.length + nm.length);
  msg.set(ns,0); msg.set(nm, ns.length);
  const h = sha1Bytes(msg);
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  let s = '';
  for(let i=0;i<16;i++) s += (h[i]>>>0).toString(16).padStart(2,'0');
  return `${s.slice(0,8)}-${s.slice(8,12)}-${s.slice(12,16)}-${s.slice(16,20)}-${s.slice(20,32)}`;
}

function habitLogId(userId, habitId, day){
  return uuidV5(HABIT_NS, `${String(userId).toLowerCase()}|${String(habitId).toLowerCase()}|${day}`);
}

/* ---------- 用例：期望值由 Python uuid.uuid5 生成 ---------- */
const cases = JSON.parse(require('fs').readFileSync(__dirname + '/_uuid_expect.json','utf8'));

let pass = 0, fail = 0;
for(const c of cases){
  const got = c.mode === 'raw' ? uuidV5(c.ns, c.name) : habitLogId(c.user, c.habit, c.day);
  if(got === c.expect){ pass++; console.log(`  PASS  ${c.desc}`); }
  else { fail++; console.log(`  FAIL  ${c.desc}\n        expect ${c.expect}\n        got    ${got}`); }
}

// isUuid 门禁兼容性（index.html:409 的正则）
const isUuid = s => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s || '');
const gid = habitLogId('3f2b1c0a-1111-4a22-9b33-000000000001','8c7d6e5f-2222-4333-8444-000000000002','2026-08-28');
const gateOk = isUuid(gid);
console.log(`  ${gateOk?'PASS':'FAIL'}  isUuid() 门禁兼容性 -> ${gid}`);

console.log(`\n结果：${pass} 通过 / ${fail} 失败，门禁 ${gateOk?'通过':'失败'}`);
process.exit(fail === 0 && gateOk ? 0 : 1);
