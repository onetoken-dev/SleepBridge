# 发布到公开仓库

此源码包已经包含 MIT、构建脚本、测试、CI 和项目说明。本地仓库未配置远端，也未创建提交；可先检查文件再提交。

如果使用源码 ZIP 解压而不是现有 Git 工作区，先在解压目录运行 `git init --initial-branch=main`。

## 使用 GitHub CLI

以下步骤由项目维护者在目标仓库目录执行，需要已登录 GitHub CLI，并自行确认公开发布的仓库名：

```bash
git status --short
git add .
git commit -m "Initial open source release"
gh repo create SleepBridge --public --source=. --remote=origin --push
```

这些命令会创建公开仓库并上传源码，不由构建或测试脚本自动执行。Git 提交使用维护者本机配置的身份；仓库不会设置全局 Git 身份。

也可先在 GitHub 创建空仓库，再将其 URL 添加为 `origin` 并推送 `main`。

## 应用发布

```bash
make test
make build
make package
```

`dist/` 生成当前机器原生架构的 `.app` ZIP 和 SHA-256 文件。可以把它们作为 GitHub Release 附件；不需要把二进制、`.build/`、`build/` 或 `dist/` 提交到 Git。

源码构建只提供临时签名。如果计划向更多用户分发，应由维护者自行配置 Apple Developer 签名／公证和相应发布流程。本项目不附带证书、私钥或公证凭据。

CI 文件将在推送后由 GitHub 执行；本地构建测试通过不表示远端 CI 已经运行。发布说明应保留“自动合盖转换未验证”的限制，直到有对应的实机测试证据。
