#!/usr/bin/env bash
# Runs scripts/run.sh on the jumpbox, detached from the SSH session (Round 16).
# Terraform runs it when run_fleet_setup is true (terraform_data.jumpbox_run):
#
#   run-fleet-setup.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys
#
#   1. source env.sh and env.jumpbox.sh (through scripts/lib/common.sh)
#   2. az login --identity with the jumpbox identity, wait until it can read
#      the hub cluster (role assignments take a few minutes to apply)
#   3. no tpg-fleet clone at FLEET_LOCAL_DIR: clone FLEET_REPO_URL there
#      (GITHUB_USER and GIT_READ_PAT for a private repository)
#   4. start scripts/run.sh ARGS... with setsid nohup, output to
#      ~/.work/fleet-setup/run-<UTC time>.log, and follow the log until it ends;
#      exit with the exit code of run.sh. A dropped SSH session or a Ctrl+C here
#      does not stop run.sh. Started again while that run.sh is still running,
#      it follows the running one instead of starting another.
#
# The tokens (BROADCOM_TOKEN, GIT_READ_PAT, GIT_PUSH_PAT) are exported by the
# caller; run.sh inherits them in its environment and they go to no file.
source "$(dirname "$0")/../lib/common.sh"

case "${1:-}" in -h|--help) sed -n '2,/^source /{/^source /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
[[ $# -gt 0 ]] || die "usage: run-fleet-setup.sh RUN.SH-ARGUMENTS..."
require_cmd az git setsid nohup tail

STATE="${WORK_DIR}/fleet-setup"
mkdir -p "$STATE"
chmod 700 "$STATE"
PID_FILE="${STATE}/run.pid"
STATUS_FILE="${STATE}/run.status"
LOG_LINK="${STATE}/run.log"

# follow PID LOG: print LOG until PID ends, then exit with its status
follow() {
  local pid="$1" log="$2" rc
  log "Following ${log} (run.sh PID ${pid}); a dropped connection does not stop it"
  tail -n +1 -F --pid="$pid" "$log" 2>/dev/null || true
  rc="$(cat "$STATUS_FILE" 2>/dev/null || true)"
  [[ "$rc" =~ ^[0-9]+$ ]] || die "run.sh ended without an exit status: see ${log}"
  if [[ "$rc" -eq 0 ]]; then ok "scripts/run.sh finished (log ${log})"
  else printf '\033[1;31mFAIL\033[0m scripts/run.sh exited with %s (log %s)\n' "$rc" "$log" >&2; fi
  exit "$rc"
}

# ---------------------------------------------------------------- running already
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    warn "scripts/run.sh is still running from an earlier start (PID ${pid}): following it instead of starting another"
    follow "$pid" "$(readlink -f "$LOG_LINK")"
  fi
fi

# ---------------------------------------------------------------- 2. Azure
log "az login --identity (jumpbox identity ${JUMPBOX_IDENTITY_CLIENT_ID:-system-assigned})"
az login --identity ${JUMPBOX_IDENTITY_CLIENT_ID:+--client-id "$JUMPBOX_IDENTITY_CLIENT_ID"} --output none \
  || die "az login --identity failed"
require_inventory
az account set --subscription "${AZURE_SUBSCRIPTION_ID:-$(subscription)}"
HUB="$(hub_name)"
RG="$(inv '.hub.resourceGroup')"
for i in $(seq 1 30); do
  az aks show -g "$RG" -n "$HUB" --query id -o tsv >/dev/null 2>&1 && break
  [[ "$i" -lt 30 ]] || die "the jumpbox identity cannot read cluster ${HUB} after 10 minutes: check its role assignments (terraform output role_assignments_to_create)"
  log "waiting for the role assignments of the jumpbox identity (${i}/30)"
  sleep 20
done
ok "the jumpbox identity reads cluster ${HUB}"

# ---------------------------------------------------------------- 3. tpg-fleet clone
require_env FLEET_LOCAL_DIR
if [[ ! -d "${FLEET_LOCAL_DIR}/.git" ]]; then
  require_env FLEET_REPO_URL
  [[ "$FLEET_REPO_URL" == https://* && ! "$FLEET_REPO_URL" =~ ^https://[^/]*@ ]] \
    || die "FLEET_REPO_URL must be an https URL without credentials: $FLEET_REPO_URL"
  [[ ! -e "$FLEET_LOCAL_DIR" ]] || die "${FLEET_LOCAL_DIR} exists but is not a git clone: move it away"
  log "Cloning ${FLEET_REPO_URL} into ${FLEET_LOCAL_DIR}"
  ASKPASS="$(mktemp)"
  cleanup_add "rm -f '${ASKPASS}'"
  # shellcheck disable=SC2016  # expanded by the askpass script, from its environment
  printf '#!/bin/sh\ncase "$1" in Username*) printf "%%s\\n" "$GITHUB_USER" ;; *) printf "%%s\\n" "$GIT_READ_PAT" ;; esac\n' > "$ASKPASS"
  chmod 700 "$ASKPASS"
  GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone -q \
    --branch "${FLEET_REPO_REVISION:-main}" -- "$FLEET_REPO_URL" "$FLEET_LOCAL_DIR" \
    || die "git clone ${FLEET_REPO_URL} failed (GITHUB_USER and GIT_READ_PAT must read it)"
  ok "cloned ${FLEET_REPO_URL} (${FLEET_REPO_REVISION:-main})"
fi

# ---------------------------------------------------------------- 4. run.sh, detached
LOG="${STATE}/run-$(date -u +%Y%m%dT%H%M%SZ).log"
: > "$LOG"
chmod 600 "$LOG"
ln -sfn "$LOG" "$LOG_LINK"
rm -f "$STATUS_FILE"
log "Starting scripts/run.sh $*"
# setsid: own session, so the SSH session's hangup does not reach it; the exit
# status goes to STATUS_FILE for the follower (this shell or a later one).
# shellcheck disable=SC2016  # expanded by the inner bash
LOG="$LOG" STATUS_FILE="$STATUS_FILE" setsid nohup \
  bash -c '"$0" "$@" > "$LOG" 2>&1 < /dev/null; echo $? > "$STATUS_FILE"' \
  "${SCRIPTS_DIR}/run.sh" "$@" > /dev/null 2>&1 < /dev/null &
echo "$!" > "$PID_FILE"
follow "$(cat "$PID_FILE")" "$LOG"
