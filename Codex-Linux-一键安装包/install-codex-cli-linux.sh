#!/usr/bin/env bash
set -euo pipefail

FORCE_NODE_REINSTALL=0
FORCE_CODEX_REINSTALL=0
REMOVE_SYSTEM_CODEX=0
SKIP_CRS_CONFIG=0
SKIP_NO_PROXY=0
DRY_RUN=0
LOG_LEVEL="${CODEX_INSTALL_LOG_LEVEL:-normal}"
NPM_CONFIG_BACKUPS=()
NVM_SAFE_STATUS=0

contains_non_ascii() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 1
  LC_ALL=C printf '%s' "$value" | grep -q '[^ -~]'
}

detect_ascii_safe_paths() {
  contains_non_ascii "${HOME:-}" || contains_non_ascii "${TMPDIR:-}"
}

DEFAULT_ASCII_ROOT="/var/tmp/codex-$(id -u 2>/dev/null || printf 'user')"
USE_ASCII_SAFE_PATHS=0
if detect_ascii_safe_paths; then
  USE_ASCII_SAFE_PATHS=1
fi

if [[ "$USE_ASCII_SAFE_PATHS" -eq 1 ]]; then
  CODEX_UNIX_ROOT="${CODEX_UNIX_ASCII_ROOT:-$DEFAULT_ASCII_ROOT}"
  CODEX_UNIX_ROOT="${CODEX_UNIX_ROOT%/}"
  NVM_DIR="$CODEX_UNIX_ROOT/.nvm"
  CODEX_HOME_DIR="$CODEX_UNIX_ROOT/.codex"
else
  CODEX_UNIX_ROOT=""
  NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  CODEX_HOME_DIR="${HOME}/.codex"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-node-reinstall)
      FORCE_NODE_REINSTALL=1
      shift
      ;;
    --force-codex-reinstall)
      FORCE_CODEX_REINSTALL=1
      shift
      ;;
    --remove-system-codex)
      REMOVE_SYSTEM_CODEX=1
      shift
      ;;
    --skip-crs-config)
      SKIP_CRS_CONFIG=1
      shift
      ;;
    --skip-no-proxy)
      SKIP_NO_PROXY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --verbose)
      LOG_LEVEL="verbose"
      shift
      ;;
    --trace)
      LOG_LEVEL="trace"
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: install-codex-cli-linux.sh [options]

Options:
  --force-node-reinstall   Force reinstall Node.js/npm
  --force-codex-reinstall  Force reinstall @openai/codex
  --remove-system-codex    Explicitly remove system-level @openai/codex if detected
  --skip-crs-config        Skip interactive CRS config generation
  --skip-no-proxy          Skip NO_PROXY/no_proxy bypass setup
  --dry-run                Print preflight environment summary and exit without changes
  --verbose                Print detailed diagnostic logs
  --trace                  Print trace-level diagnostic logs
  -h, --help               Show this help
USAGE
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

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
  log_debug() {
    case "$LOG_LEVEL" in
      verbose|trace) printf '[DEBUG] %s\n' "$*" ;;
    esac
  }
  log_trace() {
    case "$LOG_LEVEL" in
      trace) printf '[TRACE] %s\n' "$*" ;;
    esac
  }
  codex_log_init() { CODEX_LOG_LEVEL="${1:-normal}"; }
fi
codex_log_init "$LOG_LEVEL"

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

env_state() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    printf 'set'
  else
    printf 'not set'
  fi
}

command_path_or_none() {
  command -v "$1" 2>/dev/null || printf 'not found'
}

command_version_or_none() {
  local name="$1"
  if ! cmd_exists "$name"; then
    printf 'not available'
    return 0
  fi

  case "$name" in
    node|npm|codex)
      "$name" --version 2>/dev/null | head -n 1 || printf 'not available'
      ;;
    *)
      "$name" --version 2>/dev/null | head -n 1 || printf 'not available'
      ;;
  esac
}

print_preflight_summary() {
  local npm_prefix npm_cache
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  npm_cache="$(npm config get cache 2>/dev/null || true)"

  log_info "Preflight environment summary:"
  log_info "  Platform: $(uname -s) $(uname -m)"
  log_info "  User: $(id -un 2>/dev/null || printf 'unknown') (uid=$(id -u 2>/dev/null || printf 'unknown'))"
  log_info "  HOME: ${HOME:-not set}"
  log_info "  TMPDIR: ${TMPDIR:-not set}"
  log_info "  ASCII-safe mode: $USE_ASCII_SAFE_PATHS"
  if [[ -n "$CODEX_UNIX_ROOT" ]]; then
    log_info "  ASCII Codex root: $CODEX_UNIX_ROOT"
  fi
  log_info "  NVM_DIR: $NVM_DIR"
  log_info "  CODEX_HOME target: $CODEX_HOME_DIR"
  log_info "  node: $(command_path_or_none node) ($(command_version_or_none node))"
  log_info "  npm: $(command_path_or_none npm) ($(command_version_or_none npm))"
  log_info "  codex: $(command_path_or_none codex) ($(command_version_or_none codex))"
  log_info "  npm prefix: ${npm_prefix:-not available}"
  log_debug "npm cache: ${npm_cache:-not available}"
  log_debug "Options: force_node=$FORCE_NODE_REINSTALL force_codex=$FORCE_CODEX_REINSTALL remove_system=$REMOVE_SYSTEM_CODEX skip_crs=$SKIP_CRS_CONFIG skip_no_proxy=$SKIP_NO_PROXY dry_run=$DRY_RUN log_level=$LOG_LEVEL"
  log_debug "Proxy env: HTTP_PROXY=$(env_state HTTP_PROXY), HTTPS_PROXY=$(env_state HTTPS_PROXY), ALL_PROXY=$(env_state ALL_PROXY), NO_PROXY=$(env_state NO_PROXY), no_proxy=$(env_state no_proxy)"
  log_trace "PATH: ${PATH:-not set}"
}

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[ERROR] This script is for Linux only." >&2
    exit 1
  fi
}

require_non_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "[ERROR] Do not run this script as root. Please run as the target normal user." >&2
    exit 1
  fi
}

initialize_ascii_safe_environment() {
  if [[ "$USE_ASCII_SAFE_PATHS" -eq 0 ]]; then
    return 0
  fi

  log_warn "Detected non-ASCII characters in HOME/TMPDIR. Using an ASCII-only Codex root to avoid Node/npm/Codex path issues."
  log_info "ASCII Codex root: $CODEX_UNIX_ROOT"
  mkdir -p "$CODEX_UNIX_ROOT" "$NVM_DIR" "$CODEX_HOME_DIR"
  chmod 700 "$CODEX_UNIX_ROOT" 2>/dev/null || true
  export CODEX_HOME="$CODEX_HOME_DIR"
}

need_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf ''
  elif cmd_exists sudo; then
    printf 'sudo '
  else
    echo "[ERROR] sudo is required for package installation." >&2
    exit 1
  fi
}

backup_if_exists() {
  local p="$1"
  if [[ -f "$p" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local bkp="${p}.bak.${ts}"
    cp -f "$p" "$bkp"
    log_info "Backed up existing file: $bkp" >&2
    printf '%s\n' "$bkp"
  fi
}

remove_crs_backups_after_success() {
  local bkp
  for bkp in "$@"; do
    if [[ -n "$bkp" && -e "$bkp" ]]; then
      if rm -f "$bkp"; then
        log_info "Removed successful-write backup: $bkp"
      else
        log_warn "Failed to remove successful-write backup: $bkp"
      fi
    fi
  done
}

remove_npm_config_backups_after_success() {
  local bkp
  for bkp in "${NPM_CONFIG_BACKUPS[@]:-}"; do
    if [[ -n "$bkp" && -e "$bkp" ]]; then
      if rm -f "$bkp"; then
        log_info "Removed successful npm config backup: $bkp"
      else
        log_warn "Failed to remove successful npm config backup: $bkp"
      fi
    fi
  done
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_single_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

sanitize_npm_config_for_nvm() {
  local changed=0
  local npmrc="$HOME/.npmrc"

  for name in PREFIX NPM_CONFIG_PREFIX npm_config_prefix NPM_CONFIG_GLOBALCONFIG npm_config_globalconfig; do
    if [[ -n "${!name:-}" ]]; then
      unset "$name"
      changed=1
    fi
  done

  if [[ -f "$npmrc" ]] && grep -qiE '^[[:space:]]*(prefix|globalconfig)[[:space:]]*=' "$npmrc"; then
    local backup_path
    backup_path="$(backup_if_exists "$npmrc")"
    [[ -n "$backup_path" ]] && NPM_CONFIG_BACKUPS+=("$backup_path")

    local tmp
    tmp="$(mktemp)"
    awk '
      {
        trimmed = $0
        sub(/^[[:space:]]+/, "", trimmed)
        if (tolower(trimmed) ~ /^(prefix|globalconfig)[[:space:]]*=/) {
          next
        }
        print
      }
    ' "$npmrc" > "$tmp"
    mv "$tmp" "$npmrc"
    log_warn "Removed nvm-incompatible prefix/globalconfig entries from ~/.npmrc."
    changed=1
  fi

  if [[ "$changed" -eq 1 ]]; then
    log_info "Sanitized npm prefix/globalconfig settings before using nvm."
  fi

  return 0
}

load_nvm() {
  [[ -s "$NVM_DIR/nvm.sh" ]] || return 1

  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1; set +e ;;
  esac

  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
  local source_status=$?

  if [[ "$had_errexit" -eq 1 ]]; then
    set -e
  fi

  if declare -F nvm >/dev/null 2>&1; then
    return 0
  fi

  return "$source_status"
}

nvm_safe() {
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1; set +e ;;
  esac

  nvm "$@"
  NVM_SAFE_STATUS=$?

  if [[ "$had_errexit" -eq 1 ]]; then
    set -e
  fi

  return 0
}

use_existing_nvm_node() {
  local node_bin
  node_bin="$(find "$NVM_DIR/versions/node" -mindepth 3 -maxdepth 3 -type f -path '*/bin/node' 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -n "$node_bin" && -x "$node_bin" ]]; then
    local node_bin_dir
    node_bin_dir="$(dirname "$node_bin")"
    export PATH="$node_bin_dir:$PATH"
    hash -r
    return 0
  fi

  return 1
}

activate_nvm_lts_with_nvm() {
  load_nvm || return 1

  nvm_safe use --silent default >/dev/null 2>&1
  if [[ "$NVM_SAFE_STATUS" -ne 0 ]]; then
    nvm_safe use --silent 'lts/*' >/dev/null 2>&1
  fi

  [[ "$NVM_SAFE_STATUS" -eq 0 ]]
}

ensure_nvm_default_alias() {
  load_nvm || return 0

  nvm_safe alias default 'lts/*' >/dev/null 2>&1
  if [[ "$NVM_SAFE_STATUS" -ne 0 ]]; then
    log_warn "Could not set nvm default alias to lts/*; current shell still uses the installed nvm Node."
  fi

  return 0
}

ensure_nvm_prefix_not_overridden() {
  local npm_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -n "$npm_prefix" ]] && ! path_under "$npm_prefix" "$NVM_DIR"; then
    npm config delete prefix >/dev/null 2>&1 || true
    npm config delete globalconfig >/dev/null 2>&1 || true
  fi

  return 0
}

test_preexisting_node_npm() {
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    if use_existing_nvm_node; then
      return 0
    fi
  fi

  cmd_exists node && cmd_exists npm
}

test_preexisting_codex() {
  if cmd_exists codex; then
    return 0
  fi

  if test_preexisting_node_npm; then
    local npm_cmd prefix npm_bin
    npm_cmd="$(command -v npm 2>/dev/null || true)"
    [[ -n "$npm_cmd" ]] || return 1

    prefix="$("$npm_cmd" config get prefix 2>/dev/null || true)"
    npm_bin="${prefix%/}/bin"
    if [[ -n "$prefix" ]] && [[ -x "$npm_bin/codex" ]]; then
      return 0
    fi
  fi

  return 1
}

test_preexisting_node_npm_codex() {
  test_preexisting_node_npm && test_preexisting_codex
}

clear_existing_crs_config() {
  local codex_dir="$1"
  local config_path auth_path
  config_path="$codex_dir/config.toml"
  auth_path="$codex_dir/auth.json"

  if [[ -f "$config_path" ]]; then
    backup_if_exists "$config_path"
  fi
  if [[ -f "$auth_path" ]]; then
    backup_if_exists "$auth_path"
  fi

  unset CRS_OAI_KEY || true
}

read_required() {
  local prompt="$1"
  local value=''
  while true; do
    read -r -p "$prompt" value
    # Trim whitespace and drop control chars to avoid breaking sed/exports.
    value="$(printf '%s' "$value" | tr -d '\000-\037\177')"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    log_warn "Input cannot be empty." >&2
  done
}

read_secret_required() {
  local prompt="$1"
  local value=''
  while true; do
    read -r -s -p "$prompt" value
    # Print the newline to the terminal/stderr so it won't be captured by
    # command substitution (e.g. crs_key="$(read_secret_required ...)").
    printf '\n' >&2
    # Drop control chars (arrow keys, etc) and trim whitespace.
    value="$(printf '%s' "$value" | tr -d '\000-\037\177')"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    log_warn "Input cannot be empty." >&2
  done
}

install_nvm_and_node() {
  local nvm_install_url="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh"
  export NVM_DIR
  sanitize_npm_config_for_nvm

  if ! cmd_exists curl; then
    echo "[ERROR] curl is required to install nvm." >&2
    exit 1
  fi

  log_info "Installing nvm and Node.js LTS (user-space, no sudo)..."

  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    log_info "Downloading nvm..."
    curl -o- "$nvm_install_url" | bash 2>&1 | while IFS= read -r line; do
      case "$line" in
        *"% Total"*|*"Dload"*) continue ;;
        *) printf '[NVM] %s\n' "$line" ;;
      esac
    done
  fi

  if ! load_nvm; then
    echo "[ERROR] nvm was installed but could not be loaded from: $NVM_DIR/nvm.sh" >&2
    exit 1
  fi

  log_info "Installing Node.js LTS via nvm..."
  nvm_safe install --lts
  if [[ "$NVM_SAFE_STATUS" -ne 0 ]]; then
    echo "[ERROR] nvm failed to install Node.js LTS." >&2
    exit 1
  fi
  if ! use_existing_nvm_node && ! activate_nvm_lts_with_nvm; then
    echo "[ERROR] nvm failed to activate Node.js LTS." >&2
    exit 1
  fi
  nvm_safe alias default 'lts/*'
  if [[ "$NVM_SAFE_STATUS" -ne 0 ]]; then
    echo "[ERROR] nvm failed to set the default Node.js LTS alias." >&2
    exit 1
  fi

  local node_bin_dir
  node_bin_dir="$(dirname "$(which node)")"
  export PATH="$node_bin_dir:$PATH"
  hash -r
  ensure_nvm_prefix_not_overridden

  log_ok "Node.js: $(node -v)"
  log_ok "npm: $(npm -v)"
  log_ok "nvm + Node.js installed under: $NVM_DIR"
}

ensure_node_npm() {
  export NVM_DIR
  sanitize_npm_config_for_nvm

  if [[ "$FORCE_NODE_REINSTALL" -eq 0 ]] && [[ -s "$NVM_DIR/nvm.sh" ]]; then
    if use_existing_nvm_node; then
      ensure_nvm_default_alias
      ensure_nvm_prefix_not_overridden
      log_info "Using Node.js/npm from nvm."
      log_ok "Node.js: $(node -v)"
      log_ok "npm: $(npm -v)"
      return 0
    fi
  fi

  install_nvm_and_node
}

ensure_nvm_node_active() {
  export NVM_DIR
  sanitize_npm_config_for_nvm

  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    install_nvm_and_node
  fi

  if use_existing_nvm_node; then
    ensure_nvm_default_alias
    ensure_nvm_prefix_not_overridden
    return 0
  fi

  install_nvm_and_node
  if ! use_existing_nvm_node && ! activate_nvm_lts_with_nvm; then
    echo "[ERROR] Node.js/npm still not available from nvm after install." >&2
    exit 1
  fi
  ensure_nvm_default_alias
  ensure_nvm_prefix_not_overridden
}

cleanup_legacy_path_block() {
  # Remove stale # >>> codex user paths >>> blocks
  # written by previous versions of this installer (pre-nvm era).
  local block_start="# >>> codex user paths >>>"
  local block_end="# <<< codex user paths <<<"

  for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc_file" ]] && grep -qF "$block_start" "$rc_file" 2>/dev/null; then
      log_info "Removing legacy path block from: $rc_file"
      local tmp
      tmp="$(mktemp)"
      awk -v start="$block_start" -v end="$block_end" '
        index($0, start) { inblock=1; next }
        index($0, end)   { inblock=0; next }
        !inblock { print }
      ' "$rc_file" > "$tmp"
      mv "$tmp" "$rc_file"
    fi
  done
}

trim_trailing_slash() {
  local p="$1"
  while [[ "$p" != "/" && "$p" == */ ]]; do
    p="${p%/}"
  done
  printf '%s\n' "$p"
}

path_under() {
  local path root
  path="$(trim_trailing_slash "$1")"
  root="$(trim_trailing_slash "$2")"

  [[ -n "$path" && -n "$root" ]] || return 1
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

is_user_npm_path() {
  local path="$1"
  path_under "$path" "$NVM_DIR" || path_under "$path" "$HOME"
}

is_system_prefix_candidate() {
  local prefix
  prefix="$(trim_trailing_slash "$1")"
  [[ -n "$prefix" ]] || return 1
  is_user_npm_path "$prefix" && return 1

  case "$prefix" in
    /usr|/usr/local|/opt/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

known_system_npm_prefixes() {
  printf '%s\n' "/usr/local" "/usr" "/opt/nodejs" "/opt/npm"

  local npm_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if is_system_prefix_candidate "$npm_prefix"; then
    printf '%s\n' "$(trim_trailing_slash "$npm_prefix")"
  fi
}

add_unique_system_prefix() {
  local prefix="$1"
  prefix="$(trim_trailing_slash "$prefix")"
  is_system_prefix_candidate "$prefix" || return 0

  local existing
  for existing in "${SYSTEM_CODEX_PREFIXES[@]:-}"; do
    if [[ "$existing" == "$prefix" ]]; then
      return 0
    fi
  done

  SYSTEM_CODEX_PREFIXES+=("$prefix")
}

find_system_codex_prefixes() {
  SYSTEM_CODEX_PREFIXES=()

  local prefix cmd_path
  while IFS= read -r prefix; do
    prefix="$(trim_trailing_slash "$prefix")"
    [[ -n "$prefix" ]] || continue

    if [[ -e "$prefix/bin/codex" || -L "$prefix/bin/codex" || -e "$prefix/lib/node_modules/@openai/codex" ]]; then
      add_unique_system_prefix "$prefix"
    fi
  done < <(known_system_npm_prefixes)

  while IFS= read -r cmd_path; do
    [[ -n "$cmd_path" ]] || continue
    is_user_npm_path "$cmd_path" && continue

    if [[ "$cmd_path" == */bin/codex ]]; then
      add_unique_system_prefix "${cmd_path%/bin/codex}"
    fi

    while IFS= read -r prefix; do
      prefix="$(trim_trailing_slash "$prefix")"
      [[ -n "$prefix" ]] || continue

      if path_under "$cmd_path" "$prefix/bin"; then
        add_unique_system_prefix "$prefix"
        break
      fi
    done < <(known_system_npm_prefixes)
  done < <(type -P -a codex 2>/dev/null || true)
}

run_with_optional_sudo() {
  if "$@"; then
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && cmd_exists sudo; then
    if sudo "$@"; then
      return 0
    fi
  fi

  return 1
}

remove_system_codex_path() {
  local target="$1"
  local prefix="$2"

  if ! path_under "$target" "$prefix"; then
    echo "[ERROR] Refusing to remove path outside system npm prefix: $target" >&2
    exit 1
  fi

  [[ -e "$target" || -L "$target" ]] || return 0

  if [[ -d "$target" && ! -L "$target" ]]; then
    if run_with_optional_sudo rm -rf "$target"; then
      log_info "Removed system Codex residue: $target"
      return 0
    fi
  else
    if run_with_optional_sudo rm -f "$target"; then
      log_info "Removed system Codex residue: $target"
      return 0
    fi
  fi

  log_warn "Failed to remove system Codex residue: $target"
  return 1
}

uninstall_system_codex_at_prefix() {
  local prefix="$1"
  local npm_cmd
  npm_cmd="$(command -v npm 2>/dev/null || true)"

  [[ -n "$npm_cmd" ]] || {
    log_warn "npm was not found; cannot uninstall system-level Codex with npm."
    return 1
  }

  log_info "Uninstalling system-level Codex CLI from npm prefix: $prefix"
  if "$npm_cmd" uninstall -g --prefix "$prefix" @openai/codex >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && cmd_exists sudo; then
    sudo "$npm_cmd" uninstall -g --prefix "$prefix" @openai/codex >/dev/null 2>&1 || return 1
    return 0
  fi

  return 1
}

ensure_no_system_codex() {
  find_system_codex_prefixes
  if ((${#SYSTEM_CODEX_PREFIXES[@]} == 0)); then
    log_info "No system-level Codex CLI detected."
    return 0
  fi

  local prefix
  for prefix in "${SYSTEM_CODEX_PREFIXES[@]}"; do
    log_warn "Detected system-level Codex CLI: $prefix"
  done

  for prefix in "${SYSTEM_CODEX_PREFIXES[@]}"; do
    uninstall_system_codex_at_prefix "$prefix" || log_warn "npm uninstall did not fully remove Codex from: $prefix"
    remove_system_codex_path "$prefix/bin/codex" "$prefix" || true
    remove_system_codex_path "$prefix/lib/node_modules/@openai/codex" "$prefix" || true
  done

  find_system_codex_prefixes
  if ((${#SYSTEM_CODEX_PREFIXES[@]} > 0)); then
    echo "[ERROR] System-level Codex CLI is still present:" >&2
    for prefix in "${SYSTEM_CODEX_PREFIXES[@]}"; do
      echo "  - $prefix" >&2
    done
    echo "[ERROR] Remove it with sudo/admin rights and rerun this installer." >&2
    exit 1
  fi

  log_ok "System-level Codex CLI removed."
}

warn_system_codex() {
  find_system_codex_prefixes
  if ((${#SYSTEM_CODEX_PREFIXES[@]} == 0)); then
    log_info "No system-level Codex CLI detected."
    return 0
  fi

  local prefix
  for prefix in "${SYSTEM_CODEX_PREFIXES[@]}"; do
    log_warn "Detected system-level Codex CLI: $prefix"
  done
  log_warn "Leaving system-level Codex untouched. This installer installs Codex under the nvm Node.js prefix."
  log_warn "If you explicitly want to remove system-level Codex, rerun with --remove-system-codex."
}

remove_legacy_user_codex_path() {
  local target="$1"
  local prefix="$2"

  if ! path_under "$target" "$prefix"; then
    log_warn "Refusing to remove legacy Codex path outside npm prefix: $target"
    return 1
  fi

  [[ -e "$target" || -L "$target" ]] || return 0

  if [[ -d "$target" && ! -L "$target" ]]; then
    rm -rf "$target"
  else
    rm -f "$target"
  fi
}

cleanup_legacy_user_codex() {
  local nvm_prefix="$1"
  local cmd_path prefix package_dir removed=0
  local legacy_prefixes=()

  while IFS= read -r cmd_path; do
    [[ -n "$cmd_path" ]] || continue
    path_under "$cmd_path" "$nvm_prefix" && continue
    path_under "$cmd_path" "$HOME" || continue
    [[ "$cmd_path" == */bin/codex ]] || continue

    prefix="${cmd_path%/bin/codex}"
    [[ "$prefix" != "$nvm_prefix" ]] || continue
    package_dir="$prefix/lib/node_modules/@openai/codex"
    [[ -e "$package_dir" || -L "$package_dir" ]] || continue

    log_info "Removing legacy user-level Codex outside nvm prefix: $prefix"
    if npm uninstall -g --prefix "$prefix" @openai/codex >/dev/null 2>&1; then
      removed=1
    else
      remove_legacy_user_codex_path "$cmd_path" "$prefix" || true
      remove_legacy_user_codex_path "$package_dir" "$prefix" || true
      removed=1
    fi
  done < <(type -P -a codex 2>/dev/null || true)

  legacy_prefixes+=("$HOME/.npm-global")
  for prefix in "${legacy_prefixes[@]}"; do
    [[ -n "$prefix" ]] || continue
    [[ "$prefix" != "$nvm_prefix" ]] || continue
    path_under "$prefix" "$HOME" || continue
    package_dir="$prefix/lib/node_modules/@openai/codex"
    cmd_path="$prefix/bin/codex"
    [[ -e "$package_dir" || -L "$package_dir" || -e "$cmd_path" || -L "$cmd_path" ]] || continue

    log_info "Removing legacy user-level Codex outside nvm prefix: $prefix"
    if npm uninstall -g --prefix "$prefix" @openai/codex >/dev/null 2>&1; then
      removed=1
    else
      remove_legacy_user_codex_path "$cmd_path" "$prefix" || true
      remove_legacy_user_codex_path "$package_dir" "$prefix" || true
      removed=1
    fi
  done

  if [[ "$removed" -eq 1 ]]; then
    hash -r
  fi
}

ensure_codex() {
  local npm_prefix npm_bin
  ensure_nvm_node_active

  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -z "$npm_prefix" ]]; then
    echo "[ERROR] Failed to resolve npm global prefix from nvm Node.js." >&2
    exit 1
  fi
  if ! path_under "$npm_prefix" "$NVM_DIR"; then
    echo "[ERROR] Refusing to install Codex outside nvm prefix: $npm_prefix" >&2
    echo "[ERROR] Expected npm prefix under: $NVM_DIR" >&2
    exit 1
  fi
  npm_bin="${npm_prefix%/}/bin"

  if [[ "$FORCE_CODEX_REINSTALL" -eq 1 ]]; then
    log_info "Force reinstall enabled: removing existing Codex CLI from nvm Node.js prefix..."
    npm uninstall -g @openai/codex >/dev/null 2>&1 || true
  else
    if [[ -x "$npm_bin/codex" ]]; then
      if "$npm_bin/codex" --version >/dev/null 2>&1; then
        log_info "Codex CLI already installed in nvm Node.js prefix: $("$npm_bin/codex" --version)"
        cleanup_legacy_user_codex "$npm_prefix"
        return 0
      fi
      log_warn "codex exists in nvm Node.js prefix but failed to run; will reinstall."
    fi
  fi

  log_info "Installing Codex CLI to nvm Node.js prefix ($npm_prefix)..."
  if npm install -g @openai/codex >/dev/null 2>&1; then
    :
  else
    echo "[ERROR] npm install -g @openai/codex failed. Check nvm prefix and permissions: $npm_prefix" >&2
    exit 1
  fi

  npm_bin="${npm_prefix%/}/bin"
  if [[ -x "$npm_bin/codex" ]]; then
    log_ok "Codex CLI: $($npm_bin/codex --version)"
    cleanup_legacy_user_codex "$npm_prefix"
  else
    echo "[ERROR] codex command not found under npm prefix after installation." >&2
    exit 1
  fi

  if cmd_exists codex; then
    local resolved
    resolved="$(command -v codex)"
    if [[ "$resolved" != "$npm_bin/codex" ]]; then
      log_warn "PATH resolves codex to: $resolved"
      log_warn "Expected nvm Node.js prefix: $npm_bin/codex"
      log_warn "Open a new shell or ensure the active Node.js bin directory is first in PATH."
    fi
  else
    log_warn "codex is not in current PATH. Open a new shell or load nvm before running codex."
  fi
}

upsert_env_in_file() {
  local file="$1"
  local key="$2"
  local value="$3"
  local quoted
  quoted="$(shell_single_quote "$value")"

  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi

  local tmp found
  tmp="$(mktemp)"
  found=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+${key}= ]]; then
      if [[ "$found" -eq 0 ]]; then
        printf 'export %s=%s\n' "$key" "$quoted" >> "$tmp"
        found=1
      fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if [[ "$found" -eq 0 ]]; then
    printf '\nexport %s=%s\n' "$key" "$quoted" >> "$tmp"
  fi

  mv "$tmp" "$file"
}

remove_env_from_file() {
  local file="$1"
  local key="$2"
  local expected_value="${3:-}"
  local expected_quoted=""

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  if [[ -n "$expected_value" ]]; then
    expected_quoted="$(shell_single_quote "$expected_value")"
  fi

  if grep -qE "^[[:space:]]*export[[:space:]]+${key}=" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v expected="$expected_value" -v expected_quoted="$expected_quoted" '
      $0 ~ "^[[:space:]]*export[[:space:]]+" k "=" {
        rhs = $0
        sub("^[[:space:]]*export[[:space:]]+" k "=", "", rhs)
        sub("^[[:space:]]*", "", rhs)
        if (expected == "" ||
            rhs == expected ||
            rhs == expected_quoted ||
            rhs == "\"" expected "\"") {
          next
        }
      }
      { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
}

probe_crs_responses_route() {
  local base_url="$1"
  local probe_url status
  probe_url="${base_url%/}/responses"

  if ! cmd_exists curl; then
    printf '000'
    return 0
  fi

  if ! status="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      --max-time 8 \
      -X POST \
      -H 'Content-Type: application/json' \
      --data '{}' \
      "$probe_url" 2>/dev/null
  )"; then
    status='000'
  fi
  printf '%s' "$status"
}

resolve_crs_base_url() {
  local input="$1"
  local trimmed status candidate candidate_status
  trimmed="$(trim_trailing_slash "$input")"

  if [[ -z "$trimmed" ]]; then
    printf '%s' "$input"
    return 0
  fi

  if ! cmd_exists curl; then
    log_warn "curl not found; skipping CRS /responses route probe." >&2
    printf '%s' "$trimmed"
    return 0
  fi

  status="$(probe_crs_responses_route "$trimmed")"
  if [[ "$status" != "404" && "$status" != "000" ]]; then
    log_info "CRS Responses route probe: $status ${trimmed%/}/responses" >&2
    printf '%s' "$trimmed"
    return 0
  fi

  if [[ "$status" == "404" ]]; then
    log_warn "CRS Responses route probe returned 404: ${trimmed%/}/responses" >&2
  else
    log_warn "Could not verify CRS Responses route: ${trimmed%/}/responses" >&2
  fi

  candidate=''
  case "$trimmed" in
    http://*/api|https://*/api)
      candidate="${trimmed%/api}/openai"
      ;;
  esac

  if [[ -n "$candidate" ]]; then
    candidate_status="$(probe_crs_responses_route "$candidate")"
    if [[ "$candidate_status" != "404" && "$candidate_status" != "000" ]]; then
      log_warn "The entered CRS base_url does not expose /responses. Using detected OpenAI-compatible base_url instead: $candidate" >&2
      log_info "CRS Responses route probe: $candidate_status ${candidate%/}/responses" >&2
      printf '%s' "$candidate"
      return 0
    fi
  fi

  log_warn "Could not verify that the CRS base_url exposes the Responses API. Codex may fail if /responses is not available." >&2
  printf '%s' "$trimmed"
}

configure_crs() {
  local clean_existing="${1:-0}"
  local codex_dir config_path auth_path base_url_input base_url crs_key
  codex_dir="$CODEX_HOME_DIR"
  config_path="$codex_dir/config.toml"
  auth_path="$codex_dir/auth.json"

  log_info "Starting CRS configuration..."
  base_url_input="$(read_required 'Enter CRS base_url (must expose /responses, example: http://x.x.x.x:10086/openai): ')"
  crs_key="$(read_secret_required 'Enter CRS_OAI_KEY (hidden input): ')"
  base_url="$(resolve_crs_base_url "$base_url_input")"
  local base_url_toml
  base_url_toml="$(toml_escape "$base_url")"

  mkdir -p "$codex_dir"
  if [[ "$clean_existing" -eq 1 ]]; then
    log_info "Detected existing node/npm/codex; creating temporary CRS backups before regenerating..."
  fi
  local backup_paths=()
  local backup_path
  backup_path="$(backup_if_exists "$config_path")"
  [[ -n "$backup_path" ]] && backup_paths+=("$backup_path")
  backup_path="$(backup_if_exists "$auth_path")"
  [[ -n "$backup_path" ]] && backup_paths+=("$backup_path")

  cat > "$config_path" <<CFG
model_provider = "crs"
model = "gpt-5.2"
model_reasoning_effort = "xhigh"
disable_response_storage = true
preferred_auth_method = "apikey"

sandbox_mode = "workspace-write"
approval_policy = "on-request"
# High risk: only use approval_policy = "never" if you fully understand the risk.

[model_providers.crs]
name = "crs"
base_url = "$base_url_toml"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"

[features]
# 实际已去除
tui_app_server = false
# 关闭MCP和 工具 / 列表 / 发现/建议
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"
CFG

  cat > "$auth_path" <<'AUTH'
{
  "OPENAI_API_KEY": null
}
AUTH

  export CRS_OAI_KEY="$crs_key"
  export CODEX_HOME="$codex_dir"

  # Persist in common shells.
  upsert_env_in_file "$HOME/.bashrc" "CRS_OAI_KEY" "$crs_key"
  upsert_env_in_file "$HOME/.zshrc" "CRS_OAI_KEY" "$crs_key"

  # Persist CODEX_HOME in shell rc only when non-standard (not ~/.codex).
  if [[ "$codex_dir" != "$HOME/.codex" ]]; then
    upsert_env_in_file "$HOME/.bashrc" "CODEX_HOME" "$codex_dir"
    upsert_env_in_file "$HOME/.zshrc" "CODEX_HOME" "$codex_dir"
  fi

  log_ok "Wrote: $config_path"
  log_ok "Wrote: $auth_path"
  if [[ "$codex_dir" != "$HOME/.codex" ]]; then
    log_ok "Persisted CRS_OAI_KEY and CODEX_HOME in ~/.bashrc and ~/.zshrc"
  else
    log_ok "Persisted CRS_OAI_KEY in ~/.bashrc and ~/.zshrc"
  fi

  remove_crs_backups_after_success "${backup_paths[@]}"
}

configure_no_proxy() {
  local script_dir no_proxy_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  no_proxy_script="$script_dir/setup_no_proxy_linux.sh"

  if [[ ! -f "$no_proxy_script" ]]; then
    log_warn "NO_PROXY setup script not found next to installer: $no_proxy_script"
    log_warn "Skipping NO_PROXY/no_proxy configuration."
    return 0
  fi

  log_info "Configuring NO_PROXY/no_proxy bypass..."
  bash "$no_proxy_script"
}

main() {
  require_linux
  log_info "Starting one-click install for Linux Codex CLI package..."
  print_preflight_summary
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_ok "Dry run complete. No files, environment variables, packages, or PATH entries were changed."
    return 0
  fi
  require_non_root
  initialize_ascii_safe_environment
  sanitize_npm_config_for_nvm

  local clean_existing_config=0
  if test_preexisting_node_npm_codex; then
    clean_existing_config=1
  fi

  ensure_node_npm
  if [[ "$REMOVE_SYSTEM_CODEX" -eq 1 ]]; then
    log_info "--remove-system-codex requested; checking system-level Codex CLI."
    ensure_no_system_codex
  else
    warn_system_codex
  fi
  ensure_codex

  # Clean up legacy path blocks and env vars from pre-nvm installer versions.
  cleanup_legacy_path_block
  remove_env_from_file "$HOME/.bashrc" "NPM_CONFIG_PREFIX"
  remove_env_from_file "$HOME/.bashrc" "NPM_CONFIG_CACHE"
  remove_env_from_file "$HOME/.zshrc" "NPM_CONFIG_PREFIX"
  remove_env_from_file "$HOME/.zshrc" "NPM_CONFIG_CACHE"

  if [[ "$SKIP_CRS_CONFIG" -eq 0 ]]; then
    configure_crs "$clean_existing_config"
  fi

  if [[ "$SKIP_NO_PROXY" -eq 0 ]]; then
    configure_no_proxy
  fi

  remove_npm_config_backups_after_success

  printf '\n'
  log_ok "Done."
  log_info "If environment variables are not visible in current shell, run: source ~/.bashrc"
}

main "$@"
