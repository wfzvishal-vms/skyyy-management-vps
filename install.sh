#!/usr/bin/env bash
set -Eeuo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
log(){ echo -e "${CYAN}[SKYYY]${NC} $*"; }; ok(){ echo -e "${GREEN}[ OK ]${NC} $*"; }; warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }; die(){ echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
trap 'echo -e "${RED}[FAIL] Line $LINENO${NC}"' ERR

clear
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
   ███████╗██╗  ██╗██╗   ██╗██╗   ██╗██╗   ██╗
   ██╔════╝██║ ██╔╝╚██╗ ██╔╝╚██╗ ██╔╝╚██╗ ██╔╝
   ███████╗█████╔╝  ╚████╔╝  ╚████╔╝  ╚████╔╝
   ╚════██║██╔═██╗   ╚██╔╝    ╚██╔╝    ╚██╔╝
   ███████║██║  ██╗   ██║      ██║      ██║
   ╚══════╝╚═╝  ╚═╝   ╚═╝      ╚═╝      ╚═╝
      MANAGEMENT VPS • Deploy. Manage. Scale.
EOF
echo -e "${NC}"

[[ $EUID -eq 0 ]] || die "Root chahiye: sudo bash ..."
[[ -f /etc/os-release ]] || die "Unsupported OS"
. /etc/os-release
case "$ID" in ubuntu|debian) ok "OS: $PRETTY_NAME" ;; *) die "Ubuntu/Debian only. Tera: $ID" ;; esac

SKYYY_DIR="${SKYYY_DIR:-/opt/skyyy}"
SKYYY_USER="${SKYYY_USER:-skyyy}"
PANEL_PORT="${PANEL_PORT:-3000}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"

# ✅ REPO URL FIXED
REPO_URL="${REPO_URL:-https://github.com/wfzvishal-vms/skyyy-management-vps.git}"

# 1. Base packages
log "[1/12] Base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git ca-certificates gnupg lsb-release software-properties-common apt-transport-https ufw jq openssl unzip tar htop net-tools iproute2 iptables build-essential python3 rsync cron fail2ban >/dev/null
ok "Base ready"

# 2. Docker
if command -v docker &>/dev/null; then ok "Docker already installed"; else
  log "[2/12] Docker install..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker
  ok "Docker installed"
fi

# 3. LXD / LXC
if command -v lxd &>/dev/null || snap list lxd &>/dev/null 2>&1; then ok "LXD already installed"; else
  log "[3/12] LXD/LXC install..."
  if [[ "$ID" == "ubuntu" ]]; then snap install lxd >/dev/null 2>&1 || apt-get install -y -qq lxd >/dev/null
  else apt-get install -y -qq lxd >/dev/null 2>&1 || { apt-get install -y -qq snapd >/dev/null; systemctl enable --now snapd.socket; snap install lxd >/dev/null 2>&1; }; fi
  ok "LXD installed"
fi
lxd profile list &>/dev/null || lxd init --auto >/dev/null 2>&1 || warn "LXD init skip"

# 4. Node.js
if command -v node &>/dev/null && [[ "$(node -v | cut -dv -f2 | cut -d. -f1)" -ge 18 ]]; then ok "Node $(node -v)"; else
  log "[4/12] Node.js 20 install..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
  ok "Node $(node -v)"
fi
command -v pnpm &>/dev/null || npm i -g pnpm >/dev/null 2>&1
command -v pm2 &>/dev/null || npm i -g pm2 >/dev/null 2>&1
ok "pnpm + pm2 ready"

# 5. Tailscale host (for funnel key)
if ! command -v tailscale &>/dev/null; then
  log "[5/12] Tailscale install (host)..."
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || warn "Tailscale host install skip"
fi

# 6. System user
id "$SKYYY_USER" &>/dev/null || useradd -m -s /bin/bash "$SKYYY_USER"
usermod -aG docker "$SKYYY_USER" 2>/dev/null || true
usermod -aG lxd "$SKYYY_USER" 2>/dev/null || true

# 7. Clone panel
if [[ -d "$SKYYY_DIR/.git" ]]; then 
  log "[7/12] git pull..."; 
  cd "$SKYYY_DIR" && sudo -u "$SKYYY_USER" git pull --ff-only >/dev/null 2>&1 || warn "git pull skip"
else
  log "[7/12] Clone panel..."
  mkdir -p "$SKYYY_DIR"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$REPO_URL" "$SKYYY_DIR" >/dev/null 2>&1 || die "Clone fail! Check karo repo Public hai ya nahi. URL: $REPO_URL"
  chown -R "$SKYYY_USER:$SKYYY_USER" "$SKYYY_DIR"
fi
cd "$SKYYY_DIR"

# 8. .env
if [[ ! -f .env ]]; then
  log "[8/12] .env generate..."
  JWT=$(openssl rand -hex 32); DBP=$(openssl rand -base64 24 | tr -d '/+=')
  cat > .env <<EOF
NODE_ENV=production
PORT=$PANEL_PORT
APP_NAME="SKYYY MANAGEMENT VPS"
JWT_SECRET=$JWT
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=skyyy
DB_USER=skyyy
DB_PASS=$DBP
ADMIN_USER=admin
ADMIN_PASS=$(openssl rand -base64 12 | tr -d '/+=')
TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY:-}
EOF
  chown "$SKYYY_USER:$SKYYY_USER" .env && chmod 600 .env
  ok ".env ready"
fi

# 9. Postgres
log "[9/12] Postgres container..."
source .env
docker rm -f skyyy-db &>/dev/null || true
docker run -d --name skyyy-db --restart unless-stopped \
  -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB="$DB_NAME" \
  -p 127.0.0.1:5432:5432 -v skyyy_db_data:/var/lib/postgresql/data postgres:16-alpine >/dev/null
ok "Postgres running"

# 10. Build + start
log "[10/12] Dependencies + build..."
sudo -u "$SKYYY_USER" bash -c "cd $SKYYY_DIR && pnpm install --prod=false" >/dev/null 2>&1 || warn "pnpm install warning"
sudo -u "$SKYYY_USER" bash -c "cd $SKYYY_DIR && pnpm build" >/dev/null 2>&1 || warn "build skip"

log "[11/12] PM2 start..."
sudo -u "$SKYYY_USER" bash -c "cd $SKYYY_DIR && (pm2 delete skyyy 2>/dev/null || true); pm2 start npm --name skyyy -- start; pm2 save" >/dev/null
env PATH=$PATH:/usr/bin pm2 startup systemd -u "$SKYYY_USER" --hp "/home/$SKYYY_USER" >/dev/null 2>&1 || true
ok "Panel running :$PANEL_PORT"

# 12. Firewall + SSL
log "[12/12] Firewall + SSL..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
ufw allow "$PANEL_PORT"/tcp >/dev/null
ufw --force enable >/dev/null

if [[ -n "$PANEL_DOMAIN" ]]; then
  apt-get install -y -qq certbot python3-certbot-nginx nginx >/dev/null
  cat > /etc/nginx/sites-available/skyyy <<EOF
server {
  listen 80; server_name $PANEL_DOMAIN;
  location / {
    proxy_pass http://127.0.0.1:$PANEL_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_read_timeout 86400;
  }
}
EOF
  ln -sf /etc/nginx/sites-available/skyyy /etc/nginx/sites-enabled/skyyy
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >/dev/null && systemctl reload nginx
  certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos --email "admin@$PANEL_DOMAIN" --redirect >/dev/null 2>&1 && ok "SSL installed" || warn "SSL skip"
fi

IP=$(curl -s ifconfig.me || echo "YOUR_IP")
PASS=$(grep ADMIN_PASS .env | cut -d= -f2)
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅  SKYYY MANAGEMENT VPS READY!${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "  Panel:  http://${PANEL_DOMAIN:-$IP}:${PANEL_PORT}"
[[ -n "$PANEL_DOMAIN" ]] && echo -e "  SSL:    https://${PANEL_DOMAIN}"
echo -e "  User:   admin"
echo -e "  Pass:   $PASS"
echo -e ""
echo -e "  Docker: $(docker --version)"
echo -e "  LXD:    $(lxd --version 2>/dev/null || echo ok)"
echo -e "  Node:   $(node -v)"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "  🚀 Deploy. Manage. Scale."
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║      💎  POWERED BY VISHAL EXE  💎     ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
