# Codex CLI 配置指南（Windows）

> 通过 CRS 服务器使用 ChatGPT Pro 的 Codex 代码助手

**适用系统**: Windows 10/11（PowerShell 或命令提示符）
**前提条件**: 已安装 Codex CLI（未安装可按下方步骤安装）
**预计耗时**: 5-10 分钟

---

## 📥 安装 Codex CLI（新增）

> 如果你已经能在终端运行 `codex --version`，可直接跳到“前置准备”。

### 步骤 0: 安装 Node.js（含 npm）

推荐使用 `winget` 安装 Node.js LTS（含 npm）。

若提示 `winget` 不存在，可先在 **管理员 PowerShell** 执行：

```powershell
$progressPreference = 'silentlyContinue'
Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
Repair-WinGetPackageManager -AllUsers
winget --version
```

然后在 PowerShell 执行：

```powershell
winget install -e --id OpenJS.NodeJS.LTS
node -v
npm -v
```

> 若提示找不到 `node` 或 `npm`，请 **重开终端** 再试一次。

### 步骤 1: 安装 Codex CLI

```powershell
npm i -g @openai/codex
codex --version
```

> 若提示 `codex` 不是内部或外部命令，请先重开终端；仍不行再检查 npm 全局 bin 是否在 PATH。

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

PowerShell:

```powershell
mkdir $env:USERPROFILE\.codex -Force
```

命令提示符（cmd）:

```cmd
mkdir %USERPROFILE%\.codex
```

---

### 步骤 2: 配置 config.toml

用记事本打开（不存在会新建）：

```cmd
notepad %USERPROFILE%\.codex\config.toml
```

粘贴以下内容（把 `base_url` 改成你的服务器地址）：

```toml
model_provider = "crs"
model = "gpt-5.2"
model_reasoning_effort = "xhigh"
disable_response_storage = true
preferred_auth_method = "apikey"

sandbox_mode = "danger-full-access"
approval_policy = "on-request"
# 或者更激进：
# approval_policy = "never"

[model_providers.crs]
name = "crs"
base_url = "http://x.x.x.x:10086/openai"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"

[features]
# 实际已去除
tui_app_server = false
# 关闭 MCP / 工具 / 列表 / 发现/建议（可避免 codex_apps 相关报错）
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"
```

**⚠️ 重要修改**：将 `base_url` 中的地址替换为管理员提供的服务器地址。

示例（假设服务器是 x.x.x.x:10086）：

```toml
base_url = "http://x.x.x.x:10086/openai"
```

**模型说明**：
- 默认使用 `gpt-5.2`（如管理员提供其他模型名，也可以直接替换 `model = "..."`）

**推理深度**：
- `low`: 快速响应
- `medium`: 平衡性能
- `high`: 深度思考（推荐）
- `xhigh`: 更深度思考（更慢，但更稳）

保存文件：按 `Ctrl+S` 保存，关闭记事本。

---

### 步骤 3: 配置 auth.json

用记事本打开（不存在会新建）：

```cmd
notepad %USERPROFILE%\.codex\auth.json
```

粘贴以下内容：

```json
{
  "OPENAI_API_KEY": null
}
```

**说明**：设置为 `null` 表示不使用 OpenAI 官方 API，而是通过 CRS 服务器中转。

---

### 步骤 4: 设置环境变量

#### 方法 1: 永久设置（推荐）

写入 **用户环境变量**（需要重开终端生效）：

```cmd
setx CRS_OAI_KEY "cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

重开 PowerShell 后验证：

```powershell
echo $env:CRS_OAI_KEY
```

#### 方法 2: 临时设置

只在当前终端会话有效：

PowerShell:

```powershell
$env:CRS_OAI_KEY="cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

命令提示符（cmd）:

```cmd
set CRS_OAI_KEY=cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## ✅ 验证配置

### 测试 1: 检查环境变量

PowerShell:

```powershell
echo $env:CRS_OAI_KEY
```

命令提示符（cmd）:

```cmd
echo %CRS_OAI_KEY%
```

应该输出完整的 API Key（以 `cr_` 开头）。

### 测试 2: 检查配置文件

PowerShell:

```powershell
Get-ChildItem $env:USERPROFILE\.codex
```

命令提示符（cmd）:

```cmd
dir %USERPROFILE%\.codex
```

应该看到：
- `config.toml`
- `auth.json`

### 测试 3: 测试连接

```powershell
codex "Hello, 你好"
```

**预期结果**：Codex 应该正常回复你的问候。

### 测试 4: 测试代码生成

```powershell
codex "写一个 Python 函数计算斐波那契数列"
```

**预期结果**：应该生成完整的 Python 函数代码。

---

## 📊 配置检查清单

完成配置后，确认以下内容：

```
□ %USERPROFILE%\.codex\config.toml 已创建并配置正确的 base_url
□ %USERPROFILE%\.codex\auth.json 已创建并设置 OPENAI_API_KEY 为 null
□ CRS_OAI_KEY 已写入用户环境变量（setx）或在当前会话临时设置
□ 重开终端后 echo CRS_OAI_KEY 能显示正确的 API Key
□ codex "Hello" 测试成功
```

---

## 💡 日常使用

```powershell
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

如果想使用更快的模型，编辑 `%USERPROFILE%\.codex\config.toml`：

```toml
# 更快响应：降低推理深度（越低越快）
model_reasoning_effort = "medium"

# 如果管理员提供了其他模型名，也可以直接切换 model，例如：
# model = "gpt-5.4"
```

修改后立即生效，无需重启（但建议重开一次终端以避免环境变量/Path 未刷新）。

---

## 🔧 常见问题

### Q1: 提示 "Error: ECONNREFUSED"

**原因**：无法连接到 CRS 服务器

**排查步骤**：

1. 检查 `config.toml` 中的 `base_url` 是否正确（是否带 `/openai`）。
2. 测试服务器连通性（示例）：
   ```powershell
   curl.exe http://服务器IP:端口/health
   ```
3. 联系管理员确认服务器状态。

---

### Q2: 提示 "Client not allowed" 或 "Unauthorized"

**原因**：API Key 无效、过期或未正确设置

**排查步骤**：

1. 检查环境变量是否设置：
   ```powershell
   echo $env:CRS_OAI_KEY
   ```
2. 若你用的是 `setx`，请确认 **重开终端** 后再试。
3. 仍失败请联系管理员更换 Key。

---

### Q3: 提示 "`codex` 不是内部或外部命令"

**原因**：npm 全局命令目录未加入 PATH，或需要重开终端

**排查步骤**：

1. 先重开 PowerShell / cmd。
2. 查看是否能定位到 `codex`：
   - PowerShell:
     ```powershell
     Get-Command codex -ErrorAction SilentlyContinue
     ```
   - cmd:
     ```cmd
     where codex
     ```
3. 查看 npm 全局前缀（codex 通常安装在该前缀的 `bin` 目录）：
   ```powershell
   npm config get prefix
   ```
4. Windows 下常见的 npm 全局命令目录是 `%APPDATA%\npm`（例如 `C:\Users\<你>\AppData\Roaming\npm`），请确认它在 **用户 Path** 里。
   - 查看该目录：
     ```powershell
     echo $env:APPDATA
     dir "$env:APPDATA\\npm"
     ```
   - 若 Path 缺失：打开“系统属性 -> 高级 -> 环境变量”，编辑“用户变量”里的 `Path`，添加 `%APPDATA%\npm`，然后重开终端。

---

### Q4: 提示 "stdin is not a terminal"

**原因**：在非交互式环境中运行

**解决方法**：使用单次提问模式，不要直接运行 `codex` 进入交互模式

```powershell
# 正确
codex "你的问题"

# 错误（在脚本或管道中）
echo "问题" | codex
```

---

## 📁 配置文件结构

```
%USERPROFILE%\.codex\
├── config.toml       # 主配置（服务器地址、模型）
├── auth.json         # 认证配置（设为 null）
└── ...               # 其他自动生成的文件

用户环境变量:
  CRS_OAI_KEY          # CRS API Key
```

---

## 🔐 安全提醒

⚠️ **保护好你的 API Key**：
- 不要分享给其他人
- 不要提交到 Git 仓库
- 不要在公开场合展示或截图

⚠️ **说明**：
- Windows 与 WSL 的配置互不影响；如果你在 WSL 中使用 codex，需要在 `~/.codex` 另行配置。

---

## 📝 配置要点总结

完整配置需要修改三个位置：

### 1. `%USERPROFILE%\.codex\config.toml`
- 设置 `base_url` 为 CRS 服务器地址
- 配置 `model` 和 `model_reasoning_effort`
- 指定 `env_key = "CRS_OAI_KEY"`

### 2. `%USERPROFILE%\.codex\auth.json`
- 设置 `"OPENAI_API_KEY": null`

### 3. 用户环境变量 `CRS_OAI_KEY`
- 推荐使用 `setx` 写入用户环境变量
- 注意 `setx` 需要重开终端生效

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
