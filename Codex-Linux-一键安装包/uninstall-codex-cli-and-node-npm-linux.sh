#!/usr/bin/env bash
set -euo pipefail

KEEP_CODEX_HOME=0
KEEP_NPM_CACHE=0
SKIP_NODE_UNINSTALL=0
FORCE_REMOVE_SHARED_NODE=0
SKIP_SYSTEM_CODEX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-codex-home)
      KEEP_CODEX_HOME=1
      shift
      ;;
    --keep-npm-cache)
      KEEP_NPM_CACHE=1
      shift
      ;;
    --skip-node-uninstall)
      SKIP_NODE_UNINSTALL=1
      shift
      ;;
    --force-remove-shared-node)
      FORCE_REMOVE_SHARED_NODE=1
      shift
      ;;
    --skip-system-codex)
      SKIP_SYSTEM_CODEX=1
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: uninstall-codex-cli-and-node-npm-linux.sh [options]

Uninstalls in this order:
  1. Stop Codex/installer-owned Node/npm processes
  2. Uninstall @openai/codex and remove Codex config/profile residue
  3. Remove Node.js/npm only when the install is installer-owned

Options:
  --keep-codex-home          Keep CODEX_HOME / ~/.codex
  --keep-npm-cache           Keep installer npm cache
  --skip-node-uninstall      Remove Codex only; leave Node.js/npm untouched
  --force-remove-shared-node Remove ~/.nvm even when it may be shared by other tools
  --skip-system-codex        Do not try to remove system-level Codex under /usr or /opt
  -h, --help                 Show this help
USAGE
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_ok() { printf '[OK] %s\n' "$*"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[ERROR] This script is for Linux only." >&2
    exit 1
  fi
}

contains_non_ascii() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 1
  LC_ALL=C printf '%s' "$value" | grep -q '[^ -~]'
}

detect_ascii_safe_paths() {
  contains_non_ascii "${HOME:-}" || contains_non_ascii "${TMPDIR:-}"
}

trim_trailing_slash() {
  local p="${1:-}"
  while [[ "$p" != "/" && "$p" == */ ]]; do
    p="${p%/}"
  done
  printf '%s\n' "$p"
}

path_under() {
  local path root
  path="$(trim_trailing_slash "${1:-}")"
  root="$(trim_trailing_slash "${2:-}")"

  [[ -n "$path" && -n "$root" ]] || return 1
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

append_unique() {
  local var_name="$1"
  local value="${2:-}"
  local existing
  [[ -n "$value" ]] || return 0

  eval "local current=(\"\${${var_name}[@]:-}\")"
  for existing in "${current[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  eval "${var_name}+=(\"\$value\")"
}

DEFAULT_ASCII_ROOT="/var/tmp/codex-$(id -u 2>/dev/null || printf 'user')"
USE_ASCII_SAFE_PATHS=0
if detect_ascii_safe_paths; then
  USE_ASCII_SAFE_PATHS=1
fi

if [[ "$USE_ASCII_SAFE_PATHS" -eq 1 ]]; then
  CODEX_UNIX_ROOT="${CODEX_UNIX_ASCII_ROOT:-$DEFAULT_ASCII_ROOT}"
  CODEX_UNIX_ROOT="${CODEX_UNIX_ROOT%/}"
  NVM_DIR="${CODEX_UNIX_ROOT}/.nvm"
  CODEX_HOME_DIR="${CODEX_UNIX_ROOT}/.codex"
else
  CODEX_UNIX_ROOT=""
  NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  CODEX_HOME_DIR="$HOME/.codex"
fi

LEGACY_NPM_CACHE="$HOME/.npm-cache"
ASCII_NPM_CACHE="${CODEX_UNIX_ROOT:+$CODEX_UNIX_ROOT/npm-cache}"
CODEX_PREFIXES=()
SYSTEM_PREFIXES=()

run_with_optional_sudo() {
  if "$@"; then
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && cmd_exists sudo; then
    sudo "$@"
    return $?
  fi

  return 1
}

remove_path_if_safe() {
  local target="$1"
  local safety_root="${2:-}"

  [[ -e "$target" || -L "$target" ]] || return 0
  if [[ -n "$safety_root" ]] && ! path_under "$target" "$safety_root"; then
    echo "[ERROR] Refusing to remove path outside safety root: $target" >&2
    echo "[ERROR] Safety root: $safety_root" >&2
    exit 1
  fi

  if [[ -d "$target" && ! -L "$target" ]]; then
    rm -rf "$target"
  else
    rm -f "$target"
  fi
  log_info "Removed: $target"
}

remove_empty_dir() {
  local target="$1"
  [[ -d "$target" ]] || return 0
  rmdir "$target" >/dev/null 2>&1 && log_info "Removed empty directory: $target" || true
}

use_existing_nvm_node() {
  local node_bin
  node_bin="$(find "$NVM_DIR/versions/node" -mindepth 3 -maxdepth 3 -type f -path '*/bin/node' 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -n "$node_bin" && -x "$node_bin" ]]; then
    PATH="$(dirname "$node_bin"):$PATH"
    export PATH
    hash -r
    return 0
  fi

  return 1
}

load_nvm() {
  [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
}

current_npm_prefix() {
  if cmd_exists npm; then
    npm config get prefix 2>/dev/null || true
  fi
}

codex_present_in_prefix() {
  local prefix="$1"
  [[ -n "$prefix" ]] || return 1
  [[ -e "$prefix/bin/codex" || -L "$prefix/bin/codex" || -e "$prefix/lib/node_modules/@openai/codex" ]]
}

collect_codex_prefixes() {
  local prefix cmd_path

  use_existing_nvm_node || true
  prefix="$(current_npm_prefix)"
  if [[ -n "$prefix" ]]; then
    append_unique CODEX_PREFIXES "$(trim_trailing_slash "$prefix")"
  fi

  while IFS= read -r cmd_path; do
    [[ -n "$cmd_path" ]] || continue
    [[ "$cmd_path" == */bin/codex ]] || continue
    append_unique CODEX_PREFIXES "$(trim_trailing_slash "${cmd_path%/bin/codex}")"
  done < <(type -P -a codex 2>/dev/null || true)

  while IFS= read -r cmd_path; do
    [[ -n "$cmd_path" ]] || continue
    append_unique CODEX_PREFIXES "$(trim_trailing_slash "${cmd_path%/bin/codex}")"
  done < <(find "$NVM_DIR/versions/node" -mindepth 4 -maxdepth 4 -type f -path '*/bin/codex' 2>/dev/null || true)

  append_unique CODEX_PREFIXES "$HOME/.npm-global"

  for prefix in /usr/local /usr /opt/nodejs /opt/npm; do
    if codex_present_in_prefix "$prefix"; then
      append_unique SYSTEM_PREFIXES "$prefix"
    fi
  done

  for prefix in "${SYSTEM_PREFIXES[@]:-}"; do
    append_unique CODEX_PREFIXES "$prefix"
  done
}

matches_any_root() {
  local value="$1"
  local root
  shift || true
  for root in "$@"; do
    [[ -n "$root" ]] || continue
    case "$value" in
      *"$root"*) return 0 ;;
    esac
  done
  return 1
}

stop_codex_processes() {
  local roots=("$CODEX_HOME_DIR")
  local prefix
  if [[ -n "$CODEX_UNIX_ROOT" ]]; then
    roots+=("$CODEX_UNIX_ROOT")
  fi
  for prefix in "${CODEX_PREFIXES[@]:-}"; do
    if codex_present_in_prefix "$prefix"; then
      roots+=("$prefix/bin/codex" "$prefix/lib/node_modules/@openai/codex")
    fi
  done

  local pids=()
  local pid command
  while IFS= read -r line; do
    pid="${line%% *}"
    command="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" -eq "$$" || "$pid" -eq "${PPID:-0}" ]] && continue

    if [[ "$command" == *"@openai/codex"* ]] ||
       [[ "$command" == *"/bin/codex"* ]] ||
       matches_any_root "$command" "${roots[@]}"; then
      pids+=("$pid")
    fi
  done < <(ps -u "$(id -u)" -o pid= -o args= 2>/dev/null | awk '{$1=$1; print}' || true)

  if ((${#pids[@]} == 0)); then
    log_info "No running Codex/installer-owned Node/npm processes found."
    return 0
  fi

  log_warn "Stopping ${#pids[@]} Codex/Node/npm process(es) before uninstall."
  kill "${pids[@]}" >/dev/null 2>&1 || true
  sleep 1

  local still_running=()
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      still_running+=("$pid")
    fi
  done

  if ((${#still_running[@]} > 0)); then
    log_warn "Force stopping remaining process(es): ${still_running[*]}"
    kill -9 "${still_running[@]}" >/dev/null 2>&1 || true
  fi
}

uninstall_codex_at_prefix() {
  local prefix="$1"
  local npm_cmd=""
  [[ -n "$prefix" ]] || return 0
  codex_present_in_prefix "$prefix" || return 0

  if path_under "$prefix" /usr || path_under "$prefix" /opt; then
    if [[ "$SKIP_SYSTEM_CODEX" -eq 1 ]]; then
      log_warn "Skipping system-level Codex prefix: $prefix"
      return 0
    fi
  fi

  npm_cmd="$(command -v npm 2>/dev/null || true)"
  log_info "Uninstalling @openai/codex from npm prefix: $prefix"
  if [[ -n "$npm_cmd" ]]; then
    if path_under "$prefix" /usr || path_under "$prefix" /opt; then
      run_with_optional_sudo "$npm_cmd" uninstall -g --prefix "$prefix" @openai/codex >/dev/null 2>&1 || \
        log_warn "npm uninstall did not fully remove Codex from: $prefix"
    else
      "$npm_cmd" uninstall -g --prefix "$prefix" @openai/codex >/dev/null 2>&1 || \
        log_warn "npm uninstall did not fully remove Codex from: $prefix"
    fi
  else
    log_warn "npm not found; removing Codex residue directly for: $prefix"
  fi

  if path_under "$prefix" /usr || path_under "$prefix" /opt; then
    run_with_optional_sudo rm -f "$prefix/bin/codex" >/dev/null 2>&1 || true
    run_with_optional_sudo rm -rf "$prefix/lib/node_modules/@openai/codex" >/dev/null 2>&1 || true
    log_info "Removed system Codex residue under: $prefix"
  else
    remove_path_if_safe "$prefix/bin/codex" "$prefix"
    remove_path_if_safe "$prefix/lib/node_modules/@openai/codex" "$prefix"
    remove_empty_dir "$prefix/lib/node_modules/@openai"
    remove_empty_dir "$prefix/lib/node_modules"
  fi
}

remove_profile_block() {
  local file="$1"
  local start="$2"
  local end="$3"
  local tmp

  [[ -f "$file" ]] || return 0
  grep -qF "$start" "$file" 2>/dev/null || return 0

  tmp="$(mktemp)"
  awk -v start="$start" -v end="$end" '
    index($0, start) { skip=1; next }
    index($0, end) { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  log_info "Removed profile block from: $file"
}

shell_single_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

remove_env_from_file() {
  local file="$1"
  local key="$2"
  local expected_value="${3:-}"
  local expected_quoted=""
  local tmp

  [[ -f "$file" ]] || return 0
  if [[ -n "$expected_value" ]]; then
    expected_quoted="$(shell_single_quote "$expected_value")"
  fi

  grep -qE "^[[:space:]]*export[[:space:]]+${key}=" "$file" 2>/dev/null || return 0
  tmp="$(mktemp)"
  awk -v k="$key" -v expected="$expected_value" -v expected_quoted="$expected_quoted" '
    $0 ~ "^[[:space:]]*export[[:space:]]+" k "=" {
      rhs = $0
      sub("^[[:space:]]*export[[:space:]]+" k "=", "", rhs)
      sub("^[[:space:]]*", "", rhs)
      if (expected == "" || rhs == expected || rhs == expected_quoted || rhs == "\"" expected "\"") {
        next
      }
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  log_info "Cleaned $key from: $file"
}

cleanup_profiles_and_environment() {
  local file
  for file in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    remove_profile_block "$file" "# >>> codex no_proxy >>>" "# <<< codex no_proxy <<<"
    remove_profile_block "$file" "# >>> codex user paths >>>" "# <<< codex user paths <<<"
    remove_env_from_file "$file" "CODEX_HOME" "$CODEX_HOME_DIR"
    remove_env_from_file "$file" "CRS_OAI_KEY"
    remove_env_from_file "$file" "NPM_CONFIG_PREFIX" "$HOME/.npm-global"
    [[ -n "$CODEX_UNIX_ROOT" ]] && remove_env_from_file "$file" "NPM_CONFIG_PREFIX" "$CODEX_UNIX_ROOT/npm"
    remove_env_from_file "$file" "NPM_CONFIG_CACHE" "$LEGACY_NPM_CACHE"
    [[ -n "$ASCII_NPM_CACHE" ]] && remove_env_from_file "$file" "NPM_CONFIG_CACHE" "$ASCII_NPM_CACHE"
  done

  unset CODEX_HOME CRS_OAI_KEY NPM_CONFIG_PREFIX NPM_CONFIG_CACHE || true
  remove_path_if_safe "$HOME/.config/environment.d/99-codex-no-proxy.conf" "$HOME/.config/environment.d"
}

cleanup_codex_files() {
  if [[ "$KEEP_CODEX_HOME" -eq 1 ]]; then
    log_warn "Keeping Codex home because --keep-codex-home was specified."
  else
    if [[ -n "$CODEX_UNIX_ROOT" ]] && path_under "$CODEX_HOME_DIR" "$CODEX_UNIX_ROOT"; then
      remove_path_if_safe "$CODEX_HOME_DIR" "$CODEX_UNIX_ROOT"
    elif [[ "$CODEX_HOME_DIR" == "$HOME/.codex" ]]; then
      remove_path_if_safe "$CODEX_HOME_DIR/config.toml" "$CODEX_HOME_DIR"
      remove_path_if_safe "$CODEX_HOME_DIR/auth.json" "$CODEX_HOME_DIR"
      if [[ -d "$CODEX_HOME_DIR" ]]; then
        find "$CODEX_HOME_DIR" -maxdepth 1 -type f \( -name 'config.toml.bak.*' -o -name 'auth.json.bak.*' \) -print0 |
          while IFS= read -r -d '' backup_file; do
            remove_path_if_safe "$backup_file" "$CODEX_HOME_DIR"
          done
      fi
      remove_empty_dir "$CODEX_HOME_DIR"
    else
      log_warn "Skipping Codex home outside known installer roots: $CODEX_HOME_DIR"
    fi
  fi

  if [[ "$KEEP_NPM_CACHE" -eq 1 ]]; then
    log_warn "Keeping npm cache because --keep-npm-cache was specified."
  else
    if [[ -n "$ASCII_NPM_CACHE" ]]; then
      remove_path_if_safe "$ASCII_NPM_CACHE" "$CODEX_UNIX_ROOT"
    fi
  fi
}

uninstall_node_npm() {
  if [[ "$SKIP_NODE_UNINSTALL" -eq 1 ]]; then
    log_warn "Skipping Node.js/npm uninstall because --skip-node-uninstall was specified."
    return 0
  fi

  log_info "Uninstalling Node.js/npm after Codex cleanup..."

  if [[ "$USE_ASCII_SAFE_PATHS" -eq 1 ]]; then
    remove_path_if_safe "$NVM_DIR" "$CODEX_UNIX_ROOT"
    remove_empty_dir "$CODEX_UNIX_ROOT"
    return 0
  fi

  if [[ "$FORCE_REMOVE_SHARED_NODE" -eq 1 ]]; then
    if [[ -d "$NVM_DIR" ]]; then
      remove_path_if_safe "$NVM_DIR" "$HOME"
    fi
    return 0
  fi

  if [[ -d "$NVM_DIR" ]]; then
    log_warn "Node.js/npm appear to be managed by shared nvm at: $NVM_DIR"
    log_warn "Leaving shared nvm/Node.js/npm installed. Rerun with --force-remove-shared-node to remove it."
  elif cmd_exists node || cmd_exists npm; then
    log_warn "node/npm still exist on PATH, but they are outside this installer's owned paths."
    log_warn "Uninstall them with your OS/package manager if you want to remove shared Node.js."
  else
    log_ok "Node.js/npm are not found on PATH."
  fi
}

write_final_summary() {
  local name path
  printf '\n'
  for name in codex node npm; do
    path="$(command -v "$name" 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
      log_ok "$name is not found on PATH."
    else
      log_warn "$name still resolves on PATH: $path"
    fi
  done
  printf '\n'
  log_ok "Done. Open a new terminal before re-checking codex/node/npm."
}

main() {
  require_linux
  log_info "Starting Codex CLI + Node.js/npm uninstall for Linux..."
  log_info "NVM_DIR: $NVM_DIR"
  log_info "CODEX_HOME target: $CODEX_HOME_DIR"

  collect_codex_prefixes
  stop_codex_processes

  local prefix
  for prefix in "${CODEX_PREFIXES[@]:-}"; do
    uninstall_codex_at_prefix "$prefix"
  done

  cleanup_profiles_and_environment
  cleanup_codex_files
  uninstall_node_npm
  write_final_summary
}

main "$@"
