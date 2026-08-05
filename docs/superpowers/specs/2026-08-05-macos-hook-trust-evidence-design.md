# macOS Hook 信任证据边界修复设计

日期：2026-08-05
状态：设计已确认，待实施计划
关联设计：`docs/superpowers/specs/2026-08-03-macos-setup-assistant-design.md`

## 1. 问题与现场证据

Mac 配置页以 `~/.codex/codex-remote-hook-trust.json` 判断 Codex 是否信任并执行了 Codex Remote Hook。当前实现由 GUI 的 `SessionIPCDispatcher` 在收到 IPC 请求后写入证据。

现场运行真实 `codex exec` 时，Codex 已执行 `SessionStart`、`UserPromptSubmit` 和 `Stop` Hook，IPC 也返回业务层 `handler_failed`，但证据文件没有生成。相同版本的 helper 在隔离目录中可以正常写入证据。因此，证据存储和目录权限不是根因；问题在于信任判断依赖 GUI 回调和会话业务处理链。

Hook 信任只回答一个问题：Codex 是否执行了已配置的 Hook。它不应依赖 Ghostty 会话映射、GUI 是否正在监听或后续业务处理是否成功。

## 2. 目标与非目标

### 2.1 目标

- Codex 启动 hook helper 并提交合法、受支持的事件后，立即记录信任证据。
- Ghostty 会话映射或 IPC 业务处理失败时，信任检查仍能准确通过。
- malformed 或未知事件不能形成信任证据。
- 证据写入失败必须产生明确诊断，不能静默忽略。
- 保留现有证据文件格式、权限和时间有效性判断。

### 2.2 非目标

- 不修改本地 IPC 请求或响应契约。
- 不改变 Hook 队列、会话状态映射或 Ghostty 控制行为。
- 不把 Hook 信任成功解释为会话业务链成功。
- 不修改 Codex 的 `/hooks` 授权机制。

## 3. 方案

`codex-remote-helper hook` 在完成原始载荷解析后执行以下流程：

1. 校验 `hook_event_name` 是否属于 `SessionStart`、`UserPromptSubmit`、`PermissionRequest` 或 `Stop`。
2. 对受支持事件调用 `HookTrustEvidenceStore.recordAcceptedHook`。
3. 写入成功后，按现有流程把 Hook 发送到 GUI IPC 服务；连接前失败时仍按现有规则进入队列。
4. 证据写入失败时返回专用、可诊断的 helper 错误，不再继续报告伪成功。
5. 未知事件不写证据，仍交给现有业务路径决定响应。

信任证据记录器作为 `HelperCommandRunner` 的可注入依赖。生产入口使用默认 `~/.codex/codex-remote-hook-trust.json`；测试注入记录器或失败记录器，避免访问用户目录。

GUI `SessionIPCDispatcher` 不再负责记录信任证据。信任判断只保留一个写入边界，避免重复写入和职责冲突。

## 4. 数据与错误语义

证据文件继续使用现有格式：

```json
{
  "acceptedAt": "2026-08-05T12:23:09Z",
  "eventName": "SessionStart"
}
```

文件路径保持 `~/.codex/codex-remote-hook-trust.json`，权限保持 `0600`。配置检查继续要求：

- `eventName` 属于受支持事件；
- `acceptedAt` 不早于 `~/.codex/hooks.json` 的修改时间。

载荷解析失败继续返回 malformed hook。证据写入失败返回单独的诊断文本和非零退出码，文案说明“信任证据写入失败”，但不泄露用户目录、环境变量或载荷内容。

## 5. 测试与验收

自动测试至少覆盖：

- 合法受支持事件在发送 IPC 前记录证据；
- IPC 返回 `handler_failed` 时，证据仍已记录；
- IPC 不可用且 Hook 入队时，证据仍已记录；
- malformed Hook 不记录证据；
- 未知 Hook 不记录证据；
- 证据写入失败时不发送 IPC，并返回明确错误；
- 原有 Hook 队列、IPC dispatcher、SetupInspector 和证据文件安全测试继续通过。

现场验收使用真实 Codex 会话，不伪造 `~/.codex` 中的信任文件：

1. 启动当前安装的 Codex Remote。
2. 通过 Codex Remote shim 运行一次真实 Codex 会话。
3. 核对证据文件的事件名、`0600` 权限和时间。
4. 返回配置页重新检查，确认显示“Hooks 信任已确认”。
5. 单独报告 Ghostty 会话映射结果；映射失败不得回退 Hook 信任状态。

## 6. 风险与回滚

主要风险是 helper 能解析事件但 GUI 不可用时仍记录信任。该行为符合信任证据定义：Codex 已执行 Hook；GUI 和会话业务状态由 IPC、运行状态和功能测试分别检查。

回滚只需恢复 `HelperCommandRunner` 和生产入口的证据记录边界，并恢复 dispatcher 回调。证据文件格式和检查逻辑不变，无需迁移或清理用户数据。
