#!/usr/bin/env bash
set -Eeuo pipefail

APP='/opt/hkvm/app/app.js'
ENV='/etc/hkvm/hkvm.env'
LOG='/opt/hkvm/logs/hkvm.log'
PID='/opt/hkvm/hkvm.pid'
SERVICE='hkvm'

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

# Ensure both possible login routes are explicitly exempt.
set_pattern = re.compile(
    r"const CSRF_EXEMPT_PATHS\s*=\s*new Set\(\[(.*?)\]\);",
    re.S,
)
m = set_pattern.search(s)
if m:
    body = m.group(1)
    entries = [x.strip() for x in body.split(',') if x.strip()]
    for path in ["'/login'", "'/api/login'"]:
        if path not in entries:
            body = body.rstrip() + f"\n  {path},"
    s = s[:m.start(1)] + body + s[m.end(1):]

# Replace the CSRF decision logic with path normalization that works both
# when the middleware is mounted globally and when it is mounted at /api.
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

if 'const loginPath = normalizedPath === \'/login\' || normalizedPath === \'/api/login\';' in s:
    pass
else:
    match = old_logic.search(s)
    if match:
        s = s[:match.start()] + new_logic + s[match.end():]
    else:
        raise SystemExit('Expected csrfProtection function was not found')

p.write_text(s, encoding='utf-8')
PY

echo '[OK] CSRF middleware fixed for both /login and /api/login.'

# ------------------------------------------------------------
# Stop any existing HKVM instance before starting a new one.
# This prevents EADDRINUSE when an old process is still listening.
# ------------------------------------------------------------

stop_existing() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && systemctl list-unit-files 2>/dev/null | grep -q '^hkvm\.service'; then
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    return
  fi

  if [[ -f "$PID" ]]; then
    old_pid="$(cat "$PID" 2>/dev/null || true)"
    if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
      kill "$old_pid" >/dev/null 2>&1 || true
      for _ in {1..10}; do
        kill -0 "$old_pid" >/dev/null 2>&1 || break
        sleep 0.2
      done
      kill -9 "$old_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PID"
  fi

  # Catch an orphaned process from a previous broken installer run.
  while read -r orphan_pid; do
    [[ -z "$orphan_pid" ]] && continue
    kill "$orphan_pid" >/dev/null 2>&1 || true
  done < <(pgrep -f '^node /opt/hkvm/app/app\.js$' 2>/dev/null || true)
}

stop_existing

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && systemctl list-unit-files 2>/dev/null | grep -q '^hkvm\.service'; then
  systemctl restart "$SERVICE"
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
    [[ -n "$MAIN" ]] || { echo '[ERROR] No application start script or package.json main entry.'; exit 1; }
    START_CMD="node $MAIN"
  fi

  nohup bash -c "exec $START_CMD" >>"$LOG" 2>&1 &
  NEW_PID=$!
  echo "$NEW_PID" > "$PID"
  sleep 4

  if kill -0 "$NEW_PID" >/dev/null 2>&1; then
    echo '[OK] HKVM restarted in standalone mode.'
  else
    echo '[ERROR] HKVM failed to restart.'
    echo '---------------- HKVM LOG ----------------'
    tail -n 120 "$LOG" || true
    echo '--------------------------------------------'
    exit 1
  fi
fi

echo '[OK] Refresh the login page completely and try signing in again.'
