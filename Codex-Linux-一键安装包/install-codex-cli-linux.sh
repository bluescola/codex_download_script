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
Usage: install-codex-cli-linux.sh [options]

Options:
  --force-node-reinstall   Force reinstall Node.js/npm
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

ensure_node_npm() {
  if cmd_exists node && cmd_exists npm && [[ "$FORCE_NODE_REINSTALL" -eq 0 ]]; then
    log_info "Node.js and npm already installed."
    log_ok "Node.js: $(node -v)"
    log_ok "npm: $(npm -v)"
    return 0
  fi

  local SUDO
  SUDO="$(need_sudo)"

  if cmd_exists apt-get; then
    log_info "Installing Node.js LTS via NodeSource (apt)..."
    ${SUDO}apt-get update -y
    ${SUDO}apt-get install -y ca-certificates curl gnupg
    curl -fsSL https://deb.nodesource.com/setup_lts.x | ${SUDO}bash -
    ${SUDO}apt-get install -y nodejs
  elif cmd_exists dnf; then
    log_info "Installing Node.js LTS via NodeSource (dnf)..."
    ${SUDO}dnf install -y ca-certificates curl
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | ${SUDO}bash -
    ${SUDO}dnf install -y nodejs
  elif cmd_exists yum; then
    log_info "Installing Node.js LTS via NodeSource (yum)..."
    ${SUDO}yum install -y ca-certificates curl
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | ${SUDO}bash -
    ${SUDO}yum install -y nodejs
  elif cmd_exists pacman; then
    log_info "Installing Node.js/npm via pacman..."
    ${SUDO}pacman -Sy --noconfirm nodejs npm
  elif cmd_exists zypper; then
    log_info "Installing Node.js/npm via zypper..."
    ${SUDO}zypper --non-interactive install nodejs npm
  elif cmd_exists apk; then
    log_info "Installing Node.js/npm via apk..."
    ${SUDO}apk add --no-cache nodejs npm
  else
    echo "[ERROR] Unsupported package manager. Install Node.js LTS manually, then re-run." >&2
    exit 1
  fi

  if ! cmd_exists node || ! cmd_exists npm; then
    echo "[ERROR] Node.js/npm install did not complete successfully." >&2
    exit 1
  fi

  log_ok "Node.js: $(node -v)"
  log_ok "npm: $(npm -v)"
}

ensure_codex() {
  local use_sudo=''

  if [[ "$FORCE_CODEX_REINSTALL" -eq 1 ]]; then
    log_info "Force reinstall enabled: removing existing Codex CLI..."
    if npm uninstall -g @openai/codex >/dev/null 2>&1; then
      :
    else
      use_sudo="$(need_sudo)"
      ${use_sudo}npm uninstall -g @openai/codex >/dev/null 2>&1 || true
    fi
  else
    if cmd_exists codex; then
      if codex --version >/dev/null 2>&1; then
        log_info "Codex CLI already installed: $(codex --version)"
        return 0
      fi
      log_warn "codex exists but failed to run; will reinstall."
    fi
  fi

  log_info "Installing Codex CLI..."
  if npm i -g @openai/codex >/dev/null 2>&1; then
    :
  else
    use_sudo="$(need_sudo)"
    ${use_sudo}npm i -g @openai/codex >/dev/null
  fi

  if cmd_exists codex; then
    log_ok "Codex CLI: $(codex --version)"
    return 0
  fi

  # Fallback discovery from npm global bin dir.
  local npm_prefix npm_bin
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  npm_bin="${npm_prefix%/}/bin"
  if [[ -x "$npm_bin/codex" ]]; then
    log_ok "Codex CLI: $($npm_bin/codex --version)"
    log_warn "codex is not in current PATH. Add this to your shell profile:"
    printf 'export PATH="%s:$PATH"\n' "$npm_bin"
    return 0
  fi

  echo "[ERROR] codex command not found after installation." >&2
  exit 1
}

upsert_env_in_file() {
  local file="$1"
  local key="$2"
  local value="$3"

  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi

  if grep -qE "^[[:space:]]*export[[:space:]]+${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*export[[:space:]]+${key}=.*$|export ${key}=\"${value//|/\\|}\"|" "$file"
  else
    printf '\nexport %s="%s"\n' "$key" "$value" >> "$file"
  fi
}

configure_crs() {
  local codex_dir config_path auth_path base_url crs_key
  codex_dir="$HOME/.codex"
  config_path="$codex_dir/config.toml"
  auth_path="$codex_dir/auth.json"

  log_info "Starting CRS configuration..."
  base_url="$(read_required 'Enter CRS base_url (example: http://x.x.x.x:10086/openai): ')"
  crs_key="$(read_secret_required 'Enter CRS_OAI_KEY (hidden input): ')"

  mkdir -p "$codex_dir"
  backup_if_exists "$config_path"
  backup_if_exists "$auth_path"

  cat > "$config_path" <<CFG
model_provider = "crs"
model = "gpt-5.1-codex-max"
model_reasoning_effort = "high"
disable_response_storage = true
preferred_auth_method = "apikey"

[model_providers.crs]
name = "crs"
base_url = "$base_url"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"
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
  log_info "Starting one-click install for Linux Codex CLI package..."
  ensure_node_npm
  ensure_codex

  if [[ "$SKIP_CRS_CONFIG" -eq 0 ]]; then
    configure_crs
  fi

  printf '\n'
  log_ok "Done."
  log_info "If environment variables are not visible in current shell, run: source ~/.bashrc"
}

main "$@"
