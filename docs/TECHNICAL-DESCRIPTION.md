# AXO Pulse — technical description for security and infrastructure

**For:** your IT security, infrastructure and network teams, before AXO Pulse is installed.
**In short:** AXO Pulse runs as your own instance in your own Azure subscription. The instance has read-only
access, there are no client secrets, the database and the Key Vault cannot be reached from the internet, and all
code arrives as a signed image that you verify and import yourself. This document describes exactly what the
deployment creates, which permissions are granted, and which traffic goes in and out.

A Danish version of this document is available as `TEKNISK-BESKRIVELSE.md`.

This document corresponds to the deployment template for version 0.1. The template (`main.bicep`) and the scripts
can be read in full before anything is run.

---

## Overview

```
                 Your users (browser, Entra sign-in with MFA/Conditional Access)
                                        │ HTTPS 443
                                        ▼
 ┌──────────────────────────── Your Azure subscription · resource group rg-axopulse-<short-name> ──────────────────┐
 │                                                                                                                 │
 │   Container Apps environment (in the VNet)                                                                      │
 │   ┌───────────────────────────────┐      ┌───────────────────────────────┐                                      │
 │   │ ca-axopulse-web               │      │ ca-axopulse-worker            │                                      │
 │   │ public HTTPS address          │      │ no inbound access             │──── reads ───► Application Insights  │
 │   │ identity: id-axopulse-web     │      │ identity: id-axopulse-worker  │                (yours, step 1)       │
 │   └──────────┬────────────────────┘      └──────────┬────────────────────┘                                      │
 │              │ VNet (private)                        │                                                          │
 │              ▼                                       ▼                                                          │
 │   PostgreSQL (VNet only)       Key Vault (private endpoint only)       Container Registry (your copy of image)  │
 │                                                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
          worker ──► Microsoft: Power Platform APIs, Microsoft Graph, Log Analytics (read only)
          worker ──► AX Operations' Jira (user-submitted feedback only, can be turned off)
          worker ──► your own SMTP server or Teams webhook (only if you set up notifications)
```

---

## Resources the deployment creates

Everything is created in the resource group and region you choose. `<short-name>` is your agreed short name,
`<suffix>` is six characters derived from the resource group's id.

| Resource | Name | Configuration |
| --- | --- | --- |
| Container Registry | `cr<short-name><suffix>` | Basic. Admin user disabled; only the two managed identities can pull (AcrPull) |
| Managed identity | `id-axopulse-web` | User-assigned. Used by the web app |
| Managed identity | `id-axopulse-worker` | User-assigned. Used by the worker; the only one with data access |
| Virtual network | `vnet-axopulse-<short-name>` | Address space `10.80.0.0/22` (can be changed, see "Network") with three subnets |
| Private DNS zone | `privatelink.vaultcore.azure.net` | Linked to the VNet; provides the Key Vault's private address |
| Private DNS zone | `psql-axopulse-<short-name>-<suffix>.private.postgres.database.azure.com` | Linked to the VNet; provides the database's private address |
| Azure Database for PostgreSQL – Flexible Server | `psql-axopulse-<short-name>-<suffix>` | PostgreSQL 17, Burstable B1ms, 32 GB with auto-grow. VNet access only (public network access disabled). Backup 14 days, locally redundant. No high availability |
| Database | `axopulse` | UTF-8 |
| Key Vault | `kv-axopulse-<short-name>-<suffix>` | Standard. Azure RBAC, soft delete 90 days, purge protection. Public network access disabled |
| Private endpoint | `pe-kv-axopulse-…` | The Key Vault's only access path, in the VNet |
| Container Apps environment | `cae-axopulse-<short-name>` | Workload profiles (Consumption), integrated into the VNet. Logs are sent to your Log Analytics workspace |
| Container App | `ca-axopulse-web` | The web app. Public HTTPS ingress, HTTP rejected. 0.5 vCPU / 1 GiB, 0-2 replicas (scales to zero when not in use) |
| Container App | `ca-axopulse-worker` | Fetches data and evaluates findings. No ingress. 0.5 vCPU / 1 GiB, always one replica |
| Diagnostic setting | `to-customer-workspace` | The Container Apps environment's logs to your workspace from step 1.2 |

In addition, in Entra ID:

| Object | Configuration |
| --- | --- |
| App registration **AXO Pulse** (unique name `axo-pulse-<short-name>`) | Single tenant. Redirect URI `https://<web app address>/auth/callback`. No API permissions beyond sign-in (`openid`, `profile`). Four app roles. Groups claim only for groups assigned to the app. **No client secret and no certificate** |
| Federated credential `axopulse-web` on the app registration | Issuer `https://login.microsoftonline.com/<your tenant>/v2.0`, subject = `id-axopulse-web`. This is how the web app proves that it is the sign-in app |
| Enterprise application **AXO Pulse** | *Assignment required* = Yes: only users and groups with an assigned role can sign in |

The deployment does **not** create: public IP addresses, gateways, VPN, firewall openings, users, guests or
anything outside the specified resource group (apart from the role assignments on the Application Insights
resource and the Entra objects above).

---

## Identities and permissions

| Identity | Permission | Scope | Why | Granted by |
| --- | --- | --- | --- | --- |
| `id-axopulse-web` | AcrPull | Your registry | Pull the image | The template |
| | Key Vault Secrets User | Your Key Vault | Read the database connection string and the optional Jira token | The template |
| | Federated credential on the sign-in app | The sign-in app | Complete Entra sign-in without a secret | The template |
| `id-axopulse-worker` | AcrPull | Your registry | Pull the image | The template |
| | Key Vault Secrets User | Your Key Vault | Read the database connection string | The template |
| | Log Analytics Data Reader + Monitoring Reader | Only the Application Insights resource from step 1 | Read the F&O telemetry | The template |
| | Power Platform management app | Your Power Platform tenant | Environment list, capacity, F&O version, scheduled updates | `grant-access.sh power-platform` |
| | Power Platform reader | Your Power Platform tenant | Backups, disaster recovery, lifecycle history (read only) | `grant-access.sh power-platform` |
| | Microsoft Graph `ServiceHealth.Read.All` | Application permission | Microsoft service health | `grant-access.sh graph` |
| | Microsoft Graph `Organization.Read.All`, `User.Read.All` | Application permission, optional | License overview | `grant-access.sh graph --licenses` |
| | Microsoft Graph `AuditLog.Read.All` | Application permission, optional | Most recent sign-in in the license overview | `grant-access.sh graph --auditlog` |

The web app, which is the internet-facing component, has no data access outside the instance's own database —
except the optional Jira token, which can only create issues in AX Operations' feedback project and which the web
app only uses for AX Operations' connection test. None
of the permissions can write to F&O, Power Platform, Entra ID or Azure. `./grant-access.sh show <client ID>` shows
what the worker identity has, and `./grant-access.sh remove <client ID>` removes it.

**The person installing needs:**

| Role | For |
| --- | --- |
| Contributor or Owner on the subscription, once | Registering resource providers |
| Owner on the resource group (or Contributor + User Access Administrator) | The deployment and the role assignments |
| Owner or User Access Administrator on the Application Insights resource | Assigning the two reader roles (if it is in the same resource group, this is covered above) |
| Application Administrator or Cloud Application Administrator | Creating the sign-in app |
| Power Platform administrator | `grant-access.sh power-platform` |
| Global Administrator or Privileged Role Administrator | `grant-access.sh graph` (application permissions) |

**AX Operations' access:** AX Operations gets no access to your subscription, resources or Entra ID. AX
Operations' consultants can sign in to AXO Pulse as B2B guests if you invite them and assign them a role — you
control that. The access token for AX Operations' registry can only read the AXO Pulse image and is used only
during the import; it is not stored in the instance.

---

## Network

| Direction | From → to | Port | Note |
| --- | --- | --- | --- |
| Inbound | Internet → `ca-axopulse-web` | 443 | Public address `ca-axopulse-web.<environment>.<region>.azurecontainerapps.io`. HTTP rejected. Protected by Entra sign-in |
| Inbound | Internet → worker, database, Key Vault, registry data | — | None. Database and Key Vault have public network access disabled |
| Internal | Apps → PostgreSQL | 5432 | Via the VNet and private DNS. TLS with certificate and host name verification (`verify-full`) |
| Internal | Apps → Key Vault | 443 | Via private endpoint |

**Subnets** (derived from the address space, default `10.80.0.0/22`):

| Subnet | Addresses | Delegated to |
| --- | --- | --- |
| `snet-apps` | `10.80.0.0/24` | Microsoft.App/environments |
| `snet-postgres` | `10.80.1.0/27` | Microsoft.DBforPostgreSQL/flexibleServers |
| `snet-endpoints` | `10.80.1.32/27` | Private endpoints |

If the instance is to be peered with your network, agree on an address space that does not overlap. It is set with
the parameter `vnetAddressPrefix`.

**Outbound traffic** (from the worker unless stated otherwise — all over HTTPS 443):

| Destination | Purpose | Can be turned off |
| --- | --- | --- |
| `login.microsoftonline.com` | Tokens for managed identities and user sign-in (web app) | No |
| `api.loganalytics.io` | Read telemetry from Application Insights | No |
| `api.bap.microsoft.com`, `api.powerplatform.com`, `*.environment.api.powerplatform.com`, `service.powerapps.com` | Environment list, capacity, backups, updates | No |
| `graph.microsoft.com` | Service health, license overview | Yes (omit the permissions) |
| `api.atlassian.com` | Feedback to AX Operations' Jira — see "Data that leaves the instance" (web app: only AX Operations' connection test) | Yes (no Jira token) |
| Your SMTP server | Notifications by email | Only if you set it up |
| `*.webhook.office.com` | Notifications to Teams | Only if you set it up |
| `*.azurecr.io` | Pull the image from your registry (the platform, at startup) | No |

The instance does not use an outbound firewall or a NAT gateway. If you have a requirement to control outbound
traffic with Azure Firewall or UDR, the destinations above plus the tag `AzureKeyVault` must be allowed.

---

## Data

### Where data resides

All of AXO Pulse's own data resides in the PostgreSQL database in your subscription. What is stored is described
in the setup guide (`OPSAETNING.md`, Danish) under "Hvad AXO Pulse gemmer". In short: aggregated figures and
findings from the telemetry, environment information from Power Platform, sign-in history (Entra Object ID and
display name) and — if you choose the license overview — users with licenses. The telemetry itself stays in your
Application Insights; AXO Pulse stores aggregates as well as error messages and batch job names, as F&O writes them.

### Data that leaves the instance

| What | To | When | Content |
| --- | --- | --- | --- |
| Feedback | AX Operations' Jira (Atlassian Cloud) | Only when a user submits a request from AXO Pulse themselves | The user's title and description, optionally a screenshot (max 5 MB) that the user attaches themselves, and a short technical context: page, environment name, selected period, language, version, browser family, screen size, theme and role. The user sees the context before it is sent. Without consent to contact, only a pseudonym is sent, never name, email or Object ID. Never findings, telemetry or ids |
| Notifications | Your own SMTP server or Teams channel | Only when you have set up notifications | Number and type of findings — never names |

Without a Jira token from AX Operations, requests are only stored in the instance and are not forwarded.

### Encryption, backup and logs

- **At rest:** PostgreSQL, Key Vault and Container Registry are encrypted with Microsoft-managed keys.
  Customer-managed keys (CMK) are not enabled.
- **In transit:** HTTPS to the web app (HSTS), TLS with full verification to the database.
- **Secrets:** the database password and, if you have agreed to feedback, a Jira token that can only create issues
  in AX Operations' feedback project. The password is generated on every deployment and is not known to AX
  Operations. Both are stored only in Key Vault and read by the apps via managed identity.
- **Backup:** PostgreSQL's automatic backup, 14 days, locally redundant, with point-in-time restore. A restore
  creates a new server in the same network (about 10 minutes); `deploy.sh -p <new server>` points the instance at it,
  and the old server is deleted afterwards.
- **Logs:** app logs and system logs from Container Apps are sent to your Log Analytics workspace. Logs contain no
  passwords or tokens.

---

## Application security

- **Sign-in:** OpenID Connect with PKCE against your own Entra tenant, so your MFA and Conditional Access apply.
  Only users with an assigned app role can sign in; permissions in the app follow the role (four levels, see the
  setup guide (`OPSAETNING.md`, Danish), step 5.2).
- **Sessions:** cookie with `HttpOnly`, `Secure` and `SameSite=Lax`. Expires after 12 hours and after 60 minutes
  of inactivity.
- **HTTP headers:** Content-Security-Policy, Strict-Transport-Security, `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff` and Referrer-Policy on all responses.
- **Fails closed:** the instance refuses to start with an incomplete sign-in or tenant configuration and cannot be
  started in development mode in Azure.
- **Image:** built by AX Operations' build system, signed keyless with Sigstore, with an SBOM (SPDX) and build
  attestation (SLSA provenance). How you verify it: “How you know it is our software” (`SIGNERING.md`, Danish).
  Every version is scanned for known vulnerabilities and leaked secrets before it is released. The container runs
  as an unprivileged user.

---

## Azure Policy and your own requirements

- **Policies that modify resources:** for example, Microsoft Defender for Cloud can enable *Advanced Threat
  Protection* on the database after the deployment. This is harmless; the template does not overwrite it.
- **Policies that can block the deployment:**
  - requirements for tags on resources — supported: put your tags in a parameters file (`deploy.sh -P`), and every
    Azure resource gets them;
  - a requirement that private DNS zones be located centrally in a hub network — supported: name the existing zones
    in the parameters file, and the template only creates VNet links to them (needs *Private DNS Zone Contributor*
    on the zones);
  - a ban on public ingress on Container Apps;
  - restrictions on allowed regions or SKUs.

  If you have such policies, tell us before the deployment; the last two need an adjustment from AX Operations.
- **Own address:** the web app can be given your own domain (for example `pulse.yourdomain.com`) with a managed
  certificate. This is not part of the standard deployment; agree on it with AX Operations.

---

## Updates

1. AX Operations sends the version number and digest of a new version.
2. You verify the signature (`SIGNERING.md`, Danish).
3. You run `deploy.sh` again with the new version and digest. The image is imported into your registry, the
   database password is rotated, and the apps restart. Database changes are run automatically when the worker
   starts.

You decide when an update is installed. AX Operations cannot update the instance.

---

## Removal

Remove the permissions **before** the identity is deleted — otherwise the script can no longer find them:

1. `./grant-access.sh remove <workerIdentityClientId>` (the Power Platform and Graph permissions).
2. Delete the resource group `rg-axopulse-<short-name>`.
3. Delete the app registration **AXO Pulse** in Entra ID (**App registrations** → **Deleted applications** to
   remove it completely).
4. The Application Insights resource and the F&O telemetry from steps 1-2 are yours and are removed separately if
   you wish.

The Key Vault will then remain as deleted (soft delete) for 90 days and cannot be purged sooner, because of purge
protection. It contains only the database password for a database that has been deleted.

---

## Costs

Estimate for the instance in North Europe under normal use, excl. VAT (Application Insights is described in the
setup guide):

| Resource | Approx. per month |
| --- | --- |
| Container Apps (worker always on, web scales to zero) | €25–35 |
| PostgreSQL B1ms with 32 GB and backup | €15–20 |
| Container Registry Basic | €5 |
| Private endpoint and private DNS zones | €8 |
| Key Vault | under €1 |
| **Total** | **approx. €55–70** |

The figures are an estimate; your actual bill depends on region, agreement and usage.

---

*AX Operations ApS · AXO Pulse*
