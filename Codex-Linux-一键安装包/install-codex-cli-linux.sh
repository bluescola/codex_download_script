#!/usr/bin/env bash
set -euo pipefail

FORCE_NODE_REINSTALL=0
FORCE_CODEX_REINSTALL=0
REMOVE_SYSTEM_CODEX=0
SKIP_CRS_CONFIG=0
SKIP_NO_PROXY=0

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
    -h|--help)
      cat <<'USAGE'
Usage: install-codex-cli-linux.sh [options]

Options:
  --force-node-reinstall   Force reinstall Node.js/npm
  --force-codex-reinstall  Force reinstall @openai/codex
  --remove-system-codex    Explicitly remove system-level @openai/codex if detected
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
    log_info "Backed up: $bkp"
  fi
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_single_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

test_preexisting_node_npm() {
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    \. "$NVM_DIR/nvm.sh"
    if nvm use --silent default >/dev/null 2>&1 || nvm use --silent --lts >/dev/null 2>&1; then
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

  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  log_info "Installing Node.js LTS via nvm..."
  nvm install --lts
  nvm use --lts
  nvm alias default 'lts/*'

  local node_bin_dir
  node_bin_dir="$(dirname "$(which node)")"
  export PATH="$node_bin_dir:$PATH"
  hash -r

  log_ok "Node.js: $(node -v)"
  log_ok "npm: $(npm -v)"
  log_ok "nvm + Node.js installed under: $NVM_DIR"
}

ensure_node_npm() {
  export NVM_DIR

  if [[ "$FORCE_NODE_REINSTALL" -eq 0 ]] && [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    \. "$NVM_DIR/nvm.sh"
    if nvm use --silent default >/dev/null 2>&1 || nvm use --silent --lts >/dev/null 2>&1; then
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
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    install_nvm_and_node
  fi

  # shellcheck source=/dev/null
  \. "$NVM_DIR/nvm.sh"
  if nvm use --silent default >/dev/null 2>&1 || nvm use --silent --lts >/dev/null 2>&1; then
    return 0
  fi

  install_nvm_and_node
  # shellcheck source=/dev/null
  \. "$NVM_DIR/nvm.sh"
  nvm use --silent default >/dev/null 2>&1 || nvm use --silent --lts >/dev/null 2>&1
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
    log_info "Detected existing node/npm/codex; backing up old CRS configuration before regenerating..."
  fi
  backup_if_exists "$config_path"
  backup_if_exists "$auth_path"

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
  require_non_root
  initialize_ascii_safe_environment

  local clean_existing_config=0
  if test_preexisting_node_npm_codex; then
    clean_existing_config=1
  fi

  log_info "Starting one-click install for Linux Codex CLI package..."
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

  printf '\n'
  log_ok "Done."
  log_info "If environment variables are not visible in current shell, run: source ~/.bashrc"
}

main "$@"
