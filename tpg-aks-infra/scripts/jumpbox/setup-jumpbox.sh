#!/usr/bin/env bash
# Installs the operator tools of tpg-aks-infra and tpg-fleet on the jumpbox.
#
# Terraform runs it, by jumpbox_setup_method (Round 19):
#   remote-exec  sudo ~/scripts/jumpbox/setup-jumpbox.sh over SSH
#                (terraform/jumpbox-provision.tf, terraform_data.jumpbox_setup);
#                it first waits, visibly, for the image's first boot (cloud-init)
#   cloud-init   cloud-init runs /home/<admin>/setup-jumpbox.sh once at first boot
#                (terraform/modules/jumpbox, TPG_FROM_CLOUD_INIT=1: no wait)
# At the end it records its own sha256 in /var/lib/tpg-jumpbox/setup-jumpbox.sha256;
# deploy-scripts/deploy.sh copy runs a newer version again.
# Running it again is safe: a tool whose pinned version is already installed is
# skipped, so after a version bump below only that tool is replaced.
#
# Every download is pinned to the version set below and checked with sha256
# before it is installed: against the checksum file the vendor publishes for
# that release (fetched over HTTPS), or, where the vendor publishes none, against
# a checksum recorded here. A missing or wrong checksum stops the script.
#
# --clone runs as the admin user (not root) and clones tpg-fleet and
# tpg-aks-infra into ~/src. The token comes from the environment only.
set -euo pipefail

# ---------------------------------------------------------------- versions
# run-time
AZURE_CLI_VERSION="2.90.0"     # packages.microsoft.com (apt or dnf)
KUBECTL_VERSION="1.35.8"       # kubectl of the workflow tools image alpine/k8s:1.35.8
HELM_VERSION="4.3.0"           # Helm 4, as in the workflow tools image
ARGO_VERSION="4.1.3"           # Argo Workflows on the hub
ARGOCD_VERSION="3.5.3"         # Argo CD on the hub
YQ_VERSION="4.47.2"            # mikefarah yq
TOFU_VERSION="1.9.1"           # the version the tests use
TERRAFORM_VERSION="1.14.9"     # TF_TOOL=terraform
VAULT_VERSION="2.0.4"          # the hub's Vault server; installed with --vault
KUBELOGIN_VERSION="0.2.17"
# tests (the versions the repositories' offline tests are run with)
SHELLCHECK_VERSION="0.10.0"
KUBECONFORM_VERSION="0.7.0"
KUSTOMIZE_VERSION="5.7.1"
YAMLLINT_VERSION="1.38.0"
PATHSPEC_VERSION="1.1.1"       # yamllint dependency
PYYAML_VERSION="6.0.3"         # yamllint dependency (its own virtualenv)
SETUP_ENVTEST_VERSION="0.22.5" # controller-runtime release that ships the binary
ENVTEST_K8S_VERSION="1.34.1"   # tpg-fleet tests/README.md: setup-envtest use 1.34.1
# extras
KUBECTX_VERSION="0.10.0"       # kubectx and kubens
FZF_VERSION="0.73.0"

# Checksums recorded from the release downloads, for vendors that publish no
# checksum file for these assets.
SHELLCHECK_SHA256="6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87"
SETUP_ENVTEST_SHA256="fb1af14fb4d17643dfc4884ddcc4e1f3fe33f25221a1e51cb36edaf37b35a7aa"
# sha256 of the wheels as listed by PyPI (pip --require-hashes)
YAMLLINT_WHEEL_SHA256="fc394a5b3be980a4062607b8fdddc0843f4fa394152b6da21722f5d59013c220"
PATHSPEC_WHEEL_SHA256="a00ce642f577bf7f473932318056212bc4f8bfdf53128c78bbd5af0b9b20b189"
PYYAML_CP310_SHA256="9c7708761fccb9397fe64bbc0395abcae8c4bf7b0eac081e12b809bf47700d0b"
PYYAML_CP312_SHA256="ba1cc08a7ccde2d2ec775841541641e4548226580ab850948cbfda66a1befcdc"
# Signing key of packages.microsoft.com (Azure CLI repository)
MICROSOFT_KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
MICROSOFT_KEY_FPR="BC528686B50D79E339D3721CEB3E94ADBE1229CF"

# ---------------------------------------------------------------- paths
BIN_DIR="/usr/local/bin"
STATE_DIR="/var/lib/tpg-jumpbox"            # <tool>.version of every verified install
YAMLLINT_VENV="/opt/tpg-jumpbox/yamllint"
ENVTEST_DIR="/usr/local/lib/tpg-envtest"
PROFILE_FILE="/etc/profile.d/tpg-jumpbox.sh"
COMPLETION_DIR="/etc/bash_completion.d"
LOCK_FILE="/run/tpg-jumpbox-setup.lock"
# Right after boot, apt-daily and unattended-upgrades may hold the dpkg lock: wait for it
APT_LOCK=(-o DPkg::Lock::Timeout=900)
GH="https://github.com"

usage() {
  cat <<EOF
Usage: setup-jumpbox.sh [--only GROUPS] [--vault] [--dry-run]
       setup-jumpbox.sh --clone

Installs the tools of tpg-aks-infra and tpg-fleet (run as root). Safe to re-run.

  --only GROUPS  comma list of run-time, tests, extras (default: all three)
                   run-time  az, kubectl, helm, argo, argocd, yq, jq, git, curl,
                             openssl, tofu or terraform, kubelogin
                   tests     python3 + PyYAML, shellcheck, kubeconform, kustomize,
                             yamllint, envtest (etcd, kube-apiserver) with
                             KUBEBUILDER_ASSETS in ${PROFILE_FILE}
                   extras    kubectx, kubens, fzf, tmux, bash completion
  --vault        also install the HashiCorp Vault CLI (run-time group)
  --dry-run      print the plan (OS, package manager, packages, tools, versions,
                 URLs, checksum sources) and change nothing; no root needed
  --clone        clone tpg-fleet and tpg-aks-infra into \${CLONE_DIR:-\$HOME/src};
                 run as the admin user, not root. Installs nothing.
  -h, --help     this help

Environment:
  TF_TOOL           tofu (default) or terraform
  OS_RELEASE_FILE   os-release file to read (default /etc/os-release)
  --clone reads:    FLEET_REPO_URL, INFRA_REPO_URL (https URLs), and for private
                    repositories GITHUB_USER and GIT_READ_PAT, exported in the
                    shell. The token is handed to git through a temporary
                    GIT_ASKPASS script that reads the environment; it is never
                    written to a file, a command line or the git configuration.
EOF
}

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
step() { log "==> $*"; }
die()  { printf 'setup-jumpbox: ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- options
GROUPS_SELECTED="run-time,tests,extras"
WITH_VAULT=false
DRY_RUN=false
CLONE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)    [[ $# -ge 2 ]] || die "--only needs a value"; GROUPS_SELECTED="$2"; shift 2 ;;
    --only=*)  GROUPS_SELECTED="${1#*=}"; shift ;;
    --vault)   WITH_VAULT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --clone)   CLONE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "unknown option: $1" ;;
  esac
done

IFS=',' read -r -a GROUP_LIST <<<"$GROUPS_SELECTED"
[[ ${#GROUP_LIST[@]} -gt 0 ]] || die "--only needs at least one group"
for g in "${GROUP_LIST[@]}"; do
  case "$g" in run-time|tests|extras) ;; *) die "unknown group '$g' (run-time, tests, extras)" ;; esac
done
want() { [[ ",${GROUPS_SELECTED}," == *",$1,"* ]]; }

TF_TOOL="${TF_TOOL:-tofu}"
case "$TF_TOOL" in tofu|terraform) ;; *) die "TF_TOOL must be tofu or terraform, not '$TF_TOOL'" ;; esac

# ---------------------------------------------------------------- --clone
clone_repos() {
  [[ $EUID -ne 0 ]] || die "--clone clones into the admin user's home: run it as that user, without sudo"
  command -v git >/dev/null || die "git is not installed: run 'sudo $0 --only run-time' first"
  [[ -n "${FLEET_REPO_URL:-}" ]] || die "export FLEET_REPO_URL (https URL of tpg-fleet)"
  [[ -n "${INFRA_REPO_URL:-}" ]] || die "export INFRA_REPO_URL (https URL of tpg-aks-infra)"
  local url
  for url in "$FLEET_REPO_URL" "$INFRA_REPO_URL"; do
    [[ "$url" == https://* ]] || die "$url: use an https URL (the token is sent over HTTPS only)"
    [[ ! "$url" =~ ^https://[^/]*@ ]] || die "$url: remove the credentials from the URL; export GITHUB_USER and GIT_READ_PAT instead"
  done

  local dest name
  ASKPASS_DIR=""
  if [[ -n "${GIT_READ_PAT:-}" ]]; then
    [[ -n "${GITHUB_USER:-}" ]] || die "GIT_READ_PAT is set but GITHUB_USER is not: export both"
    # The script holds variable names, not values: git passes its environment
    # (the exported GITHUB_USER and GIT_READ_PAT) to the askpass program.
    ASKPASS_DIR="$(mktemp -d)"
    trap 'rm -rf "${ASKPASS_DIR:?}"' EXIT
    # shellcheck disable=SC2016  # expanded by the askpass script, from its environment
    printf '#!/bin/sh\ncase "$1" in Username*) printf "%%s\\n" "$GITHUB_USER" ;; *) printf "%%s\\n" "$GIT_READ_PAT" ;; esac\n' \
      > "$ASKPASS_DIR/askpass"
    chmod 700 "$ASKPASS_DIR/askpass"
  else
    log "GIT_READ_PAT is not set: cloning without credentials (public repositories only)"
  fi

  dest="${CLONE_DIR:-$HOME/src}"
  mkdir -p "$dest"
  for url in "$FLEET_REPO_URL" "$INFRA_REPO_URL"; do
    name="$(basename "${url%/}" .git)"
    if [[ -d "$dest/$name/.git" ]]; then
      log "$dest/$name exists: left as it is (git -C $dest/$name pull to update)"
      continue
    fi
    step "clone $url into $dest/$name"
    # credential.helper= : no configured helper may store the token
    if [[ -n "$ASKPASS_DIR" ]]; then
      GIT_ASKPASS="$ASKPASS_DIR/askpass" GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone -q -- "$url" "$dest/$name" \
        || die "git clone $url failed (check the URL, GITHUB_USER and that GIT_READ_PAT can read the repository)"
    else
      GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone -q -- "$url" "$dest/$name" \
        || die "git clone $url failed (a private repository needs GITHUB_USER and GIT_READ_PAT exported)"
    fi
  done
  if [[ -n "$ASKPASS_DIR" ]]; then rm -rf "${ASKPASS_DIR:?}"; trap - EXIT; fi
  log "done. For tpg-aks-infra/env.sh: FLEET_LOCAL_DIR=$dest/$(basename "${FLEET_REPO_URL%/}" .git)"
}

if $CLONE; then
  clone_repos
  exit 0
fi

# ---------------------------------------------------------------- OS
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
detect_os() {
  [[ -r "$OS_RELEASE_FILE" ]] || die "cannot read $OS_RELEASE_FILE"
  OS_ID="" OS_VERSION_ID="" OS_CODENAME="" OS_NAME=""
  local k v
  while IFS='=' read -r k v; do
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$k" in
      ID) OS_ID="$v" ;;
      VERSION_ID) OS_VERSION_ID="$v" ;;
      VERSION_CODENAME) OS_CODENAME="$v" ;;
      PRETTY_NAME) OS_NAME="$v" ;;
    esac
  done < "$OS_RELEASE_FILE"
  case "$OS_ID:$OS_VERSION_ID" in
    ubuntu:22.04|ubuntu:24.04)
      PM=apt
      [[ -n "$OS_CODENAME" ]] || die "$OS_RELEASE_FILE has no VERSION_CODENAME" ;;
    rhel:9|rhel:9.*|rocky:9|rocky:9.*)
      PM=dnf ;;
    *)
      die "unsupported OS '${OS_NAME:-$OS_ID $OS_VERSION_ID}': supported are Ubuntu 22.04 and 24.04, RHEL 9 and Rocky Linux 9" ;;
  esac
}

# Distribution packages, verified by the package manager's signed repositories.
packages() {
  local -a p
  if [[ $PM == apt ]]; then
    p=(ca-certificates curl git jq openssl tar gzip unzip xz-utils gnupg python3)
    want tests  && p+=(python3-yaml python3-venv)
    want extras && p+=(bash-completion tmux)
  else
    # RHEL 9 images ship curl-minimal, which conflicts with the curl package.
    p=(ca-certificates git jq openssl tar gzip unzip xz gnupg2 python3)
    command -v curl >/dev/null 2>&1 || p+=(curl)
    # yamllint 1.38 needs Python 3.10 or later; RHEL 9's python3 is 3.9.
    want tests  && p+=(python3-pyyaml python3.12 python3.12-pip)
    want extras && p+=(bash-completion tmux)
  fi
  printf '%s\n' "${p[@]}"
}

yamllint_python() { if [[ $PM == apt ]]; then echo python3; else echo python3.12; fi; }

# ---------------------------------------------------------------- tool table
# spec TOOL sets:
#   S_GROUP S_VERSION S_URL
#   S_SUM     checksum source: vendor:<url> (checksum file of the release),
#             vendor-yq:<url> (yq's multi-hash file), sha256:<hex> (recorded here),
#             repo-key:<fingerprint> (signed package repository),
#             pypi:<hashes> (pip --require-hashes), index:<url> (setup-envtest
#             checks the sha512 of the archive against controller-tools' index)
#   S_ASSET   file name in the checksum file
#   S_MEMBER  path of the binary inside the archive (empty: the download is the binary)
#   S_BIN     installed name in BIN_DIR
spec() {
  S_MEMBER="" S_ASSET="" S_BIN="$1"
  case "$1" in
    azure-cli)
      S_GROUP=run-time S_VERSION=$AZURE_CLI_VERSION S_BIN=az
      if [[ $PM == apt ]]; then S_URL="https://packages.microsoft.com/repos/azure-cli/dists/${OS_CODENAME}/"
      else S_URL="https://packages.microsoft.com/rhel/9.0/prod/"; fi
      S_SUM="repo-key:${MICROSOFT_KEY_FPR}" ;;
    kubectl)
      S_GROUP=run-time S_VERSION=$KUBECTL_VERSION
      S_URL="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
      S_ASSET=kubectl S_SUM="vendor:${S_URL}.sha256" ;;
    helm)
      S_GROUP=run-time S_VERSION=$HELM_VERSION S_ASSET="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
      S_URL="https://get.helm.sh/${S_ASSET}" S_SUM="vendor:${S_URL}.sha256sum" S_MEMBER=linux-amd64/helm ;;
    argo)
      S_GROUP=run-time S_VERSION=$ARGO_VERSION S_ASSET=argo-linux-amd64.gz
      S_URL="${GH}/argoproj/argo-workflows/releases/download/v${ARGO_VERSION}/${S_ASSET}"
      S_SUM="vendor:${GH}/argoproj/argo-workflows/releases/download/v${ARGO_VERSION}/argo-workflows-cli-checksums.txt"
      S_MEMBER=argo-linux-amd64 ;;
    argocd)
      S_GROUP=run-time S_VERSION=$ARGOCD_VERSION S_ASSET=argocd-linux-amd64
      S_URL="${GH}/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/${S_ASSET}"
      S_SUM="vendor:${GH}/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/cli_checksums.txt" ;;
    yq)
      S_GROUP=run-time S_VERSION=$YQ_VERSION S_ASSET=yq_linux_amd64
      S_URL="${GH}/mikefarah/yq/releases/download/v${YQ_VERSION}/${S_ASSET}"
      S_SUM="vendor-yq:${GH}/mikefarah/yq/releases/download/v${YQ_VERSION}/checksums" ;;
    tofu)
      S_GROUP=run-time S_VERSION=$TOFU_VERSION S_ASSET="tofu_${TOFU_VERSION}_linux_amd64.tar.gz"
      S_URL="${GH}/opentofu/opentofu/releases/download/v${TOFU_VERSION}/${S_ASSET}"
      S_SUM="vendor:${GH}/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS"
      S_MEMBER=tofu ;;
    terraform)
      S_GROUP=run-time S_VERSION=$TERRAFORM_VERSION S_ASSET="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
      S_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${S_ASSET}"
      S_SUM="vendor:https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
      S_MEMBER=terraform ;;
    vault)
      S_GROUP=run-time S_VERSION=$VAULT_VERSION S_ASSET="vault_${VAULT_VERSION}_linux_amd64.zip"
      S_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/${S_ASSET}"
      S_SUM="vendor:https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS"
      S_MEMBER=vault ;;
    kubelogin)
      S_GROUP=run-time S_VERSION=$KUBELOGIN_VERSION S_ASSET=kubelogin-linux-amd64.zip
      S_URL="${GH}/Azure/kubelogin/releases/download/v${KUBELOGIN_VERSION}/${S_ASSET}"
      S_SUM="vendor:${S_URL}.sha256" S_MEMBER=bin/linux_amd64/kubelogin ;;
    shellcheck)
      S_GROUP=tests S_VERSION=$SHELLCHECK_VERSION S_ASSET="shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
      S_URL="${GH}/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${S_ASSET}"
      S_SUM="sha256:${SHELLCHECK_SHA256}" S_MEMBER="shellcheck-v${SHELLCHECK_VERSION}/shellcheck" ;;
    kubeconform)
      S_GROUP=tests S_VERSION=$KUBECONFORM_VERSION S_ASSET=kubeconform-linux-amd64.tar.gz
      S_URL="${GH}/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/${S_ASSET}"
      S_SUM="vendor:${GH}/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/CHECKSUMS" S_MEMBER=kubeconform ;;
    kustomize)
      S_GROUP=tests S_VERSION=$KUSTOMIZE_VERSION S_ASSET="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
      S_URL="${GH}/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/${S_ASSET}"
      S_SUM="vendor:${GH}/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/checksums.txt"
      S_MEMBER=kustomize ;;
    yamllint)
      S_GROUP=tests S_VERSION=$YAMLLINT_VERSION
      S_URL="https://pypi.org/project/yamllint/${YAMLLINT_VERSION}/"   # wheels of yamllint, pathspec, PyYAML
      S_SUM="pypi:yamllint=${YAMLLINT_WHEEL_SHA256},pathspec=${PATHSPEC_WHEEL_SHA256},pyyaml=${PYYAML_CP310_SHA256}|${PYYAML_CP312_SHA256}" ;;
    setup-envtest)
      S_GROUP=tests S_VERSION=$SETUP_ENVTEST_VERSION S_ASSET=setup-envtest-linux-amd64
      S_URL="${GH}/kubernetes-sigs/controller-runtime/releases/download/v${SETUP_ENVTEST_VERSION}/${S_ASSET}"
      S_SUM="sha256:${SETUP_ENVTEST_SHA256}" ;;
    envtest)
      S_GROUP=tests S_VERSION=$ENVTEST_K8S_VERSION S_BIN=""
      S_URL="${GH}/kubernetes-sigs/controller-tools/releases/download/envtest-v${ENVTEST_K8S_VERSION}/envtest-v${ENVTEST_K8S_VERSION}-linux-amd64.tar.gz"
      S_SUM="index:https://raw.githubusercontent.com/kubernetes-sigs/controller-tools/HEAD/envtest-releases.yaml" ;;
    kubectx|kubens)
      S_GROUP=extras S_VERSION=$KUBECTX_VERSION S_ASSET="${1}_v${KUBECTX_VERSION}_linux_x86_64.tar.gz"
      S_URL="${GH}/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/${S_ASSET}"
      S_SUM="vendor:${GH}/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/checksums.txt" S_MEMBER="$1" ;;
    fzf)
      S_GROUP=extras S_VERSION=$FZF_VERSION S_ASSET="fzf-${FZF_VERSION}-linux_amd64.tar.gz"
      S_URL="${GH}/junegunn/fzf/releases/download/v${FZF_VERSION}/${S_ASSET}"
      S_SUM="vendor:${GH}/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf_${FZF_VERSION}_checksums.txt" S_MEMBER=fzf ;;
    *) die "internal: no spec for $1" ;;
  esac
}

selected_tools() {
  if want run-time; then
    echo azure-cli kubectl helm argo argocd yq "$TF_TOOL" kubelogin
    if $WITH_VAULT; then echo vault; fi
  fi
  if want tests; then echo shellcheck kubeconform kustomize yamllint setup-envtest envtest; fi
  if want extras; then echo kubectx kubens fzf; fi
}

# ---------------------------------------------------------------- dry run
dry_run() {
  local t
  echo "os: ${OS_NAME:-$OS_ID $OS_VERSION_ID} (id=${OS_ID} version=${OS_VERSION_ID}${OS_CODENAME:+ codename=$OS_CODENAME})"
  echo "package manager: ${PM}"
  echo "groups: ${GROUPS_SELECTED}"
  echo "tf tool: ${TF_TOOL}"
  echo "vault cli: $($WITH_VAULT && echo yes || echo 'no (--vault)')"
  [[ "$(uname -m)" == x86_64 ]] || echo "note: this host is $(uname -m); the install needs x86_64"
  echo "packages: $(packages | tr '\n' ' ')"
  for t in $(selected_tools); do
    spec "$t"
    printf 'tool=%s group=%s version=%s url=%s checksum=%s\n' "$t" "$S_GROUP" "$S_VERSION" "$S_URL" "$S_SUM"
  done
  if want tests; then
    echo "profile: ${PROFILE_FILE} sets KUBEBUILDER_ASSETS=${ENVTEST_DIR}/k8s/${ENVTEST_K8S_VERSION}-linux-amd64"
  fi
  if want extras; then
    echo "completion: ${COMPLETION_DIR}/{kubectl,helm,argo,argocd}"
  fi
  echo "dry run: nothing downloaded or changed"
}

# ---------------------------------------------------------------- install helpers
WORK=""
cleanup() { if [[ -n "$WORK" ]]; then rm -rf "${WORK:?}"; fi; }

download() { # URL OUT
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1" \
    || die "download failed: $1"
}

# expected_sha256 SUMSPEC ASSET: prints the sha256 the file must have
expected_sha256() {
  local kind="${1%%:*}" ref="${1#*:}" asset="$2" sums="$WORK/sums" sha="" col
  case "$kind" in
    sha256) sha="$ref" ;;
    vendor)
      download "$ref" "$sums"
      # "<sha>  <file>" lines (a leading * marks binary mode), or one bare sha
      sha="$(awk -v f="$asset" '
        NF == 1 { bare = $1; lines++; next }
        NF >= 2 { lines++; n = $2; sub(/^[*]/, "", n); sub(/^[.]\//, "", n)
                  if (n == f) { print $1; found = 1; exit } }
        END { if (!found && lines == 1 && bare != "") print bare }' "$sums")" ;;
    vendor-yq)
      # One line per file with many hashes; checksums_hashes_order names the columns.
      download "$ref" "$sums"
      download "${ref%/*}/checksums_hashes_order" "$sums.order"
      col="$(grep -nx 'SHA-256' "$sums.order" | cut -d: -f1)"
      [[ -n "$col" ]] || die "no SHA-256 column in ${ref%/*}/checksums_hashes_order"
      sha="$(awk -v f="$asset" -v c="$((col + 1))" '$1 == f { print $c; exit }' "$sums")" ;;
    *) die "internal: $kind is not a download checksum source" ;;
  esac
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 for ${asset} in ${ref} (got '${sha}'); refusing to install it"
  printf '%s\n' "$sha"
}

installed_version() { cat "$STATE_DIR/$1.version" 2>/dev/null || true; }
mark_installed() { printf '%s\n' "$2" > "$STATE_DIR/$1.version"; }

is_current() { # TOOL (after spec)
  [[ "$(installed_version "$1")" == "$S_VERSION" ]] && { [[ -z "$S_BIN" ]] || [[ -x "$BIN_DIR/$S_BIN" ]]; }
}

# install_binary TOOL: download, verify, unpack and install one binary
install_binary() {
  local tool="$1" file sha got dir
  spec "$tool"
  if is_current "$tool"; then log "$tool $S_VERSION already installed"; return; fi
  step "$tool $S_VERSION"
  file="$WORK/${S_ASSET:-$tool}"
  download "$S_URL" "$file"
  sha="$(expected_sha256 "$S_SUM" "${S_ASSET:-$tool}")"
  got="$(sha256sum "$file" | cut -d' ' -f1)"
  [[ "$got" == "$sha" ]] || die "sha256 mismatch for $S_URL: expected $sha, got $got"
  log "   sha256 ok ($sha)"
  dir="$WORK/unpack-$tool"; mkdir -p "$dir"
  case "$file" in
    *.tar.gz|*.tar.xz) tar -xf "$file" -C "$dir" ;;
    *.zip)             unzip -q -o "$file" -d "$dir" ;;
    *.gz)              gunzip -c "$file" > "$dir/$S_MEMBER" ;;
    *)                 cp "$file" "$dir/$tool"; S_MEMBER="$tool" ;;
  esac
  [[ -f "$dir/$S_MEMBER" ]] || die "$S_MEMBER not found in $S_ASSET"
  install -m 0755 "$dir/$S_MEMBER" "$BIN_DIR/$S_BIN"
  mark_installed "$tool" "$S_VERSION"
}

install_packages() {
  local -a p
  mapfile -t p < <(packages)
  step "packages ($PM): ${p[*]}"
  if [[ $PM == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get "${APT_LOCK[@]}" update -q
    apt-get "${APT_LOCK[@]}" install -y -q --no-install-recommends "${p[@]}"
  else
    dnf install -y -q "${p[@]}"
  fi
}

# The fingerprint of the downloaded key must be the pinned one before any
# package from the repository is trusted.
fetch_microsoft_key() { # OUT
  local gnupg fprs
  download "$MICROSOFT_KEY_URL" "$1"
  gnupg="$WORK/gnupg"; mkdir -m 700 "$gnupg"
  fprs="$(GNUPGHOME="$gnupg" gpg --batch --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }')"
  [[ "$fprs" == "$MICROSOFT_KEY_FPR" ]] \
    || die "$MICROSOFT_KEY_URL has fingerprint(s) '${fprs//$'\n'/ }', expected $MICROSOFT_KEY_FPR; refusing to add the repository"
  log "   key fingerprint ok ($MICROSOFT_KEY_FPR)"
}

install_azure_cli() {
  local have
  spec azure-cli
  if [[ $PM == apt ]]; then have="$(dpkg-query -W -f='${Version}' azure-cli 2>/dev/null || true)"; have="${have%%-*}"
  else have="$(rpm -q --qf '%{VERSION}' azure-cli 2>/dev/null || true)"; fi
  if [[ "$have" == "$AZURE_CLI_VERSION" ]]; then log "azure-cli $AZURE_CLI_VERSION already installed"; return; fi
  step "azure-cli $AZURE_CLI_VERSION (packages.microsoft.com)"
  if [[ $PM == apt ]]; then
    fetch_microsoft_key "$WORK/microsoft.asc"
    install -d -m 0755 /etc/apt/keyrings
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft.gpg "$WORK/microsoft.asc"
    chmod 0644 /etc/apt/keyrings/microsoft.gpg
    cat > /etc/apt/sources.list.d/azure-cli.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${OS_CODENAME}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF
    apt-get "${APT_LOCK[@]}" update -q
    apt-get "${APT_LOCK[@]}" install -y -q --no-install-recommends --allow-downgrades "azure-cli=${AZURE_CLI_VERSION}-1~${OS_CODENAME}"
  else
    fetch_microsoft_key "$WORK/microsoft.asc"
    install -m 0644 "$WORK/microsoft.asc" /etc/pki/rpm-gpg/tpg-microsoft.asc
    rpm --import /etc/pki/rpm-gpg/tpg-microsoft.asc
    cat > /etc/yum.repos.d/tpg-azure-cli.repo <<'EOF'
[tpg-azure-cli]
name=Azure CLI (packages.microsoft.com)
baseurl=https://packages.microsoft.com/rhel/9.0/prod/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/tpg-microsoft.asc
includepkgs=azure-cli
EOF
    if [[ -n "$have" ]]; then dnf remove -y -q azure-cli; fi
    dnf install -y -q "azure-cli-${AZURE_CLI_VERSION}"
  fi
}

install_yamllint() {
  local py req
  spec yamllint
  if is_current yamllint; then log "yamllint $YAMLLINT_VERSION already installed"; return; fi
  step "yamllint $YAMLLINT_VERSION (virtualenv $YAMLLINT_VENV, pip --require-hashes)"
  py="$(yamllint_python)"
  command -v "$py" >/dev/null || die "$py not found (package list above)"
  rm -rf "${YAMLLINT_VENV:?}"
  "$py" -m venv "$YAMLLINT_VENV"
  req="$WORK/yamllint-requirements.txt"
  cat > "$req" <<EOF
yamllint==${YAMLLINT_VERSION} --hash=sha256:${YAMLLINT_WHEEL_SHA256}
pathspec==${PATHSPEC_VERSION} --hash=sha256:${PATHSPEC_WHEEL_SHA256}
pyyaml==${PYYAML_VERSION} --hash=sha256:${PYYAML_CP310_SHA256} --hash=sha256:${PYYAML_CP312_SHA256}
EOF
  PIP_DISABLE_PIP_VERSION_CHECK=1 "$YAMLLINT_VENV/bin/pip" install -q --no-deps --only-binary=:all: --require-hashes -r "$req" \
    || die "pip install of yamllint failed (a hash mismatch also ends here)"
  ln -sfn "$YAMLLINT_VENV/bin/yamllint" "$BIN_DIR/yamllint"
  mark_installed yamllint "$YAMLLINT_VERSION"
}

ENVTEST_PATH="${ENVTEST_DIR}/k8s/${ENVTEST_K8S_VERSION}-linux-amd64"
install_envtest() {
  local path
  spec envtest
  if is_current envtest && [[ -x "$ENVTEST_PATH/kube-apiserver" ]]; then
    log "envtest $ENVTEST_K8S_VERSION already installed"
  else
    step "envtest $ENVTEST_K8S_VERSION (etcd, kube-apiserver) with setup-envtest"
    # setup-envtest checks the archive's sha512 against controller-tools' index.
    path="$("$BIN_DIR/setup-envtest" use "$ENVTEST_K8S_VERSION" --bin-dir "$ENVTEST_DIR" -p path)" \
      || die "setup-envtest use $ENVTEST_K8S_VERSION failed"
    [[ "$path" == "$ENVTEST_PATH" ]] || die "setup-envtest installed to $path, expected $ENVTEST_PATH"
    chmod -R a+rX "$ENVTEST_DIR"
    mark_installed envtest "$ENVTEST_K8S_VERSION"
  fi
  cat > "$PROFILE_FILE" <<EOF
# Written by setup-jumpbox.sh: envtest binaries for tpg-fleet tests/admission.
export KUBEBUILDER_ASSETS="${ENVTEST_PATH}"
EOF
  chmod 0644 "$PROFILE_FILE"
}

install_completions() {
  local t
  step "bash completion in $COMPLETION_DIR"
  install -d -m 0755 "$COMPLETION_DIR"
  for t in kubectl helm argo argocd; do
    if command -v "$t" >/dev/null 2>&1; then
      "$t" completion bash > "$COMPLETION_DIR/$t" 2>/dev/null || die "$t completion bash failed"
      chmod 0644 "$COMPLETION_DIR/$t"
    fi
  done
}

reported_version() { # TOOL: first line of the tool's own version output
  case "$1" in
    azure-cli)      az version --query '"azure-cli"' -o tsv ;;
    kubectl)        kubectl version --client ;;
    helm)           helm version --short ;;
    argo)           argo version --short ;;
    argocd)         argocd version --client --short ;;
    tofu|terraform|vault|kustomize) "$1" version ;;
    kubelogin)      kubelogin --version | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' ;;
    shellcheck)     shellcheck --version | sed -n 2p ;;
    kubeconform)    kubeconform -v ;;
    envtest)        "$ENVTEST_PATH/kube-apiserver" --version ;;
    tmux)           tmux -V ;;
    openssl)        openssl version ;;
    yq|yamllint|fzf|jq|git|python3) "$1" --version ;;
    *)              echo "(no version command; pinned version installed)" ;;
  esac 2>/dev/null | head -n 1 || true
}

summary() {
  local t
  echo
  echo "Installed versions"
  printf '  %-14s %-10s %s\n' TOOL PINNED REPORTED
  local v
  for t in $(selected_tools); do
    spec "$t"
    v="$(reported_version "$t")"
    printf '  %-14s %-10s %s\n' "$t" "$S_VERSION" "${v:-NOT FOUND}"
  done
  for t in jq git openssl python3 tmux; do
    command -v "$t" >/dev/null 2>&1 || continue
    printf '  %-14s %-10s %s\n' "$t" "(os)" "$(reported_version "$t")"
  done
  if want tests; then echo "  KUBEBUILDER_ASSETS=${ENVTEST_PATH} (${PROFILE_FILE}; new login shells)"; fi
}

# ---------------------------------------------------------------- main
detect_os
if $DRY_RUN; then dry_run; exit 0; fi

[[ $EUID -eq 0 ]] || die "run as root (sudo $0), or use --dry-run"
[[ "$(uname -m)" == x86_64 ]] || die "only x86_64 is supported (this host: $(uname -m))"
export HOME="${HOME:-/root}"   # a cloud-init runcmd starts without HOME (jumpbox_setup_method cloud-init)
export PATH="${BIN_DIR}:${PATH}"

# remote-exec right after the VM starts: the image's own cloud-init (the admin
# user, the package mirrors) may still run. Skipped when cloud-init runs us.
if [[ "${TPG_FROM_CLOUD_INIT:-0}" != 1 ]] && command -v cloud-init >/dev/null 2>&1; then
  log "waiting for the first boot to finish (cloud-init status --wait)"
  cloud-init status --wait 2>&1 || true
fi

exec 9>"$LOCK_FILE"
flock -n 9 || die "another setup-jumpbox.sh is running (Terraform remote-exec, cloud-init at first boot, or deploy.sh copy)"

WORK="$(mktemp -d)"
trap cleanup EXIT
install -d -m 0755 "$STATE_DIR" "$BIN_DIR"
log "setup-jumpbox: ${OS_NAME:-$OS_ID $OS_VERSION_ID}, $PM, groups ${GROUPS_SELECTED}, TF_TOOL=${TF_TOOL}"

install_packages
for t in $(selected_tools); do
  case "$t" in
    azure-cli) install_azure_cli ;;
    yamllint)  install_yamllint ;;
    envtest)   install_envtest ;;
    *)         install_binary "$t" ;;
  esac
done
if want extras; then install_completions; fi
summary
# deploy-scripts/deploy.sh copy compares this with its own copy of the script.
# Only a full run (all three groups) counts: --only run-time leaves tests and
# extras out, which copy would otherwise take for installed.
if want run-time && want tests && want extras; then
  sha256sum "$(readlink -f "$0")" | awk '{print $1}' > "${STATE_DIR}/setup-jumpbox.sha256"
fi
log "setup-jumpbox: done"
