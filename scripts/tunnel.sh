#!/usr/bin/env bash
# Open the lab's portal from this Mac: the lab binds everything to 127.0.0.1 on the
# droplet, and every URL (portal, muster, Dex issuer) contains host and port, so the
# local ports must equal the remote ones. Needs the lab CA trusted once:
#   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/ca.crt
# Then: https://backstage.127.0.0.1.nip.io  (admin@lab.local / password)
# If nip.io does not resolve (VPN DNS), add to /etc/hosts:
#   127.0.0.1 backstage.127.0.0.1.nip.io muster.127.0.0.1.nip.io agentgateway.127.0.0.1.nip.io
set -euo pipefail
HOST="${LAB_HOST:-157.230.107.141}"
KEY="${LAB_KEY:-$HOME/.ssh/do_agentlab}"
exec ssh -i "$KEY" -N \
  -L 443:127.0.0.1:443 \
  -L 32000:127.0.0.1:32000 \
  -L 8081:127.0.0.1:8081 \
  "root@$HOST"
