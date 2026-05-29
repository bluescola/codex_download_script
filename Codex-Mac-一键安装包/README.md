# Codex macOS 一键安装包说明

## 运行方式

```bash
bash install-codex-cli-mac.sh
```

请以目标普通用户运行，不要用 `sudo`。脚本会拒绝 root 运行，避免配置写到 root 用户目录。

建议复制整个 `Codex-Mac-一键安装包` 目录再运行，因为安装器会调用同目录的 `setup_no_proxy_mac.sh`。

## 脚本会做什么

- 检查现有 Node.js 是否为受支持 LTS 线；否则通过 Homebrew 安装 Node.js 24 LTS 和 npm。
- 安装 `@openai/codex` 到 Homebrew `node@24` 的 npm 全局前缀。
- 写入 Codex CRS 配置，默认 `sandbox_mode = "workspace-write"`。
- 写入前会备份已有 `config.toml` 和 `auth.json`，不会删除历史备份。
- 持久化 `CRS_OAI_KEY` 到 zsh/bash 常见 profile 文件（包括 `~/.zshrc`、`~/.zprofile`、`~/.bash_profile`、`~/.bashrc`）；只有启用 ASCII 安全路径等非默认 Codex 目录时才持久化 `CODEX_HOME`。
- 不再长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`；Codex 跟随 Homebrew `node@24` 的 npm 全局前缀。
- 配置 `NO_PROXY/no_proxy`，会尝试从 `CODEX_HOME` 或 `~/.codex/config.toml` 读取 CRS `base_url` 并加入实际 host/host:port。

## 系统级 Codex

- 默认只检测并提示系统级 Codex，不自动卸载 Homebrew/npm 等系统级安装。
- 如确实需要移除系统级 Codex，请显式传入：

```bash
bash install-codex-cli-mac.sh --remove-system-codex
```

执行前请确认输出中的系统级 npm prefix，避免误删共享安装。

## 常用参数

- `--force-node-reinstall`：强制重新安装用户级 Node.js/npm。
- `--force-codex-reinstall`：强制重装用户级 `@openai/codex`。
- `--remove-system-codex`：显式移除检测到的系统级 Codex。
- `--skip-crs-config`：跳过 CRS 配置交互。
- `--skip-no-proxy`：跳过 NO_PROXY/no_proxy 配置。

## Node.js 版本说明

macOS 安装器使用 Homebrew 的 `node@24` 公式安装明确的 LTS 版本；如果系统已有受支持的 Node.js LTS 线，会直接复用。
