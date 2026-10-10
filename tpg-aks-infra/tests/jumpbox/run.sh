#!/usr/bin/env bash
# scripts/jumpbox/setup-jumpbox.sh and terraform/modules/jumpbox, without Azure
# and without downloading any tool:
#   1 shellcheck of setup-jumpbox.sh
#   2 --help, and refused options (unknown group, TF_TOOL, unsupported OS)
#   3 --dry-run on Ubuntu 24.04 and 22.04 (apt) and Rocky Linux 9 and RHEL 9
#     (dnf), read from fixtures/os-release-* through OS_RELEASE_FILE: package
#     manager, packages, the Azure CLI repository, and every tool of the three
#     groups with a version, an https URL and a checksum source
#   4 --only, --vault and TF_TOOL=terraform change the tool list
#   5 --clone as root is refused before it reads anything
#   6 terraform/jumpbox-provision.tf (Round 16) and the cloud-init method
#     (Round 19): headers, streamed and teed logs, no sensitive value in a
#     provisioner block, the cloud-init template; the tokens only
#     in the /dev/shm scripts that delete themselves; the run.sh arguments; the
#     inventory has every key of inventory-from-terraform.sh
#   7 tofu fmt -check; tofu validate and tofu test (jumpbox.tftest.hcl, mocked
#     providers) on a temporary copy when tofu can install the providers
#   8 push-fleet-repo.sh against a fake GitHub API (a curl stub) and a local
#     bare repository: create and push, the same files again, other files,
#     FLEET_REPO_FORCE, a failing validate.sh, a zip with two folders, the
#     token in no file of the clone
#   9 35-vault.sh --save-vault-recovery-keys: the keys file (mode 600, no root
#     token, an existing file kept), the check before init
#  10 run.sh --save-vault-recovery-keys (help, dry run)
#  11 run-fleet-setup.sh: run.sh detached, its log and exit code (needs
#     setsid, yq and bash 4)
# Requires bash; shellcheck and tofu are used when installed (SKIP otherwise).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/scripts/jumpbox/setup-jumpbox.sh"
FIX="${HERE}/fixtures"

WORK_BEFORE=false; [[ -e "${ROOT}/.work" ]] && WORK_BEFORE=true
# remove a .work the run created in the repository (scripts/run.sh, common.sh)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; $WORK_BEFORE || rm -rf "${ROOT}/.work"' EXIT
PASS=0; FAIL=0
ok()   { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$1"; }

# assert NAME PATTERN FILE: FILE has a line matching PATTERN
assert() { if grep -Eq -- "$2" "$3"; then ok "$1"; else bad "$1" "expected a line matching: $2"; fi; }
refute() { if grep -Eq -- "$2" "$3"; then bad "$1" "unexpected: $(grep -Em1 -- "$2" "$3")"; else ok "$1"; fi; }

# dry OUT OS_FIXTURE [ARGS...]: dry run for one OS; exit status in DRY_RC
dry() {
  local out="$1" os="$2"; shift 2
  DRY_RC=0
  OS_RELEASE_FILE="${FIX}/os-release-${os}" bash "$SCRIPT" --dry-run "$@" > "$out" 2>&1 || DRY_RC=$?
}

# tools OUT: the tool names of a dry run, space separated, in order
tools() { sed -n 's/^tool=\([^ ]*\) .*/\1/p' "$1" | tr '\n' ' ' | sed 's/ $//'; }

# check_tool_lines NAME OUT: every tool line has a version, an https URL and a
# checksum source of a known kind with a value
check_tool_lines() {
  local name="$1" out="$2" line t v u c problems=""
  while IFS= read -r line; do
    t="$(sed -n 's/^tool=\([^ ]*\) .*/\1/p' <<<"$line")"
    v="$(sed -n 's/.* version=\([^ ]*\) .*/\1/p' <<<"$line")"
    u="$(sed -n 's/.* url=\([^ ]*\) .*/\1/p' <<<"$line")"
    c="$(sed -n 's/.* checksum=\(.*\)$/\1/p' <<<"$line")"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || problems+=" ${t}:version='${v}'"
    [[ "$u" == https://* ]] || problems+=" ${t}:url='${u}'"
    if ! [[ "$c" =~ ^vendor:https://[^\ ]+$ || "$c" =~ ^vendor-yq:https://[^\ ]+$ \
         || "$c" =~ ^sha256:[0-9a-f]{64}$ || "$c" =~ ^repo-key:[0-9A-F]{40}$ \
         || "$c" =~ ^index:https://[^\ ]+$ \
         || "$c" =~ ^pypi:yamllint=[0-9a-f]{64},pathspec=[0-9a-f]{64},pyyaml=[0-9a-f]{64}(\|[0-9a-f]{64})*$ ]]; then
      problems+=" ${t}:checksum='${c}'"
    fi
  done < <(grep '^tool=' "$out")
  if ! grep -q '^tool=' "$out"; then bad "$name" "no tool lines"
  elif [[ -z "$problems" ]]; then ok "$name"
  else bad "$name" "$problems"; fi
}

ALL_TOOLS="azure-cli kubectl helm argo argocd yq tofu kubelogin shellcheck kubeconform kustomize yamllint setup-envtest envtest kubectx kubens fzf"

echo "== 1: shellcheck"
if command -v shellcheck >/dev/null; then
  if shellcheck "$SCRIPT" > "$TMP/sc" 2>&1; then ok "setup-jumpbox.sh is shellcheck clean"
  else bad "setup-jumpbox.sh is shellcheck clean" "$(head -20 "$TMP/sc")"; fi
  if shellcheck "$0" > "$TMP/sc" 2>&1; then ok "tests/jumpbox/run.sh is shellcheck clean"
  else bad "tests/jumpbox/run.sh is shellcheck clean" "$(head -20 "$TMP/sc")"; fi
else
  skip "shellcheck not installed"
fi

echo "== 2: help and refused input"
rc=0; bash "$SCRIPT" --help > "$TMP/help" 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then ok "--help exits 0"; else bad "--help exits 0" "exit $rc"; fi
assert "--help documents --only, --vault, --dry-run and --clone" '--only GROUPS' "$TMP/help"
assert "--help names the token variable" 'GIT_READ_PAT' "$TMP/help"
dry "$TMP/o" ubuntu-24.04 --only run-time,bogus
if [[ $DRY_RC -ne 0 ]] && grep -q "unknown group 'bogus'" "$TMP/o"; then ok "an unknown group is refused"
else bad "an unknown group is refused" "exit ${DRY_RC}: $(cat "$TMP/o")"; fi
DRY_RC=0; TF_TOOL=terragrunt OS_RELEASE_FILE="${FIX}/os-release-ubuntu-24.04" bash "$SCRIPT" --dry-run > "$TMP/o" 2>&1 || DRY_RC=$?
if [[ $DRY_RC -ne 0 ]] && grep -q "TF_TOOL must be tofu or terraform" "$TMP/o"; then ok "TF_TOOL other than tofu or terraform is refused"
else bad "TF_TOOL other than tofu or terraform is refused" "exit ${DRY_RC}"; fi
dry "$TMP/o" debian-12
if [[ $DRY_RC -ne 0 ]] && grep -q "unsupported OS 'Debian GNU/Linux 12 (bookworm)'" "$TMP/o"; then ok "an unsupported OS is refused with its name"
else bad "an unsupported OS is refused with its name" "exit ${DRY_RC}: $(cat "$TMP/o")"; fi

echo "== 3: dry run per OS"
STATE_BEFORE=false; [[ -e /var/lib/tpg-jumpbox ]] && STATE_BEFORE=true
for os in ubuntu-24.04 ubuntu-22.04 rocky-9 rhel-9; do
  dry "$TMP/$os" "$os"
  if [[ $DRY_RC -eq 0 ]]; then ok "$os: dry run exits 0"; else bad "$os: dry run exits 0" "exit ${DRY_RC}: $(cat "$TMP/$os")"; fi
  got="$(tools "$TMP/$os")"
  if [[ "$got" == "$ALL_TOOLS" ]]; then ok "$os: every tool of run-time, tests and extras is planned"
  else bad "$os: every tool of run-time, tests and extras is planned" "got: $got"; fi
  check_tool_lines "$os: every tool has a version, an https URL and a checksum source" "$TMP/$os"
  assert "$os: KUBEBUILDER_ASSETS goes to /etc/profile.d" '^profile: /etc/profile.d/tpg-jumpbox.sh sets KUBEBUILDER_ASSETS=.*/1\.34\.1-linux-amd64$' "$TMP/$os"
  assert "$os: nothing downloaded" '^dry run: nothing downloaded or changed$' "$TMP/$os"
done
assert "ubuntu-24.04: apt" '^package manager: apt$' "$TMP/ubuntu-24.04"
assert "ubuntu-24.04: codename noble" 'codename=noble' "$TMP/ubuntu-24.04"
assert "ubuntu-24.04: Azure CLI from the noble repository, pinned key" '^tool=azure-cli .*url=https://packages\.microsoft\.com/repos/azure-cli/dists/noble/ checksum=repo-key:BC528686B50D79E339D3721CEB3E94ADBE1229CF$' "$TMP/ubuntu-24.04"
assert "ubuntu-24.04: apt packages include PyYAML, venv, tmux and bash-completion" '^packages: .*python3-yaml python3-venv bash-completion tmux' "$TMP/ubuntu-24.04"
assert "ubuntu-22.04: Azure CLI from the jammy repository" '^tool=azure-cli .*dists/jammy/ ' "$TMP/ubuntu-22.04"
assert "rocky-9: dnf" '^package manager: dnf$' "$TMP/rocky-9"
assert "rocky-9: Azure CLI from the RHEL 9 repository" '^tool=azure-cli .*url=https://packages\.microsoft\.com/rhel/9\.0/prod/ ' "$TMP/rocky-9"
assert "rocky-9: python3.12 for yamllint, python3-pyyaml for the tests" '^packages: .*python3-pyyaml python3\.12 python3\.12-pip' "$TMP/rocky-9"
refute "rocky-9: no apt package names" '^packages: .*(xz-utils|python3-venv|python3-yaml)' "$TMP/rocky-9"
assert "rhel-9: dnf" '^package manager: dnf$' "$TMP/rhel-9"
assert "kubectl is the version of the workflow tools image (alpine/k8s:1.35.8)" '^tool=kubectl .*version=1\.35\.8 ' "$TMP/ubuntu-24.04"
assert "Helm is a 4.x release" '^tool=helm .*version=4\.' "$TMP/ubuntu-24.04"
assert "argo CLI v4.1.3" '^tool=argo .*version=4\.1\.3 ' "$TMP/ubuntu-24.04"
assert "argocd CLI v3.5.3" '^tool=argocd .*version=3\.5\.3 ' "$TMP/ubuntu-24.04"
assert "yq v4.47.2" '^tool=yq .*version=4\.47\.2 ' "$TMP/ubuntu-24.04"
assert "OpenTofu 1.9.1 by default" '^tool=tofu .*version=1\.9\.1 ' "$TMP/ubuntu-24.04"
if ! $STATE_BEFORE && [[ -e /var/lib/tpg-jumpbox ]]; then bad "the dry runs wrote no state" "/var/lib/tpg-jumpbox exists"
else ok "the dry runs wrote no state"; fi

echo "== 4: --only, --vault, TF_TOOL"
dry "$TMP/o" rocky-9 --only tests
got="$(tools "$TMP/o")"
if [[ "$got" == "shellcheck kubeconform kustomize yamllint setup-envtest envtest" ]]; then ok "--only tests plans the test toolchain only"
else bad "--only tests plans the test toolchain only" "got: $got"; fi
dry "$TMP/o" ubuntu-24.04 --only extras
got="$(tools "$TMP/o")"
if [[ "$got" == "kubectx kubens fzf" ]]; then ok "--only extras plans kubectx, kubens and fzf"
else bad "--only extras plans kubectx, kubens and fzf" "got: $got"; fi
assert "--only extras installs tmux and bash-completion" '^packages: .*bash-completion tmux' "$TMP/o"
DRY_RC=0; TF_TOOL=terraform OS_RELEASE_FILE="${FIX}/os-release-ubuntu-24.04" bash "$SCRIPT" --dry-run --only run-time --vault > "$TMP/o" 2>&1 || DRY_RC=$?
got="$(tools "$TMP/o")"
if [[ $DRY_RC -eq 0 && "$got" == "azure-cli kubectl helm argo argocd yq terraform kubelogin vault" ]]; then ok "TF_TOOL=terraform and --vault replace tofu and add vault"
else bad "TF_TOOL=terraform and --vault replace tofu and add vault" "exit ${DRY_RC}, got: $got"; fi
check_tool_lines "terraform and vault have a version, an https URL and a checksum source" "$TMP/o"
assert "terraform is verified against the HashiCorp SHA256SUMS" '^tool=terraform .*checksum=vendor:https://releases\.hashicorp\.com/terraform/.*_SHA256SUMS$' "$TMP/o"

echo "== 5: --clone"
if [[ $EUID -eq 0 ]]; then
  rc=0; FLEET_REPO_URL=https://example.invalid/tpg-fleet.git INFRA_REPO_URL=https://example.invalid/tpg-aks-infra.git \
    bash "$SCRIPT" --clone > "$TMP/o" 2>&1 || rc=$?
  if [[ $rc -ne 0 ]] && grep -q 'run it as that user, without sudo' "$TMP/o"; then ok "--clone as root is refused"
  else bad "--clone as root is refused" "exit $rc: $(cat "$TMP/o")"; fi
else
  rc=0; env -u FLEET_REPO_URL -u INFRA_REPO_URL bash "$SCRIPT" --clone > "$TMP/o" 2>&1 || rc=$?
  if [[ $rc -ne 0 ]] && grep -q 'export FLEET_REPO_URL' "$TMP/o"; then ok "--clone without FLEET_REPO_URL is refused"
  else bad "--clone without FLEET_REPO_URL is refused" "exit $rc: $(cat "$TMP/o")"; fi
  rc=0; FLEET_REPO_URL=https://user:secret@example.invalid/tpg-fleet.git INFRA_REPO_URL=https://example.invalid/tpg-aks-infra.git \
    bash "$SCRIPT" --clone > "$TMP/o" 2>&1 || rc=$?
  if [[ $rc -ne 0 ]] && grep -q 'remove the credentials from the URL' "$TMP/o"; then ok "--clone refuses a URL with credentials"
  else bad "--clone refuses a URL with credentials" "exit $rc: $(cat "$TMP/o")"; fi
fi

echo "== 6: jumpbox provisioning (terraform/jumpbox-provision.tf)"
PROV="${ROOT}/terraform/jumpbox-provision.tf"
TPL="${ROOT}/terraform/modules/jumpbox/cloud-init.yaml.tftpl"
# shellcheck disable=SC2016  # template placeholders, not shell expansions
vars="$(grep -o '\${[^}]*}' "$TPL" | sort -u | tr '\n' ' ')"
# shellcheck disable=SC2016
if [[ "$vars" == '${admin_username} ${setup_script_gz_b64} ' ]]; then ok "cloud-init method: the template takes the setup script and the admin user only"
else bad "cloud-init method: the template takes the setup script and the admin user only" "template variables: $vars"; fi
assert "cloud-init method: custom_data only when cloud_init_script is set" 'custom_data = var.cloud_init_script == null \? null :' "${ROOT}/terraform/modules/jumpbox/main.tf"
assert "cloud-init method: custom_data changes never replace the VM" 'ignore_changes = \[custom_data\]' "${ROOT}/terraform/modules/jumpbox/main.tf"
assert "cloud-init method: the script runs with TPG_FROM_CLOUD_INIT=1 and its output is kept" 'TPG_FROM_CLOUD_INIT=1 bash /home/\$\{admin_username\}/setup-jumpbox.sh 2>&1 \| tee /var/log/tpg-jumpbox/setup-cloud-init.log' "$TPL"
refute "remote-exec: no cloud-init command in Terraform" '^[^#]*cloud-init status' "$PROV"
assert "remote-exec: setup-jumpbox.sh output streamed and kept (pipefail, tee)" 'sudo bash -o pipefail -c .*setup-jumpbox.sh.* 2>&1 \| tee /var/log/tpg-jumpbox/setup-' "$PROV"
assert "remote-exec: push-fleet-repo.sh output streamed and kept (pipefail, tee)" 'bash -o pipefail -c .*push-fleet-repo.sh.* 2>&1 \| tee .*/.work/logs/push-fleet-repo-' "$PROV"
for h in "== jumpbox_setup: sudo setup-jumpbox.sh" "== fleet_repo: push-fleet-repo.sh" "== jumpbox_run: run-fleet-setup.sh"; do
  assert "remote-exec: header '${h}'" "echo .*${h}" "$PROV"
done
# a sensitive value in a provisioner block would make Terraform suppress its whole output
blocks="$(awk '/provisioner "(remote-exec|file)"/ {p=1} p {print} p && /^  }/ {p=0}' "$PROV")"
if grep -qE 'var\.(git_admin_pat|broadcom_token|git_read_pat|git_push_pat)|jumpbox_private_key' <<<"$blocks"; then bad "no sensitive value in any provisioner block (its output would be suppressed)" "$(grep -nE 'var\.(git_|broadcom)|jumpbox_private_key' <<<"$blocks")"
else ok "no sensitive value in any provisioner block (its output would be suppressed)"; fi
assert "setup-jumpbox.sh: waits for the first boot, visibly, unless cloud-init runs it" 'TPG_FROM_CLOUD_INIT:-0.*!= 1.*command -v cloud-init' "$SCRIPT"
assert "setup-jumpbox.sh: records its sha256 for deploy.sh copy" 'setup-jumpbox.sha256' "$SCRIPT"
# every resource whose inline script carries a token writes it to /dev/shm and deletes it first
for r in fleet_repo jumpbox_run; do
  body="$(awk -v r="$r" '$0 ~ "^resource \"terraform_data\" \"" r "\"" {p=1} p {print} p && /^}/ {exit}' "$PROV")"
  if grep -q 'script_path = "/dev/shm/' <<<"$body" && grep -A1 'inline = \[' <<<"$body" | grep -q 'rm -f -- \\"\$0\\"'; then
    ok "terraform_data.${r}: token script in /dev/shm, deleted as its first command"
  else
    bad "terraform_data.${r}: token script in /dev/shm, deleted as its first command"
  fi
done
# the secret variables appear only in the base64 locals and the preconditions
if grep -nE 'var\.(git_admin_pat|broadcom_token|git_read_pat|git_push_pat)' "$PROV" | grep -vE 'nonsensitive\(base64encode\(var\.|condition +=' > "$TMP/sec"; then
  bad "the tokens are used only through the base64 locals" "$(cat "$TMP/sec")"
else
  ok "the tokens are used only through the base64 locals"
fi
assert "jumpbox_run runs run.sh with the four flags, stderr merged" 'run-fleet-setup\.sh\\" --hub install --targets terraform --expose-ui --save-vault-recovery-keys 2>&1"' "$PROV"
assert "the jumpbox inventory uses keySource az" 'keySource += "az"' "$PROV"
missing=""
for k in subscriptionId adminAllowedCidrs source hub targets backup network monitoring storage nodePools vault \
         resourceGroup access adminCredentials egressCidrs wave backupContainer storageAccount createContainers \
         logsContainer httpsOnly caBundleFile acnsEnabled remoteWriteExposure extraSourceCidrs azureMonitorWorkspaceId \
         grafanaResourceGroup grafanaName dataDiskSku unsealMode exposure azureKeyVault keyName tenantId clientId; do
  grep -q "${k}:" "${ROOT}/scripts/targets/terraform/inventory-from-terraform.sh" || missing+=" ${k}(not in the jq inventory any more)"
  grep -Eq "^[[:space:]]*${k}[[:space:]]+=" "$PROV" || missing+=" ${k}"
done
if [[ -z "$missing" ]]; then ok "the jumpbox inventory has every key of inventory-from-terraform.sh"
else bad "the jumpbox inventory has every key of inventory-from-terraform.sh" "missing:${missing}"; fi

echo "== 7: OpenTofu"
if command -v tofu >/dev/null; then
  if tofu -chdir="${ROOT}/terraform" fmt -check -recursive > "$TMP/fmt" 2>&1; then ok "tofu fmt -check -recursive"
  else bad "tofu fmt -check -recursive" "$(cat "$TMP/fmt")"; fi
  if tofu fmt -check "${HERE}/jumpbox.tftest.hcl" > "$TMP/fmt" 2>&1; then ok "tofu fmt -check jumpbox.tftest.hcl"
  else bad "tofu fmt -check jumpbox.tftest.hcl" "$(cat "$TMP/fmt")"; fi
  # A copy, so that init writes no .terraform or lock file into the repository.
  mkdir -p "$TMP/repo"
  cp -R "${ROOT}/terraform" "$TMP/repo/terraform"
  cp -R "${ROOT}/scripts" "$TMP/repo/scripts"
  cp "${ROOT}/env.sh.example" "$TMP/repo/"
  touch "$TMP/tpg-fleet.zip"   # the default fleet_zip_path of the copy: next to its tpg-aks-infra folder
  rm -rf "$TMP/repo/terraform/.terraform" "$TMP/repo/terraform/tests"
  mkdir "$TMP/repo/terraform/tests"
  cp "${HERE}/jumpbox.tftest.hcl" "$TMP/repo/terraform/tests/"
  if tofu -chdir="$TMP/repo/terraform" init -backend=false -input=false -no-color > "$TMP/init" 2>&1; then
    if tofu -chdir="$TMP/repo/terraform" validate -no-color > "$TMP/val" 2>&1; then ok "tofu validate"
    else bad "tofu validate" "$(cat "$TMP/val")"; fi
    if tofu -chdir="$TMP/repo/terraform" test -no-color > "$TMP/test" 2>&1; then
      ok "tofu test: $(grep -E '^Success!' "$TMP/test" | sed 's/^Success! //')"
    else
      bad "tofu test (jumpbox.tftest.hcl)" "$(grep -vE '^\s*$' "$TMP/test" | tail -25)"
    fi
  else
    skip "tofu validate and tofu test: tofu init could not install the providers ($(grep -m1 -E 'Error|error' "$TMP/init" || echo 'see tofu init'))"
  fi
else
  skip "tofu not installed"
fi

echo "== 8: push-fleet-repo.sh (fake GitHub API, local bare repository)"
PUSH="${ROOT}/scripts/jumpbox/push-fleet-repo.sh"
FLEET_SRC="${FLEET_LOCAL_DIR:-$(cd "${ROOT}/.." && pwd)/tpg-fleet}"
if ! command -v zip >/dev/null || ! command -v unzip >/dev/null || ! command -v git >/dev/null || ! command -v jq >/dev/null; then
  skip "zip, unzip, git or jq not installed"
elif [[ ! -f "${FLEET_SRC}/scripts/set-repo-url.sh" ]]; then
  skip "no tpg-fleet next to this repository (set FLEET_LOCAL_DIR): its set-repo-url.sh is used"
elif [[ $EUID -eq 0 ]]; then
  skip "push-fleet-repo.sh refuses root"
else
  G="$TMP/gh"; mkdir -p "$G/bin" "$G/remote" "$G/home"
  # curl stub: the GitHub API of owner "acme" (user "tester"); repositories are
  # bare git repositories under $G/remote. The token must arrive on stdin (-K -).
  cat > "$G/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" method=GET url="" data="" all="$*"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -w|-H|--retry|--retry-delay|-K) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
cfg="$(cat)"
echo "$method $url" >> "$GH_STUB/calls"
[[ "$all" != *test-token* ]] || echo "token on the command line" >> "$GH_STUB/calls"
if [[ "$cfg" != *"Authorization: Bearer test-token"* ]]; then echo '{"message":"Bad credentials"}' > "$out"; printf 401; exit 0; fi
path="${url#https://api.github.example}"
case "$method $path" in
  "GET /user") echo '{"login":"tester"}' > "$out"; printf 200 ;;
  "GET /repos/acme/"*)
    n="${path#/repos/acme/}"
    if [[ -d "$GH_STUB/remote/$n.git" ]]; then echo "{\"html_url\":\"https://github.example/acme/$n\"}" > "$out"; printf 200
    else echo '{"message":"Not Found"}' > "$out"; printf 404; fi ;;
  "POST /orgs/acme/repos")
    n="$(jq -r .name <<<"$data")"
    [[ "$(jq -r .private <<<"$data")" == true ]] || { echo '{"message":"must be private"}' > "$out"; printf 422; exit 0; }
    git init -q --bare "$GH_STUB/remote/$n.git"
    echo "{\"html_url\":\"https://github.example/acme/$n\"}" > "$out"; printf 201 ;;
  *) echo '{}' > "$out"; printf 500 ;;
esac
STUB
  chmod 755 "$G/bin/curl"
  # https://github.example/acme/<name>.git is the local bare repository
  printf '[url "file://%s/remote/"]\n\tinsteadOf = https://github.example/acme/\n[init]\n\tdefaultBranch = main\n' "$G" > "$G/gitconfig"
  # mkfleet DIR [EXTRA]: a minimal tpg-fleet tree with the real set-repo-url.sh
  mkfleet() {
    mkdir -p "$1/tpg-fleet/scripts" "$1/tpg-fleet/clusters" "$1/tpg-fleet/bootstrap" "$1/__MACOSX"
    cp "${FLEET_SRC}/scripts/set-repo-url.sh" "$1/tpg-fleet/scripts/"
    printf 'clusters: {}\n' > "$1/tpg-fleet/clusters/fleet.yaml"
    printf 'repoURL: https://github.com/<org>/tpg-fleet.git\n%s\n' "${2:-}" > "$1/tpg-fleet/bootstrap/app.yaml"
    printf '#!/usr/bin/env bash\nexit "${VALIDATE_RC:-0}"\n' > "$1/tpg-fleet/scripts/validate.sh"
    touch "$1/tpg-fleet/.DS_Store" "$1/__MACOSX/._tpg-fleet"
    (cd "$1" && zip -qr fleet.zip tpg-fleet __MACOSX)
  }
  mkfleet "$G/z1"; mkfleet "$G/z2" "# second version"
  # runpush NAME ZIP [VAR=VALUE...]: exit status in PUSH_RC, output in $TMP/push
  runpush() {
    local name="$1" zip="$2"; shift 2
    PUSH_RC=0
    env HOME="$G/home" PATH="$G/bin:$PATH" GH_STUB="$G" GIT_CONFIG_GLOBAL="$G/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
      ENV_FILE=/dev/null JUMPBOX_ENV_FILE=/dev/null \
      FLEET_REPO_OWNER=acme FLEET_REPO_NAME="$name" FLEET_REPO_URL="https://github.example/acme/${name}.git" \
      GITHUB_API_URL=https://api.github.example GIT_ADMIN_PAT=test-token FLEET_LOCAL_DIR="$G/home/tpg-fleet" \
      FLEET_VALIDATE_TFVARS=true FLEET_VALIDATE=true "$@" bash "$PUSH" "$zip" > "$TMP/push" 2>&1 || PUSH_RC=$?
  }
  remote_file() { git --git-dir="$G/remote/$1.git" show "${3:-main}:$2" 2>/dev/null; }

  runpush fleet "$G/z1/fleet.zip"
  if [[ $PUSH_RC -eq 0 ]] && grep -q 'repoURL: https://github.example/acme/fleet.git' <<<"$(remote_file fleet bootstrap/app.yaml)"; then
    ok "creates the repository and pushes main with the repository URL set"
  else bad "creates the repository and pushes main with the repository URL set" "exit ${PUSH_RC}: $(tail -5 "$TMP/push")"; fi
  if grep -q '^POST https://api.github.example/orgs/acme/repos$' "$G/calls" && ! grep -q 'token on the command line' "$G/calls"; then
    ok "an organization owner is created with POST /orgs/<owner>/repos, the token only on stdin"
  else bad "an organization owner is created with POST /orgs/<owner>/repos, the token only on stdin" "$(cat "$G/calls")"; fi
  if [[ "$(git --git-dir="$G/remote/fleet.git" ls-tree -r --name-only main | tr '\n' ' ')" == "bootstrap/app.yaml clusters/fleet.yaml scripts/set-repo-url.sh scripts/validate.sh " ]]; then
    ok "__MACOSX and .DS_Store are left out"
  else bad "__MACOSX and .DS_Store are left out" "$(git --git-dir="$G/remote/fleet.git" ls-tree -r --name-only main | tr '\n' ' ')"; fi
  if [[ "$(git --git-dir="$G/remote/fleet.git" ls-tree main scripts/validate.sh | cut -c1-6)" == 100755 ]]; then ok "scripts are committed executable"
  else bad "scripts are committed executable"; fi
  if grep -rq test-token "$G/home/tpg-fleet/.git" "$G/home/tpg-fleet" 2>/dev/null; then bad "the token is in no file of the clone"
  else ok "the token is in no file of the clone"; fi
  if ! grep -q 'credential' "$G/home/tpg-fleet/.git/config"; then ok "no credential helper in the clone's git configuration"
  else bad "no credential helper in the clone's git configuration" "$(cat "$G/home/tpg-fleet/.git/config")"; fi

  head_before="$(git --git-dir="$G/remote/fleet.git" rev-parse main)"
  runpush fleet "$G/z1/fleet.zip"
  if [[ $PUSH_RC -eq 0 ]] && grep -q 'nothing to push' "$TMP/push" && [[ "$(git --git-dir="$G/remote/fleet.git" rev-parse main)" == "$head_before" ]]; then
    ok "the same zip again: nothing pushed, exit 0"
  else bad "the same zip again: nothing pushed, exit 0" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi
  if ls -d "$G/home/tpg-fleet.prev-"* >/dev/null 2>&1; then ok "the earlier ~/tpg-fleet is moved aside, not deleted"
  else bad "the earlier ~/tpg-fleet is moved aside, not deleted"; fi

  runpush fleet "$G/z2/fleet.zip"
  if [[ $PUSH_RC -ne 0 ]] && grep -q 'already has other content' "$TMP/push" && [[ "$(git --git-dir="$G/remote/fleet.git" rev-parse main)" == "$head_before" ]]; then
    ok "other files on the branch: stops, nothing pushed"
  else bad "other files on the branch: stops, nothing pushed" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi

  runpush fleet "$G/z2/fleet.zip" FLEET_REPO_FORCE_TFVARS=true FLEET_REPO_FORCE=true
  if [[ $PUSH_RC -eq 0 ]] && grep -q 'second version' <<<"$(remote_file fleet bootstrap/app.yaml)"; then
    ok "FLEET_REPO_FORCE=true replaces the branch"
  else bad "FLEET_REPO_FORCE=true replaces the branch" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi

  runpush other "$G/z1/fleet.zip" FLEET_REPO_REVISION=release
  if [[ $PUSH_RC -eq 0 ]] && [[ -n "$(remote_file other clusters/fleet.yaml release)" ]] && [[ -z "$(remote_file other clusters/fleet.yaml main)" ]]; then
    ok "FLEET_REPO_REVISION picks the branch"
  else bad "FLEET_REPO_REVISION picks the branch" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi

  runpush failing "$G/z1/fleet.zip" VALIDATE_RC=1
  if [[ $PUSH_RC -ne 0 ]] && grep -q 'validate.sh failed' "$TMP/push" && [[ -z "$(git --git-dir="$G/remote/failing.git" for-each-ref 2>/dev/null)" ]]; then
    ok "a failing validate.sh stops before the push"
  else bad "a failing validate.sh stops before the push" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi

  runpush skipped "$G/z1/fleet.zip" VALIDATE_RC=1 FLEET_VALIDATE=false
  if [[ $PUSH_RC -eq 0 ]] && grep -q 'validate.sh skipped: FLEET_VALIDATE=false in env.sh' "$TMP/push"; then ok "FLEET_VALIDATE=false in env.sh skips validate.sh, saying why"
  else bad "FLEET_VALIDATE=false in env.sh skips validate.sh, saying why" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi
  runpush skip2 "$G/z1/fleet.zip" VALIDATE_RC=1 FLEET_VALIDATE_TFVARS=false
  if [[ $PUSH_RC -eq 0 ]] && grep -q 'validate.sh skipped: fleet_repo_validate is not true in Terraform' "$TMP/push"; then ok "fleet_repo_validate = false in Terraform skips validate.sh"
  else bad "fleet_repo_validate = false in Terraform skips validate.sh" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi
  # nothing set: off by default, even when validate.sh would fail
  RC0=0; env HOME="$G/home" PATH="$G/bin:$PATH" GH_STUB="$G" GIT_CONFIG_GLOBAL="$G/gitconfig" GIT_CONFIG_NOSYSTEM=1 ENV_FILE=/dev/null JUMPBOX_ENV_FILE=/dev/null \
    FLEET_REPO_OWNER=acme FLEET_REPO_NAME=skip3 FLEET_REPO_URL="https://github.example/acme/skip3.git" GITHUB_API_URL=https://api.github.example \
    GIT_ADMIN_PAT=test-token FLEET_LOCAL_DIR="$G/home/tpg-fleet" VALIDATE_RC=1 bash "$PUSH" "$G/z1/fleet.zip" > "$TMP/push" 2>&1 || RC0=$?
  if [[ $RC0 -eq 0 ]] && grep -q 'validate.sh skipped: fleet_repo_validate is not true in Terraform' "$TMP/push"; then ok "nothing set: validate.sh is off by default"
  else bad "nothing set: validate.sh is off by default" "exit ${RC0}: $(tail -3 "$TMP/push")"; fi
  runpush skip4 "$G/z1/fleet.zip" VALIDATE_RC=1 FLEET_VALIDATE_TFVARS=true FLEET_VALIDATE= fleet_repo_validate=false
  if [[ $PUSH_RC -eq 0 ]] && grep -q 'skipped: fleet_repo_validate=false in env.sh' "$TMP/push"; then ok "env.sh fleet_repo_validate=false skips validate.sh"
  else bad "env.sh fleet_repo_validate=false skips validate.sh" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi
  runpush lower "$G/z1/fleet.zip" VALIDATE_RC=1 FLEET_VALIDATE= fleet_repo_validate=true
  if [[ $PUSH_RC -ne 0 ]] && grep -q 'validate.sh failed' "$TMP/push"; then ok "env.sh fleet_repo_validate=true (lowercase) with the Terraform value true runs validate.sh"
  else bad "env.sh fleet_repo_validate=true (lowercase) with the Terraform value true runs validate.sh" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi
  runpush fleet "$G/z1/fleet.zip" FLEET_REPO_FORCE_TFVARS=true
  if [[ $PUSH_RC -ne 0 ]] && grep -q 'force is off: neither FLEET_REPO_FORCE nor fleet_repo_force is set' "$TMP/push"; then ok "force needs env.sh too: the Terraform value alone refuses"
  else bad "force needs env.sh too: the Terraform value alone refuses" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi

  mkdir -p "$G/z3/a" "$G/z3/b"; (cd "$G/z3" && zip -qr two.zip a b)
  runpush two "$G/z3/two.zip"
  if [[ $PUSH_RC -ne 0 ]] && grep -q 'exactly one top-level folder' "$TMP/push"; then ok "a zip with two folders is refused"
  else bad "a zip with two folders is refused" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi

  runpush rel fleet.zip
  if [[ $PUSH_RC -ne 0 ]] && grep -q "ZIP must be an absolute path (got 'fleet.zip')" "$TMP/push"; then ok "a relative zip path is refused"
  else bad "a relative zip path is refused" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi
  runpush rel "$G/z1/fleet.zip" FLEET_LOCAL_DIR=home/tpg-fleet
  if [[ $PUSH_RC -ne 0 ]] && grep -q "FLEET_LOCAL_DIR must be an absolute path" "$TMP/push"; then ok "a relative FLEET_LOCAL_DIR is refused"
  else bad "a relative FLEET_LOCAL_DIR is refused" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi

  runpush fleet "$G/z1/fleet.zip" GIT_ADMIN_PAT=wrong
  if [[ $PUSH_RC -ne 0 ]] && grep -q 'GIT_ADMIN_PAT was refused' "$TMP/push"; then ok "a refused token stops with a named error"
  else bad "a refused token stops with a named error" "exit ${PUSH_RC}: $(tail -3 "$TMP/push")"; fi
fi

echo "== 9: 35-vault.sh --save-vault-recovery-keys (keys file)"
VAULT_STEP="${ROOT}/scripts/steps/35-vault.sh"
# The key-file functions of the step, without Kubernetes or Vault
fn() { awk -v f="$1" '$0 ~ "^" f "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$VAULT_STEP"; }
{
  echo 'ok()   { printf "OK %s\n" "$*"; }'
  echo 'warn() { printf "WARN %s\n" "$*" >&2; }'
  echo 'die()  { printf "FAIL %s\n" "$*" >&2; exit 1; }'
  fn vault_keys_target; fn vault_save_keys; fn vault_keys_precheck
} > "$TMP/vaultfns.sh"
if [[ "$(grep -cE '^vault_(keys_target|save_keys|keys_precheck)\(\) \{' "$TMP/vaultfns.sh")" -ne 3 ]]; then
  bad "the key-file functions are found in 35-vault.sh" "$(grep '() {' "$TMP/vaultfns.sh")"
else
  mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  INIT_JSON='{"unseal_keys_b64":["k1A","k2B","k3C","k4D","k5E"],"root_token":"hvs.ROOTTOKEN"}'
  # savekeys FILE: run vault_save_keys once with a fresh INIT; output in $TMP/vk
  savekeys() {
    VK_RC=0
    KEYS_FILE="$1" INIT="$INIT_JSON" bash -c 'set -euo pipefail; source "$0"
      HUB=aks-hub MODE=shamir KEYS_NAME="Unseal keys" KEYS_FIELD=unseal_keys_b64 KEYS_SHOWN=0
      vault_save_keys' "$TMP/vaultfns.sh" > "$TMP/vk" 2>&1 || VK_RC=$?
  }
  KF="$TMP/vk-home/.tpg/vault-keys.txt"
  savekeys "$KF"
  if [[ $VK_RC -eq 0 && -f "$KF" ]] && [[ "$(mode "$KF")" == 600 && "$(mode "$(dirname "$KF")")" == 700 ]]; then
    ok "keys file written with mode 600 in a directory of mode 700"
  else bad "keys file written with mode 600 in a directory of mode 700" "exit ${VK_RC}: $(cat "$TMP/vk")"; fi
  if [[ "$(grep -c '^Key [1-5]: k[1-5][A-E]$' "$KF" 2>/dev/null)" -eq 5 ]] && grep -q 'unseal mode shamir' "$KF"; then
    ok "the file holds the 5 keys and names the unseal mode"
  else bad "the file holds the 5 keys and names the unseal mode" "$(cat "$KF" 2>/dev/null)"; fi
  if ! grep -q 'hvs.ROOTTOKEN' "$KF" && ! grep -qE 'hvs.ROOTTOKEN|k1A' "$TMP/vk" && grep -q "saved to ${KF}" "$TMP/vk"; then
    ok "no root token in the file; the output names the file and shows no key"
  else bad "no root token in the file; the output names the file and shows no key" "$(cat "$TMP/vk")"; fi
  cp "$KF" "$TMP/vk-before"
  savekeys "$KF"
  copy="$(ls "${KF}".* 2>/dev/null | head -1)"
  if [[ $VK_RC -eq 0 && -n "$copy" ]] && cmp -s "$KF" "$TMP/vk-before" && [[ "$copy" =~ \.[0-9]{8}T[0-9]{6}Z$ ]]; then
    ok "an existing keys file is kept; the new keys go to <file>.<UTC time>"
  else bad "an existing keys file is kept; the new keys go to <file>.<UTC time>" "exit ${VK_RC}, copy '${copy}': $(cat "$TMP/vk")"; fi
  if ! ls -a "$(dirname "$KF")" | grep -q '^\.vault-keys\.'; then ok "no temporary file is left behind"
  else bad "no temporary file is left behind" "$(ls -a "$(dirname "$KF")")"; fi
  if [[ $EUID -ne 0 ]]; then
    mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
    rc=0; KEYS_FILE="$TMP/ro/keys.txt" bash -c 'set -euo pipefail; source "$0"; vault_keys_precheck' "$TMP/vaultfns.sh" > "$TMP/vk" 2>&1 || rc=$?
    chmod 700 "$TMP/ro"
    if [[ $rc -ne 0 ]] && grep -q 'is not writable' "$TMP/vk"; then ok "the check before init refuses a directory it cannot write"
    else bad "the check before init refuses a directory it cannot write" "exit $rc: $(cat "$TMP/vk")"; fi
  else
    skip "unwritable directory check (root writes anywhere)"
  fi
  assert "without a terminal the step needs --save-vault-recovery-keys" 'or pass --save-vault-recovery-keys' "$VAULT_STEP"
  assert "the check runs before vault operator init" '^    vault_keys_precheck$' "$VAULT_STEP"
fi

echo "== 10: run.sh --save-vault-recovery-keys"
rc=0; bash "${ROOT}/scripts/run.sh" --help > "$TMP/o" 2>&1 || rc=$?
assert "run.sh --help documents --save-vault-recovery-keys" '--save-vault-recovery-keys +vault step' "$TMP/o"
rc=0; ENV_FILE=/dev/null bash "${ROOT}/scripts/run.sh" --hub install --targets terraform --expose-ui --save-vault-recovery-keys --dry-run > "$TMP/o" 2>&1 || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'steps/35-vault.sh' "$TMP/o"; then ok "the jumpbox command line is accepted (dry run)"
else bad "the jumpbox command line is accepted (dry run)" "exit $rc: $(cat "$TMP/o")"; fi

echo "== 11: run-fleet-setup.sh (run.sh detached)"
if ! command -v setsid >/dev/null || ! command -v yq >/dev/null || [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  skip "setsid, yq or bash 4 missing (on the jumpbox all three are installed)"
else
  R="$TMP/rfs"; mkdir -p "$R/bin" "$R/fleet/.git" "$R/.work"
  cp -R "${ROOT}/scripts" "$R/scripts"
  printf '#!/usr/bin/env bash\necho "run.sh $*"\necho "token ${GIT_PUSH_PAT:-unset}"\nexit 3\n' > "$R/scripts/run.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$R/bin/az"
  chmod 755 "$R/scripts/run.sh" "$R/bin/az"
  printf 'subscriptionId: s\nhub:\n  name: aks-hub\n  resourceGroup: rg\ntargets: []\n' > "$R/.work/inventory.yaml"
  printf 'export FLEET_LOCAL_DIR=%s\nexport INVENTORY=%s\n' "$R/fleet" "$R/.work/inventory.yaml" > "$R/env.jumpbox.sh"
  rc=0; env PATH="$R/bin:$PATH" ENV_FILE=/dev/null GIT_PUSH_PAT=from-env \
    bash "$R/scripts/jumpbox/run-fleet-setup.sh" --hub install --targets terraform > "$TMP/o" 2>&1 || rc=$?
  if [[ $rc -eq 3 ]] && grep -q 'run.sh --hub install --targets terraform' "$TMP/o"; then ok "follows the log and exits with run.sh's exit code"
  else bad "follows the log and exits with run.sh's exit code" "exit $rc: $(cat "$TMP/o")"; fi
  if grep -q 'token from-env' "$R/.work/fleet-setup/run.log"; then ok "run.sh inherits the exported tokens"
  else bad "run.sh inherits the exported tokens" "$(cat "$R/.work/fleet-setup/run.log" 2>/dev/null)"; fi
  if [[ "$(cat "$R/.work/fleet-setup/run.status" 2>/dev/null)" == 3 ]]; then ok "the exit code is recorded in run.status"
  else bad "the exit code is recorded in run.status"; fi
fi

echo
echo "jumpbox: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
