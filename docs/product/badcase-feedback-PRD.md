# ccm Badcase 反馈与采集 PRD

版本: v0.1
日期: 2026-06-13
状态: Draft
负责人: lilong.qian@okg.com

## 1. 背景与动机

ccm 把 ccc 管理的终端会话（Claude Code / Codex / OpenCode / Cursor）解析成结构化的移动端聊天。这条链路里最脆弱的一环是 **ccc 输出解析**：

- `server/src/ccc/ccc-parser.ts` 几乎全部是启发式正则——剥离终端 chrome（`╭ ╮ │ ─`）、靠 `● ⏺ ❯ ✻` 等 marker 切分用户/助手角色、用正则猜测选项菜单。
- 真实终端输出五花八门（换行、ANSI、宽字符、多后端差异），解析与渲染出错几乎不可避免：角色错位、内容截断、chrome 残留、选项识别失败、markdown 渲染异常等。
- 这类问题很难靠人工构造单测覆盖，但**每一次线上出错都是一个理想的回归用例**。

目前缺少一个把"线上出错"转化为"可复用测试样本"的闭环。本功能为用户在聊天界面对单条返回消息提交反馈，并自动采集产生该消息的**原始 tmux 输出、ccc 解析结果、ccm 渲染结果**三件套，沉淀成 badcase 库，用于优化 ccc 解析规则与 ccm 渲染。

## 2. 目标与非目标

### 2.1 MVP 目标

- 用户可在聊天页对**任意一条返回消息**发起反馈，标注它格式/内容是否有问题，并可附带文字备注。
- 服务端在生成每条消息时，保留产生它的三件套（raw / parsed / render），使事后反馈能精确关联到原始数据。
- 每条反馈落盘为一条自包含的 JSONL badcase 记录，可直接作为 ccc-parser 的回归输入。
- 采集数据受现有 token/`allowed_paths` 保护，且不进入 git。

### 2.2 非目标（本期不做）

- 不做自动分类、自动聚类、自动修复 parser。
- 不做 badcase 的远程上传/中心化后端，仅本地 JSONL 落盘 + 手动捞取。
- 不做反馈的审核流、统计看板、Web 管理界面。
- 不强制采集 App 端真实渲染像素（截图）；render 工件以"发给 App 的文本"为准，截图为可选扩展。
- 不改变现有数据流与状态机，只在既有汇合点旁路采集。

## 3. 核心概念

### 3.1 三件套（Badcase Artifacts）

三份数据在 `server/src/sessions/session-manager.ts` 的 `applySnapshot()`（约 339–378 行）中同时存在，是唯一的天然采集点：

| 工件 | 含义 | 代码来源 |
|---|---|---|
| `raw` | 原始终端输出。Bridge 能拿到的最原始形态是 `ccc read --json` 的 stdout，其内含 `lines[]` 终端行数组 | `CccClient.read()` 返回的 `CccCommandResult.stdout`（`ccc-client.ts:65-84`） |
| `parsed` | ccc 解析结果 | `parseCccRead` 产出的 `CccReadResult`（`items` / `output` / `pendingApproval`，见 `ccc-parser.ts:22`） |
| `render` | ccm 渲染输入。即写入 transcript、下发给 App 的文本（App 端再做 markdown 渲染） | `transcripts.appendIfNewTail` 的 `text`（`session-manager.ts:352`） |

> 说明：真正的"渲染像素"在 App 端 `flutter_markdown` 产生，Bridge 无法获知。MVP 以"渲染输入文本"代表 render 工件；App 可选地把自身渲染的纯文本/截图附带回传作为增强。

### 3.2 Badcase 记录

一条用户反馈 = 一条自包含的 badcase 记录，内嵌当时的三件套快照，使其脱离运行环境也能复现。

## 4. 用户流程

### 4.1 提交反馈

1. 用户在聊天页看到一条助手返回，发现格式/内容有问题（角色错、被截断、乱码、选项没识别等）。
2. 长按该消息气泡 → 弹出菜单，新增「反馈格式问题」入口（与现有「复制」并列，参见 `app/lib/features/chat/chat_screen.dart` 复制按钮 ~2315 行）。
3. 弹出轻量反馈表单：
   - 选择反馈类型（见 5.1）。
   - 可选填写文字备注。
4. 点击提交 → App 发送 `feedback.submit`，携带 `session_id` + 该消息的 `message_seq`/`message_id`。
5. 服务端关联到该消息对应的三件套，写入 badcase JSONL，返回成功。
6. App 显示「已反馈，谢谢」气泡内联提示。

### 4.2 事后捞取（开发者）

开发者直接读取服务端 badcase JSONL 文件，按反馈类型/会话过滤，作为 ccc-parser 回归用例或渲染问题排查输入。MVP 不提供 UI。

## 5. 功能需求

### 5.1 App 端

- **反馈入口**：消息气泡长按菜单新增「反馈」项。对 `role=assistant`、`snapshot` 类消息开放；用户消息可不开放（本期）。
- **反馈类型**（单选，枚举值固定，便于事后筛选）：
  - `format_error`：格式错乱（chrome 残留、换行/对齐异常）
  - `wrong_role`：角色归属错误（助手内容被当成用户，或反之）
  - `missing_content`：内容缺失/被截断
  - `garbled`：乱码/编码问题
  - `choice_misparse`：选项菜单未正确识别
  - `render_issue`：markdown 渲染异常（解析对但渲染错）
  - `other`：其他（建议配合备注）
  - `good`：正例（标记"这条解析得好"，用于正样本）
- **备注**：可选，多行文本，长度上限（建议 2000 字）。
- **反馈状态**：提交中（pending）/ 成功 / 失败可重试，复用现有乐观更新与失败重试模式。
- **客户端元信息**：随请求附带 `app_version`、`platform`，便于按版本归因。

### 5.2 Server 端

- **快照归档（SnapshotArchive）**：在 `applySnapshot` 落 transcript 的同时，按 `ccc_name + message_seq` 索引保留三件套（`raw_stdout` / `parsed` / `render_text` / `captured_at`）。
  - 容量受限：每会话保留最近 N 条（建议 N=200，可配置），超出按 FIFO 淘汰。
  - 存储介质：MVP 可用内存环形缓冲；若需跨重启保留，落 JSONL（见 7.2）。
- **关联**：`feedback.submit` 到达时，用 `message_seq` 从 SnapshotArchive 取回三件套。若已被淘汰/找不到，则记录降级（仅存 transcript 文本，标记 `artifacts_missing=true`），不报错。
- **反馈存储（FeedbackStore）**：照抄 `TranscriptStore` 的 JSONL append 模式（`session-manager` 已有 store 注入约定），把内嵌三件套的 badcase 记录追加写入。
- **去重**：同一 `message_seq` 重复反馈允许覆盖或追加（建议追加，保留用户多次修正）。

### 5.3 协议需求

新增请求类型 `feedback.submit`，在 `server/src/types/protocol.ts` 定义并在 `server/src/ws/gateway.ts` 的 dispatch switch 中增加 case：

```jsonc
// 请求
{
  "type": "feedback.submit",
  "id": "req_xxx",
  "session_id": "sess_xxx",
  "message_seq": 42,            // 主关联键
  "message_id": "msg_42",       // 冗余，便于核对
  "verdict": "format_error",    // 见 5.1 枚举
  "note": "助手内容被当成了用户消息",  // 可选
  "client": { "app_version": "0.1.15", "platform": "android" }  // 可选
}

// 响应
{ "type": "response", "id": "req_xxx", "ok": true, "data": { "feedback_id": "fb_xxx", "artifacts_missing": false } }
```

校验在 `server/src/ws/validators.ts`：`session_id` 必填、`message_seq` 为正整数、`verdict` 在枚举内、`note` 长度限制。

## 6. Badcase 记录 Schema

一行 JSONL = 一条自包含 badcase：

```jsonc
{
  "feedback_id": "fb_<base64url>",
  "created_at": "2026-06-13T10:00:00.000Z",
  "session_id": "sess_xxx",
  "ccc_name": "my-task",
  "backend": "claude",
  "message_seq": 42,
  "message_id": "msg_42",
  "verdict": "format_error",
  "note": "助手内容被当成了用户消息",
  "artifacts_missing": false,
  "artifacts": {
    "captured_at": "2026-06-13T09:59:58.000Z",
    "raw_stdout": "<ccc read --json 原文，内含 lines[]>",
    "parsed": { "state": "ready", "items": [/* CccTranscriptItem[] */], "output": "...", "pendingApproval": null },
    "render_text": "<下发给 App 的 transcript 文本>"
  },
  "client": { "app_version": "0.1.15", "platform": "android" }
}
```

设计选择：**三件套内嵌在反馈记录里**（而非仅存引用），使每条 badcase 离开运行环境也能独立复现，直接喂给 parser 回归测试。

## 7. 数据存储与位置

### 7.1 文件位置

- 复用 Bridge 的 `dataDir`，新增 `feedback/` 子目录（与 `transcripts/` 平级）。
- 文件名：`feedback/<sha256(ccc_name)>.jsonl`，与 `TranscriptStore.filePath` 一致的散列方式，避免泄露会话名。
- 也可考虑单一全局 `feedback/badcases.jsonl` 便于一次性捞取；建议按会话分文件 + 提供合并脚本。

### 7.2 SnapshotArchive 持久化（可选）

- MVP 默认内存环形缓冲即可（反馈通常在消息出现后较短时间内发生）。
- 若需跨重启保留长尾反馈能力，可把归档落 `feedback/snapshots/<hash>.jsonl` 并设总量上限。

## 8. 关键设计决策

1. **采集时机 = 生成时刻，而非反馈时刻**。`applySnapshot` 用完即弃 `result.stdout` 且按 hash 去重快照，等用户事后反馈时原始数据已丢失。必须在生成消息的同时归档三件套，反馈请求只提交轻量引用（`message_seq` + verdict + note）。
2. **关联键用 `message_seq`**。transcript 的 `message_seq` 单调递增且稳定（`transcript-store.ts`），App 的 `ChatItem` 已带 `seq`，是最可靠的关联键；`message_id`（`msg_<seq>`）作冗余校验。
3. **降级而非失败**。归档被淘汰时仍接受反馈，标 `artifacts_missing=true`，至少留住 verdict + note + transcript 文本。
4. **render 工件 = 文本**。Bridge 不持有渲染像素；以"下发文本"为准，App 截图为后续可选增强。
5. **不污染主数据流**。采集为旁路写入，失败不得影响正常的 transcript/event 流程（try/catch 吞掉采集异常并 `logger.warn`）。

## 9. 安全与隐私

- **敏感数据警示**：`raw_stdout` 原样包含终端屏幕上的一切，可能含密钥、token、PII。badcase 库等同敏感数据处理。
- **访问控制**：`feedback/` 目录与 transcripts 同级，受同一 token 鉴权与 `allowed_paths` 约束；不通过任何未鉴权接口暴露。
- **禁止入库**：`feedback/`、`feedback/snapshots/` 必须加入 `.gitignore`，严禁提交到仓库。
- **不记录到日志**：采集失败时 `logger.warn` 只记 message_seq 与错误，**不得**把 `raw_stdout` 内容写进日志。
- **本地优先**：MVP 不上传任何数据到外部，仅本地落盘。

## 10. 非功能需求

- **性能**：归档为内存写入 + 单条 JSONL append，单次开销 < 1ms 级，不得拖慢轮询。归档容量上限防止内存/磁盘膨胀。
- **稳定性**：采集路径全程 try/catch，任何异常不得影响 transcript/approval/event 主流程。
- **可观测性**：记录反馈提交次数、`artifacts_missing` 比例（衡量归档容量是否够用），复用现有 `logger`。

## 11. 验收标准

1. 聊天页长按助手消息可见「反馈」入口，选择类型 + 备注后可提交。
2. 提交后服务端 `feedback/<hash>.jsonl` 新增一行记录，含正确的 `verdict`、`note`、`message_seq`，且内嵌的 `parsed`/`render_text` 与该消息一致。
3. 反馈消息在产生后数秒内（归档未被淘汰）提交时，`artifacts.raw_stdout` 非空且为对应那次 `ccc read` 的原文。
4. 归档已淘汰的旧消息仍可反馈，记录标 `artifacts_missing=true` 且不报错。
5. `feedback/` 已在 `.gitignore` 中；日志中不出现 `raw_stdout` 内容。
6. 采集逻辑抛错时，正常聊天/审批流程不受影响（注入失败用例验证）。
7. Server 与协议改动有对应单测（validator、FeedbackStore append、applySnapshot 归档钩子）。

## 12. 开发计划

### Phase 1: Server 端闭环
- `protocol.ts` 新增 `FeedbackSubmitRequest`；`validators.ts` 校验。
- 新增 `SnapshotArchive`（内存环形缓冲，按 `ccc_name+seq` 索引）。
- `applySnapshot` 落 transcript 处挂钩归档（旁路，try/catch）。
- 新增 `FeedbackStore`（仿 `TranscriptStore` JSONL）。
- `gateway.ts` 新增 `feedback.submit` case，关联 + 写盘。
- `.gitignore` 加 `server/**/feedback/`（按实际 dataDir 调整）。
- 单测。

### Phase 2: App 端入口
- 消息气泡长按菜单加「反馈」项。
- 反馈表单（类型单选 + 备注）。
- `protocol/client.dart` 发送 `feedback.submit`，乐观状态 + 失败重试。
- Flutter widget/单测。

### Phase 3（可选增强）
- SnapshotArchive 落盘持久化。
- App 端附带渲染纯文本/截图。
- 捞取/合并脚本与 parser 回归测试套接入。

## 13. 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 归档时序丢失 | 反馈太晚，三件套已淘汰 | 容量 N 可配；降级保留；监控 `artifacts_missing` 比例 |
| 敏感数据泄露 | raw 含密钥/PII | gitignore + token 保护 + 不入日志 + 本地优先 |
| 关联键不稳 | `replaceIfLonger` 重写 transcript 可能改变 seq 对齐 | 以 seq 为准并冗余 message_id 校验；记录 ccc_name |
| 采集拖慢主流程 | 大量 append/内存增长 | 内存优先、容量上限、全程 try/catch、异步写盘 |
| render 工件不完整 | Bridge 无渲染像素 | MVP 以文本为准，截图列为后续增强 |

## 14. 后续待定问题

- badcase 是否需要按 backend 分桶存储以便分别优化各后端解析？
- 是否需要一个一次性导出命令（如 `npm run feedback:export`）把所有会话 badcase 合并 + 脱敏？
- 正例（`good`）样本是否纳入同一文件，还是单独存放用于回归基线？
- 是否对同一 `message_seq` 的重复反馈做合并展示？
