#!/usr/bin/env python3
"""Sky Management Panel © Vishal"""
import os, sys, sqlite3, secrets, hashlib, psutil
from datetime import datetime
from functools import wraps
from flask import Flask, request, redirect, url_for, session, jsonify, g, render_template_string

OWNER = "Vishal"
PANEL = "Sky Management Panel"

# ===== LICENSE =====
if not os.path.exists("LICENSE"):
    open("LICENSE","w").write(f"Copyright (c) 2026 {OWNER}\nAll rights reserved.\n{PANEL}\n")
elif OWNER not in open("LICENSE").read():
    print(f"❌ License invalid. Owner must be: {OWNER}"); sys.exit(1)

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", secrets.token_hex(32))

def db():
    if not hasattr(g,"db"):
        g.db = sqlite3.connect("panel.db"); g.db.row_factory = sqlite3.Row
    return g.db
@app.teardown_appcontext
def close_db(e=None):
    if hasattr(g,"db"): g.db.close()

def init_db():
    c = sqlite3.connect("panel.db").cursor()
    c.executescript("""
    CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password TEXT, role TEXT DEFAULT 'user', created_at TEXT);
    CREATE TABLE IF NOT EXISTS vps (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, name TEXT, os TEXT, ram INTEGER, cpu INTEGER, disk INTEGER, node TEXT, status TEXT DEFAULT 'running', ip TEXT, created_at TEXT);
    CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, location TEXT, ip TEXT, status TEXT DEFAULT 'online', created_at TEXT);
    """)
    c.connection.commit()
    if c.execute("SELECT COUNT(*) FROM users").fetchone()[0]==0:
        c.execute("INSERT INTO users (username,password,role,created_at) VALUES (?,?,?,?)",
            ("admin", hashlib.sha256(b"admin123").hexdigest(), "admin", datetime.now().isoformat()))
    if c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]==0:
        c.execute("INSERT INTO nodes (name,location,ip,created_at) VALUES (?,?,?,?)",
            ("sky-node-1","India","127.0.0.1",datetime.now().isoformat()))
    c.connection.commit(); c.connection.close()
init_db()

def h(p): return hashlib.sha256(p.encode()).hexdigest()
def login_required(f):
    @wraps(f)
    def w(*a,**kw):
        if "uid" not in session: return redirect(url_for("login"))
        return f(*a,**kw)
    return w
def admin_required(f):
    @wraps(f)
    def w(*a,**kw):
        if session.get("role")!="admin": return "Admin only",403
        return f(*a,**kw)
    return w

BASE = """<!doctype html><html><head><title>Sky Panel</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;font-family:system-ui,sans-serif}
body{background:#0a0f1e;color:#e5e7eb;min-height:100vh}
.nav{background:linear-gradient(90deg,#0f172a,#1e293b);padding:14px 24px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #1e293b;box-shadow:0 2px 20px rgba(56,189,248,0.1)}
.nav b{color:#38bdf8;font-size:18px;letter-spacing:0.5px}
.nav a{color:#94a3b8;text-decoration:none;margin:0 12px;font-size:14px;transition:0.2s}
.nav a:hover{color:#38bdf8}
.wrap{max-width:1200px;margin:24px auto;padding:0 20px}
.card{background:#0f172a;border:1px solid #1e293b;border-radius:12px;padding:20px;margin-bottom:16px;box-shadow:0 4px 24px rgba(0,0,0,0.3)}
.card h3{color:#38bdf8;margin-bottom:14px;font-size:16px}
input,select{background:#1e293b;border:1px solid #334155;color:#e5e7eb;padding:10px;border-radius:8px;width:100%;margin-bottom:10px;font-size:14px}
input:focus,select:focus{outline:none;border-color:#38bdf8}
button{background:linear-gradient(90deg,#0284c7,#38bdf8);color:#fff;border:none;padding:10px 20px;border-radius:8px;cursor:pointer;font-weight:600;transition:0.2s}
button:hover{transform:translateY(-1px);box-shadow:0 4px 16px rgba(56,189,248,0.3)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}
.stat{background:#1e293b;padding:16px;border-radius:10px;border-left:3px solid #38bdf8}
.stat h4{color:#94a3b8;font-size:12px;margin-bottom:6px;text-transform:uppercase}
.stat p{font-size:22px;font-weight:700;color:#38bdf8}
table{width:100%;border-collapse:collapse}
th,td{padding:10px;text-align:left;border-bottom:1px solid #1e293b;font-size:14px}
th{color:#94a3b8;font-size:12px;text-transform:uppercase}
.badge{padding:3px 10px;border-radius:20px;font-size:11px;font-weight:600}
.b-run{background:#065f46;color:#6ee7b7}.b-stop{background:#7f1d1d;color:#fca5a5}
.msg{padding:10px;background:#0c4a6e;border-radius:8px;margin-bottom:14px;font-size:14px;border:1px solid #0284c7}
a.action{color:#38bdf8;text-decoration:none;margin:0 4px;font-size:13px}
a.action:hover{text-decoration:underline}
.logo{font-size:22px}
</style></head><body>
<div class="nav"><b><span class="logo">🌌</span> Sky Management Panel</b><div>
{% if session.uid %}
<a href="/">Dashboard</a><a href="/vps">VPS</a><a href="/vps/create">+ Create</a>
{% if session.role=='admin' %}<a href="/admin/users">Users</a><a href="/admin/nodes">Nodes</a>{% endif %}
<a href="/logout">Logout ({{session.user}})</a>
{% endif %}</div></div>
<div class="wrap">{{{body}}}</div>
<footer style="text-align:center;padding:30px;color:#475569;font-size:12px">© 2026 Sky Management Panel · Owner: Vishal</footer>
</body></html>"""

def render(body, **kw):
    html = BASE.replace("{{{body}}}", body)
    for k,v in kw.items(): html = html.replace("{{"+k+"}}", str(v))
    return render_template_string(html)

@app.route("/login", methods=["GET","POST"])
def login():
    err=""
    if request.method=="POST":
        u=request.form["username"]; p=h(request.form["password"])
        row=db().execute("SELECT * FROM users WHERE username=? AND password=?",(u,p)).fetchone()
        if row:
            session.update(uid=row["id"], user=row["username"], role=row["role"])
            return redirect("/")
        err="Invalid credentials"
    body="""<div class="card" style="max-width:400px;margin:60px auto">
    <h3>🔐 Login to Sky Panel</h3>%s
    <form method="post"><input name="username" placeholder="Username" required>
    <input name="password" type="password" placeholder="Password" required>
    <button style="width:100%%">Login</button></form>
    <p style="margin-top:14px;font-size:13px;color:#64748b">New? <a href="/register" style="color:#38bdf8">Register</a></p>
    </div>""" % (f'<div class="msg">{err}</div>' if err else "")
    return render(body)

@app.route("/register", methods=["GET","POST"])
def register():
    err=""
    if request.method=="POST":
        u=request.form["username"]; p=h(request.form["password"])
        try:
            db().execute("INSERT INTO users (username,password,role,created_at) VALUES (?,?,?,?)",
                (u,p,"user",datetime.now().isoformat())); db().commit()
            return redirect("/login")
        except: err="Username taken"
    body="""<div class="card" style="max-width:400px;margin:60px auto">
    <h3>📝 Register</h3>%s
    <form method="post"><input name="username" placeholder="Username" required>
    <input name="password" type="password" placeholder="Password" required>
    <button style="width:100%%">Register</button></form>
    <p style="margin-top:14px;font-size:13px;color:#64748b">Have account? <a href="/login" style="color:#38bdf8">Login</a></p>
    </div>""" % (f'<div class="msg">{err}</div>' if err else "")
    return render(body)

@app.route("/logout")
def logout():
    session.clear(); return redirect("/login")

@app.route("/")
@login_required
def dashboard():
    uid = session["uid"]; role = session["role"]
    if role=="admin":
        vps_list = db().execute("SELECT * FROM vps").fetchall()
        users = db().execute("SELECT COUNT(*) c FROM users").fetchone()["c"]
        nodes = db().execute("SELECT COUNT(*) c FROM nodes").fetchone()["c"]
    else:
        vps_list = db().execute("SELECT * FROM vps WHERE user_id=?",(uid,)).fetchall()
        users = nodes = 0
    cpu = psutil.cpu_percent(interval=0.3); ram = psutil.virtual_memory().percent; disk = psutil.disk_usage("/").percent
    body=f"""<h2 style="margin-bottom:20px">Dashboard</h2>
    <div class="grid">
    <div class="stat"><h4>Total VPS</h4><p>{len(vps_list)}</p></div>
    <div class="stat"><h4>CPU Usage</h4><p>{cpu}%</p></div>
    <div class="stat"><h4>RAM Usage</h4><p>{ram}%</p></div>
    <div class="stat"><h4>Disk Usage</h4><p>{disk}%</p></div>
    <div class="stat"><h4>Users</h4><p>{users}</p></div>
    <div class="stat"><h4>Nodes</h4><p>{nodes}</p></div>
    </div>
    <div class="card" style="margin-top:20px"><h3>Recent VPS</h3>
    <table><tr><th>Name</th><th>OS</th><th>RAM</th><th>Status</th></tr>
    {''.join(f'<tr><td>{v["name"]}</td><td>{v["os"]}</td><td>{v["ram"]}MB</td><td><span class="badge b-{v["status"][:4]}">{v["status"]}</span></td></tr>' for v in vps_list[:5]) or '<tr><td colspan=4>No VPS yet</td></tr>'}
    </table></div>"""
    return render(body)

@app.route("/vps")
@login_required
def vps_list():
    uid = session["uid"]
    rows = db().execute("SELECT * FROM vps" if session["role"]=="admin" else "SELECT * FROM vps WHERE user_id=?", () if session["role"]=="admin" else (uid,)).fetchall()
    body="""<h2 style="margin-bottom:20px">My VPS</h2><div class="card">
    <table><tr><th>ID</th><th>Name</th><th>OS</th><th>RAM</th><th>CPU</th><th>Disk</th><th>IP</th><th>Status</th><th>Actions</th></tr>"""
    for v in rows:
        body += f"""<tr><td>{v['id']}</td><td>{v['name']}</td><td>{v['os']}</td><td>{v['ram']}MB</td><td>{v['cpu']}vCPU</td><td>{v['disk']}GB</td><td>{v['ip'] or '-'}</td>
        <td><span class="badge b-{v['status'][:4]}">{v['status']}</span></td>
        <td><a class="action" href="/vps/{v['id']}/toggle">{'Stop' if v['status']=='running' else 'Start'}</a>
        <a class="action" href="/vps/{v['id']}/delete" onclick="return confirm('Delete VPS?')" style="color:#f87171">Delete</a></td></tr>"""
    body += "</table></div>"
    return render(body)

@app.route("/vps/create", methods=["GET","POST"])
@login_required
def vps_create():
    if request.method=="POST":
        nodes = db().execute("SELECT name FROM nodes WHERE status='online'").fetchall()
        node = nodes[0]["name"] if nodes else "sky-node-1"
        db().execute("INSERT INTO vps (user_id,name,os,ram,cpu,disk,node,status,ip,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (session["uid"], request.form["name"], request.form["os"], int(request.form["ram"]),
             int(request.form["cpu"]), int(request.form["disk"]), node, "running",
             f"10.0.{secrets.randbelow(255)}.{secrets.randbelow(254)+1}", datetime.now().isoformat()))
        db().commit(); return redirect("/vps")
    body="""<h2>Create VPS</h2><div class="card" style="max-width:500px">
    <form method="post">
    <label style="font-size:13px;color:#94a3b8">VPS Name</label><input name="name" required>
    <label style="font-size:13px;color:#94a3b8">OS</label>
    <select name="os"><option>ubuntu-22.04</option><option>debian-12</option><option>centos-9</option><option>alpine-3.19</option></select>
    <label style="font-size:13px;color:#94a3b8">RAM (MB)</label><input name="ram" type="number" value="1024" min="512" required>
    <label style="font-size:13px;color:#94a3b8">CPU (vCPU)</label><input name="cpu" type="number" value="1" min="1" required>
    <label style="font-size:13px;color:#94a3b8">Disk (GB)</label><input name="disk" type="number" value="10" min="5" required>
    <button style="width:100%;margin-top:10px">🚀 Deploy VPS</button></form></div>"""
    return render(body)

@app.route("/vps/<int:vid>/toggle")
@login_required
def vps_toggle(vid):
    v = db().execute("SELECT * FROM vps WHERE id=?",(vid,)).fetchone()
    if v and (session["role"]=="admin" or v["user_id"]==session["uid"]):
        new = "stopped" if v["status"]=="running" else "running"
        db().execute("UPDATE vps SET status=? WHERE id=?",(new,vid)); db().commit()
    return redirect("/vps")

@app.route("/vps/<int:vid>/delete")
@login_required
def vps_delete(vid):
    v = db().execute("SELECT * FROM vps WHERE id=?",(vid,)).fetchone()
    if v and (session["role"]=="admin" or v["user_id"]==session["uid"]):
        db().execute("DELETE FROM vps WHERE id=?",(vid,)); db().commit()
    return redirect("/vps")

@app.route("/admin/users")
@login_required
@admin_required
def admin_users():
    rows = db().execute("SELECT * FROM users").fetchall()
    body="<h2>Users</h2><div class='card'><table><tr><th>ID</th><th>Username</th><th>Role</th><th>Created</th><th>Action</th></tr>"
    for u in rows:
        body+=f"<tr><td>{u['id']}</td><td>{u['username']}</td><td>{u['role']}</td><td>{u['created_at'][:10]}</td>"
        if u['username']!='admin': body+=f"<td><a class='action' href='/admin/users/{u['id']}/delete' onclick=\"return confirm('Delete user?')\" style='color:#f87171'>Delete</a></td>"
        else: body+="<td>-</td>"
        body+="</tr>"
    body+="</table></div>"
    return render(body)

@app.route("/admin/users/<int:uid>/delete")
@login_required
@admin_required
def admin_user_delete(uid):
    db().execute("DELETE FROM users WHERE id=? AND username!='admin'",(uid,)); db().commit()
    db().execute("DELETE FROM vps WHERE user_id=?",(uid,)); db().commit()
    return redirect("/admin/users")

@app.route("/admin/nodes", methods=["GET","POST"])
@login_required
@admin_required
def admin_nodes():
    if request.method=="POST":
        try:
            db().execute("INSERT INTO nodes (name,location,ip,status,created_at) VALUES (?,?,?,?,?)",
                (request.form["name"],request.form["location"],request.form["ip"],"online",datetime.now().isoformat()))
            db().commit()
        except: pass
        return redirect("/admin/nodes")
    rows = db().execute("SELECT * FROM nodes").fetchall()
    body="""<h2>Nodes</h2><div class="card"><form method="post" style="display:flex;gap:8px">
    <input name="name" placeholder="Node name" required><input name="location" placeholder="Location" required>
    <input name="ip" placeholder="IP" required><button>+ Add</button></form></div>
    <div class="card"><table><tr><th>ID</th><th>Name</th><th>Location</th><th>IP</th><th>Status</th><th>Action</th></tr>"""
    for n in rows:
        body+=f"<tr><td>{n['id']}</td><td>{n['name']}</td><td>{n['location']}</td><td>{n['ip']}</td><td><span class='badge b-run'>{n['status']}</span></td><td><a class='action' href='/admin/nodes/{n['id']}/delete' style='color:#f87171' onclick=\"return confirm('Delete?')\">Delete</a></td></tr>"
    body+="</table></div>"
    return render(body)

@app.route("/admin/nodes/<int:nid>/delete")
@login_required
@admin_required
def admin_node_delete(nid):
    db().execute("DELETE FROM nodes WHERE id=?",(nid,)); db().commit()
    return redirect("/admin/nodes")

@app.route("/api/stats")
def api_stats():
    return jsonify({"cpu":psutil.cpu_percent(),"ram":psutil.virtual_memory().percent,"disk":psutil.disk_usage("/").percent,"panel":PANEL,"owner":OWNER})

@app.route("/health")
def health():
    return jsonify({"status":"ok","panel":PANEL,"owner":OWNER})

if __name__=="__main__":
    print(f"\n🌌 {PANEL} © {OWNER}")
    print(f"🌐 http://0.0.0.0:5000")
    print(f"👤 Login: admin / admin123\n")
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT",5000)), debug=False)
