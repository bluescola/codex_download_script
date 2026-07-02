# Shared logging helpers for Bash installers.

CODEX_LOG_LEVEL="${CODEX_LOG_LEVEL:-normal}"

codex_log_is_dry_run() {
  case "${DRY_RUN:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
  esac

  case "${DryRun:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
  esac

  return 1
}

codex_log_init() {
  local level
  level="${1:-normal}"

  case "$level" in
    ""|normal)
      CODEX_LOG_LEVEL="normal"
      ;;
    verbose)
      CODEX_LOG_LEVEL="verbose"
      ;;
    trace)
      CODEX_LOG_LEVEL="trace"
      ;;
    *)
      CODEX_LOG_LEVEL="normal"
      codex_log_write "WARN" "Unknown log level \"$level\"; using normal."
      ;;
  esac
}

codex_log_write() {
  local level message timestamp log_file log_dir
  level="${1:-INFO}"
  shift || true
  message="$*"

  printf '[%s] %s\n' "$level" "$message"

  if codex_log_is_dry_run; then
    return 0
  fi

  log_file="${CODEX_INSTALL_LOG_FILE:-}"
  if [ -z "$log_file" ]; then
    return 0
  fi

  timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '0000-00-00 00:00:00')"
  log_dir="${log_file%/*}"
  if [ "$log_dir" != "$log_file" ] && [ -n "$log_dir" ]; then
    mkdir -p "$log_dir" 2>/dev/null || true
  fi

  printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >>"$log_file" 2>/dev/null || true
}

log_info() {
  codex_log_write "INFO" "$@"
}

log_warn() {
  codex_log_write "WARN" "$@"
}

log_ok() {
  codex_log_write "OK" "$@"
}

log_debug() {
  case "$CODEX_LOG_LEVEL" in
    verbose|trace) codex_log_write "DEBUG" "$@" ;;
  esac
}

log_trace() {
  case "$CODEX_LOG_LEVEL" in
    trace) codex_log_write "TRACE" "$@" ;;
  esac
}
