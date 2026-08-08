# Codex Micro compatibility fixtures

This directory is reserved for bounded, reviewable fixtures used by the independent Codex Micro compatibility layer.

Rules:

- Store only messages needed by tests.
- Record whether each fixture is device-to-host or host-to-device.
- Keep the 63-byte HOGP body and JSON payload representations separate.
- Do not copy unrelated firmware, UI assets, trademarks, or captured user content.
- Treat Report ID 6, vendor JSON-RPC methods, compatibility identities, and status messages as non-public compatibility behavior.
- Reject fixtures that contain credentials, account data, chat text, device addresses, or other user-specific data.

Sources:

- <https://learn.chatgpt.com/docs/features/codex-micro>
- <https://github.com/imliubo/codex-micro-4-core2>
- <https://github.com/imliubo/codex-micro-4-core2/blob/main/docs/TECHNICAL.md>

Initial Task 2 fixtures:

- `sys-version-request.json`: host-to-device request.
- `device-status-request.json`: host-to-device request.
- `agent-key-press.json`: device-to-host event.

The files contain the JSON payload only. The framing tests generate and verify the separate fixed 63-byte report body.
