#!/usr/bin/env bash
set -euo pipefail

# Codex NO_PROXY bypass setup (macOS)
# - Reads base_url from CODEX_HOME/config.toml or ~/.codex/config.toml.
# - Removes legacy fixed IPs (3.27.43.117*) from existing NO_PROXY.
# - Adds CRS host, host:port, localhost, and 127.0.0.1 to NO_PROXY/no_proxy.
# - Preserves user-defined NO_PROXY entries.
# - Persists across reboot by updating shell profiles and installing a LaunchAgent.
# - Idempotent: safe to run multiple times.

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

required=("localhost" "127.0.0.1")

# Legacy fixed IPs from older installer versions — strip these on every run.
legacy_fixed=("3.27.43.117" "3.27.43.117:10086")

append_crs_base_url_items() {
  local config_path="${CODEX_HOME:-$HOME/.codex}/config.toml"
  local base_url hostport host
  [[ -f "$config_path" ]] || return 0

  base_url="$(sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$config_path" | head -n 1)"
  [[ -n "$base_url" ]] || return 0

  hostport="${base_url#*://}"
  hostport="${hostport%%/*}"
  host="${hostport%%:*}"
  [[ -n "$host" && "$host" != "$base_url" ]] || return 0

  required+=("$host")
  if [[ "$hostport" == *:* && "$hostport" != "$host" ]]; then
    required+=("$hostport")
  fi
}
append_crs_base_url_items

log "Current NO_PROXY/no_proxy:"
echo "  NO_PROXY=${NO_PROXY:-}"
echo "  no_proxy=${no_proxy:-}"

trim() {
  echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

items=()
for current in "${NO_PROXY:-}" "${no_proxy:-}"; do
  IFS=',' read -r -a parts <<< "${current}"
  for p in "${parts[@]}"; do
    p="$(trim "$p")"
    [[ -z "$p" ]] && continue
    # Strip legacy fixed IPs
    if contains "$p" "${legacy_fixed[@]}"; then
      log "Removing legacy fixed IP: $p"
      continue
    fi
    if ! contains "$p" "${items[@]}"; then
      items+=("$p")
    fi
  done
done

for v in "${required[@]}"; do
  if contains "$v" "${items[@]}"; then
    log "Already present: $v"
  else
    log "Adding: $v"
    items+=("$v")
  fi
done

new=""
for i in "${items[@]}"; do
  if [[ -z "$new" ]]; then
    new="$i"
  else
    new="${new},${i}"
  fi
done

log "New NO_PROXY:"
echo "  ${new}"

block_start="# >>> codex no_proxy >>>"
block_end="# <<< codex no_proxy <<<"

upsert_block() {
  local file="$1"
  local tmp

  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  touch "$file"
  tmp="$(mktemp)"

  awk -v start="$block_start" -v end="$block_end" '
    BEGIN{skip=0}
    $0==start{skip=1;next}
    $0==end{skip=0;next}
    !skip{print}
  ' "$file" > "$tmp"

  cat >> "$tmp" <<EOF

$block_start
export NO_PROXY="$new"
export no_proxy="\$NO_PROXY"
$block_end
EOF

  mv "$tmp" "$file"
  log "Updated: $file"
}

# Persist for shells.
upsert_block "$HOME/.zprofile"
upsert_block "$HOME/.zshrc"
[[ -f "$HOME/.bash_profile" ]] && upsert_block "$HOME/.bash_profile"
[[ -f "$HOME/.bashrc" ]] && upsert_block "$HOME/.bashrc"

# Best-effort: set for current GUI session too.
if command -v launchctl >/dev/null 2>&1; then
  log "Setting launchctl environment (current login session)..."
  launchctl setenv NO_PROXY "$new" || true
  launchctl setenv no_proxy "$new" || true
else
  log "Warning: launchctl not found; skipping GUI env setup."
fi

# Install a LaunchAgent to re-apply at login (persistent).
agent_label="com.codex.no-proxy"
agent_dir="$HOME/Library/LaunchAgents"
helper_dir="$HOME/Library/Application Support/codex/no-proxy"
helper_sh="$helper_dir/setenv.sh"
plist="$agent_dir/${agent_label}.plist"

mkdir -p "$agent_dir"
mkdir -p "$helper_dir"

cat > "$helper_sh" <<EOF
#!/bin/bash
set -euo pipefail
NO_PROXY_VALUE="$new"
/bin/launchctl setenv NO_PROXY "\$NO_PROXY_VALUE" || true
/bin/launchctl setenv no_proxy "\$NO_PROXY_VALUE" || true
exit 0
EOF
chmod +x "$helper_sh" || true
log "Wrote: $helper_sh"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$agent_label</string>
    <key>ProgramArguments</key>
    <array>
      <string>$helper_sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
  </dict>
</plist>
EOF
log "Wrote: $plist"

if command -v launchctl >/dev/null 2>&1; then
  uid="$(id -u)"
  domain="gui/$uid"
  log "Loading LaunchAgent (best-effort)..."
  launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || true
  launchctl enable "$domain/$agent_label" >/dev/null 2>&1 || true
  launchctl kickstart -k "$domain/$agent_label" >/dev/null 2>&1 || true

  if launchctl print "$domain/$agent_label" >/dev/null 2>&1; then
    log "LaunchAgent loaded: $domain/$agent_label"
  else
    launchctl load -w "$plist" >/dev/null 2>&1 || true
    log "LaunchAgent load attempted (if it didn't load, you can re-login to apply)."
  fi
fi

log "Done."
log "Recommended: open a NEW terminal to apply."
log "To apply to the CURRENT shell (choose one):"
echo "  # Option A (preferred): source your shell rc/profile file you just updated:"
echo "  #   zsh : source ~/.zshrc    (or: source ~/.zprofile)"
echo "  #   bash: source ~/.bashrc   (or: source ~/.bash_profile)"
echo "  # Option B: export variables (temporary for this shell only):"
echo "  export NO_PROXY=\"$new\""
echo "  export no_proxy=\"\$NO_PROXY\""
