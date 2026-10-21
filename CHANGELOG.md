# Changelog

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
