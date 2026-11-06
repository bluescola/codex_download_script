# Codex Linux 一键安装包

## 入口

```bash
bash install-codex-cli-linux.sh
```

请以目标普通用户运行，不要用 `sudo`。建议复制整个目录运行，因为安装器会调用同目录的 `setup_no_proxy_linux.sh`。

## 行为摘要

- 开头打印 preflight 环境摘要，便于排查 Node/npm/Codex、nvm、路径和代理问题。
- 启用 ASCII-safe 路径时，preflight 会明确打印触发变量（`HOME` 或 `TMPDIR`），不会把中文运行目录作为切换条件。
- 通过 nvm 安装或启用 Node.js LTS，并把 Codex 安装到 nvm npm prefix。
- 当使用非默认 `NVM_DIR`（包括 ASCII-safe 路径）时，向 `~/.bashrc` 和 `~/.zshrc` 写入受管的 nvm 初始化区块，并验证新的 Bash 进程能解析 `codex`。
- 使用 nvm 前会清理当前进程和 `~/.npmrc` 中与 nvm 冲突的 `prefix/globalconfig`，并移除旧安装器写入的 npm cache 配置。
- 不长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`。
- 写入 CRS 配置和 `auth.json`；写入失败时保留本次备份，成功后清理本次备份。
- 调用 `setup_no_proxy_linux.sh` 合并 NO_PROXY/no_proxy。
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

## 手动重启 app-server

更新认证或配置后，使用 Linux 原生脚本重新加载 app-server：

```bash
bash restart-codex-app-server-linux.sh
```

跳过确认：

```bash
bash restart-codex-app-server-linux.sh --force
```

执行前必须设置当前 shell 的 Sub2API 客户端 key：

```bash
export CRS_OAI_KEY='你的 Sub2API 客户端 API Key'
```

脚本会停止旧 daemon，再启动新 daemon，并检查新进程是否继承 `CRS_OAI_KEY`。该 key 必须是 Sub2API 中生成的客户端 Key，不是上游 OpenAI 账号凭据。

验证：

```bash
codex app-server daemon version
```

更新 `auth.json` 或重新登录、修改 `provider`/`base_url`/`env_key`，或 CLI 正常但 app-server 子模块返回 401 时，应重启 daemon。重启可能中断正在运行的 app-server 任务，请先确认没有重要任务执行。此脚本只管理当前 Linux 环境中的 Codex，不调用 Windows PowerShell 或 WSL。

## 维护入口

- 总览：[../docs/script-system-overview.md](../docs/script-system-overview.md)
- 决策记录：[../docs/decisions.md](../docs/decisions.md)
- 流程图：[../docs/graphs/linux-install.drawio](../docs/graphs/linux-install.drawio)
- 用户配置指南：[../Codex-CLI-配置指南-linux.md](../Codex-CLI-配置指南-linux.md)
