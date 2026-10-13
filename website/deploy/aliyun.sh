#!/bin/bash
# Run as root through the existing Alibaba Cloud command assistant.
# Usage: bash aliyun.sh <full Git commit SHA>
set -euo pipefail
sha="${1:?Supply full commit SHA}"
[[ "$sha" =~ ^[a-f0-9]{40}$ ]] || { echo 'Invalid SHA'; exit 1; }
base=/opt/videonotes-web
config=/etc/paper-checker/nginx.conf
[[ -f "$config" ]] || { echo 'Existing HTTPS config missing'; exit 1; }
systemctl is-active --quiet paper-checker-proxy
systemctl is-active --quiet paper-format-checker
install -d -m 755 "$base/releases" "$base/backups"
release="$base/releases/$sha"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ -n "${2:-}" ]]; then
    [[ "${3:-}" =~ ^[a-f0-9]{64}$ ]] || { echo 'Supply archive SHA-256'; exit 1; }
    printf '%s  %s\n' "$3" "$2" | sha256sum -c -
    cp "$2" "$tmp/source.tar.gz"
else
    curl --fail --location --retry 2 --max-time 180 "https://codeload.github.com/count110/VideoNotes/tar.gz/$sha" -o "$tmp/source.tar.gz"
fi
tar -xzf "$tmp/source.tar.gz" -C "$tmp" "VideoNotes-$sha/website"
site="$tmp/VideoNotes-$sha/website"
(cd "$site" && sha256sum -c manifest.sha256)
install -d -m 755 "$release/assets"
for name in index.html style.css app.js model.mjs; do install -m 644 "$site/$name" "$release/$name"; done
install -m 644 "$site/assets/icon.png" "$release/assets/icon.png"
printf '%s\n' "$sha" > "$release/version.txt"
backup="$base/backups/nginx-$(date +%Y%m%d%H%M%S).conf"
cp -p "$config" "$backup"
previous=$(readlink "$base/current" || true)
export config
python3.11 - <<'PY'
from pathlib import Path
import os
p=Path(os.environ['config']);s=p.read_text()
block='''        # BEGIN VIDEONOTES WEB
        location = /videonotes { return 302 /videonotes/; }
        location ^~ /videonotes/ {
            alias /opt/videonotes-web/current/;
            index index.html;
            autoindex off;
            limit_except GET HEAD { deny all; }
            types { text/html html; text/css css; application/javascript js mjs; image/png png; text/plain txt; }
            default_type application/octet-stream;
            add_header X-Content-Type-Options nosniff always;
            add_header Referrer-Policy strict-origin-when-cross-origin always;
            add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'none'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'" always;
            add_header Cache-Control "no-cache" always;
        }
        # END VIDEONOTES WEB
'''
if '# BEGIN VIDEONOTES WEB' not in s:
 if '/videonotes' in s: raise SystemExit('Existing VideoNotes route needs inspection')
 anchor='        location = /health { proxy_pass http://127.0.0.1:8000; }'
 if s.count(anchor)!=1:raise SystemExit('Expected HTTPS health route missing or ambiguous')
 s=s.replace(anchor,block+anchor,1)
 p.write_text(s)
else:
 if block not in s:raise SystemExit('Existing VideoNotes config differs, inspection required')
PY
rollback(){ cp -p "$backup" "$config"; if [[ -n "$previous" ]]; then ln -sfn "$previous" "$base/current"; else rm -f "$base/current"; fi; nginx -t -c "$config" && systemctl reload paper-checker-proxy; }
if ! nginx -t -c "$config"; then rollback; exit 1; fi
ln -sfn "$release" "$base/current.next"
mv -Tf "$base/current.next" "$base/current"
if ! systemctl reload paper-checker-proxy; then rollback; exit 1; fi
if ! curl -fsS --resolve api.lwgsjc.online:443:127.0.0.1 https://api.lwgsjc.online/videonotes/version.txt | grep -Fx "$sha"; then rollback; exit 1; fi
if ! curl -fsS --resolve api.lwgsjc.online:443:127.0.0.1 https://api.lwgsjc.online/health; then rollback; exit 1; fi
printf '\nDEPLOY_OK %s\nBACKUP %s\nPREVIOUS %s\n' "$sha" "$backup" "$previous"
