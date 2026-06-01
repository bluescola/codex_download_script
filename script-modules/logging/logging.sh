#!/usr/bin/env bash

codex_log_init() {
  local requested="${1:-${CODEX_INSTALL_LOG_LEVEL:-normal}}"
  case "$requested" in
    normal|verbose|trace)
      CODEX_LOG_LEVEL="$requested"
      ;;
    *)
      CODEX_LOG_LEVEL="normal"
      printf '[WARN] Unknown log level "%s"; using normal.\n' "$requested" >&2
      ;;
  esac
  export CODEX_LOG_LEVEL
}

codex_log_emit() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
  if [[ "${DRY_RUN:-0}" -ne 1 ]] && [[ -n "${CODEX_INSTALL_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$CODEX_INSTALL_LOG_FILE")" 2>/dev/null || true
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$CODEX_INSTALL_LOG_FILE" 2>/dev/null || true
  fi
  return 0
}

log_info() { codex_log_emit INFO "$*"; }
log_warn() { codex_log_emit WARN "$*"; }
log_ok() { codex_log_emit OK "$*"; }

log_debug() {
  case "${CODEX_LOG_LEVEL:-normal}" in
    verbose|trace) codex_log_emit DEBUG "$*" ;;
  esac
}

log_trace() {
  case "${CODEX_LOG_LEVEL:-normal}" in
    trace) codex_log_emit TRACE "$*" ;;
  esac
}
