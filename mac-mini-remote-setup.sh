#!/usr/bin/env bash
# =============================================================================
# mac-mini-remote-setup.sh
# Sets up Tailscale + SSH/VNC tunnel to your Mac Mini on any remote machine
# (GitHub Codespaces, Ubuntu VM, Linux server, etc.)
#
# Usage:
#   chmod +x mac-mini-remote-setup.sh
#   ./mac-mini-remote-setup.sh
#
# Requirements:
#   - TAILSCALE_AUTHKEY env var set (get from https://login.tailscale.com/admin/settings/keys)
#   - MAC_MINI_USER env var set (e.g. "evgeny")
#   - MAC_MINI_TAILSCALE_IP env var set (e.g. "100.103.176.57")
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colour

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Config (override via env vars or edit here) ───────────────────────────────
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
MAC_MINI_USER="${MAC_MINI_USER:-evgeny}"
MAC_MINI_TAILSCALE_IP="${MAC_MINI_TAILSCALE_IP:-100.103.176.57}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SSH_CONFIG_PATH="$HOME/.ssh/config"

# Ports to forward (local:remote)
VNC_LOCAL_PORT=5900
VNC_REMOTE_PORT=5900
OLLAMA_LOCAL_PORT=11434
OLLAMA_REMOTE_PORT=11434
WEBUI_LOCAL_PORT=3000
WEBUI_REMOTE_PORT=3000

# ── Preflight checks ──────────────────────────────────────────────────────────
section "Preflight Checks"

[[ "$EUID" -eq 0 ]] && warn "Running as root — Tailscale will be installed system-wide."

if [[ -z "$TAILSCALE_AUTHKEY" ]]; then
  error "TAILSCALE_AUTHKEY is not set.\nGet one at: https://login.tailscale.com/admin/settings/keys\nThen run: export TAILSCALE_AUTHKEY=tskey-auth-xxxx"
fi

if [[ -z "$MAC_MINI_TAILSCALE_IP" ]]; then
  error "MAC_MINI_TAILSCALE_IP is not set.\nRun 'tailscale ip -4' on your Mac Mini and set it:\nexport MAC_MINI_TAILSCALE_IP=100.x.x.x"
fi

log "Config OK — Mac Mini: ${MAC_MINI_USER}@${MAC_MINI_TAILSCALE_IP}"

# ── Detect OS ─────────────────────────────────────────────────────────────────
section "Detecting Environment"

OS="$(uname -s)"
DISTRO=""
if [[ "$OS" == "Linux" ]]; then
  if command -v apt-get &>/dev/null; then
    DISTRO="debian"
  elif command -v yum &>/dev/null; then
    DISTRO="rhel"
  elif command -v pacman &>/dev/null; then
    DISTRO="arch"
  fi
  log "Linux detected — distro family: ${DISTRO:-unknown}"
elif [[ "$OS" == "Darwin" ]]; then
  DISTRO="macos"
  log "macOS detected"
else
  error "Unsupported OS: $OS"
fi

# ── Fix broken apt repos before installing anything ───────────────────────────
section "Fixing APT Repositories"

if [[ "$DISTRO" == "debian" ]]; then
  # Fix Yarn GPG key — common issue in Codespaces and fresh Ubuntu containers
  if apt-get update 2>&1 | grep -q "dl.yarnpkg.com"; then
    warn "Yarn repo GPG error detected — fixing..."

    # Modern fix: add key to keyring (apt-key is deprecated in Ubuntu 22+)
    if curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg \
        | gpg --dearmor \
        | sudo tee /usr/share/keyrings/yarn-archive-keyring.gpg > /dev/null 2>&1; then

      # Rewrite the yarn source to use the signed-by keyring
      echo "deb [signed-by=/usr/share/keyrings/yarn-archive-keyring.gpg] \
https://dl.yarnpkg.com/debian/ stable main" \
        | sudo tee /etc/apt/sources.list.d/yarn.list > /dev/null

      log "Yarn GPG key fixed"
    else
      # Fallback: just remove the broken yarn repo entirely
      warn "Could not fix Yarn GPG key — removing Yarn repo (Yarn not needed for this setup)"
      sudo rm -f /etc/apt/sources.list.d/yarn.list
    fi

    # Re-run update cleanly
    sudo apt-get update -qq
    log "APT repos updated cleanly"
  else
    log "APT repos OK — no fixes needed"
  fi
fi

# ── Install Tailscale ─────────────────────────────────────────────────────────
section "Installing Tailscale"

if command -v tailscale &>/dev/null; then
  log "Tailscale already installed — $(tailscale version | head -1)"
else
  case "$DISTRO" in
    debian|rhel)
      curl -fsSL https://tailscale.com/install.sh | sh
      ;;
    arch)
      sudo pacman -Sy --noconfirm tailscale
      ;;
    macos)
      if command -v brew &>/dev/null; then
        brew install tailscale
      else
        error "Homebrew not found. Install it first: https://brew.sh"
      fi
      ;;
    *)
      curl -fsSL https://tailscale.com/install.sh | sh
      ;;
  esac
  log "Tailscale installed"
fi

# ── Start Tailscale daemon ────────────────────────────────────────────────────
section "Starting Tailscale"

tailscaled_running() {
  sudo tailscale status >/dev/null 2>&1
}

start_tailscaled_manually() {
  warn "Starting tailscaled manually..."
  sudo mkdir -p /var/run/tailscale /var/lib/tailscale /var/cache/tailscale

  # Kill any stale instance first
  sudo pkill -9 tailscaled 2>/dev/null || true
  sleep 2

  # Explicitly set socket path so it is always predictable
  sudo tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    --port=41641 \
    > /tmp/tailscaled.log 2>&1 &

  TAILSCALED_PID=$!
  log "tailscaled launched (PID: $TAILSCALED_PID)"

  # Brief local wait so the socket likely exists before the auth section polls
  for i in $(seq 1 5); do
    [[ -S "/var/run/tailscale/tailscaled.sock" ]] && return 0
    sleep 1
  done
  # Not an error here — the auth section will keep polling up to 30s
  warn "Socket not yet visible after 5s — auth section will keep waiting..."
}

if [[ "$DISTRO" == "macos" ]]; then
  sudo brew services start tailscale 2>/dev/null || true
  log "Tailscale daemon started via brew services"
else
  # Detect whether systemd is actually functional (not just installed)
  SYSTEMD_RUNNING=false
  if command -v systemctl &>/dev/null; then
    # is-system-running exits non-zero in containers even if binary exists
    if systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; then
      SYSTEMD_RUNNING=true
    fi
  fi

  if $SYSTEMD_RUNNING; then
    warn "systemd detected — attempting to start tailscaled via systemctl..."
    sudo systemctl enable --now tailscaled 2>/dev/null || true

    # Give systemd a moment, then verify the daemon is actually up.
    # In GitHub Codespaces systemctl can claim success but never start the daemon.
    sleep 3
    if ! tailscaled_running; then
      warn "systemd reported success but daemon is not responding — falling back to manual start"
      start_tailscaled_manually
      # give manual start a bit more time
      sleep 2
      if ! tailscaled_running; then
        warn "manual start failed; see /tmp/tailscaled.log for clues"
      fi
    else
      log "Tailscale daemon started via systemd"
    fi
  else
    start_tailscaled_manually
  fi

fi

# ── Authenticate to Tailscale ─────────────────────────────────────────────────
section "Authenticating to Tailscale"

_tailscale_up() {
  local output
  output=$(sudo tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-routes 2>&1) || true
  # Extract auth URL if present
  AUTH_URL=$(echo "$output" | grep -oE 'https://login\.tailscale\.com/[^ ]+' | head -1 || true)
  echo "$output"
}

AUTH_URL=""

if tailscale status &>/dev/null 2>&1; then
  CURRENT_STATUS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState',''))" 2>/dev/null || echo "unknown")
  if [[ "$CURRENT_STATUS" == "Running" ]]; then
    log "Already authenticated to Tailscale"
  else
    _tailscale_up
    [[ -z "$AUTH_URL" ]] && log "Tailscale authenticated"
  fi
else
  _tailscale_up
  [[ -z "$AUTH_URL" ]] && log "Tailscale authenticated"
fi

# Verify we got an IP
sleep 2
THIS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
if [[ "$THIS_IP" == "unknown" ]]; then
  warn "Could not get Tailscale IP — auth may have failed. Check: sudo tailscale status"
else
  log "This machine's Tailscale IP: $THIS_IP"
fi

# ── Generate SSH key if needed ────────────────────────────────────────────────
section "SSH Key Setup"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ -f "$SSH_KEY_PATH" ]]; then
  log "SSH key already exists at $SSH_KEY_PATH"
else
  ssh-keygen -t ed25519 -C "$(hostname)-remote-$(date +%Y%m%d)" -f "$SSH_KEY_PATH" -N ""
  log "SSH key generated at $SSH_KEY_PATH"
fi

PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
log "Public key: $PUBLIC_KEY"

echo ""
warn "╔══════════════════════════════════════════════════════════════╗"
warn "║  ACTION REQUIRED — Add this public key to your Mac Mini:    ║"
warn "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Run this on your Mac Mini:"
echo ""
echo -e "  ${GREEN}echo \"$PUBLIC_KEY\" >> ~/.ssh/authorized_keys${NC}"
echo ""
echo "  Or from this machine (if you can still auth with password):"
echo ""
echo -e "  ${GREEN}ssh-copy-id -i ${SSH_KEY_PATH}.pub ${MAC_MINI_USER}@${MAC_MINI_TAILSCALE_IP}${NC}"
echo ""

read -r -p "Press ENTER once you've added the public key to Mac Mini..."

# ── Test SSH connection ───────────────────────────────────────────────────────
section "Testing SSH Connection"

if ssh -o StrictHostKeyChecking=no \
       -o ConnectTimeout=10 \
       -i "$SSH_KEY_PATH" \
       "${MAC_MINI_USER}@${MAC_MINI_TAILSCALE_IP}" \
       "echo 'SSH_OK'" 2>/dev/null | grep -q "SSH_OK"; then
  log "SSH connection to Mac Mini successful!"
else
  error "SSH connection failed. Check:\n  1. Mac Mini has Remote Login enabled (System Settings → Sharing)\n  2. Public key was added to ~/.ssh/authorized_keys on Mac Mini\n  3. Tailscale is connected on Mac Mini (run: tailscale status)"
fi

# ── Write SSH config ──────────────────────────────────────────────────────────
section "Writing SSH Config"

# Remove existing mac-mini block if present
if [[ -f "$SSH_CONFIG_PATH" ]]; then
  # Backup existing config
  cp "$SSH_CONFIG_PATH" "${SSH_CONFIG_PATH}.bak"
  # Remove old mac-mini block
  python3 - <<'PYEOF'
import re, os
path = os.path.expanduser("~/.ssh/config")
with open(path) as f:
    content = f.read()
# Remove block between "# BEGIN mac-mini" and "# END mac-mini"
content = re.sub(r'# BEGIN mac-mini.*?# END mac-mini\n', '', content, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(content)
PYEOF
fi

cat >> "$SSH_CONFIG_PATH" <<EOF

# BEGIN mac-mini
Host mac-mini
  HostName ${MAC_MINI_TAILSCALE_IP}
  User ${MAC_MINI_USER}
  IdentityFile ${SSH_KEY_PATH}
  ServerAliveInterval 60
  ServerAliveCountMax 3
  # Port forwards — active when connected
  LocalForward ${VNC_LOCAL_PORT} 127.0.0.1:${VNC_REMOTE_PORT}
  LocalForward ${OLLAMA_LOCAL_PORT} 127.0.0.1:${OLLAMA_REMOTE_PORT}
  LocalForward ${WEBUI_LOCAL_PORT} 127.0.0.1:${WEBUI_REMOTE_PORT}
# END mac-mini
EOF

chmod 600 "$SSH_CONFIG_PATH"
log "SSH config written to $SSH_CONFIG_PATH"

# ── Install VNC viewer (Linux only) ──────────────────────────────────────────
section "VNC Client Setup"

if [[ "$DISTRO" == "debian" ]]; then
  if ! command -v xtightvncviewer &>/dev/null && ! command -v vncviewer &>/dev/null; then
    warn "Installing TigerVNC viewer..."
    sudo apt-get install -y tigervnc-viewer 2>/dev/null || \
    sudo apt-get install -y xtightvncviewer 2>/dev/null || \
    warn "Could not install VNC viewer automatically — install manually: sudo apt install tigervnc-viewer"
  else
    log "VNC viewer already installed"
  fi
elif [[ "$DISTRO" == "macos" ]]; then
  log "macOS has built-in VNC (Screen Sharing) — no install needed"
elif [[ "$DISTRO" == "rhel" ]]; then
  sudo yum install -y tigervnc 2>/dev/null || warn "Install VNC manually: sudo yum install tigervnc"
fi

# ── Create helper scripts ─────────────────────────────────────────────────────
section "Creating Helper Scripts"

# Scripts go into the workspace root so they are visible and easy to find.
# In Codespaces this is /workspaces/<repo>; elsewhere it falls back to $HOME.
if [[ -n "${CODESPACES:-}" ]] && [[ -d "/workspaces" ]]; then
  SCRIPTS_DIR="/workspaces/mac-mini"
elif [[ -n "${GITHUB_WORKSPACE:-}" ]] && [[ -d "$GITHUB_WORKSPACE" ]]; then
  SCRIPTS_DIR="${GITHUB_WORKSPACE}/mac-mini"
else
  SCRIPTS_DIR="$HOME/mac-mini"
fi
mkdir -p "$SCRIPTS_DIR"
log "Helper scripts will be created in: $SCRIPTS_DIR"

# ── tunnel.sh ────────────────────────────────────────────────────────────────
cat > "$SCRIPTS_DIR/tunnel.sh" <<SCRIPT
#!/usr/bin/env bash
# Opens all SSH tunnels to Mac Mini without an interactive shell.
# Leave this running in a terminal — Ctrl+C closes all tunnels.
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
echo -e "\n\${BLUE}Opening tunnels to Mac Mini...\${NC}"
echo -e "  \${GREEN}VNC (screen):  \${NC}localhost:${VNC_LOCAL_PORT}    →  mac-mini:${VNC_REMOTE_PORT}"
echo -e "  \${GREEN}Ollama:        \${NC}localhost:${OLLAMA_LOCAL_PORT}  →  mac-mini:${OLLAMA_REMOTE_PORT}"
echo -e "  \${GREEN}Open WebUI:    \${NC}localhost:${WEBUI_LOCAL_PORT}   →  mac-mini:${WEBUI_REMOTE_PORT}"
echo ""
echo "Press Ctrl+C to close all tunnels."
echo ""
ssh -N mac-mini
SCRIPT

# ── vnc.sh ───────────────────────────────────────────────────────────────────
# NOTE: VNC from a headless environment like Codespaces requires forwarding the
# tunnel port back to your local machine first (see guide printed at the end).
cat > "$SCRIPTS_DIR/vnc.sh" <<SCRIPT
#!/usr/bin/env bash
# Opens a VNC-only SSH tunnel to Mac Mini.
# In Codespaces: forward port ${VNC_LOCAL_PORT} in the Ports panel, then open
# a VNC client on your local machine pointing to localhost:${VNC_LOCAL_PORT}.
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
echo -e "\${GREEN}Opening VNC tunnel to Mac Mini on localhost:${VNC_LOCAL_PORT}...\${NC}"

# Kill any previous tunnel on this port
fuser -k ${VNC_LOCAL_PORT}/tcp 2>/dev/null || true

ssh -f -N -L ${VNC_LOCAL_PORT}:127.0.0.1:${VNC_REMOTE_PORT} mac-mini
sleep 1

if [[ "\$(uname)" == "Darwin" ]]; then
  echo -e "\${GREEN}Launching macOS Screen Sharing...\${NC}"
  open vnc://localhost:${VNC_LOCAL_PORT}
elif command -v vncviewer &>/dev/null; then
  vncviewer localhost:${VNC_LOCAL_PORT}
elif command -v xtightvncviewer &>/dev/null; then
  xtightvncviewer localhost:${VNC_LOCAL_PORT}
else
  echo -e "\${YELLOW}Tunnel is open.\${NC}"
  echo "No VNC client found locally. Connect your VNC client to:"
  echo "  localhost:${VNC_LOCAL_PORT}"
  echo ""
  echo "In Codespaces: open the Ports panel (Ctrl+Shift+P → 'Ports: Focus on Ports View'),"
  echo "forward port ${VNC_LOCAL_PORT}, then open the forwarded address in a VNC client."
fi
SCRIPT

# ── status.sh ────────────────────────────────────────────────────────────────
cat > "$SCRIPTS_DIR/status.sh" <<SCRIPT
#!/usr/bin/env bash
# Checks Tailscale, SSH reachability, and open tunnel ports.
GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "\n\${BLUE}=== Tailscale Status ===\${NC}"
tailscale status 2>/dev/null || echo -e "\${RED}Tailscale not running\${NC}"

echo -e "\n\${BLUE}=== SSH Connection Test ===\${NC}"
if ssh -o ConnectTimeout=5 -o BatchMode=yes mac-mini "echo 'reachable'" &>/dev/null; then
  echo -e "\${GREEN}Mac Mini is reachable via SSH ✓\${NC}"
else
  echo -e "\${RED}Mac Mini not reachable ✗\${NC}"
  echo "Check: tailscale status | grep mac-mini"
fi

echo -e "\n\${BLUE}=== Open Tunnel Ports ===\${NC}"
for port in ${VNC_LOCAL_PORT} ${OLLAMA_LOCAL_PORT} ${WEBUI_LOCAL_PORT}; do
  if ss -tlnp 2>/dev/null | grep -q ":\${port} " || \
     lsof -i ":\${port}" 2>/dev/null | grep -q LISTEN; then
    echo -e "  \${GREEN}\${port} OPEN ✓\${NC}"
  else
    echo -e "  \${RED}\${port} closed\${NC}"
  fi
done
echo ""
SCRIPT

chmod +x "$SCRIPTS_DIR/tunnel.sh" "$SCRIPTS_DIR/vnc.sh" "$SCRIPTS_DIR/status.sh"
log "Helper scripts created in $SCRIPTS_DIR/"

# ── Install noVNC on Mac Mini (browser-based VNC) ────────────────────────────
section "Setting Up Browser VNC (noVNC) on Mac Mini"

NOVNC_PORT=6080

# Run the noVNC install+start over SSH on the Mac Mini
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "${MAC_MINI_USER}@${MAC_MINI_TAILSCALE_IP}" bash << 'REMOTE'
set -euo pipefail

NOVNC_PORT=6080
NOVNC_DIR="$HOME/.novnc"

# Install noVNC if not present
if [[ ! -d "$NOVNC_DIR" ]]; then
  echo "[→] Cloning noVNC..."
  git clone --depth 1 https://github.com/novnc/noVNC.git "$NOVNC_DIR"
  git clone --depth 1 https://github.com/novnc/websockify.git "$NOVNC_DIR/utils/websockify"
  echo "[✓] noVNC installed at $NOVNC_DIR"
else
  echo "[✓] noVNC already installed at $NOVNC_DIR"
fi

# Make sure Screen Sharing (VNC) is enabled
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

# Kill any existing noVNC/websockify on this port
pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
sleep 1

# Start noVNC — websockify bridges HTTP→VNC
nohup "$NOVNC_DIR/utils/novnc_proxy" \
  --vnc localhost:5900 \
  --listen ${NOVNC_PORT} \
  > /tmp/novnc.log 2>&1 &

echo "[✓] noVNC started on port ${NOVNC_PORT} (log: /tmp/novnc.log)"
REMOTE

log "noVNC is running on Mac Mini port ${NOVNC_PORT}"

# ── Open SSH tunnel for noVNC port ────────────────────────────────────────────
section "Opening Browser VNC Tunnel"

# Kill any stale tunnel on this port first
fuser -k "${NOVNC_PORT}/tcp" 2>/dev/null || true
sleep 1

# Open the tunnel in the background
ssh -f -N \
  -L "${NOVNC_PORT}:127.0.0.1:${NOVNC_PORT}" \
  -L "${VNC_LOCAL_PORT}:127.0.0.1:${VNC_REMOTE_PORT}" \
  -L "${OLLAMA_LOCAL_PORT}:127.0.0.1:${OLLAMA_REMOTE_PORT}" \
  -L "${WEBUI_LOCAL_PORT}:127.0.0.1:${WEBUI_REMOTE_PORT}" \
  -i "$SSH_KEY_PATH" \
  mac-mini

log "All tunnels open"

# ── Expose the noVNC port in Codespaces ───────────────────────────────────────
IN_CODESPACES=false
[[ -n "${CODESPACES:-}" ]] && IN_CODESPACES=true

if $IN_CODESPACES; then
  section "Exposing Ports in Codespaces"

  # Use gh CLI to make port public so it opens in the browser
  # (requires gh CLI which is pre-installed in all Codespaces)
  if command -v gh &>/dev/null; then
    gh codespace ports visibility "${NOVNC_PORT}:public" 2>/dev/null && \
      log "Port ${NOVNC_PORT} set to public in Codespaces" || \
      warn "Could not set port visibility via gh — forward manually in the Ports panel"
  fi

  # Derive the Codespaces forwarded URL
  # Format: https://<codespace-name>-<port>.app.github.dev
  CODESPACE_NAME="${CODESPACE_NAME:-$(hostname)}"
  BROWSER_URL="https://${CODESPACE_NAME}-${NOVNC_PORT}.app.github.dev/vnc.html?autoconnect=true&resize=scale"
else
  BROWSER_URL="http://localhost:${NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale"
fi

# ── Update the vnc.sh helper to use noVNC ────────────────────────────────────
cat > "$SCRIPTS_DIR/vnc.sh" << SCRIPT
#!/usr/bin/env bash
# Opens browser-based VNC (noVNC) to Mac Mini.
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

NOVNC_PORT=${NOVNC_PORT}
BROWSER_URL="${BROWSER_URL}"

echo -e "\${BLUE}Ensuring noVNC tunnel is open on port \${NOVNC_PORT}...\${NC}"
fuser -k "\${NOVNC_PORT}/tcp" 2>/dev/null || true
sleep 1
ssh -f -N -L "\${NOVNC_PORT}:127.0.0.1:\${NOVNC_PORT}" mac-mini
sleep 1

echo -e "\${GREEN}Opening Mac Mini desktop in your browser...\${NC}"
echo "  URL: \${BROWSER_URL}"
echo ""

if [[ "\$(uname)" == "Darwin" ]]; then
  open "\${BROWSER_URL}"
elif command -v xdg-open &>/dev/null; then
  xdg-open "\${BROWSER_URL}"
else
  echo "Open this URL in your browser:"
  echo "  \${BROWSER_URL}"
fi
SCRIPT
chmod +x "$SCRIPTS_DIR/vnc.sh"

# ── Final summary ─────────────────────────────────────────────────────────────
section "Setup Complete"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Mac Mini is ready — open in your browser!           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}── Open Mac Mini desktop in browser ───────────────────────────${NC}"
echo ""
echo -e "    ${GREEN}${BROWSER_URL}${NC}"
echo ""

if $IN_CODESPACES; then
echo -e "${YELLOW}  Codespaces note:${NC}"
echo "  If the URL above gives a 404, VS Code may not have registered"
echo "  the port yet. Do this once:"
echo ""
echo "    1. Open Ports panel: Ctrl+Shift+P → 'Ports: Focus on Ports View'"
echo "    2. Click '+ Forward a Port' → enter: ${NOVNC_PORT}"
echo "    3. Right-click the forwarded port → 'Open in Browser'"
echo "    4. Or copy the HTTPS URL shown in the Ports panel"
echo ""
fi

echo -e "${BLUE}── Other ports (tunnel already open) ──────────────────────────${NC}"
echo "    Ollama API:   http://localhost:${OLLAMA_LOCAL_PORT}"
echo "    Open WebUI:   http://localhost:${WEBUI_LOCAL_PORT}"
echo "    Raw VNC:      localhost:${VNC_LOCAL_PORT}  (for native VNC clients)"
echo ""
echo -e "${BLUE}── SSH ─────────────────────────────────────────────────────────${NC}"
echo "    ssh mac-mini"
echo ""
echo -e "${BLUE}── Helper scripts ──────────────────────────────────────────────${NC}"
echo "    $SCRIPTS_DIR/tunnel.sh   — reopen all tunnels"
echo "    $SCRIPTS_DIR/vnc.sh      — reopen browser VNC"
echo "    $SCRIPTS_DIR/status.sh   — check connectivity"
echo ""

# ── Auth URL reminder (shown last if browser auth is required) ────────────────
if [[ -n "$AUTH_URL" ]]; then
  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ACTION REQUIRED — Tailscale needs browser authentication!  ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Visit this URL to authenticate this machine with Tailscale:"
  echo ""
  echo -e "  ${GREEN}${AUTH_URL}${NC}"
  echo ""
  echo -e "  After authenticating, re-run: ${BLUE}ssh mac-mini${NC}"
  echo ""
fi