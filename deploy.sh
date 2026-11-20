#!/usr/bin/env bash
# PLS-094: deploy one customer-hosted AXO Pulse instance (model b) — guide step 3.
# Runs in Azure Cloud Shell (bash) or anywhere with az >= 2.60, signed in as the customer admin.
#
#   ./deploy.sh -g rg-axopulse-contoso -n contoso \
#     -a /subscriptions/.../components/appi-contoso-fo \
#     -d sha256:<digest> -v 0.1.0 -u kunde-contoso
#
# Optional: -P parameters.json (tags, existing central private DNS zones — see parameters.example.json)
# and -p <server-name> (adopt a point-in-time-restored Postgres server).
#
# Idempotent: run it again to update. Each run rotates the database password and restarts the apps.
set -euo pipefail

SOURCE_REGISTRY="acraxopulse.azurecr.io"
REPOSITORY="axo-pulse"
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<EOF
Usage: $0 -g <resource-group> -n <short-name> -a <app-insights-resource-id> -d <sha256:digest> -v <version> -u <token-name> [-p <server-name>] [-P <parameters-file>]
  -g  resource group from guide step 1.1 (must exist)
  -n  short customer name, 2-12 characters (e.g. contoso)
  -a  Application Insights Resource ID from guide step 1.5
  -d  image digest from AX Operations (sha256:...)
  -v  version from AX Operations (e.g. 0.1.0)
  -u  registry token name from AX Operations (the password is asked for)
  -p  optional: name of an existing (point-in-time restored) Postgres server to adopt instead of the generated name
  -P  optional: extra ARM parameters file (JSON) passed to both deployments, e.g. tags,
      postgresPrivateDnsZoneId, keyVaultPrivateDnsZoneId (see parameters.example.json)
Optional environment: AXOPULSE_JIRA_TOKEN (feedback token from AX Operations).
EOF
  exit 2
}

RG="" SHORT="" APPI="" DIGEST="" VERSION="" TOKEN_NAME="" PG_NAME="" PARAMS_FILE=""
while getopts "g:n:a:d:v:u:p:P:h" opt; do
  case "$opt" in
    g) RG="$OPTARG" ;; n) SHORT="$OPTARG" ;; a) APPI="$OPTARG" ;;
    d) DIGEST="$OPTARG" ;; v) VERSION="$OPTARG" ;; u) TOKEN_NAME="$OPTARG" ;;
    p) PG_NAME="$OPTARG" ;; P) PARAMS_FILE="$OPTARG" ;;
    *) usage ;;
  esac
done
[[ -n "$RG" && -n "$SHORT" && -n "$APPI" && -n "$DIGEST" && -n "$VERSION" && -n "$TOKEN_NAME" ]] || usage
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "The digest must be sha256: followed by 64 hex characters." >&2; exit 2; }
[[ "$SHORT" =~ ^[a-z0-9-]{2,12}$ ]] || { echo "The short name must be 2-12 lowercase letters, digits or dashes." >&2; exit 2; }
[[ -z "$PARAMS_FILE" || -f "$PARAMS_FILE" ]] || { echo "Parameters file not found: $PARAMS_FILE" >&2; exit 2; }

# The extra parameters file goes first so the explicit values below win. registry.bicep declares (and
# ignores) the main.bicep-only keys, so the same file is valid for both deployments.
extra=()
[[ -n "$PARAMS_FILE" ]] && extra=(-p "@$PARAMS_FILE")

step() { printf '\n== %s\n' "$*"; }

step "1/5 Checking sign-in and the resource group"
az account show --query "{subscription:name, tenant:tenantId, user:user.name}" -o table
az group show -n "$RG" --query location -o tsv >/dev/null \
  || { echo "Resource group $RG not found — create it first (guide step 1.1)." >&2; exit 1; }

step "2/5 Checking resource providers"
missing=()
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL Microsoft.KeyVault \
          Microsoft.ManagedIdentity Microsoft.Network Microsoft.OperationalInsights Microsoft.Insights; do
  state="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
  [[ "$state" == "Registered" ]] || missing+=("$ns")
done
if (( ${#missing[@]} )); then
  echo "These resource providers are not registered in the subscription: ${missing[*]}" >&2
  echo "Someone with Contributor or Owner on the subscription must run, once:" >&2
  for ns in "${missing[@]}"; do echo "  az provider register --namespace $ns --wait" >&2; done
  exit 1
fi
echo "All providers registered."

step "3/5 Creating the registry"
REGISTRY="$(az deployment group create -g "$RG" -n axopulse-registry \
  -f "$HERE/registry.bicep" ${extra[@]+"${extra[@]}"} -p shortName="$SHORT" \
  --query properties.outputs.registryName.value -o tsv)"
echo "Registry: $REGISTRY"

step "4/5 Importing the image $DIGEST"
if az acr manifest show-metadata -r "$REGISTRY" -n "$REPOSITORY@$DIGEST" >/dev/null 2>&1; then
  echo "Already imported."
else
  if command -v cosign >/dev/null 2>&1; then
    echo "cosign found — the signature check from SIGNERING.md must already have passed for this digest."
  fi
  read -r -s -p "Password for registry token $TOKEN_NAME: " TOKEN_PASSWORD; echo
  az acr import --name "$REGISTRY" \
    --source "$SOURCE_REGISTRY/$REPOSITORY@$DIGEST" \
    --image "$REPOSITORY:$VERSION" \
    --username "$TOKEN_NAME" --password "$TOKEN_PASSWORD" >/dev/null
  unset TOKEN_PASSWORD
  echo "Imported as $REGISTRY.azurecr.io/$REPOSITORY:$VERSION ($DIGEST)."
fi

step "5/5 Deploying the instance (10-20 minutes the first time)"
params=(shortName="$SHORT" appInsightsResourceId="$APPI" registryName="$REGISTRY"
        imageDigest="$DIGEST" appVersion="$VERSION")
[[ -n "${AXOPULSE_JIRA_TOKEN:-}" ]] && params+=(jiraApiToken="$AXOPULSE_JIRA_TOKEN")
[[ -n "$PG_NAME" ]] && params+=(postgresServerName="$PG_NAME")
az deployment group create -g "$RG" -n axopulse-instance -f "$HERE/main.bicep" \
  ${extra[@]+"${extra[@]}"} -p "${params[@]}" \
  --query "properties.outputs.{webUrl:webUrl.value, webIdentityClientId:webIdentityClientId.value, workerIdentityClientId:workerIdentityClientId.value, loginAppClientId:loginAppClientId.value}" \
  -o table

cat <<EOF

Done. Note the values above (guide step 3). Next: guide step 4 (read access) and step 5.3 (assign roles).
EOF
