#!/usr/bin/env bash
set -euo pipefail

FORCE_NODE_REINSTALL=0
FORCE_CODEX_REINSTALL=0
REMOVE_SYSTEM_CODEX=0
SKIP_CRS_CONFIG=0
SKIP_NO_PROXY=0

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
    -h|--help)
      cat <<'USAGE'
Usage: install-codex-cli-mac.sh [options]

Options:
  --force-node-reinstall   Force reinstall Node.js/npm (user-only install)
  --force-codex-reinstall  Force reinstall @openai/codex
  --remove-system-codex    Compatibility flag; system-level @openai/codex removal is automatic
  --skip-crs-config        Skip interactive CRS config generation
  --skip-no-proxy          Skip NO_PROXY/no_proxy bypass setup
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

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_ok() { printf '[OK] %s\n' "$*"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

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
    log_info "Backed up: $bkp"
  fi
}

test_preexisting_node_npm() {
  if [[ -x "$NODE_ROOT/current/bin/node" ]] && [[ -x "$NODE_ROOT/current/bin/npm" ]]; then
    return 0
  fi
  cmd_exists node && cmd_exists npm
}

test_preexisting_codex() {
  if cmd_exists codex; then
    return 0
  fi

  if [[ -x "$NPM_PREFIX/bin/codex" ]]; then
    return 0
  fi

  if test_preexisting_node_npm; then
    local npm_cmd prefix npm_bin
    npm_cmd="npm"
    if [[ -x "$NODE_ROOT/current/bin/npm" ]]; then
      npm_cmd="$NODE_ROOT/current/bin/npm"
    fi

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
    rm -f "$config_path"
    log_info "Removed old config: $config_path"
  fi
  if [[ -f "$auth_path" ]]; then
    rm -f "$auth_path"
    log_info "Removed old config: $auth_path"
  fi

  local backups=()
  shopt -s nullglob
  backups+=( "${config_path}.bak."* )
  backups+=( "${auth_path}.bak."* )
  shopt -u nullglob
  if ((${#backups[@]})); then
    rm -f "${backups[@]}"
    for b in "${backups[@]}"; do
      log_info "Removed old backup: $b"
    done
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

NODE_ROOT="$HOME/.local/node"
NPM_PREFIX="$HOME/.npm-global"

ensure_shell_path_block() {
  local npm_bin="$NPM_PREFIX/bin"
  local node_bin=""
  if [[ -d "$NODE_ROOT/current/bin" ]]; then
    node_bin="$NODE_ROOT/current/bin"
  fi

  local path_line="export PATH=\"$npm_bin"
  if [[ -n "$node_bin" ]]; then
    path_line="$path_line:$node_bin"
  fi
  path_line="$path_line:\$PATH\""

  local block_start="# >>> codex user paths >>>"
  local block_end="# <<< codex user paths <<<"
  local block="${block_start}\n${path_line}\n${block_end}"

  for file in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [[ ! -f "$file" ]]; then
      touch "$file"
    fi
    if ! grep -F "$block_start" "$file" >/dev/null 2>&1; then
      printf '\n%s\n' "$block" >> "$file"
    fi
  done
}

install_node_user() {
  log_info "Installing Node.js LTS to user directory (no sudo)..."

  if ! cmd_exists curl; then
    echo "[ERROR] curl is required but not found." >&2
    exit 1
  fi

  local arch
  arch="$(uname -m)"
  local node_arch=''
  case "$arch" in
    arm64) node_arch='darwin-arm64' ;;
    x86_64) node_arch='darwin-x64' ;;
    *)
      echo "[ERROR] Unsupported CPU architecture: $arch" >&2
      exit 1
      ;;
  esac

  local lts_version
  # NOTE: Do not exit early in the consumer (awk) when piping from curl.
  # Exiting early closes the pipe, curl then errors with:
  #   curl: (23) Failure writing output to destination
  # which is fatal under `set -o pipefail`.
  lts_version="$(
    curl -fsSL https://nodejs.org/dist/index.tab |
      awk -F'\t' '
        NR==1 { next }
        $9 != "-" && !found { v=$1; found=1 }
        END { if (found) print v; else exit 1 }
      '
  )"
  if [[ -z "$lts_version" ]]; then
    echo "[ERROR] Failed to resolve Node.js LTS version." >&2
    exit 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local tarball="$tmp_dir/node.tar.gz"
  local node_url="https://nodejs.org/dist/${lts_version}/node-${lts_version}-${node_arch}.tar.gz"

  curl -fsSL "$node_url" -o "$tarball"

  mkdir -p "$NODE_ROOT"
  tar -xzf "$tarball" -C "$NODE_ROOT"

  local extracted_dir="$NODE_ROOT/node-${lts_version}-${node_arch}"
  local target_dir="$NODE_ROOT/$lts_version"

  if [[ -d "$target_dir" ]]; then
    rm -rf "$target_dir"
  fi
  mv "$extracted_dir" "$target_dir"
  ln -sfn "$target_dir" "$NODE_ROOT/current"

  export PATH="$NODE_ROOT/current/bin:$PATH"
  hash -r

  log_ok "Node.js: $(node -v)"
  log_ok "npm: $(npm -v)"
}

ensure_node_npm() {
  if cmd_exists node && cmd_exists npm && [[ "$FORCE_NODE_REINSTALL" -eq 0 ]]; then
    log_info "Node.js and npm already installed."
    log_ok "Node.js: $(node -v)"
    log_ok "npm: $(npm -v)"
    return 0
  fi

  if [[ "$FORCE_NODE_REINSTALL" -eq 1 && -d "$NODE_ROOT" ]]; then
    log_info "Removing previous user Node.js install at $NODE_ROOT"
    rm -rf "$NODE_ROOT"
  fi

  install_node_user
}

ensure_npm_user_prefix() {
  mkdir -p "$NPM_PREFIX"
  npm config set prefix "$NPM_PREFIX" >/dev/null
  export NPM_CONFIG_PREFIX="$NPM_PREFIX"
  export PATH="$NPM_PREFIX/bin:$PATH"
  ensure_shell_path_block
  log_ok "npm global prefix: $(npm config get prefix)"
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
  path_under "$path" "$NPM_PREFIX" || path_under "$path" "$HOME"
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

ensure_codex() {
  local npm_bin="$NPM_PREFIX/bin"

  if [[ "$FORCE_CODEX_REINSTALL" -eq 1 ]]; then
    log_info "Force reinstall enabled: removing existing Codex CLI in user prefix..."
    npm uninstall -g @openai/codex >/dev/null 2>&1 || true
  else
    if [[ -x "$npm_bin/codex" ]]; then
      if "$npm_bin/codex" --version >/dev/null 2>&1; then
        log_info "Codex CLI already installed in user prefix: $("$npm_bin/codex" --version)"
        return 0
      fi
      log_warn "codex exists in user prefix but failed to run; will reinstall."
    fi
  fi

  log_info "Installing Codex CLI (user npm prefix)..."
  npm i -g @openai/codex

  if [[ -x "$npm_bin/codex" ]]; then
    log_ok "Codex CLI: $("$npm_bin/codex" --version)"
  else
    echo "[ERROR] codex command not found under user npm prefix after installation." >&2
    exit 1
  fi

  if cmd_exists codex; then
    local resolved
    resolved="$(command -v codex)"
    if [[ "$resolved" != "$npm_bin/codex" ]]; then
      log_warn "PATH resolves codex to: $resolved"
      log_warn "Expected user prefix: $npm_bin/codex"
      log_warn "Open a new terminal or ensure PATH has $npm_bin first."
    fi
  else
    log_warn "codex is not in PATH yet. Open a new terminal or run: source ~/.zshrc"
  fi
}

upsert_env_in_file() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped="$value"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"

  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi

  if grep -qE "^[[:space:]]*export[[:space:]]+${key}=" "$file"; then
    perl -pi -e "s|^[[:space:]]*export[[:space:]]+${key}=.*$|export ${key}=\"${escaped}\"|" "$file"
  else
    printf '\nexport %s="%s"\n' "$key" "$value" >> "$file"
  fi
}

configure_crs() {
  local clean_existing="${1:-0}"
  local codex_dir config_path auth_path base_url crs_key
  codex_dir="$HOME/.codex"
  config_path="$codex_dir/config.toml"
  auth_path="$codex_dir/auth.json"

  log_info "Starting CRS configuration..."
  base_url="$(read_required 'Enter CRS base_url (example: http://x.x.x.x:10086/openai): ')"
  crs_key="$(read_secret_required 'Enter CRS_OAI_KEY (hidden input): ')"

  mkdir -p "$codex_dir"
  if [[ "$clean_existing" -eq 1 ]]; then
    log_info "Detected existing node/npm/codex; cleaning old CRS configuration before regenerating..."
    clear_existing_crs_config "$codex_dir"
  else
    backup_if_exists "$config_path"
    backup_if_exists "$auth_path"
  fi

  cat > "$config_path" <<CFG
model_provider = "crs"
model = "gpt-5.2"
model_reasoning_effort = "xhigh"
disable_response_storage = true
preferred_auth_method = "apikey"

sandbox_mode = "danger-full-access"
approval_policy = "on-request"
# Or more aggressive:
# approval_policy = "never"

[model_providers.crs]
name = "crs"
base_url = "$base_url"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"

[features]
tui_app_server = false
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
  upsert_env_in_file "$HOME/.zshrc" "CRS_OAI_KEY" "$crs_key"
  upsert_env_in_file "$HOME/.bashrc" "CRS_OAI_KEY" "$crs_key"

  log_ok "Wrote: $config_path"
  log_ok "Wrote: $auth_path"
  log_ok "Persisted CRS_OAI_KEY in ~/.zshrc and ~/.bashrc"
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
  require_non_root
  require_macos

  local clean_existing_config=0
  if test_preexisting_node_npm_codex; then
    clean_existing_config=1
  fi

  log_info "Starting one-click install for macOS Codex CLI package..."
  ensure_node_npm
  if [[ "$REMOVE_SYSTEM_CODEX" -eq 1 ]]; then
    log_info "--remove-system-codex is now automatic; checking system-level Codex CLI."
  fi
  ensure_no_system_codex
  ensure_npm_user_prefix
  ensure_codex

  if [[ "$SKIP_CRS_CONFIG" -eq 0 ]]; then
    configure_crs "$clean_existing_config"
  fi

  if [[ "$SKIP_NO_PROXY" -eq 0 ]]; then
    configure_no_proxy
  fi

  printf '\n'
  log_ok "Done."
  log_info "If environment variables are not visible, run: source ~/.zshrc"
}

main "$@"
