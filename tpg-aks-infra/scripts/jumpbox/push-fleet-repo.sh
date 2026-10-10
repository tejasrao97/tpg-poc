#!/usr/bin/env bash
# Publishes tpg-fleet from a zip into a new GitHub repository (Round 16).
# Terraform runs it on the jumpbox when create_fleet_repo is true
# (terraform_data.fleet_repo); it also runs by hand, as the admin user.
#
#   1. unzip ZIP into FLEET_LOCAL_DIR (default ~/tpg-fleet). ZIP and
#      FLEET_LOCAL_DIR must be absolute paths (Round 18). The zip holds one
#      top-level folder; __MACOSX/, .DS_Store and any .git are left out. An
#      existing FLEET_LOCAL_DIR is moved to FLEET_LOCAL_DIR.prev-<UTC time>.
#   2. create the repository FLEET_REPO_OWNER/FLEET_REPO_NAME (private) through
#      the GitHub REST API, unless it exists
#   3. scripts/set-repo-url.sh <repository URL>, chmod +x of every *.sh
#   4. git init -b FLEET_REPO_REVISION, commit
#   5. scripts/validate.sh, only when enabled (default: skipped, see below)
#   6. push. An empty repository, or a missing branch: push. A branch that holds
#      the same files: nothing to do. A branch with other content: stop, unless
#      FLEET_REPO_FORCE=true (git push --force replaces the branch history).
#
# Usage: push-fleet-repo.sh ZIP
#
# Environment (env.jumpbox.sh, written by Terraform, sets all but the token):
#   FLEET_REPO_OWNER, FLEET_REPO_NAME   repository to create (user or organization)
#   FLEET_REPO_REVISION                 branch (default main)
#   FLEET_REPO_URL                      https URL of the repository
#   GITHUB_API_URL                      default https://api.github.com
#   GITHUB_USER                         commit author name (default the token's user)
#   FLEET_VALIDATE_TFVARS, FLEET_REPO_FORCE_TFVARS  fleet_repo_validate / fleet_repo_force of
#                                       Terraform (deploy.sh passes them; env.jumpbox.sh sets them)
#   FLEET_VALIDATE, FLEET_REPO_FORCE    (or fleet_repo_validate, fleet_repo_force) in env.sh
#   Both are off unless every source that is set says true and at least one of
#   the env.sh names is set (Round 20): validate.sh and --force are opt-in twice.
#   GIT_ADMIN_PAT                       exported only: creates the repository and
#                                       pushes. Sent to curl on stdin (-K -) and to
#                                       git through GIT_ASKPASS; never on a command
#                                       line, in a file or in the git configuration.
source "$(dirname "$0")/../lib/common.sh"

usage() { sed -n '2,/^source /{/^source /d;s/^# \{0,1\}//;p;}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[[ $# -eq 1 ]] || { usage >&2; die "usage: push-fleet-repo.sh ZIP"; }
ZIP="$1"

require_cmd curl git jq unzip
require_env FLEET_REPO_OWNER FLEET_REPO_NAME FLEET_REPO_URL GIT_ADMIN_PAT
# absolute paths only (Round 18): nothing is resolved against the current folder
[[ "$ZIP" == /* ]] || die "ZIP must be an absolute path (got '${ZIP}')"
[[ -f "$ZIP" ]] || die "$ZIP not found"
[[ $EUID -ne 0 ]] || die "run it as the admin user, not root: the repository goes to that user's home"
BRANCH="${FLEET_REPO_REVISION:-main}"
API="${GITHUB_API_URL:-https://api.github.com}"
DEST="${FLEET_LOCAL_DIR:-${HOME}/tpg-fleet}"
[[ "$DEST" == /* && "$DEST" != */ ]] || die "FLEET_LOCAL_DIR must be an absolute path without a trailing / (got '${DEST}')"
[[ "$FLEET_REPO_URL" == https://* && ! "$FLEET_REPO_URL" =~ ^https://[^/]*@ ]] \
  || die "FLEET_REPO_URL must be an https URL without credentials: $FLEET_REPO_URL"

TMP="$(mktemp -d)"
cleanup_add "rm -rf '${TMP}'"

# ---------------------------------------------------------------- GitHub API
# gh_api METHOD PATH [JSON]: prints the body, sets GH_STATUS. The token goes to
# curl in a config read from stdin, so it is not in the process list.
GH_STATUS=""
gh_api() {
  local method="$1" path="$2" data="${3:-}" out="${TMP}/gh-body"
  local args=(-sS --retry 3 --retry-delay 2 -o "$out" -w '%{http_code}' -X "$method" -K -
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -z "$data" ]] || args+=(-H "Content-Type: application/json" --data "$data")
  GH_STATUS="$(printf 'header = "Authorization: Bearer %s"\n' "$GIT_ADMIN_PAT" \
    | curl "${args[@]}" "${API}${path}")" || GH_STATUS="000"
  cat "$out" 2>/dev/null || true
}

# ---------------------------------------------------------------- 1. unzip
log "Unpacking $ZIP"
unzip -q "$ZIP" -x '__MACOSX/*' '*/.DS_Store' '.DS_Store' -d "${TMP}/zip"
TOP="$(find "${TMP}/zip" -mindepth 1 -maxdepth 1)"
[[ -n "$TOP" && "$(wc -l <<<"$TOP")" -eq 1 && -d "$TOP" ]] \
  || die "$ZIP must hold exactly one top-level folder (found: $(sed 's#.*/##' <<<"$TOP" | paste -sd' ' -))"
SRC="$TOP"
[[ -f "${SRC}/scripts/set-repo-url.sh" && -f "${SRC}/clusters/fleet.yaml" ]] \
  || die "$ZIP is not a tpg-fleet repository (no scripts/set-repo-url.sh or clusters/fleet.yaml)"
rm -rf "${SRC}/.git"
if [[ -e "$DEST" ]]; then
  prev="${DEST}.prev-$(date -u +%Y%m%dT%H%M%SZ)"
  # two runs in the same second: a numbered name, never a move into the older copy
  n=1; base="$prev"
  while [[ -e "$prev" ]]; do prev="${base}.${n}"; n=$((n + 1)); done
  mv "$DEST" "$prev"
  warn "${DEST} existed: moved to ${prev}"
fi
mkdir -p "$(dirname "$DEST")"
mv "$SRC" "$DEST"
ok "$(basename "$SRC") unpacked to ${DEST}"

# ---------------------------------------------------------------- 2. repository
log "GitHub repository ${FLEET_REPO_OWNER}/${FLEET_REPO_NAME}"
gh_api GET /user > "${TMP}/user.json"
[[ "$GH_STATUS" == 200 ]] || die "GIT_ADMIN_PAT was refused by ${API}/user (HTTP ${GH_STATUS}): check the token and GITHUB_API_URL"
LOGIN="$(jq -r '.login' "${TMP}/user.json")"
gh_api GET "/repos/${FLEET_REPO_OWNER}/${FLEET_REPO_NAME}" > "${TMP}/repo.json"
case "$GH_STATUS" in
  200) ok "repository exists: $(jq -r '.html_url' "${TMP}/repo.json")" ;;
  404)
    body="$(jq -cn --arg n "$FLEET_REPO_NAME" '{name: $n, private: true, auto_init: false,
      description: "Tanzu for Postgres fleet (tpg-fleet), pushed by tpg-aks-infra"}')"
    owner_lc="$(tr '[:upper:]' '[:lower:]' <<<"$FLEET_REPO_OWNER")"
    login_lc="$(tr '[:upper:]' '[:lower:]' <<<"$LOGIN")"
    if [[ "$owner_lc" == "$login_lc" ]]; then path=/user/repos; else path="/orgs/${FLEET_REPO_OWNER}/repos"; fi
    gh_api POST "$path" "$body" > "${TMP}/create.json"
    [[ "$GH_STATUS" == 201 ]] \
      || die "could not create ${FLEET_REPO_OWNER}/${FLEET_REPO_NAME} (POST ${path}: HTTP ${GH_STATUS}: $(jq -r '.message // empty' "${TMP}/create.json" 2>/dev/null)). The token needs scope repo (classic) or Administration: Read and write (fine-grained)$( [[ "$path" == /orgs/* ]] && echo ", and repository creation rights in organization ${FLEET_REPO_OWNER}")"
    ok "repository created (private): $(jq -r '.html_url' "${TMP}/create.json")" ;;
  *) die "GET /repos/${FLEET_REPO_OWNER}/${FLEET_REPO_NAME}: HTTP ${GH_STATUS}" ;;
esac

# ---------------------------------------------------------------- 3. repository URL
log "scripts/set-repo-url.sh ${FLEET_REPO_URL}"
bash "${DEST}/scripts/set-repo-url.sh" "$FLEET_REPO_URL"
find "$DEST" -type f -name '*.sh' -exec chmod 755 {} +

# ---------------------------------------------------------------- 4. commit
# askpass prints variable values from its own environment: the script holds no secret
# shellcheck disable=SC2016  # expanded by the askpass script, from its environment
printf '#!/bin/sh\ncase "$1" in Username*) printf "%%s\\n" "${GIT_ASKPASS_USER}" ;; *) printf "%%s\\n" "$GIT_ADMIN_PAT" ;; esac\n' \
  > "${TMP}/askpass"
chmod 700 "${TMP}/askpass"
export GIT_ASKPASS="${TMP}/askpass" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS_USER="${GITHUB_USER:-$LOGIN}"
[[ "$GIT_ASKPASS_USER" != *"<"*">"* ]] || GIT_ASKPASS_USER="$LOGIN"
g() { git -C "$DEST" -c credential.helper= "$@"; }
AUTHOR="${GIT_ASKPASS_USER}"
g init -q -b "$BRANCH"
g add -A
g -c user.name="$AUTHOR" -c user.email="${AUTHOR}@users.noreply.github.com" \
  commit -q -m "tpg-fleet from $(basename "$ZIP") for ${FLEET_REPO_URL}"
g remote add origin "$FLEET_REPO_URL"
ok "committed $(g rev-parse --short HEAD) on ${BRANCH}"

# ---------------------------------------------------------------- 5. validate
# flag_on TFVARS_VALUE ENV_UPPER ENV_LOWER NAME UPPER_NAME: true only when the Terraform
# value is true and the env.sh names that are set (at least one) are all true
flag_why=""
flag_on() {
  local tf="$1" up="$2" low="$3" name="$4" upname="$5"
  flag_why=""
  if [[ "$tf" != true ]]; then flag_why="fleet_repo_${name} is not true in Terraform"; return 1; fi
  if [[ -z "$up" && -z "$low" ]]; then flag_why="neither ${upname} nor fleet_repo_${name} is set to true in env.sh"; return 1; fi
  if [[ -n "$up" && "$up" != true ]]; then flag_why="${upname}=${up} in env.sh"; return 1; fi
  if [[ -n "$low" && "$low" != true ]]; then flag_why="fleet_repo_${name}=${low} in env.sh"; return 1; fi
  return 0
}
validate_on=false; force_on=false
flag_on "${FLEET_VALIDATE_TFVARS:-false}" "${FLEET_VALIDATE:-}" "${fleet_repo_validate:-}" validate FLEET_VALIDATE && validate_on=true
validate_why="$flag_why"
flag_on "${FLEET_REPO_FORCE_TFVARS:-false}" "${FLEET_REPO_FORCE:-}" "${fleet_repo_force:-}" force FLEET_REPO_FORCE && force_on=true
force_why="$flag_why"

if [[ "$validate_on" == true ]]; then
  log "scripts/validate.sh (yamllint, shellcheck, tests/run-all.sh, kustomize, kubeconform, ...)"
  if [[ -f /etc/profile.d/tpg-jumpbox.sh ]]; then
    # KUBEBUILDER_ASSETS for the envtest tests
    # shellcheck source=/dev/null
    source /etc/profile.d/tpg-jumpbox.sh
  fi
  ( cd "$DEST" && bash scripts/validate.sh ) || die "scripts/validate.sh failed in ${DEST}: nothing was pushed. Fix the zip, or leave validation off (the default) to push anyway"
  ok "scripts/validate.sh passed"
else
  warn "scripts/validate.sh skipped: ${validate_why}. To run it set fleet_repo_validate = true (Terraform) and FLEET_VALIDATE=true or fleet_repo_validate=true in env.sh"
fi

# ---------------------------------------------------------------- 6. push
remote_head="$(g ls-remote --heads origin "refs/heads/${BRANCH}" | awk '{print $1}')" \
  || die "git ls-remote ${FLEET_REPO_URL} failed: check that GIT_ADMIN_PAT can read the repository"
force=""
if [[ -n "$remote_head" ]]; then
  g fetch -q origin "refs/heads/${BRANCH}"
  if [[ "$(g rev-parse 'FETCH_HEAD^{tree}')" == "$(g rev-parse 'HEAD^{tree}')" ]]; then
    ok "${BRANCH} of ${FLEET_REPO_URL} already holds these files (${remote_head:0:7}): nothing to push"
    exit 0
  fi
  [[ "$force_on" == true ]] \
    || die "${BRANCH} of ${FLEET_REPO_URL} already has other content (${remote_head:0:7}): nothing was pushed (force is off: ${force_why}). Use another fleet_repo_name, or set fleet_repo_force = true (Terraform) and FLEET_REPO_FORCE=true in env.sh to replace the branch history"
  warn "force is on: replacing ${BRANCH} (was ${remote_head:0:7})"
  force=--force
fi
g push -q ${force:+"$force"} origin "HEAD:refs/heads/${BRANCH}" \
  || die "git push to ${FLEET_REPO_URL} failed: the token needs Contents: Read and write"
ok "pushed ${BRANCH} to ${FLEET_REPO_URL}"
echo "     FLEET_REPO_URL=${FLEET_REPO_URL} FLEET_REPO_REVISION=${BRANCH} FLEET_LOCAL_DIR=${DEST}"
