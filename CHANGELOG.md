# Changelog

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
