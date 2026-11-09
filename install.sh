#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# SKYYY VM MANAGER - ALL-IN-ONE INSTALLER
# ==========================================

echo "[1/7] Checking environment..."
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] || echo "Warning: tested on Ubuntu 24.04"
uname -m | grep -q x86_64 || { echo "x86_64 required"; exit 1; }

echo "[2/7] Installing system dependencies (this takes a few minutes)..."
apt-get update
# FIXED: Added pkg-config, libvirt-dev, gcc, and build-essential for libvirt-python
apt-get install -y python3 python3-venv python3-pip nginx curl git qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils cloud-image-utils genisoimage pkg-config libvirt-dev gcc build-essential

echo "[3/7] Installing Incus (LXC) & Docker..."
command -v incus >/dev/null || apt-get install -y incus
if ! incus profile list >/dev/null 2>&1; then
  cat <<EOF | incus admin init --preseed
config: {}
networks:
  - name: incusbr0
    type: bridge
storage_pools:
  - name: default
    driver: dir
    config: {}
profiles:
  - name: default
    devices:
      eth0: {name: eth0, network: incusbr0, type: nic}
      root: {path: /, pool: default, type: disk}
EOF
fi
command -v docker >/dev/null || apt-get install -y docker.io
systemctl enable --now docker

echo "[4/7] Creating project files..."
INSTALL_DIR="/opt/skyyy-vm-manager"
DATA_DIR="/var/lib/skyyy-vm-manager"
mkdir -p "$INSTALL_DIR"/{backend/api,backend/virtualization,frontend/templates,frontend/static/css,frontend/static/js,config,cli,systemd} "$DATA_DIR"

# --- requirements.txt ---
cat << 'EOF' > "$INSTALL_DIR/requirements.txt"
fastapi==0.115.0
uvicorn[standard]==0.30.6
sqlalchemy==2.0.35
aiosqlite==0.20.0
passlib[bcrypt]==1.7.4
python-jose[cryptography]==3.3.0
python-multipart==0.0.9
jinja2==3.1.4
docker==7.1.0
libvirt-python==10.6.0
psutil==6.0.0
requests==2.32.3
requests-unixsocket==0.4.1
websockets==13.1
EOF

# --- config/settings.py ---
cat << 'EOF' > "$INSTALL_DIR/config/settings.py"
import os
from pathlib import Path
BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.getenv("SKYYY_DATA_DIR", "/var/lib/skyyy-vm-manager"))
DATABASE_URL = os.getenv("SKYYY_DATABASE_URL", f"sqlite+aiosqlite:///{DATA_DIR}/skyyy.db")
SECRET_KEY = os.getenv("SKYYY_SECRET_KEY", "")
if not SECRET_KEY:
    key_file = DATA_DIR / "secret.key"
    SECRET_KEY = key_file.read_text().strip() if key_file.exists() else __import__('secrets').token_urlsafe(64)
    key_file.write_text(SECRET_KEY)
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 8
EOF

# --- config/providers.py ---
cat << 'EOF' > "$INSTALL_DIR/config/providers.py"
import os, shutil
def detect_providers():
    status = {"lxc": {"available": False}, "docker": {"available": False}, "kvm": {"available": False}}
    if os.path.exists("/var/lib/incus/unix.socket"):
        status["lxc"]["available"] = True
    else:
        status["lxc"]["reason"] = "Incus socket missing"
    try:
        import docker
        docker.from_env().ping()
        status["docker"]["available"] = True
    except Exception as e:
        status["docker"]["reason"] = str(e)
    if os.path.exists("/dev/kvm") and shutil.which("virsh"):
        status["kvm"]["available"] = True
    else:
        status["kvm"]["reason"] = "/dev/kvm missing or libvirt not installed"
    return status
EOF

# --- backend/database.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/database.py"
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from config.settings import DATABASE_URL
engine = create_async_engine(DATABASE_URL, echo=False)
AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
Base = declarative_base()
async def get_db():
    async with AsyncSessionLocal() as session:
        yield session
async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
EOF

# --- backend/models.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/models.py"
import uuid
from datetime import datetime, timezone
from sqlalchemy import Column, String, Integer, DateTime, Boolean, ForeignKey, Text
from sqlalchemy.orm import relationship
from backend.database import Base
class User(Base):
    __tablename__ = "users"
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    username = Column(String, unique=True, index=True, nullable=False)
    hashed_password = Column(String, nullable=False)
    role = Column(String, default="USER")
    is_active = Column(Boolean, default=True)
class Instance(Base):
    __tablename__ = "instances"
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name = Column(String, unique=True, index=True, nullable=False)
    provider = Column(String, nullable=False)
    status = Column(String, default="unknown")
    ram_mb = Column(Integer)
    cpu_cores = Column(Integer)
    disk_gb = Column(Integer)
    owner_id = Column(String, ForeignKey("users.id"))
EOF

# --- backend/auth.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/auth.py"
from datetime import datetime, timedelta, timezone
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from config.settings import SECRET_KEY, ALGORITHM, ACCESS_TOKEN_EXPIRE_MINUTES
from backend.database import get_db
from backend.models import User
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")
def verify_password(p, h): return pwd_context.verify(p, h)
def get_password_hash(p): return pwd_context.hash(p)
def create_access_token(data: dict):
    to_encode = data.copy()
    to_encode.update({"exp": datetime.now(timezone.utc) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
async def get_current_user(token: str = Depends(oauth2_scheme), db: AsyncSession = Depends(get_db)) -> User:
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id = payload.get("sub")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user: raise HTTPException(status_code=401, detail="User not found")
    return user
EOF

# --- backend/virtualization/lxc.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/virtualization/lxc.py"
import requests, time
from requests_unixsocket import Session
session = Session()
BASE = "http+unix://%2Fvar%2Flib%2Fincus%2Funix.socket/1.0"
def _req(method, path, **kwargs):
    r = session.request(method, BASE + path, **kwargs)
    r.raise_for_status()
    return r.json()
class LXCProvider:
    def create(self, name, template="ubuntu/24.04", ram_mb=1024, cpu_cores=1, **kw):
        config = {"name": name, "source": {"type": "image", "protocol": "simplestreams", "server": "https://images.linuxcontainers.org", "alias": template}, "config": {"limits.memory": f"{ram_mb}MB", "limits.cpu": str(cpu_cores)}}
        res = _req("POST", "/instances", json=config)
        if res.get("type") == "async": self._wait(res["operation"])
        return {"status": "created"}
    def start(self, name):
        res = _req("PUT", f"/instances/{name}/state", json={"action": "start"})
        if res.get("type") == "async": self._wait(res["operation"])
    def stop(self, name):
        res = _req("PUT", f"/instances/{name}/state", json={"action": "stop", "force": True})
        if res.get("type") == "async": self._wait(res["operation"])
    def delete(self, name): _req("DELETE", f"/instances/{name}")
    def _wait(self, op):
        for _ in range(60):
            if _req("GET", op.replace("/1.0", ""))["metadata"]["status"] == "Success": return
            time.sleep(1)
EOF

# --- backend/virtualization/docker_provider.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/virtualization/docker_provider.py"
import docker
class DockerProvider:
    def __init__(self): self.client = docker.from_env()
    def create(self, name, image="ubuntu:24.04", ram_mb=1024, cpu_cores=1, **kw):
        self.client.containers.run(image=image, name=name, detach=True, mem_limit=f"{ram_mb}m", nano_cpus=cpu_cores * 10**9, command="sleep infinity", restart_policy={"Name": "unless-stopped"})
    def start(self, name): self.client.containers.get(name).start()
    def stop(self, name): self.client.containers.get(name).stop()
    def delete(self, name): self.client.containers.get(name).remove(force=True)
EOF

# --- backend/virtualization/kvm.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/virtualization/kvm.py"
import libvirt, os, subprocess
class KVMProvider:
    def __init__(self):
        if not os.path.exists("/dev/kvm"): raise RuntimeError("KVM unavailable")
        self.conn = libvirt.open("qemu:///system")
    def create(self, name, ram_mb=2048, cpu_cores=2, disk_gb=20, **kw):
        disk = f"/var/lib/libvirt/images/{name}.qcow2"
        subprocess.run(["qemu-img", "create", "-f", "qcow2", disk, f"{disk_gb}G"], check=True)
        xml = f"<domain type='kvm'><name>{name}</name><memory unit='MiB'>{ram_mb}</memory><vcpu>{cpu_cores}</vcpu><os><type arch='x86_64'>hvm</type></os><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='{disk}'/><target dev='vda' bus='virtio'/></disk><interface type='network'><source network='default'/></interface></devices></domain>"
        self.conn.defineXML(xml)
    def start(self, name): self.conn.lookupByName(name).create()
    def stop(self, name): self.conn.lookupByName(name).destroy()
    def delete(self, name): self.conn.lookupByName(name).undefine()
EOF

# --- backend/api/instances.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/api/instances.py"
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from backend.database import get_db
from backend.models import Instance, User
from backend.auth import get_current_user
from backend.virtualization.lxc import LXCProvider
from backend.virtualization.docker_provider import DockerProvider
from backend.virtualization.kvm import KVMProvider
router = APIRouter()
@router.get("/")
async def list_instances(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    res = await db.execute(select(Instance))
    return [{"id": i.id, "name": i.name, "provider": i.provider, "status": i.status} for i in res.scalars().all()]
@router.post("/")
async def create_instance(payload: dict, user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p = payload["provider"]
    try:
        if p == "lxc": LXCProvider().create(payload["name"], ram_mb=payload.get("ram_mb", 1024))
        elif p == "docker": DockerProvider().create(payload["name"], ram_mb=payload.get("ram_mb", 1024))
        elif p == "kvm": KVMProvider().create(payload["name"], ram_mb=payload.get("ram_mb", 1024))
    except Exception as e: raise HTTPException(500, str(e))
    inst = Instance(name=payload["name"], provider=p, ram_mb=payload.get("ram_mb", 1024), cpu_cores=1, owner_id=user.id, status="running")
    db.add(inst); await db.commit()
    return {"status": "success"}
EOF

# --- backend/api/auth_routes.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/api/auth_routes.py"
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from backend.database import get_db
from backend.models import User
from backend.auth import verify_password, create_access_token, get_password_hash
router = APIRouter()
@router.post("/login")
async def login(form: OAuth2PasswordRequestForm = Depends(), db: AsyncSession = Depends(get_db)):
    res = await db.execute(select(User).where(User.username == form.username))
    user = res.scalar_one_or_none()
    if not user or not verify_password(form.password, user.hashed_password): raise HTTPException(401, "Bad login")
    return {"access_token": create_access_token({"sub": user.id}), "token_type": "bearer"}
@router.post("/register")
async def register(username: str, password: str, db: AsyncSession = Depends(get_db)):
    res = await db.execute(select(User))
    role = "OWNER" if res.scalars().first() is None else "USER"
    db.add(User(username=username, hashed_password=get_password_hash(password), role=role))
    await db.commit()
    return {"status": "created"}
EOF

# --- backend/api/system.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/api/system.py"
from fastapi import APIRouter, Depends
from backend.auth import get_current_user
from backend.models import User
from config.providers import detect_providers
import psutil
router = APIRouter()
@router.get("/")
async def system_info(user: User = Depends(get_current_user)):
    return {"cpu": psutil.cpu_percent(), "ram": psutil.virtual_memory().percent, "disk": psutil.disk_usage('/').percent, "providers": detect_providers()}
EOF

# --- backend/main.py ---
cat << 'EOF' > "$INSTALL_DIR/backend/main.py"
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.responses import RedirectResponse
from backend.database import init_db
from backend.api import instances, auth_routes, system
@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield
app = FastAPI(lifespan=lifespan)
app.mount("/static", StaticFiles(directory="frontend/static"), name="static")
templates = Jinja2Templates(directory="frontend/templates")
app.include_router(auth_routes.router, prefix="/api/auth")
app.include_router(system.router, prefix="/api/system")
app.include_router(instances.router, prefix="/api/instances")
@app.get("/")
async def root(): return RedirectResponse("/dashboard")
@app.get("/dashboard")
async def dashboard(): return templates.TemplateResponse("dashboard.html", {"request": {}})
@app.get("/login")
async def login_page(): return templates.TemplateResponse("login.html", {"request": {}})
EOF

# --- frontend/templates/base.html ---
cat << 'EOF' > "$INSTALL_DIR/frontend/templates/base.html"
<!DOCTYPE html><html><head><title>SKYYY</title><link rel="stylesheet" href="/static/css/style.css"></head>
<body><div class="app"><aside class="sidebar"><div class="logo">SKYYY</div><nav><a href="/dashboard">Dashboard</a></nav></aside><main class="main">{% block content %}{% endblock %}</main></div></body></html>
EOF

# --- frontend/templates/login.html ---
cat << 'EOF' > "$INSTALL_DIR/frontend/templates/login.html"
{% extends "base.html" %}{% block content %}
<h1>Login</h1>
<input id="u" placeholder="Username"><input id="p" type="password" placeholder="Password">
<button onclick="login()">Login / Register</button>
<script>
async function login(){
  let u=document.getElementById('u').value, p=document.getElementById('p').value;
  await fetch('/api/auth/register?username='+u+'&password='+p, {method:'POST'});
  let res=await fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${u}&password=${p}`});
  let data=await res.json(); if(data.access_token){localStorage.setItem('token',data.access_token);window.location='/dashboard';}
}
</script>{% endblock %}
EOF

# --- frontend/templates/dashboard.html ---
cat << 'EOF' > "$INSTALL_DIR/frontend/templates/dashboard.html"
{% extends "base.html" %}{% block content %}
<h1>Dashboard</h1><div class="grid">
<div class="card"><h3>CPU</h3><p id="cpu">-</p></div>
<div class="card"><h3>RAM</h3><p id="ram">-</p></div>
<div class="card"><h3>Disk</h3><p id="disk">-</p></div>
<div class="card"><h3>Providers</h3><pre id="prov">-</pre></div>
</div>
<script>
async function load(){
  let t=localStorage.getItem('token'); if(!t){window.location='/login';return;}
  let res=await fetch('/api/system/',{headers:{'Authorization':'Bearer '+t}});
  if(!res.ok){localStorage.clear();window.location='/login';return;}
  let d=await res.json();
  document.getElementById('cpu').innerText=d.cpu+'%';
  document.getElementById('ram').innerText=d.ram+'%';
  document.getElementById('disk').innerText=d.disk+'%';
  document.getElementById('prov').innerText=JSON.stringify(d.providers,null,2);
}
setInterval(load, 5000); load();
</script>{% endblock %}
EOF

# --- frontend/static/css/style.css ---
cat << 'EOF' > "$INSTALL_DIR/frontend/static/css/style.css"
body { background: #0a0e1a; color: white; font-family: sans-serif; margin: 0; }
.app { display: flex; } .sidebar { width: 200px; padding: 20px; background: #111827; height: 100vh; }
.logo { font-size: 24px; font-weight: bold; color: #3b82f6; margin-bottom: 20px; }
.main { flex: 1; padding: 20px; } .grid { display: flex; gap: 20px; }
.card { background: #1e293b; padding: 20px; border-radius: 10px; flex: 1; border: 1px solid #3b82f6; }
input, button { padding: 10px; margin: 5px; border-radius: 5px; border: none; }
button { background: #3b82f6; color: white; cursor: pointer; }
EOF

# --- systemd service ---
cat << 'EOF' > "$INSTALL_DIR/systemd/skyyy-vm-manager.service"
[Unit]
Description=SKYYY VM MANAGER
After=network.target incus.service docker.service libvirtd.service
[Service]
User=skyyy
WorkingDirectory=/opt/skyyy-vm-manager
Environment="SKYYY_DATA_DIR=/var/lib/skyyy-vm-manager"
ExecStart=/opt/skyyy-vm-manager/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8787
Restart=always
[Install]
WantedBy=multi-user.target
EOF

echo "[5/7] Setting up user and permissions..."
id -u skyyy &>/dev/null || useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin skyyy
# FIXED: Added incus-admin group for Ubuntu 24.04
usermod -aG incus-admin,docker,libvirt skyyy || true

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
chown -R skyyy:skyyy "$INSTALL_DIR" "$DATA_DIR"

echo "[6/7] Starting services..."
cp "$INSTALL_DIR/systemd/skyyy-vm-manager.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now skyyy-vm-manager

echo "[7/7] Setting up Nginx..."
cat > /etc/nginx/sites-available/skyyy <<'EOF'
server {
    listen 80;
    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
ln -sf /etc/nginx/sites-available/skyyy /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

IP=$(hostname -I | awk '{print $1}')
echo "=============================================="
echo " SUCCESS! SKYYY VM MANAGER IS INSTALLED!"
echo " URL: http://$IP/"
echo " Register to become the OWNER."
echo "=============================================="
