#!/usr/bin/env bash
# rotate-write.sh WORKFLOW_NAME
# tpg-rotate-credential, the write step (Round 15, design decision D87). Runs as the
# ServiceAccount tpg-credential-writer (Vault role and policy tpg-credential-writer),
# the only workflow step that writes to Vault.
#   1 The new value: the wrapping token (input wrappingToken, read from this run's
#     Workflow object, never from the pod environment) is unwrapped once
#     (sys/wrapping/unwrap; a used or expired token fails with WRAPPING_TOKEN_INVALID
#     and nothing is written), or, for secretType ca-bundle, the PEM file of the
#     input caBundleFile (a file of the submitting machine; contents in patchFiles).
#   2 The value is checked before it is written:
#       broadcom-registry         username and password; helm registry login to the
#                                 Broadcom registry with them
#       git-push, git-read        username and token; git ls-remote of the fleet
#                                 repository (git-push: also git push --dry-run)
#       backup-storage            accountName (the fleet's account) and accountKey;
#                                 every target container answers 200 with the key
#       monitoring-remote-write   username and password (16 characters or more)
#       ca-bundle                 caBundle: PEM certificates that have not expired
#       custom                    a map of one or more non-empty string values
#   3 It is written as a new version of its KV v2 path (created when missing):
#       tpg/shared/<broadcom-registry | github-push | github-read | backup-storage |
#       monitoring-remote-write>, tpg/ca-bundles/<secretName>, tpg/custom/<secretName>
# The value stays in a shell variable and goes to jq, helm, git and curl through
# pipes and the environment: it is never logged, never an argument, never a file.
# Records result.vault WRITTEN | FAILED (result_guard records an unexpected exit).
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose
WF="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
key="result.vault"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"
TYPE="${P_SECRET_TYPE:-}"; NAME="${P_SECRET_NAME:-}"

case "$TYPE" in
  broadcom-registry)       path="shared/broadcom-registry"; keys="username password" ;;
  git-push)                path="shared/github-push"; keys="username token" ;;
  git-read)                path="shared/github-read"; keys="username token" ;;
  backup-storage)          path="shared/backup-storage"; keys="accountName accountKey" ;;
  monitoring-remote-write) path="shared/monitoring-remote-write"; keys="username password" ;;
  ca-bundle)               path="ca-bundles/${NAME}"; keys="caBundle" ;;
  custom)                  path="custom/${NAME}"; keys="" ;;
  *) fail INVALID_SECRET_TYPE "$TYPE" ;;
esac

# ---- 1 the value (DATA: the JSON object of the new value, a shell variable only)
DATA=""
token="$(kubectl -n "$ARGO_NS" get workflow "$WF" -o json 2>/dev/null \
  | jq -r '[.spec.arguments.parameters[]? | select(.name == "wrappingToken") | (.value // "")][0] // ""')" \
  || fail WORKFLOW_UNREADABLE "Workflow ${ARGO_NS}/${WF} could not be read (ServiceAccount tpg-credential-writer needs get on workflows)"
addr="$(setting vaultAddr 2>/dev/null)"; addr="${addr:-https://vault.vault.svc:8200}"
ca="$WORK/vault-ca.crt"
secret_val vault-ca ca.crt > "$ca" 2>/dev/null || true
[[ -s "$ca" ]] || fail VAULT_UNREACHABLE "Secret ${ARGO_NS}/vault-ca (the Vault CA) is missing"
if [[ -n "$token" ]]; then
  # curl's own messages go to a file of their own, so a partly read response (the
  # value) can never reach the error message
  out="$(curl -sS --max-time 20 --cacert "$ca" -H @<(printf 'X-Vault-Token: %s\n' "$token") -X POST "${addr}/v1/sys/wrapping/unwrap" 2>"$WORK/curl.err")" \
    || { out=""; fail VAULT_UNREACHABLE "Vault at ${addr}: $(tail -c 300 "$WORK/curl.err")"; }
  if ! printf '%s' "$out" | jq -e '.data | type == "object"' >/dev/null 2>&1; then
    fail WRAPPING_TOKEN_INVALID "the wrapping token was used already, expired (10 minutes) or is not a wrapping token: $(printf '%s' "$out" | jq -r '.errors // [] | join("; ")' 2>/dev/null) (wrap the value again: tpg-aks-infra scripts/vault-secret.sh wrap ${TYPE})"
  fi
  DATA="$(printf '%s' "$out" | jq -c '.data')"
  out=""; token=""
  source_note="wrapping token (unwrapped, now invalid)"
elif [[ "$TYPE" == ca-bundle && -n "${P_CA_FILE:-}" ]]; then
  # a CA bundle is public; the validate step refuses a repo: file for this workflow
  pem="$WORK/ca.pem"
  patch_file_write "$P_CA_FILE" "$pem" "$WORK/repo" || fail FILE_NOT_RECEIVED "${P_CA_FILE}: ${PATCH_FILES_ERROR:-its contents are not in patchFiles}"
  DATA="$(jq -cn --rawfile v "$pem" '{caBundle: $v}')"
  source_note="${P_CA_FILE}"
else
  fail NOTHING_TO_WRITE "neither wrappingToken nor caBundleFile is set"
fi

# a value wrapped by vault-secret.sh wrap ca-bundle|custom NAME carries the name it was
# wrapped for: it must be this run's secretName (the key itself is not written)
wn="$(printf '%s' "$DATA" | jq -r '._secretName // ""')"
if [[ -n "$wn" ]]; then
  [[ "$wn" == "$NAME" ]] || fail VALUE_INVALID "the value was wrapped for secretName ${wn} (vault-secret.sh wrap ${TYPE} ${wn}); this run names secretName ${NAME:-(empty)}"
  DATA="$(printf '%s' "$DATA" | jq -c 'del(._secretName)')"
fi

# ---- 2 the checks
d_jq() { printf '%s' "$DATA" | jq "$@"; }   # jq over the value, through a pipe
for k in $keys; do
  d_jq -e --arg k "$k" '.[$k] | type == "string" and length > 0' >/dev/null \
    || fail VALUE_INVALID "the value has no key ${k} (${TYPE} needs: ${keys}); got keys: $(d_jq -r 'keys | join(", ")')"
done
extra="$(d_jq -r --arg ks "$keys" '($ks | split(" ")) as $w | keys | map(select(. as $k | $w | index($k) | not)) | join(", ")')"
[[ -z "$keys" || -z "$extra" ]] || fail VALUE_INVALID "${TYPE} takes only ${keys}; the value also has ${extra}"
v() { d_jq -r --arg k "$1" '.[$k]'; }
case "$TYPE" in
  broadcom-registry)
    host="$(setting registryHost 2>/dev/null)"; host="${host:-tanzu-sql-postgres.packages.broadcom.com}"; host="${host%%/*}"
    cfg="$(mktemp -d)"
    v password | HELM_REGISTRY_CONFIG="$cfg/config.json" helm registry login "$host" --username "$(v username)" --password-stdin >/dev/null 2>&1 \
      || { rm -rf "${cfg:?}"; fail VALUE_REJECTED "helm registry login to ${host} with the new username and password failed"; }
    rm -rf "${cfg:?}" ;;
  git-push|git-read)
    url="$(setting fleetRepoURL)"
    [[ -n "$url" ]] || fail VALUE_REJECTED "tpg-settings fleetRepoURL is empty"
    askpass="$(mktemp)"; chmod 700 "$askpass"
    # the token reaches git through the environment, never an argument or a file
    # shellcheck disable=SC2016  # expanded by the askpass script, from its environment
    printf '#!/bin/sh\ncase "$1" in Username*) printf "%%s" "$GIT_U";; *) printf "%%s" "$GIT_T";; esac\n' > "$askpass"
    if ! GIT_U="$(v username)" GIT_T="$(v token)" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$url" >/dev/null 2>&1; then
      rm -f "${askpass:?}"; fail VALUE_REJECTED "git ls-remote ${url} with the new token failed (expired, or no Contents read access)"
    fi
    if [[ "$TYPE" == git-push ]]; then
      d="$(mktemp -d)"
      if ! GIT_U="$(v username)" GIT_T="$(v token)" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$(setting fleetRevision)" "$url" "$d/r" 2>/dev/null \
         || ! GIT_U="$(v username)" GIT_T="$(v token)" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git -C "$d/r" push --dry-run -q origin "HEAD:$(setting fleetRevision)" 2>/dev/null; then
        rm -rf "${d:?}" "${askpass:?}"; fail VALUE_REJECTED "git push --dry-run with the new token failed (no Contents write access)"
      fi
      rm -rf "${d:?}"
    fi
    rm -f "${askpass:?}" ;;
  backup-storage)
    [[ "$(v accountName)" == "$(setting backupStorageAccount)" ]] \
      || fail VALUE_REJECTED "accountName $(v accountName) is not the fleet's storage account $(setting backupStorageAccount)"
    for c in $(registered_clusters); do
      code="$(blob_container_status "$(v accountName)" "$(v accountKey)" "pg-backups-${c}")"
      [[ "$code" == 200 ]] || fail VALUE_REJECTED "container pg-backups-${c}: HTTP ${code} with the new key (403: key rejected, 404: container missing)"
    done ;;
  monitoring-remote-write)
    [[ "$(v password | wc -c)" -gt 16 ]] || fail VALUE_REJECTED "the password has fewer than 16 characters" ;;
  ca-bundle)
    v caBundle > "$WORK/ca-check.pem"
    out="$(ca_check "$WORK/ca-check.pem")" || fail VALUE_REJECTED "caBundle: ${out}" ;;
  custom)
    d_jq -e 'length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null \
      || fail VALUE_REJECTED "a custom secret is a map of one or more non-empty string values" ;;
esac

# ---- 3 the write (a new KV v2 version; created when missing)
VAULT_ROLE=tpg-credential-writer vault_login_token || fail VAULT_LOGIN_FAILED "$VAULT_READ_ERROR"
out="$(d_jq -c '{data: .}' | curl -sS --max-time 20 --cacert "$ca" -H @<(printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN_VALUE") \
  -X POST --data @- "${addr}/v1/tpg/data/${path}" 2>"$WORK/curl.err")" || fail VAULT_WRITE_FAILED "tpg/${path}: $(tail -c 300 "$WORK/curl.err")"
DATA=""
ver="$(jq -r '.data.version // empty' <<<"$out" 2>/dev/null)"
[[ -n "$ver" ]] || fail VAULT_WRITE_FAILED "tpg/${path}: $(jq -r '.errors // [] | join("; ")' <<<"$out" 2>/dev/null)"
record "$key" WRITTEN "" "tpg/${path} version ${ver} from ${source_note}; checked before the write"
