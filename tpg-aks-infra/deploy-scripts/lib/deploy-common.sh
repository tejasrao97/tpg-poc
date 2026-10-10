#!/usr/bin/env bash
# Shared by deploy-scripts/deploy.sh and deploy-scripts/terraform-enabled-deploy.sh
# (Round 17). Source it; do not run it.
#
#   - subcommands and options (dp_parse_args), usage
#   - tool and version checks (dp_check_tools), with setup-jumpbox.sh offered on
#     a supported Linux and brew hints on macOS
#   - prompts with defaults (the environment, terraform/deploy.tfvars,
#     terraform/terraform.tfvars, then the variables.tf default)
#   - terraform/deploy.tfvars (written here, never terraform.tfvars) and env.sh
#     (created from env.sh.example, or changed line by line after a diff and a yes)
#   - tokens read hidden and exported only: never written to a file, the log or
#     a command line
#   - terraform plan, one confirmation, terraform apply (no saved plan file: it
#     would hold the tokens)
#   - the step runner of 'all' and its log in .work/deploy-<UTC time>.log
#
# Written for bash 3.2 as well (macOS), so that the checks can tell you what is
# missing; scripts/run.sh itself needs bash 4 or later.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
TF_DIR="${INFRA_DIR}/terraform"
TFVARS="${TFVARS:-${TF_DIR}/terraform.tfvars}"
DEPLOY_TFVARS="${DEPLOY_TFVARS:-${TF_DIR}/deploy.tfvars}"
DP_ENV_FILE="${ENV_FILE:-${INFRA_DIR}/env.sh}"
ENV_EXAMPLE="${INFRA_DIR}/env.sh.example"
WORK_DIR="${INFRA_DIR}/.work"

SUBCOMMAND="" FROM="" ASSUME_YES=0 NON_INTERACTIVE=0 PROMPTS_OFF=0 RUN_FROM=""

# The four tokens stay shell variables from here on: exported ones (from your
# shell) are taken but no longer exported, so no command started by these
# scripts sees them unless it is given them (VAR="$VAR" command).
for _t in GIT_ADMIN_PAT BROADCOM_TOKEN GIT_READ_PAT GIT_PUSH_PAT; do export -n "$_t" 2>/dev/null || true; done
unset _t

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- bash
# A bash 4 or later found at DEPLOY_BASH_CANDIDATES runs this script again, and
# goes first on PATH, so that scripts/run.sh (#!/usr/bin/env bash) gets it too.
dp_reexec_bash4() {
  [[ "${BASH_VERSINFO[0]}" -ge 4 || "${DEPLOY_REEXEC:-0}" == 1 ]] && return 0
  local c
  for c in ${DEPLOY_BASH_CANDIDATES-/opt/homebrew/bin/bash /usr/local/bin/bash}; do
    if [[ -x "$c" ]] && [[ "$("$c" -c 'echo "${BASH_VERSINFO[0]}"')" -ge 4 ]]; then
      export PATH="$(dirname "$c"):${PATH}" DEPLOY_REEXEC=1
      exec "$c" "$0" "$@"
    fi
  done
}

# ---------------------------------------------------------------- arguments
# dp_parse_args "SUBCOMMANDS" ARGS...: sets SUBCOMMAND, FROM, ASSUME_YES, NON_INTERACTIVE
dp_parse_args() {
  local allowed="$1"; shift
  [[ "$-" != *x* ]] || { echo "do not run this under bash -x or set -x: the trace would print the tokens" >&2; exit 2; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) ASSUME_YES=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --from) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; FROM="$2"; shift 2 ;;
      --from=*) FROM="${1#*=}"; shift ;;
      --run-step-from)
        # deploy.sh only (ALLOW_RUN_STEP_FROM): the step of scripts/run.sh to resume at
        [[ "${ALLOW_RUN_STEP_FROM:-0}" == 1 ]] || { echo "unknown option: $1" >&2; usage >&2; exit 2; }
        [[ $# -ge 2 ]] || { usage >&2; exit 2; }; RUN_FROM="$2"; shift 2 ;;
      --run-step-from=*)
        [[ "${ALLOW_RUN_STEP_FROM:-0}" == 1 ]] || { echo "unknown option: $1" >&2; usage >&2; exit 2; }
        RUN_FROM="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
      *)
        [[ -z "$SUBCOMMAND" ]] || { echo "one subcommand only (got $SUBCOMMAND and $1)" >&2; usage >&2; exit 2; }
        SUBCOMMAND="$1"; shift ;;
    esac
  done
  if [[ -z "$SUBCOMMAND" ]]; then usage; exit 2; fi
  [[ " $allowed " == *" $SUBCOMMAND "* ]] || { echo "unknown subcommand: $SUBCOMMAND" >&2; usage >&2; exit 2; }
  if [[ -n "$FROM" ]]; then
    [[ "$SUBCOMMAND" == all ]] || { echo "--from works with 'all' only" >&2; exit 2; }
    [[ " ${STEPS} " == *" $FROM "* ]] || { echo "unknown step for --from: $FROM (steps: ${STEPS})" >&2; exit 2; }
  fi
  if [[ -n "$RUN_FROM" ]]; then
    [[ " ${RUN_STEPS:-} " == *" $RUN_FROM "* ]] || { echo "unknown step for --run-step-from: $RUN_FROM (run.sh steps: ${RUN_STEPS:-})" >&2; exit 2; }
    case "$SUBCOMMAND" in
      setup|all) ;;
      *) echo "note: --run-step-from only applies to setup and all; ignored by ${SUBCOMMAND}" >&2; RUN_FROM="" ;;
    esac
  fi
  # --non-interactive: every value from the environment and the files
  [[ "$NON_INTERACTIVE" == 1 ]] && PROMPTS_OFF=1
  return 0
}

# ---------------------------------------------------------------- log
# dp_run_logged FUNCTION ARGS...: FUNCTION's output also goes to .work/deploy-<UTC>.log.
# The scripts behind it then see no terminal on stdout and stderr (run.sh: Helm
# releases that are already installed follow ADDONS_EXISTING, default skip).
dp_run_logged() {
  mkdir -p "$WORK_DIR"
  chmod 700 "$WORK_DIR"
  DEPLOY_LOG="${WORK_DIR}/deploy-$(date -u +%Y%m%dT%H%M%SZ).log"
  : > "$DEPLOY_LOG"
  chmod 600 "$DEPLOY_LOG"
  export DEPLOY_LOG
  local rc
  # ( set -e; ... ): a pipeline stage inherits set +e, which would let every
  # failure of FUNCTION pass (and not inside if or ||, where bash ignores set -e)
  set +e
  ( set -e; "$@" ) 2>&1 | tee -a "$DEPLOY_LOG"
  rc="${PIPESTATUS[0]}"
  set -e
  printf 'log: %s\n' "$DEPLOY_LOG" >&2
  return "$rc"
}

# ---------------------------------------------------------------- tools
ver_ge() {  # ver_ge A B: version A >= B (numeric dot parts)
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, ".");
    for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0 }'
}

DP_MISSING="" DP_WRONG=""
_need() { command -v "$1" >/dev/null 2>&1 || DP_MISSING="${DP_MISSING} $1"; }
_wrong() { DP_WRONG="${DP_WRONG}
  - $*"; }

# dp_tf_bin: TF_BIN from the environment or env.sh, else terraform, else tofu
dp_tf_bin() {
  local b="${TF_BIN:-$(env_get TF_BIN)}"
  b="${b:-terraform}"
  if ! command -v "$b" >/dev/null 2>&1; then
    if [[ "$b" == terraform ]] && command -v tofu >/dev/null 2>&1; then b=tofu
    elif [[ "$b" == tofu ]] && command -v terraform >/dev/null 2>&1; then b=terraform; fi
  fi
  printf '%s' "$b"
}

_check_tf() {
  local v
  TF_BIN="$(dp_tf_bin)"
  if ! command -v "$TF_BIN" >/dev/null 2>&1; then DP_MISSING="${DP_MISSING} terraform-or-tofu"; return; fi
  v="$("$TF_BIN" version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null || true)"
  case "$TF_BIN" in
    tofu) ver_ge "${v:-0}" 1.9.0 || _wrong "OpenTofu ${v:-unknown}: 1.9 or later is needed (terraform/versions.tf)" ;;
    *)    ver_ge "${v:-0}" 1.9.0 || _wrong "Terraform ${v:-unknown}: 1.9 or later is needed" ;;
  esac
}

_check_run_tools() {
  local v
  for t in az kubectl helm argocd jq yq git curl openssl python3 base64; do _need "$t"; done
  v="$("${DEPLOY_BASH:-bash}" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null || echo 0)"
  ver_ge "$v" 4.0 || _wrong "bash ${v} on PATH: scripts/run.sh needs bash 4 or later (macOS: brew install bash, and put it first on PATH)"
  if command -v helm >/dev/null 2>&1; then
    v="$(helm version --template '{{.Version}}' 2>/dev/null || true)"; v="${v#v}"
    if ! ver_ge "${v:-0}" 3.10.0; then _wrong "Helm ${v:-unknown}: 3.10 or later is needed (the workflows run Helm 4)"
    elif ! ver_ge "$v" 4.0.0; then warn "Helm ${v}: works, but the workflows run Helm 4"; fi
  fi
  if command -v yq >/dev/null 2>&1; then
    v="$(yq --version 2>&1 || true)"
    local re='version v?4[.]'
    [[ "$v" == *mikefarah* && "$v" =~ $re ]] || _wrong "yq is not mikefarah yq v4 (${v}): install it from github.com/mikefarah/yq"
  fi
  command -v argo >/dev/null 2>&1 || warn "argo CLI not found: run.sh does not need it, docs/workflow-commands.md (tpg-fleet) does"
  command -v kubelogin >/dev/null 2>&1 || warn "kubelogin not found: needed only for clusters with Entra ID accounts only (Terraform clusters keep local accounts)"
}

# dp_flag_on TFVAR ENV_UPPER ENV_LOWER: the Round 20 double opt-in, as
# push-fleet-repo.sh decides it: the Terraform variable (deploy.tfvars, then
# terraform.tfvars) is true, and the env.sh names that are set (at least one) are all true
dp_flag_on() {
  local tf up low
  tf="$(tfv_get "$1")"; up="$(env_file_get "$2")"; low="$(env_file_get "$3")"
  [[ "$tf" == true ]] || return 1
  [[ -n "$up" || -n "$low" ]] || return 1
  [[ -z "$up" || "$up" == true ]] || return 1
  [[ -z "$low" || "$low" == true ]] || return 1
}

_check_validate_tools() {
  local t
  for t in yamllint shellcheck kustomize kubeconform helm yq python3; do _need "$t"; done
  if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
    _wrong "python3 has no PyYAML (pip install pyyaml), which scripts/validate.sh of tpg-fleet needs"
  fi
}

# dp_check_tools STEP...: every tool the given steps need; stops with one list
DP_CHECKED=" "
dp_check_tools() {
  DP_MISSING="" DP_WRONG=""
  local s todo=""
  for s in "$@"; do [[ "$DP_CHECKED" == *" $s "* ]] || todo="${todo} ${s}"; done
  [[ -n "$todo" ]] || return 0
  _need jq; _need diff; _need cmp
  for s in $todo; do
    case "$s" in
      apply) _need az; _need curl; _check_tf ;;
      repo)
        _need git; _need curl; _need unzip
        if dp_flag_on fleet_repo_validate FLEET_VALIDATE fleet_repo_validate; then _check_validate_tools; fi ;;
      setup) _check_run_tools; _check_tf ;;
      copy)  _need ssh; _need tar; _check_tf ;;
      jumpbox-access) command -v ssh >/dev/null 2>&1 || warn "ssh not found: you need it to log in to the jumpbox" ;;
    esac
  done
  if [[ -z "$DP_MISSING" && -z "$DP_WRONG" ]]; then
    DP_CHECKED="${DP_CHECKED}${todo# } "
    ok "tools for:${todo}"
    return 0
  fi
  {
    echo "Missing or unsuitable tools for:${todo}"
    [[ -z "$DP_MISSING" ]] || echo "  missing:${DP_MISSING}"
    [[ -z "$DP_WRONG" ]] || echo "  wrong version:${DP_WRONG}"
  } >&2
  _tool_hints
  die "install the tools above and run the command again"
}

_tool_hints() {
  local os_id="" os_ver=""
  if [[ "$(uname -s)" == Darwin ]]; then
    cat >&2 <<'EOF'
On macOS (Homebrew):
  brew install bash jq yq git openssl azure-cli kubernetes-cli helm argocd argo
  brew install hashicorp/tap/terraform        # or: brew install opentofu
  brew install Azure/kubelogin/kubelogin       # only for Entra ID-only clusters
  brew install yamllint shellcheck kustomize kubeconform && pip3 install pyyaml   # scripts/validate.sh
Then put the Homebrew bash first on PATH (or run this script with it).
EOF
    return
  fi
  if [[ -r /etc/os-release ]]; then
    os_id="$(. /etc/os-release && echo "${ID:-}")"; os_ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  fi
  case "${os_id}:${os_ver}" in
    ubuntu:22.04|ubuntu:24.04|rhel:9*|rocky:9*)
      echo "This Linux is supported by scripts/jumpbox/setup-jumpbox.sh, which installs the pinned tools:" >&2
      echo "  sudo TF_TOOL=$(_tf_tool) ${INFRA_DIR}/scripts/jumpbox/setup-jumpbox.sh --only run-time,tests" >&2
      if [[ "$PROMPTS_OFF" != 1 && "$(uname -m)" == x86_64 ]]; then
        local a=""
        read -r -p "Run it now with sudo? [y/N] " a || true
        if [[ "$a" == y || "$a" == yes ]]; then
          sudo TF_TOOL="$(_tf_tool)" bash "${INFRA_DIR}/scripts/jumpbox/setup-jumpbox.sh" --only run-time,tests \
            || die "setup-jumpbox.sh failed"
          ok "tools installed: run the command again (a new shell picks up /etc/profile.d/tpg-jumpbox.sh)"
        fi
      fi ;;
    *) echo "Install them with your package manager; the pinned versions are at the top of scripts/jumpbox/setup-jumpbox.sh." >&2 ;;
  esac
}
_tf_tool() { [[ "$(dp_tf_bin)" == tofu ]] && echo tofu || echo terraform; }

# ---------------------------------------------------------------- tfvars
# tfv_file_get KEY FILE: the value of KEY in a tfvars file, unquoted; a list as
# a comma-separated string. Single-line values only.
tfv_file_get() {
  [[ -f "$2" ]] || return 0
  awk -v k="$1" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      v = $0; sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", v)
      if (v ~ /^"/) { v = substr(v, 2); out = ""
        while (length(v) > 0) { c = substr(v, 1, 1)
          if (c == "\\") { out = out substr(v, 2, 1); v = substr(v, 3); continue }
          if (c == "\"") break
          out = out c; v = substr(v, 2) }
        print out; exit }
      if (v ~ /^\[/) {
        # a list may span lines: read on to the closing bracket; drop comments
        sub(/#.*$/, "", v)
        while (v !~ /\]/ && (getline line) > 0) { sub(/#.*$/, "", line); v = v line }
        sub(/\].*$/, "", v); sub(/^\[/, "", v); gsub(/"/, "", v); gsub(/[[:space:]]/, "", v)
        sub(/,$/, "", v); print v; exit }
      sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit
    }' "$2"
}

# tfv_get KEY: deploy.tfvars, then terraform.tfvars
tfv_get() {
  local v
  v="$(tfv_file_get "$1" "$DEPLOY_TFVARS")"
  [[ -n "$v" ]] || v="$(tfv_file_get "$1" "$TFVARS")"
  [[ "$v" == null ]] && v=""
  printf '%s' "$v"
}

# The Terraform variables these scripts prompt for or set, in file order
DP_TF_KEYS="subscription_id location prefix resource_group_name target_cluster_count admin_allowed_cidrs
  api_access_mode network_mode vault_unseal_mode create_role_assignments enable_jumpbox
  jumpbox_provision jumpbox_setup_method jumpbox_os
  jumpbox_admin_username create_fleet_repo run_fleet_setup fleet_repo_owner fleet_repo_name
  fleet_repo_branch fleet_zip_path"
DP_TF_LISTS=" admin_allowed_cidrs "
DP_TF_RAW=" target_cluster_count create_role_assignments enable_jumpbox jumpbox_provision create_fleet_repo run_fleet_setup "

_hcl_str() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }
_hcl_value() {
  local key="$1" val="$2" out="" item rest
  if [[ "$DP_TF_LISTS" == *" $key "* ]]; then
    rest="$val"
    while [[ -n "$rest" ]]; do
      item="${rest%%,*}"; [[ "$rest" == *,* ]] && rest="${rest#*,}" || rest=""
      out="${out:+$out, }$(_hcl_str "$item")"
    done
    printf '[%s]' "$out"
  elif [[ "$DP_TF_RAW" == *" $key "* ]]; then
    printf '%s' "$val"
  else
    _hcl_str "$val"
  fi
}

# dp_write_tfvars: terraform/deploy.tfvars from the DV_<key> variables set in
# this run, keeping the values of an earlier run for keys not asked this time
dp_write_tfvars() {
  local k v tmp
  tmp="$(mktemp "${DEPLOY_TFVARS}.XXXXXX")"
  {
    echo "# Written by tpg-aks-infra/deploy-scripts ($(basename "$0"), $(date -u +%Y-%m-%dT%H:%M:%SZ))."
    echo "# Passed with -var-file after terraform.tfvars, so these values win. No secret here:"
    echo "# the tokens are exported as TF_VAR_* by the scripts, never saved."
    for k in $DP_TF_KEYS; do
      v="$(_dv "$k")"
      [[ -n "$v" ]] || v="$(tfv_file_get "$k" "$DEPLOY_TFVARS")"
      [[ -n "$v" ]] || continue
      printf '%s = %s\n' "$k" "$(_hcl_value "$k" "$v")"
    done
    # every other line of an earlier deploy.tfvars (your own keys, such as
    # github_url or fleet_repo_validate) is kept as it was
    if [[ -f "$DEPLOY_TFVARS" ]]; then
      DP_KEYS="$DP_TF_KEYS" awk '
        BEGIN { n = split(ENVIRON["DP_KEYS"], a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] != "") managed[a[i]] = 1 }
        skip && /\]/ { skip = 0; next }
        skip { next }
        /^# (Written by tpg-aks-infra\/deploy-scripts|Passed with -var-file|the tokens are exported)/ { next }
        match($0, /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=/) {
          k = $0; sub(/^[[:space:]]*/, "", k); sub(/[[:space:]]*=.*$/, "", k)
          if (k in managed) { if ($0 ~ /=[[:space:]]*\[/ && $0 !~ /\]/) skip = 1; next }
        }
        { print }' "$DEPLOY_TFVARS"
    fi
  } > "$tmp"
  mv "$tmp" "$DEPLOY_TFVARS"
  ok "values written to ${DEPLOY_TFVARS}"
}
_dv() { local n="DV_$1"; printf '%s' "${!n:-}"; }

# ---------------------------------------------------------------- env.sh
# env_get VAR: VAR from env.sh (sourced in a subshell), else env.sh.example;
# empty when it still holds a <placeholder>
env_get() {
  local f v=""
  for f in "$DP_ENV_FILE" "$ENV_EXAMPLE"; do
    [[ -f "$f" ]] || continue
    v="$( set +eu; source "$f" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" )"
    break
  done
  [[ "$v" == *"<"*">"* ]] && v=""
  printf '%s' "$v"
}

# env_file_get VAR: VAR from env.sh only (never env.sh.example); for values that
# must not fall back to an example default, such as FLEET_LOCAL_DIR
env_file_get() {
  local v=""
  if [[ -f "$DP_ENV_FILE" ]]; then
    v="$( set +eu; source "$DP_ENV_FILE" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" )"
  fi
  [[ "$v" == *"<"*">"* ]] && v=""
  printf '%s' "$v"
}

# dp_update_env VAR=VALUE...: env.sh with these lines; created from env.sh.example
# when missing. Shows the diff and asks before it writes (--yes accepts).
dp_update_env() {
  local base new pair var
  base="$DP_ENV_FILE"; [[ -f "$base" ]] || base="$ENV_EXAMPLE"
  new="$(mktemp)"
  cp "$base" "$new"
  for pair in "$@"; do
    var="${pair%%=*}"
    DP_V="${pair#*=}" DP_K="$var" awk '
      BEGIN { k = ENVIRON["DP_K"]; line = "export " k "=\"" ENVIRON["DP_V"] "\""; done = 0 }
      $0 ~ "^[[:space:]]*export[[:space:]]+" k "=" && !done { print line; done = 1; next }
      { print }
      END { if (!done) print line }' "$new" > "${new}.2"
    mv "${new}.2" "$new"
  done
  if [[ -f "$DP_ENV_FILE" ]] && cmp -s "$DP_ENV_FILE" "$new"; then
    rm -f "$new"; ok "env.sh is up to date"; return 0
  fi
  if [[ -f "$DP_ENV_FILE" ]]; then
    echo "Changes to ${DP_ENV_FILE}:"
    diff -u "$DP_ENV_FILE" "$new" | sed '1,2d' || true
  else
    echo "${DP_ENV_FILE} does not exist: it is created from env.sh.example with:"
    for pair in "$@"; do echo "  export ${pair%%=*}=\"${pair#*=}\""; done
  fi
  if ! dp_confirm "Write ${DP_ENV_FILE}?"; then
    rm -f "$new"; die "env.sh not changed: nothing else was done (terraform/deploy.tfvars not written either)"
  fi
  if [[ -f "$DP_ENV_FILE" ]]; then cat "$new" > "$DP_ENV_FILE"; else cp "$new" "$DP_ENV_FILE"; fi
  rm -f "$new"
  ok "env.sh written"
}

# ---------------------------------------------------------------- prompts
# ask NAME "Question" DEFAULT CHECK [SOURCE]: sets DV_NAME. CHECK is a function
# that prints the normalized value or fails. With prompts off the default is
# taken; SOURCE (where the default came from) is named when it fails.
ask() {
  local name="$1" q="$2" def="${3:-}" check="${4:-v_any}" src="${5:-}" ans norm
  while :; do
    if [[ "$PROMPTS_OFF" == 1 ]]; then
      ans="$def"
    else
      ans=""
      if [[ -n "$def" ]]; then
        read -r -p "${q}"$'\n'"  default = ${def}: " ans || die "no answer for ${name} (end of input)"
      else
        read -r -p "${q}: " ans || die "no answer for ${name} (end of input)"
      fi
      ans="${ans:-$def}"
    fi
    if [[ -z "$ans" ]]; then
      [[ "$PROMPTS_OFF" != 1 ]] || die "${name} has no value: set it in terraform/deploy.tfvars, terraform/terraform.tfvars, env.sh or the environment, or run without --non-interactive"
      echo "  a value is required" >&2; continue
    fi
    if norm="$("$check" "$ans")"; then break; fi
    [[ "$PROMPTS_OFF" != 1 ]] || die "${name}: '${ans}' is not valid${src:+ (from ${src})}"
  done
  printf -v "DV_${name}" '%s' "$norm"
}

# default_for NAME [ENVVAR] [BUILTIN]: the environment (ENVVAR, or TF_VAR_NAME),
# deploy.tfvars, terraform.tfvars, env.sh (for ENVVAR), then BUILTIN
default_for() {
  local name="$1" envvar="${2:-}" builtin="${3:-}" v=""
  if [[ -n "$envvar" ]]; then v="${!envvar:-}"; else local t="TF_VAR_${name}"; v="${!t:-}"; fi
  [[ -n "$v" ]] || [[ -n "$envvar" ]] || v="$(tfv_get "$name")"
  [[ -n "$v" || -z "$envvar" ]] || v="$(env_get "$envvar")"
  [[ -n "$v" ]] || v="$builtin"
  printf '%s' "$v"
}

# default_src NAME [ENVVAR]: where default_for NAME [ENVVAR] takes its value from
default_src() {
  local name="$1" envvar="${2:-}" t="TF_VAR_$1"
  if [[ -n "$envvar" ]]; then
    [[ -z "${!envvar:-}" ]] || { echo "the environment (${envvar})"; return; }
    [[ -z "$(env_get "$envvar")" ]] || { [[ -f "$DP_ENV_FILE" ]] && echo "$DP_ENV_FILE" || echo "$ENV_EXAMPLE"; return; }
  else
    [[ -z "${!t:-}" ]] || { echo "the environment (${t})"; return; }
    [[ -z "$(tfv_file_get "$name" "$DEPLOY_TFVARS")" ]] || { echo "$DEPLOY_TFVARS"; return; }
    [[ -z "$(tfv_file_get "$name" "$TFVARS")" ]] || { echo "$TFVARS"; return; }
  fi
  echo "the built-in default"
}

_bad() { echo "  $*" >&2; return 1; }
v_any() { printf '%s' "$1"; }
# no blank, quote, dollar, backtick or backslash: safe in env.sh and in HCL strings
DP_PLAIN_RE=$'^[^[:space:]"\'$`\\\\]+$'
v_plain() {
  [[ "$1" =~ $DP_PLAIN_RE ]] || { _bad "no spaces, quotes, \$, \` or \\ allowed"; return 1; }
  printf '%s' "$1"
}
v_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { _bad "a subscription ID (GUID)"; return 1; }; printf '%s' "$1"; }
v_location() { [[ "$1" =~ ^[a-z0-9]+$ ]] || { _bad "an Azure region name such as eastus2"; return 1; }; printf '%s' "$1"; }
v_prefix() { [[ "$1" =~ ^[a-z][a-z0-9]{2,10}$ ]] || { _bad "3 to 11 lowercase letters or digits, starting with a letter"; return 1; }; printf '%s' "$1"; }
v_rg() { [[ "$1" =~ ^[A-Za-z0-9._()-]{1,90}$ && "$1" != *. ]] || { _bad "a resource group name"; return 1; }; printf '%s' "$1"; }
v_count() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 60 ]] || { _bad "a number from 1 to 60"; return 1; }; printf '%s' "$1"; }
v_cidrs() {
  local c rest="${1// /}" out="" o
  rest="${rest#[}"; rest="${rest%]}"; rest="${rest//\"/}"
  while [[ -n "$rest" ]]; do
    c="${rest%%,*}"; [[ "$rest" == *,* ]] && rest="${rest#*,}" || rest=""
    [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || { _bad "'$c' is not an IPv4 CIDR such as 203.0.113.10/32"; return 1; }
    for o in $(echo "${c%/*}" | tr . ' '); do [[ "$o" -le 255 ]] || { _bad "'$c': an octet is above 255"; return 1; }; done
    out="${out:+$out,}$c"
  done
  [[ -n "$out" ]] || { _bad "at least one CIDR"; return 1; }
  printf '%s' "$out"
}
_enum() { local v="$1"; shift; local o; for o in "$@"; do [[ "$v" == "$o" ]] && { printf '%s' "$v"; return 0; }; done; _bad "one of: $*"; }
v_access() { _enum "$1" restricted public; }
v_network() { _enum "$1" byo managed; }
v_unseal() { _enum "$1" shamir azure-keyvault; }
v_monitoring() { _enum "$1" none azure standalone; }
v_jumpbox_os() { _enum "$1" ubuntu-24.04 ubuntu-22.04 rhel-9 rocky-9; }
v_bool() {
  case "$1" in y|yes|true|Y|YES|Yes|True) printf true ;; n|no|false|N|NO|No|False) printf false ;; *) _bad "yes or no" ;; esac
}
v_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { _bad "a lowercase Linux user name"; return 1; }; printf '%s' "$1"; }
v_owner() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || { _bad "a GitHub user or organization name"; return 1; }; printf '%s' "$1"; }
v_repo() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,100}$ && "$1" != *.git ]] || { _bad "a repository name without .git"; return 1; }; printf '%s' "$1"; }
v_branch() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != -* ]] || { _bad "a branch name"; return 1; }; printf '%s' "$1"; }
# Paths (FLEET_LOCAL_DIR, fleet_zip_path): absolute and used exactly as given.
# Nothing is prepended, ~ is not expanded, nothing is stripped (Round 18).
DP_PATH_BAD_RE=$'[][[:space:]"\'$`\\\\]'
_path_check() {
  local p="$1"
  [[ "$p" == /* ]] || { _bad "must be an absolute path starting with / (got '${p}'); ~ and relative paths are not accepted"; return 1; }
  [[ ! "$p" =~ $DP_PATH_BAD_RE ]] || { _bad "no spaces, quotes, \$, \`, \\, [ or ] (got '${p}'; press Enter to take the default)"; return 1; }
  [[ "$p" != / ]] || { _bad "/ itself is not a valid path here"; return 1; }
  [[ "$p" != */ ]] || { _bad "no trailing / (got '${p}')"; return 1; }
  case "${p}/" in
    */./*|*/../*|*//*) _bad "no '.' or '..' segments and no '//' (got '${p}')"; return 1 ;;
  esac
  return 0
}
v_zip() {
  _path_check "$1" || return 1
  [[ "$1" == *.zip ]] || { _bad "must be a .zip file (got '$1')"; return 1; }
  [[ -f "$1" ]] || { _bad "$1 is not an existing file"; return 1; }
  printf '%s' "$1"
}
v_fleet_dir() {
  local zip="${DV_fleet_zip_path:-$(tfv_get fleet_zip_path)}"
  _path_check "$1" || return 1
  [[ -d "$(dirname "$1")" ]] || { _bad "the parent folder $(dirname "$1") does not exist"; return 1; }
  [[ "$1" != "$INFRA_DIR" && "$1" != "$INFRA_DIR"/* ]] || { _bad "$1 is inside tpg-aks-infra (${INFRA_DIR}): choose a folder outside it"; return 1; }
  [[ -z "$zip" || "$zip" != "$1"/* ]] || { _bad "the zip ${zip} is inside $1, which the repo step moves aside: choose another folder"; return 1; }
  printf '%s' "$1"
}

# path_default NAME VALUE SOURCE: VALUE, or nothing when it is not absolute (a
# relative path is never resolved against some folder); stops with prompts off
path_default() {
  if [[ -n "$2" && "$2" != /* ]]; then
    [[ "$PROMPTS_OFF" != 1 ]] || die "$1 in $3 is not an absolute path ('$2'): set an absolute path there"
    warn "$1 in $3 is not an absolute path ('$2'): it is not offered as the default; give an absolute path"
    return 0
  fi
  printf '%s' "$2"
}

# token VAR "Label": VAR from the environment, else a hidden prompt. Kept as
# a shell variable, not exported: each command gets only the tokens it needs
# (VAR="$VAR" command), so terraform, ssh and the others never see them.
token() {
  local var="$1" label="$2" v
  v="${!var:-}"
  if [[ -z "$v" ]]; then
    [[ "$NON_INTERACTIVE" != 1 ]] || die "${var} is not exported (--non-interactive reads the tokens from the environment only)"
    read -r -s -p "${label} (hidden): " v || die "no value for ${var} (end of input)"
    echo >&2
    [[ -n "$v" ]] || die "${var} must not be empty"
  fi
  printf -v "$var" '%s' "$v"
  export -n "$var"
}

# dp_confirm "Question": --yes accepts; --non-interactive without --yes refuses
dp_confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  [[ "$NON_INTERACTIVE" != 1 ]] || die "$1 needs a confirmation: add --yes"
  local a=""
  read -r -p "$1 Type yes to continue: " a || true
  [[ "$a" == yes ]]
}

# ---------------------------------------------------------------- common prompts
public_ip_cidr() {
  local ip
  ip="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && printf '%s/32' "$ip"
  return 0
}

# ask_infra: the Terraform settings of every deployment
ask_infra() {
  local sub
  sub="$(default_for subscription_id)"
  [[ -n "$sub" ]] || sub="$(az account show --query id -o tsv 2>/dev/null || true)"
  ask subscription_id "Azure subscription ID" "$sub" v_uuid
  ask location "Azure region" "$(default_for location "" eastus2)" v_location
  ask prefix "Name prefix" "$(default_for prefix "" tpgpoc)" v_prefix
  ask resource_group_name "Resource group" "$(default_for resource_group_name "" "rg-${DV_prefix}")" v_rg
  ask target_cluster_count "Number of target clusters" "$(default_for target_cluster_count "" 3)" v_count
  local cidrs
  cidrs="$(default_for admin_allowed_cidrs)"
  [[ -n "$cidrs" ]] || cidrs="$(public_ip_cidr)"
  ask admin_allowed_cidrs "Admin CIDRs, comma separated (must include this machine; the UI load balancers, SSH to the jumpbox, and with byo the API servers)" "$cidrs" v_cidrs
  # Round 19 order: the role assignments first, as byo depends on them
  local ra
  # terraform-enabled-deploy.sh needs yes, so yes is its default
  ra="$(default_for create_role_assignments "" "$( [[ "${DP_ROLE_CHECK:-}" == v_role_tf ]] && echo true || echo false)")"
  ask create_role_assignments "Can the account running Terraform create role assignments (Owner or User Access Administrator)? yes/no" \
    "$( [[ "$ra" == true ]] && echo yes || echo no)" "${DP_ROLE_CHECK:-v_bool}" "$(default_src create_role_assignments)"
  local nm
  nm="$(default_for network_mode "" managed)"
  # a saved byo is not offered when it would be refused (asking only: with
  # prompts off the saved value stays, and its refusal names the file)
  [[ "$PROMPTS_OFF" == 1 || "$nm" != byo || "$DV_create_role_assignments" == true ]] || nm=managed
  ask network_mode "Network mode: managed (AKS-managed VNets, public API servers) or byo (own VNet, needs role assignments)" \
    "$nm" v_network_ra "$(default_src network_mode)"
  if [[ "$DV_network_mode" == byo ]]; then
    ask api_access_mode "API server access: restricted or public" "$(default_for api_access_mode "" restricted)" v_access
  fi
  ask vault_unseal_mode "Vault unseal mode: shamir or azure-keyvault (no default)" "$(default_for vault_unseal_mode)" v_unseal
}

# v_network_ra: byo or managed; byo only with the role assignments (the
# Terraform validation on network_mode refuses the same)
v_network_ra() {
  local v
  v="$(v_network "$1")" || return 1
  if [[ "$v" == byo && "${DV_create_role_assignments:-false}" != true ]]; then
    _bad "byo needs the Network Contributor role assignments before the clusters exist: answer yes to the role question (Owner or User Access Administrator), or use managed"
    return 1
  fi
  printf '%s' "$v"
}

# api_line: the API server access the answers give, for the summaries
api_line() {
  if [[ "${DV_network_mode:-}" == managed ]]; then
    printf '  %-24s %s\n' "API servers" "public (managed network mode)"
  fi
}

ask_jumpbox() {
  ask jumpbox_os "Jumpbox OS: ubuntu-24.04, ubuntu-22.04, rhel-9 or rocky-9" "$(default_for jumpbox_os "" ubuntu-24.04)" v_jumpbox_os
  ask jumpbox_admin_username "Jumpbox admin user" "$(default_for jumpbox_admin_username "" tpgadmin)" v_user
}

ask_env() {
  ask GITHUB_USER "GitHub user (env.sh GITHUB_USER)" "$(default_for GITHUB_USER GITHUB_USER)" v_plain
  ask BROADCOM_USER "Broadcom support portal user (env.sh BROADCOM_USER)" "$(default_for BROADCOM_USER BROADCOM_USER)" v_plain
  ask MONITORING_OPTION "Monitoring: none, azure or standalone" "$(default_for MONITORING_OPTION MONITORING_OPTION none)" v_monitoring
}

ask_repo() {
  ask fleet_repo_owner "GitHub owner of the fleet repository (user or organization)" "$(default_for fleet_repo_owner "" "${DV_GITHUB_USER:-}")" v_owner
  ask fleet_repo_name "Fleet repository name" "$(default_for fleet_repo_name "" poc-tpg-fleet-v15)" v_repo
  ask fleet_repo_branch "Fleet repository branch" "$(default_for fleet_repo_branch "" main)" v_branch
  local z src
  src="$(default_src fleet_zip_path)"
  z="$(default_for fleet_zip_path)"
  if [[ -n "$z" ]]; then
    z="$(path_default fleet_zip_path "$z" "$src")"
  else
    z="$(cd "${INFRA_DIR}/.." && pwd)/tpg-fleet.zip"   # absolute: next to tpg-aks-infra
  fi
  ask fleet_zip_path "Path of tpg-fleet.zip (absolute path)" "$z" v_zip "$src"
}

# ask_fleet_dir "Question": FLEET_LOCAL_DIR, absolute only. No default is offered
# (Round 19): the path is always typed. With prompts off (--non-interactive,
# all --from) it comes from the environment or env.sh.
ask_fleet_dir() {
  local src="" d=""
  if [[ "$PROMPTS_OFF" == 1 ]]; then
    # the environment or env.sh only: never the example's ~/src/tpg-fleet
    if [[ -n "${FLEET_LOCAL_DIR:-}" ]]; then src="the environment (FLEET_LOCAL_DIR)"; d="$FLEET_LOCAL_DIR"
    else src="$DP_ENV_FILE"; d="$(env_file_get FLEET_LOCAL_DIR)"; fi
    [[ -n "$d" ]] || die "FLEET_LOCAL_DIR is not set in ${DP_ENV_FILE} or the environment: with --non-interactive (and all --from) it is not asked; set an absolute path there"
    d="$(path_default FLEET_LOCAL_DIR "$d" "$src")"
  fi
  ask FLEET_LOCAL_DIR "$1 (absolute path)" "$d" v_fleet_dir "$src"
}

# github_urls: GITHUB_WEB and GITHUB_API from github_url of the tfvars files
github_urls() {
  GITHUB_WEB="$(tfv_get github_url)"; GITHUB_WEB="${GITHUB_WEB:-https://github.com}"
  if [[ "$GITHUB_WEB" == https://github.com ]]; then GITHUB_API=https://api.github.com; else GITHUB_API="${GITHUB_WEB}/api/v3"; fi
}

# ---------------------------------------------------------------- terraform
tfb() { "$TF_BIN" -chdir="$TF_DIR" "$@"; }

# tf_plan_apply: init, plan, one confirmation, apply (-var-file deploy.tfvars)
tf_plan_apply() {
  TF_BIN="$(dp_tf_bin)"
  log "${TF_BIN} init"
  tfb init -input=false
  log "${TF_BIN} plan (terraform.tfvars, then ${DEPLOY_TFVARS}); no plan file is saved: it would hold the tokens"
  tfb plan -input=false -var-file="$DEPLOY_TFVARS"
  dp_confirm "Apply this plan? The apply plans again; if anything changed in between, that is applied too." \
    || die "stopped before terraform apply: nothing was changed in Azure"
  log "${TF_BIN} apply"
  tfb apply -input=false -auto-approve -var-file="$DEPLOY_TFVARS"
  ok "terraform apply finished"
}

# tf_out NAME: an output (raw), empty when it is null or missing
tf_out() {
  TF_BIN="${TF_BIN:-$(dp_tf_bin)}"
  local v
  v="$(tfb output -raw "$1" 2>/dev/null || true)"
  [[ "$v" == null ]] && v=""
  printf '%s' "$v"
}

# az_logged_in: az account show works (az login before Terraform and run.sh)
az_logged_in() {
  az account show >/dev/null 2>&1 || die "not logged in to Azure: run az login (and az account set --subscription <id>)"
  ok "az logged in: $(az account show --query name -o tsv 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------- steps
# run_steps "STEP..." [FROM]: run step_<name> in order from FROM; on a failure
# print the command that resumes. A step that exits DP_PAUSE pauses the run (it printed
# what to do first); the resume line then names the next step. A step pauses
# with exit status DP_PAUSE (75, EX_TEMPFAIL), which no script it runs uses.
DP_PAUSE=75
run_steps() {
  local steps="$1" from="${2:-}" started=0 s rc
  [[ -n "$from" ]] || started=1
  for s in $steps; do
    [[ "$s" == "$from" ]] && started=1
    [[ "$started" == 1 ]] || continue
    step "$s"
    # Not in an if or || list: there bash would turn set -e off inside the step
    set +e
    ( set -e; "step_${s}" )
    rc=$?
    set -e
    if [[ "$rc" -eq "$DP_PAUSE" ]]; then
      local next
      next="$(echo "$steps" | tr ' ' '\n' | grep -A1 -x "$s" | sed -n 2p)"
      printf '\n\033[1;33mPAUSED\033[0m after step %s (see above). Then resume with:\n  %s all --from %s\n' "$s" "$0" "${next:-$s}" >&2
      return "$DP_PAUSE"
    fi
    if [[ "$rc" -ne 0 ]]; then
      printf '\n\033[1;31mFAIL\033[0m step %s failed. After fixing the cause, resume with:\n  %s all --from %s\n' \
        "$s" "$0" "$s" >&2
      return 1
    fi
  done
}
