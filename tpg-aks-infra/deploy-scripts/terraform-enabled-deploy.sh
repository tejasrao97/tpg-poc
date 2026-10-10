#!/usr/bin/env bash
# Terraform-enabled deployment (Round 17): one terraform apply creates the
# clusters and the jumpbox, and the jumpbox provisioners of
# terraform/jumpbox-provision.tf publish the fleet repository
# (create_fleet_repo) and run scripts/run.sh --hub install --targets terraform
# --expose-ui --save-vault-recovery-keys on the jumpbox (run_fleet_setup).
#
#   terraform-enabled-deploy.sh preflight|apply|all [--from STEP] [--yes] [--non-interactive]
#
#   preflight  the tools of this machine (terraform or tofu, az, jq, curl), az login
#   apply      every value and the four tokens, terraform/deploy.tfvars with
#              enable_jumpbox, create_fleet_repo and run_fleet_setup true, env.sh,
#              terraform plan, one confirmation, terraform apply; then the outputs
#   all        preflight, then apply; --from apply skips the preflight
#
# The machine running this must be inside admin_allowed_cidrs (Terraform reaches
# the jumpbox over SSH). Tokens: GIT_ADMIN_PAT, BROADCOM_TOKEN, GIT_READ_PAT and
# GIT_PUSH_PAT from the environment (or TF_VAR_git_admin_pat, ...) or a hidden
# prompt; exported as TF_VAR_* for this terraform run only, never written anywhere.
#   --yes              confirm the plan and the env.sh change
#   --non-interactive  no prompts: values from the files and the environment
STEPS="preflight apply"
source "$(dirname "$0")/lib/deploy-common.sh"
dp_reexec_bash4 "$@"

usage() {
  sed -n '2,/^STEPS=/{/^STEPS=/d;s/^# \{0,1\}//;p;}' "$0"
}

# tf_token VAR TF_NAME "Label": VAR, else TF_VAR_<TF_NAME>, else a hidden prompt;
# exported as TF_VAR_<TF_NAME> for terraform (the only command this script runs
# with them), VAR itself stays unexported
tf_token() {
  local var="$1" tfn="TF_VAR_$2"
  [[ -n "${!var:-}" || -z "${!tfn:-}" ]] || export "${var}=${!tfn}"
  token "$var" "$3"
  export "${tfn}=${!var}"
}

# The role-assignment question: this mode needs yes. In the same apply that
# creates them, the jumpbox identity uses its Cluster Admin role assignments to
# run run.sh, so they cannot be created later by someone else.
v_role_tf() {
  local v
  v="$(v_bool "$1")" || return 1
  [[ "$v" == true ]] || { _bad "this mode needs yes: the jumpbox runs run.sh inside the same terraform apply, with the Cluster Admin role assignments Terraform creates (run_fleet_setup requires create_role_assignments = true). Without Owner or User Access Administrator use deploy-scripts/deploy.sh"; return 1; }
  printf '%s' "$v"
}
DP_ROLE_CHECK=v_role_tf

step_preflight() {
  dp_check_tools apply jumpbox-access
  az_logged_in
}

step_apply() {
  dp_check_tools apply
  az_logged_in
  ask_infra
  ask_jumpbox
  ask_env
  ask_repo
  DV_enable_jumpbox=true
  DV_jumpbox_provision=true
  DV_jumpbox_setup_method=remote-exec   # the provisioners need SSH; their logs are in the apply output
  DV_create_fleet_repo=true
  DV_run_fleet_setup=true
  echo
  echo "Summary (tokens are not shown):"
  local k v
  for k in $DP_TF_KEYS GITHUB_USER BROADCOM_USER MONITORING_OPTION; do
    v="$(_dv "$k")"; [[ -z "$v" ]] || printf '  %-24s %s\n' "$k" "$v"
  done
  api_line
  echo "  on the jumpbox:          push-fleet-repo.sh, then run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys"
  echo
  tf_token GIT_ADMIN_PAT git_admin_pat "GitHub token that creates the repository and pushes (GIT_ADMIN_PAT)"
  tf_token BROADCOM_TOKEN broadcom_token "Broadcom registry token (BROADCOM_TOKEN)"
  tf_token GIT_READ_PAT git_read_pat "GitHub read-only PAT (GIT_READ_PAT)"
  tf_token GIT_PUSH_PAT git_push_pat "GitHub read/write PAT (GIT_PUSH_PAT)"
  # env.sh goes to the jumpbox (run_fleet_setup requires it); env.jumpbox.sh
  # sets the repository and path values there. env.sh first: refused, it
  # leaves deploy.tfvars as it was
  dp_update_env "GITHUB_USER=${DV_GITHUB_USER}" "BROADCOM_USER=${DV_BROADCOM_USER}" "MONITORING_OPTION=${DV_MONITORING_OPTION}"
  dp_write_tfvars
  local rc=0
  set +e
  ( set -e; tf_plan_apply )
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    cat >&2 <<EOF

terraform apply failed (exit ${rc}). If it failed inside the jumpbox_run step (run.sh on the jumpbox),
the log above shows the failed run.sh step. Resume that run by hand, without terraform:
  ssh -i ~/.ssh/tpg-jumpbox ${DV_jumpbox_admin_username}@<jumpbox ip>
  export BROADCOM_TOKEN=... GIT_READ_PAT=... GIT_PUSH_PAT=...
  ~/scripts/jumpbox/run-fleet-setup.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys --from <step>
  (steps: inventory preflight kubeconfigs hub vault service-accounts register hub-secrets addons bootstrap verify;
   the log is ~/.work/fleet-setup/run.log)
Afterwards run this script's apply again, or terraform apply: the fleet steps are idempotent.
EOF
    exit "$rc"
  fi
  local ip
  ip="$(tf_out jumpbox_public_ip)"
  echo
  ok "the jumpbox pushed $(tf_out fleet_repo_url) and ran scripts/run.sh"
  cat <<EOF
Next:
  ${TF_BIN} -chdir=${TF_DIR} output -raw jumpbox_ssh_private_key > ~/.ssh/tpg-jumpbox && chmod 600 ~/.ssh/tpg-jumpbox
  ssh -i ~/.ssh/tpg-jumpbox ${DV_jumpbox_admin_username}@${ip} 'cat $(tf_out jumpbox_vault_keys_file)'   # Vault keys: into a password manager
  ssh -i ~/.ssh/tpg-jumpbox ${DV_jumpbox_admin_username}@${ip} 'shred -u $(tf_out jumpbox_vault_keys_file)'
  ssh -i ~/.ssh/tpg-jumpbox ${DV_jumpbox_admin_username}@${ip}   # then: export KUBECONFIG=~/.work/kubeconfig
EOF
}

main() {
  case "$SUBCOMMAND" in
    preflight) step_preflight ;;
    apply) step_apply ;;
    all)
      # nothing to resume between the two steps but the preflight: values are asked in apply
      if [[ -n "$FROM" ]]; then run_steps "$STEPS" "$FROM"; else run_steps "$STEPS"; fi
      ok "terraform-enabled-deploy.sh all finished" ;;
  esac
}

dp_parse_args "$STEPS all" "$@"
dp_run_logged main
