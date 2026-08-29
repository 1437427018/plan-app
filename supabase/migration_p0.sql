-- ============================================================
-- P0 迁移：昵称落库正确化
-- 背景：原触发器用 split_part(email,'@',1) 填 profiles.display_name，
--       导致前端传的昵称（raw_user_meta_data.display_name）被邮箱前缀覆盖。
-- ============================================================

-- 1. 触发器改为优先读注册时填的昵称，没填才兜底邮箱前缀
create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
      split_part(new.email, '@', 1)
    )
  )
  on conflict (id) do nothing;
  return new;
end; $$;

-- 2. profiles 原来只有 select / update 策略，缺 insert
--    前端注册后想 upsert 会被 RLS 拦掉，这里补上
drop policy if exists "建自己" on public.profiles;
create policy "建自己" on public.profiles for insert with check (auth.uid() = id);

-- 3. 修正历史数据：昵称被邮箱前缀覆盖的，用注册时填的真名改回来
update public.profiles p
set display_name = trim(u.raw_user_meta_data->>'display_name')
from auth.users u
where u.id = p.id
  and nullif(trim(u.raw_user_meta_data->>'display_name'), '') is not null
  and p.display_name = split_part(u.email, '@', 1);
