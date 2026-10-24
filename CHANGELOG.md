# Changelog

## 1.4.2 — Lid-closed DarkWake transition

- 监听 powerd 的动态能力状态，并每秒补查；不再仅依赖完整唤醒通知。
- 合盖、达到阈值、CPU 已唤醒且图形未唤醒时，立即设置模式 25，随系统自然回睡；不等待 25 秒，不调用 sleepnow。
- 保留开盖完整唤醒的活动保护；未知能力、未知合盖状态、接电及未到期不转换。
- 操作锁忙时保留待执行周期，恢复模式时也会重试；重复通知不会重复转换。
- 服务页显示后台唤醒监听状态；补齐 DarkWake to FullWake 的原因解析。
- GUI 1.4.2、helper 协议 1.5；需要更新系统后台。新增隔离 DarkWake 回归；已在 M1 MacBook Air 完成一次合盖到期、DarkWake、自然回睡及 Hibernate 恢复验证，范围见 Docs/TESTING.md，不代表跨机型保证或零能耗。

## 1.4.1 — Automatic wake-check deadlock fix

- 修复到期唤醒检查中 Foundation waitUntilExit 重入定时器、重复等待自身 flock 的死锁。
- 后台服务改用有硬超时的 POSIX 子进程读取，日志解析移到串行工作队列；主循环锁采用非阻塞尝试。
- 同时解析本轮 Full Wake / DarkWake，识别带 smc 前缀的开盖和用户活动，不再复用过期唤醒原因。
- 新周期会丢弃旧异步结果；界面隐藏过期计划和不可确认的旧状态。
- 增加只读 diagnose 控制请求与延迟自动检查回归测试。
- 后台协议增至 1.4，旧服务需要安装修复。合盖完整自动转换仍待硬件验证。


## 1.4 — Initial source distribution

- 按 App、Helper、Shared、History 整理 Swift 源码。
- 添加 MIT、原创图标生成、构建／测试／打包脚本、中英文说明和 CI。
- 为通知阻塞修复加入可复现的隔离回归与可选 launchd 测试。
- 移除本机路径依赖、个人日志、开发临时产物和过时版本说明。
- GUI 1.4：时间范围、状态时间线、端点电量、历史推断、区间明细和 CSV。
- helper 协议仍为 1.3；源码整理不改变已经部署的后台服务。

## Earlier local iterations

- 1.3：异步 sleepnow，避免主循环与睡眠通知互相等待；手动磁盘休眠实机验证通过。
- 1.2：控制接口转入主运行循环；补充服务心跳。
- 1.1：日常请求交给已授权的本机服务，减少重复管理员认证。
- 1.0：初始 GUI、策略、监测、恢复与卸载。
