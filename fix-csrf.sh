#!/usr/bin/env bash
set -Eeuo pipefail

APP='/opt/hkvm/app/app.js'
ENV='/etc/hkvm/hkvm.env'
LOG='/opt/hkvm/logs/hkvm.log'
PID='/opt/hkvm/hkvm.pid'
SERVICE='hkvm'
PORT='8080'

[[ $EUID -eq 0 ]] || { echo '[ERROR] Run as root.'; exit 1; }
[[ -f "$APP" ]] || { echo "[ERROR] $APP not found."; exit 1; }

mkdir -p "$(dirname "$LOG")"
touch "$LOG"

# Backup before modifying the application.
cp -a "$APP" "$APP.bak.$(date +%Y%m%d-%H%M%S)"

python3 - "$APP" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

# Make both real login routes exempt. The running VNM/HKVM code uses POST /login.
set_pattern = re.compile(
    r"const CSRF_EXEMPT_PATHS\s*=\s*new Set\(\[(.*?)\]\);",
    re.S,
)
m = set_pattern.search(s)
if not m:
    raise SystemExit('Expected CSRF_EXEMPT_PATHS block was not found')

body = m.group(1)
entries = [x.strip() for x in body.split(',') if x.strip()]
for path in ["'/login'", "'/api/login'"]:
    if path not in entries:
        body = body.rstrip() + f"\n  {path},"
s = s[:m.start(1)] + body + s[m.end(1):]

# Normalize the URL before checking exemptions. This works whether the middleware
# is mounted globally or beneath /api.
old_logic = re.compile(
    r"function csrfProtection\(req, res, next\)\s*\{.*?\n\s*next\(\);\n\}",
    re.S,
)
new_logic = '''function csrfProtection(req, res, next) {
  const mutating = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method);
  const requestPath = (req.originalUrl || req.url || req.path || '/').split('?')[0];
  const normalizedPath = requestPath.replace(/\\/+$/, '') || '/';
  const loginPath = normalizedPath === '/login' || normalizedPath === '/api/login';

  if (
    !mutating ||
    loginPath ||
    CSRF_EXEMPT_PATHS.has(normalizedPath) ||
    normalizedPath.startsWith('/api/auth/')
  ) {
    return next();
  }

  const headerToken = req.get('x-csrf-token');
  if (!headerToken || headerToken !== req.session.csrfToken) {
    console.warn(`[CSRF] Rejected ${req.method} ${normalizedPath} (bad/missing token) from ${req.ip}`);
    return res.status(403).json({ error: 'Invalid or missing CSRF token' });
  }
  next();
}'''

if 'const loginPath = normalizedPath === \'/login\' || normalizedPath === \'/api/login\';' not in s:
    match = old_logic.search(s)
    if not match:
        raise SystemExit('Expected csrfProtection function was not found')
    s = s[:match.start()] + new_logic + s[match.end():]

p.write_text(s, encoding='utf-8')
PY

echo '[OK] CSRF middleware fixed for both /login and /api/login.'

# ------------------------------------------------------------
# Stop the existing HKVM process before restarting.
# IMPORTANT: the old installer could leave an orphan process alive
# without a valid PID file. Detect the actual listener on port 8080.
# ------------------------------------------------------------

stop_existing() {
  echo "[INFO] Stopping existing HKVM listeners on port ${PORT}..."

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && \
     systemctl list-unit-files 2>/dev/null | grep -q '^hkvm\\.service'; then
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  fi

  if [[ -f "$PID" ]]; then
    old_pid="$(cat "$PID" 2>/dev/null || true)"
    if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
      kill "$old_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PID"
  fi

  if command -v lsof >/dev/null 2>&1; then
    mapfile -t port_pids < <(lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
    for port_pid in "${port_pids[@]:-}"; do
      [[ "$port_pid" =~ ^[0-9]+$ ]] || continue

      args="$(ps -p "$port_pid" -o args= 2>/dev/null || true)"
      cwd="$(readlink -f "/proc/${port_pid}/cwd" 2>/dev/null || true)"

      # Only terminate the HKVM/VNM application, never an unrelated service.
      if [[ "$cwd" == '/opt/hkvm/app' ]] || \
         [[ "$args" == *'/opt/hkvm/app/app.js'* ]] || \
         [[ "$args" == *'npm start'* && "$cwd" == '/opt/hkvm/app' ]]; then
        echo "[INFO] Stopping HKVM PID ${port_pid}..."
        kill "$port_pid" >/dev/null 2>&1 || true
      fi
    done

    for _ in {1..10}; do
      remaining="$(lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
      [[ -z "$remaining" ]] && break
      sleep 0.5
    done

    # Force-stop only remaining HKVM listeners.
    mapfile -t remaining_pids < <(lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
    for port_pid in "${remaining_pids[@]:-}"; do
      [[ "$port_pid" =~ ^[0-9]+$ ]] || continue
      args="$(ps -p "$port_pid" -o args= 2>/dev/null || true)"
      cwd="$(readlink -f "/proc/${port_pid}/cwd" 2>/dev/null || true)"
      if [[ "$cwd" == '/opt/hkvm/app' ]] || [[ "$args" == *'/opt/hkvm/app/app.js'* ]]; then
        echo "[WARNING] Force-stopping stuck HKVM PID ${port_pid}..."
        kill -9 "$port_pid" >/dev/null 2>&1 || true
      fi
    done
  fi

  # Remove a stale PID file after cleanup.
  rm -f "$PID"
}

stop_existing

# ------------------------------------------------------------
# Restart
# ------------------------------------------------------------

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && \
   systemctl list-unit-files 2>/dev/null | grep -q '^hkvm\\.service'; then

  systemctl daemon-reload
  systemctl start "$SERVICE"
  sleep 4

  if systemctl is-active --quiet "$SERVICE"; then
    echo '[OK] HKVM service restarted.'
  else
    echo '[ERROR] HKVM service failed to restart.'
    journalctl -u "$SERVICE" -n 100 --no-pager || true
    exit 1
  fi

else

  cd /opt/hkvm/app
  set -a
  [[ -f "$ENV" ]] && source "$ENV"
  set +a

  START_CMD=''

  if node -e 'const p=require("./package.json"); process.exit(p.scripts&&p.scripts.start?0:1)' >/dev/null 2>&1; then
    START_CMD='npm start'
  else
    MAIN="$(node -e 'const p=require("./package.json"); process.stdout.write(p.main||"")' 2>/dev/null || true)"
    [[ -n "$MAIN" ]] || {
      echo '[ERROR] No application start script or package.json main entry.'
      exit 1
    }
    START_CMD="node $MAIN"
  fi

  echo "[INFO] Starting HKVM: ${START_CMD}"
  nohup bash -c "exec ${START_CMD}" >>"$LOG" 2>&1 &
  NEW_PID=$!
  echo "$NEW_PID" > "$PID"

  sleep 4

  if ! kill -0 "$NEW_PID" >/dev/null 2>&1; then
    echo '[ERROR] HKVM failed to restart.'
    echo '---------------- HKVM LOG ----------------'
    tail -n 160 "$LOG" || true
    echo '--------------------------------------------'
    exit 1
  fi

  if command -v lsof >/dev/null 2>&1 && \
     ! lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo '[ERROR] HKVM process is alive but port 8080 is not listening.'
    tail -n 100 "$LOG" || true
    exit 1
  fi

  echo '[OK] HKVM restarted in standalone mode.'
fi

echo '[OK] Refresh the login page completely and try signing in again.'
echo '[OK] Use Ctrl+Shift+R to clear the cached login page.'
