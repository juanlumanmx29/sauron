# Banco de pruebas del puente de permisos de Sauron, con una copia falsa de
# ~/.claude. Detener antes el Sauron instalado (comparten el socket):
#   launchctl bootout gui/$(id -u)/local.sauron
#   python3 pruebas/permisos.py <carpeta temporal> build.noindex/Sauron.app/Contents/MacOS/Sauron
import json, os, shutil, signal, socket, stat, subprocess, sys, time

W, BIN = sys.argv[1], sys.argv[2]
falso = os.path.join(W, 'claude')
shutil.rmtree(falso, ignore_errors=True)
for d in ('sessions', 'ide', 'projects'):
    os.makedirs(os.path.join(falso, d))
SOCK = os.path.expanduser('~/Library/Application Support/Sauron/permisos.sock')

# Proceso propio y vivo que hace de "Claude Code" y de "VS Code".
dormido = subprocess.Popen(['sleep', '600'])
PID = dormido.pid
S1, S2 = '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'

def ms(): return int(time.time() * 1000)
def registro(nombre, sid, status, waiting=None):
    d = {"pid": PID, "sessionId": sid, "cwd": "/ejemplo/api", "entrypoint": "claude-vscode",
         "kind": "interactive", "status": status, "statusUpdatedAt": ms(), "updatedAt": ms()}
    if waiting: d["waitingFor"] = waiting
    with open(os.path.join(falso, 'sessions', nombre + '.json'), 'w') as f: json.dump(d, f)
registro('s1', S1, 'waiting', 'permission prompt')
registro('s2', S2, 'idle')
with open(os.path.join(falso, 'ide', '1.lock'), 'w') as f:
    json.dump({"pid": PID, "workspaceFolders": ["/ejemplo/api"]}, f)
os.makedirs(os.path.join(falso, 'projects', '-ejemplo-api'))
for sid, titulo in ((S1, 'Migrar autenticación a OAuth'), (S2, 'Revisar dependencias')):
    with open(os.path.join(falso, 'projects', '-ejemplo-api', sid + '.jsonl'), 'w') as f:
        f.write(json.dumps({"type": "user", "permissionMode": "default"}) + '\n')
        f.write(json.dumps({"type": "ai-title", "aiTitle": titulo}) + '\n')

def peticion(sid, **extra):
    d = {"session_id": sid, "transcript_path": "/x.jsonl", "cwd": "/ejemplo/api",
         "permission_mode": "default", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
         "tool_input": {"command": "npm run build --prefix web", "description": "Compilar la interfaz"}}
    d.update(extra)
    return json.dumps(d).encode()

def hook(sid, entrada='claude-vscode', **kw):
    env = dict(os.environ, CLAUDE_CODE_ENTRYPOINT=entrada)
    t0 = time.time()
    p = subprocess.Popen([BIN, '--hook-permiso'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    p.stdin.write(peticion(sid, **kw)); p.stdin.close()
    return p, t0

def esperar(p, t0, limite=20):
    try: p.wait(timeout=limite)
    except subprocess.TimeoutExpired:
        p.kill(); return None, None, time.time() - t0
    return p.returncode, p.stdout.read().decode(), time.time() - t0

def sauron(*args, extra_env=None):
    env = dict(os.environ, SAURON_CLAUDE_DIR=falso, **(extra_env or {}))
    return subprocess.Popen([BIN, *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True)

def esperar_socket(limite=5):
    fin = time.time() + limite
    while time.time() < fin:
        if os.path.exists(SOCK): return True
        time.sleep(0.05)
    return False

resultados = []
def informe(nombre, ok, detalle):
    resultados.append((nombre, ok))
    print(('OK   ' if ok else 'FALLA') + '  ' + nombre + ' :: ' + detalle)

# E: Sauron apagado -> sale al instante sin decidir
if os.path.exists(SOCK): os.unlink(SOCK)
p, t0 = hook(S1); rc, out, dt = esperar(p, t0)
informe('Sauron apagado', rc == 0 and out == '' and dt < 1, f'rc={rc} salida={out!r} {dt*1000:.0f} ms')

# A: permitir de punta a punta (autoprueba contesta "permitir")
s = sauron('--autoprueba', os.path.join(W, 'autoprueba-permitir'))
esperar_socket()
modo = oct(stat.S_IMODE(os.stat(SOCK).st_mode)); carpeta = oct(stat.S_IMODE(os.stat(os.path.dirname(SOCK)).st_mode))
informe('permisos del socket', modo == '0o600' and carpeta == '0o700', f'socket {modo}, carpeta {carpeta}')
time.sleep(0.5)
p, t0 = hook(S1); rc, out, dt = esperar(p, t0)
salida_a = s.communicate(timeout=20)[0]
try: dec = json.loads(out)['hookSpecificOutput']['decision']['behavior']
except Exception: dec = None
informe('permitir', rc == 0 and dec == 'allow', f'rc={rc} salida={out!r} tras {dt:.1f} s')
for l in salida_a.splitlines():
    if any(k in l for k in ('permiso', 'respondido', 'canal')): print('        ' + l.strip())

# B: rechazar
s = sauron('--autoprueba', os.path.join(W, 'autoprueba-rechazar'), extra_env={'SAURON_PRUEBA_RECHAZAR': '1'})
esperar_socket(); time.sleep(0.5)
p, t0 = hook(S1); rc, out, dt = esperar(p, t0)
s.communicate(timeout=20)
try:
    d = json.loads(out)['hookSpecificOutput']; dec = d['decision']['behavior']; msj = d['decision'].get('message')
except Exception: dec = msj = None
informe('rechazar', rc == 0 and dec == 'deny' and bool(msj), f'rc={rc} salida={out!r}')

# D: el hook muere a mitad de camino -> Sauron lo retira
s = sauron('--autoprueba', os.path.join(W, 'autoprueba-muerto'))
esperar_socket(); time.sleep(0.3)
p, t0 = hook(S1); time.sleep(1.0); p.kill(); p.wait()
salida_d = s.communicate(timeout=20)[0]
informe('hook muerto se retira', 'permisos pendientes: 0' in salida_d,
        [l.strip() for l in salida_d.splitlines() if 'pendiente' in l][:1].__str__())

# C, F, G con Sauron normal (sin autoprueba)
s = sauron()
esperar_socket(); time.sleep(0.8)
# C: sesion que no espera -> se suelta tras el margen
p, t0 = hook(S2); rc, out, dt = esperar(p, t0, limite=10)
informe('sesión que no espera', rc == 0 and out == '' and 2.0 < dt < 6, f'rc={rc} salida={out!r} tras {dt:.1f} s')
# F: sesion de terminal -> sale al instante
p, t0 = hook(S1, entrada='cli'); rc, out, dt = esperar(p, t0)
informe('sesión de terminal', rc == 0 and out == '' and dt < 1, f'rc={rc} salida={out!r} {dt*1000:.0f} ms')
s.terminate(); s.wait()

# G: impostor escuchando en el socket -> el hook no le manda nada
if os.path.exists(SOCK): os.unlink(SOCK)
imp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); imp.bind(SOCK); imp.listen(1); imp.settimeout(5)
p, t0 = hook(S1)
conn, _ = imp.accept(); conn.settimeout(3)
recibido = b''
try:
    while True:
        b = conn.recv(65536)
        if not b: break
        recibido += b
except socket.timeout: pass
rc, out, dt = esperar(p, t0)
informe('impostor no recibe nada', rc == 0 and out == '' and recibido == b'', f'recibió {len(recibido)} bytes, rc={rc}')
conn.close(); imp.close(); os.unlink(SOCK)

dormido.terminate()
print(f"\n{sum(ok for _, ok in resultados)}/{len(resultados)} pruebas correctas")
