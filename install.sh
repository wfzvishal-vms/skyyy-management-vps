#!/usr/bin/env bash
set -Eeuo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
log(){ echo -e "${CYAN}[SKYYY]${NC} $*"; }; ok(){ echo -e "${GREEN}[ OK ]${NC} $*"; }

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
ART
echo -e "${NC}"

# ==========================================
# 🧹 PURANA SAB KUCH DELETE KARNE KA SECTION
# ==========================================
log "Purana panel aur processes delete kiye ja rahe hain..."
pm2 delete all >/dev/null 2>&1 || true
rm -rf /opt/skyyy
ok "Purana data saaf ho gaya."

# ==========================================
# 🚀 NAYA INSTALLATION SHURU
# ==========================================
log "System dependencies install ho rahi hain..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git ufw jq openssl build-essential python3 >/dev/null

# Docker Install
if ! command -v docker &>/dev/null; then
  log "Docker install ho raha hai..."
  curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker
fi

# LXD/LXC Install
if ! command -v lxd &>/dev/null && ! snap list lxd &>/dev/null 2>&1; then
  log "LXD install ho raha hai..."
  snap install lxd >/dev/null 2>&1 || apt-get install -y -qq lxd >/dev/null
  lxd init --auto >/dev/null 2>&1 || true
fi

# Node.js Install
if ! command -v node &>/dev/null; then
  log "Node.js install ho raha hai..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
npm i -g pm2 >/dev/null 2>&1

log "Panel directory aur Backend ban raha hai..."
mkdir -p /opt/skyyy/public
cd /opt/skyyy

cat << 'EOF' > package.json
{
  "name": "skyyy-panel",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "express": "^4.19.2", "cors": "^2.8.5", "sqlite3": "^5.1.7", "bcryptjs": "^2.4.3", "jsonwebtoken": "^9.0.2" }
}
EOF

# Backend with Auth & SQLite
cat << 'EOF' > server.js
const express = require('express');
const { exec } = require('child_process');
const cors = require('cors');
const sqlite3 = require('sqlite3').verbose();
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');

const app = express();
const SECRET_KEY = 'VISHAL_EXE_SECRET_KEY_123';

app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// Database Setup (Fresh DB)
const db = new sqlite3.Database('./skyyy.db');
db.serialize(() => {
  db.run("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT UNIQUE, password TEXT)");
  // Create default admin/admin
  const hash = bcrypt.hashSync('admin', 8);
  db.run(`INSERT OR IGNORE INTO users (id, username, password) VALUES (1, 'admin', '${hash}')`);
});

// Login Route
app.post('/api/login', (req, res) => {
  const { username, password } = req.body;
  db.get("SELECT * FROM users WHERE username = ?", [username], (err, user) => {
    if (!user) return res.status(401).json({ error: 'User not found' });
    const valid = bcrypt.compareSync(password, user.password);
    if (!valid) return res.status(401).json({ error: 'Invalid password' });
    const token = jwt.sign({ id: user.id, username: user.username }, SECRET_KEY, { expiresIn: '1d' });
    res.json({ token });
  });
});

// Middleware to protect routes
const authenticate = (req, res, next) => {
  const token = req.headers['authorization'];
  if (!token) return res.status(401).json({ error: 'Unauthorized' });
  jwt.verify(token, SECRET_KEY, (err, decoded) => {
    if (err) return res.status(401).json({ error: 'Invalid token' });
    req.user = decoded;
    next();
  });
};

// Stats API
app.get('/api/stats', authenticate, (req, res) => {
  exec('free -m | grep Mem | awk \'{print $3 "," $2}\' && top -bn1 | grep "Cpu(s)" | awk \'{print $2}\'', (err, stdout) => {
    let ram = { used: 0, total: 0 }, cpu = 0;
    if (!err && stdout) {
      const lines = stdout.trim().split('\n');
      if(lines[0]) { const r = lines[0].split(','); ram = {used: r[0], total: r[1]}; }
      if(lines[1]) cpu = parseFloat(lines[1]);
    }
    res.json({ cpu, ram });
  });
});

// LXC APIs
app.get('/api/lxc', authenticate, (req, res) => {
  exec('lxc list --format json', (err, stdout) => {
    if (err) return res.json([]);
    try { res.json(JSON.parse(stdout)); } catch(e) { res.json([]); }
  });
});
app.post('/api/lxc', authenticate, (req, res) => {
  const { name, image } = req.body;
  exec(`lxc launch ${image} ${name}`, (err) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ success: true });
  });
});

// Docker APIs
app.get('/api/docker', authenticate, (req, res) => {
  exec('docker ps -a --format "{\\"name\\":\\"{{.Names}}\\",\\"image\\":\\"{{.Image}}\\",\\"status\\":\\"{{.Status}}\\"}"', (err, stdout) => {
    if (err) return res.json([]);
    try {
      const lines = stdout.trim().split('\n').filter(l => l);
      res.json(lines.map(l => JSON.parse(l)));
    } catch(e) { res.json([]); }
  });
});
app.post('/api/docker', authenticate, (req, res) => {
  const { name, image } = req.body;
  exec(`docker run -d --name ${name} ${image}`, (err) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ success: true });
  });
});

app.get('/api/kvm', authenticate, (req, res) => res.json([{ name: "kvm-demo-vm", status: "Running", os: "Ubuntu ISO" }]));
app.get('/api/nodes', authenticate, (req, res) => res.json([{ name: "Master-Node", ip: "127.0.0.1", status: "Online", type: "Master" }]));

app.listen(3000, () => console.log('SKYYY Panel Backend Running'));
EOF

log "Frontend (Login + Dashboard) ban raha hai..."

# Login Page
cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Login - SKYYY</title>
  <style>
    body { background: radial-gradient(circle at top right, #1a1a3a, #0a0a0f); color: #fff; font-family: sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
    .login-box { background: rgba(255,255,255,0.05); backdrop-filter: blur(10px); border: 1px solid rgba(255,255,255,0.1); padding: 40px; border-radius: 16px; width: 100%; max-width: 350px; text-align: center; box-shadow: 0 8px 32px rgba(0,0,0,0.3); }
    h1 { color: #4ad7ff; margin-bottom: 20px; font-size: 2rem; }
    input { width: 100%; padding: 12px; margin: 10px 0; border-radius: 8px; border: 1px solid rgba(255,255,255,0.2); background: rgba(0,0,0,0.5); color: #fff; box-sizing: border-box; }
    button { width: 100%; padding: 12px; border-radius: 8px; border: none; background: linear-gradient(135deg, #7c5cff, #4ad7ff); color: #fff; font-weight: bold; cursor: pointer; margin-top: 10px; }
  </style>
</head>
<body>
  <div class="login-box">
    <h1>SKYYY</h1>
    <input type="text" id="user" placeholder="Username (admin)" value="admin">
    <input type="password" id="pass" placeholder="Password (admin)" value="admin">
    <button onclick="login()">Login</button>
    <p id="msg" style="color: red; font-size: 0.9rem; margin-top: 10px;"></p>
  </div>
  <script>
    async function login() {
      const res = await fetch('/api/login', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ username: document.getElementById('user').value, password: document.getElementById('pass').value })
      });
      const data = await res.json();
      if (data.token) {
        localStorage.setItem('skyyy_token', data.token);
        window.location.href = '/';
      } else {
        document.getElementById('msg').innerText = data.error || 'Login failed';
      }
    }
  </script>
</body>
</html>
EOF

# Main Dashboard
cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SKYYY MANAGEMENT VPS</title>
  <style>
    :root { --primary: #7c5cff; --secondary: #4ad7ff; --bg: #0a0a0f; --glass: rgba(255,255,255,0.05); }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; }
    body { background: radial-gradient(circle at top right, #1a1a3a, var(--bg)); color: #fff; display: flex; min-height: 100vh; overflow-x: hidden; }
    
    .sidebar { width: 250px; background: rgba(0,0,0,0.3); backdrop-filter: blur(10px); border-right: 1px solid rgba(255,255,255,0.1); padding: 20px; display: flex; flex-direction: column; gap: 10px; height: 100vh; position: fixed; z-index: 10; transition: 0.3s; }
    .logo { font-size: 1.5rem; font-weight: bold; background: linear-gradient(90deg, var(--primary), var(--secondary)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin-bottom: 30px; text-align: center; letter-spacing: 1px; }
    .nav-item { padding: 12px 15px; border-radius: 10px; cursor: pointer; transition: 0.3s; color: #aaa; display: flex; align-items: center; gap: 10px; }
    .nav-item:hover, .nav-item.active { background: rgba(124, 92, 255, 0.2); color: #fff; border-left: 3px solid var(--primary); }
    
    .main { margin-left: 250px; padding: 30px; width: calc(100% - 250px); transition: 0.3s; }
    .page { display: none; animation: fadeIn 0.3s; }
    .page.active { display: block; }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
    h2 { margin-bottom: 20px; font-weight: 500; }
    
    .glass-card { background: var(--glass); backdrop-filter: blur(15px); border: 1px solid rgba(255,255,255,0.1); border-radius: 16px; padding: 20px; margin-bottom: 20px; box-shadow: 0 8px 32px rgba(0,0,0,0.3); }
    .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 30px; }
    .stat-box { text-align: center; }
    .stat-val { font-size: 2rem; font-weight: bold; color: var(--secondary); margin-top: 10px; }
    
    .form-row { display: flex; gap: 10px; margin-bottom: 20px; flex-wrap: wrap; }
    input, select { padding: 12px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.2); background: rgba(0,0,0,0.5); color: #fff; outline: none; flex: 1; min-width: 150px; }
    button { padding: 12px 20px; border-radius: 8px; border: none; background: linear-gradient(135deg, var(--primary), var(--secondary)); color: #fff; font-weight: bold; cursor: pointer; transition: 0.3s; }
    button:hover { transform: translateY(-2px); box-shadow: 0 5px 15px rgba(124, 92, 255, 0.4); }
    
    .list-item { display: flex; justify-content: space-between; align-items: center; padding: 15px; background: rgba(0,0,0,0.3); border-radius: 10px; margin-bottom: 10px; border-left: 4px solid var(--primary); }
    .badge { padding: 4px 8px; border-radius: 4px; font-size: 0.8rem; font-weight: bold; background: var(--secondary); color: #000; }
    .footer { margin-top: 50px; text-align: center; color: #555; font-size: 0.9rem; letter-spacing: 2px; }
    .footer span { color: var(--secondary); font-weight: bold; }
    .loading { color: var(--secondary); font-style: italic; }

    /* Mobile View */
    @media (max-width: 768px) {
      .sidebar { width: 100%; height: auto; position: relative; flex-direction: row; overflow-x: auto; padding: 10px; gap: 5px; }
      .logo { display: none; }
      .main { margin-left: 0; width: 100%; padding: 15px; }
      .nav-item { white-space: nowrap; padding: 8px 12px; font-size: 0.9rem; }
    }
  </style>
</head>
<body>
  <script>
    const token = localStorage.getItem('skyyy_token');
    if (!token) window.location.href = '/login.html';
  </script>

  <div class="sidebar">
    <div class="logo">SKYYY</div>
    <div class="nav-item active" onclick="nav('dashboard', event)">📊 Dashboard</div>
    <div class="nav-item" onclick="nav('lxc', event)">🐧 LXC Containers</div>
    <div class="nav-item" onclick="nav('docker', event)">🐳 Docker</div>
    <div class="nav-item" onclick="nav('kvm', event)">💻 KVM VMs</div>
    <div class="nav-item" onclick="nav('nodes', event)">🌐 Nodes</div>
    <div class="nav-item" style="margin-top: auto; color: #ff5555;" onclick="logout()">🚪 Logout</div>
  </div>

  <div class="main">
    <div id="dashboard" class="page active">
      <h2>Dashboard Overview</h2>
      <div class="stats-grid">
        <div class="glass-card stat-box"><div>CPU Usage</div><div class="stat-val" id="cpu">0%</div></div>
        <div class="glass-card stat-box"><div>RAM Usage</div><div class="stat-val" id="ram">0 / 0 MB</div></div>
      </div>
      <div class="glass-card">
        <h3>Welcome, Admin! 👋</h3>
        <p style="margin-top: 10px; color: #aaa;">Manage your LXC, Docker, and KVM environments from one place.</p>
      </div>
    </div>

    <div id="lxc" class="page">
      <h2>🐧 LXC Containers</h2>
      <div class="glass-card">
        <div class="form-row">
          <input type="text" id="lxc-name" placeholder="Container Name (e.g. test-vps)">
          <select id="lxc-image">
            <option value="ubuntu:22.04">Ubuntu 22.04</option>
            <option value="debian:12">Debian 12</option>
            <option value="alpine:3.19">Alpine 3.19</option>
          </select>
          <button onclick="createLXC()">Create LXC</button>
        </div>
        <div id="lxc-list" class="loading">Loading...</div>
      </div>
    </div>

    <div id="docker" class="page">
      <h2>🐳 Docker Containers</h2>
      <div class="glass-card">
        <div class="form-row">
          <input type="text" id="docker-name" placeholder="Container Name">
          <input type="text" id="docker-image" placeholder="Image (e.g. nginx:latest)">
          <button onclick="createDocker()">Run Docker</button>
        </div>
        <div id="docker-list" class="loading">Loading...</div>
      </div>
    </div>

    <div id="kvm" class="page">
      <h2>💻 KVM Virtual Machines</h2>
      <div class="glass-card">
        <div class="form-row">
          <input type="text" id="kvm-name" placeholder="VM Name">
          <select id="kvm-os"><option>Ubuntu ISO</option><option>Windows ISO</option></select>
          <button onclick="alert('KVM requires hardware virtualization. In VPS it may not work.')">Create VM</button>
        </div>
        <div id="kvm-list" class="loading">Loading...</div>
      </div>
    </div>

    <div id="nodes" class="page">
      <h2>🌐 Connected Nodes</h2>
      <div class="glass-card"><div id="nodes-list" class="loading">Loading...</div></div>
    </div>

    <div class="footer">POWERED BY <span>VISHAL EXE</span></div>
  </div>

  <script>
    const token = localStorage.getItem('skyyy_token');
    const headers = { 'Authorization': token };

    function logout() { localStorage.removeItem('skyyy_token'); window.location.href = '/login.html'; }
    function nav(id, e) {
      document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
      document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
      document.getElementById(id).classList.add('active');
      if(e) e.target.classList.add('active');
      
      if(id === 'dashboard') loadStats();
      if(id === 'lxc') loadLXC();
      if(id === 'docker') loadDocker();
      if(id === 'kvm') loadKVM();
      if(id === 'nodes') loadNodes();
    }

    async function loadStats() {
      const res = await fetch('/api/stats', { headers });
      const data = await res.json();
      document.getElementById('cpu').innerText = data.cpu + '%';
      document.getElementById('ram').innerText = data.ram.used + ' / ' + data.ram.total + ' MB';
    }

    async function loadLXC() {
      const res = await fetch('/api/lxc', { headers });
      const data = await res.json();
      const list = document.getElementById('lxc-list');
      if(!data.length) { list.innerHTML = '<p>No LXC containers found.</p>'; return; }
      list.innerHTML = data.map(c => `<div class="list-item"><div><b>${c.name}</b> <br><small>${c.image?.description || 'LXC'}</small></div><span class="badge">${c.status}</span></div>`).join('');
    }
    async function createLXC() {
      const name = document.getElementById('lxc-name').value;
      const image = document.getElementById('lxc-image').value;
      if(!name) return alert('Enter name');
      document.getElementById('lxc-list').innerHTML = '<p class="loading">Creating... (Please wait 15s)</p>';
      await fetch('/api/lxc', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({name, image}) });
      setTimeout(loadLXC, 5000);
    }

    async function loadDocker() {
      const res = await fetch('/api/docker', { headers });
      const data = await res.json();
      const list = document.getElementById('docker-list');
      if(!data.length) { list.innerHTML = '<p>No Docker containers found.</p>'; return; }
      list.innerHTML = data.map(c => `<div class="list-item"><div><b>${c.name}</b> <br><small>${c.image}</small></div><span class="badge">${c.status}</span></div>`).join('');
    }
    async function createDocker() {
      const name = document.getElementById('docker-name').value;
      const image = document.getElementById('docker-image').value;
      if(!name || !image) return alert('Enter name and image');
      document.getElementById('docker-list').innerHTML = '<p class="loading">Pulling and starting...</p>';
      await fetch('/api/docker', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({name, image}) });
      setTimeout(loadDocker, 3000);
    }

    async function loadKVM() {
      const res = await fetch('/api/kvm', { headers });
      const data = await res.json();
      document.getElementById('kvm-list').innerHTML = data.map(c => `<div class="list-item"><div><b>${c.name}</b> <br><small>${c.os}</small></div><span class="badge">${c.status}</span></div>`).join('');
    }
    async function loadNodes() {
      const res = await fetch('/api/nodes', { headers });
      const data = await res.json();
      document.getElementById('nodes-list').innerHTML = data.map(c => `<div class="list-item"><div><b>${c.name}</b> <br><small>${c.ip}</small></div><span class="badge">${c.status}</span></div>`).join('');
    }

    loadStats(); setInterval(loadStats, 5000);
  </script>
</body>
</html>
EOF

log "Dependencies install ho rahi hain (Isme 1-2 min lag sakte hain)..."
npm install >/dev/null 2>&1

log "Panel start ho raha hai (PM2)..."
pm2 start server.js --name skyyy >/dev/null
pm2 save >/dev/null
pm2 startup >/dev/null 2>&1 || true

ufw allow 3000/tcp >/dev/null 2>&1 || true

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅  FRESH SKYYY PANEL INSTALLED!${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "  Login ID:   admin"
echo -e "  Password:   admin"
echo -e "  Ab Pinggy ya VPS IP se open karo!"
echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║      💎  POWERED BY VISHAL EXE  💎     ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
