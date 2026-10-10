#!/usr/bin/env bash
# Credential pre-checks used by steps/40-hub-secrets.sh before anything is stored.
# Source after common.sh. Every check exits the script (die) with the exact
# error returned by the registry or GitHub. Tokens never appear in command-line
# arguments or files that outlive the check.
#
#   check_broadcom_token REGISTRY USER TOKEN
#   check_github_pats REPO_URL REVISION API_URL USER READ_PAT PUSH_PAT
#     VALIDATE_PR_WRITE=true  also create a temporary branch and pull request with
#                             the read/write PAT, then close and delete them

# ----------------------------------------------------------------- Broadcom registry
check_broadcom_token() {
  local registry="$1" user="$2" token="$3" out rc
  require_cmd helm
  log "Checking the Broadcom registry token: helm registry login ${registry}"
  # A throwaway registry config (mode 600, removed on exit) keeps the token out of
  # ~/.config/helm and out of any file that outlives this check.
  out="$(
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT   # mktemp -d: mode 700
    cfg="$tmp/registry.json"
    printf '%s' "$token" | helm registry login "$registry" --username "$user" \
      --password-stdin --registry-config "$cfg" 2>&1
  )" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    die "Broadcom registry token rejected. helm registry login ${registry} --username ${user} failed (exit ${rc}):
${out}"
  fi
  ok "Broadcom registry token accepted by ${registry} (user ${user})"
}

# ----------------------------------------------------------------- GitHub
# _gh TOKEN METHOD PATH [JSON]: GitHub REST call. Sets GH_STATUS, GH_BODY and
# GH_HEADERS. The token is passed to curl on stdin, never as an argument.
_gh() {
  local token="$1" method="$2" path="$3" data="${4:-}" tmp args
  tmp="$(mktemp -d)"
  args=(-sS -X "$method" -D "$tmp/h" -o "$tmp/b" -w '%{http_code}'
        -H @- -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  [[ -z "$data" ]] || args+=(-H 'Content-Type: application/json' --data-raw "$data")
  GH_STATUS="$(printf 'Authorization: Bearer %s\n' "$token" | curl "${args[@]}" "${GH_API}${path}" 2>"$tmp/e")" || GH_STATUS="000"
  GH_BODY="$(cat "$tmp/b" 2>/dev/null || true)"
  GH_HEADERS="$(tr -d '\r' < "$tmp/h" 2>/dev/null || true)"
  [[ "$GH_STATUS" != "000" ]] || GH_BODY="$(cat "$tmp/e")"
  rm -rf "$tmp"
}

_gh_header() { awk -v k="$(tr '[:upper:]' '[:lower:]' <<<"$1")" -F': ' 'tolower($1) == k {print $2}' <<<"$GH_HEADERS" | tail -n1; }

# _gh_msg LABEL WHAT: the GitHub status, message and the permission GitHub says
# is required (X-Accepted-GitHub-Permissions) for the last _gh call.
_gh_msg() {
  local label="$1" what="$2" msg need
  msg="$(jq -r '.message // empty' <<<"$GH_BODY" 2>/dev/null || true)"
  [[ -n "$msg" ]] || msg="$GH_BODY"
  need="$(_gh_header x-accepted-github-permissions)"
  printf 'GitHub %s PAT: %s failed: HTTP %s: %s%s' "$label" "$what" "$GH_STATUS" "$msg" "${need:+ (required permission: ${need})}"
}

_gh_error() { die "$(_gh_msg "$1" "$2")"; }

# _git_auth TOKEN CMD...: run git with an Authorization header from the
# environment (GIT_CONFIG_*), so the token is not in the process arguments.
_git_auth() {
  local token="$1"; shift
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')" \
    GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="" \
    git "$@"
}

# _check_pat LABEL TOKEN: identity, expiry and repository access
_check_pat() {
  local label="$1" token="$2" login exp exp_epoch days
  case "$token" in
    github_pat_*) ;;
    ghp_*) warn "GitHub ${label} PAT is a classic token; the design uses fine-grained PATs limited to ${GH_REPO}" ;;
    *) warn "GitHub ${label} PAT does not look like a fine-grained PAT (github_pat_...)" ;;
  esac

  _gh "$token" GET /user
  [[ "$GH_STATUS" == "200" ]] || _gh_error "$label" "GET /user (token active)"
  login="$(jq -r '.login' <<<"$GH_BODY")"
  [[ "$login" == "$GITHUB_USER" ]] \
    || warn "GitHub ${label} PAT belongs to ${login}, GITHUB_USER is ${GITHUB_USER} (Git accepts it; check it is the intended account)"
  exp="$(_gh_header github-authentication-token-expiration)"
  if [[ -n "$exp" ]]; then
    # Format "2026-10-01 00:00:00 UTC"; jq keeps this portable (no GNU date -d)
    exp_epoch="$(jq -rn --arg e "$exp" '$e | sub(" UTC$"; "") | strptime("%Y-%m-%d %H:%M:%S") | mktime' 2>/dev/null || true)"
    if [[ "$exp_epoch" =~ ^[0-9]+$ ]]; then
      days=$(( (exp_epoch - $(date +%s)) / 86400 ))
      if (( days < 7 )); then
        warn "GitHub ${label} PAT expires in ${days} day(s) (${exp}): rotate it soon"
      else
        ok "GitHub ${label} PAT active (user ${login}, expires ${exp})"
      fi
    fi
  else
    ok "GitHub ${label} PAT active (user ${login}, no expiration)"
  fi

  _gh "$token" GET "/repos/${GH_REPO}"
  [[ "$GH_STATUS" == "200" ]] \
    || _gh_error "$label" "GET /repos/${GH_REPO} (repository selected under Repository access; Metadata: Read-only)"

  _gh "$token" GET "/repos/${GH_REPO}/contents/clusters/fleet.yaml?ref=${GH_REV}"
  [[ "$GH_STATUS" == "200" ]] \
    || _gh_error "$label" "read clusters/fleet.yaml on ${GH_REV} (Contents: Read-only)"

  local out
  out="$(_git_auth "$token" ls-remote --heads "$GH_URL" "$GH_REV" 2>&1)" \
    || die "GitHub ${label} PAT: git ls-remote ${GH_URL} failed: ${out}"
  grep -q "refs/heads/${GH_REV}$" <<<"$out" \
    || die "GitHub ${label} PAT: branch ${GH_REV} not found in ${GH_URL}"
  ok "GitHub ${label} PAT reads ${GH_REPO}@${GH_REV} (REST and Git)"
}

# _push_dry_run TOKEN DIR: 0 when GitHub accepts push authentication. A dry-run
# push still requests the receive-pack advertisement, which GitHub authorizes
# only for tokens with write access; nothing is written.
_push_dry_run() {
  _git_auth "$1" -C "$2" push --dry-run --porcelain origin "HEAD:refs/heads/${GH_REV}" 2>&1
}

_check_pr_write() {
  local token="$1" sha branch path number fail=""
  branch="tpg-pat-check-$(date -u +%Y%m%d%H%M%S)"
  path=".tpg-pat-check"
  log "VALIDATE_PR_WRITE=true: temporary branch ${branch} and pull request in ${GH_REPO}"
  _gh "$token" GET "/repos/${GH_REPO}/git/ref/heads/${GH_REV}"
  [[ "$GH_STATUS" == "200" ]] || _gh_error read/write "read refs/heads/${GH_REV}"
  sha="$(jq -r '.object.sha' <<<"$GH_BODY")"
  _gh "$token" POST "/repos/${GH_REPO}/git/refs" "$(jq -cn --arg r "refs/heads/${branch}" --arg s "$sha" '{ref:$r, sha:$s}')"
  [[ "$GH_STATUS" == "201" ]] || _gh_error read/write "create branch ${branch} (Contents: Read and write)"

  _gh "$token" PUT "/repos/${GH_REPO}/contents/${path}" \
    "$(jq -cn --arg b "$branch" --arg c "$(printf 'tpg PAT check %s' "$branch" | base64 | tr -d '\n')" \
      '{message:"tpg-aks-infra: PAT permission check (branch is deleted)", content:$c, branch:$b}')"
  if [[ "$GH_STATUS" != "201" ]]; then
    fail="$(_gh_msg read/write "commit to ${branch} (Contents: Read and write)")"
  else
    _gh "$token" POST "/repos/${GH_REPO}/pulls" \
      "$(jq -cn --arg h "$branch" --arg b "$GH_REV" '{title:"tpg-aks-infra PAT permission check (closed automatically)", head:$h, base:$b, body:"Opened and closed by scripts/steps/40-hub-secrets.sh to verify Pull requests: Read and write."}')"
    if [[ "$GH_STATUS" != "201" ]]; then
      fail="$(_gh_msg read/write "open a pull request (Pull requests: Read and write)")"
    else
      number="$(jq -r '.number' <<<"$GH_BODY")"
      _gh "$token" PATCH "/repos/${GH_REPO}/pulls/${number}" '{"state":"closed"}'
      [[ "$GH_STATUS" == "200" ]] || fail="$(_gh_msg read/write "close pull request #${number}")"
    fi
  fi
  # Always remove the branch (this also closes a pull request that is still open).
  _gh "$token" DELETE "/repos/${GH_REPO}/git/refs/heads/${branch}"
  [[ "$GH_STATUS" == "204" ]] || warn "could not delete branch ${branch} in ${GH_REPO}: HTTP ${GH_STATUS}; delete it by hand"
  [[ -z "$fail" ]] || die "$fail"
  ok "GitHub read/write PAT opened and closed pull request #${number}; branch ${branch} deleted"
}

check_github_pats() {
  GH_URL="$1"; GH_REV="$2"; GH_API="${3%/}"; GITHUB_USER="$4"
  local read_pat="$5" push_pat="$6" tmp out
  require_cmd curl git jq base64
  GH_REPO="$(sed -E 's#^https?://[^/]+/##; s#\.git$##; s#/$##' <<<"$GH_URL")"
  [[ "$GH_REPO" =~ ^[^/]+/[^/]+$ ]] || die "FLEET_REPO_URL must look like https://github.com/<owner>/<repo>.git (got ${GH_URL})"
  log "Checking the GitHub PATs against ${GH_REPO} (${GH_API})"
  _check_pat read-only "$read_pat"
  _check_pat read/write "$push_pat"

  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$GH_URL"
  if ! out="$(_git_auth "$push_pat" -C "$tmp" fetch -q --depth 1 origin "refs/heads/${GH_REV}" 2>&1)"; then
    rm -rf "$tmp"; die "GitHub read/write PAT: git fetch ${GH_REV} failed: ${out}"
  fi
  git -C "$tmp" checkout -q FETCH_HEAD
  if ! out="$(_push_dry_run "$push_pat" "$tmp")"; then
    rm -rf "$tmp"
    die "GitHub read/write PAT cannot push to ${GH_REPO} (Contents: Read and write). git push --dry-run returned:
${out}"
  fi
  ok "GitHub read/write PAT: push authorized (git push --dry-run, nothing written)"
  if _push_dry_run "$read_pat" "$tmp" >/dev/null 2>&1; then
    warn "GitHub read-only PAT can push to ${GH_REPO}: Argo CD needs Contents: Read-only only"
  else
    ok "GitHub read-only PAT has no push access (least privilege)"
  fi
  rm -rf "$tmp"

  _gh "$push_pat" GET "/repos/${GH_REPO}/pulls?state=all&per_page=1"
  [[ "$GH_STATUS" == "200" ]] || _gh_error read/write "list pull requests (Pull requests: Read and write, used by pushMode=pr)"
  ok "GitHub read/write PAT reads pull requests"
  if [[ "${VALIDATE_PR_WRITE:-false}" == "true" ]]; then
    _check_pr_write "$push_pat"
  else
    log "Pull request write access is not tested (set VALIDATE_PR_WRITE=true to open and close a test pull request)"
  fi
}
