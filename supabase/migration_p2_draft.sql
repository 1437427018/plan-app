-- ============================================================
--  草稿方案，未经用户确认，不要执行
-- ============================================================
-- 小计划 PWA · P2 增量迁移（草稿 / DRAFT / NOT REVIEWED / DO NOT RUN）
--
-- 目标：修复三个既有缺陷
--   缺陷1 习惯整行 LWW 丢数据   → §1 habits.type/target + habit_logs 表
--   缺陷2 删除无云端 tombstone  → §2 五张计划表加 deleted_at
--   缺陷3 save() 无保护 + 全量拉 → §3 纯前端（本文件只给策略，无 DDL）
--
-- 约束：纯增量、零停机、可回滚。不修改 index.html / sw.js / 已有 .sql。
--       habits.done_dates 列保留不动，只做「写入旁路」，随时可回退。
--
-- 状态：本文件未执行过任何语句。确认前请阅读文末「执行顺序」「回滚」「风险」。
-- ============================================================


-- ============================================================
-- §0 前置：扩展 + 确定性 UUID v5 函数（前后端共用的命门）
-- ============================================================

-- pgcrypto 已在 schema.sql:7 建过，这里再保一次（幂等）
create extension if not exists "pgcrypto";

-- ---------- 0.1 应用级命名空间（固定常量，前端必须用同一个值）----------
-- 选一个一次性定死、永不修改的值。改动 = 所有历史 habit_logs 主键失效。
-- 注意：这个 UUID 的 version 半字节写 5 只是语义标注，参与哈希时它被当作
--       纯 16 字节，写 4 也行；但必须与 JS 侧字符串完全相同（小写、带连字符）。
create or replace function public.habit_log_ns()
returns uuid language sql immutable
as $$ select '6f5a1c8e-0d2b-5f47-9a3e-1c7d2b8e4a10'::uuid $$;

-- ---------- 0.2 UUID v5（RFC 4122 §4.3）：SHA-1 + 版本号/变体位 ----------
-- 【为什么不用 md5() 拼装】
--   md5() 拼出来的是 UUID v3（version 半字节 = 3），不是 v5。
--   MD5 已被废弃（碰撞可构造、FIPS 模式下 md5() 直接不可用）。本项目虽然
--   不靠它做安全，但一旦将来有人按「v5」语义校验或迁移到别的语言标准库，
--   v3/v5 混用会静默出错。
-- 【为什么不用 uuid-ossp 的 uuid_generate_v5()】
--   算法等价（同为 RFC 4122 §4.3），但要多装一个扩展。pgcrypto 已经在
--   schema.sql:7 装好了，digest(x,'sha1') 现成可用。
-- 【决定性理由】自写函数把每一步都摊开写：取前 16 字节 / (&0x0F|0x50) /
--   (&0x3F|0x80)。前端要逐行对照实现，黑盒函数反而多一层不确定性。
--
-- 算法（与前端 JS 必须逐字节一致）：
--   1. ns_bytes = namespace UUID 的 16 字节（按文本形式的大端顺序）
--   2. msg      = ns_bytes || convert_to(name, 'UTF8')
--   3. h        = digest(msg,'sha1') 的前 16 字节
--   4. h[6]     = (h[6] & 0x0F) | 0x50     -- version = 5
--   5. h[8]     = (h[8] & 0x3F) | 0x80     -- variant = RFC 4122 (10x)
--   6. 按 8-4-4-4-12 小写十六进制拼串
create or replace function public.uuid_v5(p_ns uuid, p_name text)
returns uuid
language plpgsql immutable strict
set search_path = public, pg_temp
as $$
declare
  h  bytea;
  hx text;
begin
  h := substring(
         digest(
           decode(replace(p_ns::text, '-', ''), 'hex')   -- ns 的 16 字节
           || convert_to(p_name, 'UTF8'),                -- name 的 UTF-8 字节
           'sha1'
         ) from 1 for 16                                 -- 只取前 16 字节
       );
  h := set_byte(h, 6, (get_byte(h, 6) & 15)  | 80 );     -- &0x0F | 0x50
  h := set_byte(h, 8, (get_byte(h, 8) & 63)  | 128);     -- &0x3F | 0x80
  hx := encode(h, 'hex');
  return (substr(hx,1,8)  || '-' || substr(hx,9,4)  || '-' ||
          substr(hx,13,4) || '-' || substr(hx,17,4) || '-' ||
          substr(hx,21,12))::uuid;
end $$;

-- ---------- 0.3 name 字符串的构造规则（前后端唯一真源）----------
-- 格式（严格）： lower(user_id) || '|' || lower(habit_id) || '|' || 'YYYY-MM-DD'
--   · 分隔符用 '|'（不会出现在 UUID / 日期里，无需转义）
--   · 两侧 UUID 一律小写（Postgres 的 uuid::text 本身就输出小写）
--   · 日期用 to_char(day,'YYYY-MM-DD')，不用 day::text —— 后者受 DateStyle
--     会话参数影响，万一被改成 'SQL, DMY' 就会算成 '28/08/2026'，前后端错位。
--     代价：to_char(date,text) 在 pg_proc 里是 STABLE 不是 IMMUTABLE，
--     所以本函数只能标 STABLE（不影响使用：它只用于触发器，不进索引）。
create or replace function public.habit_log_name(p_user uuid, p_habit uuid, p_day date)
returns text
language sql stable strict
set search_path = public, pg_temp
as $$
  select lower(p_user::text) || '|' || lower(p_habit::text) || '|' || to_char(p_day, 'YYYY-MM-DD');
$$;

-- ---------- 0.4 自检：只告警，不中断 ----------
-- 向量 1：RFC 4122 通行测试向量（ns=DNS 6ba7b810-9dad-11d1-80b4-00c04fd430c8,
--         name='www.widgets.com' → 21f7f8de-8051-5b89-8680-0195ef798b6a）
-- 向量 2：真实业务形态（跨 64 字节 SHA-1 分块边界，顺带验证 padding）
-- 执行后请在 Output 里确认两行都是「自检通过」，否则不要跑 §3 回填。
do $$
declare
  got1 uuid := public.uuid_v5('6ba7b810-9dad-11d1-80b4-00c04fd430c8'::uuid, 'www.widgets.com');
  got2 uuid := public.uuid_v5(
        public.habit_log_ns(),
        '3f2b1c0a-1111-4a22-9b33-000000000001|8c7d6e5f-2222-4333-8444-000000000002|2026-08-28');
begin
  if got1 = '21f7f8de-8051-5b89-8680-0195ef798b6a'::uuid then
    raise notice '[自检通过] 标准向量 uuid_v5 = %', got1;
  else
    raise warning '[自检失败] 标准向量期望 21f7f8de-8051-5b89-8680-0195ef798b6a，实际 % —— 不要执行回填', got1;
  end if;

  if got2 = '11d4e5a4-77cf-527a-90f6-ed44edf752f2'::uuid then
    raise notice '[自检通过] 业务向量 habit_log id = %', got2;
  else
    raise warning '[自检失败] 业务向量期望 11d4e5a4-77cf-527a-90f6-ed44edf752f2，实际 % —— 前后端 id 会不一致', got2;
  end if;
end $$;


-- ============================================================
-- §1 习惯打卡升级：check（打勾）/ count（计数）
-- ============================================================
-- 设计要点：
--   · 不做「时长」「时间段」模式。timestamptz 是本项目历史事故高发区
--     （index.html:420-422 注释：前端传毫秒数字 → Postgres 22008）。
--     本方案的 day 用 date（无时区概念），value 用 int，彻底绕开 timestamptz。
--   · habit_logs 主键由 (user_id, habit_id, day) 哈希得出，客户端自己算。
--     原因：两台设备给同一天各生成随机 uuid → 撞唯一约束；用文本复合主键
--     → 过不了 index.html:409 的 isUuid() 门禁，flushPending 永远走 insert
--       分支（index.html:496），反复插入 → 重复键死循环。
--   · 「取消打卡」= 写 value=0 的行，不物理删除。这样 (habit_id, day)
--     唯一约束天然保证「一天只有一条记录」，LWW 决定最终值，不需要 tombstone。
--     value>=1 视为已打卡，value=0 视为未打卡。

-- ---------- 1.1 habits 表加列（零停机：PG11+ 带常量默认值的 add column 只改元数据，不重写表）----------
alter table public.habits add column if not exists type   text not null default 'check';
alter table public.habits add column if not exists target int;

alter table public.habits drop constraint if exists habits_type_check;
alter table public.habits add constraint habits_type_check
  check (type in ('check','count'));

alter table public.habits drop constraint if exists habits_target_check;
alter table public.habits add constraint habits_target_check
  check (target is null or target > 0);

comment on column public.habits.type   is 'check=打勾；count=计数（达到 target 算完成）';
comment on column public.habits.target is 'count 模式的每日目标值；check 模式为 null';

-- ---------- 1.2 habit_logs 表 ----------
create table if not exists public.habit_logs (
  id         uuid primary key,                  -- 无 default：由客户端 uuid_v5 算，触发器兜底
  user_id    uuid not null references auth.users(id) on delete cascade,
  habit_id   uuid not null references public.habits(id) on delete cascade,
  day        date not null,
  value      int  not null default 1,
  updated_at timestamptz not null default now(),  -- 客户端逻辑时间，LWW 依据
  created_at timestamptz not null default now()
);
comment on table  public.habit_logs is '习惯每日打卡值。check 模式 value∈{0,1}；count 模式 value>=0';
comment on column public.habit_logs.id is 'uuid_v5(HABIT_NS, lower(user_id)|lower(habit_id)|day)，前后端必须一致';

-- 幂等补列（表已存在时重复执行本文件用）
alter table public.habit_logs add column if not exists value      int not null default 1;
alter table public.habit_logs add column if not exists updated_at timestamptz not null default now();
alter table public.habit_logs add column if not exists created_at timestamptz not null default now();

-- 唯一约束：一个习惯一天只有一条。upsert 的冲突目标。
create unique index if not exists habit_logs_habit_day_uidx
  on public.habit_logs (habit_id, day);

-- 拉取索引：按用户 + 日期倒序取最近 N 天
create index if not exists habit_logs_user_day_idx
  on public.habit_logs (user_id, day desc);

-- 增量拉取索引：按 updated_at 过滤
create index if not exists habit_logs_user_updated_idx
  on public.habit_logs (user_id, updated_at desc);

alter table public.habit_logs drop constraint if exists habit_logs_value_check;
alter table public.habit_logs add constraint habit_logs_value_check check (value >= 0);

-- ---------- 1.3 主键兜底触发器 ----------
-- 客户端没传 id 时（例如 SQL 手工插入、将来其它服务端写入）按同一规则补齐，
-- 保证表里不可能出现「算不出来的 id」。
create or replace function public.habit_logs_set_id()
returns trigger language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.id is null then
    new.id := public.uuid_v5(
      public.habit_log_ns(),
      public.habit_log_name(new.user_id, new.habit_id, new.day));
  end if;
  return new;
end $$;

drop trigger if exists habit_logs_set_id_bi on public.habit_logs;
create trigger habit_logs_set_id_bi
  before insert on public.habit_logs
  for each row execute function public.habit_logs_set_id();

-- ---------- 1.4 RLS ----------
-- 关键：不能只信 habit_logs.user_id（那是客户端传的，可伪造）。
-- 必须回 habits 校验这条 habit 真的属于当前登录者。
alter table public.habit_logs enable row level security;

drop policy if exists "自己的习惯打卡" on public.habit_logs;
create policy "自己的习惯打卡" on public.habit_logs
  for all
  using (
    auth.uid() = user_id
    and exists (
      select 1 from public.habits h
      where h.id = habit_logs.habit_id
        and h.user_id = auth.uid()
    )
  )
  with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.habits h
      where h.id = habit_logs.habit_id
        and h.user_id = auth.uid()
    )
  );

-- ---------- 1.5 写入入口：带 DB 级 LWW 保护的 upsert ----------
-- 为什么不用 PostgREST 的 upsert()：
--   a) 确定性 id 已存在时，PostgREST 的 update 命中的是「0 行」而不是报错，
--      乱序重试（离线很久的老设备补传）会把新值盖成旧值；
--   b) 放在 RPC 里可以在 SQL 层做 updated_at 比较，客户端时钟漂移也不怕。
-- 前端仍要自己算 id（离线渲染需要），这里返回的行用来对账。
create or replace function public.upsert_habit_log(
  p_habit      uuid,
  p_day        date,
  p_value      int,
  p_updated_at timestamptz
)
returns public.habit_logs
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare rec public.habit_logs;
begin
  insert into public.habit_logs (id, user_id, habit_id, day, value, updated_at)
  values (
    public.uuid_v5(public.habit_log_ns(), public.habit_log_name(auth.uid(), p_habit, p_day)),
    auth.uid(), p_habit, p_day, p_value, p_updated_at
  )
  on conflict (habit_id, day) do update
    set value      = excluded.value,
        updated_at = excluded.updated_at
    where excluded.updated_at > habit_logs.updated_at   -- 旧值不覆盖新值
  returning * into rec;

  -- 冲突分支被 where 挡掉时 returning 无行，回读当前胜出的那行
  if rec.id is null then
    select * into rec
    from public.habit_logs
    where habit_id = p_habit and day = p_day;
  end if;

  return rec;
end $$;

revoke execute on function public.upsert_habit_log(uuid, date, int, timestamptz) from public, anon;
grant  execute on function public.upsert_habit_log(uuid, date, int, timestamptz) to authenticated;

-- ---------- 1.6 加入 realtime ----------
-- 默认 REPLICA IDENTITY = PRIMARY KEY，UPDATE/DELETE 事件只带 id。
-- 前端只需要 id 去查本地，够用；若要拿到整行 old 记录需
--   alter table public.habit_logs replica identity full;
-- 但那会让 WAL 变大，当前规模下不划算，不加。
do $$
begin
  alter publication supabase_realtime add table public.habit_logs;
exception when duplicate_object then null;
end $$;


-- ============================================================
-- §2 删除 tombstone（5 张计划表）
-- ============================================================
-- 为什么必须放在 §3 回填之前：回填语句里有 h.deleted_at is null 的过滤条件。
-- 顺序错了会直接报错（列不存在），不会静默出错。

-- ---------- 2.1 加列（nullable、无默认值 → 只改元数据，秒级）----------
alter table public.year_goals    add column if not exists deleted_at timestamptz;
alter table public.month_goals   add column if not exists deleted_at timestamptz;
alter table public.tasks         add column if not exists deleted_at timestamptz;
alter table public.habits        add column if not exists deleted_at timestamptz;
alter table public.special_dates add column if not exists deleted_at timestamptz;

comment on column public.tasks.deleted_at is '软删标记。非 null = 已删除，前端 select 必须 .is(deleted_at, null)';

-- ---------- 2.2 活跃数据索引（前端每次同步都走这个过滤）----------
create index if not exists year_goals_live_idx    on public.year_goals    (user_id, updated_at desc) where deleted_at is null;
create index if not exists month_goals_live_idx   on public.month_goals   (user_id, updated_at desc) where deleted_at is null;
create index if not exists special_dates_live_idx on public.special_dates (user_id, updated_at desc) where deleted_at is null;
create index if not exists habits_live_idx        on public.habits        (user_id, updated_at desc) where deleted_at is null;

-- tasks 额外按 plan_date 建一个：冷启动时间窗查询按 plan_date 过滤
create index if not exists tasks_live_plan_idx    on public.tasks         (user_id, plan_date)       where deleted_at is null;
create index if not exists tasks_live_idx         on public.tasks         (user_id, updated_at desc) where deleted_at is null;

-- ---------- 2.3 tombstone 回收索引 ----------
create index if not exists tasks_purge_idx on public.tasks (deleted_at) where deleted_at is not null;

-- ---------- 2.4 归档表（物理删除前的兜底）----------
-- 单张 jsonb 表收所有表的墓碑，不按原表建 5 张归档表。
-- RLS 打开但零策略 → 前端/anon/authenticated 一律看不到，只有函数（definer）和
-- postgres 角色能写。
create table if not exists public.deleted_archive (
  id          uuid primary key default gen_random_uuid(),
  table_name  text not null,
  row_data    jsonb not null,
  deleted_at  timestamptz not null,
  archived_at timestamptz not null default now()
);
alter table public.deleted_archive enable row level security;
create index if not exists deleted_archive_tbl_time_idx on public.deleted_archive (table_name, deleted_at);

-- ---------- 2.5 回收函数：归档 → 物理删除 ----------
-- N 默认 90 天。当前只有 2 个真实用户，墓碑量可忽略；建好先不挂定时任务，
-- 等数据量上来再上 pg_cron 每月跑一次：
--   select cron.schedule('purge-deleted','0 3 1 * *', $$select public.purge_deleted(90)$$);
-- 注意：OUT 参数刻意不叫 table_name / row_data —— 若与 deleted_archive 的列名
-- 同名，PL/pgSQL 会在 SQL 里把标识符捕获成变量（得到 NULL），静默出错。
create or replace function public.purge_deleted(p_days int default 90)
returns table (tbl text, purged bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  cutoff timestamptz := now() - (p_days || ' days')::interval;
  n bigint;
begin
  -- 实际顺序：tasks → special_dates → month_goals → year_goals → habits → habit_logs 孤儿
  -- month_goals 引用 year_goals，必须先删前者；habits 放最后，靠外键
  -- on delete cascade 带走 habit_logs，不单独处理。

  -- 1) tasks（无外键依赖它，先删）
  with moved as (
    delete from public.tasks t
    where t.deleted_at is not null and t.deleted_at < cutoff
    returning to_jsonb(t.*) as j
  )
  insert into public.deleted_archive (table_name, row_data, deleted_at)
  select 'tasks', m.j, (m.j->>'deleted_at')::timestamptz from moved m;
  get diagnostics n = row_count;
  tbl := 'tasks'; purged := n; return next;

  -- 2) special_dates
  with moved as (
    delete from public.special_dates t
    where t.deleted_at is not null and t.deleted_at < cutoff
    returning to_jsonb(t.*) as j
  )
  insert into public.deleted_archive (table_name, row_data, deleted_at)
  select 'special_dates', m.j, (m.j->>'deleted_at')::timestamptz from moved m;
  get diagnostics n = row_count;
  tbl := 'special_dates'; purged := n; return next;

  -- 3) month_goals（引用 year_goals，必须在 year_goals 之前删）
  with moved as (
    delete from public.month_goals t
    where t.deleted_at is not null and t.deleted_at < cutoff
    returning to_jsonb(t.*) as j
  )
  insert into public.deleted_archive (table_name, row_data, deleted_at)
  select 'month_goals', m.j, (m.j->>'deleted_at')::timestamptz from moved m;
  get diagnostics n = row_count;
  tbl := 'month_goals'; purged := n; return next;

  -- 4) year_goals：只删「没有活着的 month_goals 还指向它」的。
  --    外键是 on delete set null，硬删会把还活着的月目标的 year_goal_id 抹成 null，
  --    属于静默数据损坏，必须先挡掉。
  with moved as (
    delete from public.year_goals t
    where t.deleted_at is not null and t.deleted_at < cutoff
      and not exists (select 1 from public.month_goals m
                      where m.year_goal_id = t.id and m.deleted_at is null)
    returning to_jsonb(t.*) as j
  )
  insert into public.deleted_archive (table_name, row_data, deleted_at)
  select 'year_goals', m.j, (m.j->>'deleted_at')::timestamptz from moved m;
  get diagnostics n = row_count;
  tbl := 'year_goals'; purged := n; return next;

  -- 5) habits（最后删，级联带走 habit_logs）
  with moved as (
    delete from public.habits t
    where t.deleted_at is not null and t.deleted_at < cutoff
    returning to_jsonb(t.*) as j
  )
  insert into public.deleted_archive (table_name, row_data, deleted_at)
  select 'habits', m.j, (m.j->>'deleted_at')::timestamptz from moved m;
  get diagnostics n = row_count;
  tbl := 'habits'; purged := n; return next;

  -- 6) 孤儿 habit_logs（对应 habits 已被物理删除的残留，正常路径下不会产生）
  delete from public.habit_logs hl
  where not exists (select 1 from public.habits h where h.id = hl.habit_id);
  get diagnostics n = row_count;
  tbl := 'habit_logs(orphan)'; purged := n; return next;

  return;
end $$;

revoke execute on function public.purge_deleted(int) from public, anon, authenticated;


-- ============================================================
-- §3 历史数据回填：habits.done_dates → habit_logs
-- ============================================================
-- 幂等：on conflict (habit_id, day) do nothing，重复执行无副作用。
-- 只迁 done_dates 里存在的日期 → value=1（check 模式）。
-- done_dates 列本身不动，随时可对照、可回滚。

insert into public.habit_logs (id, user_id, habit_id, day, value, updated_at, created_at)
select
  public.uuid_v5(
    public.habit_log_ns(),
    public.habit_log_name(h.user_id, h.id, d.day)      -- 与前端完全同一公式
  ),
  h.user_id,
  h.id,
  d.day,
  1,                                                    -- check 模式，value=1
  coalesce(h.updated_at, h.created_at, now()),          -- 老数据没有精确时间，用习惯行的时间兜底
  coalesce(h.created_at, now())
from public.habits h
cross join lateral unnest(coalesce(h.done_dates, '{}'::date[])) as d(day)
where h.deleted_at is null
on conflict (habit_id, day) do nothing;


-- ============================================================
-- §4 验收查询（全部为只读，可放心执行）
-- ============================================================

-- 4.1 行数对账：habit_logs 应等于所有习惯的 done_dates 长度之和
select
  (select count(*) from public.habit_logs)                                        as logs_rows,
  (select coalesce(sum(cardinality(coalesce(done_dates,'{}'::date[]))), 0)
     from public.habits where deleted_at is null)                                  as done_dates_total,
  (select count(*) from public.habit_logs) =
  (select coalesce(sum(cardinality(coalesce(done_dates,'{}'::date[]))), 0)
     from public.habits where deleted_at is null)                                  as 对得上;

-- 4.2 抽样核对 id：把这三行的 expect_id 拿去和前端 habitLogId() 的输出比
select
  h.user_id,
  h.id as habit_id,
  public.uuid_v5(
    public.habit_log_ns(),
    public.habit_log_name(h.user_id, h.id, current_date)
  ) as expect_id_for_today
from public.habits h
where h.deleted_at is null
limit 3;

-- 4.3 已回填的行：确认 id 确实等于 uuid_v5（若有行说明有手改/触发器兜底产生的偏差）
select count(*) as id_mismatch_rows
from public.habit_logs l
where l.id <> public.uuid_v5(public.habit_log_ns(),
                             public.habit_log_name(l.user_id, l.habit_id, l.day));

-- 4.4 结构确认
select table_name, column_name, data_type, column_default, is_nullable
from information_schema.columns
where table_schema='public'
  and ((table_name='habits'        and column_name in ('type','target','deleted_at','done_dates'))
    or (table_name='habit_logs')
    or (table_name in ('year_goals','month_goals','tasks','special_dates') and column_name='deleted_at'))
order by table_name, ordinal_position;

-- 4.5 realtime 发布确认
select tablename from pg_publication_tables
where pubname='supabase_realtime' order by tablename;


-- ============================================================
-- §5 回滚脚本（注释状态，不执行。执行前请先确认 §3 已回填无误）
-- ============================================================
--
-- 【R1 回滚 §1 习惯打卡】—— 零数据丢失，因为 done_dates 从头到尾没动过
--   drop trigger if exists habit_logs_set_id_bi on public.habit_logs;
--   drop policy if exists "自己的习惯打卡" on public.habit_logs;
--   drop function if exists public.upsert_habit_log(uuid, date, int, timestamptz);
--   drop function if exists public.habit_logs_set_id();
--   do $$ begin
--     alter publication supabase_realtime drop table public.habit_logs;
--   exception when undefined_object then null; end $$;
--   drop table if exists public.habit_logs;
--   alter table public.habits drop constraint if exists habits_type_check;
--   alter table public.habits drop constraint if exists habits_target_check;
--   alter table public.habits drop column if exists type;
--   alter table public.habits drop column if exists target;
--   -- 前端回退到「只读写 done_dates」的旧逻辑即可，无残留
--
-- 【R2 回滚 §2 tombstone】—— 必须先把墓碑物理删掉，否则已删记录会复活
--   -- 步骤 1（必须）：清掉所有软删行。想留底的先跑一遍归档：
--   --   select * from public.purge_deleted(0);   -- 0 天 = 全部软删行
--   -- 步骤 2：确认没有残留
--   --   select 'tasks', count(*) from public.tasks where deleted_at is not null
--   --   union all select 'habits', count(*) from public.habits where deleted_at is not null
--   --   union all select 'year_goals', count(*) from public.year_goals where deleted_at is not null
--   --   union all select 'month_goals', count(*) from public.month_goals where deleted_at is not null
--   --   union all select 'special_dates', count(*) from public.special_dates where deleted_at is not null;
--   -- 步骤 3：删列
--   alter table public.year_goals    drop column if exists deleted_at;
--   alter table public.month_goals   drop column if exists deleted_at;
--   alter table public.tasks         drop column if exists deleted_at;
--   alter table public.habits        drop column if exists deleted_at;
--   alter table public.special_dates drop column if exists deleted_at;
--   drop index if exists public.tasks_live_plan_idx, public.tasks_live_idx,
--              public.tasks_purge_idx, public.habits_live_idx,
--              public.year_goals_live_idx, public.month_goals_live_idx,
--              public.special_dates_live_idx;
--   drop function if exists public.purge_deleted(int);
--   drop table if exists public.deleted_archive;
--
-- 【R3 回滚 §0】—— 只有 habit_logs 用得到，R1 之后即可删
--   drop function if exists public.habit_log_name(uuid, uuid, date);
--   drop function if exists public.uuid_v5(uuid, text);
--   drop function if exists public.habit_log_ns();
--
-- 【R4 §3 无需回滚】—— 回填只 INSERT 到新表 habit_logs，drop table 就干净了。


-- ============================================================
-- §6 前端配套 JS（确定性 UUID v5 —— 必须与 §0 逐字节一致）
-- ============================================================
--
-- 已实测校验（Node 22 实现 vs Python uuid.uuid5 / RFC 4122 参考实现）：
--   标准向量 ns=DNS(6ba7b810-9dad-11d1-80b4-00c04fd430c8) name='www.widgets.com'
--     → 21f7f8de-8051-5b89-8680-0195ef798b6a  一致
--   业务向量 ns=6f5a1c8e-0d2b-5f47-9a3e-1c7d2b8e4a10
--     name='3f2b1c0a-1111-4a22-9b33-000000000001|8c7d6e5f-2222-4333-8444-000000000002|2026-08-28'
--     → 11d4e5a4-77cf-527a-90f6-ed44edf752f2  一致
--   边界用例：空串、55/56/64 字节（SHA-1 分块 + padding 边界）、中文 UTF-8 全部一致
--
-- 零依赖，同步函数（不用 crypto.subtle —— 它是异步的，会污染 syncInsert 的调用链）。
--
-- ------------------------------------------------------------
-- // >>> 复制开始（放在 index.html 中 isUuid 定义之后，约 index.html:410 附近）
--
-- // 应用级命名空间：必须与 SQL public.habit_log_ns() 返回的字符串完全相同
-- const HABIT_NS = '6f5a1c8e-0d2b-5f47-9a3e-1c7d2b8e4a10';
--
-- function utf8Bytes(str){
--   const out = [];
--   for(let i=0;i<str.length;i++){
--     let c = str.charCodeAt(i);
--     if(c < 0x80) out.push(c);
--     else if(c < 0x800){ out.push(0xC0|(c>>6), 0x80|(c&0x3F)); }
--     else if(c >= 0xD800 && c <= 0xDBFF && i+1 < str.length){
--       const c2 = str.charCodeAt(i+1);
--       const cp = 0x10000 + ((c-0xD800)<<10) + (c2-0xDC00);
--       i++;
--       out.push(0xF0|(cp>>18), 0x80|((cp>>12)&0x3F), 0x80|((cp>>6)&0x3F), 0x80|(cp&0x3F));
--     } else {
--       out.push(0xE0|(c>>12), 0x80|((c>>6)&0x3F), 0x80|(c&0x3F));
--     }
--   }
--   return new Uint8Array(out);
-- }
--
-- // SHA-1，输入 Uint8Array，输出 Uint8Array(20)。同步实现。
-- function sha1Bytes(msg){
--   const ml = msg.length;
--   const blocks = Math.ceil((ml + 1 + 8) / 64);       // 0x80 + 8 字节长度
--   const total = blocks * 64;
--   const buf = new Uint8Array(total);
--   buf.set(msg);
--   buf[ml] = 0x80;
--   const bitLen = ml * 8;
--   const dv = new DataView(buf.buffer);
--   dv.setUint32(total - 8, Math.floor(bitLen / 0x100000000));   // 高 32 位
--   dv.setUint32(total - 4, bitLen >>> 0);                       // 低 32 位
--
--   let h0=0x67452301, h1=0xEFCDAB89, h2=0x98BADCFE, h3=0x10325476, h4=0xC3D2E1F0;
--   const w = new Uint32Array(80);
--   for(let b=0;b<blocks;b++){
--     const off = b*64;
--     for(let i=0;i<16;i++) w[i] = dv.getUint32(off + i*4);      // SHA-1 是大端
--     for(let i=16;i<80;i++){
--       const x = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16];
--       w[i] = (x << 1) | (x >>> 31);
--     }
--     let a=h0, bb=h1, c=h2, d=h3, e=h4;
--     for(let i=0;i<80;i++){
--       let f, k;
--       if(i<20)      { f = (bb & c) | ((~bb) & d);          k = 0x5A827999; }
--       else if(i<40) { f = bb ^ c ^ d;                      k = 0x6ED9EBA1; }
--       else if(i<60) { f = (bb & c) | (bb & d) | (c & d);   k = 0x8F1BBCDC; }
--       else          { f = bb ^ c ^ d;                      k = 0xCA62C1D6; }
--       const t = (((a<<5)|(a>>>27)) + f + e + k + w[i]) >>> 0;
--       e = d; d = c; c = ((bb<<30)|(bb>>>2)) >>> 0; bb = a; a = t;
--     }
--     h0=(h0+a)>>>0; h1=(h1+bb)>>>0; h2=(h2+c)>>>0; h3=(h3+d)>>>0; h4=(h4+e)>>>0;
--   }
--   const out = new Uint8Array(20);
--   const odv = new DataView(out.buffer);
--   odv.setUint32(0,h0); odv.setUint32(4,h1); odv.setUint32(8,h2);
--   odv.setUint32(12,h3); odv.setUint32(16,h4);
--   return out;
-- }
--
-- function uuidToBytes(u){
--   const h = String(u).replace(/-/g,'');
--   const b = new Uint8Array(16);
--   for(let i=0;i<16;i++) b[i] = parseInt(h.substr(i*2,2),16);
--   return b;
-- }
--
-- // RFC 4122 §4.3 UUID v5
-- function uuidV5(nsUuid, name){
--   const ns = uuidToBytes(nsUuid);
--   const nm = utf8Bytes(name);
--   const msg = new Uint8Array(ns.length + nm.length);
--   msg.set(ns,0); msg.set(nm, ns.length);
--   const h = sha1Bytes(msg);
--   h[6] = (h[6] & 0x0f) | 0x50;      // version = 5
--   h[8] = (h[8] & 0x3f) | 0x80;      // variant = RFC 4122
--   let s = '';
--   for(let i=0;i<16;i++) s += (h[i]>>>0).toString(16).padStart(2,'0');
--   return `${s.slice(0,8)}-${s.slice(8,12)}-${s.slice(12,16)}-${s.slice(16,20)}-${s.slice(20,32)}`;
-- }
--
-- // 习惯打卡行 id：三个入参必须与 SQL public.habit_log_name() 完全一致
-- //   lower(user_id) | lower(habit_id) | 'YYYY-MM-DD'
-- function habitLogId(userId, habitId, day){
--   return uuidV5(
--     HABIT_NS,
--     `${String(userId).toLowerCase()}|${String(habitId).toLowerCase()}|${day}`
--   );
-- }
--
-- // 自检（控制台跑一次，两次都必须 true 才能上生产）
-- //   console.log(uuidV5('6ba7b810-9dad-11d1-80b4-00c04fd430c8','www.widgets.com')
-- //     === '21f7f8de-8051-5b89-8680-0195ef798b6a');
-- //   console.log(habitLogId('3f2b1c0a-1111-4a22-9b33-000000000001',
-- //                          '8c7d6e5f-2222-4333-8444-000000000002','2026-08-28')
-- //     === '11d4e5a4-77cf-527a-90f6-ed44edf752f2');
-- //   console.log(isUuid(habitLogId(me.id, hb.id, todayStr())));   // 必须 true
-- // <<< 复制结束
--
-- ------------------------------------------------------------
-- 【前端改动清单】（详细「现在 / 改成」对照见交付文档中的表格）
--
--  A. 打卡写入路径（index.html:988）
--     现在：hb.doneDates.push(t) / splice → syncUpdate('habits', hb) → 整行覆盖
--     改成：const row = { id: habitLogId(me.id, hb.id, todayStr()),
--                         habitId: hb.id, day: todayStr(),
--                         value: nextValue, updatedAt: Date.now() };
--           syncInsert('habitLogs', row);
--     读路径（index.html:975/977）改成查 S.habitLogs 里 (habitId, day) 的 value>=1。
--
--  B. flushPending（index.html:492-499）
--     habitLogs 的 id 是前端算好的 uuid，会走 update 分支；但行可能不存在 →
--     update 命中 0 行且不报错 → 永远同步不上去。必须特殊处理：
--       if(kind === 'habitLogs'){
--         const { data, error } = await sb.rpc('upsert_habit_log',
--           { p_habit: r.habitId, p_day: r.day, p_value: r.value,
--             p_updated_at: new Date(r.updatedAt).toISOString() });
--         ...
--       }
--     通用规则：**凡前端自算 id 的表，一律 upsert，不能走 update。**
--
--  C. syncDelete（index.html:454-462）
--     现在：S.pendingDeletes.push({kind,id}) → 物理 delete（509）
--     改成：软删 —— row.deletedAt = Date.now(); row.updatedAt = Date.now();
--           row.cloudPending = true; save(); await flushPending();
--           然后从 S[kind] 移除。pendingDeletes 只保留做「历史残留硬删」的兜底。
--
--  D. toCloud（index.html:412-426）
--     habits 补 type / target / deleted_at；新增 case 'habitLogs'。
--     deleted_at 必须传 ISO 字符串（同 done_time 的教训，不能传毫秒数字）。
--
--  E. fromCloud（index.html:427-436）
--     五张表补 deletedAt = r.deleted_at ? new Date(r.deleted_at).getTime() : null
--     新增 case 'habitLogs'。
--
--  F. mergeRows（index.html:524-544）
--     · 第 528 行 cloudPending 分支：local.deletedAt 非空 → 不 push（别把已删的传上去）
--     · 第 537-540 行：c.deletedAt 非空 → 不 push（云端已删，本机跟着删）
--     · habitLogs 的 value 合并：check 模式 LWW；count 模式用 Math.max
--       （LWW 会把「读到旧值后 +1 再写回」的计数丢掉，max 至少单调不减；
--        严格正确需要 PN-counter + delta 表，本次不做，见风险 R-5）
--
--  G. pullPlans（index.html:550-556）
--     · 五张表 select 加 .is('deleted_at', null)
--     · 新增 habit_logs 拉取（时间窗规则见 §3 文档部分）
--
--  H. save()（index.html:277）—— 见文档第三部分，配额降级阶梯
--
--  I. sw.js:2  const CACHE = 'planapp-v7'  → 发版时必须改成 v8。
--     否则用户端一直用旧 bundle，新旧版本混合期被无限拉长，
--     tombstone 的兼容窗口就守不住了。


-- ============================================================
-- §7 执行顺序（严格遵守，顺序错了会出错或产生新旧版本混合期）
-- ============================================================
--
--  阶段 0  备份
--          Supabase Dashboard → Database → Backups，确认有可用备份；
--          或 pg_dump 一份。两个真实用户的数据，这一步不能省。
--
--  阶段 1  跑本文件 §0（只到自检为止）
--          确认 Output 里两行都是「自检通过」。不通过就停在这里。
--
--  阶段 2  前端发「只读兼容版」
--          只做 §6 的 E（fromCloud 认识 deletedAt）+ F（mergeRows 跳过已删行）
--          + 读路径优先读 habitLogs、读不到再回退 doneDates。
--          此时 DB 还没改，这一步零风险，但为的是让慢更新的设备先具备
--          识别 deleted_at 的能力 —— 否则一旦上了 DDL，旧 bundle 会把
--          软删的行 merge 回来，造成「已删数据复活」。
--          同时把 sw.js:2 的 CACHE 改成 v8。
--
--  阶段 3  跑本文件 §1 + §2（顺序不能反：§2 加的 deleted_at 被 §3 用到）
--
--  阶段 4  跑本文件 §4 验收查询
--          4.1 对得上 = true；4.3 id_mismatch_rows = 0；
--          4.2 的 expect_id_for_today 与前端 habitLogId() 输出手比一次。
--
--  阶段 5  跑本文件 §3 回填
--          再跑一次 4.1 对账。
--
--  阶段 6  前端发「完整版」（§6 的 A/B/C/D/G/H）
--
--  阶段 7  观察 3~7 天，确认没有同步异常后，再考虑挂 purge_deleted 的定时任务。
--
-- ============================================================
-- §8 风险评估
-- ============================================================
--  R-1  add column 阻塞？        低。PG11+ 带常量默认值的 add column 只改元数据；
--                                 deleted_at 无默认值同样是元数据操作。habits 只有个位数行。
--  R-2  破坏现有两个用户的数据？  低。全部是「加列 / 加新表 / 加索引」，
--                                 没有任何 update/drop/alter column type。
--                                 done_dates 全程不动，§1 可 100% 回滚。
--  R-3  旧 bundle 兼容性          中。旧前端 select('*') 会多拿到 deleted_at = null 的字段，
--                                 fromCloud 忽略未知字段 → 无影响；
--                                 旧前端 toCloud 不含 type/target → 走 DB 默认值 → 无影响。
--                                 唯一风险是 §2 上线后旧 bundle 不认识 deleted_at 非 null 的行，
--                                 会把它们 merge 回本地 → 已删数据复活。
--                                 缓解：阶段 2 先发只读兼容版 + sw.js 缓存版本 +1。
--  R-4  count 模式并发计数不精确  中。两台设备同一天各 +1 → 正确值 2，max 合并得 1。
--                                 发生概率低（同一习惯同一天两台设备都计数）。
--                                 严格解法是 PN-counter（habit_log_deltas 表按
--                                 (log_id, device_id) 唯一，求和），留作后续。
--  R-5  year_goals 硬删误伤       中。purge 一个软删的年目标会把活着的月目标的
--                                 year_goal_id 置 null（外键 on delete set null）。
--                                 已在 purge_deleted 里加 not exists 守卫。
--  R-6  to_char 的 STABLE 属性    低。habit_log_name 标 STABLE（to_char(date,text) 是
--                                 STABLE 不是 IMMUTABLE）。只用于触发器，不进索引，
--                                 不影响正确性。切勿改成 IMMUTABLE 后拿去建索引。
--  R-7  realtime 负载             低。habit_logs 进 publication，若前端不订阅则无成本；
--                                 订阅了也只是每天几次变更。
--  R-8  命名空间常量写死          高（后果）/ 低（概率）。HABIT_NS 一旦上线就不能改，
--                                 改 = 所有历史 habit_logs 主键失配。
--                                 缓解：SQL 与 JS 各写一份，阶段 4 做一次人工比对。
-- ============================================================
-- 草稿结束。未执行。
-- ============================================================
