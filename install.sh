#!/usr/bin/env bash
# =============================================================================
# SKY MANAGEMENT VMS - One-Command Installer
# Usage (interactive):        bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh)
# Usage (non-interactive):    bash install.sh --non-interactive --all
# Options:
#   --non-interactive         Skip all prompts
#   --all                     Install every supported component
#   --docker / --no-docker    Enable/disable Docker
#   --lxc    / --no-lxc       Enable/disable LXD/Incus
#   --kvm    / --no-kvm       Enable/disable KVM/QEMU (only if /dev/kvm present)
#   --tailscale / --no-tailscale
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[SKY]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }

PANEL_DIR="/opt/sky-management"
PANEL_USER="sky"
PANEL_PORT="8000"
DB_NAME="sky_management"
DB_USER="sky_user"
REPO_URL="${SKY_REPO_URL:-https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY.git}"

NON_INTERACTIVE=false
INSTALL_DOCKER="ask"; INSTALL_LXC="ask"; INSTALL_KVM="ask"; INSTALL_TAILSCALE="ask"

parse_args() {
  for arg in "$@"; do
    case $arg in
      --non-interactive) NON_INTERACTIVE=true ;;
      --all) INSTALL_DOCKER=y; INSTALL_LXC=y; INSTALL_KVM=y; INSTALL_TAILSCALE=y ;;
      --docker) INSTALL_DOCKER=y ;;
      --no-docker) INSTALL_DOCKER=n ;;
      --lxc) INSTALL_LXC=y ;;
      --no-lxc) INSTALL_LXC=n ;;
      --kvm) INSTALL_KVM=y ;;
      --no-kvm) INSTALL_KVM=n ;;
      --tailscale) INSTALL_TAILSCALE=y ;;
      --no-tailscale) INSTALL_TAILSCALE=n ;;
      -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
  done
}

# --------------------------- Preflight checks --------------------------------
preflight() {
  if [ "$(id -u)" -ne 0 ]; then err "Run as root (sudo -i or root user)."; exit 1; fi
  if [ ! -f /etc/os-release ]; then err "Cannot detect OS."; exit 1; fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    err "This installer targets Ubuntu. Detected: ${ID:-unknown}"; exit 1
  fi
  ok "Ubuntu ${VERSION_ID} detected"

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|aarch64) ok "Architecture: $ARCH" ;;
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
  esac

  RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  if [ "$RAM_MB" -lt 2048 ]; then
    warn "Low RAM: ${RAM_MB}MB (2GB recommended)"; sleep 2
  else ok "RAM: ${RAM_MB}MB"; fi

  DISK_AVAIL=$(df -m /opt | awk 'NR==2{print $4}')
  if [ "$DISK_AVAIL" -lt 10240 ]; then
    err "Need at least 10GB free on /opt (have ${DISK_AVAIL}MB)"; exit 1
  fi
  ok "Free disk on /opt: ${DISK_AVAIL}MB"
}

# ----------------------- Virtualization detection ----------------------------
detect_capabilities() {
  KVM_SUPPORTED=false; KVM_REASON=""
  if [ -e /dev/kvm ]; then
    if grep -qE '(vmx|svm)' /proc/cpuinfo; then
      KVM_SUPPORTED=true
      ok "KVM: supported (/dev/kvm present, CPU flags OK)"
    else
      KVM_REASON="CPU virtualization disabled in BIOS"
      warn "KVM: $KVM_REASON"
    fi
  else
    KVM_REASON="/dev/kvm not present (BIOS virtualization disabled or nested virt unavailable)"
    warn "KVM: $KVM_REASON"
  fi

  VIRT_TYPE="none"
  if command -v systemd-detect-virt &>/dev/null; then
    VIRT_TYPE=$(systemd-detect-virt || true)
  fi
  log "Running inside: $VIRT_TYPE"

  command -v docker &>/dev/null && DOCKER_PREEXISTING=true || DOCKER_PREEXISTING=false
  command -v incus  &>/dev/null && INCUS_PREEXISTING=true  || INCUS_PREEXISTING=false
  command -v tailscale &>/dev/null && TS_PREEXISTING=true  || TS_PREEXISTING=false
}

prompt_choice() {
  local label="$1" current="$2" avail="$3"
  if [ "$NON_INTERACTIVE" = true ] || [ "$current" != "ask" ]; then echo "$current"; return; fi
  local prompt="Install $label? [Y/n]"
  if [ "$avail" = "false" ]; then echo "n"; return; fi
  read -r -p "$prompt " ans
  case "$ans" in [Nn]*) echo "n" ;; *) echo "y" ;; esac
}

plan_install() {
  INSTALL_DOCKER=$(prompt_choice "Docker Engine" "$INSTALL_DOCKER" "true")
  INSTALL_LXC=$(prompt_choice "LXD/Incus" "$INSTALL_LXC" "true")
  INSTALL_TAILSCALE=$(prompt_choice "Tailscale CLI (panel host)" "$INSTALL_TAILSCALE" "true")
  if [ "$KVM_SUPPORTED" = true ]; then
    INSTALL_KVM=$(prompt_choice "KVM/QEMU/libvirt" "$INSTALL_KVM" "true")
  else
    if [ "$INSTALL_KVM" = "y" ]; then warn "KVM requested but unsupported: $KVM_REASON"; fi
    INSTALL_KVM="n"
  fi
  log "Plan: docker=$INSTALL_DOCKER lxc=$INSTALL_LXC kvm=$INSTALL_KVM tailscale=$INSTALL_TAILSCALE"
}

# ------------------------------ Base packages --------------------------------
install_base() {
  log "Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg lsb-release software-properties-common \
    git python3 python3-pip python3-venv python3-dev build-essential \
    nginx postgresql postgresql-contrib ufw jq \
    net-tools iproute2 bridge-utils openssh-client
  ok "Base packages installed"
}

# -------------------------------- Docker -------------------------------------
install_docker() {
  [ "$INSTALL_DOCKER" = "y" ] || { warn "Skipping Docker (not selected)"; return; }
  if [ "$DOCKER_PREEXISTING" = true ]; then ok "Docker already installed"; return; fi
  log "Installing Docker Engine..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  usermod -aG docker "$PANEL_USER" 2>/dev/null || true
  ok "Docker installed"
}

# ------------------------------- LXD / Incus ---------------------------------
install_incus() {
  [ "$INSTALL_LXC" = "y" ] || { warn "Skipping LXD/Incus (not selected)"; return; }
  if [ "$INCUS_PREEXISTING" = true ]; then ok "Incus already installed"; return; fi
  log "Installing Incus (LXD successor)..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
  echo "deb [signed-by=/etc/apt/keyrings/zabbly.asc] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo $VERSION_CODENAME) main" \
    > /etc/apt/sources.list.d/zabbly-incus-stable.list
  apt-get update -y
  apt-get install -y incus
  systemctl enable --now incus
  adduser "$PANEL_USER" incus-admin 2>/dev/null || true
  # Non-interactive init (default storage + bridge)
  incus admin init --auto || warn "Incus init needs manual review (run: incus admin init)"
  ok "Incus installed"
}

# ------------------------------- KVM / QEMU ----------------------------------
install_kvm() {
  [ "$INSTALL_KVM" = "y" ] || { warn "Skipping KVM (not selected/unsupported: ${KVM_REASON:-n/a})"; return; }
  log "Installing KVM/QEMU/libvirt..."
  apt-get install -y --no-install-recommends \
    qemu-kvm qemu-system-x86 qemu-utils libvirt-daemon-system \
    libvirt-clients bridge-utils virtinst virt-manager ovmf
  systemctl enable --now libvirtd
  adduser "$PANEL_USER" libvirt 2>/dev/null || true
  adduser "$PANEL_USER" kvm 2>/dev/null || true
  virsh net-list --all | grep -q default || virsh net-define /usr/share/libvirt/networks/default.xml
  virsh net-autostart default || true
  virsh net-start default 2>/dev/null || true
  ok "KVM installed (virsh: $(virsh version | head -1))"
}

# -------------------------------- Tailscale ----------------------------------
install_tailscale() {
  [ "$INSTALL_TAILSCALE" = "y" ] || { warn "Skipping Tailscale (not selected)"; return; }
  if [ "$TS_PREEXISTING" = true ]; then ok "Tailscale already installed"; return; fi
  log "Installing Tailscale CLI on panel host..."
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  ok "Tailscale installed (authenticate per-VPS from panel, not here)"
}

# ------------------------------ Panel bootstrap ------------------------------
create_user() {
  id "$PANEL_USER" &>/dev/null || useradd -m -s /bin/bash "$PANEL_USER"
  ok "System user '$PANEL_USER' ready"
}

setup_db() {
  log "Configuring PostgreSQL..."
  systemctl enable --now postgresql
  sudo -u postgres psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '$(openssl rand -hex 24)';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec
SQL
  ok "Database '$DB_NAME' ready"
}

deploy_panel() {
  log "Deploying SKY MANAGEMENT VMS panel..."
  mkdir -p "$PANEL_DIR"
  if [ -d "$PANEL_DIR/.git" ]; then
    git -C "$PANEL_DIR" pull --ff-only || warn "Git pull failed"
  else
    git clone --depth 1 "$REPO_URL" "$PANEL_DIR" || {
      err "Failed to clone $REPO_URL"
      err "Set SKY_REPO_URL env var to your actual repo URL."
      exit 1
    }
  fi
  chown -R "$PANEL_USER:$PANEL_USER" "$PANEL_DIR"
  sudo -u "$PANEL_USER" python3 -m venv "$PANEL_DIR/venv"
  sudo -u "$PANEL_USER" "$PANEL_DIR/venv/bin/pip" install --upgrade pip wheel
  if [ -f "$PANEL_DIR/requirements.txt" ]; then
    sudo -u "$PANEL_USER" "$PANEL_DIR/venv/bin/pip" install -r "$PANEL_DIR/requirements.txt"
  else
    sudo -u "$PANEL_USER" "$PANEL_DIR/venv/bin/pip" install \
      fastapi uvicorn[standard] gunicorn psycopg2-binary sqlalchemy \
      docker incus-sdk libvirt-python python-multipart passlib[bcrypt] python-jose
  fi
  if [ -f "$PANEL_DIR/.env.example" ] && [ ! -f "$PANEL_DIR/.env" ]; then
    cp "$PANEL_DIR/.env.example" "$PANEL_DIR/.env"
    sed -i "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://${DB_USER}:$(openssl rand -hex 24)@localhost/${DB_NAME}|" "$PANEL_DIR/.env" || true
  fi
  ok "Panel code deployed to $PANEL_DIR"
}

setup_systemd() {
  log "Creating systemd service..."
  cat > /etc/systemd/system/sky-management.service <<EOF
[Unit]
Description=SKY MANAGEMENT VMS
After=network.target postgresql.service docker.service
Wants=postgresql.service

[Service]
Type=simple
User=$PANEL_USER
Group=$PANEL_USER
WorkingDirectory=$PANEL_DIR
EnvironmentFile=-$PANEL_DIR/.env
ExecStart=$PANEL_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port $PANEL_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sky-management.service
  ok "systemd service started"
}

setup_nginx() {
  log "Configuring Nginx reverse proxy..."
  cat > /etc/nginx/sites-available/sky-management <<EOF
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 1024M;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  ln -sf /etc/nginx/sites-available/sky-management /etc/nginx/sites-enabled/sky-management
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl enable --now nginx
  ok "Nginx configured"
}

setup_firewall() {
  log "Configuring firewall..."
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
  ok "Firewall: SSH + HTTP(S) open"
}

wait_ready() {
  local tries=0
  until curl -sf "http://127.0.0.1:$PANEL_PORT" >/dev/null 2>&1 || [ $tries -ge 15 ]; do
    sleep 2; tries=$((tries+1))
  done
}

summary() {
  local ip; ip=$(hostname -I | awk '{print $1}')
  echo
  echo -e "${GREEN}==============================================================${NC}"
  echo -e "${GREEN}      SKY MANAGEMENT VMS - INSTALL COMPLETE${NC}"
  echo -e "${GREEN}==============================================================${NC}"
  echo -e "  Panel URL     : ${BLUE}http://${ip}/${NC}   (or http://${ip}:${PANEL_PORT}/)"
  echo -e "  Panel dir     : $PANEL_DIR"
  echo -e "  Service       : systemctl status sky-management"
  echo -e "  Logs          : journalctl -u sky-management -f"
  echo
  echo -e "  Components:"
  echo -e "    Docker        : $([ "$INSTALL_DOCKER" = y ] && echo 'installed' || echo 'skipped')"
  echo -e "    LXD/Incus     : $([ "$INSTALL_LXC" = y ] && echo 'installed' || echo 'skipped')"
  echo -e "    KVM/QEMU      : $([ "$INSTALL_KVM" = y ] && echo 'installed' || echo "skipped (${KVM_REASON:-not selected})")"
  echo -e "    Tailscale CLI : $([ "$INSTALL_TAILSCALE" = y ] && echo 'installed' || echo 'skipped')"
  echo
  echo -e "  ${YELLOW}Next step:${NC} create admin user"
  echo -e "    sudo -u $PANEL_USER $PANEL_DIR/venv/bin/python $PANEL_DIR/manage.py createsuperuser"
  echo -e "${GREEN}==============================================================${NC}"
}

main() {
  parse_args "$@"
  echo -e "${GREEN}SKY MANAGEMENT VMS Installer${NC}"
  preflight
  detect_capabilities
  plan_install
  create_user
  install_base
  install_docker
  install_incus
  install_kvm
  install_tailscale
  setup_db
  deploy_panel
  setup_systemd
  setup_nginx
  setup_firewall
  wait_ready
  summary
}

main "$@"
