-- ============================================================
-- P1.5 附加迁移：user_settings 表（warmMessage + cleared 同步）、
--       year_goals/month_goals 加 description 字段（编辑用）
-- ============================================================

-- 1. year_goals 加 description（编辑时需要）
--    已有数据不受影响，新插入的行会有这个字段

-- 2. user_settings 表：每个用户一行，固定 id
create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  warm_message jsonb default '{}'::jsonb,           -- {"text":"","updatedAt":null}
  cleared jsonb default '{}'::jsonb,                 -- {"2026-08-29":true, ...}
  created_at timestamptz default now()
);

-- 注册时自动创建
drop trigger if exists on_settings_created on auth.users;
create or replace function handle_new_settings()
returns trigger language plpgsql security definer as $$
begin
  insert into public.user_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end; $$;
create trigger on_settings_created
  after insert on auth.users
  for each row execute function handle_new_settings();

-- 3. 权限
alter table public.user_settings enable row level security;
create policy "自己的设置" on public.user_settings for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 4. user_settings 加入 realtime（清标记需要）
do $$
begin
  alter publication supabase_realtime add table public.user_settings;
exception when duplicate_object then null;
end $$;
