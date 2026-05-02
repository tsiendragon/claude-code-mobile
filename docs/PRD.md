# ccm (Claude Code Mobile) PRD

版本: v0.1  
日期: 2026-05-02  
状态: Draft

## 1. 背景

开发者越来越多地使用 Claude Code、Codex、OpenCode 等 CLI 编程助手处理真实代码库。但这些工具主要运行在桌面终端中，离开电脑后很难继续跟进任务、发送 prompt、审批代码修改或查看输出。

传统移动 SSH 客户端可以连接远程机器，但不适合 AI 编程助手场景：

- 手机键盘输入命令效率低。
- TUI 在小屏幕上显示混乱。
- 审批、选择、方向键等交互成本高。
- 多个 AI 会话难以管理。
- 无法提供移动端通知和结构化 UI。

ccm 的目标是把远程服务器上的 AI 编程助手包装成移动端友好的聊天式控制台。

## 2. 产品定位

ccm 是一个移动端 AI 编程助手远程控制 App。它不是 SSH 终端，也不是完整 IDE，而是一个面向 AI 编程代理的会话控制层。

核心定位：

- App 是结构化交互界面，不直接暴露原始终端。
- Bridge Server 负责连接远程机器上的 ccc/tmux/AI CLI。
- 用户在手机上以聊天方式发送 prompt、查看结果、审批修改、管理会话。
- 优先服务“离开电脑后继续控制 AI 编程任务”的场景。

## 3. 目标用户

主要用户：

- 经常使用 Claude Code、Codex、OpenCode 等 CLI 编程助手的开发者。
- 有一台常开开发机、家用服务器、云服务器或工作站的开发者。
- 希望在通勤、外出、休息时查看 AI 编程任务进度并做轻量干预的用户。

非目标用户：

- 需要在手机上完整写代码的用户。
- 需要完整远程桌面或完整 SSH 终端能力的用户。
- 不愿意部署任何服务端组件的纯移动端用户。

## 4. 核心使用场景

### 4.1 接管已有任务并查看进度

用户在电脑上通过 ccc 启动 Claude Code 任务后离开电脑。打开 ccm App，可以看到 Bridge 发现的现有 ccc 会话，并选择 attach 到某个会话继续跟进。

App 需要展示当前会话状态：

- ready
- thinking
- waiting for approval
- waiting for choice
- error

用户可以进入会话查看 AI 输出摘要和最新消息。

MVP 只要求接管 ccc 管理的会话，不要求识别任意 tmux session。

### 4.2 发送新 prompt

用户打开某个会话，直接输入新的 prompt，例如：

> 继续修复刚才失败的测试，只改必要文件。

App 将消息发送给 Bridge Server，Bridge 调用 ccc 写入对应 tmux 会话。

### 4.3 审批代码变更

当 AI 助手请求修改文件、执行命令或继续操作时，App 显示审批卡片：

- 变更说明
- 文件路径
- diff 摘要
- Accept
- Always
- Reject

用户点击按钮后，Bridge 调用 ccc 完成审批。

### 4.4 管理多个会话

用户可以在会话列表中看到多个项目：

- 项目名
- 后端类型
- 当前状态
- 最后一条输出
- 是否需要操作

支持创建、进入、终止会话。

### 4.5 远程查看文件

用户点击 AI 输出中的文件路径，App 请求 Bridge 读取远程文件。Bridge 校验路径权限后返回内容，App 用 Markdown 或代码高亮方式展示。

文件查看不进入 MVP，放入 Phase 2。Phase 2 只支持只读查看，不支持手机端直接编辑文件。

## 5. 产品目标

### 5.1 MVP 目标

MVP 需要验证一个核心闭环：

> 手机 App 可以安全连接远程 Bridge Server，并控制一个 ccc 管理的 AI 编程会话。

MVP 必须支持：

- 配置一个服务器地址和 Token。
- WebSocket 连接 Bridge Server。
- Token 认证。
- 查看会话列表。
- attach 到已有 ccc 会话。
- 创建会话。
- 进入聊天页面。
- 发送 prompt。
- 接收 AI 输出和状态变化。
- 显示 thinking/ready/approval 状态。
- 执行审批操作。
- 中断当前任务。

### 5.2 非 MVP 范围

以下能力不进入第一版：

- 完整文件浏览器。
- 文件只读查看。
- 本地通知。
- 多设备同步。
- 多用户权限系统。
- 手机端编辑远程文件。
- 插件市场。
- 完整 SSH 客户端。
- 原始 tmux/TUI 长期显示。

## 6. 系统架构

### 6.1 总体架构

```text
Flutter App
  <-> WebSocket / WSS
Bridge Server
  <-> ccc CLI
ccc
  <-> tmux sessions
tmux
  <-> Claude Code / Codex / OpenCode
```

### 6.2 Flutter App 职责

- 服务器配置。
- Token 安全存储。
- WebSocket 连接管理。
- 会话列表 UI。
- 聊天 UI。
- Markdown 和代码片段渲染。
- 审批卡片交互。

Flutter App 不负责：

- SSH 登录。
- PTY 管理。
- tmux 控制。
- AI CLI 适配。
- 文件权限判断。

### 6.3 Bridge Server 职责

- 暴露 WebSocket API。
- Token 认证。
- 管理客户端连接。
- 调用 ccc 命令。
- 轮询或订阅 ccc 会话状态。
- 将 ccc 输出转换成结构化事件。
- 控制文件读取权限。
- 记录审计日志。

### 6.4 ccc 职责

- 管理 tmux 会话。
- 向 AI CLI 发送输入。
- 读取 AI CLI 输出。
- 检测 ready/thinking/approval/choosing 等状态。
- 执行 approve、interrupt、kill 等操作。

## 7. 远程连接方案

ccm 的服务端通常运行在用户自己的开发机、家用服务器、NAS、云服务器或办公室工作站上。不同网络环境需要不同连接方案。

### 7.1 方案 A: 有静态公网 IP + 域名

适用条件：

- 用户有固定公网 IP。
- 用户有域名。
- 可以配置路由器端口转发。

连接链路：

```text
手机 App
  -> wss://ccm.example.com
  -> 路由器 443 端口转发
  -> Caddy / nginx
  -> Bridge Server 127.0.0.1:8900
```

推荐配置：

- Bridge Server 只监听 `127.0.0.1:8900`。
- Caddy 监听 `443` 并自动签发 HTTPS 证书。
- 路由器只转发 `443`。
- SSH 管理端口可选，不应默认开放到公网。

Caddy 示例：

```caddyfile
ccm.example.com {
    reverse_proxy 127.0.0.1:8900
}
```

优点：

- 长期使用体验最好。
- App 直接使用标准 WSS。
- TLS 证书自动续期。

缺点：

- 需要域名和公网 IP。
- 需要正确配置防火墙和端口转发。

MVP 支持级别：必须支持。

### 7.2 方案 B: 有动态公网 IP + 域名

适用条件：

- 用户有公网 IP，但 IP 会变化。
- 用户有域名。

连接链路与方案 A 相同，但需要 DDNS 自动更新域名解析。

推荐方式：

- Cloudflare DNS + ddclient。
- 路由器内置 DDNS。
- 其他 DNS 服务商 API。

优点：

- 接近方案 A 的体验。
- 不需要固定公网 IP。

缺点：

- IP 变化后可能有短暂不可用。
- DDNS 配置复杂度略高。

MVP 支持级别：文档支持，产品无需特殊适配。

### 7.3 方案 C: 有公网 IP 但没有域名

适用条件：

- 用户有公网 IP。
- 用户没有域名，或不想配置域名。

可选路径：

1. 使用 Tailscale。
2. 使用自签证书 + 证书绑定。
3. 使用 `https://公网IP:端口`，但正式场景不推荐。

推荐优先级：

1. Tailscale。
2. 购买或绑定域名。
3. 自签证书。

原因：

- 公开 IP + 自签证书会带来证书信任和中间人风险。
- Android 客户端处理自签证书和证书绑定会增加实现复杂度。

MVP 支持级别：推荐使用 Tailscale，不优先做自签证书体验。

### 7.4 方案 D: 无公网 IP / CGNAT

适用条件：

- 路由器 WAN IP 不是真正公网 IP。
- 用户在运营商 CGNAT 后面。
- 无法做有效端口转发。

推荐方案：Tailscale。

连接链路：

```text
手机 App
  -> Tailscale 网络 100.x.x.x
  -> Bridge Server 100.x.x.x:8900
```

部署方式：

- 服务器安装 Tailscale。
- 手机安装 Tailscale App。
- 两端登录同一个 tailnet。
- Bridge Server 监听具体 Tailscale IP。
- 防火墙只允许 tailscale0 接口访问 Bridge 端口。

安全要求：

- 不推荐 Bridge Server 监听 `0.0.0.0`。
- 如确需监听 `0.0.0.0`，必须通过显式高级参数开启，例如 `--allow-wide-bind`。
- 开启 `--allow-wide-bind` 时，Bridge 启动日志必须打印高风险警告，并检查是否配置了 Token、限流和访问来源限制。
- Tailscale 模式下优先绑定具体 `100.x.x.x` 地址，避免意外暴露到 LAN 或公网接口。

优点：

- 不需要公网 IP。
- 不需要端口转发。
- 不需要域名。
- WireGuard 加密。
- 服务不直接暴露公网。

缺点：

- 手机需要开启 Tailscale VPN。
- 依赖 Tailscale 控制面。

MVP 支持级别：必须支持。App 只需要允许配置 `ws://100.x.x.x:8900` 或 `wss://100.x.x.x:8900`。

### 7.5 方案 E: Cloudflare Tunnel

适用条件：

- 用户没有公网 IP。
- 用户有托管在 Cloudflare 的域名。
- 用户不想在手机上开 Tailscale。

连接链路：

```text
手机 App
  -> wss://ccm.example.com
  -> Cloudflare Edge
  -> cloudflared tunnel
  -> Bridge Server 127.0.0.1:8900
```

优点：

- 无需暴露端口。
- 自带 HTTPS。
- 适合 CGNAT 环境。

缺点：

- 依赖 Cloudflare。
- TLS 在 Cloudflare 边缘终结，Cloudflare 是可信中间方。
- WebSocket 长连接需要心跳保活。
- 配置比 Tailscale 稍复杂。

安全建议：

- Cloudflare Tunnel 不能替代 Bridge 自身 Token 认证。
- 推荐启用 Cloudflare Access、mTLS 或 service token 作为额外保护。
- 如果用户不希望第三方中间方可见流量，应优先选择 Tailscale。

MVP 支持级别：文档支持，产品无需特殊适配。

### 7.6 方案 F: SSH 隧道

适用条件：

- 临时调试。
- 开发阶段。
- 用户已经可以 SSH 到服务器。

示例：

```bash
ssh -L 8900:127.0.0.1:8900 user@server
```

然后 App 连接本地或局域网转发地址。

优点：

- 简单。
- 安全。
- 适合调试。

缺点：

- 不适合长期使用。
- 手机端维持 SSH 隧道体验较差。

MVP 支持级别：开发调试支持，不作为主推方案。

### 7.7 连接方案选择

推荐决策：

```text
有公网 IP + 有域名
  -> Caddy + WSS

有公网 IP + 无域名
  -> Tailscale 优先

动态公网 IP + 有域名
  -> DDNS + Caddy + WSS

无公网 IP / CGNAT
  -> Tailscale 优先
  -> Cloudflare Tunnel 备选

临时调试
  -> SSH 隧道
```

### 7.8 App 对连接方式的要求

App 不需要理解用户使用的是公网 IP、Tailscale 还是 Cloudflare Tunnel。App 只需要支持以下配置：

- Server URL: `wss://ccm.example.com/ws`
- Server URL: `ws://100.x.x.x:8900`
- Token
- 可选: 允许不安全连接，仅限 Tailscale/局域网/开发模式

默认策略：

- 公网地址必须使用 `wss://`。
- `ws://` 仅允许在受限地址范围内使用。
- Tailscale 场景可以允许 `ws://`，但 UI 要提示其依赖 VPN 隧道加密。

`ws://` URL 校验规则：

- 允许 `127.0.0.1`、`localhost`。
- 允许 RFC1918 私网地址：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`，但需要明确警告。
- 允许 Tailscale/CGNAT 常见地址段 `100.64.0.0/10`，但需要提示用户确认当前连接依赖 Tailscale 或其他私有隧道。
- 默认拒绝 `ws://` 连接公网 IP 或公网域名。
- 用户不能仅靠“允许不安全连接”绕过公网 `ws://` 限制。

### 7.9 服务端首次部署流程

MVP 文档必须覆盖从新服务器到 App 连接成功的最短路径。

用户需要完成：

1. 安装 Node.js、tmux、ccc 和至少一个 AI 后端 CLI。
2. 安装或下载 Bridge Server。
3. 创建 Bridge 配置文件。
4. 配置 `workspace_root`，默认可以使用 `~/workspace`。
5. 如需高级绝对路径，配置 `allowed_paths`，例如 `["~/workspace", "/home/user/projects"]`。
6. 生成或填写 Token。
7. 选择连接方式：Caddy + WSS 或 Tailscale。
8. 启动 Bridge Server。
9. 在 App 中填写 Server URL 和 Token。
10. 执行连接测试。

Bridge 启动时必须打印：

- 当前监听地址。
- 是否启用 TLS 终结代理模式。
- 是否允许 `ws://`。
- `workspace_root` 摘要。
- `allowed_paths` 摘要。
- Token 来源：自动生成、配置文件或环境变量。
- App 可填写的示例 Server URL。

Bridge 启动时不得打印完整 Token 到日志文件。首次生成 Token 时可以打印到交互式终端，但日志中只能记录 Token 前缀或 hash。

## 8. 功能需求

### 8.1 服务器配置

MVP 支持保存一个服务器配置：

- 名称
- Server URL
- Token
- 是否允许不安全连接

验收标准：

- Token 存入系统安全存储。
- 用户可以测试连接。
- 认证成功后显示服务器在线。
- 认证失败时展示明确错误。
- 如果用户输入公网 `ws://` 地址，App 必须拒绝保存。
- 多服务器配置不进入 MVP。

### 8.2 会话列表

展示当前服务器上的 AI 会话。

字段：

- session_id
- 会话名称
- 后端类型
- 当前状态
- 最后一条消息摘要
- 最后活跃时间
- 是否需要用户操作

交互：

- 点击进入聊天页。
- attach 到已有会话。
- 新建会话。
- 终止会话。
- 下拉刷新。

排序规则：

1. approval / choosing 置顶。
2. thinking 次之。
3. ready 按最后活跃时间倒序。
4. ended 沉底。

### 8.3 新建会话

用户输入：

- 会话名
- 工作目录
- 后端类型
- 可选初始 prompt

MVP 后端类型：

- claude

后续扩展：

- codex
- opencode
- cursor-agent

验收标准：

- 会话名校验失败时提示。
- 工作目录不在白名单时拒绝。
- 创建成功后 Bridge 返回不可变 `session_id`。
- 创建成功后进入聊天页。
- 如果有初始 prompt，自动发送。

### 8.4 聊天页

核心区域：

- 顶部栏：会话名、后端、状态。
- 消息流：用户消息、AI 消息、系统消息、审批卡片。
- 输入区：多行 prompt 输入。
- 操作区：发送、中断、快捷命令。

验收标准：

- 用户发送消息后立即显示本地消息。
- 每条用户消息带 `client_msg_id`。
- Bridge 接收后返回 accepted，后续通过事件确认 delivered 或 failed。
- AI 输出以结构化消息展示。
- thinking 状态可见。
- 用户可以中断当前任务。
- 断线时输入区禁用并提示重连。

### 8.5 审批卡片

当会话进入 approval 状态时，App 插入审批卡片。

内容：

- approval_id。
- 操作说明。
- 操作类型：文件修改、命令执行、选择确认等。
- 相关文件路径。
- diff 摘要。
- 审批内容 hash。
- Accept。
- Always。
- Reject。

验收标准：

- 点击后按钮进入 loading。
- 审批请求必须绑定 `approval_id`，不能只按 session 审批。
- 如果审批已过期、已处理或 hash 不匹配，Bridge 必须拒绝。
- Bridge 返回成功后卡片变为已处理。
- 已处理卡片不可重复点击。
- 失败时允许重试。
- MVP 中 `Always` 仅允许作用于当前 session 内同类低风险操作，不做跨会话或长期持久化。

### 8.6 文件只读查看

Phase 2 支持从消息中的文件路径打开文件。

支持：

- Markdown。
- 常见代码文件。
- 纯文本。
- JSON/YAML。

限制：

- 只读。
- 最大 5MB。
- 只允许白名单目录。
- 拒绝敏感文件。

验收标准：

- 文件路径点击后打开查看器。
- Markdown 正确渲染。
- 代码文件使用等宽字体和基础高亮。
- 无权限或文件过大时展示错误。

## 9. 协议需求

### 9.1 基础消息格式

所有业务消息使用 JSON。

```json
{
  "type": "message.type",
  "id": "req_123"
}
```

### 9.2 认证

请求：

```json
{
  "type": "auth",
  "id": "req_1",
  "token": "Bearer xxx",
  "client": {
    "device_id": "device-uuid",
    "app_version": "0.1.0",
    "protocol_version": 1
  }
}
```

响应：

```json
{
  "type": "response",
  "id": "req_1",
  "ok": true,
  "data": {
    "status": "authenticated"
  }
}
```

### 9.3 请求响应

```json
{
  "type": "response",
  "id": "req_123",
  "ok": false,
  "error": {
    "code": "SESSION_NOT_FOUND",
    "message": "session not found"
  }
}
```

### 9.4 会话请求

```json
{ "type": "session.list", "id": "req_1" }
{ "type": "workspace.list", "id": "req_2" }
{ "type": "workspace.create", "id": "req_3", "name": "myproject" }
{ "type": "session.run", "id": "req_4", "name": "myproject", "workspace_id": "myproject", "backend": "claude" }
{ "type": "session.run", "id": "req_5", "name": "legacy-path", "cwd": "/home/user/project", "backend": "claude" }
{ "type": "session.kill", "id": "req_6", "session_id": "sess_abc123" }
{ "type": "session.attach", "id": "req_7", "session_id": "sess_abc123" }
```

`workspace.list` 返回 Bridge 允许 App 展示的工作区，默认来自服务端 `~/workspace` 下的一级子目录。`workspace.create` 只创建单段目录名，禁止路径分隔符和默认隐藏目录。

`session.run` 必须传且只传 `workspace_id` 或 `cwd` 之一。`cwd` 是服务端机器上的绝对路径，仅作为高级入口使用，且必须位于 `allowed_paths` 内。

`session.run` 成功后返回：

```json
{
  "type": "response",
  "id": "req_2",
  "ok": true,
  "data": {
    "session_id": "sess_abc123",
    "name": "myproject",
    "backend": "claude",
    "state": "ready"
  }
}
```

协议要求：

- `session_id` 是 Bridge 生成的不可变 ID。
- `name` 是用户可见名称，可以与 ccc/tmux handle 相同，但不能作为协议唯一标识。
- 同名会话被终止后重新创建，必须得到新的 `session_id`。
- 事件流、审批、重连、审计均以 `session_id` 为准。

### 9.5 交互请求

```json
{
  "type": "message.send",
  "id": "req_5",
  "session_id": "sess_abc123",
  "client_msg_id": "msg_client_001",
  "text": "修复失败测试"
}
{
  "type": "message.approve",
  "id": "req_6",
  "session_id": "sess_abc123",
  "approval_id": "appr_001",
  "action": "yes",
  "idempotency_key": "idem_001"
}
{
  "type": "message.interrupt",
  "id": "req_7",
  "session_id": "sess_abc123"
}
{
  "type": "command.send",
  "id": "req_8",
  "session_id": "sess_abc123",
  "client_msg_id": "msg_client_002",
  "command": "/compact"
}
```

`message.send` 的 response 只表示 Bridge 已接受请求，不表示 AI CLI 已处理成功。实际投递结果必须通过事件通知：

- `message_delivered`
- `message_failed`

### 9.6 服务端事件

Bridge 主动推送事件：

```json
{
  "type": "event",
  "session_id": "sess_abc123",
  "seq": 42,
  "event": {
    "kind": "state_changed",
    "state": "thinking"
  }
}
```

事件类型：

- `session_snapshot`
- `state_changed`
- `user_message`
- `message_delivered`
- `message_failed`
- `assistant_message`
- `approval_requested`
- `approval_resolved`
- `choice_requested`
- `choice_resolved`
- `error`

审批事件示例：

```json
{
  "type": "event",
  "session_id": "sess_abc123",
  "seq": 43,
  "event": {
    "kind": "approval_requested",
    "approval_id": "appr_001",
    "operation_kind": "file_edit",
    "description": "修改 src/auth.py",
    "paths": ["src/auth.py"],
    "diff_summary": "+15 -3",
    "content_hash": "sha256:...",
    "expires_at": "2026-05-02T10:00:00Z",
    "actions": ["yes", "no"]
  }
}
```

MVP 中 `Always` 是可选能力。如果提供，Bridge 必须在 `actions` 中显式返回 `always`，并同时返回其作用域说明。

### 9.7 会话状态机

MVP 状态：

- `ready`
- `thinking`
- `approval`
- `choosing`
- `error`
- `ended`

基础规则：

- `ready` 允许 `message.send` 和 `command.send`。
- `thinking` 允许 `message.interrupt`，是否允许追加 `message.send` 由后端 capability 决定。
- `approval` 允许 `message.approve` 和 `message.interrupt`。
- `choosing` 允许选择操作和 `message.interrupt`。
- `interrupt` 成功后，当前 pending approval 或 choice 必须失效。
- `ended` 不允许发送消息、命令或审批。
- `error` 可通过 `session.attach` 获取最新 snapshot，但是否可继续操作由 Bridge 返回的 capability 决定。

### 9.8 断线恢复

App 重连后可以请求指定会话的增量事件：

```json
{
  "type": "events.sync",
  "id": "req_9",
  "session_id": "sess_abc123",
  "after": 41
}
```

重连模型：

1. App 重新认证。
2. App 调用 `session.attach` 获取最新 snapshot。
3. App 使用 snapshot 中的 `last_seq` 或本地最后 seq 调用 `events.sync`。
4. 如果 Bridge 可以返回完整 delta，则 App 合并事件。
5. 如果 Bridge 返回 `EVENT_GAP`，App 必须丢弃该会话的本地未确认状态，以 snapshot 为准。

`session.attach` 返回：

```json
{
  "type": "response",
  "id": "req_4",
  "ok": true,
  "data": {
    "session_id": "sess_abc123",
    "name": "myproject",
    "backend": "claude",
    "state": "thinking",
    "last_seq": 42,
    "messages": [],
    "pending_approval": null,
    "capabilities": {
      "can_interrupt": true,
      "can_send_while_thinking": false
    }
  }
}
```

MVP 可以只保留内存事件缓存，但必须定义缓存策略：

- 每个 session 至少保留最近 200 条事件。
- Bridge 重启后事件缓存丢失，`events.sync` 必须返回 `EVENT_GAP`。
- App 遇到 `EVENT_GAP` 后以 `session.attach` snapshot 为准。
- 正式版再考虑持久化事件。

## 10. 安全需求

### 10.1 认证

- Bridge 使用随机 Token。
- Token 至少 256-bit 熵。
- Token 比较使用 constant-time comparison。
- WebSocket 建立后 5 秒内必须完成认证，否则 Bridge 主动断开。
- 认证前只允许 `auth` 消息，其他消息一律拒绝并断开。
- 认证失败立即断开连接。
- 连续认证失败需要限流。
- 默认单用户模式，同一时间只允许一个活跃 App 连接。
- 新连接认证成功后，旧连接会收到 `CONNECTION_REPLACED` 并被断开。
- Bridge 必须支持启动时从配置文件或环境变量加载 Token。
- Bridge 必须支持重新生成 Token；旧 Token 失效后现有连接应被断开。

### 10.2 传输安全

- 公网访问必须使用 WSS。
- 推荐通过 Caddy 或 nginx 终结 TLS。
- Bridge 默认只监听 `127.0.0.1`。
- Tailscale/局域网场景允许显式启用 `ws://`。
- Bridge 默认拒绝监听 `0.0.0.0`，除非用户显式开启高级参数。
- App 默认拒绝公网 `ws://` URL。

### 10.3 命令执行安全

- Bridge 调用 ccc 必须使用 `execFile` 或等价 API。
- 禁止使用 shell 拼接命令。
- 用户可见会话名最多 80 字符。
- 传给 ccc/tmux 的内部会话 handle 由 Bridge 从显示名生成安全 slug，只允许 `[a-z0-9_-]` 加随机后缀。
- 用户 prompt 最大 100KB。
- 单个 WebSocket 消息最大 256KB。
- 单个服务端事件最大 512KB，超过后必须截断并标记 `truncated: true`。
- 所有请求有超时。

### 10.4 文件安全

- 默认 `workspace_root` 为 `~/workspace`，`allowed_paths` 默认收敛到 `workspace_root`。
- App 普通创建流程只暴露 `workspace_root` 下的一级工作区子目录。
- `session.run` 必须传且只传 `workspace_id` 或 `cwd` 之一。
- `workspace_id` 解析后必须位于 `workspace_root` 内，并继续通过 `allowed_paths` 校验。
- 高级 `cwd` 是服务端机器上的绝对路径，必须位于 `allowed_paths` 内。
- 文件路径必须经过 `realpath`。
- 解析后路径必须位于白名单目录内。
- 默认拒绝隐藏目录和敏感目录，包括 `.git`、`.ssh`、`.aws`、`.config/gcloud`。
- 拒绝 `.env*`、`*.pem`、`*_rsa`、云厂商凭证、包管理器 token 文件等敏感文件。
- 拒绝二进制文件、设备文件、socket、FIFO 等特殊文件。
- 单文件最大 5MB。
- 目录列表最多返回 500 项。

### 10.5 运行权限

- Bridge 不允许 root 运行。
- Bridge 只拥有当前开发用户权限。
- 日志不记录完整 Token。
- 日志不记录完整 prompt 内容。
- 日志默认不记录完整绝对路径，只记录项目相对路径或 hash。
- 日志文件权限必须为 owner-only。
- 日志需要支持轮转和保留天数配置。

## 11. 非功能需求

### 11.1 性能

- WebSocket 连接建立后 1 秒内完成认证响应。
- 会话状态变化在 2 秒内反映到 App。
- 消息发送请求 1 秒内返回接受结果。
- 会话列表加载 2 秒内完成。

### 11.2 稳定性

- WebSocket 断开后自动重连。
- 重连使用指数退避。
- App 前后台切换后能恢复连接。
- Bridge 重启后 App 能显示离线并重连。
- MVP 必须支持 snapshot-based reconnect；事件持久化不进入 MVP。

### 11.3 可观测性

Bridge 日志记录：

- 启动配置摘要。
- 连接成功/失败。
- 认证成功/失败。
- 会话创建/终止。
- 消息发送长度。
- 审批操作。
- 文件访问路径和结果。
- ccc 命令错误。

不记录：

- 完整 Token。
- 完整 prompt。
- 完整文件内容。

## 12. MVP 验收标准

MVP 完成时应能演示以下流程：

1. 在远程服务器启动 Bridge Server。
2. Android App 配置服务器地址和 Token。
3. App 成功连接并认证。
4. App 展示 Bridge 发现的已有 ccc 会话。
5. App attach 到一个已有 Claude Code 会话。
6. App 创建一个新的 Claude Code 会话。
7. App 发送 prompt。
8. Claude Code 在远程 tmux 会话中收到输入。
9. App 显示 thinking 状态。
10. App 收到并显示 AI 输出。
11. 当需要审批时，App 显示带 `approval_id` 的审批卡片。
12. 用户点击 Accept 后，远程会话继续执行。
13. 用户可以中断会话。
14. 用户可以终止会话。

远程连接验收：

- 通过 Caddy + WSS 可以连接。
- 通过 Tailscale + `ws://100.x.x.x:8900` 可以连接。
- Token 错误时连接被拒绝。
- Bridge 默认不暴露在公网裸端口上。
- App 拒绝保存公网 `ws://` 地址。

断线恢复验收：

- App 断网后进入离线状态。
- 网络恢复后 App 自动重连并重新认证。
- App 调用 `session.attach` 获取最新 snapshot。
- 如果事件 delta 可用，App 补齐事件。
- 如果事件 delta 不可用，App 以 snapshot 为准并清理未确认状态。

## 13. 开发计划

### Phase 0: 技术验证

目标：验证 Bridge 到 ccc 的闭环。

内容：

- Node.js Bridge 原型。
- Token 认证。
- `session.list`。
- `workspace.list`。
- `workspace.create`。
- `session.run`。
- `message.send`。
- 轮询 `ccc read --json`。
- 推送 `state_changed` 和 `assistant_message`。
- 验证 `ccc read --json` 是否能稳定提供状态、审批和可去重输出。
- 验证 tmux 屏幕快照能否转换成 App 可接受的事件流。

产出：

- 可用 WebSocket API。
- 简单 CLI 或 Web 测试客户端。
- go/no-go 结论。

go/no-go 标准：

- 如果 ccc 能提供稳定消息边界或可可靠去重的输出，MVP 使用聊天消息流。
- 如果 ccc 只能提供屏幕快照，MVP 降级为“最新输出快照 + 状态 + 审批”，不承诺完整聊天历史。
- 如果 ccc 无法稳定检测 approval，MVP 不进入 App 开发，优先修复 Bridge/ccc 集成。

### Phase 1: App MVP

目标：完成手机端核心闭环。

内容：

- Flutter 项目初始化。
- 服务器配置页。
- 会话列表页。
- 聊天页。
- WebSocket 客户端。
- 消息发送。
- 状态显示。
- 审批卡片。
- attach 已有会话。
- 创建新会话。
- 基础断线重连。

产出：

- 可安装 Android APK。
- 可通过 Tailscale 或 WSS 控制远程会话。

### Phase 2: 文件查看和体验完善

内容：

- 文件路径识别。
- `file.read`。
- Markdown 查看器。
- 代码查看器。
- 快捷命令栏。
- 基础本地缓存。

### Phase 3: 加固和部署

内容：

- 速率限制。
- 日志审计。
- Caddy 部署文档。
- Tailscale 部署文档。
- Cloudflare Tunnel 部署文档。
- systemd 服务。
- Token 轮换命令和 App 重新认证体验完善。

## 14. 关键风险

### 14.1 ccc 输出是否足够结构化

风险：

如果 `ccc read --json` 只能提供屏幕快照，而不能提供稳定的消息边界，Bridge 需要自行做 diff 和消息切分。

缓解：

- Phase 0 优先验证。
- Bridge 内部使用事件序号和去重。
- MVP 可以先接受较粗粒度输出。

### 14.2 多后端行为不一致

风险：

Claude Code、Codex、OpenCode 的审批和选择行为不同。

缓解：

- MVP 只支持 Claude。
- 后端能力通过 capability 描述。
- 每个后端单独适配审批行为。

### 14.3 远程暴露风险

风险：

Bridge 一旦暴露公网且 Token 泄露，攻击者可能控制开发机上的 AI 编程助手。

缓解：

- 默认 localhost。
- 推荐 Tailscale。
- 公网必须 WSS。
- 限流和审计。
- 最小权限运行。

### 14.4 移动端复杂代码查看体验

风险：

手机屏幕不适合阅读大 diff 和大文件。

缓解：

- MVP 审批卡片只展示摘要。
- 大 diff 折叠。
- Phase 2 文件查看只读。
- 超大文件拒绝打开。

## 15. 后续待定问题

- ccc 当前 JSON 输出格式是否稳定。
- 是否需要 Bridge 自己持久化消息事件。
- Android 是否需要支持后台 WebSocket 常驻。
- Token 是否需要自动过期。
- 是否支持多服务器配置。
- 是否允许多个 App 同时连接同一 Bridge。
- App 是否需要显示原始 tmux 输出作为调试页面。
