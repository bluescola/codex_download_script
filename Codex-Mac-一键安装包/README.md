# Codex macOS 一键安装包

## 入口

```bash
bash install-codex-cli-mac.sh
```

请以目标普通用户运行，不要用 `sudo`。建议复制整个目录运行，因为安装器会调用同目录的 `setup_no_proxy_mac.sh`。

## 行为摘要

- 开头打印 preflight 环境摘要，便于排查 Node/npm/Codex、Homebrew、路径和代理问题。
- 使用 Homebrew `node@24` 作为明确 LTS 目标，并把 Codex 安装到 `node@24` npm prefix。
- 将 `node@24/bin` 以去重方式放到 zsh/bash profile 的 PATH 前面，避免 keg-only `node@24` 被其它 Homebrew Node 覆盖。
- 清理旧安装器写入的 npm prefix/cache 配置和默认 `CODEX_HOME` profile 导出。
- 不长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`。
- 写入 CRS 配置和 `auth.json`；写入失败时保留本次备份，成功后清理本次备份。
- 调用 `setup_no_proxy_mac.sh` 合并 NO_PROXY/no_proxy，按登录 shell 写入对应 zsh 或 bash profile，并覆盖终端和 GUI 会话。
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
