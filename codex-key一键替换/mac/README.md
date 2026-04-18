# mac 版本 codex-key 一键替换（未测试）

注意：本目录下脚本目前**未在真实 macOS 环境**中做过完整测试，请在确认风险后再使用。

包含文件：
- `codex-key-replace-mac.sh`
  - 交互式输入 `base_url` 与 `CRS_OAI_KEY`
  - 写入/更新 `~/.codex/config.toml`：
    - `base_url = "..."`（存在则替换，不存在则追加）
    - `requires_openai_auth = false`（存在则替换，不存在则追加）
  - 写入/更新 shell rc 文件（用于持久化 `CRS_OAI_KEY`）：
    - 默认写 `~/.zshrc`（macOS 默认 shell）
    - 若检测到 `$SHELL` 包含 `bash`，则写 `~/.bashrc`
- `一键-替换codex-key.command`
  - Finder 双击运行的包装脚本（内部调用 `codex-key-replace-mac.sh`）

运行方式：
1. Terminal：`bash ./codex-key-replace-mac.sh`
2. Finder：双击 `一键-替换codex-key.command`（首次可能需要 `chmod +x`）

生效说明：
- 写入 rc 文件后，推荐“新开一个终端”使其生效。
- 如需当前终端立即生效，按脚本输出提示 `source ~/.zshrc`（或对应 rc 文件）。

