# Node 和 npm 安装/卸载脚本说明

本目录用于单独处理 Windows 上的 Node.js/npm，不绑定 Codex 安装流程。

维护图谱：[`../docs/graphs/node-npm.drawio`](../docs/graphs/node-npm.drawio)

## `download-node-npm-install.cmd`

- 调用 `download-node-npm-install.ps1`，安装 Node.js LTS x64 zip 到当前用户目录（默认类似 `%LOCALAPPDATA%\Programs\nodejs`）。
- 下载完成后会读取 Node 官方 `SHASUMS256.txt` 并校验 zip 的 SHA256；校验失败会中止。
- 替换已有用户级 Node 时采用“先备份旧目录、再移动新目录、失败回滚”的方式，避免先删旧版本后安装失败导致本机没有 Node 可用。
- 会把用户级 Node 目录加入用户 `Path`；如果当前终端看不到新路径，重开 PowerShell/cmd。

## `uninstall-node-npm.cmd`

- 优先删除本脚本安装的用户级 Node 目录。
- 如果没有找到用户级安装，会继续查找系统级 Node.js MSI 卸载项，并通过 UAC 调用 `msiexec` 卸载。
- 系统级卸载本身会要求管理员权限，这是预期行为；如果客户无法授权，请让客户通过“应用和功能”手动卸载，或只使用用户级安装脚本覆盖使用。

## 为什么要做下载校验

- HTTPS 能降低传输风险，但不能覆盖所有场景，例如代理/CDN/缓存污染、错误镜像、下载不完整、或本地文件被替换。
- SHA256 校验能确保下载到的 Node zip 与 Node 官方发布清单一致；不一致时脚本会拒绝解压和安装。
- 没有校验的后果：轻则 zip 损坏导致安装失败，重则被篡改的二进制进入用户 `Path`，带来供应链安全风险。
