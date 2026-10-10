#!/usr/bin/env bash
# Replace the https://github.com/<org>/tpg-fleet.git placeholder with your repository URL.
# Usage: scripts/set-repo-url.sh https://github.com/acme/tpg-fleet.git
# Safe to re-run: with no placeholder left it changes nothing and exits 0
# (tpg-aks-infra scripts/jumpbox/push-fleet-repo.sh runs it on every push).
set -euo pipefail
URL="${1:?repository URL}"
# https only (Argo CD and the workflows authenticate with tokens), and no
# credentials in the URL: it lands in committed files
[[ "$URL" =~ ^https://[^/@[:space:]]+/[^[:space:]#]+$ ]] \
  || { echo "set-repo-url.sh: expected https://<host>/<owner>/<repository>.git without credentials, got: $URL" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# grep exits 1 when no file matches: not an error here. This script keeps its
# own copy of the placeholder, so that it still works after a re-run.
files="$(grep -rl --exclude-dir=.git --exclude=set-repo-url.sh 'https://github.com/<org>/tpg-fleet.git' "$ROOT" || true)"
if [[ -z "$files" ]]; then
  echo "no placeholder left: nothing to update"
  exit 0
fi
while read -r f; do
  sed -i.bak "s#https://github.com/<org>/tpg-fleet.git#${URL}#g" "$f" && rm -f "$f.bak"
  echo "updated ${f#"$ROOT"/}"
done <<<"$files"
