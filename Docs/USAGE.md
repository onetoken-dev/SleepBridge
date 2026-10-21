# 使用、恢复与排障

## 路径

| 项目 | 路径 |
| --- | --- |
| Root helper | `/Library/Application Support/SleepBridge/SleepBridgeHelper` |
| 配置 | 同目录 `config.json` |
| 服务状态 | 同目录 `status.json` |
| 服务日志 | 同目录 `events.log` |
| 本机控制接口 | 同目录 `control.sock` |
| launchd plist | `/Library/LaunchDaemons/local.sleepbridge.helper.plist` |
| 用户历史 | `~/Library/Application Support/SleepBridgeHistory/history.json` |

这些是产品运行路径，不是构建输入。构建和自动测试不写入生产路径。

## 管理员授权

首次启用、调整策略、修复服务和卸载通过 macOS 管理员认证执行。日常手动硬盘休眠通过已授权 helper 的 socket 执行，不重复要求密码。

`-60005` 表示系统没有通过管理员身份验证；使用管理员账户的名称和该账户登录密码。应用不读取或保存密码。取消授权时不继续执行受保护操作。

## 只读诊断

```bash
'/Library/Application Support/SleepBridge/SleepBridgeHelper' --control ping
launchctl print system/local.sleepbridge.helper
pmset -g custom
pmset -g sched
pmset -g assertions
```

GUI 的“监测与日志”也可读取这些信息。`ping` 失败不等于升级没完成；同时检查服务运行、协议、状态更新时间与相关日志。新打开 GUI 时应等待首次状态刷新完成。

“请求已接受”只是服务接受命令。“Sleep”是系统进入睡眠的事件。“Wake from Hibernate”才是从磁盘恢复的系统证据。

## 停用与卸载

优先使用 GUI：后台服务 → 停用并恢复原设置 / 卸载后台服务。

如果界面不可用，先恢复模式：

```bash
sudo '/Library/Application Support/SleepBridge/SleepBridgeHelper' --disable
```

确认恢复成功后，再卸载指定服务和它的安装目录：

```bash
sudo launchctl bootout system/local.sleepbridge.helper
sudo rm -f '/Library/LaunchDaemons/local.sleepbridge.helper.plist'
sudo rm -rf '/Library/Application Support/SleepBridge'
```

这些命令只适用于已经安装的 SleepBridge。`--disable` 失败时先排查，不要跳过恢复直接删除。用户历史单独保留；可自行在 Finder 删除 `~/Library/Application Support/SleepBridgeHistory/`。应用本身可以移到废纸篓。

## 图标与升级

应用与 helper 是两个进程。替换 `.app` 不会自动替换已安装的 root helper。需要更新协议或 helper 行为时，在 GUI 使用“升级／修复后台服务”。仅统计界面更新不要求更换兼容 helper。

如果 Dock 中固定的图标仍指向旧副本，从 Dock 移除旧快捷方式，再固定新构建的应用；不要为了刷新图标去修改系统安全设置。
