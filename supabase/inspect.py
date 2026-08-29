#!/usr/bin/env python3
"""通过 Supabase Management API 只读查询数据库现状（排查用，不写数据）"""
import json, urllib.request, urllib.error, sys

REF = 'hoofhoblsbnivtbxqduq'
URL = f'https://api.supabase.com/v1/projects/{REF}/database/query'

_args = sys.argv[1:]
if _args and _args[0] == '--sql':
    CUSTOM_SQL = _args[1] if len(_args) > 1 else ''
    PAT = _args[2] if len(_args) > 2 else ''
else:
    CUSTOM_SQL = None
    PAT = _args[0] if _args else ''

QUERIES = {
    'auth.users': "select id, email, raw_user_meta_data, created_at from auth.users order by created_at desc limit 10",
    'profiles':   "select * from public.profiles order by created_at desc limit 10",
    'trigger':    "select tgname from pg_trigger where tgname = 'on_auth_user_created'",
    'columns':    "select table_name, column_name, data_type from information_schema.columns "
                  "where table_schema='public' order by table_name, ordinal_position",
    'rowcounts':  "select 'year_goals' t, count(*) n from public.year_goals union all "
                  "select 'month_goals', count(*) from public.month_goals union all "
                  "select 'tasks', count(*) from public.tasks union all "
                  "select 'habits', count(*) from public.habits union all "
                  "select 'special_dates', count(*) from public.special_dates union all "
                  "select 'profiles', count(*) from public.profiles union all "
                  "select 'relationships', count(*) from public.relationships union all "
                  "select 'whispers', count(*) from public.whispers",
}


def run(q):
    req = urllib.request.Request(
        URL,
        data=json.dumps({'query': q}).encode(),
        method='POST',
        headers={
            'Authorization': f'Bearer {PAT}',
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0 (plan-app inspect)',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return {'__error__': e.code, 'body': e.read().decode()[:600]}
    except Exception as e:
        return {'__error__': str(e)}


def show(label, res):
    print('=' * 60)
    print('##', label)
    if isinstance(res, dict) and '__error__' in res:
        print('  ERROR:', res['__error__'])
        print('  ', res.get('body', ''))
        return
    for row in (res if isinstance(res, list) else [res]):
        print('  ', json.dumps(row, ensure_ascii=False, default=str))


if CUSTOM_SQL is not None:
    # 自定义查询：inspect.py --sql "select ..." <PAT>
    show('custom', run(CUSTOM_SQL))
elif PAT:
    for name, q in QUERIES.items():
        show(name, run(q))
else:
    print('用法: inspect.py [--sql "自定义SQL"] <PAT>')
