---
titleTemplate: false
---

# Drover — 支持

Drover 让你在手机上监督和操控运行在自己电脑上的 AI 编程智能体。

**联系方式：** kei.sj.nstn@gmail.com — 这是找到开发者最快的途径。你也可以在 https://github.com/keinstn/drover/issues 提 issue。

反馈时请附上你的 Drover 版本（设置 → 版本，点一下即可复制）、iOS 版本，以及问题发生时你正在做什么。

## 使用 Drover 需要准备什么

Drover 是连接你已有机器的客户端，无法单独运行。你需要：

1. **一台运行 [Herdr](https://herdr.dev) 的电脑**，并且你的编程智能体运行在其中。
2. **能用密钥认证 SSH 连到那台机器。**
   - macOS: 系统设置 → 通用 → 共享 → 远程登录 (System Settings → General → Sharing → Remote Login)。
   - Windows: 安装 OpenSSH Server 功能。如果用的是**管理员**账户，公钥必须放在 `C:\ProgramData\ssh\administrators_authorized_keys`，而不是 `~\.ssh\authorized_keys`，否则连接会以 "All authentication methods failed"（所有认证方式均失败）告终。
3. 那台机器上的 **Herdr 0.8.0 或更新版本**。Drover 会强制检查这一点，在更旧的 Herdr 上启动智能体会失败。Drover 依赖的 `agent prompt` 以及 `--pane` / `--until` 这几种命令写法，从 0.7.5 起才有；而从 0.8.0 起，Herdr 会把「后台服务已停止」这件事报告得足够清楚，Drover 才能如实告诉你，而不是抛出一个看起来像网络故障的错误。

如果你只是想在动手准备这些之前先看看 Drover 是什么样子，可以用设置画面上的演示。它完全跑在你的设备上，用的是示例数据。

## 常见问题

**"Connection closed before authentication"（认证之前连接就被关闭了）**
主机上有别的东西抢在操作系统的 SSH 服务之前应答了 SSH 端口，于是操作系统根本没看到这个连接。常见元凶是 **Tailscale SSH**，它的连接检查会把会话截走——请为那台机器关掉 Tailscale SSH，或者改连机器本来的 SSH 端口。用 VPN 本身不是问题：Drover 在 VPN 下工作正常，所以要找的是截走端口的东西，而不是 VPN。

**会话记录显示的是原始终端文字，而不是好读的聊天**
只有当主机上装了对应智能体的 Herdr integration 时，Drover 才会读取该智能体自己的会话历史。请在主机上装一个：

```sh
herdr integration install claude
herdr integration install codex
herdr integration install copilot
```

integration 只对安装**之后**开始的会话生效，所以装完请重新开一个智能体会话。没有 integration 时，Drover 会退回去读终端窗格的内容，能读到多少取决于 Herdr 保留了多少回滚缓冲。

**语音输入启动不了**
Drover 只使用设备本地的语音识别。如果你的设备无法在本地完成识别，Drover 不会退回到服务器端识别，语音输入也就用不了。请在 iOS 设置里确认识别所用的语言包已经下载。

**收不到通知**
通知需要先与主机配对，而配对要求那台机器上装有 `drover.notify` 这个 Herdr plugin。通知的设置说明见 https://github.com/keinstn/drover 上的文档。只有 `blocked`（等你回应）事件会发通知——智能体干完活时 Drover 不会通知你。

## 隐私

Drover 从你的设备直接连到你自己的机器。你的会话记录、命令和代码都不会到开发者手里。唯一会把数据送出设备的功能是可选的语音助手：语音会话进行期间，你的语音以及助手作答所需的智能体上下文会发送给 Google。详见[隐私政策](/privacy/)（仅提供英文版，它是在 App Store Connect 登记的、具有法律效力的文本）。

## 文档

完整的设置说明与命令参考： https://github.com/keinstn/drover
