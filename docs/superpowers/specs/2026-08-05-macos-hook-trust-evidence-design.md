# macOS Hook 信任证据边界修复设计

日期：2026-08-05
状态：运行目录修订已确认，待实施计划修订
关联设计：`docs/superpowers/specs/2026-08-03-macos-setup-assistant-design.md`

## 1. 问题与现场证据

Mac 配置页根据 Hook 信任证据判断 Codex 是否信任并执行了 Codex Remote Hook。原实现由 GUI 的 `SessionIPCDispatcher` 在收到 IPC 请求后把证据写入 `~/.codex/codex-remote-hook-trust.json`。

第一次现场运行真实 `codex exec` 时，Codex 已执行 `SessionStart`、`UserPromptSubmit` 和 `Stop` Hook，IPC 也返回业务层 `handler_failed`，但 GUI 没有生成证据文件。由此确认信任判断不能依赖 GUI 回调和会话业务处理链。

第二次现场验证把写入职责移到 hook helper，但真实 Hook 仍失败。Codex 的 workspace-write 沙箱只允许 Hook 子进程写工作目录、`/tmp` 和 `$TMPDIR`；helper 直接写 `~/.codex` 时稳定返回退出码 `74` 和 `hook trust evidence write failed`。相同 helper 在 `$TMPDIR` 隔离目录中可以正常写入证据。因此，根因是持久证据路径超出 Codex Hook 子进程的可写边界。

Hook 信任只回答一个问题：Codex 是否执行了已配置的 Hook。它不应依赖 Ghostty 会话映射、GUI 是否正在监听或后续业务处理是否成功。

## 2. 目标与非目标

### 2.1 目标

- Codex 启动 hook helper 并提交合法、受支持的事件后，立即记录信任证据。
- Ghostty 会话映射或 IPC 业务处理失败时，信任检查仍能准确通过。
- malformed 或未知事件不能形成信任证据。
- 证据写入失败必须产生明确诊断，不能静默忽略。
- 把证据保存到 Unix Socket 同级私有运行目录，使真实 Codex 沙箱允许写入。
- 保留现有证据文件格式、`0600` 权限和时间有效性判断。

### 2.2 非目标

- 不修改本地 IPC 请求或响应契约。
- 不改变 Hook 队列、会话状态映射或 Ghostty 控制行为。
- 不把 Hook 信任成功解释为会话业务链成功。
- 不修改 Codex 的 `/hooks` 授权机制。

## 3. 方案

`codex-remote-helper hook` 在完成原始载荷解析后执行以下流程：

1. 校验 `hook_event_name` 是否属于 `SessionStart`、`UserPromptSubmit`、`PermissionRequest` 或 `Stop`。
2. 根据本次 `--socket` 参数解析 Socket URL，并把证据路径固定为 Socket 父目录下的 `codex-remote-hook-trust.json`。
3. 对受支持事件调用该路径对应的 `HookTrustEvidenceStore.recordAcceptedHook`。
4. 写入成功后，按现有流程把 Hook 发送到 GUI IPC 服务；连接前失败时仍按现有规则进入队列。
5. 证据写入失败时返回专用、可诊断的 helper 错误，不再继续报告伪成功。
6. 未知事件不写证据，仍交给现有业务路径决定响应。

信任证据记录器工厂作为 `HelperCommandRunner` 的可注入依赖。工厂接收已经严格解析的 Socket URL，生产入口返回 Socket 同级的安全存储；测试注入记录器或失败记录器，避免访问用户目录和真实运行目录。

GUI `SessionIPCDispatcher` 不再负责记录信任证据。信任判断只保留一个写入边界，避免重复写入和职责冲突。

`SetupInspector` 使用相同的 Socket 路径推导函数读取证据。helper 和检查器不得分别拼接文件名，以免自定义 Socket 配置产生路径漂移。

## 4. 数据与错误语义

证据文件继续使用现有格式：

```json
{
  "acceptedAt": "2026-08-05T12:23:09Z",
  "eventName": "SessionStart"
}
```

默认 Socket 为 `$TMPDIR/codex-remote-$UID/events.sock` 时，证据路径为 `$TMPDIR/codex-remote-$UID/codex-remote-hook-trust.json`。Socket 父目录必须由现有安全逻辑校验为当前用户所有且禁止组和其他用户写入；证据文件权限保持 `0600`。

配置检查继续要求：

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
- 原有 Hook 队列、IPC dispatcher、SetupInspector 和证据文件安全测试继续通过；
- helper 与 SetupInspector 对同一 Socket URL 推导出完全相同的证据路径；
- 生产 helper 不再尝试写入 `~/.codex`。

现场验收使用真实 Codex 会话，不伪造运行目录中的信任文件：

1. 启动当前安装的 Codex Remote。
2. 通过 Codex Remote shim 运行一次真实 Codex 会话。
3. 核对 Socket 同级证据文件的事件名、`0600` 权限和时间。
4. 返回配置页重新检查，确认显示“Hooks 信任已确认”。
5. 单独报告 Ghostty 会话映射结果；映射失败不得回退 Hook 信任状态。

## 6. 风险与回滚

主要风险是 `$TMPDIR` 可被系统清理。证据丢失后，配置页必须回到“等待真实 Hook 回调验证”，下一次正式 Hook 会自动重建证据；客户端不得把旧缓存当作成功。

helper 能解析事件但 GUI 不可用时仍会记录信任。该行为符合信任证据定义：Codex 已执行 Hook；GUI 和会话业务状态由 IPC、运行状态和功能测试分别检查。

回滚应用时恢复 `/Applications/Codex Remote.app.backup-20260805-204404`。代码回滚只需恢复 `HelperCommandRunner`、生产入口和 `SetupInspector` 的证据路径边界。证据文件位于系统运行目录，不需要迁移或清理用户持久数据。
