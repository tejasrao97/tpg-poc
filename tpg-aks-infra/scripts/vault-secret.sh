#!/usr/bin/env bash
# Named CA bundles in Vault, and wrapping tokens for tpg-rotate-credential
# (Round 15, design decisions D86 and D87).
#
# Usage
#   scripts/vault-secret.sh [OPTIONS] ca put NAME FILE|-    write (or replace) tpg/ca-bundles/NAME
#   scripts/vault-secret.sh [OPTIONS] ca get NAME           print the bundle (PEM)
#   scripts/vault-secret.sh [OPTIONS] ca list               list the bundle names
#   scripts/vault-secret.sh [OPTIONS] ca delete NAME        delete every version of tpg/ca-bundles/NAME
#   scripts/vault-secret.sh [OPTIONS] wrap SECRET_TYPE [NAME [KEY...]]
#       print a wrapping token (single use, valid 10 minutes) for the new value of
#       a credential; submit it as the input wrappingToken of tpg-rotate-credential.
#
# Options
#   --vault-addr URL       talk to Vault over HTTPS (for example the vault-ui or
#                          vault-fleet load balancer) instead of kubectl exec into
#                          vault/vault-0 on the hub
#   --vault-ca-file FILE   the Vault CA with --vault-addr (default: .work/vault-ca.crt,
#                          written by the vault step)
#   --inventory PATH       the inventory (default .work/inventory.yaml)
#   --yes                  ca delete without asking
#
# A named bundle is used by tpg-day0, tpg-create-instance and tpg-patch with the
# input or clusterMap key backupCaBundleVaultSecret=NAME: the workflow reads it at
# plan time and writes it into the instance's backup.caBundle in fleet.yaml, so a
# later change or delete in Vault does not touch running instances until the next
# tpg-patch. NAME is a Kubernetes object name (lowercase letters, digits, - and .).
# FILE - reads the bundle from stdin, for example:
#   terraform -chdir=terraform output -raw backup_storage_ca_bundle | scripts/vault-secret.sh ca put azure-storage -
#
# wrap SECRET_TYPE: the value is read from the shell environment when the
# variable is exported, otherwise asked for with hidden input:
#   broadcom-registry         username BROADCOM_USER, password BROADCOM_TOKEN
#   git-read                  username GITHUB_USER,   token GIT_READ_PAT
#   git-push                  username GITHUB_USER,   token GIT_PUSH_PAT
#   backup-storage            accountName: the inventory's backup.storageAccount
#                             (or BACKUP_STORAGE_ACCOUNT), accountKey BACKUP_STORAGE_KEY
#   monitoring-remote-write   username tpg-remote-write, password REMOTE_WRITE_PASSWORD
#   ca-bundle NAME FILE|-     caBundle: the PEM file (tpg-rotate-credential can also
#                             take the file itself: caBundleFile)
#   custom NAME KEY...        one hidden prompt per KEY
# Then:
#   argo submit -n argo --from workflowtemplate/tpg-rotate-credential \
#     -p secretType=<type> [-p secretName=<name>] -p wrappingToken=<token> --watch
# The token is the only output on stdout. Values never reach a command-line
# argument or a file; the wrapping token is single use: whoever unwraps it first
# gets the value, and the workflow then fails with WRAPPING_TOKEN_INVALID, which
# shows that the token was intercepted.
#
# Login: VAULT_TOKEN when exported; otherwise, over kubectl exec, a 30-minute
# token of the Kubernetes auth role tpg-setup (policy tpg-admin), and with
# --vault-addr the userpass account tpg-admin (password VAULT_UI_PASSWORD, or
# asked for; scripts/access.sh prints it).
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/vault.sh"

ADDR="" CA_FILE="" YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-addr) ADDR="${2:-}"; shift 2 ;;
    --vault-ca-file) CA_FILE="${2:-}"; shift 2 ;;
    --inventory) INVENTORY="${2:-}"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || die "usage: scripts/vault-secret.sh [--vault-addr URL] ca put|get|list|delete ... | wrap SECRET_TYPE ... (--help)"
require_cmd jq

NAME_RE='^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$'
check_name() { [[ "$1" =~ $NAME_RE ]] || die "${1:-(empty)}: a bundle or secret name is a Kubernetes object name (lowercase letters, digits, '-' and '.')"; }

# ---------------------------------------------------------------- transport
if [[ -n "$ADDR" ]]; then
  require_cmd curl
  ADDR="${ADDR%/}"
  [[ "$ADDR" == https://* ]] || die "--vault-addr must be an https:// URL"
  CA_FILE="${CA_FILE:-$VAULT_CA_LOCAL}"
  [[ -s "$CA_FILE" ]] || die "Vault CA ${CA_FILE} not found: pass --vault-ca-file (Secret vault/vault-tls, key ca.crt)"
else
  require_cmd kubectl yq
  require_inventory
  HUB="$(hub_name)"
  require_context "$HUB"
  vault_require_unsealed
fi

TOKEN=""
login() {
  [[ -n "$TOKEN" ]] && return 0
  # shellcheck disable=SC2119  # vault_login without "try": exits when the login is refused
  if [[ -z "$ADDR" ]]; then vault_login; TOKEN="kubectl-exec"; return 0; fi
  if [[ -n "${VAULT_TOKEN:-}" ]]; then TOKEN="$VAULT_TOKEN"; return 0; fi
  if [[ -z "${VAULT_UI_PASSWORD:-}" ]]; then
    # stdin may carry a PEM (ca put NAME -): ask on the terminal itself
    { exec 3</dev/tty; } 2>/dev/null || die "VAULT_UI_PASSWORD is not exported and no terminal is available to ask for it"
    read -r -s -p "Vault password of the userpass account tpg-admin: " VAULT_UI_PASSWORD <&3; exec 3<&-; echo >&2
    [[ -n "$VAULT_UI_PASSWORD" ]] || die "VAULT_UI_PASSWORD must not be empty"
  fi
  local out
  out="$(printf '%s' "$VAULT_UI_PASSWORD" | jq -Rsc '{password: .}' | api POST auth/userpass/login/tpg-admin -)" \
    || die "userpass login tpg-admin failed: Vault at ${ADDR} did not answer (curl error above)"
  TOKEN="$(jq -r '.auth.client_token // empty' <<<"$out")"
  [[ -n "$TOKEN" ]] || die "userpass login tpg-admin failed: $(jq -r '.errors // [] | join("; ")' <<<"$out" 2>/dev/null)"
}

# api METHOD PATH [-] [HEADER]: one HTTPS request; the token travels in a header
# read from a pipe, the body (with -) from stdin
api() {
  local m="$1" p="$2" body="${3:-}" extra="${4:-}"
  local args=(-sS --max-time 20 --cacert "$CA_FILE" -X "$m")
  [[ "$body" == - ]] && args+=(--data @-)
  [[ -n "$extra" ]] && args+=(-H "$extra")
  if [[ -n "$TOKEN" ]]; then
    curl "${args[@]}" -H @<(printf 'X-Vault-Token: %s\n' "$TOKEN") "${ADDR}/v1/${p}"
  else
    curl "${args[@]}" "${ADDR}/v1/${p}"
  fi
}
errors_of() { jq -r '.errors // [] | join("; ")' <<<"$1" 2>/dev/null || printf '%s' "$1"; }

# kv_put PATH (JSON map on stdin)
kv_put() {
  local out
  login
  if [[ -z "$ADDR" ]]; then vt kv put -mount=tpg "$1" - >/dev/null || die "could not write tpg/$1"; return 0; fi
  out="$(jq -c '{data: .}' | api POST "tpg/data/$1" -)" || die "tpg/$1: ${out}"
  jq -e '.data.version' <<<"$out" >/dev/null 2>&1 || die "could not write tpg/$1: $(errors_of "$out")"
}
# kv_get PATH -> the JSON map, or nothing when missing
kv_get() {
  local out
  login
  if [[ -z "$ADDR" ]]; then vt kv get -mount=tpg -format=json "$1" </dev/null 2>/dev/null | jq -c '.data.data // empty'; return 0; fi
  out="$(api GET "tpg/data/$1")" || die "tpg/$1: ${out}"
  jq -c '.data.data // empty' <<<"$out" 2>/dev/null
}
kv_list() {
  local out
  login
  if [[ -z "$ADDR" ]]; then vt kv list -mount=tpg -format=json "$1" </dev/null 2>/dev/null | jq -r '.[]'; return 0; fi
  out="$(api LIST "tpg/metadata/$1")" || die "tpg/$1: ${out}"
  jq -r '.data.keys[]?' <<<"$out" 2>/dev/null
}
kv_delete() {
  local out
  login
  if [[ -z "$ADDR" ]]; then vt kv metadata delete -mount=tpg "$1" </dev/null >/dev/null || die "could not delete tpg/$1"; return 0; fi
  out="$(api DELETE "tpg/metadata/$1")" || die "tpg/$1: ${out}"
  [[ -z "$out" ]] || die "could not delete tpg/$1: $(errors_of "$out")"
}
# wrap (JSON map on stdin) -> the wrapping token
wrap() {
  local out
  login
  if [[ -z "$ADDR" ]]; then
    out="$(vt write -wrap-ttl=10m -format=json sys/wrapping/wrap -)" || die "sys/wrapping/wrap failed"
  else
    out="$(api POST sys/wrapping/wrap - 'X-Vault-Wrap-TTL: 10m')" || die "sys/wrapping/wrap: ${out}"
  fi
  jq -r '.wrap_info.token // empty' <<<"$out" | grep . || die "sys/wrapping/wrap returned no token: $(errors_of "$out")"
}

# pem_read FILE|- DEST: a PEM bundle of certificates that have not expired
pem_read() {
  local src="$1" dest="$2" n=0 tmp
  if [[ "$src" == - ]]; then cat > "$dest"; else [[ -f "$src" ]] || die "${src}: no such file"; cat "$src" > "$dest"; fi
  [[ "$(wc -c < "$dest")" -le 65536 ]] || die "${src}: a CA bundle has at most 64 KiB"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$dest" || die "${src}: no PEM certificate (-----BEGIN CERTIFICATE-----)"
  if command -v openssl >/dev/null; then
    tmp="$(mktemp -d)"; cleanup_add "rm -rf '$tmp'"
    awk -v d="$tmp" '/-----BEGIN CERTIFICATE-----/{n++} n{print > (d "/c" n ".pem")} /-----END CERTIFICATE-----/{close(d "/c" n ".pem")}' "$dest"
    for c in "$tmp"/c*.pem; do
      n=$((n + 1))
      openssl x509 -noout -in "$c" 2>/dev/null || die "${src}: certificate ${n} cannot be read"
      openssl x509 -checkend 0 -noout -in "$c" >/dev/null 2>&1 \
        || die "${src}: certificate ${n} ($(openssl x509 -noout -subject -in "$c" | sed 's/^subject=//')) has expired"
    done
  fi
}

# value VAR "prompt": the exported variable, or hidden input (the source is named on stderr)
value() {
  local v
  if [[ -n "${!1:-}" ]]; then printf '  %s: from the environment\n' "$1" >&2; printf '%s' "${!1}"; return 0; fi
  [[ -t 0 ]] || die "$1 is not exported and no terminal is available to ask for it"
  read -r -s -p "$2: " v; echo >&2
  [[ -n "$v" ]] || die "$1 must not be empty"
  printf '%s' "$v"
}

cmd="$1"; shift
# log in here, in this shell: kv_put, wrap and the others run at the end of a pipeline
# (a subshell), where a prompt could not read the terminal and the token would be lost
case "$cmd" in ca|wrap) login ;; esac
case "$cmd" in
  ca)
    sub="${1:-}"; shift || true
    case "$sub" in
      put)
        [[ $# -eq 2 ]] || die "usage: ca put NAME FILE|-"
        check_name "$1"
        tmp="$(mktemp)"; cleanup_add "rm -f '$tmp'"
        pem_read "$2" "$tmp"
        jq -Rsc '{caBundle: .}' < "$tmp" | kv_put "ca-bundles/$1"
        ok "tpg/ca-bundles/$1 written ($(grep -c -- '-----BEGIN CERTIFICATE-----' "$tmp") certificate(s)); use it with backupCaBundleVaultSecret=$1" >&2 ;;
      get)
        [[ $# -eq 1 ]] || die "usage: ca get NAME"
        check_name "$1"
        d="$(kv_get "ca-bundles/$1")"
        [[ -n "$d" ]] || die "tpg/ca-bundles/$1 does not exist (ca list shows the names)"
        jq -r '.caBundle // empty' <<<"$d" ;;
      list)
        [[ $# -eq 0 ]] || die "usage: ca list"
        kv_list ca-bundles ;;
      delete)
        [[ $# -eq 1 ]] || die "usage: ca delete NAME"
        check_name "$1"
        [[ -n "$(kv_get "ca-bundles/$1")" ]] || die "tpg/ca-bundles/$1 does not exist"
        if [[ "$YES" != 1 ]]; then
          [[ -t 0 ]] || die "ca delete asks for confirmation: pass --yes"
          read -r -p "Delete every version of tpg/ca-bundles/$1? Instances keep the copy in fleet.yaml; later runs with backupCaBundleVaultSecret=$1 fail. [y/N] " a
          [[ "$a" == y || "$a" == Y ]] || die "not deleted"
        fi
        kv_delete "ca-bundles/$1"
        ok "tpg/ca-bundles/$1 deleted" >&2 ;;
      *) die "usage: ca put|get|list|delete" ;;
    esac ;;
  wrap)
    type="${1:-}"; shift || true
    sname=""
    case "$type" in
      broadcom-registry)
        U="$(value BROADCOM_USER "Broadcom support portal user")"; P="$(value BROADCOM_TOKEN "New Broadcom registry token")"
        json="$(U="$U" P="$P" jq -nc '{username: env.U, password: env.P}')" ;;
      git-read|git-push)
        var=GIT_READ_PAT; [[ "$type" == git-push ]] && var=GIT_PUSH_PAT
        U="$(value GITHUB_USER "GitHub user")"; P="$(value "$var" "New GitHub fine-grained PAT ($type)")"
        json="$(U="$U" P="$P" jq -nc '{username: env.U, token: env.P}')" ;;
      backup-storage)
        A="${BACKUP_STORAGE_ACCOUNT:-}"
        if [[ -z "$A" && -f "$INVENTORY" ]]; then A="$(inv '.backup.storageAccount // ""')"; fi
        [[ -n "$A" ]] || die "the storage account name: export BACKUP_STORAGE_ACCOUNT or pass --inventory"
        P="$(value BACKUP_STORAGE_KEY "New access key of storage account ${A}")"
        json="$(U="$A" P="$P" jq -nc '{accountName: env.U, accountKey: env.P}')" ;;
      monitoring-remote-write)
        P="$(value REMOTE_WRITE_PASSWORD "New remote-write password (16 characters or more)")"
        [[ "${#P}" -ge 16 ]] || die "the password has fewer than 16 characters"
        json="$(P="$P" jq -nc '{username: "tpg-remote-write", password: env.P}')" ;;
      ca-bundle)
        [[ $# -eq 2 ]] || die "usage: wrap ca-bundle NAME FILE|-"
        check_name "$1"
        tmp="$(mktemp)"; cleanup_add "rm -f '$tmp'"
        pem_read "$2" "$tmp"
        sname="$1"
        # _secretName: the workflow checks it against its input secretName and drops it
        json="$(N="$1" jq -Rsc '{caBundle: ., _secretName: env.N}' < "$tmp")" ;;
      custom)
        [[ $# -ge 2 ]] || die "usage: wrap custom NAME KEY..."
        check_name "$1"; sname="$1"; shift
        json="$(N="$sname" jq -nc '{_secretName: env.N}')"
        for k in "$@"; do
          [[ "$k" =~ ^[A-Za-z0-9_.-]+$ ]] || die "${k}: a key has letters, digits, _, . and - only"
          [[ -t 0 ]] || die "wrap custom asks for each value: run it from a terminal"
          read -r -s -p "Value of ${k}: " v; echo >&2
          [[ -n "$v" ]] || die "the value of ${k} is empty"
          [[ "$k" != _secretName ]] || die "_secretName is reserved"
          json="$(printf '%s' "$json" | V="$v" jq -c --arg k "$k" '. + {($k): env.V}')"; v=""
        done ;;
      "") die "usage: wrap SECRET_TYPE [NAME [KEY...]] (broadcom-registry, git-read, git-push, backup-storage, monitoring-remote-write, ca-bundle, custom)" ;;
      *) die "${type}: unknown secret type" ;;
    esac
    printf '%s' "$json" | wrap
    json=""
    printf 'wrapping token printed above: single use, valid 10 minutes. Submit it with -p secretType=%s%s -p wrappingToken=<token>\n' \
      "$type" "$( [[ "$type" == ca-bundle || "$type" == custom ]] && printf ' -p secretName=%s' "$sname")" >&2 ;;
  *) die "unknown command ${cmd}: ca or wrap (--help)" ;;
esac
