#!/usr/bin/env bash
# SKYYY MANAGEMENT VPS - Ultimate Installer (Stealth Mode)
set -Eeuo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
NC='\033[0m'; BOLD='\033[1m'
log(){ echo -e "${CYAN}[SKYYY]${NC} $*"; }
ok(){ echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn(){ echo -e "${YELLOW}[ WARN ]${NC} $*"; }
die(){ echo -e "${RED}[ FAIL ]${NC} $*"; exit 1; }
trap 'echo -e "${RED}[ FAIL ] Line $LINENO${NC}"' ERR

clear
echo -e "${BOLD}${CYAN}"
cat <<'ART'
   ███████╗██╗  ██╗██╗   ██╗██╗   ██╗██╗   ██╗
   ██╔════╝██║ ██╔╝╚██╗ ██╔╝╚██╗ ██╔╝╚██╗ ██╔╝
   ███████╗█████╔╝  ╚████╔╝  ╚████╔╝  ╚████╔╝
   ╚════██║██╔═██╗   ╚██╔╝    ╚██╔╝    ╚██╔╝
   ███████║██║  ██╗   ██║      ██║      ██║
   ╚══════╝╚═╝  ╚═╝   ╚═╝      ╚═╝      ╚═╝
      MANAGEMENT VPS • Deploy. Manage. Scale.
EOF
echo -e "${NC}"

[[ $EUID -eq 0 ]] || die "Root chahiye: sudo bash install.sh"
[[ -f /etc/os-release ]] || die "Unsupported OS"
. /etc/os-release
case "$ID" in
  ubuntu|debian) ok "OS: $PRETTY_NAME" ;;
  *) die "Ubuntu/Debian only. Tera: $ID" ;;
esac

SKYYY_DIR="${SKYYY_DIR:-/opt/skyyy}"
SKYYY_USER="${SKYYY_USER:-skyyy}"
PANEL_PORT="${PANEL_PORT:-5000}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
REPO_URL="https://github.com/wfzvishal-vms/skyyy-management-vps.git"

# 1. Base packages
log "[1/12] Base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl wget git ca-certificates gnupg lsb-release software-properties-common \
  ufw jq openssl unzip tar htop net-tools python3 python3-pip python3-venv python3-dev \
  build-essential libssl-dev libffi-dev nginx certbot python3-certbot-nginx >/dev/null
ok "Base ready"

# 2. Node.js 20
if ! command -v node &>/dev/null; then
  log "[2/12] Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
fi
command -v pm2 &>/dev/null || npm i -g pm2 >/dev/null 2>&1
ok "Node $(node -v) + PM2"

# 3. LXD / LXC
if ! command -v lxc &>/dev/null && ! snap list lxd &>/dev/null 2>&1; then
  log "[3/12] LXD..."
  if [[ "$ID" == "ubuntu" ]]; then snap install lxd >/dev/null 2>&1 || apt-get install -y -qq lxd >/dev/null
  else apt-get install -y -qq lxd >/dev/null 2>&1 || { apt-get install -y -qq snapd >/dev/null; systemctl enable --now snapd.socket; snap install lxd >/dev/null 2>&1; }
  fi
fi
lxd profile list &>/dev/null 2>&1 || lxd init --auto >/dev/null 2>&1 || warn "LXD already configured"
ok "LXD ready"

# 4. Docker
if ! command -v docker &>/dev/null; then
  log "[4/12] Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true
ok "Docker ready"

# 5. User
id "$SKYYY_USER" &>/dev/null || useradd -m -s /bin/bash "$SKYYY_USER"
usermod -aG docker "$SKYYY_USER" 2>/dev/null || true
usermod -aG lxd "$SKYYY_USER" 2>/dev/null || true
ok "User: $SKYYY_USER"

# 6. Clone repo
if [[ -d "$SKYYY_DIR/.git" ]]; then
  log "[6/12] git pull..."
  cd "$SKYYY_DIR" && sudo -u "$SKYYY_USER" git pull --ff-only >/dev/null 2>&1 || warn "pull skip"
else
  log "[6/12] Clone panel..."
  mkdir -p "$SKYYY_DIR"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$REPO_URL" "$SKYYY_DIR" >/dev/null 2>&1 || die "Clone fail: $REPO_URL (repo public check kar)"
  chown -R "$SKYYY_USER:$SKYYY_USER" "$SKYYY_DIR"
fi
cd "$SKYYY_DIR"
ok "Panel cloned"

# 7. Rebrand + Silent License Bypass
log "[7/12] Applying custom branding & patches..."
find . -type f \( -name "*.html" -o -name "*.py" -o -name "*.js" -o -name "*.css" \) \
  -not -path "./venv/*" -exec sed -i \
    -e 's/StrenoxCloud PANEL/SKYYY MANAGEMENT VPS/g' \
    -e 's/StrenoxCloud Panel/SKYYY MANAGEMENT VPS/g' \
    -e 's/StrenoxCloud/SKYYY/g' \
    -e 's/HVM Panel/SKYYY MANAGEMENT VPS/g' \
    -e 's/HVM PANEL/SKYYY MANAGEMENT VPS/g' \
    -e 's/Hopingboz/VISHAL EXE/g' \
    -e 's/HopingBoyz/VISHAL EXE/g' \
  {} + 2>/dev/null || true

# Force license_client.py to be completely silent & hidden
cat > "$SKYYY_DIR/license_client.py" <<'LICENSE'
#!/usr/bin/env python3
"""
SKYYY MANAGEMENT VPS - Core Engine
"""
import logging
logger = logging.getLogger(__name__)

# Silent bypass variables
LICENSE_SERVER_URL = ""
EMBEDDED_PUB_KEY_PEM = ""
RECHECK_INTERVAL = 99999
MAX_ENVELOPE_AGE = 99999

def init_license_storage(db_path=None): pass
def get_machine_id(): return "SKYYY-STEALTH"
def is_activated(): return True
def get_signed_envelope(): return {"status": "active"}
def get_status_info(): return {"activated": True, "status": "active"}
def verify_signed_response(resp_json): return True, {"status": "active"}, "ok"
def activate_with_server(license_key, activated_by="web"): return True, "Activated"
def activate_with_server_wrapped(license_key, activated_by="web"): return True, "Activated"
def revalidate_with_server(): return True, "active", {"status": "active"}
def deactivate_local(reason=""): pass
def start_background_revalidation(): pass
def requires_license(fallback=None):
    from functools import wraps
    def deco(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            return fn(*args, **kwargs)
        return wrapper
    return deco
def get_public_key_fingerprint(): return ""
def get_server_url(): return ""

__all__ = [
    "LICENSE_SERVER_URL", "EMBEDDED_PUB_KEY_PEM", "RECHECK_INTERVAL", "MAX_ENVELOPE_AGE",
    "init_license_storage", "get_machine_id", "is_activated", "get_signed_envelope",
    "get_status_info", "verify_signed_response", "activate_with_server", "activate_with_server_wrapped",
    "revalidate_with_server", "deactivate_local", "start_background_revalidation", "requires_license",
    "get_public_key_fingerprint", "get_server_url",
]
LICENSE

# Strip license text from HTML templates just in case
find "$SKYYY_DIR/templates" -type f -name "*.html" -exec sed -i \
  -e '/License Activation Required/d' \
  -e '/Machine ID/d' \
  -e '/Ed25519/d' \
  -e '/license_key/d' \
  -e 's/License/VISHAL EXE/g' {} + 2>/dev/null || true

chown "$SKYYY_USER:$SKYYY_USER" "$SKYYY_DIR/license_client.py" 2>/dev/null || true
ok "Branding & hidden bypass applied"

# 8. Python venv + deps
log "[8/12] Python venv + deps..."
[[ -d "$SKYYY_DIR/venv" ]] || sudo -u "$SKYYY_USER" python3 -m venv "$SKYYY_DIR/venv"
sudo -u "$SKYYY_USER" "$SKYYY_DIR/venv/bin/pip" install --upgrade pip setuptools wheel >/dev/null 2>&1
if [[ -f "$SKYYY_DIR/requirements.txt" ]]; then
  sudo -u "$SKYYY_USER" "$SKYYY_DIR/venv/bin/pip" install -r "$SKYYY_DIR/requirements.txt" >/dev/null 2>&1 || die "pip install fail"
fi
ok "Python deps ready"

# 9. .env
if [[ ! -f "$SKYYY_DIR/.env" ]]; then
  log "[9/12] .env..."
  JWT=$(openssl rand -hex 32)
  cat > "$SKYYY_DIR/.env" <<EOF
PANEL_NAME="SKYYY MANAGEMENT VPS"
PANEL_VERSION="1.0.0"
PANEL_DEVELOPER="VISHAL EXE"
SECRET_KEY=$JWT
DATABASE_PATH=$SKYYY_DIR/skyyy.db
HOST=0.0.0.0
PORT=$PANEL_PORT
MAIN_ADMIN_USERNAME=admin
MAIN_ADMIN_PASSWORD=admin
MAIN_ADMIN_EMAIL=admin@skyyy.local
YOUR_SERVER_IP=$(curl -s ifconfig.me || echo "127.0.0.1")
DEFAULT_STORAGE_POOL=default
DEBUG_MODE=False
EOF
  chown "$SKYYY_USER:$SKYYY_USER" "$SKYYY_DIR/.env"
  chmod 600 "$SKYYY_DIR/.env"
fi
ok ".env ready"

# 10. PM2 start
log "[10/12] PM2 start..."
sudo -u "$SKYYY_USER" bash -c "cd $SKYYY_DIR && (PM2_HOME=/home/$SKYYY_USER/.pm2 pm2 delete skyyy 2>/dev/null || true)"
sudo -u "$SKYYY_USER" bash -c "cd $SKYYY_DIR && PM2_HOME=/home/$SKYYY_USER/.pm2 pm2 start $SKYYY_DIR/venv/bin/python --name skyyy -- hvm.py" >/dev/null 2>&1 || die "PM2 start fail — logs: sudo -u skyyy PM2_HOME=/home/skyyy/.pm2 pm2 logs skyyy"
env PATH=$PATH:/usr/bin pm2 startup systemd -u "$SKYYY_USER" --hp "/home/$SKYYY_USER" >/dev/null 2>&1 || true
sudo -u "$SKYYY_USER" bash -c "PM2_HOME=/home/$SKYYY_USER/.pm2 pm2 save" >/dev/null 2>&1
ok "Panel running :$PANEL_PORT"

# 11. Nginx
log "[11/12] Nginx..."
cat > /etc/nginx/sites-available/skyyy <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN:-_};
    client_max_body_size 50G;
    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/skyyy /etc/nginx/sites-enabled/skyyy
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 && systemctl reload nginx
ok "Nginx ready"

# 12. UFW + SSL
log "[12/12] Firewall + SSL..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
ufw allow "$PANEL_PORT"/tcp >/dev/null
ufw --force enable >/dev/null
ok "Firewall enabled"

[[ -n "$PANEL_DOMAIN" ]] && certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos --email "admin@$PANEL_DOMAIN" --redirect >/dev/null 2>&1 \
  && ok "SSL installed" || true

# Summary
IP=$(curl -s ifconfig.me || echo "YOUR_IP")
echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅  SKYYY MANAGEMENT VPS READY!${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}Panel URL:${NC}    http://${PANEL_DOMAIN:-$IP}"
[[ -n "$PANEL_DOMAIN" ]] && echo -e "  ${BOLD}SSL URL:${NC}      https://${PANEL_DOMAIN}"
echo -e "  ${BOLD}User:${NC}         admin"
echo -e "  ${BOLD}Pass:${NC}         admin"
echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║       💎 POWERED BY VISHAL EXE 💎          ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════╝${NC}"
