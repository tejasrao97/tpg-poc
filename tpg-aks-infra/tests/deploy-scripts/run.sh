#!/usr/bin/env bash
# deploy-scripts/deploy.sh and terraform-enabled-deploy.sh against stubs, on a
# temporary copy of this repository (Round 17). No Azure, no GitHub, no SSH:
#   terraform, az, curl, ssh and the run-time CLIs are stubs in $T/bin; the
#   copy's scripts/run.sh and scripts/jumpbox/push-fleet-repo.sh are replaced by
#   recorders; ssh runs the remote command locally with HOME=$T/remote.
#   1 usage: no subcommand, an unknown one, --from without all
#   2 preflight: the tools pass; a Python yq and bash 3 are named
#   3 apply: prompts with defaults, deploy.tfvars (terraform.tfvars untouched),
#     plan with -var-file, apply only after "yes"; --non-interactive needs --yes
#   4 repo: env.sh created after a diff and a yes, push-fleet-repo.sh gets the
#     repository values and the token in its environment
#   5 setup: refused before apply; run.sh with the four flags and the tokens
#   6 copy: no jumpbox, a jumpbox not set up, then the copy (the jumpbox keeps
#     its inventory.yaml), a second copy moves ~/tpg-fleet aside, no key left
#   7 all: every step in order; a failed setup prints the resume line; --from
#   8 terraform-enabled-deploy.sh all: the three switches true, the tokens as
#     TF_VAR_* for terraform only
#   9 no token in deploy.tfvars, env.sh, the logs or any command line
#  10 review findings: a failing plan, apply, run.sh or copy fails the single
#     subcommand; the generated key is removed on every path; tofu only;
#     a multi-line admin_allowed_cidrs; env.sh on the jumpbox; env.sh follows a
#     changed repository name; extra deploy.tfvars keys kept; each command sees
#     only its tokens; xtrace refused; CIDR octets
#  11 FLEET_LOCAL_DIR and fleet_zip_path (Round 18): absolute only, used as typed;
#     relative, ~, [..] pasted from the prompt, '..', a trailing /, not .zip, a
#     missing zip or parent, inside tpg-aks-infra, a folder holding the zip are
#     each refused and asked again; with --non-interactive the file is named
#  12 Round 19: create_role_assignments = no pauses all after apply (the az
#     commands printed, all --from repo resumes); terraform-enabled-deploy.sh
#     refuses no; the prompt shows "default = <value>"; FLEET_LOCAL_DIR has no
#     default and is not in the summary
# Requires bash (3.2 or later), git, jq, tar, unzip, zip and awk.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in git jq tar unzip zip awk; do
  command -v "$t" >/dev/null || { echo "SKIP tests/deploy-scripts: $t not installed" >&2; exit 0; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ADMIN_TOK="tok-admin-6f1c" BC_TOK="tok-broadcom-91aa" READ_TOK="tok-read-22bb" PUSH_TOK="tok-push-33cc"
SUB="00000000-1111-2222-3333-444444444444"

# ---------------------------------------------------------------- stubs
mkdir -p "$T/bin" "$T/calls"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/bin/$1"; chmod 755 "$T/bin/$1"; }
# terraform: records its arguments and which TF_VAR tokens are set; outputs from $T/outputs/<name>
stub terraform '
echo "terraform $*" >> "$T_CALLS/log"
for v in GIT_ADMIN_PAT BROADCOM_TOKEN GIT_READ_PAT GIT_PUSH_PAT; do [[ -z "${!v:-}" ]] || echo "terraform-sees $v" >> "$T_CALLS/env"; done
case "$* " in *" ${TF_FAIL:-none} "*) echo "stub: terraform ${TF_FAIL} failed" >&2; exit 1 ;; esac
for v in git_admin_pat broadcom_token git_read_pat git_push_pat; do n="TF_VAR_$v"; [[ -z "${!n:-}" ]] || echo "terraform-env $v=${!n}" >> "$T_CALLS/env"; done
case "$*" in
  *"version -json"*) echo "{\"terraform_version\": \"${TF_STUB_VERSION:-1.14.9}\"}" ;;
  *" output -raw "*) n="${@: -1}"; [[ -f "$T_OUT/$n" ]] && cat "$T_OUT/$n" || { echo "no output $n" >&2; exit 1; } ;;
  *" output -json "*) n="${@: -1}"; [[ -f "$T_OUT/$n.json" ]] && cat "$T_OUT/$n.json" || echo "[]" ;;
  *" apply "*) mkdir -p "$T_OUT"; echo aks-tpg-hub > "$T_OUT/hub_cluster_name" ;;
esac
exit 0'
stub az '
case "$*" in
  *"--query id"*) echo "'"$SUB"'" ;;
  *"--query name"*) echo "POC subscription" ;;
  "account show") echo "{}" ;;
  *) echo "az $*" >> "$T_CALLS/log" ;;
esac'
stub curl 'case "$*" in *ifconfig.me*) echo 203.0.113.7 ;; *) exit 1 ;; esac'
stub helm 'echo v4.3.0'
stub yq 'echo "yq (https://github.com/mikefarah/yq/) version ${YQ_STUB:-v4.47.2}"'
for t in kubectl argocd argo kubelogin openssl yamllint shellcheck kustomize kubeconform; do stub "$t" 'exit 0'; done
stub python3 'exit 0'
stub bash5 'echo "${BASH_STUB_VERSION:-5.2}"'
# ssh: the remote command runs here with HOME=$T/remote; GNU tar options dropped
stub ssh '
echo "ssh $*" >> "$T_CALLS/log"
while [[ $# -gt 0 ]]; do case "$1" in -i|-o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
cmd="${*//--warning=no-unknown-keyword/}"
for v in GIT_ADMIN_PAT BROADCOM_TOKEN GIT_READ_PAT GIT_PUSH_PAT; do [[ -z "${!v:-}" ]] || echo "ssh-sees $v" >> "$T_CALLS/env"; done
[[ -z "${SSH_FAIL_TAR:-}" || "$cmd" != *"tar -C ~/tpg-fleet"* ]] || { echo "stub: remote tar failed" >&2; exit 1; }
HOME="$T_REMOTE" /bin/bash -c "$cmd"'
# on the fake jumpbox: cloud-init has finished; sudo runs the command, except a
# run of setup-jumpbox.sh, which is only recorded
stub cloud-init 'case "$*" in *--wait*) exit 0 ;; status*) echo "status: ${CLOUDINIT_STATUS:-done}" ;; esac'
stub sudo '
echo "sudo $*" >> "$T_CALLS/log"
case "$*" in *setup-jumpbox.sh*) echo "stub: setup-jumpbox.sh ran"; exit "${STUB_SETUP_RC:-0}" ;; esac
exec "$@"'

# a copy of the repository with recorders for run.sh and push-fleet-repo.sh
new_repo() {
  R="$T/$1/tpg-aks-infra"
  rm -rf "$T/$1"; mkdir -p "$R/terraform"
  cp -R "$ROOT/deploy-scripts" "$ROOT/scripts" "$R/"
  cp "$ROOT/env.sh.example" "$R/"
  printf '# hand-edited\nfleet_repo_validate = false # tests: no validate.sh tools\n' > "$R/terraform/terraform.tfvars"
  cat > "$R/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/lib/common.sh"
trap - EXIT   # common.sh cleanup: bash 3.2 here, the real scripts run under bash 4
echo "run.sh $*" >> "$T_CALLS/log"
[[ "${RUNSH_RC:-0}" == 0 ]] || printf '\033[1;35m== %-17s scripts/%s\033[0m\n' "${RUNSH_FAIL_STEP:-hub-secrets}" "steps/x.sh"
echo "run.sh-sees-admin=${GIT_ADMIN_PAT:-} tf_bin=${TF_BIN}" >> "$T_CALLS/env"
echo "run.sh-env broadcom=${BROADCOM_TOKEN:-} read=${GIT_READ_PAT:-} push=${GIT_PUSH_PAT:-}" >> "$T_CALLS/env"
d="$(cd "$(dirname "$0")/.." && pwd)/.work"; mkdir -p "$d"; echo "kubeconfig" > "$d/kubeconfig"; echo local > "$d/inventory.yaml"
exit "${RUNSH_RC:-0}"
EOF
  cat > "$R/scripts/jumpbox/push-fleet-repo.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/../lib/common.sh"
trap - EXIT   # common.sh cleanup: bash 3.2 here, the real scripts run under bash 4
echo "push $1" >> "$T_CALLS/log"
echo "push-sees-broadcom=${BROADCOM_TOKEN:-}" >> "$T_CALLS/env"
echo "push-env url=${FLEET_REPO_URL} rev=${FLEET_REPO_REVISION} dir=${FLEET_LOCAL_DIR} api=${GITHUB_API_URL} validate=${FLEET_VALIDATE_TFVARS:-} admin=${GIT_ADMIN_PAT:-}" >> "$T_CALLS/env"
mkdir -p "$FLEET_LOCAL_DIR/.git" && echo fleet > "$FLEET_LOCAL_DIR/README.md"
EOF
  chmod 755 "$R/scripts/run.sh" "$R/scripts/jumpbox/push-fleet-repo.sh"
  printf 'zip' > "$T/$1/tpg-fleet.zip"
  export T_CALLS="$T/$1/calls" T_OUT="$T/$1/outputs" T_REMOTE="$T/$1/remote"
  mkdir -p "$T_CALLS" "$T_REMOTE"; : > "$T_CALLS/log"; : > "$T_CALLS/env"
  export HOME="$T/$1/home"; mkdir -p "$HOME/src"   # FLEET_LOCAL_DIR ~/src/tpg-fleet: its parent must exist
  # the fake jumpbox's state, log and cloud-init log (deploy.sh copy)
  export DEPLOY_JUMPBOX_STATE_DIR="$T/$1/remote-state" DEPLOY_JUMPBOX_LOG_DIR="$T/$1/remote-log" \
    DEPLOY_CLOUD_INIT_LOG="$T/$1/remote-log/cloud-init-output.log"
}
# dep SCRIPT ARGS... < answers: exit status in RC, output in $T/out. Feed the
# answers with < <(printf ...), not a pipe: a pipe runs dep in a subshell and RC is lost.
dep() {
  local s="$1"; shift
  RC=0
  env -u TF_BIN -u GITHUB_USER -u BROADCOM_USER -u MONITORING_OPTION -u FLEET_LOCAL_DIR -u ENV_FILE \
    PATH="$T/bin:$PATH" DEPLOY_BASH_CANDIDATES="" DEPLOY_BASH="$T/bin/bash5" \
    bash "$R/deploy-scripts/$s" "$@" > "$T/out" 2>&1 || RC=$?
}
tokens_on() { export GIT_ADMIN_PAT="$ADMIN_TOK" BROADCOM_TOKEN="$BC_TOK" GIT_READ_PAT="$READ_TOK" GIT_PUSH_PAT="$PUSH_TOK"; }
tokens_off() { unset GIT_ADMIN_PAT BROADCOM_TOKEN GIT_READ_PAT GIT_PUSH_PAT TF_VAR_git_admin_pat TF_VAR_broadcom_token TF_VAR_git_read_pat TF_VAR_git_push_pat 2>/dev/null || true; }
tokens_off
sha_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}'; }

echo "== 1: usage"
new_repo u
dep deploy.sh < /dev/null
check "no subcommand: usage, exit 2, nothing run" '[[ $RC -eq 2 ]] && grep -q "preflight|apply|repo|setup|copy|all" "$T/out" && [[ ! -s "$T_CALLS/log" ]]' "$(cat "$T/out")"
dep deploy.sh deploy < /dev/null
check "an unknown subcommand is refused" '[[ $RC -eq 2 ]] && grep -q "unknown subcommand: deploy" "$T/out"'
dep deploy.sh apply --from repo < /dev/null
check "--from works with all only" '[[ $RC -eq 2 ]] && grep -q "with .all. only" "$T/out"'
dep terraform-enabled-deploy.sh < /dev/null
check "terraform-enabled-deploy.sh: no subcommand prints its usage" '[[ $RC -eq 2 ]] && grep -q "preflight|apply|all" "$T/out"'

echo "== 2: preflight"
dep deploy.sh preflight < /dev/null
check "preflight passes with every tool" '[[ $RC -eq 0 ]] && grep -q "az logged in" "$T/out"' "$(tail -5 "$T/out")"
YQ_STUB=v3.4.1 dep deploy.sh preflight < /dev/null
check "a yq that is not mikefarah v4 is named" '[[ $RC -ne 0 ]] && grep -q "yq is not mikefarah yq v4" "$T/out"' "$(tail -5 "$T/out")"
BASH_STUB_VERSION=3.2 dep deploy.sh preflight < /dev/null
check "bash 3 on PATH is named for run.sh" '[[ $RC -ne 0 ]] && grep -q "needs bash 4 or later" "$T/out"'
TF_STUB_VERSION=1.5.7 dep deploy.sh preflight < /dev/null
check "Terraform older than 1.9 is named" '[[ $RC -ne 0 ]] && grep -q "Terraform 1.5.7: 1.9 or later" "$T/out"'

echo "== 3: apply"
tfsum="$(cksum < "$R/terraform/terraform.tfvars")"
dep deploy.sh apply < <(printf '\n\n\n\n\n\nyes\n\nshamir\n\nno\n')
check "answer other than yes: no apply" '[[ $RC -ne 0 ]] && grep -q "stopped before terraform apply" "$T/out" && ! grep -q "terraform -chdir=.* apply" "$T_CALLS/log"' "$(tail -5 "$T/out")"
dep deploy.sh apply < <(printf '\n\n\n\n\n\nyes\n\nshamir\n\nyes\n')
DT="$R/terraform/deploy.tfvars"
check "apply runs after yes, with -var-file deploy.tfvars" '[[ $RC -eq 0 ]] && grep -q "plan -input=false -var-file=$DT" "$T_CALLS/log" && grep -q "apply -input=false -auto-approve -var-file=$DT" "$T_CALLS/log"' "$(tail -5 "$T/out")"
check "deploy.tfvars: the defaults, the public IP, no jumpbox, no jumpbox steps" \
  'grep -q "^subscription_id = \"$SUB\"$" "$DT" && grep -q "^admin_allowed_cidrs = \[\"203.0.113.7/32\"\]$" "$DT" && grep -q "^resource_group_name = \"rg-tpgpoc\"$" "$DT" && grep -q "^vault_unseal_mode = \"shamir\"$" "$DT" && grep -q "^enable_jumpbox = false$" "$DT" && grep -q "^create_fleet_repo = false$" "$DT" && grep -q "^run_fleet_setup = false$" "$DT"' "$(cat "$DT" 2>/dev/null)"
check "deploy.tfvars: network_mode managed by default; no API access question (not written)" 'grep -q "^network_mode = \"managed\"$" "$DT" && ! grep -q "^api_access_mode" "$DT" && grep -q "API servers  *public (managed network mode)" "$T/out"' "$(cat "$DT")"
check "deploy.tfvars: create_role_assignments as answered, the cloud-init setup method" 'grep -q "^create_role_assignments = true$" "$DT" && grep -q "^jumpbox_setup_method = \"cloud-init\"$" "$DT"' "$(cat "$DT")"
check "terraform.tfvars is not changed" '[[ "$(cksum < "$R/terraform/terraform.tfvars")" == "$tfsum" ]]'
dep deploy.sh apply --non-interactive < /dev/null
check "--non-interactive without --yes refuses at the plan" '[[ $RC -ne 0 ]] && grep -q "needs a confirmation: add --yes" "$T/out"'
: > "$T_CALLS/log"
dep deploy.sh apply --non-interactive --yes < /dev/null
check "--non-interactive --yes reuses deploy.tfvars and applies" '[[ $RC -eq 0 ]] && grep -q "apply -input=false -auto-approve" "$T_CALLS/log"' "$(tail -5 "$T/out")"
sed -i.bak 's/^prefix = .*/prefix = "Bad-Prefix"/' "$DT" && rm -f "$DT.bak"
dep deploy.sh apply --non-interactive --yes < /dev/null
check "--non-interactive stops on an invalid saved value" '[[ $RC -ne 0 ]] && grep -q "prefix: .Bad-Prefix. is not valid" "$T/out"' "$(tail -3 "$T/out")"
sed -i.bak 's/^prefix = .*/prefix = "tpgpoc"/' "$DT" && rm -f "$DT.bak"

echo "== 4: repo"
tokens_on
dep deploy.sh repo < <(printf "octo\n\n\n\n\n$HOME/src/tpg-fleet\nno\n")
check "env.sh not written after no: nothing pushed" '[[ $RC -ne 0 ]] && [[ ! -f "$R/env.sh" ]] && ! grep -q "^push " "$T_CALLS/log"' "$(tail -5 "$T/out")"
dep deploy.sh repo < <(printf "octo\n\n\n\n\n$HOME/src/tpg-fleet\nyes\n")
check "repo: env.sh created from env.sh.example with the repository values" \
  '[[ $RC -eq 0 ]] && grep -q "^export GITHUB_USER=\"octo\"$" "$R/env.sh" && grep -q "^export FLEET_REPO_URL=\"https://github.com/octo/poc-tpg-fleet-v15.git\"$" "$R/env.sh" && grep -q "^export FLEET_LOCAL_DIR=\"$HOME/src/tpg-fleet\"$" "$R/env.sh" && grep -q "^export BROADCOM_USER=\"<broadcom-support-portal-user>\"$" "$R/env.sh"' "$(tail -5 "$T/out")"
check "the summary shows no FLEET_LOCAL_DIR line and no note" '! grep -q "^  FLEET_LOCAL_DIR " "$T/out" && ! grep -q "note: " "$T/out"' "$(grep -n "FLEET_LOCAL_DIR\|note" "$T/out")"
check "push-fleet-repo.sh gets the zip, the repository values and the token" \
  'grep -q "^push $T/u/tpg-fleet.zip$" "$T_CALLS/log" && grep -q "url=https://github.com/octo/poc-tpg-fleet-v15.git rev=main dir=$HOME/src/tpg-fleet api=https://api.github.com validate=false admin=$ADMIN_TOK" "$T_CALLS/env"' "$(cat "$T_CALLS/env")"
tokens_off

echo "== 5: setup"
rm -rf "$T_OUT"
tokens_on
dep deploy.sh setup < <(printf "\nbob\n\n$HOME/src/tpg-fleet\nyes\n")
check "setup before apply: refused, run.sh not run" '[[ $RC -ne 0 ]] && grep -q "run deploy.sh apply first" "$T/out" && ! grep -q "^run.sh" "$T_CALLS/log"' "$(tail -5 "$T/out")"
check "setup wrote BROADCOM_USER to env.sh" 'grep -q "^export BROADCOM_USER=\"bob\"$" "$R/env.sh"'
mkdir -p "$T_OUT"; echo aks-tpg-hub > "$T_OUT/hub_cluster_name"
dep deploy.sh setup < <(printf "\n\n\n$HOME/src/tpg-fleet\n")
check "setup runs run.sh with the four flags" '[[ $RC -eq 0 ]] && grep -q "^run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys$" "$T_CALLS/log"' "$(tail -5 "$T/out")"
check "run.sh gets the three tokens in its environment" 'grep -q "^run.sh-env broadcom=$BC_TOK read=$READ_TOK push=$PUSH_TOK$" "$T_CALLS/env"'
tokens_off
dep deploy.sh setup --non-interactive < <(printf "\n\n\n$HOME/src/tpg-fleet\n")
check "--non-interactive: a token that is not exported stops the step" '[[ $RC -ne 0 ]] && grep -q "BROADCOM_TOKEN is not exported" "$T/out"'

echo "== 6: copy"
dep deploy.sh copy --yes < /dev/null
check "copy without a jumpbox: nothing to copy, exit 0" '[[ $RC -eq 0 ]] && grep -q "nothing to copy" "$T/out"'
echo 198.51.100.7 > "$T_OUT/jumpbox_public_ip"; echo "PRIVATE-KEY" > "$T_OUT/jumpbox_ssh_private_key"
dep deploy.sh copy --yes < /dev/null
check "copy before the jumpbox_env_override and jumpbox_inventory_yaml outputs exist is refused" '[[ $RC -ne 0 ]] && grep -q "outputs jumpbox_env_override and jumpbox_inventory_yaml are missing" "$T/out"' "$(tail -3 "$T/out")"
printf 'export FLEET_LOCAL_DIR="/home/tpgadmin/tpg-fleet"\nexport INVENTORY_PREBUILT="true"\n' > "$T_OUT/jumpbox_env_override"
echo "backup: {keySource: az}" > "$T_OUT/jumpbox_inventory_yaml"
mkdir -p "$DEPLOY_JUMPBOX_LOG_DIR" "$T_REMOTE/.work"; echo "E: apt-get failed (stub)" > "$DEPLOY_CLOUD_INIT_LOG"; echo remote > "$T_REMOTE/.work/inventory.yaml"
STUB_SETUP_RC=1 dep deploy.sh copy --yes < /dev/null
check "no setup record after cloud-init: the log tail is shown and the setup runs again; its failure stops copy with the log path" '[[ $RC -ne 0 ]] && grep -q "did not finish at first boot" "$T/out" && grep -q "E: apt-get failed (stub)" "$T/out" && grep -q "stub: setup-jumpbox.sh ran" "$T/out" && grep -q "setup-jumpbox.sh failed on the jumpbox" "$T/out"' "$(tail -4 "$T/out")"
dep deploy.sh copy --yes < /dev/null
check "copy again: the setup runs again and copy goes on (no dead end)" '[[ $RC -eq 0 ]] && grep -q "runs again now" "$T/out" && grep -q "stub: setup-jumpbox.sh ran" "$T/out"' "exit $RC: $(tail -4 "$T/out")"
mkdir -p "$DEPLOY_JUMPBOX_STATE_DIR"; sha_of "$R/scripts/jumpbox/setup-jumpbox.sh" > "$DEPLOY_JUMPBOX_STATE_DIR/setup-jumpbox.sha256"
: > "$T_CALLS/log"
dep deploy.sh copy --yes < /dev/null
check "copy waits for cloud-init, then copies scripts/ and env.sh" '[[ $RC -eq 0 ]] && grep -q "cloud-init status --wait" "$T_CALLS/log" && [[ -f "$T_REMOTE/scripts/jumpbox/setup-jumpbox.sh" && -f "$T_REMOTE/scripts/run.sh" ]] && cmp -s "$T_REMOTE/env.sh" "$R/env.sh"' "exit $RC: $(tail -4 "$T/out")"
check "the same setup-jumpbox.sh as at first boot: not run again" '! grep -q "stub: setup-jumpbox.sh ran" "$T/out"'
check "copy: tpg-fleet with .git and .work with the kubeconfig" '[[ -d "$T_REMOTE/tpg-fleet/.git" && -f "$T_REMOTE/tpg-fleet/README.md" && "$(cat "$T_REMOTE/.work/kubeconfig")" == kubeconfig ]]'
check "copy: env.jumpbox.sh and inventory.yaml from the Terraform outputs; no deploy log copied" 'cmp -s "$T_REMOTE/env.jumpbox.sh" "$T_OUT/jumpbox_env_override" && [[ "$(cat "$T_REMOTE/.work/inventory.yaml")" == "backup: {keySource: az}" ]] && ! ls "$T_REMOTE/.work" | grep -q "^deploy-"' "$(cat "$T_REMOTE/.work/inventory.yaml")"
check "copy: ssh as tpgadmin with the generated key, which is gone afterwards" \
  'left=""; for k in $(grep -o -- "-i [^ ]*" "$T_CALLS/log" | cut -c4- | sort -u); do [[ ! -e "$k" ]] || left="$left $k"; done; grep -q "tpgadmin@198.51.100.7" "$T_CALLS/log" && [[ -z "$left" ]]'
echo "older-version" > "$DEPLOY_JUMPBOX_STATE_DIR/setup-jumpbox.sha256"
dep deploy.sh copy --yes < /dev/null
check "a newer setup-jumpbox.sh is run again over SSH, its output shown" '[[ $RC -eq 0 ]] && grep -q "stub: setup-jumpbox.sh ran" "$T/out" && grep -q "an older version" "$T/out" && [[ -d "$DEPLOY_JUMPBOX_LOG_DIR" ]]' "$(tail -4 "$T/out")"
check "a second copy moves ~/tpg-fleet to ~/tpg-fleet.prev-<UTC>" 'ls -d "$T_REMOTE"/tpg-fleet.prev-* >/dev/null 2>&1'
dep deploy.sh copy --non-interactive < /dev/null
check "copy needs a confirmation (--yes) without a terminal" '[[ $RC -ne 0 ]] && grep -q "needs a confirmation" "$T/out"'

echo "== 7: all"
new_repo a
tokens_on
ANS="\n\n\n\n\n\nyes\n\nshamir\n\nocto\nbob\n\n\n\n\n\n$HOME/src/tpg-fleet\nyes\nyes\n"
dep deploy.sh all < <(printf "$ANS")
order="$(grep -oE "^(terraform -chdir=[^ ]+ (init|plan|apply)|push|run.sh)" "$T_CALLS/log" | sed 's/terraform -chdir=[^ ]* //' | tr '\n' ' ')"
check "all: preflight, apply, repo, setup in order; copy skipped without a jumpbox" '[[ $RC -eq 0 ]] && [[ "$order" == "init plan apply push run.sh " ]] && grep -q "nothing to copy" "$T/out"' "exit $RC, order: $order; $(tail -5 "$T/out")"
check "all: one deploy.tfvars and env.sh with every value" 'grep -q "^fleet_repo_owner = \"octo\"$" "$R/terraform/deploy.tfvars" && grep -q "^export BROADCOM_USER=\"bob\"$" "$R/env.sh" && grep -q "^export MONITORING_OPTION=\"none\"$" "$R/env.sh"'
: > "$T_CALLS/log"
RUNSH_RC=3 dep deploy.sh all --non-interactive --yes < /dev/null
check "a failed setup stops all and prints the resume line" '[[ $RC -ne 0 ]] && grep -q "deploy.sh all --from setup" "$T/out"' "$(tail -4 "$T/out")"
: > "$T_CALLS/log"
dep deploy.sh all --from setup --yes < /dev/null
check "all --from setup runs setup and copy only, without prompts" '[[ $RC -eq 0 ]] && ! grep -qE "terraform -chdir=[^ ]+ (plan|apply)|^push" "$T_CALLS/log" && grep -q "^run.sh" "$T_CALLS/log"' "$(tail -4 "$T/out")"
check "all wrote a log in .work" 'ls "$R/.work"/deploy-*.log >/dev/null 2>&1'
tokens_off

echo "== 8: terraform-enabled-deploy.sh all"
new_repo tf
tokens_on
dep terraform-enabled-deploy.sh all < <(printf '\n\n\n\n\n\nyes\n\nshamir\n\n\nocto\nbob\n\n\n\n\n\nyes\nyes\n')
DT="$R/terraform/deploy.tfvars"
check "the three switches are true in deploy.tfvars" '[[ $RC -eq 0 ]] && grep -q "^enable_jumpbox = true$" "$DT" && grep -q "^create_fleet_repo = true$" "$DT" && grep -q "^run_fleet_setup = true$" "$DT" && grep -q "^jumpbox_os = \"ubuntu-24.04\"$" "$DT" && grep -q "^fleet_zip_path = \"$T/tf/tpg-fleet.zip\"$" "$DT"' "exit $RC: $(tail -5 "$T/out")"
check "terraform gets the four tokens as TF_VAR_*" 'grep -q "terraform-env git_admin_pat=$ADMIN_TOK" "$T_CALLS/env" && grep -q "terraform-env broadcom_token=$BC_TOK" "$T_CALLS/env" && grep -q "terraform-env git_read_pat=$READ_TOK" "$T_CALLS/env" && grep -q "terraform-env git_push_pat=$PUSH_TOK" "$T_CALLS/env"'
check "env.sh for the jumpbox: GITHUB_USER, BROADCOM_USER, MONITORING_OPTION" 'grep -q "^export GITHUB_USER=\"octo\"$" "$R/env.sh" && grep -q "^export BROADCOM_USER=\"bob\"$" "$R/env.sh"'
check "no push or run.sh on this machine" '! grep -qE "^(push|run.sh)" "$T_CALLS/log"'
tokens_off

echo "== 10: review findings"
new_repo f
tokens_on
dep deploy.sh all --yes < <(printf "\n\n\n\n\n\nyes\n\nshamir\n\nocto\nbob\n\n\n\n\n\n$HOME/src/tpg-fleet\n")
check "setup: run.sh does not see GIT_ADMIN_PAT; push does not see BROADCOM_TOKEN" '[[ $RC -eq 0 ]] && grep -q "^run.sh-sees-admin= " "$T_CALLS/env" && grep -q "^push-sees-broadcom=$" "$T_CALLS/env"' "$(cat "$T_CALLS/env")"
check "terraform and ssh see none of the four tokens in the local mode" '! grep -qE "^(terraform|ssh)-sees " "$T_CALLS/env"' "$(grep -E "sees" "$T_CALLS/env")"
: > "$T_CALLS/log"
TF_FAIL=plan dep deploy.sh apply --non-interactive --yes < /dev/null
check "a failed plan fails apply, and nothing is applied" '[[ $RC -ne 0 ]] && ! grep -q "apply -input=false -auto-approve" "$T_CALLS/log"' "exit $RC: $(tail -3 "$T/out")"
TF_FAIL=apply dep deploy.sh apply --non-interactive --yes < /dev/null
check "a failed apply fails the subcommand" '[[ $RC -ne 0 ]] && ! grep -q "terraform apply finished" "$T/out"' "exit $RC"
RUNSH_RC=4 dep deploy.sh setup --non-interactive --yes < /dev/null
check "a failed run.sh fails setup" '[[ $RC -ne 0 ]] && ! grep -q "onboarding finished" "$T/out"' "exit $RC: $(tail -3 "$T/out")"
mkdir -p "$T_OUT" "$DEPLOY_JUMPBOX_STATE_DIR"; sha_of "$R/scripts/jumpbox/setup-jumpbox.sh" > "$DEPLOY_JUMPBOX_STATE_DIR/setup-jumpbox.sha256"
echo 198.51.100.7 > "$T_OUT/jumpbox_public_ip"; echo "PRIVATE-KEY" > "$T_OUT/jumpbox_ssh_private_key"
echo 'export INVENTORY_PREBUILT="true"' > "$T_OUT/jumpbox_env_override"; echo "backup: {keySource: az}" > "$T_OUT/jumpbox_inventory_yaml"
: > "$T_CALLS/log"
SSH_FAIL_TAR=1 dep deploy.sh copy --yes < /dev/null
check "a failed remote tar fails copy, and the key is removed" 'k="$(grep -o -- "-i [^ ]*" "$T_CALLS/log" | head -1 | cut -c4-)"; [[ $RC -ne 0 && -n "$k" && ! -e "$k" ]] && ! grep -q "^.*copied\." "$T/out"' "exit $RC, key $k"
# a renamed repository: env.sh follows, so push-fleet-repo.sh (which sources env.sh) uses it
sed -i.bak 's/^fleet_repo_name = .*/fleet_repo_name = "renamed"/' "$R/terraform/deploy.tfvars" && rm -f "$R/terraform/deploy.tfvars.bak"
: > "$T_CALLS/env"
dep deploy.sh all --from repo --yes < /dev/null
check "all --from repo after a rename: env.sh and push-fleet-repo.sh use the new URL" '[[ $RC -eq 0 ]] && grep -q "url=https://github.com/octo/renamed.git" "$T_CALLS/env" && grep -q "^export FLEET_REPO_URL=\"https://github.com/octo/renamed.git\"$" "$R/env.sh"' "$(grep push-env "$T_CALLS/env")"
printf 'github_url = "https://ghe.example"\n' >> "$R/terraform/deploy.tfvars"
dep deploy.sh apply --non-interactive --yes < /dev/null
check "a key of your own in deploy.tfvars is kept" '[[ $RC -eq 0 ]] && grep -q "^github_url = \"https://ghe.example\"$" "$R/terraform/deploy.tfvars" && [[ "$(grep -c "^subscription_id" "$R/terraform/deploy.tfvars")" -eq 1 ]]' "$(cat "$R/terraform/deploy.tfvars")"
dep deploy.sh repo --non-interactive --yes < /dev/null
check "validate.sh is off by default: the repo step says so, and asks for no validate tools" '[[ $RC -eq 0 ]] && grep -q "validate.sh: skipped (off by default" "$T/out"' "$(tail -3 "$T/out")"
echo 'export FLEET_VALIDATE="true"' >> "$R/env.sh"
dep deploy.sh repo --non-interactive --yes < /dev/null
check "env.sh true but fleet_repo_validate not true in tfvars: still skipped (no mismatch error)" '[[ $RC -eq 0 ]] && grep -q "validate.sh: skipped" "$T/out" && grep -q "validate=false" "$T_CALLS/env"' "$(tail -3 "$T/out")"
printf 'fleet_repo_validate = true\n' >> "$R/terraform/deploy.tfvars"
dep deploy.sh repo --non-interactive --yes < /dev/null
check "both true: validate.sh will run, and the validate tools are required (yamllint is a stub here)" '[[ $RC -eq 0 ]] && grep -q "validate.sh will run" "$T/out" && grep -q "validate=true" "$T_CALLS/env"' "$(tail -4 "$T/out")"
tokens_off

new_repo m
printf 'admin_allowed_cidrs = [\n  "203.0.113.10/32", # office\n  "198.51.100.0/24",\n]\n' >> "$R/terraform/terraform.tfvars"
dep deploy.sh apply --yes < <(printf '\n\n\n\n\n\nyes\n\nshamir\n\n')
check "a multi-line admin_allowed_cidrs is read as the default" '[[ $RC -eq 0 ]] && grep -q "^admin_allowed_cidrs = \[\"203.0.113.10/32\", \"198.51.100.0/24\"\]$" "$R/terraform/deploy.tfvars"' "$(grep admin "$R/terraform/deploy.tfvars")"
TF_VAR_admin_allowed_cidrs='["10.0.0.0/8", "300.1.1.1/32"]' dep deploy.sh apply --non-interactive --yes < /dev/null
check "a CIDR with an octet above 255 is refused" '[[ $RC -ne 0 ]] && grep -q "admin_allowed_cidrs: .* is not valid" "$T/out"' "$(tail -3 "$T/out")"
RC=0; env PATH="$T/bin:$PATH" bash -x "$R/deploy-scripts/deploy.sh" preflight > "$T/out" 2>&1 || RC=$?
check "bash -x is refused (the trace would print the tokens)" '[[ $RC -eq 2 ]] && grep -q "do not run this under bash -x" "$T/out"'

if PATH="/usr/bin:/bin" command -v terraform >/dev/null 2>&1; then
  ok "tofu only: SKIP (a real terraform is installed outside the stubs)"
else
  new_repo o
  mkdir -p "$T/bin-tofu"; cp "$T/bin/"* "$T/bin-tofu/"; mv "$T/bin-tofu/terraform" "$T/bin-tofu/tofu"
  tokens_on
  RC=0; env -u TF_BIN -u GITHUB_USER -u BROADCOM_USER -u MONITORING_OPTION -u FLEET_LOCAL_DIR PATH="$T/bin-tofu:/usr/bin:/bin" \
    DEPLOY_BASH_CANDIDATES="" DEPLOY_BASH="$T/bin-tofu/bash5" bash "$R/deploy-scripts/deploy.sh" all --yes \
    < <(printf "\n\n\n\n\n\nyes\n\nshamir\n\nocto\nbob\n\n\n\n\n\n$HOME/src/tpg-fleet\n") > "$T/out" 2>&1 || RC=$?
  check "tofu only: env.sh gets TF_BIN=tofu and run.sh uses it" '[[ $RC -eq 0 ]] && grep -q "^export TF_BIN=\"tofu\"$" "$R/env.sh" && grep -q "tf_bin=tofu" "$T_CALLS/env"' "exit $RC: $(tail -4 "$T/out")"
  tokens_off
fi

echo "== 11: absolute paths only"
new_repo p
tokens_on
Z="$T/p/tpg-fleet.zip"; echo notes > "$T/p/notes.txt"
ANS="octo\n\n\n\n"
ANS="${ANS}tpg-fleet.zip\n~/tpg-fleet.zip\n[${Z}]\n$T/p/notes.txt\n$T/p/missing.zip\n$T/p/../p/tpg-fleet.zip\n$T/p/[x].zip\n\n"
ANS="${ANS}src/tpg-fleet\n${HOME}/src/tpg-fleet/\n/nonexistent-parent-dir/tpg-fleet\n$R/fleet\n$T/p\n\n${HOME}/src/tpg-fleet\nyes\n"
dep deploy.sh repo < <(printf "$ANS")
check "FLEET_LOCAL_DIR has no default: Enter alone asks again" 'grep -q "a value is required" "$T/out"'
check "asking for FLEET_LOCAL_DIR does not trip set -u (no unbound variable)" '! grep -q "unbound variable" "$T/out"'
check "repo: every refused path asked again, then the defaults taken as typed" '[[ $RC -eq 0 ]] && grep -q "^fleet_zip_path = \"$Z\"$" "$R/terraform/deploy.tfvars" && grep -q "^export FLEET_LOCAL_DIR=\"$HOME/src/tpg-fleet\"$" "$R/env.sh"' "exit $RC: $(tail -4 "$T/out")"
for msg in "must be an absolute path starting with / (got 'tpg-fleet.zip')" "must be an absolute path starting with / (got '~/tpg-fleet.zip')" \
           "must be an absolute path starting with / (got '[$Z]')" "must be a .zip file (got '$T/p/notes.txt')" "$T/p/missing.zip is not an existing file" \
           "no '.' or '..' segments" "or ] (got '$T/p/[x].zip'" "must be an absolute path starting with / (got 'src/tpg-fleet')" "no trailing / (got '$HOME/src/tpg-fleet/')" \
           "the parent folder /nonexistent-parent-dir does not exist" "$R/fleet is inside tpg-aks-infra" "the zip $Z is inside $T/p"; do
  if grep -qF -- "$msg" "$T/out"; then ok "refused with: $msg"; else bad "refused with: $msg" "$(grep -E '^  ' "$T/out" | head -20)"; fi
done
check "nothing was prepended to a relative answer" '! grep -q "$R/tpg-fleet.zip\|$R/src/tpg-fleet\|$R/\[" "$R/env.sh" "$R/terraform/deploy.tfvars"'
sed -i.bak "s#^fleet_zip_path = .*#fleet_zip_path = \"tpg-fleet.zip\"#" "$R/terraform/deploy.tfvars" && rm -f "$R/terraform/deploy.tfvars.bak"
dep deploy.sh repo --non-interactive --yes < /dev/null
check "--non-interactive: a relative fleet_zip_path in deploy.tfvars stops, naming the file" '[[ $RC -ne 0 ]] && grep -qF "fleet_zip_path in $R/terraform/deploy.tfvars is not an absolute path ('"'"'tpg-fleet.zip'"'"')" "$T/out"' "$(tail -3 "$T/out")"
sed -i.bak "s#^fleet_zip_path = .*#fleet_zip_path = \"$T/p/\"#" "$R/terraform/deploy.tfvars" && rm -f "$R/terraform/deploy.tfvars.bak"
dep deploy.sh repo --non-interactive --yes < /dev/null
check "--non-interactive: an invalid absolute value stops, naming its file" '[[ $RC -ne 0 ]] && grep -qF "fleet_zip_path: '"'"'$T/p/'"'"' is not valid (from $R/terraform/deploy.tfvars)" "$T/out"' "$(tail -3 "$T/out")"
sed -i.bak "s#^fleet_zip_path = .*#fleet_zip_path = \"$Z\"#" "$R/terraform/deploy.tfvars" && rm -f "$R/terraform/deploy.tfvars.bak"
sed -i.bak 's#^export FLEET_LOCAL_DIR=.*#export FLEET_LOCAL_DIR="rel/tpg-fleet"#' "$R/env.sh" && rm -f "$R/env.sh.bak"
dep deploy.sh repo --non-interactive --yes < /dev/null
check "--non-interactive: a relative FLEET_LOCAL_DIR in env.sh stops, naming env.sh" '[[ $RC -ne 0 ]] && grep -qF "FLEET_LOCAL_DIR in $R/env.sh is not an absolute path ('"'"'rel/tpg-fleet'"'"')" "$T/out"' "$(tail -3 "$T/out")"
tokens_off

echo "== 13: network mode"
new_repo nm
dep deploy.sh apply < <(printf '\n\n\n\n\n\nno\nbyo\n\nshamir\n\nyes\n')
check "role answer no: byo is refused with the reason, then managed" '[[ $RC -eq 0 ]] && grep -q "byo needs the Network Contributor role assignments" "$T/out" && grep -q "^network_mode = \"managed\"$" "$R/terraform/deploy.tfvars"' "exit $RC: $(tail -4 "$T/out")"
dep deploy.sh apply < <(printf '\n\n\n\n\n\nyes\nbyo\npublic\nshamir\n\nyes\n')
check "role answer yes: byo accepted, then the API access question" '[[ $RC -eq 0 ]] && grep -q "^network_mode = \"byo\"$" "$R/terraform/deploy.tfvars" && grep -q "^api_access_mode = \"public\"$" "$R/terraform/deploy.tfvars"' "exit $RC: $(tail -4 "$T/out")"
sed -i.bak 's/^create_role_assignments = .*/create_role_assignments = false/' "$R/terraform/deploy.tfvars" && rm -f "$R/terraform/deploy.tfvars.bak"
dep deploy.sh apply --non-interactive --yes < /dev/null
check "--non-interactive: byo with create_role_assignments = false stops, naming deploy.tfvars" '[[ $RC -ne 0 ]] && grep -q "byo needs the Network Contributor role assignments" "$T/out" && grep -qF "network_mode: '"'"'byo'"'"' is not valid (from $R/terraform/deploy.tfvars)" "$T/out"' "$(tail -3 "$T/out")"

echo "== 15: --run-step-from, validate defaults"
new_repo rf
tokens_on
mkdir -p "$T_OUT"; echo aks-tpg-hub > "$T_OUT/hub_cluster_name"; mkdir -p "$HOME/src/tpg-fleet/.git"
printf 'export FLEET_LOCAL_DIR="%s"\nexport GITHUB_USER="octo"\nexport BROADCOM_USER="bob"\n' "$HOME/src/tpg-fleet" > "$R/env.sh"
printf 'fleet_repo_owner = "octo"\nfleet_zip_path = "%s"\n' "$T/rf/tpg-fleet.zip" > "$R/terraform/deploy.tfvars"
dep deploy.sh setup --non-interactive --yes --run-step-from vault < /dev/null
check "--run-step-from vault: run.sh gets --from vault" '[[ $RC -eq 0 ]] && grep -q "^run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys --from vault$" "$T_CALLS/log"' "exit $RC: $(tail -3 "$T/out")"
dep deploy.sh setup --non-interactive --run-step-from=bogus < /dev/null
check "an unknown --run-step-from step is refused with the list" '[[ $RC -eq 2 ]] && grep -q "unknown step for --run-step-from: bogus" "$T/out"'
: > "$T_CALLS/log"
RUNSH_RC=7 RUNSH_FAIL_STEP=hub-secrets dep deploy.sh setup --non-interactive --yes < /dev/null
check "a failed run.sh prints the line that resumes it at the failed step, and exits with its status" '[[ $RC -eq 7 ]] && grep -q "deploy.sh setup --run-step-from hub-secrets" "$T/out" && grep -q "all --from setup --run-step-from hub-secrets" "$T/out"' "exit $RC: $(tail -5 "$T/out")"
dep deploy.sh repo --non-interactive --yes --run-step-from vault < /dev/null
check "--run-step-from is ignored with a note by repo" '[[ $RC -eq 0 ]] && grep -q "only applies to setup and all" "$T/out"' "exit $RC: $(tail -3 "$T/out")"
dep terraform-enabled-deploy.sh apply --run-step-from vault < /dev/null
check "terraform-enabled-deploy.sh has no --run-step-from" '[[ $RC -eq 2 ]] && grep -q "unknown option: --run-step-from" "$T/out"'
tokens_off
new_repo tfh
tokens_on
printf 'export GITHUB_USER="octo"\nexport BROADCOM_USER="bob"\n' > "$R/env.sh"
printf 'fleet_repo_owner = "octo"\n' > "$R/terraform/deploy.tfvars"
TF_FAIL=apply TF_VAR_create_role_assignments=true TF_VAR_vault_unseal_mode=shamir dep terraform-enabled-deploy.sh apply --non-interactive --yes < /dev/null
check "terraform-enabled-deploy.sh: a failed apply prints how to resume run.sh by hand on the jumpbox" '[[ $RC -ne 0 ]] && grep -q "run-fleet-setup.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys --from <step>" "$T/out"' "$(tail -6 "$T/out")"
tokens_off
check "validate and force default to false in Terraform" 'awk "/^variable \"fleet_repo_validate\"/,/^}/" "$ROOT/terraform/variables.tf" | grep -q "default     = false" && awk "/^variable \"fleet_repo_force\"/,/^}/" "$ROOT/terraform/variables.tf" | grep -q "default     = false"'

echo "== 14: re-review fixes"
new_repo rv
tokens_on
mkdir -p "$T_OUT"
echo '["az role assignment create --role \"Contributor\" --scope /rg  # id-jumpbox/resource-group"]' > "$T_OUT/role_assignments_to_create.json"
dep deploy.sh all < <(printf "\n\n\n\n\n\nno\n\nshamir\n\nocto\nbob\n\n\n\n\n\n$HOME/src/tpg-fleet\nyes\nyes\n")
check "only jumpbox role commands: printed, no pause, repo and setup run" '[[ $RC -eq 0 ]] && grep -q "id-jumpbox/resource-group" "$T/out" && ! grep -q "PAUSED" "$T/out" && grep -q "^run.sh" "$T_CALLS/log"' "exit $RC: $(tail -4 "$T/out")"
sed -i.bak 's/^network_mode = .*/network_mode = "byo"/' "$R/terraform/deploy.tfvars" && rm -f "$R/terraform/deploy.tfvars.bak"
: > "$T_CALLS/log"
dep deploy.sh all --from apply --yes < /dev/null
check "all --from apply with a saved byo and no role assignments stops before terraform, naming deploy.tfvars" '[[ $RC -ne 0 ]] && grep -qF "$R/terraform/deploy.tfvars has network_mode = \"byo\" with create_role_assignments = false" "$T/out" && ! grep -q "plan -input" "$T_CALLS/log"' "$(tail -3 "$T/out")"
dep deploy.sh apply < <(printf '\n\n\n\n\n\nno\n\nshamir\n\nyes\n')
check "a saved byo with the role answer no: managed is the offered default" '[[ $RC -eq 0 ]] && grep -q "^network_mode = \"managed\"$" "$R/terraform/deploy.tfvars" && ! grep -q "byo needs" "$T/out"' "exit $RC: $(tail -3 "$T/out")"
tokens_off

echo "== 12: role assignments, prompt look"
new_repo r
tokens_on
mkdir -p "$T_OUT"
echo '["az role assignment create --role \"Network Contributor\" --scope /subnets/x  # id-aks-tpg-hub/subnet"]' > "$T_OUT/role_assignments_to_create.json"
dep deploy.sh all < <(printf "\n\n\n\n\n\nno\n\nshamir\n\nocto\nbob\n\n\n\n\n\n$HOME/src/tpg-fleet\nyes\nyes\n")
check "create_role_assignments = no: all pauses after apply with the az commands and the resume line" '[[ $RC -eq 75 ]] && grep -q "PAUSED" "$T/out" && grep -q "after step apply" "$T/out" && grep -q "deploy.sh all --from repo" "$T/out" && grep -q "az role assignment create --role \"Network Contributor\"" "$T/out" && ! grep -q "^push " "$T_CALLS/log"' "exit $RC: $(tail -6 "$T/out")"
check "deploy.tfvars: create_role_assignments = false" 'grep -q "^create_role_assignments = false$" "$R/terraform/deploy.tfvars"'
dep deploy.sh all --from repo --yes < /dev/null
check "all --from repo goes on after the owner ran them" '[[ $RC -eq 0 ]] && grep -q "^push " "$T_CALLS/log" && grep -q "^run.sh" "$T_CALLS/log"' "exit $RC: $(tail -4 "$T/out")"
dep deploy.sh apply --non-interactive --yes < /dev/null
check "deploy.sh apply alone with no role assignments: commands printed, exit 0" '[[ $RC -eq 0 ]] && grep -q "Terraform created no role assignments" "$T/out"' "exit $RC"
echo '[]' > "$T_OUT/role_assignments_to_create.json"
: > "$T_CALLS/log"
dep deploy.sh all --non-interactive --yes < /dev/null
check "nothing to assign (an empty role_assignments_to_create): all does not pause" '[[ $RC -eq 0 ]] && ! grep -q "PAUSED" "$T/out" && grep -q "^run.sh" "$T_CALLS/log"' "exit $RC: $(tail -4 "$T/out")"
new_repo nf
tokens_on
printf 'fleet_repo_owner = "octo"\nfleet_zip_path = "%s"\n' "$T/nf/tpg-fleet.zip" > "$R/terraform/deploy.tfvars"
# GITHUB_USER exported (dep unsets it), no env.sh: FLEET_LOCAL_DIR must not come from env.sh.example
RC=0; env -u FLEET_LOCAL_DIR -u ENV_FILE GITHUB_USER=octo PATH="$T/bin:$PATH" DEPLOY_BASH_CANDIDATES="" DEPLOY_BASH="$T/bin/bash5" \
  bash "$R/deploy-scripts/deploy.sh" repo --non-interactive --yes < /dev/null > "$T/out" 2>&1 || RC=$?
check "--non-interactive without env.sh: FLEET_LOCAL_DIR is not taken from env.sh.example" '[[ $RC -ne 0 ]] && grep -q "FLEET_LOCAL_DIR is not set in" "$T/out" && ! grep -q "^push " "$T_CALLS/log"' "$(tail -3 "$T/out")"
new_repo t2
tokens_on
TF_VAR_create_role_assignments=false TF_VAR_vault_unseal_mode=shamir dep terraform-enabled-deploy.sh apply --non-interactive --yes < /dev/null
check "terraform-enabled-deploy.sh refuses create_role_assignments = no, saying why" '[[ $RC -ne 0 ]] && grep -q "this mode needs yes" "$T/out" && ! grep -q "apply -input=false" "$T_CALLS/log"' "$(tail -4 "$T/out")"
dep terraform-enabled-deploy.sh apply < <(printf '\n\n\n\n\n\nno\nyes\n\nshamir\n\n\nocto\nbob\n\n\n\n\n\nyes\nyes\n')
check "terraform-enabled-deploy.sh asks again after no; remote-exec setup method" '[[ $RC -eq 0 ]] && grep -q "this mode needs yes" "$T/out" && grep -q "^jumpbox_setup_method = \"remote-exec\"$" "$R/terraform/deploy.tfvars" && grep -q "^create_role_assignments = true$" "$R/terraform/deploy.tfvars"' "exit $RC: $(tail -4 "$T/out")"
tokens_off
check "the prompt shows its default as 'default = <value>'" 'grep -qF "\"  default = \${def}: \"" "$ROOT/deploy-scripts/lib/deploy-common.sh" && ! grep -q "Enter = " "$ROOT/deploy-scripts/lib/deploy-common.sh"'

echo "== 9: no token outside the environment"
leak=""
for d in "$T"/*/; do d="${d%/}"; [[ -d "$d/tpg-aks-infra" ]] || continue
  for tok in "$ADMIN_TOK" "$BC_TOK" "$READ_TOK" "$PUSH_TOK"; do
    for f in "$d/tpg-aks-infra/terraform/deploy.tfvars" "$d/tpg-aks-infra/env.sh" "$d"/tpg-aks-infra/.work/deploy-*.log "$d/calls/log"; do
      [[ -f "$f" ]] && grep -q "$tok" "$f" && leak="${leak} ${f}:${tok}"
    done
  done
done
check "no token in deploy.tfvars, env.sh, the deploy logs or a command line" '[[ -z "$leak" ]]' "$leak"

echo
echo "deploy-scripts: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
