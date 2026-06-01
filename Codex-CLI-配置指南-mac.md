# Codex CLI 配置指南（macOS）

> 通过 CRS 服务器使用 ChatGPT Pro 的 Codex 代码助手

**适用系统**: macOS（zsh / bash）
**前提条件**: 已安装 Codex CLI（未安装可按下方步骤安装）
**预计耗时**: 5-10 分钟

---

## 📥 安装 Codex CLI（新增）

> 如果你已经能在终端运行 `codex --version`，可直接跳到“前置准备”。

### 步骤 0: 安装 Node.js（含 npm）

请先安装 **Node.js LTS（建议 >= 18）**。

方式 1（推荐）：Homebrew

```bash
brew --version
brew install node
node -v
npm -v
```

如果提示 `brew: command not found`，说明你还没安装 Homebrew：

```bash
# 先安装命令行工具（如已安装会提示已存在）
xcode-select --install

# 安装 Homebrew（官方命令）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 安装完成后，Homebrew 会打印 “Next steps”，照着执行把 brew 加入 PATH
brew --version
```

方式 2：从 Node.js 官网下载并安装 LTS（图形化安装）

安装完成后同样验证：

```bash
node -v
npm -v
```

### 步骤 1: 安装 Codex CLI

```bash
npm i -g @openai/codex
codex --version
```

> 若提示 `codex: command not found`，请重开终端，或确认 npm 全局 bin 已加入 `PATH`。

---

## 📋 前置准备

在开始配置前，你需要从管理员处获取：

- **CRS 2.0 base_url**: `https://your-crs-host:8443`
- **OPENAI_API_KEY / CRS 2.0 token**: 管理员提供的 token

示例：

```
CRS 2.0 base_url: https://your-crs-host:8443
OPENAI_API_KEY: sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## 🔧 配置步骤

### 步骤 1: 创建配置目录

> 如果你通过一键安装脚本启用了 ASCII 安全路径，请优先使用 `CODEX_HOME` 指向的目录；未设置时再使用 `~/.codex`。

```bash
# 创建 Codex 配置目录
mkdir -p ~/.codex
```

---

### 步骤 2: 配置 config.toml

在 `~/.codex/config.toml` 文件**开头**添加以下配置：

```bash
# 创建或编辑配置文件
nano ~/.codex/config.toml
```

粘贴以下内容：

```toml
model_provider = "OpenAI"
model = "gpt-5.5"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
disable_response_storage = true
network_access = "enabled"

sandbox_mode = "danger-full-access"
approval_policy = "never"
# 正常模式：
# sandbox_mode = "workspace-write"
# approval_policy = "on-request"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://your-crs-host:8443"  # 根据实际填写你服务器的地址
wire_api = "responses"
requires_openai_auth = true

[features]
# 实际已去除
tui_app_server = false
# 关闭MCP和 工具 / 列表 / 发现/建议
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"
```

**⚠️ 重要修改**：将 `base_url` 中的地址替换为管理员提供的服务器地址。

示例（CRS 2.0）：

```toml
base_url = "https://your-crs-host:8443"
```

**模型说明**：
- 默认使用 `gpt-5.5`（如管理员提供其他模型名，也可以直接替换 `model = "..."`）

**推理深度**：
- `low`: 快速响应
- `medium`: 平衡性能
- `high`: 深度思考（推荐）
- `xhigh`: 更深度思考（更慢，但更稳）

保存文件：按 `Ctrl+O` 回车保存，按 `Ctrl+X` 退出。

---

### 步骤 3: 配置 auth.json

在 `~/.codex/auth.json` 文件中直接写入 API 密钥：

```bash
# 创建或编辑认证文件
nano ~/.codex/auth.json
```

粘贴以下内容：

```json
{
    "OPENAI_API_KEY": "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

**说明**：这里填写的是当前 CRS 2.0 / OpenAI-compatible 入口使用的 token。

保存并退出。

---

### 步骤 4: 可选设置 CODEX_HOME

如果安装脚本因为中文路径兼容问题启用了 ASCII 安全目录，你可能还需要保留 `CODEX_HOME`：

```bash
export CODEX_HOME="/Users/Shared/Codex-$(id -u)/.codex"
```

---

## ✅ 验证配置

### 测试 1: 检查认证文件

```bash
cat ~/.codex/auth.json
```

应该能看到 `OPENAI_API_KEY` 已写入管理员提供的 CRS 2.0 token。

### 测试 2: 检查配置文件

```bash
# 查看配置文件是否存在
ls -la ~/.codex/

# 应该看到:
# config.toml
# auth.json
```

### 测试 3: 测试连接

```bash
# 简单测试
codex "Hello, 你好"
```

**预期结果**：Codex 应该正常回复你的问候。

### 测试 4: 测试代码生成

```bash
# 测试代码生成
codex "写一个 Python 函数计算斐波那契数列"
```

**预期结果**：应该生成完整的 Python 函数代码。

---

## 📊 配置检查清单

完成配置后，确认以下内容：

```
□ ~/.codex/config.toml 已创建并配置正确的 base_url
□ ~/.codex/auth.json 已创建并写入 OPENAI_API_KEY
□ 如使用 ASCII 安全目录，CODEX_HOME 已指向对应 .codex 目录
□ codex "Hello" 测试成功
```

---

## 💡 日常使用

### 基本命令

```bash
# 单次提问
codex "如何在 Python 中读取 CSV 文件？"

# 交互模式（连续对话）
codex

# 生成代码
codex "写一个快速排序算法"

# 解释代码
codex "解释这段代码的功能: [粘贴代码]"
```

### 切换模型

如果想使用更快的模型，编辑 `~/.codex/config.toml`：

```toml
# 更快响应：降低推理深度（越低越快）
model_reasoning_effort = "medium"

# 如果管理员提供了其他模型名，也可以直接切换 model，例如：
# model = "gpt-5.5"
```

修改后立即生效，无需重启。

---

## 🔧 常见问题

### Q1: 提示 "Error: ECONNREFUSED"

**原因**：无法连接到 CRS 服务器

**排查步骤**：

1. 检查配置文件中的服务器地址：
   ```bash
   cat ~/.codex/config.toml | grep base_url
   ```
2. 测试 CRS 2.0 Responses 入口连通性：
   ```bash
   base_url="https://your-crs-host:8443"
   curl -i -X POST "$base_url/responses" -H "Content-Type: application/json" -d '{}'
   ```
3. 联系管理员确认服务器状态

---

### Q2: 提示 "Client not allowed" 或 "Unauthorized"

**原因**：API Key 无效、过期或未正确设置

**排查步骤**：

1. 检查 `auth.json` 是否写入 token：
   ```bash
   cat ~/.codex/auth.json
   ```
2. 确认 `config.toml` 使用 OpenAI-compatible 配置：
   ```bash
   grep -E 'model_provider|requires_openai_auth|base_url' ~/.codex/config.toml
   ```
3. 如果仍然失败，联系管理员获取新的 API Key

---

### Q3: 每次打开新终端都找不到配置

**原因**：使用了非默认配置目录，但 `CODEX_HOME` 未正确持久化

**解决方法**：

1. 确认当前配置目录：
   ```bash
   echo "${CODEX_HOME:-$HOME/.codex}"
   ls -la "${CODEX_HOME:-$HOME/.codex}"
   ```
2. 如果一键安装脚本启用了 ASCII 安全目录，持久化 `CODEX_HOME` 到 `~/.zshrc` 或 `~/.bash_profile`。

---

### Q4: 提示 "stdin is not a terminal"

**原因**：在非交互式环境中运行

**解决方法**：使用单次提问模式，不要直接运行 `codex` 进入交互模式

```bash
# 正确
codex "你的问题"

# 错误（在脚本或管道中）
echo "问题" | codex
```

---

## 📁 配置文件结构

完整的配置目录结构：

```
~/.codex/
├── config.toml       # 主配置（服务器地址、模型）
├── auth.json         # 认证配置（OPENAI_API_KEY）
└── ...               # 其他自动生成的文件
```

---

## 🔐 安全提醒

⚠️ **保护好你的 API Key**：
- 不要分享给其他人
- 不要提交到 Git 仓库
- 不要在公开场合展示或截图

⚠️ **合理使用**：
- API Key 可能有使用配额限制
- 避免滥用或高频请求
- 仅供个人学习和开发使用

---

## 📝 配置要点总结

完整配置需要修改三个位置：

### 1. `~/.codex/config.toml`
- 设置 `base_url` 为 CRS 2.0 OpenAI-compatible 入口地址
- 配置 `model` 和 `model_reasoning_effort`
- 使用 `model_provider = "OpenAI"` 和 `requires_openai_auth = true`

### 2. `~/.codex/auth.json`
- 写入 `"OPENAI_API_KEY": "你的密钥"`

### 3. 可选 `CODEX_HOME`
- 仅当配置目录不是默认 `~/.codex` 时设置
- 执行 `source ~/.zshrc`（或 `source ~/.bashrc`）加载

---

## 🎉 配置完成

配置成功后，你可以：
- 在终端直接使用 `codex "问题"` 提问
- 进入交互模式进行连续对话
- 生成、解释、优化代码
- 集成到日常开发工作流中

**享受 AI 辅助编程！** 🚀

---

**文档版本**: 2.0
**更新时间**: 2026-04-18
**维护者**: 请联系管理员
