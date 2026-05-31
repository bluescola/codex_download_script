#!/usr/bin/env bash
set -euo pipefail

FORCE_NODE_REINSTALL=0
FORCE_CODEX_REINSTALL=0
REMOVE_SYSTEM_CODEX=0
SKIP_CRS_CONFIG=0
SKIP_NO_PROXY=0
DRY_RUN=0
LOG_LEVEL="${CODEX_INSTALL_LOG_LEVEL:-normal}"
ACTIVE_NODE_PREFIX=""
ACTIVE_NPM_CMD=""
NPM_CONFIG_BACKUPS=("")

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
Usage: install-codex-cli-mac.sh [options]

Options:
  --force-node-reinstall   Force reinstall Node.js/npm (user-only install)
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

contains_non_ascii() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 1
  LC_ALL=C printf '%s' "$value" | grep -q '[^ -~]'
}

detect_ascii_safe_paths() {
  contains_non_ascii "${HOME:-}" || contains_non_ascii "${TMPDIR:-}"
}

require_non_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "[ERROR] Do not run this script as root. Please run as a normal user." >&2
    exit 1
  fi
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[ERROR] This script is for macOS only." >&2
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
  for bkp in "${NPM_CONFIG_BACKUPS[@]}"; do
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

sanitize_legacy_npm_config() {
  local changed=0
  local npmrc="$HOME/.npmrc"

  for name in PREFIX NPM_CONFIG_PREFIX npm_config_prefix NPM_CONFIG_GLOBALCONFIG npm_config_globalconfig NPM_CONFIG_CACHE npm_config_cache; do
    if [[ -n "${!name:-}" ]]; then
      unset "$name"
      changed=1
    fi
  done

  if [[ -f "$npmrc" ]] && grep -qiE '^[[:space:]]*(prefix|globalconfig|cache)[[:space:]]*=' "$npmrc"; then
    local backup_path tmp
    tmp="$(mktemp)"
    awk \
      -v legacy_prefix_global="$LEGACY_NPM_PREFIX_GLOBAL" \
      -v legacy_prefix_local="$LEGACY_NPM_PREFIX_LOCAL" \
      -v legacy_ascii_prefix="$LEGACY_ASCII_NPM_PREFIX" \
      -v legacy_cache="$LEGACY_NPM_CACHE" \
      -v legacy_ascii_cache="$LEGACY_ASCII_NPM_CACHE" '
      {
        trimmed = $0
        sub(/^[[:space:]]+/, "", trimmed)
        if (tolower(trimmed) ~ /^(prefix|globalconfig|cache)[[:space:]]*=/) {
          key = tolower(trimmed)
          sub(/[[:space:]]*=.*/, "", key)

          value = trimmed
          sub(/^[^=]*=/, "", value)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          gsub(/^"|"$/, "", value)
          gsub(/^'\''|'\''$/, "", value)

          if ((key == "prefix" || key == "globalconfig") &&
              (value == legacy_prefix_global ||
               value == legacy_prefix_local ||
               (legacy_ascii_prefix != "" && value == legacy_ascii_prefix) ||
               value == legacy_prefix_global "/etc/npmrc" ||
               value == legacy_prefix_local "/etc/npmrc" ||
               (legacy_ascii_prefix != "" && value == legacy_ascii_prefix "/etc/npmrc"))) {
            next
          }
          if (key == "cache" &&
              (value == legacy_cache ||
               (legacy_ascii_cache != "" && value == legacy_ascii_cache))) {
            next
          }
        }
        print
      }
    ' "$npmrc" > "$tmp"
    if cmp -s "$npmrc" "$tmp"; then
      rm -f "$tmp"
    else
      backup_path="$(backup_if_exists "$npmrc")"
      [[ -n "$backup_path" ]] && NPM_CONFIG_BACKUPS+=("$backup_path")
      mv "$tmp" "$npmrc"
      log_warn "Removed legacy installer npm prefix/globalconfig/cache entries from ~/.npmrc."
      changed=1
    fi
  fi

  if [[ "$changed" -eq 1 ]]; then
    log_info "Sanitized legacy npm environment/config settings before using Homebrew node@24."
  fi

  return 0
}

test_preexisting_node_npm() {
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
    # Trim whitespace and drop control chars to avoid breaking exports/config.
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
    # Print newline to terminal/stderr so it won't be captured by $(...)
    # (e.g. crs_key="$(read_secret_required ...)").
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

DEFAULT_ASCII_ROOT="/Users/Shared/Codex-$(id -u 2>/dev/null || printf 'user')"
USE_ASCII_SAFE_PATHS=0
if detect_ascii_safe_paths; then
  USE_ASCII_SAFE_PATHS=1
fi

if [[ "$USE_ASCII_SAFE_PATHS" -eq 1 ]]; then
  CODEX_UNIX_ROOT="${CODEX_UNIX_ASCII_ROOT:-$DEFAULT_ASCII_ROOT}"
  CODEX_UNIX_ROOT="${CODEX_UNIX_ROOT%/}"
  CODEX_HOME_DIR="$CODEX_UNIX_ROOT/.codex"
else
  CODEX_UNIX_ROOT=""
  CODEX_HOME_DIR="$HOME/.codex"
fi
LEGACY_NPM_PREFIX_GLOBAL="$HOME/.npm-global"
LEGACY_NPM_PREFIX_LOCAL="$HOME/.local"
LEGACY_ASCII_NPM_PREFIX="${CODEX_UNIX_ROOT:+$CODEX_UNIX_ROOT/npm}"
LEGACY_NPM_CACHE="$HOME/.npm-cache"
LEGACY_ASCII_NPM_CACHE="${CODEX_UNIX_ROOT:+$CODEX_UNIX_ROOT/npm-cache}"

is_default_codex_home() {
  [[ "$CODEX_HOME_DIR" == "$HOME/.codex" ]]
}

initialize_ascii_safe_environment() {
  if [[ "$USE_ASCII_SAFE_PATHS" -eq 0 ]]; then
    unset NPM_CONFIG_PREFIX NPM_CONFIG_CACHE CODEX_HOME
    return 0
  fi

  log_warn "Detected non-ASCII characters in HOME/TMPDIR. Using an ASCII-only Codex root to avoid Node/npm/Codex path issues."
  log_info "ASCII Codex root: $CODEX_UNIX_ROOT"
  mkdir -p "$CODEX_UNIX_ROOT" "$CODEX_HOME_DIR"
  chmod 700 "$CODEX_UNIX_ROOT" 2>/dev/null || true
  export CODEX_HOME="$CODEX_HOME_DIR"
}

print_preflight_summary() {
  local npm_prefix npm_cache brew_path node24_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  npm_cache="$(npm config get cache 2>/dev/null || true)"
  brew_path="$(command -v brew 2>/dev/null || true)"
  if [[ -n "$brew_path" ]]; then
    node24_prefix="$(brew --prefix node@24 2>/dev/null || true)"
  else
    node24_prefix=""
  fi

  log_info "Preflight environment summary:"
  log_info "  Platform: $(uname -s) $(uname -m)"
  log_info "  User: $(id -un 2>/dev/null || printf 'unknown') (uid=$(id -u 2>/dev/null || printf 'unknown'))"
  log_info "  HOME: ${HOME:-not set}"
  log_info "  TMPDIR: ${TMPDIR:-not set}"
  log_info "  ASCII-safe mode: $USE_ASCII_SAFE_PATHS"
  if [[ -n "$CODEX_UNIX_ROOT" ]]; then
    log_info "  ASCII Codex root: $CODEX_UNIX_ROOT"
  fi
  log_info "  CODEX_HOME target: $CODEX_HOME_DIR"
  log_info "  Homebrew: ${brew_path:-not found}"
  log_info "  Homebrew node@24 prefix: ${node24_prefix:-not installed or not available}"
  log_info "  node: $(command_path_or_none node) ($(command_version_or_none node))"
  log_info "  npm: $(command_path_or_none npm) ($(command_version_or_none npm))"
  log_info "  codex: $(command_path_or_none codex) ($(command_version_or_none codex))"
  log_info "  npm prefix: ${npm_prefix:-not available}"
  log_debug "npm cache: ${npm_cache:-not available}"
  log_debug "Options: force_node=$FORCE_NODE_REINSTALL force_codex=$FORCE_CODEX_REINSTALL remove_system=$REMOVE_SYSTEM_CODEX skip_crs=$SKIP_CRS_CONFIG skip_no_proxy=$SKIP_NO_PROXY dry_run=$DRY_RUN log_level=$LOG_LEVEL"
  log_debug "Proxy env: HTTP_PROXY=$(env_state HTTP_PROXY), HTTPS_PROXY=$(env_state HTTPS_PROXY), ALL_PROXY=$(env_state ALL_PROXY), NO_PROXY=$(env_state NO_PROXY), no_proxy=$(env_state no_proxy)"
  log_trace "PATH: ${PATH:-not set}"
}

cleanup_legacy_path_block() {
  # Remove stale # >>> codex user paths >>> blocks
  # written by previous versions of this installer (pre-Homebrew era).
  local block_start="# >>> codex user paths >>>"
  local block_end="# <<< codex user paths <<<"

  for rc_file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
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

ensure_homebrew_node_path_profile() {
  local node_bin="${ACTIVE_NODE_PREFIX%/}/bin"
  local block_start="# >>> codex homebrew node path >>>"
  local block_end="# <<< codex homebrew node path <<<"
  local quoted_node_bin
  quoted_node_bin="$(shell_single_quote "$node_bin")"

  [[ -d "$node_bin" ]] || return 0

  for rc_file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    local tmp
    touch "$rc_file"
    tmp="$(mktemp)"

    awk -v start="$block_start" -v end="$block_end" '
      index($0, start) { inblock=1; next }
      index($0, end)   { inblock=0; next }
      !inblock { print }
    ' "$rc_file" > "$tmp"

    cat >> "$tmp" <<EOF

$block_start
_codex_node_bin=$quoted_node_bin
PATH=":\$PATH:"
PATH="\${PATH//:\$_codex_node_bin:/:}"
PATH="\${PATH#:}"
PATH="\${PATH%:}"
if [[ -n "\$PATH" ]]; then
  export PATH="\$_codex_node_bin:\$PATH"
else
  export PATH="\$_codex_node_bin"
fi
unset _codex_node_bin
$block_end
EOF

    mv "$tmp" "$rc_file"
  done

  log_ok "Persisted Homebrew node@24 PATH in zsh/bash profile files: $node_bin"
}

install_brew_and_node() {
  local node_formula="node@24"
  local node_prefix
  log_info "Installing Node.js 24 LTS via Homebrew (user-space, no sudo)..."

  if ! cmd_exists brew; then
    log_info "Installing Homebrew..."
    if ! cmd_exists curl; then
      echo "[ERROR] curl is required to install Homebrew." >&2
      exit 1
    fi
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null

    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! cmd_exists brew; then
      echo "[ERROR] Homebrew installation failed." >&2
      exit 1
    fi
    log_ok "Homebrew installed."
  else
    log_info "Homebrew already installed."
  fi

  log_info "Installing Node.js 24 LTS via Homebrew..."
  if ! brew install "$node_formula"; then
    node_prefix="$(brew --prefix "$node_formula" 2>/dev/null || true)"
    if [[ -n "$node_prefix" && -x "$node_prefix/bin/node" && -x "$node_prefix/bin/npm" ]]; then
      log_warn "Homebrew reported a link conflict for node@24; continuing with keg binaries under: $node_prefix"
    else
      echo "[ERROR] Homebrew failed to install node@24." >&2
      exit 1
    fi
  fi

  node_prefix="$(brew --prefix "$node_formula")"
  if [[ ! -x "$node_prefix/bin/node" || ! -x "$node_prefix/bin/npm" ]]; then
    echo "[ERROR] Homebrew node@24 installed but node/npm were not found under: $node_prefix/bin" >&2
    exit 1
  fi

  ACTIVE_NODE_PREFIX="$node_prefix"
  ACTIVE_NPM_CMD="$node_prefix/bin/npm"
  export PATH="$node_prefix/bin:$PATH"
  hash -r

  log_ok "Node.js: $("$ACTIVE_NODE_PREFIX/bin/node" -v)"
  log_ok "npm: $("$ACTIVE_NPM_CMD" -v)"
}

ensure_homebrew_node_active() {
  local node_formula="node@24"
  if ! cmd_exists brew; then
    install_brew_and_node
    return 0
  fi

  local node_prefix
  if ! node_prefix="$(brew --prefix "$node_formula" 2>/dev/null)"; then
    install_brew_and_node
    return 0
  fi

  if [[ ! -x "$node_prefix/bin/node" || ! -x "$node_prefix/bin/npm" ]]; then
    if ! brew install "$node_formula"; then
      if [[ -x "$node_prefix/bin/node" && -x "$node_prefix/bin/npm" ]]; then
        log_warn "Homebrew reported a link conflict for node@24; continuing with keg binaries under: $node_prefix"
      else
        echo "[ERROR] Homebrew failed to install node@24." >&2
        exit 1
      fi
    fi
  fi

  if [[ ! -x "$node_prefix/bin/node" || ! -x "$node_prefix/bin/npm" ]]; then
    echo "[ERROR] Homebrew node@24 is installed but node/npm were not found under: $node_prefix/bin" >&2
    exit 1
  fi

  ACTIVE_NODE_PREFIX="$node_prefix"
  ACTIVE_NPM_CMD="$node_prefix/bin/npm"
  export PATH="$node_prefix/bin:$PATH"
  hash -r
}

is_supported_node_lts() {
  local major
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
  case "$major" in
    22|24) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_node_npm() {
  if [[ "$FORCE_NODE_REINSTALL" -eq 1 ]]; then
    install_brew_and_node
  else
    ensure_homebrew_node_active
  fi

  if [[ -z "$ACTIVE_NODE_PREFIX" || -z "$ACTIVE_NPM_CMD" || ! -x "$ACTIVE_NODE_PREFIX/bin/node" || ! -x "$ACTIVE_NPM_CMD" ]]; then
    echo "[ERROR] Node.js/npm are not available after activating Homebrew node@24." >&2
    exit 1
  fi

  if ! "$ACTIVE_NODE_PREFIX/bin/node" -p 'process.versions.node.split(".")[0]' 2>/dev/null | grep -qx '24'; then
    echo "[ERROR] Active Homebrew node@24 is not Node.js 24: $("$ACTIVE_NODE_PREFIX/bin/node" -v)" >&2
    exit 1
  fi

  log_info "Using Homebrew node@24 Node.js/npm."
  log_ok "Node.js: $("$ACTIVE_NODE_PREFIX/bin/node" -v)"
  log_ok "npm: $("$ACTIVE_NPM_CMD" -v)"
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
  path_under "$path" "$HOME"
}

is_system_prefix_candidate() {
  local prefix
  prefix="$(trim_trailing_slash "$1")"
  [[ -n "$prefix" ]] || return 1
  is_user_npm_path "$prefix" && return 1

  case "$prefix" in
    /opt/homebrew|/usr/local|/opt/local|/usr)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

known_system_npm_prefixes() {
  printf '%s\n' "/opt/homebrew" "/usr/local" "/opt/local" "/usr"

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
  for existing in "${SYSTEM_CODEX_PREFIXES[@]}"; do
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
  log_warn "Leaving system-level Codex untouched. This installer installs Codex under the Homebrew node@24 prefix."
  log_warn "If you explicitly want to remove system-level Codex, rerun with --remove-system-codex."
}

ensure_codex() {
  local npm_prefix npm_bin
  ensure_homebrew_node_active

  npm_prefix="$ACTIVE_NODE_PREFIX"
  if [[ -z "$npm_prefix" ]]; then
    echo "[ERROR] Failed to resolve npm global prefix from Homebrew node@24." >&2
    exit 1
  fi
  if ! path_under "$npm_prefix" "$(brew --prefix node@24)"; then
    echo "[ERROR] Refusing to install Codex outside Homebrew node@24 prefix: $npm_prefix" >&2
    echo "[ERROR] Expected npm prefix under: $(brew --prefix node@24)" >&2
    exit 1
  fi
  if [[ ! -w "$npm_prefix" ]]; then
    echo "[ERROR] Homebrew node@24 npm prefix is not writable: $npm_prefix" >&2
    echo "[ERROR] Fix Homebrew permissions or reinstall Homebrew as the current user; do not use sudo for Codex." >&2
    exit 1
  fi
  npm_bin="${npm_prefix%/}/bin"

  if [[ "$FORCE_CODEX_REINSTALL" -eq 1 ]]; then
    log_info "Force reinstall enabled: removing existing Codex CLI from Homebrew node@24 prefix..."
    "$ACTIVE_NPM_CMD" uninstall -g --prefix "$npm_prefix" @openai/codex >/dev/null 2>&1 || true
  else
    if [[ -x "$npm_bin/codex" ]]; then
      if "$npm_bin/codex" --version >/dev/null 2>&1; then
        log_info "Codex CLI already installed in Homebrew node@24 prefix: $("$npm_bin/codex" --version)"
        return 0
      fi
      log_warn "codex exists in Homebrew node@24 prefix but failed to run; will reinstall."
    fi
  fi

  log_info "Installing Codex CLI to Homebrew node@24 prefix ($npm_prefix)..."
  "$ACTIVE_NPM_CMD" install -g --prefix "$npm_prefix" @openai/codex

  if [[ -x "$npm_bin/codex" ]]; then
    log_ok "Codex CLI: $("$npm_bin/codex" --version)"
  else
    echo "[ERROR] codex command not found under Homebrew node@24 prefix after installation." >&2
    exit 1
  fi

  if cmd_exists codex; then
    local resolved
    resolved="$(command -v codex)"
    if [[ "$resolved" != "$npm_bin/codex" ]]; then
      log_warn "PATH resolves codex to: $resolved"
      log_warn "Expected Homebrew node@24 prefix: $npm_bin/codex"
      log_warn "Open a new terminal or ensure the active Node.js bin directory is first in PATH."
    fi
  else
    log_warn "codex is not in PATH yet. Open a new terminal or ensure Homebrew node@24 is in PATH."
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

  if grep -qE "^[[:space:]]*export[[:space:]]+${key}=" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v q="$quoted" '
      BEGIN{done=0}
      $0 ~ "^[[:space:]]*export[[:space:]]+" k "=" {
        if (!done) {
          print "export " k "=" q
          done=1
        }
        next
      }
      { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '\nexport %s=%s\n' "$key" "$quoted" >> "$file"
  fi
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

cleanup_obsolete_profile_env() {
  for rc_file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    remove_env_from_file "$rc_file" "NPM_CONFIG_PREFIX"
    remove_env_from_file "$rc_file" "NPM_CONFIG_CACHE"
    if is_default_codex_home; then
      remove_env_from_file "$rc_file" "CODEX_HOME" "$HOME/.codex"
    fi
  done
}

ensure_codex_home_profile_env() {
  if is_default_codex_home; then
    return 0
  fi

  export CODEX_HOME="$CODEX_HOME_DIR"
  for rc_file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    upsert_env_in_file "$rc_file" "CODEX_HOME" "$CODEX_HOME_DIR"
  done
  log_ok "Persisted CODEX_HOME in zsh/bash profile files: $CODEX_HOME_DIR"
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
  for rc_file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    upsert_env_in_file "$rc_file" "CRS_OAI_KEY" "$crs_key"
  done

  log_ok "Wrote: $config_path"
  log_ok "Wrote: $auth_path"
  log_ok "Persisted CRS_OAI_KEY in zsh/bash profile files"
  remove_crs_backups_after_success "${backup_paths[@]}"
}

configure_no_proxy() {
  local script_dir no_proxy_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  no_proxy_script="$script_dir/setup_no_proxy_mac.sh"

  if [[ ! -f "$no_proxy_script" ]]; then
    log_warn "NO_PROXY setup script not found next to installer: $no_proxy_script"
    log_warn "Skipping NO_PROXY/no_proxy configuration."
    return 0
  fi

  log_info "Configuring NO_PROXY/no_proxy bypass..."
  bash "$no_proxy_script"
}

main() {
  require_macos
  log_info "Starting one-click install for macOS Codex CLI package..."
  print_preflight_summary
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_ok "Dry run complete. No files, environment variables, packages, or PATH entries were changed."
    return 0
  fi
  require_non_root
  initialize_ascii_safe_environment
  sanitize_legacy_npm_config

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

  # Clean up legacy path blocks and env vars from pre-Homebrew installer versions.
  cleanup_legacy_path_block
  ensure_homebrew_node_path_profile
  cleanup_obsolete_profile_env
  ensure_codex_home_profile_env

  if [[ "$SKIP_CRS_CONFIG" -eq 0 ]]; then
    configure_crs "$clean_existing_config"
  fi

  if [[ "$SKIP_NO_PROXY" -eq 0 ]]; then
    configure_no_proxy
  fi

  printf '\n'
  log_ok "Done."
  remove_npm_config_backups_after_success
  log_info "If environment variables are not visible, open a new terminal or source the updated zsh/bash profile file."
}

main "$@"
