#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${CRS_OAI_KEY:-}" ]]; then
  printf '%s\n' '[ERROR] CRS_OAI_KEY 未设置' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGGING_MODULE="$REPO_ROOT/script-modules/logging/logging.sh"
if [[ -f "$LOGGING_MODULE" ]]; then
  # shellcheck source=../script-modules/logging/logging.sh
  . "$LOGGING_MODULE"
else
  log_info() { printf '[INFO] %s\n' "$*"; }
  log_warn() { printf '[WARN] %s\n' "$*"; }
  log_ok() { printf '[OK] %s\n' "$*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if declare -F codex_log_init >/dev/null 2>&1; then
  codex_log_init normal
fi

FORCE=0
case "${1:-}" in
  '') ;;
  --force) FORCE=1 ;;
  -h|--help)
    cat <<'USAGE'
Usage: restart-codex-app-server-linux.sh [--force]

  --force  Skip the confirmation prompt.
  -h, --help  Show this help.
USAGE
    exit 0
    ;;
  *)
    log_error "Unknown argument: $1"
    exit 2
    ;;
esac
if [[ $# -gt 1 ]]; then
  log_error "Unknown argument: $2"
  exit 2
fi

if [[ "$(uname -s 2>/dev/null || true)" != "Linux" ]]; then
  log_error 'This script is for Linux only.'
  exit 2
fi

if [[ -n "${CODEX_HOME:-}" ]]; then
  CODEX_HOME_DIR="$CODEX_HOME"
  CODEX_HOME_SOURCE='当前进程 CODEX_HOME'
elif [[ -n "${HOME:-}" ]]; then
  CODEX_HOME_DIR="$HOME/.codex"
  CODEX_HOME_SOURCE='HOME/.codex'
else
  log_error '无法确定 CODEX_HOME：CODEX_HOME 和 HOME 均未设置。'
  exit 1
fi

if [[ ! -d "$CODEX_HOME_DIR" ]]; then
  log_error "CODEX_HOME 路径不存在或不是目录（来源：$CODEX_HOME_SOURCE）：$CODEX_HOME_DIR"
  exit 1
fi
log_info "CODEX_HOME: $CODEX_HOME_DIR（来源：$CODEX_HOME_SOURCE）"

CODEX_COMMAND="$(type -P codex 2>/dev/null || true)"
if [[ -z "$CODEX_COMMAND" || ! -x "$CODEX_COMMAND" ]]; then
  log_error '找不到 codex 命令。请确认 Codex CLI 已安装且当前 shell 的 PATH 已加载。'
  log_warn '命令失败时，请分别检查：'
  printf '%s\n' '  CRS_OAI_KEY' '  codex login status' '  codex app-server daemon version' '  CODEX_HOME' '  config.toml' '  auth.json'
  exit 1
fi
log_info "Codex 命令路径: $CODEX_COMMAND"

CODEX_OUTPUT=''
CODEX_EXIT_CODE=0
invoke_codex() {
  set +e
  CODEX_OUTPUT="$(CRS_OAI_KEY="$CRS_OAI_KEY" CODEX_HOME="$CODEX_HOME_DIR" "$CODEX_COMMAND" "$@" 2>&1)"
  CODEX_EXIT_CODE=$?
  set -e
}

print_command_output() {
  if [[ -n "$CODEX_OUTPUT" ]]; then
    printf '%s\n' "$CODEX_OUTPUT"
  fi
}

print_failure_hints() {
  log_warn '命令失败时，请分别检查：'
  printf '%s\n' '  codex login status' '  codex app-server daemon version' '  CODEX_HOME' '  config.toml' '  auth.json'
}

run_daemon_command() {
  local action="$1"

  log_info "执行：codex app-server daemon $action"
  invoke_codex app-server daemon "$action"
  print_command_output
  if [[ "$CODEX_EXIT_CODE" -ne 0 ]]; then
    if printf '%s' "$CODEX_OUTPUT" | grep -Eiq '(unknown|unrecognized|invalid|unsupported|not supported|does not support|no such command|unexpected).{0,120}(command|subcommand|app-server|daemon|stop|start)|(command|subcommand|app-server|daemon|stop|start).{0,120}(unknown|unrecognized|invalid|unsupported|not supported|does not support|no such command|unexpected)'; then
      log_error "当前 Codex 版本不支持 app-server daemon $action（退出码：$CODEX_EXIT_CODE）。"
    else
      log_error "app-server daemon $action 失败（退出码：$CODEX_EXIT_CODE）。"
    fi
    print_failure_hints
    exit 1
  fi
}

verify_linux_app_server_environment() {
  local pid=''
  local attempt

  for attempt in {1..20}; do
    pid="$(pgrep -f 'codex app-server --listen' | head -n1 || true)"
    if [[ -n "$pid" ]] && [[ -r "/proc/$pid/environ" ]] && tr '\0' '\n' < "/proc/$pid/environ" | grep -F -x -q -- "CRS_OAI_KEY=$CRS_OAI_KEY"; then
      log_ok "CRS_OAI_KEY 已传入 app-server（PID: $pid，值已隐藏）。"
      return 0
    fi
    sleep 0.5
  done

  if [[ -z "$pid" ]]; then
    log_error "未找到 codex app-server --listen 进程，无法验证 CRS_OAI_KEY。"
  else
    log_error "CRS_OAI_KEY 未传入 app-server（PID: $pid）。"
  fi
  return 1
}

invoke_codex --version
log_info '当前 Codex 版本：'
print_command_output
if [[ "$CODEX_EXIT_CODE" -ne 0 || -z "$CODEX_OUTPUT" ]]; then
  log_error "无法读取 Codex 版本（退出码：$CODEX_EXIT_CODE）。"
  print_failure_hints
  exit 1
fi

log_info '即将停止并重新启动 codex app-server daemon'
log_warn '重启可能中断正在运行的 app-server 任务，请先确认没有重要任务执行。'
if [[ "$FORCE" -eq 0 ]]; then
  read -r -p '确认继续重启 app-server daemon？输入 Y 继续，其他输入取消: ' confirmation || confirmation=''
  if [[ ! "$confirmation" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
    log_warn '用户取消了 app-server daemon 重启。'
    exit 1
  fi
fi

run_daemon_command stop
run_daemon_command start

log_info '执行 app-server daemon version，以下为原样输出：'
invoke_codex app-server daemon version
print_command_output
if [[ "$CODEX_EXIT_CODE" -ne 0 || -z "$CODEX_OUTPUT" ]]; then
  log_error "重启成功但 app-server daemon version 检查失败（退出码：$CODEX_EXIT_CODE）。"
  print_failure_hints
  exit 1
fi
log_ok 'app-server daemon version 检查通过。'
verify_linux_app_server_environment
