#!/usr/bin/env bash
# PLS-077: guide steps 4.2 and 4.3 — read access for the worker identity (id-axopulse-worker).
# Run in Azure Cloud Shell (bash) by the admin each part needs:
#
#   ./grant-access.sh power-platform <worker-client-id>             # 4.2, Power Platform administrator
#   ./grant-access.sh graph <worker-client-id> [--licenses] [--auditlog]
#                                                                    # 4.3, Global Admin / Privileged Role Admin
#   ./grant-access.sh show <worker-client-id>                       # what the identity has now
#   ./grant-access.sh remove <worker-client-id>                     # take everything away again
#
# Idempotent: granting something that is already there is skipped. Uses `az rest`, so no token
# is ever printed or written to disk.
set -euo pipefail

# Power Platform
PP_ADMIN_APPS="https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/adminApplications"
PP_ADMIN_VERSION="2020-06-01"
PP_ROLES="https://api.powerplatform.com/authorization/roleAssignments"
PP_ROLES_VERSION="2024-10-01"
PP_READER_ROLE="c886ad2e-27f7-4874-8381-5849b8d8a090" # "Power Platform reader", same id in every tenant

# Entra resource apps and their application permissions
LOG_ANALYTICS_API="ca7f3f0b-7d91-482c-8e09-c5d840d0eac5"
GRAPH_API="00000003-0000-0000-c000-000000000000"
GRAPH="https://graph.microsoft.com/v1.0"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[[ $# -ge 2 ]] || usage
ACTION="$1" CLIENT_ID="$2"; shift 2
[[ "$CLIENT_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] \
  || { echo "'$CLIENT_ID' is not a client ID (GUID)." >&2; exit 2; }
WITH_LICENSES=false WITH_AUDITLOG=false
for arg in "$@"; do
  case "$arg" in
    --licenses) WITH_LICENSES=true ;; --auditlog) WITH_AUDITLOG=true ;; *) usage ;;
  esac
done

TENANT="$(az account show --query tenantId -o tsv)"
WORKER_SP="$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null)" \
  || { echo "No identity with client ID $CLIENT_ID in this tenant — use workerIdentityClientId from step 3.3." >&2; exit 1; }
WORKER_NAME="$(az ad sp show --id "$CLIENT_ID" --query displayName -o tsv)"
echo "Identity: $WORKER_NAME ($CLIENT_ID) in tenant $TENANT"

# ------------------------------------------------------------------ Power Platform (4.2)

pp_registered() {
  az rest --method get --resource https://service.powerapps.com/ \
    --url "$PP_ADMIN_APPS?api-version=$PP_ADMIN_VERSION" \
    --query "value[?applicationId=='$CLIENT_ID'] | length(@)" -o tsv
}

pp_reader_id() {
  az rest --method get --resource https://api.powerplatform.com \
    --url "$PP_ROLES?api-version=$PP_ROLES_VERSION" \
    --query "value[?principalObjectId=='$WORKER_SP' && roleDefinitionId=='$PP_READER_ROLE'].roleAssignmentId | [0]" -o tsv
}

grant_power_platform() {
  if [[ "$(pp_registered)" != "0" ]]; then
    echo "  = management app registration: already there"
  else
    az rest --method put --resource https://service.powerapps.com/ \
      --url "$PP_ADMIN_APPS/$CLIENT_ID?api-version=$PP_ADMIN_VERSION" --headers "Content-Length=0" >/dev/null
    echo "  + management app registration"
  fi
  if [[ -n "$(pp_reader_id)" ]]; then
    echo "  = Power Platform reader: already there"
  else
    az rest --method post --resource https://api.powerplatform.com \
      --url "$PP_ROLES?api-version=$PP_ROLES_VERSION" \
      --body "{\"roleDefinitionId\":\"$PP_READER_ROLE\",\"principalObjectId\":\"$WORKER_SP\",\"principalType\":\"ApplicationUser\",\"scope\":\"/tenants/$TENANT\"}" >/dev/null
    echo "  + Power Platform reader (tenant scope, read only)"
  fi
}

remove_power_platform() {
  if [[ "$(pp_registered)" != "0" ]]; then
    az rest --method delete --resource https://service.powerapps.com/ \
      --url "$PP_ADMIN_APPS/$CLIENT_ID?api-version=$PP_ADMIN_VERSION" >/dev/null
    echo "  - management app registration"
  fi
  local id; id="$(pp_reader_id)"
  if [[ -n "$id" ]]; then
    az rest --method delete --resource https://api.powerplatform.com \
      --url "$PP_ROLES/$id?api-version=$PP_ROLES_VERSION" >/dev/null
    echo "  - Power Platform reader"
  fi
}

# ------------------------------------------------------------------ Graph / Log Analytics (4.3)

resource_sp() { # appId -> service principal object id (created if the tenant lacks it)
  local id
  id="$(az ad sp show --id "$1" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$id" ]]; then id="$(az ad sp create --id "$1" --query id -o tsv)"; fi
  printf '%s' "$id"
}

grant_app_role() { # resource appId, permission value
  local res role existing
  res="$(resource_sp "$1")"
  role="$(az ad sp show --id "$1" --query "appRoles[?value=='$2' && contains(allowedMemberTypes,'Application')].id | [0]" -o tsv)"
  [[ -n "$role" ]] || { echo "  ! $2 not found on $1" >&2; return 1; }
  existing="$(az rest --method get --url "$GRAPH/servicePrincipals/$WORKER_SP/appRoleAssignments" \
    --query "value[?appRoleId=='$role' && resourceId=='$res'] | length(@)" -o tsv)"
  if [[ "$existing" != "0" ]]; then
    echo "  = $2: already there"
  else
    az rest --method post --url "$GRAPH/servicePrincipals/$WORKER_SP/appRoleAssignments" \
      --body "{\"principalId\":\"$WORKER_SP\",\"resourceId\":\"$res\",\"appRoleId\":\"$role\"}" >/dev/null
    echo "  + $2"
  fi
}

grant_graph() {
  # PLS-129: no Log Analytics Data.Read — the worker's managed identity queries telemetry through the
  # Azure RBAC roles the template assigns on the Application Insights resource. LOG_ANALYTICS_API stays
  # so `show` and `remove` still handle a Data.Read grant from an earlier install.
  grant_app_role "$GRAPH_API" "ServiceHealth.Read.All"
  if $WITH_LICENSES; then
    grant_app_role "$GRAPH_API" "Organization.Read.All"
    grant_app_role "$GRAPH_API" "User.Read.All"
  fi
  if $WITH_AUDITLOG; then grant_app_role "$GRAPH_API" "AuditLog.Read.All"; fi
}

list_app_roles() {
  az rest --method get --url "$GRAPH/servicePrincipals/$WORKER_SP/appRoleAssignments" \
    --query "value[].{resource:resourceDisplayName, appRoleId:appRoleId, id:id}" -o tsv
}

show_app_roles() {
  local line resource role_id res_app value
  while IFS=$'\t' read -r resource role_id _; do
    [[ -n "$resource" ]] || continue
    res_app="$([[ "$resource" == "Microsoft Graph" ]] && echo "$GRAPH_API" || echo "$LOG_ANALYTICS_API")"
    value="$(az ad sp show --id "$res_app" --query "appRoles[?id=='$role_id'].value | [0]" -o tsv)"
    echo "  $resource — $value"
  done < <(list_app_roles)
}

remove_graph() {
  local id
  while IFS=$'\t' read -r _ _ id; do
    [[ -n "$id" ]] || continue
    az rest --method delete --url "$GRAPH/servicePrincipals/$WORKER_SP/appRoleAssignments/$id" >/dev/null
    echo "  - app role assignment $id"
  done < <(list_app_roles)
}

case "$ACTION" in
  power-platform) echo "Power Platform (step 4.2):"; grant_power_platform ;;
  graph) echo "Microsoft Graph (step 4.3):"; grant_graph ;;
  show)
    echo "Power Platform:"
    [[ "$(pp_registered)" != "0" ]] && echo "  management app registration" || echo "  (no management app registration)"
    [[ -n "$(pp_reader_id)" ]] && echo "  Power Platform reader" || echo "  (no Power Platform reader)"
    echo "Application permissions:"; show_app_roles ;;
  remove) echo "Removing:"; remove_power_platform; remove_graph ;;
  *) usage ;;
esac
[[ "$ACTION" == "show" ]] || echo "Done. Changes can take 5-10 minutes before AXO Pulse sees them."
