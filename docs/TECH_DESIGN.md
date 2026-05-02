# ccm 技术设计文档

版本: v0.1  
日期: 2026-05-02  
状态: Draft  
对应 PRD: [PRD.md](./PRD.md)

## 1. 设计目标

本文档定义 ccm MVP 的技术实现方案。MVP 的目标是验证手机 App 可以安全连接远程 Bridge Server，并控制 ccc 管理的 Claude Code 会话。

MVP 技术范围：

- Bridge Server: Node.js WebSocket 服务。
- AI 会话管理: 通过 ccc CLI 操作 tmux 中的 Claude Code。
- Flutter App: Android 客户端，支持服务器配置、会话列表、聊天页、审批卡片和基础断线重连。
- 协议: JSON over WebSocket。
- 连接方式: Caddy + WSS、Tailscale + 受限 `ws://`。

MVP 不包含：

- 文件查看。
- 本地消息持久化。
- 多用户系统。
- 多服务器配置。
- 多后端完整适配。
- 原始终端 UI。

## 2. 总体架构

```text
Android Flutter App
  |
  | JSON over WebSocket
  | wss://domain/ws or ws://tailscale-ip:8900
  v
Bridge Server (Node.js)
  |
  | child_process.execFile()
  v
ccc CLI
  |
  v
tmux sessions
  |
  v
Claude Code
```

设计原则：

- Bridge 是唯一可信控制面，App 不直接执行 SSH、tmux 或 shell 操作。
- Bridge 调用 ccc 必须使用 `execFile`，禁止 shell 拼接。
- App 与 Bridge 之间只传结构化事件，不传原始 TUI 屏幕作为主 UI。
- 所有会话、审批和事件均使用 Bridge 生成的不可变 ID。
- Phase 0 先验证 ccc 输出能力，再决定 App 消息流展示粒度。

## 3. Bridge Server 设计

### 3.1 技术栈

- Runtime: Node.js 20 LTS。
- Language: TypeScript。
- WebSocket: `ws`。
- Config: JSON 或 YAML 配置文件。
- Process execution: `child_process.execFile`。
- Logging: `pino` 或 Node structured logger。
- Test: `vitest`。

Node.js 18 可作为最低运行版本，但开发和 CI 优先使用 Node.js 20。

### 3.2 目录结构

建议服务端目录：

```text
server/
  package.json
  tsconfig.json
  src/
    index.ts
    config.ts
    logger.ts
    ws/
      gateway.ts
      auth.ts
      protocol.ts
      validators.ts
    sessions/
      session-manager.ts
      state-poller.ts
      event-store.ts
      state-machine.ts
    ccc/
      ccc-client.ts
      ccc-parser.ts
      ccc-types.ts
    security/
      paths.ts
      rate-limit.ts
      token.ts
    files/
      file-service.ts
    types/
      protocol.ts
      domain.ts
  test/
```

MVP 可以先实现 `files/` 空壳，Phase 2 再启用文件读取。

### 3.3 运行配置

配置示例：

```json
{
  "host": "127.0.0.1",
  "port": 8900,
  "token_env": "CCM_TOKEN",
  "workspace_root": "~/workspace",
  "allowed_paths": ["~/workspace"],
  "allow_manual_cwd": true,
  "ccc_bin": "ccc",
  "poll_interval_ms": 1000,
  "event_buffer_size": 200,
  "max_prompt_bytes": 102400,
  "max_ws_message_bytes": 262144,
  "max_event_bytes": 524288,
  "allow_wide_bind": false,
  "allow_hidden_cwd": false,
  "log_level": "info"
}
```

启动规则：

- 默认监听 `127.0.0.1:8900`。
- 监听 `0.0.0.0` 时必须设置 `allow_wide_bind: true`，并打印高风险警告。
- 如果未提供 Token，开发模式可以交互式生成并打印一次；生产部署必须从配置文件或环境变量读取。
- `workspace_root` 默认 `~/workspace`，App 普通创建流程只允许创建其一级子目录。
- `allowed_paths` 默认等于 `workspace_root`，禁止设置为 `/`。
- 高级 `cwd` 只有在 `allow_manual_cwd: true` 时可用，且必须解析在 `allowed_paths` 内。
- Bridge 检测到 root 运行时直接退出。

### 3.4 核心模块

#### WebSocket Gateway

职责：

- 接受 WebSocket 连接。
- 设置 5 秒认证 deadline。
- 认证前只允许 `auth`。
- 校验协议版本。
- 处理请求响应。
- 推送服务端事件。
- 管理单用户连接替换。
- 心跳和断线检测。

连接状态：

```text
connected
  -> authenticating
  -> authenticated
  -> closing
```

关闭策略：

- 认证超时: close code `4001 AUTH_TIMEOUT`。
- 认证失败: close code `4003 AUTH_FAILED`。
- 协议版本不支持: close code `4004 UNSUPPORTED_PROTOCOL`。
- 新连接替换旧连接: close code `4009 CONNECTION_REPLACED`。
- 消息过大: close code `4013 MESSAGE_TOO_LARGE`。

#### Auth Service

职责：

- 解析 `Bearer <token>`。
- 使用 constant-time comparison。
- 跟踪认证失败次数。
- 支持 Token rotation。
- 新 Token 生效时断开旧连接。

MVP 不做多用户，不做 refresh token。

#### Session Manager

职责：

- 维护 `session_id -> SessionRecord`。
- 把 ccc/tmux 会话映射到 Bridge session。
- 处理 `session.list`、`session.run`、`session.attach`、`session.kill`。
- 处理 `workspace.list`、`workspace.create`，并把 `workspace_id` 解析为服务端 cwd。
- 启动和停止状态轮询。

SessionRecord:

```ts
type SessionRecord = {
  sessionId: string;
  name: string;
  backend: "claude";
  cwd: string;
  cccName: string;
  state: SessionState;
  createdAt: string;
  updatedAt: string;
  lastSeq: number;
  lastSnapshotHash?: string;
  pendingApproval?: ApprovalRecord;
  capabilities: SessionCapabilities;
};
```

`session_id` 由 Bridge 生成，例如 `sess_${base32(random)}`。`cccName` 是 ccc/tmux 使用的名字，不作为协议身份。

#### ccc Client

职责：

- 封装所有 ccc 命令。
- 使用 `execFile`。
- 设置 timeout。
- 标准化 stdout/stderr/error。
- 将 ccc JSON 转成内部领域对象。

命令映射：

```text
session.list      -> ccc ps --json
session.run       -> ccc run <safe-ccc-name> --cwd <resolved workspace/cwd> --claude
session.kill      -> ccc kill <safe-ccc-name>
message.send      -> ccc send <safe-ccc-name> <text> --no-wait
message.approve   -> ccc approve <safe-ccc-name> <action>
message.interrupt -> ccc interrupt <safe-ccc-name>
command.send      -> ccc input <safe-ccc-name> <command>
state polling     -> ccc read <safe-ccc-name> --json
```

`name` 是用户可见显示名，最多 80 字符。Bridge 传给 ccc/tmux 的 `safe-ccc-name` 由显示名生成 ASCII slug，并追加随机后缀，避免空格、路径分隔符或 shell 元字符进入底层 session handle。

具体参数以 ccc 实际 CLI 为准。Phase 0 必须验证命令签名。

#### State Poller

职责：

- 每 `poll_interval_ms` 读取活跃 session。
- 调用 `ccc read <name> --json`。
- 根据输出更新 SessionRecord。
- 生成事件。
- 避免重复推送。

轮询策略：

- `thinking`、`approval`、`choosing`: 1 秒。
- `ready`: 3 秒。
- `ended`: 停止轮询。
- ccc 连续失败 3 次后 session 进入 `error`，继续低频轮询。

#### Event Store

MVP 使用内存环形缓冲。

职责：

- 为每个 session 分配单调递增 `seq`。
- 保存最近 `event_buffer_size` 条事件。
- 支持 `events.sync(session_id, after_seq)`。
- Bridge 重启后丢失历史，返回 `EVENT_GAP`。

接口：

```ts
interface EventStore {
  append(sessionId: string, event: DomainEvent): StoredEvent;
  latestSeq(sessionId: string): number;
  listAfter(sessionId: string, seq: number): StoredEvent[] | EventGap;
  clear(sessionId: string): void;
}
```

`seq` 只在单个 session 内递增。

#### State Machine

状态：

```ts
type SessionState =
  | "ready"
  | "thinking"
  | "approval"
  | "choosing"
  | "error"
  | "ended";
```

允许操作：

| State | message.send | approve | interrupt | kill |
|-------|--------------|---------|-----------|------|
| ready | yes | no | no | yes |
| thinking | capability | no | yes | yes |
| approval | no | yes | yes | yes |
| choosing | no | choice only | yes | yes |
| error | capability | no | maybe | yes |
| ended | no | no | no | no |

`interrupt` 成功后必须清理 pending approval 和 pending choice。

### 3.5 ccc 输出转换

这是 MVP 最大技术风险。Bridge 不能假设 ccc 输出天然等于聊天消息。

Phase 0 需要验证 ccc JSON 是否包含：

- 当前状态。
- 可稳定识别的 assistant 输出。
- 是否有输出 cursor 或 message id。
- approval 状态和审批内容。
- diff 或文件修改摘要。
- choosing 选项。

根据验证结果选择模式：

#### 模式 A: 事件流模式

条件：

- ccc 输出包含稳定消息边界，或可可靠去重。

Bridge 行为：

- 新 assistant 输出生成 `assistant_message`。
- 状态变化生成 `state_changed`。
- 审批请求生成 `approval_requested`。
- 重复快照不生成新事件。

#### 模式 B: 快照模式

条件：

- ccc 只能提供屏幕快照或难以切分消息。

Bridge 行为：

- `session.attach` 返回 `latest_output_snapshot`。
- 状态变化仍生成 `state_changed`。
- 输出变化生成 `assistant_message`，但标记 `snapshot: true`。
- App 不承诺完整聊天历史，只展示最新输出快照。

去重策略：

- 对标准化后的 ccc 输出计算 `sha256`。
- hash 不变则不推送。
- hash 变化但无法切分 delta 时，推送 snapshot。
- spinner、计时器、光标等易变字段需要在 hash 前归一化。

### 3.6 审批模型

ApprovalRecord:

```ts
type ApprovalRecord = {
  approvalId: string;
  sessionId: string;
  operationKind: "file_edit" | "command" | "choice" | "unknown";
  description: string;
  paths: string[];
  diffSummary?: string;
  contentHash: string;
  actions: ApprovalAction[];
  scope?: ApprovalScope;
  expiresAt: string;
  status: "pending" | "approved" | "rejected" | "expired" | "interrupted";
};
```

审批请求生成规则：

- Bridge 从 ccc 状态中识别 pending approval。
- 对审批内容做规范化并计算 `contentHash`。
- 如果同一个 pending approval hash 未变化，复用原 `approval_id`。
- 如果 hash 变化，创建新的 `approval_id`。
- 过期时间 MVP 默认 10 分钟。

审批执行规则：

- `message.approve` 必须带 `approval_id`。
- `approval_id` 必须等于当前 pending approval。
- `contentHash` 不匹配或已过期时拒绝。
- `idempotency_key` 重复时返回第一次执行结果。
- 审批成功后生成 `approval_resolved`。

MVP 中 `always` 为可选。若支持，仅允许当前 session 内同类低风险操作，不持久化到磁盘。

### 3.7 请求处理流程

#### Auth

```text
client connects
  -> Bridge starts auth timer
  -> client sends auth
  -> validate token + protocol version
  -> authenticated
  -> send response ok
```

#### Send Message

```text
App optimistic renders user message
  -> message.send(client_msg_id)
  -> Bridge validates session/state/size
  -> Bridge appends user_message event
  -> Bridge calls ccc send
  -> success: message_delivered event
  -> failure: message_failed event
```

#### Attach Session

```text
App requests session.attach(session_id)
  -> Bridge reads SessionRecord
  -> Bridge optionally performs immediate ccc read
  -> Bridge returns snapshot:
       session metadata
       current state
       last_seq
       recent messages or latest output snapshot
       pending approval
       capabilities
```

#### Reconnect

```text
WebSocket reconnect
  -> auth
  -> session.attach
  -> events.sync(after=local_last_seq)
  -> merge delta or handle EVENT_GAP
```

## 4. WebSocket Protocol

### 4.1 Envelope

Request:

```json
{
  "type": "message.send",
  "id": "req_123"
}
```

Response:

```json
{
  "type": "response",
  "id": "req_123",
  "ok": true,
  "data": {}
}
```

Error:

```json
{
  "type": "response",
  "id": "req_123",
  "ok": false,
  "error": {
    "code": "SESSION_NOT_FOUND",
    "message": "session not found",
    "retryable": false
  }
}
```

Event:

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

### 4.2 Error Codes

MVP error codes:

| Code | Meaning | Retryable |
|------|---------|-----------|
| `AUTH_FAILED` | Token invalid | no |
| `UNSUPPORTED_PROTOCOL` | Protocol version unsupported | no |
| `INVALID_REQUEST` | Schema validation failed | no |
| `SESSION_NOT_FOUND` | Session missing | no |
| `SESSION_STATE_INVALID` | Operation not allowed in current state | no |
| `CCC_COMMAND_FAILED` | ccc command failed | maybe |
| `CCC_TIMEOUT` | ccc command timed out | yes |
| `APPROVAL_NOT_FOUND` | approval_id missing or stale | no |
| `APPROVAL_EXPIRED` | approval expired | no |
| `EVENT_GAP` | requested events no longer available | no |
| `RATE_LIMITED` | too many requests | yes |
| `MESSAGE_TOO_LARGE` | payload exceeds limit | no |
| `PATH_NOT_ALLOWED` | path outside allowed_paths | no |

### 4.3 Schema Validation

Bridge must validate every request before handling:

- `type` is known.
- `id` is present for request messages.
- `session_id` format is valid where required.
- `client_msg_id` format is valid where required.
- Text length <= `max_prompt_bytes`.
- Unknown fields are allowed but ignored in MVP, unless they affect security.

Recommended implementation:

- Define TypeScript types in `server/src/types/protocol.ts`.
- Use `zod` or a small custom validator for runtime validation.

## 5. Flutter App 设计

### 5.1 技术栈

- Flutter 3.x。
- State management: Riverpod or Provider. MVP 可选 Provider，复杂度更低。
- WebSocket: `web_socket_channel`.
- Secure storage: `flutter_secure_storage`.
- Markdown: Phase 2 使用 `flutter_markdown`.

### 5.2 App 模块

建议目录：

```text
app/
  lib/
    main.dart
    app.dart
    core/
      config/
      logging/
      secure_storage/
    protocol/
      models.dart
      codec.dart
      client.dart
    features/
      server_config/
      sessions/
      chat/
      approvals/
```

### 5.3 状态管理

核心状态：

```dart
enum ConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
  reconnecting,
  error,
}

class SessionSummary {
  final String sessionId;
  final String name;
  final String backend;
  final String state;
  final int lastSeq;
  final String? lastMessage;
  final bool needsAttention;
}

class ChatState {
  final String sessionId;
  final List<ChatItem> items;
  final int lastSeq;
  final PendingApproval? pendingApproval;
  final bool hasEventGap;
}
```

### 5.4 WebSocket Client

职责：

- 连接 Server URL。
- 发送 auth。
- 维护 request id -> Completer。
- 分发 event。
- 心跳。
- 指数退避重连。
- 重连后自动 `session.attach`。

重连策略：

- 初始延迟 1 秒。
- 最大延迟 30 秒。
- 前台立即重连。
- 后台按系统限制尽力恢复。

App 不要求后台 WebSocket 常驻。MVP 中 App 回到前台时恢复连接即可。

### 5.5 URL 校验

保存服务器配置前执行：

- `wss://` 允许。
- `ws://localhost`、`ws://127.0.0.1` 允许。
- `ws://10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 允许但警告。
- `ws://100.64.0.0/10` 允许但提示用户确认 Tailscale 或私有隧道。
- 其他 `ws://` 拒绝。

域名形式的 `ws://` 默认拒绝，因为 App 无法可靠判断是否为公网。

### 5.6 页面

#### ServerConfigScreen

功能：

- 输入 Server URL。
- 输入 Token。
- 开关: 允许私网 `ws://`。
- 测试连接。
- 保存配置。

验收：

- Token 存储在 secure storage。
- URL 校验失败时不能保存。
- auth 失败显示明确错误。

#### ConversationListScreen

功能：

- 调用 `session.list`。
- 展示 session summary。
- 支持 attach。
- 支持新建 session。
- 支持 kill session。

排序：

1. `approval` / `choosing`
2. `thinking`
3. `ready`
4. `error`
5. `ended`

#### ChatScreen

功能：

- `session.attach` 获取 snapshot。
- 显示消息或最新输出快照。
- 发送 prompt。
- 中断。
- 显示审批卡片。
- 处理 `message_delivered` 和 `message_failed`。

当 Bridge 返回 snapshot 模式时，ChatScreen 显示“最新输出”区域，不承诺完整聊天历史。

#### ApprovalCard

字段：

- description
- operation kind
- paths
- diff summary
- expires at
- actions

交互：

- 点击按钮后 disabled + loading。
- 成功后显示 resolved。
- stale/expired 显示错误并等待下一个 snapshot。

## 6. 安全设计

### 6.1 默认安全姿态

- Bridge 默认只监听 localhost。
- 公网部署必须走 WSS reverse proxy。
- Tailscale 部署绑定具体 Tailscale IP。
- Bridge 禁止 root 运行。
- App 拒绝公网 `ws://`。
- 所有 ccc 调用使用 `execFile`。

### 6.2 Token

Token 格式：

- 至少 32 bytes random。
- 推荐 base64url 或 hex 编码。
- 存储时使用文件权限 `0600`。

比较：

- 使用 constant-time comparison。
- 比较前统一解码为 byte buffer。

轮换：

- `ccm-bridge rotate-token` 生成新 Token。
- 旧 Token 立即失效。
- 当前连接收到 `TOKEN_ROTATED` 或被断开。

MVP 可以先实现配置文件/环境变量加载，CLI rotate 命令可在 Phase 3 完善。

### 6.3 Rate Limit

MVP 最低要求：

- 未认证连接: 同 IP 最多 5 个。
- 认证失败: 同 IP 5 次失败后冷却 30 分钟。
- 已认证消息: 10 req/s，burst 30。
- ccc 命令并发: 每个 session 同时最多 1 个 mutating command。

### 6.4 Path Security

虽然文件查看不进 MVP，`session.run` 的工作目录仍必须校验。

规则：

- App 普通流程传 `workspace_id`，Bridge 将其解析为 `workspace_root/<workspace_id>`。
- `workspace_id` 只能是单段目录名，禁止路径分隔符，默认禁止隐藏目录名。
- 高级流程传 `cwd`，该值必须是服务端机器上的绝对路径。
- `session.run` 必须传且只传 `workspace_id` 或 `cwd` 之一。
- `realpath(workspace cwd 或高级 cwd)` 必须位于 `allowed_paths` 内。
- 禁止 symlink 逃逸。
- 默认拒绝隐藏目录作为 cwd/workspace，除非配置显式允许。

## 7. 部署设计

### 7.1 Caddy + WSS

Bridge:

```bash
ccm-bridge --host 127.0.0.1 --port 8900
```

Caddy:

```caddyfile
ccm.example.com {
    reverse_proxy 127.0.0.1:8900
}
```

App:

```text
wss://ccm.example.com/ws
```

如果 Bridge 直接挂在根路径，`/ws` 可以由 Caddy 转发到同一服务。MVP 需要确定 Bridge 是否只接受 `/ws` path，建议同时接受 `/` 和 `/ws`，降低部署摩擦。

### 7.2 Tailscale

Bridge:

```bash
ccm-bridge --host 100.x.y.z --port 8900
```

App:

```text
ws://100.x.y.z:8900
```

要求：

- 手机 Tailscale VPN 已开启。
- Bridge 不监听 `0.0.0.0`。
- 防火墙只允许 tailnet 访问该端口。

## 8. 测试策略

### 8.1 Bridge 单元测试

覆盖：

- Token compare。
- URL/path validation。
- request schema validation。
- state machine allowed operations。
- event store gap handling。
- approval idempotency。
- ccc command builder 不走 shell。

### 8.2 Bridge 集成测试

使用 fake ccc binary：

- `ccc ps --json` 返回固定会话。
- `ccc read --json` 返回状态序列。
- `ccc send` 模拟成功/失败。
- `ccc approve` 模拟成功/失败。

验证：

- session list。
- attach snapshot。
- send message -> delivered/failed。
- approval requested/resolved。
- reconnect events.sync。
- EVENT_GAP。

### 8.3 Phase 0 真机验证

在真实机器上安装 ccc、tmux、Claude Code，执行：

1. `workspace.create` 创建测试工作区。
2. `session.run` 使用 `workspace_id` 创建会话。
3. `message.send` 发送 prompt。
4. `ccc read --json` 轮询 60 秒。
5. 记录输出是否有稳定 message boundary。
6. 触发一次 approval。
7. 验证 approval 内容是否可结构化。
8. 执行 approve。
9. 验证状态回到 thinking/ready。
10. 断开 Bridge 重连，验证 attach snapshot。

产出 `docs/phase0-ccc-findings.md`，明确使用事件流模式还是快照模式。

### 8.4 Flutter 测试

MVP 覆盖：

- URL validation。
- protocol encode/decode。
- connection state reducer。
- session list ordering。
- approval card state。
- reconnect flow with fake WebSocket。

## 9. 可观测性

### 9.1 日志字段

日志结构：

```json
{
  "ts": "2026-05-02T10:00:00Z",
  "level": "info",
  "event": "message_send",
  "session_id": "sess_abc123",
  "backend": "claude",
  "text_bytes": 128,
  "request_id": "req_123"
}
```

禁止记录：

- 完整 Token。
- 完整 prompt。
- 完整 assistant output。
- 完整绝对路径。
- 文件内容。

### 9.2 Metrics

MVP 可先只通过日志观察。后续可加入：

- active connections。
- active sessions。
- ccc command latency。
- poll latency。
- auth failures。
- reconnect count。
- approval latency。

## 10. 实施顺序

### Step 1: Bridge Skeleton

- 配置加载。
- logger。
- WebSocket server。
- auth。
- protocol validator。

### Step 2: ccc Adapter

- `ccc ps --json`。
- `ccc run`。
- `ccc send`。
- `ccc read --json`。
- fake ccc tests。

### Step 3: Session and Events

- session manager。
- event store。
- state poller。
- state machine。
- attach snapshot。
- events.sync。

### Step 4: Approval

- approval detection。
- approval_id。
- idempotency。
- approve command。
- stale/expired handling。

### Step 5: Flutter MVP

- project init。
- server config。
- WebSocket client。
- session list。
- chat screen。
- approval card。
- reconnect。

### Step 6: Deployment Docs

- Caddy guide。
- Tailscale guide。
- systemd guide。
- security checklist。

## 11. Open Questions

- ccc `read --json` 是否提供稳定 message id 或 cursor。
- ccc approval JSON 中是否包含 diff、文件路径和操作类型。
- ccc 是否支持 attach 到非 ccm 创建但由 ccc 管理的会话。
- `ccc approve always` 的实际作用域是什么。
- Bridge 是否需要在 MVP 持久化 session_id 到磁盘，以便重启后保留同一会话身份。
- Flutter MVP 使用 Provider 还是 Riverpod。
- Android 后台恢复是否只做前台重连，还是需要通知能力提前进入 Phase 2。
