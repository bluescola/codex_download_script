# mac 版本 NO_PROXY 脚本说明（未测试）

注意：本目录下脚本目前**未在真实 macOS 环境**中做过完整测试，请在确认风险后再使用。

包含文件：
- `setup_no_proxy_mac.sh`
  - 作用：将指定条目追加到 `NO_PROXY/no_proxy`（缺少才加，重复不加）。
  - 持久化：会写入/更新 `~/.zprofile`、`~/.zshrc`（以及存在的话 `~/.bash_profile`、`~/.bashrc`）。
  - GUI 会话：会尝试用 `launchctl setenv` 设置当前登录会话环境变量，并安装 LaunchAgent 以便登录时自动生效（best-effort）。
- `一键-设置NO_PROXY绕过代理.command`
  - Finder 双击运行的包装脚本（内部调用 `setup_no_proxy_mac.sh`）。

使用建议：
1. 运行前先打开脚本确认修改内容；必要时备份 `~/.zprofile`、`~/.zshrc` 等文件。
2. 推荐在 Terminal 中执行：`bash ./setup_no_proxy_mac.sh`；执行后重开终端验证：`echo "$NO_PROXY"`。
3. 如出现异常/不需要该配置，可手动回滚：
   - 删除 shell 配置文件中 `# >>> codex no_proxy >>>` 与 `# <<< codex no_proxy <<<` 之间的块。
   - 删除 LaunchAgent：`~/Library/LaunchAgents/com.codex.no-proxy.plist`
   - 删除辅助脚本：`~/Library/Application Support/codex/no-proxy/setenv.sh`

