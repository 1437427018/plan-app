#!/usr/bin/env python3
"""通过 Supabase Management API 执行 SQL 文件。

用法: run_sql.py <sql文件> <PAT>
注意: 请求必须带 User-Agent，否则 Supabase 前面的 Cloudflare 会返回 1010。
"""
import json, sys, urllib.request, urllib.error

REF = 'hoofhoblsbnivtbxqduq'
URL = f'https://api.supabase.com/v1/projects/{REF}/database/query'


def run_sql(sql, pat, label=''):
    req = urllib.request.Request(
        URL,
        data=json.dumps({'query': sql}).encode(),
        method='POST',
        headers={
            'Authorization': f'Bearer {pat}',
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0 (plan-app migrate)',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            body = r.read().decode()
            print(f'[OK] {label or sql[:40]}' + (f' -> {body[:300]}' if body.strip() not in ('', '[]', 'null') else ''))
            return True
    except urllib.error.HTTPError as e:
        print(f'[FAIL] {label or sql[:40]} -> HTTP {e.code}: {e.read().decode()[:500]}')
        return False
    except Exception as e:
        print(f'[FAIL] {label or sql[:40]} -> {e}')
        return False


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    sql = open(sys.argv[1], encoding='utf-8').read()
    ok = run_sql(sql, sys.argv[2])
    sys.exit(0 if ok else 1)
