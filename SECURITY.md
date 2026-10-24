# 特权与安全边界

SleepBridge 是早期实验项目，尚未接受独立安全审计。

- GUI 不以 root 运行；安装／配置／恢复／卸载由 macOS 管理员授权的 helper CLI 执行。
- 后台 executable 和配置位于 root 拥有的 `/Library` 目录。
- Unix socket 只暴露 `ping`、只读 `diagnose` 和已启用策略下的 `hibernate`。服务器使用内核 `getpeereid` 校验启用时授权的 UID。
- socket 的文件模式允许建立连接，但命令许可仍由服务端 UID 检查决定。**该授权针对本机用户，不是代码签名或特定 GUI 进程授权**；同 UID 的其他进程也能发送受支持请求。
- 不监听 TCP，不提供远程命令、任意执行路径或网络 API。客户端和服务端响应有时间上限。
- root CLI 的配置参数由固定枚举、分钟范围和 UID 数字限制；调用它仍需要 root 权限。
- 当前采用本机临时签名和管理员脚本安装，没有实现 SMAppService / SMJobBless 的应用身份信任模型，也未公证。

如果发现授权绕过、生产目录被非授权写入、任意代码执行或状态恢复相关漏洞，报告时请只给必要的复现材料，不公开账户信息、密码或完整个人日志。托管仓库若开启 GitHub Private Vulnerability Reporting，请优先使用 Security → Report a vulnerability；否则先联系仓库维护者，不在公开 issue 中附敏感利用细节。
