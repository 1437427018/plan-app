-- ============================================================
-- 字段类型一致性检查（只读，不写数据）
-- 用途：前端 toCloud() 传的值必须能被 Postgres 隐式转换，否则会静默同步失败。
--       曾经踩坑：done_time 传了 Date.now() 的毫秒数字，报 22008 out of range，
--       导致「勾完成」永远同步不上，而错误被重试逻辑掩盖了。
-- 改字段或改 toCloud() 后请重跑本文件。
-- ============================================================

select
  -- tasks
  'x'::text                          as title,
  'done'::text                       as status,
  '2026-08-29'::date                 as created_date,
  '2026-08-30'::date                 as plan_date,
  '2026-08-29'::date                 as original_date,
  '2026-08-29T08:47:00.000Z'::timestamptz as done_time,      -- 必须是 ISO，不能是毫秒数字
  null::timestamptz                  as done_time_null,      -- 未完成时的 null 也要能写
  0::int                             as delay_count,
  -- habits
  '{2026-08-29,2026-08-30}'::date[]  as done_dates,
  -- year_goals / month_goals
  2026::int                          as year,
  '2026-08'::text                    as month,
  null::uuid                         as year_goal_id,
  -- special_dates
  '2026-08-29'::date                 as sd_date,
  -- 公共
  '2026-08-29T08:47:00.000Z'::timestamptz as updated_at,
  null::uuid                         as user_id;
