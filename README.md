# SleepBridge

本地 macOS 睡眠策略与电量统计工具，使用 SwiftUI、IOKit 和系统 `pmset` 构建。

A local macOS sleep policy and battery history app. [English quick start](Docs/README.en.md).

**GUI 1.4 · 后台协议 1.3 · MIT**

[GitHub 仓库](https://github.com/onetoken-dev/SleepBridge) · [实验版下载](https://github.com/onetoken-dev/SleepBridge/releases) · [问题反馈](https://github.com/onetoken-dev/SleepBridge/issues)

SleepBridge 尝试让短时间睡眠保留快速唤醒，长时间后再进入磁盘休眠；同时把唤醒、RAM 睡眠、磁盘恢复与电量放在同一条时间线上。默认仅监测，启用策略时才通过 macOS 管理员授权安装后台服务。

## 功能

- 设置 1–1440 分钟的转换等待时间，选择仅电池或所有供电状态。
- 系统实际睡眠时开始计时；提前唤醒取消本轮转换。
- 到期安排一次系统唤醒，检查用户活动与供电范围，再请求磁盘休眠。
- 手动睡眠、手动请求磁盘休眠、状态与进程诊断。
- 1 小时 / 24 小时 / 7 天 / 30 天 / 自定义区间的时间线、电量轨迹和区间明细。
- 区分工具请求、系统事件和历史推断；导出 CSV，保留 90 天本地历史。
- 停用并恢复启用前的休眠模式；卸载后台服务。

## 状态与适用范围

这是早期实验项目，不保证精确的硬件休眠时刻。Apple silicon 上的策略通过“定时唤醒 → 再次请求睡眠”实现，系统可能推迟或忽略唤醒，或短暂点亮屏幕；macOS 也可能自行更早进入深度休眠。

- 已在 M1 MacBook Air、macOS 27.0.1 上验证一次手动磁盘休眠、唤醒、模式恢复及后台响应。
- **合盖后等待完整阈值再自动转换尚未实机验证。**
- 构建目标为 macOS 14.0+；这不等于所有机型和系统都验证通过。默认生成当前机器架构的程序。
- 没有开发者公证；脚本使用本机临时签名。

详细精度约束见 [历史数据模型](Docs/HISTORY.md)，测试范围见 [测试说明](Docs/TESTING.md)。

## 从源码构建

需要 macOS 和 Xcode Command Line Tools，或者完整 Xcode。建议使用带 Swift 6 的工具链；源码当前以 Swift 5 language mode 编译。

```bash
xcode-select --install  # 尚未安装开发工具时执行一次
./build.sh
open build/SleepBridge.app
```

构建脚本只编译、生成原创图标和临时签名，不安装服务、不修改电源设置、不自动启动应用。无第三方 Swift 包或包管理器依赖。

```bash
./build.sh /path/to/output   # 可选输出目录
make test                   # 不执行真实电源命令的测试
make test-launchd           # 可选；需要当前用户的 GUI 登录会话
make lint                   # 需要 xcrun swift-format
make format
make package                # dist/ 内生成原生架构应用 ZIP 和 SHA-256
```

`build/`、`.build/` 和 `dist/` 均忽略于 Git；仓库只保存源码和资源描述。构建输出内保留 MIT 许可证。

## 使用

1. 打开应用，在“睡眠策略”选择等待时间和供电范围。
2. 勾选已了解限制，点击“授权并启用”，由 macOS 系统窗口处理管理员认证。
3. 确认服务运行；合盖或系统睡眠时开始本轮计时。
4. 在“时间与电量”查看区间和电量，点击区间展开依据。
5. 从“后台服务”停用、恢复原设置，或者卸载服务。

退出应用后，已启用的后台策略仍运行；分钟电量采样暂停，下次打开会补读系统保留的事件。仅关闭主窗口不会退出应用。应用不主动联网、不上传日志、不保存管理员密码。

GUI 和后台协议分别版本化；GUI 1.4 能使用后台协议 1.3，单独增加统计界面不要求升级服务。

## 恢复

GUI 的“停用并恢复原设置”恢复启用前的电池与接电源 `hibernatemode`，只取消本工具的唤醒事件。后台服务安装过后，也可使用：

```bash
sudo '/Library/Application Support/SleepBridge/SleepBridgeHelper' --disable
```

卸载顺序、文件位置与诊断说明见 [使用与排障](Docs/USAGE.md)。不要在未停用服务时只删除应用或后台程序。

## 目录

```text
Sources/
  App/         SwiftUI 界面、状态模型、统计界面
  Helper/      launchd 服务、电源通知、原生定时唤醒
  Shared/      配置、模式解析、IPC、非阻塞休眠进程启动
  History/     系统日志解析、区间归类、电量与本地历史
Resources/     应用与 launchd plist
Scripts/       构建、测试、格式化、打包、原创图标生成
Tests/         合成数据与隔离服务测试
Docs/          架构、精度约束、排障、测试、英文说明
.github/       CI 与问题反馈模板
```

发布步骤见 [PUBLISHING.md](Docs/PUBLISHING.md)。架构见 [ARCHITECTURE.md](Docs/ARCHITECTURE.md)。参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)。特权边界和问题报告见 [SECURITY.md](SECURITY.md)。

## 许可证与素材

采用 [MIT](LICENSE)（[许可证原文来源](https://opensource.org/license/mit)）。应用图标由 `Scripts/GenerateIcon.swift` 中的原创几何路径生成，也按 MIT 分发。界面运行时使用系统符号；仓库不包含导出的系统符号图片或个人诊断数据。
