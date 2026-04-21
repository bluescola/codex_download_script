#!/usr/bin/env bash
set -euo pipefail

FORCE_NODE_REINSTALL=0
FORCE_CODEX_REINSTALL=0
SKIP_CRS_CONFIG=0

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
    --skip-crs-config)
      SKIP_CRS_CONFIG=1
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: install-codex-cli-mac.sh [options]

Options:
  --force-node-reinstall   Force reinstall Node.js/npm (user-only install)
  --force-codex-reinstall  Force reinstall @openai/codex
  --skip-crs-config        Skip interactive CRS config generation
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
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    log_warn "Input cannot be empty."
  done
}

read_secret_required() {
  local prompt="$1"
  local value=''
  while true; do
    read -r -s -p "$prompt" value
    printf '\n'
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    log_warn "Input cannot be empty."
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
  lts_version="$(curl -fsSL https://nodejs.org/dist/index.tab | awk -F'\t' 'NR>1 && $9 != "-" {print $1; exit}')"
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

ensure_codex() {
  if [[ "$FORCE_CODEX_REINSTALL" -eq 1 ]]; then
    log_info "Force reinstall enabled: removing existing Codex CLI..."
    npm uninstall -g @openai/codex >/dev/null 2>&1 || true
  else
    if cmd_exists codex; then
      if codex --version >/dev/null 2>&1; then
        log_info "Codex CLI already installed: $(codex --version)"
        return 0
      fi
      log_warn "codex exists but failed to run; will reinstall."
    fi
  fi

  log_info "Installing Codex CLI (user npm prefix)..."
  npm i -g @openai/codex

  local npm_bin="$NPM_PREFIX/bin"
  if cmd_exists codex; then
    log_ok "Codex CLI: $(codex --version)"
    return 0
  fi

  if [[ -x "$npm_bin/codex" ]]; then
    log_ok "Codex CLI: $("$npm_bin/codex" --version)"
    log_warn "codex is not in PATH yet. Open a new terminal or run: source ~/.zshrc"
    return 0
  fi

  echo "[ERROR] codex command not found after installation." >&2
  exit 1
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

main() {
  require_non_root
  require_macos

  local clean_existing_config=0
  if test_preexisting_node_npm_codex; then
    clean_existing_config=1
  fi

  log_info "Starting one-click install for macOS Codex CLI package..."
  ensure_node_npm
  ensure_npm_user_prefix
  ensure_codex

  if [[ "$SKIP_CRS_CONFIG" -eq 0 ]]; then
    configure_crs "$clean_existing_config"
  fi

  printf '\n'
  log_ok "Done."
  log_info "If environment variables are not visible, run: source ~/.zshrc"
}

main "$@"
