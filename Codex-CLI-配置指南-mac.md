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

- **CRS 服务器地址**: `http://服务器IP:端口`
- **CRS API Key**: `cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

示例：

```
CRS 服务器: http://x.x.x.x:10086
API Key: cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## 🔧 配置步骤

### 步骤 1: 创建配置目录

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
model_provider = "crs"
model = "gpt-5.1-codex-max"
model_reasoning_effort = "high"
disable_response_storage = true
preferred_auth_method = "apikey"

[model_providers.crs]
name = "crs"
base_url = "http://127.0.0.1:3000/openai"  # 根据实际填写你服务器的ip地址或者域名
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"
```

**⚠️ 重要修改**：将 `base_url` 中的地址替换为管理员提供的服务器地址。

示例（假设服务器是 x.x.x.x:10086）：

```toml
base_url = "http://x.x.x.x:10086/openai"
```

**模型说明**：
- `gpt-5.1-codex-mini`: 快速响应，适合简单问题
- `gpt-5.1-codex-max`: 深度思考，适合复杂问题（推荐）

**推理深度**：
- `low`: 快速响应
- `medium`: 平衡性能
- `high`: 深度思考（推荐）

保存文件：按 `Ctrl+O` 回车保存，按 `Ctrl+X` 退出。

---

### 步骤 3: 配置 auth.json

在 `~/.codex/auth.json` 文件中配置 API 密钥为 `null`：

```bash
# 创建或编辑认证文件
nano ~/.codex/auth.json
```

粘贴以下内容：

```json
{
    "OPENAI_API_KEY": null
}
```

**说明**：设置为 `null` 表示不使用 OpenAI 官方 API，而是通过 CRS 服务器中转。

保存并退出。

---

### 步骤 4: 设置环境变量

#### 方法 1: 永久设置（推荐）

macOS 默认 shell 通常为 zsh，推荐写入 `~/.zshrc`：

```bash
# 编辑 zshrc
nano ~/.zshrc
```

在文件**末尾**添加：

```bash
# CRS API Key for Codex CLI
export CRS_OAI_KEY="后台创建的API密钥"
```

**⚠️ 重要**：将 `后台创建的API密钥` 替换为管理员提供的实际 API Key。

示例：

```bash
export CRS_OAI_KEY="cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

保存并退出，然后加载环境变量：

```bash
# 立即应用配置
source ~/.zshrc

# 验证环境变量
echo $CRS_OAI_KEY
```

> 如果你使用的是 bash，请改为写入 `~/.bashrc` 并执行 `source ~/.bashrc`。

#### 方法 2: 临时设置

如果只想临时使用，可以直接在终端执行：

```bash
export CRS_OAI_KEY="cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

**注意**：此方法仅在当前终端会话有效，关闭终端后失效。

---

## ✅ 验证配置

### 测试 1: 检查环境变量

```bash
echo $CRS_OAI_KEY
```

应该输出完整的 API Key（以 `cr_` 开头）。

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
□ ~/.codex/auth.json 已创建并设置 OPENAI_API_KEY 为 null
□ 环境变量 CRS_OAI_KEY 已添加到 ~/.zshrc（或 ~/.bashrc）
□ 执行 source ~/.zshrc（或 source ~/.bashrc）加载环境变量
□ echo $CRS_OAI_KEY 显示正确的 API Key
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
# 将 max 改为 mini，获得更快响应
model = "gpt-5.1-codex-mini"
model_reasoning_effort = "medium"
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
2. 测试服务器连通性：
   ```bash
   curl http://服务器IP:端口/health
   # 应返回: {"status":"healthy",...}
   ```
3. 联系管理员确认服务器状态

---

### Q2: 提示 "Client not allowed" 或 "Unauthorized"

**原因**：API Key 无效、过期或未正确设置

**排查步骤**：

1. 检查环境变量是否设置：
   ```bash
   echo $CRS_OAI_KEY
   ```
2. 如果显示为空，重新加载配置：
   ```bash
   source ~/.zshrc
   echo $CRS_OAI_KEY
   ```
3. 如果仍然失败，联系管理员获取新的 API Key

---

### Q3: 每次打开新终端都需要重新设置环境变量

**原因**：环境变量未正确添加到 `~/.zshrc`（或 `~/.bashrc`）

**解决方法**：

1. 确认 rc 文件中有以下内容：
   ```bash
   grep -n "CRS_OAI_KEY" ~/.zshrc ~/.bashrc 2>/dev/null || true
   ```
2. 如果没有，重新添加并 `source` 对应文件。

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
├── auth.json         # 认证配置（设为 null）
└── ...               # 其他自动生成的文件

~/.zshrc 或 ~/.bashrc # 环境变量（CRS_OAI_KEY）
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
- 设置 `base_url` 为 CRS 服务器地址
- 配置 `model` 和 `model_reasoning_effort`
- 指定 `env_key = "CRS_OAI_KEY"`

### 2. `~/.codex/auth.json`
- 设置 `"OPENAI_API_KEY": null`

### 3. `~/.zshrc`（或 `~/.bashrc`）
- 添加 `export CRS_OAI_KEY="你的密钥"`
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
