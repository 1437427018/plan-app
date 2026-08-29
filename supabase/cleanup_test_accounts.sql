-- 清理端到端测试残留账号
-- 真实账号（如 wx13994393503@163.com）不匹配 e2e% / diag%，不受影响
-- auth.users 上的删除会级联清掉 profiles / tasks 等（建表时都是 on delete cascade）
delete from auth.users
where email like 'e2e%' or email like 'diag%';
