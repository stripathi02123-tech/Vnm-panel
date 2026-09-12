#!/usr/bin/env bash
set -Eeuo pipefail
APP='/opt/hkvm/app/app.js'; ENV='/etc/hkvm/hkvm.env'; LOG='/opt/hkvm/logs/hkvm.log'; PID='/opt/hkvm/hkvm.pid'
[[ $EUID -eq 0 ]] || { echo '[ERROR] Run as root.'; exit 1; }
[[ -f "$APP" ]] || { echo "[ERROR] $APP not found."; exit 1; }
cp -a "$APP" "$APP.bak.$(date +%Y%m%d-%H%M%S)"
python3 - "$APP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old="""function csrfProtection(req, res, next) {
  const mutating = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method);
  if (!mutating || CSRF_EXEMPT_PATHS.has(req.path) || req.path.startsWith('/api/auth/')) {
    return next();
  }
"""
new="""function csrfProtection(req, res, next) {
  const mutating = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method);
  const requestPath = (req.originalUrl || req.url || '').split('?')[0];
  if (!mutating || CSRF_EXEMPT_PATHS.has(requestPath) || requestPath.startsWith('/api/auth/')) {
    return next();
  }
"""
if "const requestPath = (req.originalUrl || req.url || '').split('?')[0];" not in s:
    if old not in s: raise SystemExit('Expected CSRF block not found')
    s=s.replace(old,new,1); p.write_text(s)
PY
echo '[OK] CSRF middleware fixed.'
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && systemctl list-unit-files 2>/dev/null | grep -q '^hkvm\.service'; then
 systemctl restart hkvm; echo '[OK] HKVM service restarted.'
else
 if [[ -f "$PID" ]]; then kill "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID"; fi
 cd /opt/hkvm/app; set -a; source "$ENV"; set +a
 if node -e 'const p=require("./package.json"); process.exit(p.scripts&&p.scripts.start?0:1)' >/dev/null 2>&1; then nohup npm start >>"$LOG" 2>&1 &
 else MAIN="$(node -e 'const p=require("./package.json"); process.stdout.write(p.main||"")')"; [[ -n "$MAIN" ]] || { echo '[ERROR] No main entry.'; exit 1; }; nohup node "$MAIN" >>"$LOG" 2>&1 & fi
 echo $! > "$PID"; sleep 3; kill -0 "$(cat "$PID")" 2>/dev/null || { echo '[ERROR] HKVM failed to restart.'; tail -n 80 "$LOG"; exit 1; }; echo '[OK] HKVM restarted in standalone mode.'
fi
echo '[OK] Refresh the login page and try again.'
