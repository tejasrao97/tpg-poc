#!/usr/bin/env bash
# Apply the tpg-fleet bootstrap (AppProjects tpg and tpg-hub, ApplicationSets,
# hub workflows Application) and the selected monitoring option to the hub.
source "$(dirname "$0")/../lib/common.sh"

require_cmd kubectl yq
require_inventory
require_env FLEET_LOCAL_DIR
HUB="$(hub_name)"
require_context "$HUB"
BOOT="${FLEET_LOCAL_DIR}/bootstrap"
MONITORING_OPTION="${MONITORING_OPTION:-none}"

[[ -d "$BOOT" ]] || die "bootstrap folder not found at $BOOT"
if grep -rq '<org>' "$BOOT"; then
  die "tpg-fleet still contains the <org> placeholder: run scripts/set-repo-url.sh in tpg-fleet, commit and push first"
fi
FLEET_FILE="${FLEET_LOCAL_DIR}/clusters/fleet.yaml"
[[ -f "$FLEET_FILE" ]] || die "tpg-fleet has no clusters/fleet.yaml"
for c in $(target_names); do
  C="$c" yq -e '.clusters | has(strenv(C))' "$FLEET_FILE" >/dev/null 2>&1 \
    || log "$c is not in clusters/fleet.yaml yet: no operator or instance Applications until tpg-day0 adds it"
done

log "Applying the AppProjects and ApplicationSets"
# tpg: the target Applications (synced by the workflows only); tpg-hub: the hub
# Applications (tpg-hub-workflows, tpg-hub-monitoring), which admins can sync
kubectl --context "$HUB" apply -f "$BOOT/project-tpg.yaml"
kubectl --context "$HUB" apply -f "$BOOT/project-tpg-hub.yaml"
kubectl --context "$HUB" apply -f "$BOOT/appsets/"
kubectl --context "$HUB" apply -f "$BOOT/app-hub-workflows.yaml"

case "$MONITORING_OPTION" in
  none) log "Monitoring option: none" ;;
  azure)
    log "Monitoring option: azure (Argo CD Applications)"
    kubectl --context "$HUB" apply -f "$BOOT/monitoring/azure/" ;;
  standalone) log "Monitoring option: standalone (Helm releases from the addons step; nothing to apply here)" ;;
  *) die "MONITORING_OPTION must be none, azure or standalone" ;;
esac

log "Waiting for the hub workflows Application to sync"
s=""
for _ in $(seq 1 60); do
  s="$(kubectl --context "$HUB" -n argocd get application tpg-hub-workflows \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [[ "$s" == "Synced/Healthy" ]] && { ok "tpg-hub-workflows $s"; break; }
  sleep 10
done
[[ "$s" == "Synced/Healthy" ]] || die "tpg-hub-workflows is $s; check it in the Argo CD UI"

kubectl --context "$HUB" -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
