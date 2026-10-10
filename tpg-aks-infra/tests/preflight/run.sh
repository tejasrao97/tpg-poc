#!/usr/bin/env bash
# scripts/targets/precreated/preflight.sh, backup storage section, against a
# stubbed az.
#
# What this proves (design decision I22): the "Secure transfer required" setting
# of the backup storage account is read as the account reports it. The check
# ended its jq expression in a true fallback after //, and jq's // replaces
# false as well as null, so an account with secure transfer turned off
# was reported as HTTPS only and the preflight failed. The fixed expression tests
# for null. tpg-fleet tests/cli-flags (check_zero_defaults.py) keeps the pattern
# out of both repositories.
#
# The clusters use kubeconfig access, so the only az calls are the login check,
# the storage account and the container checks, all answered by the stub below.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP tests/preflight: jq not installed" >&2; exit 0; }
command -v yq >/dev/null || { echo "SKIP tests/preflight: yq not installed" >&2; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/az" <<'STUB'
#!/usr/bin/env bash
# Stub az: the storage account JSON comes from $STUB_SA_JSON.
case "$1 $2" in
  "account show"|"account set") echo '{}' ;;
  "storage account") [[ "$3" == "show" ]] && cat "$STUB_SA_JSON" ;;
  "storage container") [[ "$3" == "exists" ]] && echo true ;;
  *) echo "stub az: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/az"
export PATH="$TMP/bin:$PATH"
export ENV_FILE="$TMP/env.sh"; : > "$ENV_FILE"
export INVENTORY="$TMP/inventory.yaml" STUB_SA_JSON="$TMP/sa.json"
export BACKUP_STORAGE_KEY="stub-key-not-a-secret"
: > "$TMP/kubeconfig"
write_inventory() {   # write_inventory HTTPS_ONLY (true, false or "" for not set)
  local https=""
  [[ -n "$1" ]] && https=", httpsOnly: $1"
  cat > "$INVENTORY" <<YAML
subscriptionId: 11111111-2222-3333-4444-555555555555
adminAllowedCidrs: ["203.0.113.10/32"]
hub: {name: aks-tpg-hub, resourceGroup: rg-tpgpoc, access: kubeconfig, kubeconfig: $TMP/kubeconfig,
      context: hub, egressCidrs: ["198.51.100.7/32"]}
targets:
  - {name: aks-tpg-poc-01, resourceGroup: rg-tpgpoc, wave: 0, access: kubeconfig,
     kubeconfig: $TMP/kubeconfig, context: poc-01, backupContainer: pg-backups-aks-tpg-poc-01}
backup: {storageAccount: tpgpocbkp, resourceGroup: rg-tpgpoc, createContainers: false, keySource: env${https}}
storage: {dataDiskSku: StandardSSD_LRS}
vault: {unsealMode: shamir, exposure: public}
YAML
}

PASS=0; FAIL=0
strip_ansi() { sed -E $'s/\033\\[[0-9;]*m//g'; }
# check NAME SA_JSON HTTPS_ONLY WANT_RC PATTERN
check() {
  local name="$1" rc=0
  echo "$2" > "$STUB_SA_JSON"
  write_inventory "$3"
  bash "$ROOT/scripts/targets/precreated/preflight.sh" > "$TMP/out" 2>&1 || rc=$?
  strip_ansi < "$TMP/out" > "$TMP/all"
  if { [[ "$4" == "0" && "$rc" == "0" ]] || [[ "$4" != "0" && "$rc" != "0" ]]; } && grep -Eq "$5" "$TMP/all"; then
    printf 'ok   %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'FAIL %s (exit %s, expected %s; pattern %s)\n' "$name" "$rc" "$4" "$5"
    sed 's/^/       /' "$TMP/all"; FAIL=$((FAIL + 1))
  fi
}

check "secure transfer off (enableHttpsTrafficOnly false) is read as false" \
  '{"allowSharedKeyAccess": true, "enableHttpsTrafficOnly": false}' "" 0 \
  'tpgpocbkp: HTTP and HTTPS accepted'
check "secure transfer on, fleet default enableSSL false: refused with the fix" \
  '{"allowSharedKeyAccess": true, "enableHttpsTrafficOnly": true}' "" 1 \
  'tpgpocbkp requires secure transfer \(HTTPS only\).*--https-only false'
check "secure transfer on with backup.httpsOnly true: accepted" \
  '{"allowSharedKeyAccess": true, "enableHttpsTrafficOnly": true}' true 0 \
  'tpgpocbkp: HTTPS only \(backup.httpsOnly: true'
check "older field supportsHttpsTrafficOnly false is read as false" \
  '{"allowSharedKeyAccess": true, "supportsHttpsTrafficOnly": false}' "" 0 \
  'tpgpocbkp: HTTP and HTTPS accepted'
check "neither field reported: the Azure default (on) is assumed" \
  '{"allowSharedKeyAccess": true}' "" 1 \
  'tpgpocbkp requires secure transfer'
check "the newer field wins over the older one" \
  '{"allowSharedKeyAccess": true, "enableHttpsTrafficOnly": false, "supportsHttpsTrafficOnly": true}' "" 0 \
  'tpgpocbkp: HTTP and HTTPS accepted'

echo
echo "preflight: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
