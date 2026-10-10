#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2001,SC2034  # check() evaluates its single-quoted conditions; rc is read inside them
# scripts/vault-secret.sh against stand-ins of Vault (Round 15, D86 and D87).
#
# Both transports: kubectl exec into vault-0 (a stub kubectl that runs a fake
# vault CLI, tests/vault-secret/fake-vault.py, which accepts only the argument
# forms the script is meant to use) and --vault-addr (an HTTPS mock of the Vault
# API, mock_vault.py). Proves: a bundle is checked (PEM, not expired) before it
# is written; put, get, list and delete round-trip; wrap prints only the token on
# stdout and wraps exactly the keys tpg-rotate-credential expects; values come
# from the environment and never appear in a command-line argument.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
S="${ROOT}/scripts/vault-secret.sh"
for c in python3 openssl jq yq curl; do
  command -v "$c" >/dev/null || { echo "SKIP tests/vault-secret: $c not installed" >&2; exit 0; }
done
TMP="$(mktemp -d)"; PID=""
trap '[[ -z "$PID" ]] || kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export ENV_FILE="$TMP/env.sh"; : > "$ENV_FILE"
export INVENTORY="$TMP/inventory.yaml"
cat > "$INVENTORY" <<'YAML'
subscriptionId: 11111111-2222-3333-4444-555555555555
hub: {name: aks-tpg-hub}
targets: []
backup: {storageAccount: sttpgbackup01}
YAML
unset VAULT_TOKEN BROADCOM_USER BROADCOM_TOKEN GITHUB_USER GIT_READ_PAT GIT_PUSH_PAT BACKUP_STORAGE_ACCOUNT BACKUP_STORAGE_KEY REMOTE_WRITE_PASSWORD VAULT_UI_PASSWORD

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || sed 's/^/       | /' <<<"$2"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# certificates: a valid CA, an expired one
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=test-ca -keyout "$TMP/ca.key" -out "$TMP/ca.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=second-ca -keyout "$TMP/ca2.key" -out "$TMP/ca2.pem" 2>/dev/null
cat "$TMP/ca.pem" "$TMP/ca2.pem" > "$TMP/bundle.pem"
if openssl req -x509 -newkey rsa:2048 -nodes -not_before 20200101000000Z -not_after 20200201000000Z -subj /CN=old \
     -keyout "$TMP/old.key" -out "$TMP/old.pem" 2>/dev/null; then HAVE_OLD=1
elif python3 - "$TMP/old.pem" <<'PY' 2>/dev/null; then HAVE_OLD=1; else HAVE_OLD=0; echo "note: no expired test certificate (OpenSSL before 3.4 and no python cryptography)"; fi
import datetime, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
n = x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "old")])
c = (x509.CertificateBuilder().subject_name(n).issuer_name(n).public_key(k.public_key())
     .serial_number(1).not_valid_before(datetime.datetime(2020, 1, 1)).not_valid_after(datetime.datetime(2020, 2, 1))
     .sign(k, hashes.SHA256()))
open(sys.argv[1], "wb").write(c.public_bytes(serialization.Encoding.PEM))
PY
printf 'not a certificate\n' > "$TMP/junk.pem"

# ================================================================ kubectl exec
echo "== 1. kubectl exec into vault-0"
export PATH="${HERE}/bin:${PATH}" FAKE_VAULT_STATE="$TMP/fake.json"
out="$(bash "$S" ca put azure-storage "$TMP/bundle.pem" 2>&1)" && rc=0 || rc=$?
check "ca put writes tpg/ca-bundles/azure-storage" \
  '[[ $rc == 0 ]] && [[ "$(jq -r ".kv[\"ca-bundles/azure-storage\"].caBundle" "$FAKE_VAULT_STATE")" == "$(cat "$TMP/bundle.pem")" ]]' "$out"
check "ca put reports the certificate count" '[[ "$out" == *"2 certificate(s)"* ]]' "$out"
out="$(bash "$S" ca put other "$TMP/junk.pem" 2>&1)" && rc=0 || rc=$?
check "ca put refuses a file without a PEM certificate" '[[ $rc != 0 && "$out" == *"no PEM certificate"* ]] && ! jq -e ".kv.other" "$FAKE_VAULT_STATE" >/dev/null' "$out"
if [[ "$HAVE_OLD" == 1 ]]; then
  out="$(bash "$S" ca put old "$TMP/old.pem" 2>&1)" && rc=0 || rc=$?
  check "ca put refuses an expired certificate" '[[ $rc != 0 && "$out" == *"has expired"* ]]' "$out"
fi
out="$(bash "$S" ca put Bad_Name "$TMP/ca.pem" 2>&1)" && rc=0 || rc=$?
check "ca put refuses a name that is not a Kubernetes name" '[[ $rc != 0 && "$out" == *"Kubernetes object name"* ]]' "$out"
out="$(bash "$S" ca put from-stdin - < "$TMP/ca.pem" 2>&1)" && rc=0 || rc=$?
check "ca put NAME - reads stdin" '[[ $rc == 0 ]] && jq -e ".kv[\"ca-bundles/from-stdin\"]" "$FAKE_VAULT_STATE" >/dev/null' "$out"
check "ca list names the bundles" '[[ "$(bash "$S" ca list 2>/dev/null | paste -sd, -)" == "azure-storage,from-stdin" ]]'
check "ca get prints the PEM" '[[ "$(bash "$S" ca get azure-storage 2>/dev/null)" == "$(cat "$TMP/bundle.pem")" ]]'
out="$(bash "$S" ca delete from-stdin </dev/null 2>&1)" && rc=0 || rc=$?
check "ca delete without a terminal needs --yes" '[[ $rc != 0 && "$out" == *"--yes"* ]]' "$out"
out="$(bash "$S" --yes ca delete from-stdin 2>&1)" && rc=0 || rc=$?
check "ca delete --yes removes it" '[[ $rc == 0 ]] && ! jq -e ".kv[\"ca-bundles/from-stdin\"]" "$FAKE_VAULT_STATE" >/dev/null' "$out"

out="$(BROADCOM_USER=svc-user BROADCOM_TOKEN='s3cr3t-token' bash "$S" wrap broadcom-registry 2>"$TMP/err")" && rc=0 || rc=$?
check "wrap prints only the wrapping token on stdout" '[[ $rc == 0 && "$out" == hvs.wrapped-exec ]]' "$out $(cat "$TMP/err")"
check "wrap broadcom-registry wraps {username, password}" \
  '[[ "$(jq -c ".wrapped" "$FAKE_VAULT_STATE")" == "{\"username\":\"svc-user\",\"password\":\"s3cr3t-token\"}" ]]' "$(jq -c .wrapped "$FAKE_VAULT_STATE")"
check "the value source is named, the value is not printed" \
  'grep -q "BROADCOM_TOKEN: from the environment" "$TMP/err" && ! grep -q s3cr3t "$TMP/err"' "$(cat "$TMP/err")"
check "the submit hint names the secret type" 'grep -q -- "-p secretType=broadcom-registry -p wrappingToken" "$TMP/err"' "$(cat "$TMP/err")"
out="$(GITHUB_USER=gh GIT_PUSH_PAT=ghp_x bash "$S" wrap git-push 2>&1 >/dev/null)"
check "wrap git-push wraps {username, token} from GIT_PUSH_PAT" '[[ "$(jq -c ".wrapped" "$FAKE_VAULT_STATE")" == "{\"username\":\"gh\",\"token\":\"ghp_x\"}" ]]' "$out"
out="$(BACKUP_STORAGE_KEY=k== bash "$S" wrap backup-storage 2>&1 >/dev/null)"
check "wrap backup-storage takes the account from the inventory" \
  '[[ "$(jq -c ".wrapped" "$FAKE_VAULT_STATE")" == "{\"accountName\":\"sttpgbackup01\",\"accountKey\":\"k==\"}" ]]' "$out"
out="$(REMOTE_WRITE_PASSWORD=short bash "$S" wrap monitoring-remote-write 2>&1)" && rc=0 || rc=$?
check "wrap monitoring-remote-write refuses fewer than 16 characters" '[[ $rc != 0 && "$out" == *"16 characters"* ]]' "$out"
out="$(bash "$S" wrap ca-bundle azure-storage "$TMP/ca.pem" 2>&1 >/dev/null)"
check "wrap ca-bundle wraps {caBundle, _secretName} and names secretName in the hint" \
  '[[ "$(jq -r ".wrapped.caBundle" "$FAKE_VAULT_STATE")" == "$(cat "$TMP/ca.pem")" && "$(jq -r ".wrapped._secretName" "$FAKE_VAULT_STATE")" == azure-storage && "$out" == *"-p secretName=azure-storage"* ]]' "$out"
out="$(bash "$S" wrap custom app KEY </dev/null 2>&1)" && rc=0 || rc=$?
check "wrap custom without a terminal fails" '[[ $rc != 0 && "$out" == *"terminal"* ]]' "$out"
out="$(bash "$S" wrap nope 2>&1)" && rc=0 || rc=$?
check "an unknown secret type is refused" '[[ $rc != 0 && "$out" == *"unknown secret type"* ]]' "$out"
out="$(BROADCOM_USER=u bash "$S" wrap broadcom-registry </dev/null 2>&1)" && rc=0 || rc=$?
check "a value neither exported nor typed fails" '[[ $rc != 0 && "$out" == *"BROADCOM_TOKEN is not exported"* ]]' "$out"

# ================================================================ --vault-addr
echo "== 2. --vault-addr (HTTPS)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 -addext "subjectAltName=IP:127.0.0.1" \
  -keyout "$TMP/srv.key" -out "$TMP/srv.pem" 2>/dev/null
python3 "$HERE/mock_vault.py" "$TMP/srv.pem" "$TMP/srv.key" "$TMP/port" "$TMP/wrap.json" "$TMP/req.log" &
PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
ADDR="https://127.0.0.1:$(cat "$TMP/port")"
V=(bash "$S" --vault-addr "$ADDR" --vault-ca-file "$TMP/srv.pem")
out="$(VAULT_UI_PASSWORD=pw-ok "${V[@]}" ca put azure-storage "$TMP/ca.pem" 2>&1)" && rc=0 || rc=$?
check "userpass login, then ca put over HTTPS" '[[ $rc == 0 ]] && grep -q "POST /v1/tpg/data/ca-bundles/azure-storage token=yes" "$TMP/req.log"' "$out"
check "ca get over HTTPS" '[[ "$(VAULT_UI_PASSWORD=pw-ok "${V[@]}" ca get azure-storage 2>/dev/null)" == "$(cat "$TMP/ca.pem")" ]]'
check "ca list over HTTPS" '[[ "$(VAULT_UI_PASSWORD=pw-ok "${V[@]}" ca list 2>/dev/null)" == azure-storage ]]'
out="$(VAULT_TOKEN=tok-admin GITHUB_USER=gh GIT_READ_PAT=ghp_r "${V[@]}" wrap git-read 2>/dev/null)" && rc=0 || rc=$?
check "VAULT_TOKEN is used as is; wrap sends X-Vault-Wrap-TTL and prints the token" \
  '[[ $rc == 0 && "$out" == hvs.wrapped-1 && "$(jq -c . "$TMP/wrap.json")" == "{\"username\":\"gh\",\"token\":\"ghp_r\"}" ]]' "$out"
# the login runs before the pipeline: a PEM on stdin, the password from the environment
out="$(VAULT_UI_PASSWORD=pw-ok "${V[@]}" ca put from-stdin - < "$TMP/ca.pem" 2>&1)" && rc=0 || rc=$?
check "ca put NAME - reads the PEM from stdin after the login" '[[ $rc == 0 ]] && grep -q "POST /v1/tpg/data/ca-bundles/from-stdin token=yes" "$TMP/req.log"' "$out"
# no password, no terminal (setsid: no controlling terminal): a clear message, nothing written
if command -v setsid >/dev/null; then
  out="$(env -u VAULT_UI_PASSWORD -u VAULT_TOKEN setsid "${V[@]}" ca put no-login - < "$TMP/ca.pem" 2>&1)" && rc=0 || rc=$?
  check "without a password or a terminal the login stops with the variable to export" \
    '[[ $rc != 0 && "$out" == *"VAULT_UI_PASSWORD is not exported and no terminal"* ]] && ! grep -q "ca-bundles/no-login" "$TMP/req.log"' "$out"
fi
out="$(VAULT_TOKEN=tok-admin "${V[@]}" --yes ca delete azure-storage 2>&1)" && rc=0 || rc=$?
check "ca delete over HTTPS" '[[ $rc == 0 ]] && grep -q "DELETE /v1/tpg/metadata/ca-bundles/azure-storage" "$TMP/req.log"' "$out"
out="$(VAULT_UI_PASSWORD=wrong "${V[@]}" ca list 2>&1)" && rc=0 || rc=$?
check "a refused userpass login fails with Vault's message" '[[ $rc != 0 && "$out" == *"invalid username or password"* ]]' "$out"
out="$("${V[@]/--vault-ca-file/--vault-ca-file-x}" ca list 2>&1)" && rc=0 || rc=$?
check "an unknown option is refused" '[[ $rc != 0 ]]' "$out"
out="$(bash "$S" --vault-addr "$ADDR" --vault-ca-file "$TMP/ca.pem" --yes ca list </dev/null 2>&1)" && rc=0 || rc=$?
check "a wrong Vault CA fails (TLS is verified)" '[[ $rc != 0 ]]' "$out"

echo
echo "vault-secret: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
