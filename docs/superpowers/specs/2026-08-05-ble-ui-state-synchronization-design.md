# BLE 与界面状态同步修复设计

## 目标

修复三类已复现的不一致：ESP32 已建立 BLE 连接但仍显示 `Waiting for Mac`，安装配置页始终显示等待设备，菜单栏图标停留在未连接状态。新建 Codex 会话后，Mac 和 ESP32 应同时显示该会话。

## 根因

1. NimBLE 恢复持久化订阅时，`BLE_GAP_EVENT_SUBSCRIBE` 可能早于 `BLE_GAP_EVENT_CONNECT` 回调到达。固件使用尚未赋值的全局连接句柄发送 `deviceInfo`，返回 `BLE_HS_ENOTCONN`。Mac 只有收到 `deviceInfo` 才发送首个会话快照。
2. `MacSetupEnvironment` 支持注入 ESP32 连接状态读取器，但 `AppModel` 创建安装检查服务时没有注入，检查器一直使用默认值 `false`。
3. 菜单栏下拉内容观察 `AppModel`，菜单栏标签直接读取嵌套模型属性，未建立稳定的观察关系，因此图标不随连接状态更新。
4. 真机复测确认，绑定恢复会在 Mac 完成特征发现前恢复 `deviceInfo` 的 CCCD。ESP32 虽然使用了有效连接句柄，但三个通知分片仍早于 `Mac connected` 发出，CoreBluetooth 没有把它们交给应用。Mac 随后设置同一通知值时没有产生新的订阅事件。

## 设计

### 固件

发送 `deviceInfo` 时使用 `BLE_GAP_EVENT_SUBSCRIBE` 自带的 `conn_handle`。其他业务消息仍使用连接成功后保存的全局句柄。该改动不改变 GATT 服务、消息编码或配对数据。

### Mac 连接状态

增加一个由 `AppModel` 持有的轻量连接状态源。`MacClientCoordinator` 发布快照时同步更新该状态源；`MacSetupEnvironment` 通过注入闭包读取它。安装检查继续使用现有 `SetupInspector`，不增加轮询器或第二套连接判断。

### Mac 通知订阅

Mac 发现全部特征后，先关闭再重新开启 `deviceInfo` 通知，清除系统恢复的旧 CCCD 状态。重新开启发生在应用已建立特征对象和回调之后，因此 ESP32 收到的新订阅事件可以安全发送设备信息。该操作不修改 BLE 消息、UUID 或持久化格式。

### 菜单栏图标

将菜单栏标签封装为观察 `AppModel` 的 SwiftUI 子视图。图标仍使用现有 `menuBarSymbol` 映射，不改变文案、菜单结构或状态定义。

## 数据流

连接建立后的顺序如下：

1. Mac 完成特征发现，关闭并重新开启 `deviceInfo` 通知。
2. ESP32 在新订阅事件中使用事件连接句柄发送 `deviceInfo`。
3. Mac 解码 `deviceInfo`，读取当前会话并发送完整快照。
4. ESP32 应用快照，将 `has_snapshot` 设为真并刷新屏幕。
5. `AppModel` 接收连接快照，更新菜单栏内容、图标和安装检查使用的连接状态源。
6. 后续 hook 事件触发 `refreshSessions()`，Mac 发送会话增量或重同步快照。

## 测试与验收

- 固件回归测试证明订阅处理使用事件连接句柄；全部主机测试和 ESP-IDF 构建通过。
- Mac 单元测试覆盖连接状态源的连接与断开结果，以及安装检查器读取注入状态。
- Mac 构建验证菜单栏观察视图可以编译。
- 真机连接后，ESP32 显示 `Mac connected`；安装配置页显示 `ESP32 已连接`；菜单栏使用连接图标；新建 Codex 会话后两端都显示会话。

## 范围与风险

本次不修改协议、共享数据结构、配置格式、配对策略、会话识别规则或安装路径。自动化测试不能替代四项真机 UI 验收；新 App 只生成临时安装包，替换 `/Applications/Codex Remote.app` 需要单独确认或由用户手动完成。
