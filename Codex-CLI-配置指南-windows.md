# Codex CLI 配置指南（Windows）

> 通过 CRS 服务器使用 ChatGPT Pro 的 Codex 代码助手

**适用系统**: Windows 10/11（PowerShell 或命令提示符）
**前提条件**: 已安装 Codex CLI
**预计耗时**: 5 分钟

---

## 📥 安装 Codex CLI（新增）

> 如果你已经安装过 Codex CLI，可直接跳到“前置准备”。

### 步骤 0: 用命令安装 Node.js（含 npm）

若提示 `winget` 不存在，先在 **管理员 PowerShell** 执行：
```powershell
$progressPreference = 'silentlyContinue'
Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
Repair-WinGetPackageManager -AllUsers
winget --version
```

然后执行：
```powershell
winget install -e --id OpenJS.NodeJS.LTS
node -v
npm -v
```

> 若命令提示找不到 `node` 或 `npm`，请重开终端再试。

### 步骤 1: 安装 Codex CLI

```powershell
npm i -g @openai/codex
codex --version
```

---

## 📋 前置准备

向管理员获取：
- **CRS 服务器地址**: `http://服务器IP:端口`
- **CRS API Key**: `cr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

---

## 🔧 配置步骤

### 步骤 1: 创建配置目录

PowerShell:
```powershell
mkdir $env:USERPROFILE\.codex
```

或命令提示符:
```cmd
mkdir %USERPROFILE%\.codex
```

### 步骤 2: 配置 config.toml

用记事本打开（不存在会新建）：
```cmd
notepad %USERPROFILE%\.codex\config.toml
```

粘贴以下内容（把 `base_url` 改成你的服务器地址）：
```toml
model_provider = "crs"
model = "gpt-5.1-codex-max"
model_reasoning_effort = "high"
disable_response_storage = true
preferred_auth_method = "apikey"

[model_providers.crs]
name = "crs"
base_url = "http://x.x.x.x:10086/openai"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"
```

### 步骤 3: 配置 auth.json

```cmd
notepad %USERPROFILE%\.codex\auth.json
```

内容如下：
```json
{
  "OPENAI_API_KEY": null
}
```

### 步骤 4: 设置环境变量

临时（当前会话有效）：
- PowerShell:
```powershell
$env:CRS_OAI_KEY="cr_xxx..."
```
- 命令提示符:
```cmd
set CRS_OAI_KEY=cr_xxx...
```

永久（推荐，写入用户环境变量，重开终端生效）：
```cmd
setx CRS_OAI_KEY "cr_xxx..."
```

---

## ✅ 验证配置

PowerShell:
```powershell
echo $env:CRS_OAI_KEY
codex "Hello, 你好"
```

命令提示符:
```cmd
echo %CRS_OAI_KEY%
codex "Hello, 你好"
```

---

## 🔧 常见问题

### Q1: 提示 "Error: ECONNREFUSED"
- 检查 `base_url` 是否正确
- 确认 CRS 服务器可访问：
```cmd
curl http://服务器IP:端口/health
```

### Q2: 提示 "Unauthorized" 或 "Client not allowed"
- 确认环境变量是否生效
- 重新设置 `CRS_OAI_KEY` 并重开终端

---

## 📁 配置文件位置

```
%USERPROFILE%\.codex\config.toml
%USERPROFILE%\.codex\auth.json
```

---

## 🔐 安全提醒

- 不要把 `CRS_OAI_KEY` 提交到 Git 或公开分享。
- Windows 与 WSL 的配置互不影响，WSL 需要在 `~/.codex` 单独配置。

**文档版本**: 1.3
**更新时间**: 2026-03-06
