### How to use it

**Step 1 — Get a Tailscale auth key** (one-time):
> https://login.tailscale.com/admin/settings/keys → Generate an ephemeral or reusable key

**Step 2 — On the new remote machine** (Codespaces, Linux VM, etc.):

```bash
# Set your config
export TAILSCALE_AUTHKEY=tskey-auth-xxxxxxxx
export MAC_MINI_USER=XXXXX
export MAC_MINI_TAILSCALE_IP=XXX.XXX.XXX.XXX

# Download and run
# curl -O https://your-storage/mac-mini-remote-setup.sh
# or just copy the file, then:
chmod +x mac-mini-remote-setup.sh
./mac-mini-remote-setup.sh
```

**Step 3 — After setup, use the helper scripts it creates:**

```bash
ssh mac-mini              # SSH shell
~/.mac-mini/tunnel.sh     # All tunnels open (VNC + Ollama + WebUI)
~/.mac-mini/vnc.sh        # VNC directly
~/.mac-mini/status.sh     # Check everything is working
```

The script handles: Tailscale install + auth, SSH key generation, SSH config writing, VNC viewer install (on Linux), and creates the three helper scripts automatically. It also detects whether it's running in a container (like Codespaces) without systemd, and starts `tailscaled` manually in that case.