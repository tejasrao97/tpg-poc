#!/usr/bin/env bash
# Local deployment (Round 17): Terraform, the fleet repository and the onboarding
# run on this machine, the one that holds tpg-aks-infra.
#
#   deploy.sh preflight|apply|repo|setup|copy|all [--from STEP] [--yes] [--non-interactive]
#
#   preflight  the tools and versions of every step, az login
#   apply      terraform plan, one confirmation, terraform apply with
#              terraform/deploy.tfvars; create_fleet_repo and run_fleet_setup
#              false, a jumpbox only if you choose one (jumpbox_setup_method
#              cloud-init: its tools installed at first boot). With
#              create_role_assignments = false it prints the az commands for an
#              owner; all then pauses (exit 75) until all --from repo
#   repo       scripts/jumpbox/push-fleet-repo.sh <zip> here: unzip to
#              FLEET_LOCAL_DIR, create the GitHub repository, set-repo-url.sh,
#              validate.sh, push
#   setup      scripts/run.sh --hub install --targets terraform --expose-ui
#              --save-vault-recovery-keys here (the Vault keys go to
#              VAULT_RECOVERY_KEYS_FILE on this machine)
#   copy       with a jumpbox: wait for its first boot (cloud-init), scripts/ to
#              ~/scripts (a changed setup-jumpbox.sh runs again), env.sh,
#              FLEET_LOCAL_DIR (with .git) to ~/tpg-fleet, .work (kubeconfig
#              included) to ~/.work, and env.jumpbox.sh and the jumpbox
#              inventory from the Terraform outputs
#   all        every value asked once, then the five steps in order (copy only
#              with a jumpbox); --from STEP resumes at STEP with the saved values
#
# Values: asked with defaults from the environment, terraform/deploy.tfvars,
# terraform/terraform.tfvars and env.sh; saved to terraform/deploy.tfvars and
# env.sh (after a diff and a yes). Tokens (GIT_ADMIN_PAT for repo; BROADCOM_TOKEN,
# GIT_READ_PAT, GIT_PUSH_PAT for setup) come from the environment or a hidden
# prompt and are never written anywhere.
#   --run-step-from S  setup and all: start scripts/run.sh at its step S
#                      (run.sh --from S) to resume after a failed run.sh; S is one
#                      of inventory preflight kubeconfigs hub vault service-accounts
#                      register hub-secrets addons bootstrap verify. When run.sh
#                      fails, deploy.sh prints the line that resumes it.
#   --yes              confirm the plan, the env.sh change and the jumpbox copy
#   --non-interactive  no prompts: values from the files and the environment
STEPS="preflight apply repo setup copy"
# the steps of scripts/run.sh, for --run-step-from
RUN_STEPS="inventory preflight kubeconfigs hub vault service-accounts register hub-secrets addons bootstrap verify"
ALLOW_RUN_STEP_FROM=1
source "$(dirname "$0")/lib/deploy-common.sh"
dp_reexec_bash4 "$@"

usage() {
  sed -n '2,/^STEPS=/{/^STEPS=/d;s/^# \{0,1\}//;p;}' "$0"
}

# ---------------------------------------------------------------- values
want_jumpbox() { [[ "$(_dv enable_jumpbox)" == true || ( -z "$(_dv enable_jumpbox)" && "$(tfv_get enable_jumpbox)" == true ) ]]; }

values_apply() {
  ask_infra
  ask enable_jumpbox "Create a jumpbox VM as well (yes/no)" "$( [[ "$(default_for enable_jumpbox)" == true ]] && echo yes || echo no)" v_bool
  if [[ "$DV_enable_jumpbox" == true ]]; then ask_jumpbox; fi
  DV_jumpbox_provision=true
  # local mode: the jumpbox installs its tools at first boot; copy adds the rest
  DV_jumpbox_setup_method=cloud-init
  DV_create_fleet_repo=false
  DV_run_fleet_setup=false
}

values_repo() {
  [[ -n "${DV_GITHUB_USER:-}" ]] || ask GITHUB_USER "GitHub user (env.sh GITHUB_USER)" "$(default_for GITHUB_USER GITHUB_USER)" v_plain
  ask_repo
  ask_fleet_dir "Local folder for the fleet repository (env.sh FLEET_LOCAL_DIR; an existing one is moved to <folder>.prev-<UTC>)"
}

values_setup() {
  ask_env
  [[ -n "${DV_fleet_repo_owner:-}" ]] || ask_repo_saved
  ask_fleet_dir "Local folder of the fleet repository (env.sh FLEET_LOCAL_DIR)"
}

# the repository values of an earlier run, without prompting
ask_repo_saved() {
  local keep="$PROMPTS_OFF"
  PROMPTS_OFF=1
  DV_fleet_repo_owner="$(tfv_get fleet_repo_owner)"
  if [[ -n "$DV_fleet_repo_owner" ]]; then
    DV_fleet_repo_name="$(default_for fleet_repo_name "" poc-tpg-fleet-v15)"
    DV_fleet_repo_branch="$(default_for fleet_repo_branch "" main)"
    PROMPTS_OFF="$keep"
    return
  fi
  PROMPTS_OFF="$keep"
  ask fleet_repo_owner "GitHub owner of the fleet repository (user or organization)" "$(default_for fleet_repo_owner "" "${DV_GITHUB_USER:-}")" v_owner
  ask fleet_repo_name "Fleet repository name" "$(default_for fleet_repo_name "" poc-tpg-fleet-v15)" v_repo
  ask fleet_repo_branch "Fleet repository branch" "$(default_for fleet_repo_branch "" main)" v_branch
}

# env.sh lines that follow from the values
env_pairs() {
  github_urls
  ENV_PAIRS=""
  [[ -z "${DV_GITHUB_USER:-}" ]] || ENV_PAIRS="${ENV_PAIRS} GITHUB_USER=${DV_GITHUB_USER}"
  [[ -z "${DV_BROADCOM_USER:-}" ]] || ENV_PAIRS="${ENV_PAIRS} BROADCOM_USER=${DV_BROADCOM_USER}"
  if [[ -n "${DV_MONITORING_OPTION:-}" ]]; then
    # run.sh reads TF_BIN from env.sh: the binary these scripts found (tofu when only tofu is installed)
    ENV_PAIRS="${ENV_PAIRS} MONITORING_OPTION=${DV_MONITORING_OPTION} TF_BIN=$(dp_tf_bin)"
  fi
  [[ -z "${DV_FLEET_LOCAL_DIR:-}" ]] || ENV_PAIRS="${ENV_PAIRS} FLEET_LOCAL_DIR=${DV_FLEET_LOCAL_DIR}"
  if [[ -n "${DV_fleet_repo_owner:-}" ]]; then
    ENV_PAIRS="${ENV_PAIRS} FLEET_REPO_URL=${GITHUB_WEB}/${DV_fleet_repo_owner}/${DV_fleet_repo_name}.git"
    ENV_PAIRS="${ENV_PAIRS} FLEET_REPO_REVISION=${DV_fleet_repo_branch} GITHUB_API_URL=${GITHUB_API}"
  fi
  [[ -n "$ENV_PAIRS" ]] || return 0
  # shellcheck disable=SC2086  # the pairs hold no blank (v_plain)
  dp_update_env $ENV_PAIRS
}

save_values() {
  env_pairs
  dp_write_tfvars
}

summary() {
  echo
  echo "Summary (tokens are not shown):"
  local k v
  # FLEET_LOCAL_DIR is not repeated here (Round 19): it was just typed
  for k in $DP_TF_KEYS GITHUB_USER BROADCOM_USER MONITORING_OPTION; do
    v="$(_dv "$k")"; [[ -z "$v" ]] || printf '  %-24s %s\n' "$k" "$v"
  done
  api_line
  [[ " $1 " != *" setup "* ]] || echo "  setup runs:              scripts/run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys"
  [[ " $1 " != *" copy "* ]] || ! want_jumpbox || echo "  copy:                    scripts/, env.sh, the fleet repository and .work (kubeconfig included) to the jumpbox"
  echo
}

# ---------------------------------------------------------------- steps
step_preflight() {
  local s="apply repo setup"
  want_jumpbox && s="$s copy"
  dp_check_tools $s
  az_logged_in
  no_jumpbox_env
}

step_apply() {
  dp_check_tools apply
  local nm ra0
  nm="${DV_network_mode:-$(tfv_get network_mode)}"; ra0="${DV_create_role_assignments:-$(tfv_get create_role_assignments)}"
  [[ "$nm" != byo || "$ra0" == true ]] \
    || die "${DEPLOY_TFVARS} has network_mode = \"byo\" with create_role_assignments = false, which Terraform refuses: run deploy-scripts/deploy.sh apply and answer the role and network questions again"
  az_logged_in
  tf_plan_apply
  local ra="${DV_create_role_assignments:-$(tfv_get create_role_assignments)}" cmds
  [[ "$ra" != true ]] || return 0
  cmds="$(tfb output -json role_assignments_to_create | jq -r '.[] | "  " + .')"
  # nothing to assign (managed network, no Azure Monitor, no jumpbox): no pause
  [[ -n "$cmds" ]] || return 0
  echo
  warn "create_role_assignments = false: Terraform created no role assignments. An account with Owner or User Access Administrator runs these:"
  printf '%s\n' "$cmds"
  # run.sh here needs only the Network Contributor ones (byo, which needs true
  # anyway); the jumpbox ones matter for run.sh on the jumpbox, Grafana's for the
  # dashboard import (a warning), so the run goes on for them
  if grep -q "Network Contributor" <<<"$cmds"; then
    if [[ "${DP_IN_ALL:-0}" == 1 ]]; then
      echo "run.sh needs the Network Contributor ones; deploy.sh stops here. If an owner already ran them, resume right away." >&2
      exit "$DP_PAUSE"
    fi
  else
    echo "  (repo and setup on this machine do not need them; run them before using the jumpbox identity or the Azure Managed Grafana import)"
  fi
}

step_repo() {
  dp_check_tools repo
  no_jumpbox_env
  github_urls
  local owner name branch dir zip validate force url v
  owner="${DV_fleet_repo_owner:-$(tfv_get fleet_repo_owner)}"
  name="${DV_fleet_repo_name:-$(default_for fleet_repo_name "" poc-tpg-fleet-v15)}"
  branch="${DV_fleet_repo_branch:-$(default_for fleet_repo_branch "" main)}"
  zip="${DV_fleet_zip_path:-$(tfv_get fleet_zip_path)}"
  dir="${DV_FLEET_LOCAL_DIR:-${FLEET_LOCAL_DIR:-$(env_file_get FLEET_LOCAL_DIR)}}"
  validate="$(tfv_get fleet_repo_validate)"; validate="${validate:-false}"
  force="$(tfv_get fleet_repo_force)"; force="${force:-false}"
  [[ -n "$owner" && -n "$zip" && -n "$dir" ]] || die "the repository values are missing: run deploy.sh repo (or all) without --non-interactive once"
  url="${GITHUB_WEB}/${owner}/${name}.git"
  # push-fleet-repo.sh sources env.sh (scripts/lib/common.sh), which would win
  # over what is passed here: env.sh must hold the same values
  dp_update_env "FLEET_REPO_URL=${url}" "FLEET_REPO_REVISION=${branch}" "FLEET_LOCAL_DIR=${dir}" "GITHUB_API_URL=${GITHUB_API}"
  if dp_flag_on fleet_repo_validate FLEET_VALIDATE fleet_repo_validate; then
    log "scripts/validate.sh will run (fleet_repo_validate and env.sh are true)"
  else
    log "scripts/validate.sh: skipped (off by default; set fleet_repo_validate = true and FLEET_VALIDATE=true or fleet_repo_validate=true in env.sh to run it)"
  fi
  token GIT_ADMIN_PAT "GitHub token that creates the repository and pushes (GIT_ADMIN_PAT)"
  log "push-fleet-repo.sh ${zip} -> ${url} (${branch})"
  GIT_ADMIN_PAT="$GIT_ADMIN_PAT" FLEET_REPO_OWNER="$owner" FLEET_REPO_NAME="$name" FLEET_REPO_URL="$url" \
  FLEET_REPO_REVISION="$branch" GITHUB_API_URL="$GITHUB_API" FLEET_LOCAL_DIR="$dir" \
  FLEET_VALIDATE_TFVARS="$validate" FLEET_REPO_FORCE_TFVARS="$force" \
    bash "${INFRA_DIR}/scripts/jumpbox/push-fleet-repo.sh" "$zip"
}

no_jumpbox_env() {
  [[ ! -f "${INFRA_DIR}/env.jumpbox.sh" ]] \
    || die "${INFRA_DIR}/env.jumpbox.sh exists here: it belongs on the jumpbox (scripts/lib/common.sh would read it and use the jumpbox paths); move it away"
}

step_setup() {
  dp_check_tools setup
  TF_BIN="$(dp_tf_bin)"
  [[ -n "$(tf_out hub_cluster_name)" ]] || die "no Terraform outputs in ${TF_DIR}: run deploy.sh apply first"
  local dir="${DV_FLEET_LOCAL_DIR:-${FLEET_LOCAL_DIR:-$(env_file_get FLEET_LOCAL_DIR)}}"
  [[ -d "${dir}/.git" ]] || die "no fleet repository at ${dir:-FLEET_LOCAL_DIR}: run deploy.sh repo first"
  no_jumpbox_env
  az_logged_in
  token BROADCOM_TOKEN "Broadcom registry token (BROADCOM_TOKEN)"
  token GIT_READ_PAT "GitHub read-only PAT (GIT_READ_PAT)"
  token GIT_PUSH_PAT "GitHub read/write PAT (GIT_PUSH_PAT)"
  local from_args=() rc=0 failed
  [[ -z "$RUN_FROM" ]] || from_args=(--from "$RUN_FROM")
  log "scripts/run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys${RUN_FROM:+ --from ${RUN_FROM}}"
  set +e
  BROADCOM_TOKEN="$BROADCOM_TOKEN" GIT_READ_PAT="$GIT_READ_PAT" GIT_PUSH_PAT="$GIT_PUSH_PAT" \
    "${INFRA_DIR}/scripts/run.sh" --hub install --targets terraform --expose-ui --save-vault-recovery-keys ${from_args[@]+"${from_args[@]}"}
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    # run.sh prints "== <step>  scripts/..." before every step: the last one failed
    failed="$(sed 's/\x1b\[[0-9;]*m//g' "${DEPLOY_LOG:-/dev/null}" 2>/dev/null | sed -n 's/^== \([a-z-]*\) .*scripts\/.*/\1/p' | tail -n 1)"
    echo >&2
    echo "scripts/run.sh failed (exit ${rc})${failed:+ in step ${failed}}. After fixing the cause, resume it with:" >&2
    echo "  $0 setup --run-step-from ${failed:-<step>}" >&2
    echo "  (or: $0 all --from setup --run-step-from ${failed:-<step>})" >&2
    exit "$rc"
  fi
  local keys
  keys="$(env_get VAULT_RECOVERY_KEYS_FILE)"
  ok "onboarding finished. Vault keys (first run only): ${keys:-~/.tpg/vault-keys.txt} on this machine: move them into a password manager, then delete the file"
}

step_copy() {
  dp_check_tools copy
  TF_BIN="$(dp_tf_bin)"
  local ip user key dir rc
  ip="$(tf_out jumpbox_public_ip)"
  [[ -n "$ip" ]] || { warn "no jumpbox in the Terraform outputs (enable_jumpbox = false): nothing to copy"; return 0; }
  user="$(tfv_get jumpbox_admin_username)"; user="${user:-tpgadmin}"
  dir="${DV_FLEET_LOCAL_DIR:-${FLEET_LOCAL_DIR:-$(env_file_get FLEET_LOCAL_DIR)}}"
  [[ -d "${dir}/.git" ]] || die "no fleet repository at ${dir:-FLEET_LOCAL_DIR}: run deploy.sh repo first"
  [[ -s "${WORK_DIR}/kubeconfig" ]] || die "${WORK_DIR}/kubeconfig not found: run deploy.sh setup first"
  [[ -n "$(tf_out jumpbox_env_override)" && -n "$(tf_out jumpbox_inventory_yaml)" ]] \
    || die "the Terraform outputs jumpbox_env_override and jumpbox_inventory_yaml are missing: run deploy.sh apply with this version"
  echo "The copy puts scripts/, env.sh, the fleet repository and .work, kubeconfig with the cluster-admin credentials included, on ${user}@${ip}."
  dp_confirm "Copy to the jumpbox?" || die "nothing copied"
  key="$(tfv_get jumpbox_ssh_private_key_path)"
  if [[ -n "$key" ]]; then
    # as Terraform reads it: ~ expanded, a relative path from terraform/
    key="${key/#\~/$HOME}"
    [[ "$key" == /* ]] || key="${TF_DIR}/${key}"
    COPY_KEY_DIR=""
    copy_to_jumpbox "$ip" "$user" "$key" "$dir"
    return
  fi
  # the generated key, in a private temporary directory that is removed on
  # every path (the subshell keeps set -e and still returns here)
  COPY_KEY_DIR="$(mktemp -d)"
  trap 'rm -rf "${COPY_KEY_DIR:-/nonexistent-dir}"' EXIT INT TERM
  ( umask 077; tfb output -raw jumpbox_ssh_private_key > "${COPY_KEY_DIR}/key" ) \
    || { rm -rf "$COPY_KEY_DIR"; die "terraform output jumpbox_ssh_private_key failed"; }
  set +e
  ( set -e; copy_to_jumpbox "$ip" "$user" "${COPY_KEY_DIR}/key" "$dir" )
  rc=$?
  set -e
  rm -rf "$COPY_KEY_DIR"
  return "$rc"
}

# copy_to_jumpbox IP USER KEY DIR
copy_to_jumpbox() {
  local ip="$1" user="$2" key="$3" dir="$4" stamp rc
  local ssh_cmd=(ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${WORK_DIR}/jumpbox_known_hosts" -o ConnectTimeout=20
    -o ServerAliveInterval=30 "${user}@${ip}")   # keepalives: the Azure IP idle timeout is 4 minutes
  set +e
  "${ssh_cmd[@]}" true
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    die "ssh ${user}@${ip} failed (exit ${rc}). From an address outside admin_allowed_cidrs it times out; after the VM was replaced (same IP, new host key) remove the old key: ssh-keygen -R ${ip} -f ${WORK_DIR}/jumpbox_known_hosts"
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local tarc=(tar)
  if tar --version 2>/dev/null | grep -q bsdtar; then tarc=(tar --no-mac-metadata); fi
  # Remote paths; tests/deploy-scripts points them at a fake jumpbox
  local state_dir="${DEPLOY_JUMPBOX_STATE_DIR:-/var/lib/tpg-jumpbox}" log_dir="${DEPLOY_JUMPBOX_LOG_DIR:-/var/log/tpg-jumpbox}"
  local ci_log="${DEPLOY_CLOUD_INIT_LOG:-/var/log/cloud-init-output.log}" method remote_sha local_sha

  # 1. the first boot: cloud-init runs setup-jumpbox.sh (jumpbox_setup_method = cloud-init)
  method="$(tfv_get jumpbox_setup_method)"; method="${method:-remote-exec}"
  log "waiting for the jumpbox's first boot (cloud-init status --wait; setup method ${method})"
  "${ssh_cmd[@]}" 'if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait || true; fi'
  remote_sha="$("${ssh_cmd[@]}" "cat '${state_dir}/setup-jumpbox.sha256' 2>/dev/null || true")"
  if [[ -z "$remote_sha" ]]; then
    # no record of a finished setup: it failed at first boot, or the jumpbox was
    # set up before Round 19. Show why (cloud-init method) and run it again below.
    if [[ "$method" == cloud-init ]]; then
      warn "setup-jumpbox.sh did not finish at first boot; the end of ${ci_log} on the jumpbox:"
      "${ssh_cmd[@]}" "sudo tail -n 40 '${ci_log}'" >&2 || true
    fi
    warn "setup-jumpbox.sh has no record of a finished run on the jumpbox: it runs again now"
  fi

  # 2. scripts/ to ~/scripts (what remote-exec setup puts there)
  log "scripts/ -> ${user}@${ip}:~/scripts"
  "${ssh_cmd[@]}" 'rm -rf ~/scripts && mkdir -p ~/scripts'
  COPYFILE_DISABLE=1 "${tarc[@]}" -C "${INFRA_DIR}/scripts" --exclude .DS_Store -cf - . \
    | "${ssh_cmd[@]}" 'tar -C ~/scripts --warning=no-unknown-keyword -xpf -'

  # 3. a setup-jumpbox.sh newer than the one that ran: run it again, output shown
  local_sha="$( (sha256sum "${INFRA_DIR}/scripts/jumpbox/setup-jumpbox.sh" 2>/dev/null || shasum -a 256 "${INFRA_DIR}/scripts/jumpbox/setup-jumpbox.sh") | awk '{print $1}')"
  if [[ "$remote_sha" != "$local_sha" ]]; then
    log "setup-jumpbox.sh on the jumpbox is ${remote_sha:+an older version}${remote_sha:-not recorded}: running ~/scripts/jumpbox/setup-jumpbox.sh (log on the jumpbox: ${log_dir}/setup-${stamp}.log)"
    "${ssh_cmd[@]}" "sudo install -d -m 0755 '${log_dir}' && sudo bash -o pipefail -c \"bash '\$HOME/scripts/jumpbox/setup-jumpbox.sh' 2>&1 | tee '${log_dir}/setup-${stamp}.log'\"" \
      || die "setup-jumpbox.sh failed on the jumpbox (output above; log there: ${log_dir}/setup-${stamp}.log). Fix the cause and run deploy.sh copy again: it runs the script again"
  fi
  log "${dir} -> ${user}@${ip}:~/tpg-fleet (an existing one moves to ~/tpg-fleet.prev-${stamp})"
  # a numbered name when ~/tpg-fleet.prev-<stamp> exists (two copies in one second)
  "${ssh_cmd[@]}" "if [ -e ~/tpg-fleet ]; then p=~/tpg-fleet.prev-${stamp}; n=1; b=\$p; while [ -e \"\$p\" ]; do p=\$b.\$n; n=\$((n + 1)); done; mv ~/tpg-fleet \"\$p\"; fi; mkdir -p ~/tpg-fleet"
  COPYFILE_DISABLE=1 "${tarc[@]}" -C "$dir" --exclude .DS_Store -cf - . \
    | "${ssh_cmd[@]}" 'tar -C ~/tpg-fleet --warning=no-unknown-keyword -xf -'
  # env.sh holds no secret; Terraform uploaded the one of apply time, and repo
  # and setup may have changed it since
  if [[ -f "$DP_ENV_FILE" ]]; then
    log "env.sh -> ${user}@${ip}:~/env.sh (env.jumpbox.sh there keeps the jumpbox paths)"
    "${ssh_cmd[@]}" 'cat > ~/env.sh && chmod 600 ~/env.sh' < "$DP_ENV_FILE"
  fi
  log "${WORK_DIR} -> ${user}@${ip}:~/.work (kubeconfig included; inventory.yaml comes from Terraform, keySource az)"
  COPYFILE_DISABLE=1 "${tarc[@]}" -C "$WORK_DIR" --exclude inventory.yaml --exclude 'deploy-*.log' \
      --exclude jumpbox_known_hosts --exclude .DS_Store -cf - . \
    | "${ssh_cmd[@]}" 'mkdir -p ~/.work && chmod 700 ~/.work && tar -C ~/.work --warning=no-unknown-keyword -xpf -'
  # env.jumpbox.sh and the jumpbox inventory (backup.keySource az): from Terraform,
  # as the remote-exec setup writes them
  log "env.jumpbox.sh and .work/inventory.yaml -> ${user}@${ip} (Terraform outputs jumpbox_env_override, jumpbox_inventory_yaml)"
  printf '%s\n' "$(tf_out jumpbox_env_override)" | "${ssh_cmd[@]}" 'cat > ~/env.jumpbox.sh && chmod 600 ~/env.jumpbox.sh'
  printf '%s\n' "$(tf_out jumpbox_inventory_yaml)" | "${ssh_cmd[@]}" 'cat > ~/.work/inventory.yaml && chmod 600 ~/.work/inventory.yaml'
  ok "copied. On the jumpbox: export KUBECONFIG=~/.work/kubeconfig; ~/tpg-fleet/scripts/submit/tpg-day0.sh; ~/scripts/run.sh --hub install --targets terraform --only verify"
}

# ---------------------------------------------------------------- main
main() {
  case "$SUBCOMMAND" in
    preflight) step_preflight ;;
    apply)
      dp_check_tools apply; values_apply; summary apply; save_values; step_apply ;;
    repo)
      dp_check_tools repo; values_repo; summary repo; save_values; step_repo ;;
    setup)
      dp_check_tools setup; values_setup; summary setup; save_values; step_setup ;;
    copy) step_copy ;;
    all)
      if [[ -n "$FROM" ]]; then
        # resume: the values of the earlier run, no prompts (tokens are asked when missing)
        PROMPTS_OFF=1
      fi
      DP_IN_ALL=1
      if [[ -z "$FROM" ]]; then
        step_preflight
        values_apply; ask_env; values_repo
        [[ "$DV_enable_jumpbox" != true ]] || dp_check_tools copy
        summary "apply repo setup copy"
        # every token now, so that the run does not stop for one after the apply
        token GIT_ADMIN_PAT "GitHub token that creates the repository and pushes (GIT_ADMIN_PAT)"
        token BROADCOM_TOKEN "Broadcom registry token (BROADCOM_TOKEN)"
        token GIT_READ_PAT "GitHub read-only PAT (GIT_READ_PAT)"
        token GIT_PUSH_PAT "GitHub read/write PAT (GIT_PUSH_PAT)"
        save_values
      fi
      if [[ -n "$FROM" ]]; then run_steps "$STEPS" "$FROM"; else run_steps "${STEPS#preflight }"; fi
      ok "deploy.sh all finished" ;;
  esac
}

dp_parse_args "$STEPS all" "$@"
dp_run_logged main
