-- ============================================================
-- P1 迁移：给 5 张个人计划表加 updated_at
-- 用途：多设备合并的依据（last-write-wins，比 updated_at）
-- 说明：updated_at 由前端显式写入（客户端逻辑时间），服务端只给 default 兜底，
--       不加 before update 触发器 —— 否则会覆盖前端传来的值，合并就失效了。
-- ============================================================

alter table public.year_goals    add column if not exists updated_at timestamptz default now();
alter table public.month_goals   add column if not exists updated_at timestamptz default now();
alter table public.tasks         add column if not exists updated_at timestamptz default now();
alter table public.habits        add column if not exists updated_at timestamptz default now();
alter table public.special_dates add column if not exists updated_at timestamptz default now();

-- 老数据补一个值，免得首次合并时全是 0 被新数据无条件覆盖
update public.year_goals    set updated_at = created_at where updated_at is null;
update public.month_goals   set updated_at = created_at where updated_at is null;
update public.tasks         set updated_at = created_at where updated_at is null;
update public.habits        set updated_at = created_at where updated_at is null;
update public.special_dates set updated_at = created_at where updated_at is null;
