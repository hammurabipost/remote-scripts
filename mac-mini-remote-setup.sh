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

# ── Install Tailscale ─────────────────────────────────────────────────────────
section "Installing Tailscale"

if command -v tailscale &>/dev/null; then
  log "Tailscale already installed — $(tailscale version | head -1)"
else
  case "$DISTRO" in
    debian)
      curl -fsSL https://tailscale.com/install.sh | sh
      ;;
    rhel)
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

if [[ "$DISTRO" == "macos" ]]; then
  sudo brew services start tailscale 2>/dev/null || true
else
  # GitHub Codespaces / containers don't have systemd — use tailscaled directly
  if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
    sudo systemctl enable --now tailscaled
    log "Tailscale daemon started via systemd"
  else
    warn "No systemd detected (likely a container) — starting tailscaled manually"
    sudo mkdir -p /var/run/tailscale /var/lib/tailscale /var/cache/tailscale
    sudo tailscaled --state=/var/lib/tailscale/tailscaled.state \
                    --socket=/var/run/tailscale/tailscaled.sock \
                    --port=41641 \
                    > /tmp/tailscaled.log 2>&1 &
    sleep 3
    log "tailscaled started in background (PID: $!)"
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

sleep 2
THIS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
log "This machine's Tailscale IP: $THIS_IP"

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

SCRIPTS_DIR="$HOME/.mac-mini"
mkdir -p "$SCRIPTS_DIR"

# tunnel-only.sh — open all tunnels without interactive shell
cat > "$SCRIPTS_DIR/tunnel.sh" <<SCRIPT
#!/usr/bin/env bash
# Opens all SSH tunnels to Mac Mini (no interactive shell)
echo "Opening tunnels to Mac Mini..."
echo "  VNC:    localhost:${VNC_LOCAL_PORT}"
echo "  Ollama: localhost:${OLLAMA_LOCAL_PORT}"
echo "  WebUI:  localhost:${WEBUI_LOCAL_PORT}"
echo ""
echo "Press Ctrl+C to close all tunnels"
ssh -N mac-mini
SCRIPT

# vnc.sh — open tunnel + launch VNC viewer
cat > "$SCRIPTS_DIR/vnc.sh" <<SCRIPT
#!/usr/bin/env bash
# Opens VNC tunnel and launches viewer
echo "Opening VNC tunnel to Mac Mini..."
ssh -f -N -L ${VNC_LOCAL_PORT}:127.0.0.1:${VNC_REMOTE_PORT} mac-mini
sleep 1

if [[ "\$(uname)" == "Darwin" ]]; then
  open vnc://localhost:${VNC_LOCAL_PORT}
elif command -v vncviewer &>/dev/null; then
  vncviewer localhost:${VNC_LOCAL_PORT}
elif command -v xtightvncviewer &>/dev/null; then
  xtightvncviewer localhost:${VNC_LOCAL_PORT}
else
  echo "VNC tunnel is open at localhost:${VNC_LOCAL_PORT}"
  echo "Connect with your VNC client to: localhost:${VNC_LOCAL_PORT}"
fi
SCRIPT

# status.sh — check connectivity
cat > "$SCRIPTS_DIR/status.sh" <<SCRIPT
#!/usr/bin/env bash
echo "=== Tailscale Status ==="
tailscale status 2>/dev/null || echo "Tailscale not running"
echo ""
echo "=== SSH Connection Test ==="
ssh -o ConnectTimeout=5 -o BatchMode=yes mac-mini "echo 'Mac Mini reachable ✓'" 2>/dev/null || echo "Mac Mini not reachable ✗"
echo ""
echo "=== Open Tunnels ==="
ss -tlnp 2>/dev/null | grep -E "${VNC_LOCAL_PORT}|${OLLAMA_LOCAL_PORT}|${WEBUI_LOCAL_PORT}" || \
lsof -i ":${VNC_LOCAL_PORT}" -i ":${OLLAMA_LOCAL_PORT}" -i ":${WEBUI_LOCAL_PORT}" 2>/dev/null || \
echo "No tunnels currently open"
SCRIPT

chmod +x "$SCRIPTS_DIR/tunnel.sh" "$SCRIPTS_DIR/vnc.sh" "$SCRIPTS_DIR/status.sh"
log "Helper scripts created in $SCRIPTS_DIR/"

# ── Final summary ─────────────────────────────────────────────────────────────
section "Setup Complete"

echo ""
echo -e "${GREEN}Everything is configured. Here's how to use it:${NC}"
echo ""
echo -e "  ${BLUE}SSH into Mac Mini:${NC}"
echo "    ssh mac-mini"
echo ""
echo -e "  ${BLUE}Open all tunnels (VNC + Ollama + WebUI):${NC}"
echo "    ~/.mac-mini/tunnel.sh"
echo ""
echo -e "  ${BLUE}Open VNC (screen sharing):${NC}"
echo "    ~/.mac-mini/vnc.sh"
echo "    Then open:  vnc://localhost:${VNC_LOCAL_PORT}  in your VNC client"
echo ""
echo -e "  ${BLUE}Check connectivity status:${NC}"
echo "    ~/.mac-mini/status.sh"
echo ""
echo -e "  ${BLUE}Ports available after tunnel is open:${NC}"
echo "    VNC (screen):  localhost:${VNC_LOCAL_PORT}"
echo "    Ollama:        localhost:${OLLAMA_LOCAL_PORT}"
echo "    Open WebUI:    localhost:${WEBUI_LOCAL_PORT}"
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