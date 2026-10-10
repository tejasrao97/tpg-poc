#!/usr/bin/env bash
# Build .work/kubeconfig with one context per cluster, named after the cluster.
#   access: az          az aks get-credentials (--admin, or kubelogin when adminCredentials: false);
#                       the <cluster>-admin context that --admin creates is renamed to <cluster>
#   access: kubeconfig  copy the named context from an existing kubeconfig file
source "$(dirname "$0")/../lib/common.sh"

require_cmd kubectl yq
require_inventory
touch "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

for c in $(all_clusters); do
  access="$(cluster_field "$c" access az)"
  log "Credentials for $c ($access)"
  case "$access" in
    az)
      require_cmd az
      rg="$(cluster_field "$c" resourceGroup)"
      args=(--subscription "$(subscription)" --resource-group "$rg" --name "$c"
            --context "$c" --file "$KUBECONFIG" --overwrite-existing --only-show-errors)
      if [[ "$(cluster_field "$c" adminCredentials true)" == "true" ]]; then
        # With --admin, az renames the merged context to <context>-admin even when
        # --context is set (the admin rename runs after the --context override).
        # Rename it back so every script can use the cluster name as the context.
        kubectl config delete-context "$c" >/dev/null 2>&1 || true
        kubectl config delete-context "${c}-admin" >/dev/null 2>&1 || true
        az aks get-credentials "${args[@]}" --admin
        kubectl config get-contexts "${c}-admin" >/dev/null 2>&1 \
          || die "$c: az aks get-credentials --admin did not create context ${c}-admin"
        kubectl config rename-context "${c}-admin" "$c" >/dev/null
        kubectl config use-context "$c" >/dev/null
      else
        require_cmd kubelogin
        az aks get-credentials "${args[@]}"
        kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG" --context "$c"
      fi
      ;;
    kubeconfig)
      src="$(cluster_field "$c" kubeconfig)"; src="${src/#\~/$HOME}"
      ctx="$(cluster_field "$c" context)"
      [[ -f "$src" && -n "$ctx" ]] || die "$c: kubeconfig '$src' or context '$ctx' is missing"
      tmp="${WORK_DIR}/$c.import"
      kubectl config view --raw --flatten --minify --kubeconfig "$src" --context "$ctx" > "$tmp"
      # Rename cluster, user and context to the inventory name to avoid clashes.
      yq -i "
        .clusters[0].name = \"$c\" | .users[0].name = \"$c-user\" |
        .contexts[0].name = \"$c\" | .contexts[0].context.cluster = \"$c\" |
        .contexts[0].context.user = \"$c-user\" | .[\"current-context\"] = \"$c\"" "$tmp"
      kubectl config delete-context "$c" >/dev/null 2>&1 || true
      KUBECONFIG="${KUBECONFIG}:${tmp}" kubectl config view --raw --flatten > "${WORK_DIR}/kubeconfig.merged"
      mv "${WORK_DIR}/kubeconfig.merged" "$KUBECONFIG"
      chmod 600 "$KUBECONFIG"
      rm -f "$tmp"
      ;;
    *) die "$c: access must be az or kubeconfig" ;;
  esac
  kubectl --context "$c" get --raw=/readyz >/dev/null \
    || die "cannot reach the API server of $c (authorized IP ranges? VPN?)"
  ok "$c reachable"
done
log "Kubeconfig written to $KUBECONFIG (export KUBECONFIG=$KUBECONFIG to use it)"
