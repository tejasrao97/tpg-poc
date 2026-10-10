#!/usr/bin/env bash
# tpg-rotate-credential, the write step (workflows/scripts/rotate-write.sh; Round 15,
# design decision D87), with stub kubectl (the Workflow object and its inputs, the
# tpg-settings ConfigMap, the vault-ca Secret), a stub curl (the Vault API: unwrap,
# KV v2 write) and the Kubernetes auth login replaced:
#   1 a wrapped custom value is checked, written without its _secretName, and never
#     lands in a file of the step
#   2 a value wrapped for another secretName is refused, nothing written
#   3 a used or expired token is WRAPPING_TOKEN_INVALID, nothing written
#   4 a failed unwrap names curl's error, never the (partial) response
#   5 a short remote-write password is VALUE_REJECTED
#   6 a CA bundle from caBundleFile (patchFiles) is written; an expired one refused
#   7 an unexpected exit is still recorded (result_guard)
# Requires bash 4, jq, python3 and openssl; skipped without them.
# ok() and bad() always return 0.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in jq python3 openssl base64; do command -v "$t" >/dev/null || { echo "SKIP tests/rotate: $t not installed" >&2; exit 0; }; done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -10; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
# kubectl: the Workflow (wrappingToken, patchFiles), tpg-settings and vault-ca
cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"get workflow"*) jq -cn --arg t "${S_TOKEN:-}" --arg p "${S_PATCH_FILES:-}" \
      '{spec: {arguments: {parameters: [{name: "wrappingToken", value: $t}, {name: "patchFiles", value: $p}]}}}' ;;
  *"get configmap tpg-settings"*) echo '{"data": {"vaultAddr": "https://vault.test:8200"}}' ;;
  *"get secret vault-ca"*) printf '{"data": {"ca.crt": "%s"}}' "$(printf 'dummy-ca' | base64)" ;;
  *) echo "kubectl stub: $*" >&2; exit 1 ;;
esac
SH
# curl: the Vault API. S_UNWRAP: the JSON the token unwraps to (once); S_CURL_FAIL=1:
# the unwrap breaks off after part of the response
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  */v1/sys/wrapping/unwrap)
    if [[ "${S_CURL_FAIL:-0}" == 1 ]]; then printf '{"data":{"password":"PARTIAL-SECRET'; echo "curl: (18) transfer closed with outstanding read data remaining" >&2; exit 18; fi
    if [[ -f "$S_DIR/used" || -z "${S_UNWRAP:-}" ]]; then echo '{"errors":["wrapping token is not valid or does not exist"]}'; exit 0; fi
    touch "$S_DIR/used"; jq -cn --argjson d "$S_UNWRAP" '{data: $d}' ;;
  */v1/tpg/data/*)
    cat > "$S_DIR/write.json"; echo "${url##*/v1/}" > "$S_DIR/write.path"
    if [[ "${S_WRITE_GARBAGE:-0}" == 1 ]]; then echo '<html>502 from a proxy</html>'; else echo '{"data":{"version":3}}'; fi ;;
  *) echo "curl stub: $url" >&2; exit 7 ;;
esac
SH
chmod +x "$TMP/bin/kubectl" "$TMP/bin/curl"

# rotate-write.sh with the library of this repository, the records in a file, and the
# Kubernetes auth login replaced (it reads the pod's ServiceAccount token)
cat > "$TMP/prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/work"
source "$ROOT/workflows/scripts/lib.sh"
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
vault_login_token() { [[ "\${VAULT_ROLE:-}" == tpg-credential-writer ]] || { VAULT_READ_ERROR="role \${VAULT_ROLE:-} (stub)"; return 1; }; VAULT_TOKEN_VALUE=tok-writer; }
PRELUDE
sed -e "s#^source /scripts/lib.sh#source $TMP/prelude.sh#" "$ROOT/workflows/scripts/rotate-write.sh" > "$TMP/rotate-write.sh"

run() {  # run VAR=VALUE...: rotate-write.sh; $OUT, the records in $TMP/records
  rm -rf "$TMP/work" "$TMP/state"; mkdir -p "$TMP/work" "$TMP/state"; : > "$TMP/records"
  OUT="$(env PATH="$TMP/bin:$PATH" S_DIR="$TMP/state" ARGO_NS=argo "$@" bash "$TMP/rotate-write.sh" wf-1 2>&1)" || true
}
rec() { grep -F "$1" "$TMP/records" || true; }
no_value_in_files() {  # no_value_in_files TEXT: TEXT is in no file of the step's work directory
  ! grep -rqF -- "$1" "$TMP/work" 2>/dev/null
}

echo "== 1 a wrapped custom value"
run S_TOKEN=hvs.good-token-0000 S_UNWRAP='{"_secretName": "app", "API_KEY": "s3cret-value-1"}' P_SECRET_TYPE=custom P_SECRET_NAME=app
[[ -n "$(rec "result.vault|WRITTEN")" && "$(cat "$TMP/state/write.path")" == tpg/data/custom/app \
   && "$(jq -c . "$TMP/state/write.json")" == '{"data":{"API_KEY":"s3cret-value-1"}}' ]] \
  && ok "1 written to tpg/custom/app without _secretName" || bad "1 custom" "$OUT $(cat "$TMP/records")"
no_value_in_files s3cret-value-1 && ! grep -qF s3cret-value-1 <<<"$OUT$(cat "$TMP/records")" \
  && ok "1 the value is in no file, log line or record of the step" || bad "1 value leaked" "$(grep -rlF s3cret-value-1 "$TMP/work" || true) $OUT"

echo "== 2 wrapped for another secretName"
run S_TOKEN=hvs.good-token-0000 S_UNWRAP='{"_secretName": "other", "K": "v"}' P_SECRET_TYPE=custom P_SECRET_NAME=app
[[ -n "$(rec "result.vault|FAILED|VALUE_INVALID|the value was wrapped for secretName other")" && ! -f "$TMP/state/write.json" ]] \
  && ok "2 refused, nothing written" || bad "2 name" "$OUT $(cat "$TMP/records")"

echo "== 3 a used token"
run S_TOKEN=hvs.used-token-0000 S_UNWRAP='' P_SECRET_TYPE=git-read
[[ -n "$(rec "result.vault|FAILED|WRAPPING_TOKEN_INVALID")" && ! -f "$TMP/state/write.json" ]] \
  && ok "3 WRAPPING_TOKEN_INVALID, nothing written" || bad "3 used" "$OUT $(cat "$TMP/records")"

echo "== 4 the unwrap breaks off"
run S_TOKEN=hvs.good-token-0000 S_UNWRAP='{"username": "tpg-remote-write", "password": "x"}' S_CURL_FAIL=1 P_SECRET_TYPE=monitoring-remote-write
r="$(rec "result.vault|FAILED|VAULT_UNREACHABLE")"
[[ -n "$r" && "$r" == *"transfer closed"* ]] && ! grep -qF PARTIAL-SECRET <<<"$(cat "$TMP/records")$OUT" && no_value_in_files PARTIAL-SECRET \
  && ok "4 VAULT_UNREACHABLE with curl's message, no part of the response" || bad "4 partial" "$OUT $(cat "$TMP/records")"

echo "== 5 a short remote-write password"
run S_TOKEN=hvs.good-token-0000 S_UNWRAP='{"username": "tpg-remote-write", "password": "short"}' P_SECRET_TYPE=monitoring-remote-write
[[ -n "$(rec "result.vault|FAILED|VALUE_REJECTED|the password has fewer than 16 characters")" && ! -f "$TMP/state/write.json" ]] \
  && ok "5 VALUE_REJECTED" || bad "5 short" "$OUT $(cat "$TMP/records")"
run S_TOKEN=hvs.good-token-0000 S_UNWRAP='{"username": "tpg-remote-write", "password": "a-long-enough-password-1"}' P_SECRET_TYPE=monitoring-remote-write
[[ -n "$(rec "result.vault|WRITTEN")" && "$(cat "$TMP/state/write.path")" == tpg/data/shared/monitoring-remote-write ]] \
  && ok "5 a password of 16 characters or more is written" || bad "5 long" "$OUT $(cat "$TMP/records")"

echo "== 6 a CA bundle from caBundleFile"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=ok-ca -keyout "$TMP/k1" -out "$TMP/ok.pem" 2>/dev/null
pf="$(jq -cn --arg b "$(base64 < "$TMP/ok.pem" | tr -d '\n')" '{"./ca.pem": $b}')"
run S_TOKEN= S_PATCH_FILES="$pf" P_SECRET_TYPE=ca-bundle P_SECRET_NAME=storage-ca P_CA_FILE=./ca.pem
[[ -n "$(rec "result.vault|WRITTEN")" && "$(jq -r .data.caBundle "$TMP/state/write.json")" == "$(cat "$TMP/ok.pem")" ]] \
  && ok "6 written to tpg/ca-bundles/storage-ca" || bad "6 ca" "$OUT $(cat "$TMP/records")"
python3 - "$TMP/old.pem" "$TMP/k2" <<'PY' 2>/dev/null || openssl req -x509 -newkey rsa:2048 -nodes -days 0 -subj /CN=old -keyout "$TMP/k2" -out "$TMP/old.pem" 2>/dev/null
import sys, datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
n = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "expired")])
now = datetime.datetime.now(datetime.timezone.utc)
c = (x509.CertificateBuilder().subject_name(n).issuer_name(n).public_key(k.public_key()).serial_number(1)
     .not_valid_before(now - datetime.timedelta(days=10)).not_valid_after(now - datetime.timedelta(days=1)).sign(k, hashes.SHA256()))
open(sys.argv[1], "wb").write(c.public_bytes(serialization.Encoding.PEM))
PY
pf="$(jq -cn --arg b "$(base64 < "$TMP/old.pem" | tr -d '\n')" '{"./old.pem": $b}')"
run S_TOKEN= S_PATCH_FILES="$pf" P_SECRET_TYPE=ca-bundle P_SECRET_NAME=storage-ca P_CA_FILE=./old.pem
[[ -n "$(rec "result.vault|FAILED|VALUE_REJECTED")" && ! -f "$TMP/state/write.json" ]] \
  && ok "6 an expired certificate is refused" || bad "6 expired" "$OUT $(cat "$TMP/records")"

echo "== 7 an unexpected exit"
# the write answers with something that is not JSON: jq fails under set -e
run S_TOKEN=hvs.good-token-0000 S_UNWRAP='{"_secretName": "app", "K": "v"}' S_WRITE_GARBAGE=1 P_SECRET_TYPE=custom P_SECRET_NAME=app
[[ -n "$(rec "result.vault|FAILED|UNEXPECTED_ERROR")" ]] && ok "7 an unexpected exit is recorded (result_guard)" || bad "7 guard" "$OUT $(cat "$TMP/records")"

# rotate-hub.sh (Round 21): the Argo CD repository list has no "items" when workflow-bot may read
# none of them; jq must not iterate null, and the step names the missing RBAC line
H="$ROOT/workflows/scripts/rotate-hub.sh"
# log_cmd lines print the equivalent command for the reader; they run nothing
if grep -n '\.items\[\]' "$H" | grep -v '(\.items // \[\])\[\]' | grep -vE '^[0-9]+:[[:space:]]*log_cmd ' >/dev/null; then bad "8 rotate-hub.sh iterates .items without a default"
else ok "8 rotate-hub.sh reads .items only with a default"; fi
grep -q 'RBAC_MISSING' "$H" && grep -q 'repositories, get' "$H" && ok "8 an empty repository list fails as RBAC_MISSING, naming the policy line" || bad "8 RBAC_MISSING"
if command -v jq >/dev/null; then
  [[ "$(echo '{}' | jq -r '(.items // [])[] | .repo' | wc -l | tr -d ' ')" == 0 ]] && ok "8 an empty list ({}) iterates to nothing" || bad "8 empty list"
fi

echo
echo "tests/rotate: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
