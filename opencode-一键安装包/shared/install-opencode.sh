#!/usr/bin/env bash
# ==============================================================================
# install-opencode.sh — OpenCode 2 共享安装逻辑 (Linux & macOS)
# 自动检测操作系统，安装 Node.js（若缺失），并通过镜像源安装 @opencode/cli。
# 入口: bash ../linux/install-opencode-linux.sh 或 bash ../mac/install-opencode-mac.sh
# ==============================================================================
set -euo pipefail

# ================= 编码设置（避免中文乱码）=================
# 强制使用 UTF-8 locale，确保终端能正常显示中文
setup_locale() {
  # 如果当前 locale 已支持 UTF-8，则不做修改
  local current_lang="${LANG:-}"
  local current_lc_all="${LC_ALL:-}"
  if printf '%s' "$current_lang$current_lc_all" | grep -qi 'utf-8\|utf8'; then
    return 0
  fi

  # 优先使用系统已有的中文 UTF-8 locale
  local preferred_locales="zh_CN.UTF-8 zh_TW.UTF-8 en_US.UTF-8 C.UTF-8"
  for loc in $preferred_locales; do
    if locale -a 2>/dev/null | grep -qi "^${loc}$"; then
      export LANG="$loc"
      export LC_ALL="$loc"
      return 0
    fi
  done

  # 回退：至少保证输出编码为 UTF-8
  export LANG="en_US.UTF-8"
  export LC_ALL="en_US.UTF-8"
  export PYTHONIOENCODING="utf-8"
}

setup_locale

# ================= 参数开关 =================
FORCE_NODE_REINSTALL=0
FORCE_OPENCODE_REINSTALL=0
SKIP_NODE_CHECK=0
DRY_RUN=0
LOG_LEVEL="${OPENCODE_INSTALL_LOG_LEVEL:-normal}"

# npm registry 由 detect_npm_registry() 自动探测，此处为最终使用值
NPM_REGISTRY=""
NPM_PREFIX="${HOME}/.local/share/opencode/npm"
NPM_CACHE="${HOME}/.cache/opencode/npm"

# 国内 npm 镜像候选列表（按优先级排序），最后一个为官方源
NPM_REGISTRY_CANDIDATES=(
  "https://registry.npmmirror.com"   # 淘宝镜像（最主流）
  "https://mirrors.huaweicloud.com/repository/npm"  # 华为云
  "https://mirrors.tencent.com/npm"  # 腾讯云
  "https://registry.npmjs.org"       # 官方（备用）
)

# ================= 日志函数 =================
log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_ok()    { printf '[OK]   %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_debug() {
  case "$LOG_LEVEL" in
    verbose|trace) printf '[DEBUG] %s\n' "$*" ;;
  esac
}

# ================= 帮助文档 =================
print_help() {
  cat <<'USAGE'
用法: bash linux/install-opencode-linux.sh [选项]
      bash mac/install-opencode-mac.sh [选项]

选项:
  --force-node-reinstall     强制重装 Node.js
  --force-opencode-reinstall 强制重装 @opencode/cli
  --skip-node-check          跳过 Node.js 检测，直接安装 @opencode/cli
  --dry-run                  仅打印环境摘要，不做任何修改
  --verbose                  输出详细日志
  --registry <url>           自定义 npm registry（默认: https://registry.npmmirror.com）
  -h, --help                 显示此帮助

示例:
  bash linux/install-opencode-linux.sh
  bash mac/install-opencode-mac.sh --force-opencode-reinstall
  bash linux/install-opencode-linux.sh --registry https://registry.npmjs.org
USAGE
}

# ================= 解析参数 =================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-node-reinstall)
      FORCE_NODE_REINSTALL=1; shift ;;
    --force-opencode-reinstall)
      FORCE_OPENCODE_REINSTALL=1; shift ;;
    --skip-node-check)
      SKIP_NODE_CHECK=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --verbose)
      LOG_LEVEL="verbose"; shift ;;
    --trace)
      LOG_LEVEL="trace"; shift ;;
    --registry)
      if [[ $# -lt 2 || "$2" == -* || ! "$2" =~ ^https?://[^[:space:]]+$ ]]; then
        log_error "--registry 需要 http(s) URL。"; exit 1
      fi
      NPM_REGISTRY="${2%/}"
      shift 2 ;;
    -h|--help)
      print_help; exit 0 ;;
    *)
      log_error "未知参数: $1"; exit 1 ;;
  esac
done

# ================= 工具函数 =================
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# 检测命令是否是 Linux/macOS 原生命令（排除 WSL 下 /mnt/ 挂载的 Windows 路径）
cmd_exists_native() {
  local cmd_path
  cmd_path="$(command -v "$1" 2>/dev/null)" || return 1
  # /mnt/ 开头的路径是 WSL 挂载的 Windows 目录，不算原生 Linux/macOS 命令
  case "$cmd_path" in
    /mnt/*) return 1 ;;
  esac
  return 0
}

detect_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Linux*)  printf 'linux' ;;
    Darwin*) printf 'macos' ;;
    *)       printf 'unknown' ;;
  esac
}

detect_npm_registry() {
  log_info "正在探测可用的 npm 镜像..."

  local registry timeout_sec=5
  for registry in "${NPM_REGISTRY_CANDIDATES[@]}"; do
    local is_official=0
    [[ "$registry" == "https://registry.npmjs.org" ]] && is_official=1

    printf '  测试: %s ... ' "$registry"
    local ok=0

    if cmd_exists curl; then
      if curl --fail --silent --max-time "$timeout_sec" --head "${registry}/@opencode%2fcli" -o /dev/null 2>&1; then
        ok=1
      fi
    elif cmd_exists wget; then
      if wget --quiet --timeout="$timeout_sec" --spider "${registry}/@opencode%2fcli" 2>/dev/null; then
        ok=1
      fi
    fi

    if [[ "$ok" -eq 1 ]]; then
      printf '可用\n'
      NPM_REGISTRY="$registry"

      if [[ "$is_official" -eq 1 ]]; then
        log_warn "所有国内镜像均不可达，已回退到官方源: ${NPM_REGISTRY}"
        log_warn "如果下载缓慢或失败，请开启代理（VPN / 系统代理）后重试。"
        log_warn "常见代理设置方式:"
        log_warn "  export https_proxy=http://127.0.0.1:7890"
        log_warn "  export http_proxy=http://127.0.0.1:7890"
      else
        log_ok "使用镜像: ${NPM_REGISTRY}"
      fi
      return 0
    else
      printf '不可达\n'
    fi
  done

  # 理论上不会走到这里（官方源是最后一个候选）
  log_warn "所有镜像均不可达，使用官方源并建议开启代理。"
  NPM_REGISTRY="https://registry.npmjs.org"
}

require_non_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    log_error "请勿以 root 用户运行此脚本，请切换到普通用户后重试。"
    exit 1
  fi
}

print_preflight_summary() {
  local os
  os="$(detect_os)"
  log_info "===== 环境预检 ====="
  log_info "  操作系统: $(uname -s) $(uname -m) [检测为: $os]"
  log_info "  用户: $(id -un 2>/dev/null || printf 'unknown') (uid=$(id -u 2>/dev/null))"
  log_info "  HOME: ${HOME:-未设置}"
  if cmd_exists_native node; then
    log_info "  node: $(command -v node) ($(node --version 2>/dev/null || printf '版本未知'))"
  else
    log_info "  node: 未找到"
  fi
  if cmd_exists_native npm; then
    log_info "  npm: $(command -v npm) ($(npm --version 2>/dev/null || printf '版本未知'))"
  else
    log_info "  npm: 未找到"
  fi
  if cmd_exists_native opencode; then
    log_info "  opencode: $(command -v opencode) ($(opencode --version 2>/dev/null || printf '版本未知'))"
  else
    log_info "  opencode: 未找到"
  fi
  log_info "  npm registry: ${NPM_REGISTRY}"
  log_debug "  DRY_RUN=$DRY_RUN FORCE_NODE=$FORCE_NODE_REINSTALL FORCE_OPENCODE=$FORCE_OPENCODE_REINSTALL SKIP_NODE=$SKIP_NODE_CHECK"
}

# ================= Node.js 安装 =================

install_node_linux() {
  log_info "正在安装 Node.js (Linux)..."

  # 优先尝试通过 nvm 安装（用户空间，无需 sudo）
  if ! cmd_exists curl && ! cmd_exists wget; then
    log_error "需要 curl 或 wget 来下载 nvm，请先安装其中一个工具。"
    exit 1
  fi

  # nvm 国内镜像（gitee），官方地址作为备用
  local nvm_gitee_url="https://gitee.com/mirrors/nvm/raw/v0.40.1/install.sh"
  local nvm_github_url="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh"
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"

  if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
    log_info "下载并安装 nvm（优先国内镜像）..."
    local nvm_installed=0 nvm_script
    nvm_script="$(mktemp)"

    # 优先尝试 gitee 国内镜像
    if cmd_exists curl; then
      log_info "尝试 gitee 镜像: $nvm_gitee_url"
      if curl --connect-timeout 10 -fsSL "$nvm_gitee_url" -o "$nvm_script" || curl -fsSL "$nvm_github_url" -o "$nvm_script"; then
        bash "$nvm_script" && nvm_installed=1
      fi
    elif cmd_exists wget; then
      log_info "尝试 gitee 镜像: $nvm_gitee_url"
      if wget --timeout=10 -qO "$nvm_script" "$nvm_gitee_url" || wget -qO "$nvm_script" "$nvm_github_url"; then
        bash "$nvm_script" && nvm_installed=1
      fi
    fi
    rm -f "$nvm_script"

    if [[ "$nvm_installed" -eq 0 ]]; then
      log_error "nvm 安装失败，请检查网络连接后重试。"
      exit 1
    fi
  else
    log_info "nvm 已存在，跳过 nvm 下载。"
  fi

  # 加载 nvm（nvm.sh 内部有不兼容 set -eu 的写法，需临时关闭）
  export NVM_DIR="$nvm_dir"
  # shellcheck source=/dev/null
  set +eu
  . "$NVM_DIR/nvm.sh"
  set -eu

  if ! declare -F nvm >/dev/null 2>&1; then
    log_error "nvm 加载失败，请手动检查 $NVM_DIR/nvm.sh。"
    exit 1
  fi

  # 使用淘宝镜像加速 Node.js 下载
  # nvm 内部使用了 set -u 不兼容的变量，需全程关闭 set -e / set -u
  log_info "通过 nvm 安装 Node.js LTS（使用淘宝镜像加速）..."
  export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"

  set +eu
  local nvm_status=0
  nvm install --lts && nvm use --lts && nvm alias default 'lts/*' || nvm_status=$?
  set -eu
  if [[ "$nvm_status" -ne 0 ]]; then
    log_error "nvm 安装或启用 Node.js LTS 失败。"
    exit "$nvm_status"
  fi

  hash -r 2>/dev/null || true

  if ! cmd_exists_native node; then
    log_error "Node.js 安装后仍无法找到 node 命令，请重新打开终端后重试。"
    exit 1
  fi

  log_ok "Node.js: $(node --version)"
  log_ok "npm:     $(npm --version)"
}

install_node_macos() {
  log_info "正在安装 Node.js (macOS)..."

  if cmd_exists brew; then
    log_info "检测到 Homebrew，通过 brew 安装 Node.js..."
    brew install node
    log_ok "Node.js: $(node --version)"
    log_ok "npm:     $(npm --version)"
    return 0
  fi

  # Homebrew 未安装，先安装 Homebrew
  if ! cmd_exists curl; then
    log_error "需要 curl 来安装 Homebrew，请先安装 curl。"
    exit 1
  fi

  log_info "未检测到 Homebrew，正在安装 Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # 将 Homebrew 加入当前 shell PATH
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if ! cmd_exists brew; then
    log_error "Homebrew 安装失败，请手动安装后重试。"
    exit 1
  fi

  log_ok "Homebrew 安装完成。"
  log_info "通过 Homebrew 安装 Node.js..."
  brew install node

  log_ok "Node.js: $(node --version)"
  log_ok "npm:     $(npm --version)"
}

ensure_node_npm() {
  if [[ "$SKIP_NODE_CHECK" -eq 1 ]]; then
    log_info "--skip-node-check: 跳过 Node.js 检测。"
    return 0
  fi

  local os
  os="$(detect_os)"

  if cmd_exists_native node && cmd_exists_native npm; then
    local node_ver npm_ver
    node_ver="$(node --version 2>/dev/null || printf 'unknown')"
    npm_ver="$(npm --version 2>/dev/null || printf 'unknown')"
    log_ok "检测到 Node.js 已安装，当前版本: $node_ver  (npm $npm_ver)"

    if [[ "$FORCE_NODE_REINSTALL" -eq 1 ]]; then
      log_info "已指定强制重装，继续安装..."
    else
      printf '\n'
      printf '  是否重新安装 Node.js？\n'
      printf '  [1] 不重装，保留当前版本（推荐）\n'
      printf '  [2] 重新安装（覆盖当前版本）\n'
      printf '\n'
      local choice=''
      while true; do
        read -r -p '  请输入选项 [1/2]，然后按回车: ' choice || choice=1
        case "$choice" in
          1|'')
            log_info "保留当前 Node.js 版本，跳过安装。"
            return 0
            ;;
          2)
            log_info "用户选择重新安装 Node.js..."
            break
            ;;
          *)
            printf '  请输入 1 或 2\n'
            ;;
        esac
      done
    fi
  fi

  case "$os" in
    linux) install_node_linux ;;
    macos) install_node_macos ;;
    *)
      log_error "不支持的操作系统: $(uname -s)。请手动安装 Node.js 后重试。"
      exit 1
      ;;
  esac
}

# ================= opencode 配置文件 =================

# 全局配置文件路径: ~/.config/opencode/opencode.json
OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
OPENCODE_CONFIG_FILE="${OPENCODE_CONFIG_DIR}/opencode.json"

create_opencode_config() {
  if [[ -f "${OPENCODE_CONFIG_DIR}/opencode.jsonc" ]]; then
    log_info "保留现有配置文件: ${OPENCODE_CONFIG_DIR}/opencode.jsonc"
    return 0
  fi
  mkdir -p "${OPENCODE_CONFIG_DIR}"

  if [[ -f "${OPENCODE_CONFIG_FILE}" ]]; then
    log_info "配置文件已存在: ${OPENCODE_CONFIG_FILE}"
  else
    log_info "创建 opencode 配置文件: ${OPENCODE_CONFIG_FILE}"
    printf '{"$schema":"https://opencode.ai/config.json"}\n' > "${OPENCODE_CONFIG_FILE}"
    log_ok "配置文件已创建: ${OPENCODE_CONFIG_FILE}"
  fi
  log_info "可在 OpenCode 中使用 /connect 配置提供商。"
}

configure_npm_path() {
  local bin_dir="${NPM_PREFIX}/bin" profile
  mkdir -p "$bin_dir" "$NPM_CACHE"
  export PATH="$bin_dir:$PATH"
  for profile in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if ! [[ -f "$profile" ]] || ! grep -Fq '# >>> opencode npm >>>' "$profile"; then
      printf '\n# >>> opencode npm >>>\nexport PATH="$HOME/.local/share/opencode/npm/bin:$PATH"\n# <<< opencode npm <<<\n' >> "$profile"
    fi
  done
  if [[ "$(detect_os)" == macos ]]; then
    profile="$HOME/.zprofile"
  else
    profile="$HOME/.profile"
  fi
  if ! [[ -f "$profile" ]] || ! grep -Fq '# >>> opencode npm >>>' "$profile"; then
    printf '\n# >>> opencode npm >>>\nexport PATH="$HOME/.local/share/opencode/npm/bin:$PATH"\n# <<< opencode npm <<<\n' >> "$profile"
  fi
}

# ================= opencode 安装 =================

ensure_opencode() {
  # 检查是否已安装（排除 WSL 下挂载的 Windows 版本）
  if cmd_exists_native opencode; then
    local ver
    ver="$(opencode --version 2>/dev/null || printf '版本未知')"
    log_ok "检测到 opencode 已安装，当前版本: $ver"

    if [[ "$FORCE_OPENCODE_REINSTALL" -eq 1 ]]; then
      log_info "已指定强制重装，继续安装..."
    elif [[ "$ver" == 1.* ]]; then
      log_info "检测到 OpenCode 1，升级到 OpenCode 2..."
    else
      # 交互询问用户
      printf '\n'
      printf '  是否重新安装 opencode？\n'
      printf '  [1] 不重装，保留当前版本（推荐）\n'
      printf '  [2] 重新安装（覆盖当前版本）\n'
      printf '\n'
      local choice=''
      while true; do
        read -r -p '  请输入选项 [1/2]，然后按回车: ' choice || choice=1
        case "$choice" in
          1|'')
            log_info "保留当前 opencode 版本，跳过安装。"
            return 0
            ;;
          2)
            log_info "用户选择重新安装 opencode..."
            break
            ;;
          *)
            printf '  请输入 1 或 2\n'
            ;;
        esac
      done
    fi
  fi

  if ! cmd_exists_native npm; then
    log_error "npm 未找到，无法安装 @opencode/cli。请先确保 Node.js/npm 已安装。"
    exit 1
  fi

  log_info "正在安装 @opencode/cli..."
  log_info "registry: ${NPM_REGISTRY}; prefix: ${NPM_PREFIX}"
  if ! npm install -g --prefix "$NPM_PREFIX" --cache "$NPM_CACHE" @opencode/cli --registry "$NPM_REGISTRY"; then
    log_error "@opencode/cli 安装失败。"
    exit 1
  fi

  # 刷新命令哈希
  hash -r 2>/dev/null || true

  local installed_command="${NPM_PREFIX}/bin/opencode" ver
  if [[ ! -x "$installed_command" ]] || ! ver="$("$installed_command" --version 2>/dev/null)" || [[ -z "$ver" ]]; then
    log_error "安装后无法执行 ${installed_command} --version。"
    return 1
  fi
  log_ok "opencode 安装成功: $ver"
}

# ================= 主流程 =================

main() {
  local os
  os="$(detect_os)"

  if [[ "$os" == "unknown" || ( -n "${OPENCODE_TARGET_OS:-}" && "$os" != "$OPENCODE_TARGET_OS" ) ]]; then
    log_error "不支持的操作系统: $(uname -s)；此入口要求 ${OPENCODE_TARGET_OS:-Linux/macOS}。"
    exit 1
  fi

  log_info "===== OpenCode 2 一键安装脚本 ====="
  log_info "目标系统: $os"

  print_preflight_summary

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_ok "Dry run 完成，未做任何修改。"
    return 0
  fi

  require_non_root
  if [[ -z "$NPM_REGISTRY" ]]; then detect_npm_registry; fi
  ensure_node_npm
  configure_npm_path
  ensure_opencode
  create_opencode_config

  printf '\n'
  log_ok "===== 安装完成 ====="
  if [[ -f "${OPENCODE_CONFIG_DIR}/opencode.jsonc" ]]; then
    log_info "配置文件位置: ${OPENCODE_CONFIG_DIR}/opencode.jsonc"
  else
    log_info "配置文件位置: ${OPENCODE_CONFIG_FILE}"
  fi
  log_info "如果 opencode 命令不可用，请打开新终端。"
  log_info "验证安装: opencode --version"
  log_info "启动 opencode: opencode"
}

main "$@"
