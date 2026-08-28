-- ============================================================
-- 小计划 PWA · 后端数据表（Supabase / PostgreSQL）
-- 用法：Supabase Dashboard → SQL Editor 粘贴运行；或 Supabase CLI 执行
-- 设计依据：knowledge-base.md 数据模型 + 四状态任务 + 两人共享
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- 1. 用户资料（账号由 Supabase Auth 管，这里只存展示信息）----------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz default now()
);

-- 注册时自动建 profile
create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, split_part(new.email, '@', 1))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- 2. 两人关系 ----------
create table if not exists relationships (
  id uuid primary key default gen_random_uuid(),
  user_a uuid references auth.users(id) on delete cascade,
  user_b uuid references auth.users(id) on delete cascade,
  created_at timestamptz default now(),
  unique (user_a, user_b)
);

-- ---------- 3. 年计划 ----------
create table if not exists year_goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  title text not null,
  description text,
  year int not null,
  created_at timestamptz default now()
);

-- ---------- 4. 月计划 ----------
create table if not exists month_goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  year_goal_id uuid references year_goals(id) on delete set null,
  title text not null,
  month text not null,            -- 'YYYY-MM'
  created_at timestamptz default now()
);

-- ---------- 5. 日任务（四状态）----------
create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  title text not null,
  status text not null default 'todo'
    check (status in ('todo','done','delayed','skipped')),
  created_date date default current_date,
  plan_date date default current_date,
  original_date date default current_date,
  done_time timestamptz,
  delay_count int default 0,
  created_at timestamptz default now()
);

-- ---------- 6. 习惯 ----------
create table if not exists habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  name text not null,
  done_dates date[] default '{}',
  created_at timestamptz default now()
);

-- ---------- 7. 特别日子 ----------
create table if not exists special_dates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  title text not null,
  date date not null,
  reminder_enabled boolean default true,
  created_at timestamptz default now()
);

-- ---------- 8. 今天的第一句话 / 悄悄话 ----------
create table if not exists whispers (
  id uuid primary key default gen_random_uuid(),
  from_user_id uuid references auth.users(id) on delete cascade,
  to_user_id uuid references auth.users(id) on delete cascade,
  text text not null,
  created_at timestamptz default now()
);

-- ---------- 9. 共享清单 ----------
create table if not exists shared_lists (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid references relationships(id) on delete cascade,
  title text,
  items jsonb default '[]'::jsonb,   -- [{id,text,done}]
  created_at timestamptz default now()
);

-- ============================================================
-- 行级安全（RLS）：每个人只能访问自己的数据 / 自己所在关系的数据
-- ============================================================
alter table profiles      enable row level security;
alter table relationships enable row level security;
alter table year_goals    enable row level security;
alter table month_goals   enable row level security;
alter table tasks         enable row level security;
alter table habits        enable row level security;
alter table special_dates enable row level security;
alter table whispers      enable row level security;
alter table shared_lists  enable row level security;

-- profiles：看/改自己
create policy "看自己" on profiles for select using (auth.uid() = id);
create policy "改自己" on profiles for update using (auth.uid() = id);

-- 个人数据：属于自己
create policy "自己的年计划" on year_goals for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "自己的月计划" on month_goals for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "自己的任务" on tasks for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "自己的习惯" on habits for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "自己的特别日子" on special_dates for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 关系：自己是其中一方
create policy "自己的关系" on relationships for all
  using (auth.uid() in (user_a, user_b)) with check (auth.uid() in (user_a, user_b));

-- 悄悄话：发送或接收方可见，只能自己发
create policy "自己的悄悄话" on whispers for all
  using (auth.uid() in (from_user_id, to_user_id))
  with check (auth.uid() = from_user_id);

-- 共享清单：属于自己所在的某段关系
create policy "自己的共享清单" on shared_lists for all
  using (relationship_id in (
    select id from relationships where auth.uid() in (user_a, user_b)))
  with check (relationship_id in (
    select id from relationships where auth.uid() in (user_a, user_b)));

-- ============================================================
-- 实时同步：把需要跨设备/双人同步的表加入 realtime 发布
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array[
    'shared_lists','whispers','tasks','year_goals',
    'month_goals','habits','special_dates','relationships'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
