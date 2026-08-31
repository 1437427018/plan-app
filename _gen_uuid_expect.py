# 用 Python 的 uuid.uuid5（RFC 4122 权威实现）生成期望值，供 JS 实现对拍
import json, uuid

HABIT_NS = uuid.UUID('6f5a1c8e-0d2b-5f47-9a3e-1c7d2b8e4a10')
DNS_NS   = uuid.UUID('6ba7b810-9dad-11d1-80b4-00c04fd430c8')

cases = []

# 1) RFC 4122 标准测试向量
cases.append(dict(mode='raw', ns=str(DNS_NS), name='www.widgets.com',
                  expect=str(uuid.uuid5(DNS_NS, 'www.widgets.com')),
                  desc='[RFC4122标准向量] DNS ns + www.widgets.com'))

# 2) 空串
cases.append(dict(mode='raw', ns=str(HABIT_NS), name='',
                  expect=str(uuid.uuid5(HABIT_NS, '')),
                  desc='[边界] name 为空串'))

# 3) SHA-1 分块边界：总长 = 16(ns) + len(name)。覆盖 55/56/64 字节 padding 临界
for total in (55, 56, 63, 64, 65):
    n = total - 16
    name = 'x' * n
    cases.append(dict(mode='raw', ns=str(HABIT_NS), name=name,
                      expect=str(uuid.uuid5(HABIT_NS, name)),
                      desc=f'[SHA-1分块边界] 消息总长 {total} 字节'))

# 4) 中文 UTF-8
cases.append(dict(mode='raw', ns=str(HABIT_NS), name='喝水打卡',
                  expect=str(uuid.uuid5(HABIT_NS, '喝水打卡')),
                  desc='[UTF-8] 中文 name'))

U = '3f2b1c0a-1111-4a22-9b33-000000000001'
H = '8c7d6e5f-2222-4333-8444-000000000002'
for day in ('2026-08-28', '2026-01-01', '2026-12-31'):
    name = f'{U.lower()}|{H.lower()}|{day}'
    cases.append(dict(mode='habit', user=U, habit=H, day=day,
                      expect=str(uuid.uuid5(HABIT_NS, name)),
                      desc=f'[业务形态] habitLogId {day}'))

# 5) 大写 UUID 输入（验证前端是否真的 lower 过）
U2 = '3F2B1C0A-1111-4A22-9B33-000000000001'
name2 = f'{U2.lower()}|{H.lower()}|2026-08-28'
cases.append(dict(mode='habit', user=U2, habit=H, day='2026-08-28',
                  expect=str(uuid.uuid5(HABIT_NS, name2)),
                  desc='[大小写] 大写 user_id 输入应被 lower'))

with open('_uuid_expect.json', 'w', encoding='utf-8') as f:
    json.dump(cases, f, ensure_ascii=False, indent=1)

print(f'已生成 {len(cases)} 个用例')
for c in cases[:2] + cases[-1:]:
    print(f"  {c['desc']}\n    -> {c['expect']}")
