# Codex macOS 一键安装包

## 入口

```bash
bash install-codex-cli-mac.sh
```

请以目标普通用户运行，不要用 `sudo`。建议复制整个目录运行，因为安装器会调用同目录的 `setup_no_proxy_mac.sh`。

## 行为摘要

- 开头打印 preflight 环境摘要，便于排查 Node/npm/Codex、Homebrew、路径和代理问题。
- 优先复用当前用户已有且可用的 Node.js/npm；缺失时才通过 Homebrew 安装或复用 Node.js/npm。
- 将 Codex 安装到用户 npm prefix（如 `~/.local`，非 ASCII HOME/TMPDIR 时使用 ASCII-safe prefix），后续更新不需要 `sudo`。
- 持久化用户 npm prefix 与必要 PATH；只有脚本本次通过 Homebrew 安装 Node.js 时，才把对应 Node bin 写入 PATH 块。
- 清理旧安装器写入的 npm prefix/cache 配置和默认 `CODEX_HOME` profile 导出。
- 不长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`。
- 写入 CRS 配置和 `auth.json`；写入失败时保留本次备份，成功后清理本次备份。
- 调用 `setup_no_proxy_mac.sh` 合并 NO_PROXY/no_proxy：保留用户已有条目，移除旧固定 IP `3.27.43.117`、`3.27.43.117:10086`，追加 `localhost`、`127.0.0.1` 和 CRS host/host:port，并覆盖终端和 GUI 会话。
- HOME/TMPDIR 含非 ASCII 时使用 ASCII-safe 根目录。

## 常用参数

- `--dry-run`：只打印环境摘要，不安装、不写文件、不改环境。
- `--verbose`：打印详细诊断。
- `--trace`：打印 trace 级诊断。
- `--force-node-reinstall`：强制重装 Node.js/npm。
- `--force-codex-reinstall`：强制重装 `@openai/codex`。
- `--remove-system-codex`：显式移除检测到的系统级 Codex。
- `--skip-crs-config`：跳过 CRS 配置交互。
- `--skip-no-proxy`：跳过 NO_PROXY/no_proxy 配置。

## 维护入口

- 总览：[../docs/script-system-overview.md](../docs/script-system-overview.md)
- 决策记录：[../docs/decisions.md](../docs/decisions.md)
- 流程图：[../docs/graphs/mac-install.drawio](../docs/graphs/mac-install.drawio)
- 用户配置指南：[../Codex-CLI-配置指南-mac.md](../Codex-CLI-配置指南-mac.md)
