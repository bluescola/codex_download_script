#!/usr/bin/env bash
set -euo pipefail

FORCE_NODE_REINSTALL=0
FORCE_CODEX_REINSTALL=0
REMOVE_SYSTEM_CODEX=0
SKIP_CRS_CONFIG=0
NODE_ROOT="${HOME}/.local/node"
NPM_PREFIX="${HOME}/.npm-global"

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
    -h|--help)
      cat <<'USAGE'
Usage: install-codex-cli-linux.sh [options]

Options:
  --force-node-reinstall   Force reinstall Node.js/npm
  --force-codex-reinstall  Force reinstall @openai/codex
  --remove-system-codex    Remove system-level @openai/codex (e.g. /usr/lib/node_modules)
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

  # Codex is usually installed under the user npm prefix.
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

  # Remove installer-generated backups to avoid clutter.
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
    # Trim whitespace and drop control chars to avoid breaking sed/exports.
    value="$(printf '%s' "$value" | tr -d '\000-\037\177')"
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
    # Drop control chars (arrow keys, etc) and trim whitespace.
    value="$(printf '%s' "$value" | tr -d '\000-\037\177')"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    log_warn "Input cannot be empty."
  done
}

install_node_user() {
  log_info "Installing Node.js LTS to user directory (no sudo)..."

  if ! cmd_exists curl; then
    echo "[ERROR] curl is required but not found." >&2
    exit 1
  fi

  local arch node_arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) node_arch='linux-x64' ;;
    aarch64|arm64) node_arch='linux-arm64' ;;
    armv7l) node_arch='linux-armv7l' ;;
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

  local tmp_dir tarball node_url
  tmp_dir="$(mktemp -d)"
  tarball="$tmp_dir/node.tar.xz"
  node_url="https://nodejs.org/dist/${lts_version}/node-${lts_version}-${node_arch}.tar.xz"
  curl -fsSL "$node_url" -o "$tarball"

  mkdir -p "$NODE_ROOT"
  tar -xJf "$tarball" -C "$NODE_ROOT"

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
  if [[ "$FORCE_NODE_REINSTALL" -eq 0 ]] && [[ -x "$NODE_ROOT/current/bin/node" ]] && [[ -x "$NODE_ROOT/current/bin/npm" ]]; then
    log_info "Node.js and npm already installed (user directory)."
    log_ok "Node.js: $("$NODE_ROOT/current/bin/node" -v)"
    log_ok "npm: $("$NODE_ROOT/current/bin/npm" -v)"
    return 0
  fi

  if cmd_exists node && cmd_exists npm && [[ "$FORCE_NODE_REINSTALL" -eq 0 ]]; then
    log_warn "System Node.js/npm detected, but user-level install is required. Installing user copy..."
  fi

  if [[ "$FORCE_NODE_REINSTALL" -eq 1 && -d "$NODE_ROOT" ]]; then
    log_info "Removing previous user Node.js install at $NODE_ROOT"
    rm -rf "$NODE_ROOT"
  fi

  install_node_user
}

upsert_path_block() {
  local file="$1"
  local block_start="$2"
  local block_end="$3"
  local line="$4"

  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi

  if grep -qF "$block_start" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v start="$block_start" -v end="$block_end" -v line="$line" '
      $0==start {print start; print line; print end; inblock=1; next}
      $0==end {inblock=0; next}
      !inblock {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '\n%s\n%s\n%s\n' "$block_start" "$line" "$block_end" >> "$file"
  fi
}

ensure_user_npm_prefix() {
  local user_prefix="$NPM_PREFIX"
  local npm_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"

  mkdir -p "$user_prefix"

  if [[ "$npm_prefix" != "$user_prefix" ]]; then
    log_info "Setting npm global prefix to user directory: $user_prefix"
    npm config set prefix "$user_prefix"
  fi

  local npm_bin="${user_prefix%/}/bin"
  local node_bin=""
  if [[ -d "$NODE_ROOT/current/bin" ]]; then
    node_bin="$NODE_ROOT/current/bin"
  fi
  export PATH="$npm_bin:$PATH"

  local block_start="# >>> codex user paths >>>"
  local block_end="# <<< codex user paths <<<"
  local line="export PATH=\"$npm_bin"
  if [[ -n "$node_bin" ]]; then
    line="$line:$node_bin"
  fi
  line="$line:\$PATH\""

  upsert_path_block "$HOME/.bashrc" "$block_start" "$block_end" "$line"
  upsert_path_block "$HOME/.zshrc" "$block_start" "$block_end" "$line"

  log_ok "npm prefix: $(npm config get prefix)"
  log_ok "Ensured PATH includes: $npm_bin"
}

ensure_codex() {
  local npm_prefix npm_bin
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  npm_bin="${npm_prefix%/}/bin"

  if [[ "$FORCE_CODEX_REINSTALL" -eq 1 ]]; then
    log_info "Force reinstall enabled: removing existing Codex CLI in user prefix..."
    npm uninstall -g @openai/codex >/dev/null 2>&1 || true
  else
    if [[ -x "$npm_bin/codex" ]]; then
      if "$npm_bin/codex" --version >/dev/null 2>&1; then
        log_info "Codex CLI already installed in user prefix: $($npm_bin/codex --version)"
        return 0
      fi
      log_warn "codex exists in user prefix but failed to run; will reinstall."
    fi
  fi

  log_info "Installing Codex CLI to user prefix ($npm_prefix)..."
  if npm i -g @openai/codex >/dev/null 2>&1; then
    :
  else
    echo "[ERROR] npm install -g @openai/codex failed in user prefix. Check npm prefix and permissions." >&2
    exit 1
  fi

  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  npm_bin="${npm_prefix%/}/bin"
  if [[ -x "$npm_bin/codex" ]]; then
    log_ok "Codex CLI: $($npm_bin/codex --version)"
  else
    echo "[ERROR] codex command not found under npm prefix after installation." >&2
    exit 1
  fi

  if cmd_exists codex; then
    local resolved
    resolved="$(command -v codex)"
    if [[ "$resolved" != "$npm_bin/codex" ]]; then
      log_warn "PATH resolves codex to: $resolved"
      log_warn "Expected user prefix: $npm_bin/codex"
      log_warn "Open a new shell or ensure PATH has $npm_bin first."
    fi
  else
    log_warn "codex is not in current PATH. Open a new shell or add this to your shell profile:"
    printf 'export PATH="%s:$PATH"\n' "$npm_bin"
  fi
}

remove_system_codex() {
  local use_sudo
  local found=0

  # Common system-level npm global locations.
  if [[ -d "/usr/lib/node_modules/@openai/codex" ]]; then
    found=1
  elif [[ -d "/usr/local/lib/node_modules/@openai/codex" ]]; then
    found=1
  fi

  if [[ "$found" -eq 0 ]]; then
    log_info "No system-level Codex CLI found under /usr or /usr/local."
    return 0
  fi

  log_info "Removing system-level Codex CLI with sudo..."
  use_sudo="$(need_sudo)"
  ${use_sudo}npm uninstall -g @openai/codex >/dev/null 2>&1 || true
}

upsert_env_in_file() {
  local file="$1"
  local key="$2"
  local value="$3"

  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi

  local tmp found
  tmp="$(mktemp)"
  found=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+${key}= ]]; then
      if [[ "$found" -eq 0 ]]; then
        printf 'export %s="%s"\n' "$key" "$value" >> "$tmp"
        found=1
      fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if [[ "$found" -eq 0 ]]; then
    printf '\nexport %s="%s"\n' "$key" "$value" >> "$tmp"
  fi

  mv "$tmp" "$file"
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

  # Persist in common shells.
  upsert_env_in_file "$HOME/.bashrc" "CRS_OAI_KEY" "$crs_key"
  upsert_env_in_file "$HOME/.zshrc" "CRS_OAI_KEY" "$crs_key"

  log_ok "Wrote: $config_path"
  log_ok "Wrote: $auth_path"
  log_ok "Persisted CRS_OAI_KEY in ~/.bashrc and ~/.zshrc"
}

main() {
  local clean_existing_config=0
  if test_preexisting_node_npm_codex; then
    clean_existing_config=1
  fi

  log_info "Starting one-click install for Linux Codex CLI package..."
  ensure_node_npm
  if [[ "$REMOVE_SYSTEM_CODEX" -eq 1 ]]; then
    remove_system_codex
  fi
  ensure_user_npm_prefix
  ensure_codex

  if [[ "$SKIP_CRS_CONFIG" -eq 0 ]]; then
    configure_crs "$clean_existing_config"
  fi

  printf '\n'
  log_ok "Done."
  log_info "If environment variables are not visible in current shell, run: source ~/.bashrc"
}

main "$@"
