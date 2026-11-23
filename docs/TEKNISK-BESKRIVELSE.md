# AXO Pulse — teknisk beskrivelse til sikkerhed og infrastruktur

**Til:** jeres IT-sikkerhed, infrastruktur- og netværksteam, før AXO Pulse installeres.
**Kort fortalt:** AXO Pulse kører som jeres egen instans i jeres eget Azure-abonnement. Instansen har kun
læseadgang, der findes ingen client secrets, databasen og Key Vault'en kan ikke nås fra internettet, og al kode
kommer som et signeret image, I selv kontrollerer og importerer. Dette dokument beskriver præcis, hvad
udrulningen opretter, hvilke rettigheder der gives, og hvilken trafik der går ind og ud.

En engelsk udgave findes som `TECHNICAL-DESCRIPTION.md`.

Dokumentet svarer til udrulningsskabelonen for version 0.1. Skabelonen (`main.bicep`) og scripts er offentlige og
kan læses i deres helhed, før noget køres — se "Levering: installationspakke og image".

---

## Overblik

```
                 Jeres brugere (browser, Entra-login med MFA/Conditional Access)
                                        │ HTTPS 443
                                        ▼
 ┌──────────────────────────── Jeres Azure-abonnement · resource group rg-axopulse-<kortnavn> ─────────────────────┐
 │                                                                                                                 │
 │   Container Apps-miljø (i VNet'et)                                                                              │
 │   ┌───────────────────────────────┐      ┌───────────────────────────────┐                                      │
 │   │ ca-axopulse-web               │      │ ca-axopulse-worker            │                                      │
 │   │ offentlig HTTPS-adresse       │      │ ingen indgående adgang        │──── læser ───► Application Insights  │
 │   │ identitet: id-axopulse-web    │      │ identitet: id-axopulse-worker │                (jeres, trin 1)       │
 │   └──────────┬────────────────────┘      └──────────┬────────────────────┘                                      │
 │              │ VNet (privat)                         │                                                          │
 │              ▼                                       ▼                                                          │
 │   PostgreSQL (kun VNet)        Key Vault (kun private endpoint)       Container Registry (jeres kopi af imaget) │
 │                                                                                                                 │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
          worker ──► Microsoft: Power Platform-API'er, Microsoft Graph, Log Analytics (kun læsning)
          worker ──► AX Operations' Jira (kun brugerindsendt feedback, kan slås fra)
          worker ──► jeres egen SMTP-server eller Teams-webhook (kun hvis I opsætter beskeder)
```

---

## Ressourcer, udrulningen opretter

Alt oprettes i den resource group og region, I vælger. `<kortnavn>` er jeres aftalte kortnavn, `<suffiks>` er
seks tegn afledt af resource group'ens id.

| Ressource | Navn | Konfiguration |
| --- | --- | --- |
| Container Registry | `cr<kortnavn><suffiks>` | Basic. Admin-bruger slået fra; kun de to managed identities kan hente (AcrPull) |
| Managed identity | `id-axopulse-web` | User-assigned. Bruges af webappen |
| Managed identity | `id-axopulse-worker` | User-assigned. Bruges af worker'en; den eneste med dataadgang |
| Virtuelt netværk | `vnet-axopulse-<kortnavn>` | Adresserum `10.80.0.0/22` (kan ændres, se "Netværk") med tre subnets |
| Private DNS-zone | `privatelink.vaultcore.azure.net` | Linket til VNet'et; giver Key Vault'ens private adresse |
| Private DNS-zone | `psql-axopulse-<kortnavn>-<suffiks>.private.postgres.database.azure.com` | Linket til VNet'et; giver databasens private adresse |
| Azure Database for PostgreSQL – Flexible Server | `psql-axopulse-<kortnavn>-<suffiks>` | PostgreSQL 17, Burstable B1ms, 32 GB med auto-grow. Kun VNet-adgang (public network access slået fra). Backup 14 dage, lokalt redundant. Ingen high availability |
| Database | `axopulse` | UTF-8 |
| Key Vault | `kv-axopulse-<kortnavn>-<suffiks>` | Standard. Azure RBAC, soft delete 90 dage, purge protection. Public network access slået fra |
| Private endpoint | `pe-kv-axopulse-…` | Key Vault'ens eneste adgangsvej, i VNet'et |
| Container Apps-miljø | `cae-axopulse-<kortnavn>` | Workload profiles (Consumption), integreret i VNet'et. Logs sendes til jeres Log Analytics workspace |
| Container App | `ca-axopulse-web` | Webappen. Offentlig HTTPS-ingress, HTTP afvises. 0,5 vCPU / 1 GiB, 0-2 replikaer (skalerer til nul uden brug) |
| Container App | `ca-axopulse-worker` | Henter data og vurderer fund. Ingen ingress. 0,5 vCPU / 1 GiB, altid én replika |
| Diagnostikindstilling | `to-customer-workspace` | Container Apps-miljøets logs til jeres workspace fra trin 1.2 |

Desuden i Entra ID:

| Objekt | Konfiguration |
| --- | --- |
| App-registrering **AXO Pulse** (unique name `axo-pulse-<kortnavn>`) | Single tenant. Redirect-adresse `https://<webappens adresse>/auth/callback`. Ingen API-tilladelser ud over login (`openid`, `profile`). Fire app-roller. Groups claim kun for grupper tildelt appen. **Ingen client secret og intet certifikat** |
| Federated credential `axopulse-web` på app-registreringen | Udsteder `https://login.microsoftonline.com/<jeres tenant>/v2.0`, subject = `id-axopulse-web`. Det er sådan webappen beviser, at den er login-appen |
| Enterprise application **AXO Pulse** | *Assignment required* = Yes: kun brugere og grupper med en tildelt rolle kan logge ind |

Udrulningen opretter **ikke**: offentlige IP-adresser, gateways, VPN, firewall-åbninger, brugere, gæster eller
noget uden for den angivne resource group (bortset fra rolletildelingerne på Application Insights-ressourcen og
Entra-objekterne ovenfor).

---

## Identiteter og rettigheder

| Identitet | Rettighed | Scope | Hvorfor | Gives af |
| --- | --- | --- | --- | --- |
| `id-axopulse-web` | AcrPull | Jeres registry | Hente imaget | Skabelonen |
| | Key Vault Secrets User | Jeres Key Vault | Læse databasens forbindelsesstreng og det valgfri Jira-token | Skabelonen |
| | Federated credential på login-appen | Login-appen | Gennemføre Entra-login uden secret | Skabelonen |
| `id-axopulse-worker` | AcrPull | Jeres registry | Hente imaget | Skabelonen |
| | Key Vault Secrets User | Jeres Key Vault | Læse databasens forbindelsesstreng | Skabelonen |
| | Log Analytics Data Reader + Monitoring Reader | Kun Application Insights-ressourcen fra trin 1 | Læse F&O-telemetrien | Skabelonen |
| | Power Platform management-app | Jeres Power Platform-tenant | Miljøliste, kapacitet, F&O-version, planlagte opdateringer | `grant-access.sh power-platform` |
| | Power Platform reader | Jeres Power Platform-tenant | Backups, disaster recovery, livscyklushistorik (kun læsning) | `grant-access.sh power-platform` |
| | Microsoft Graph `ServiceHealth.Read.All` | Application permission | Microsofts servicetilstand | `grant-access.sh graph` |
| | Microsoft Graph `Organization.Read.All`, `User.Read.All` | Application permission, valgfri | Licensoverblik | `grant-access.sh graph --licenses` |
| | Microsoft Graph `AuditLog.Read.All` | Application permission, valgfri | Seneste login i licensoverblikket | `grant-access.sh graph --auditlog` |

Webappen, som er den internetvendte del, har ingen dataadgang uden for instansens egen database — bortset fra det
valgfri Jira-token, som kun kan oprette sager i AX Operations' feedbackprojekt, og som webappen kun bruger til AX
Operations' forbindelsestest. Ingen af
rettighederne kan skrive i F&O, Power Platform, Entra ID eller Azure. `./grant-access.sh show <client ID>` viser,
hvad worker-identiteten har, og `./grant-access.sh remove <client ID>` fjerner det.

**Den, der installerer, skal have:**

| Rolle | Til |
| --- | --- |
| Contributor eller Owner på abonnementet, én gang | Registrere resource providers |
| Owner på resource group'en (eller Contributor + User Access Administrator) | Udrulningen og rolletildelingerne |
| Owner eller User Access Administrator på Application Insights-ressourcen | Tildele de to læseroller (ligger den i samme resource group, er det dækket ovenfor) |
| Application Administrator eller Cloud Application Administrator | Oprette login-appen |
| Power Platform-administrator | `grant-access.sh power-platform` |
| Global Administrator eller Privileged Role Administrator | `grant-access.sh graph` (application permissions) |

**AX Operations' adgang:** AX Operations får ingen adgang til jeres abonnement, ressourcer eller Entra ID. AX
Operations' konsulenter kan logge ind i AXO Pulse som B2B-gæster, hvis I inviterer dem og tildeler dem en rolle —
det styrer I. Adgangstokenet til AX Operations' registry kan kun læse AXO Pulse-imaget og bruges kun under
importen; det gemmes ikke i instansen.

---

## Netværk

| Retning | Fra → til | Port | Bemærkning |
| --- | --- | --- | --- |
| Ind | Internet → `ca-axopulse-web` | 443 | Offentlig adresse `ca-axopulse-web.<miljø>.<region>.azurecontainerapps.io`. HTTP afvises. Beskyttet af Entra-login |
| Ind | Internet → worker, database, Key Vault, registry-data | — | Ingen. Database og Key Vault har public network access slået fra |
| Internt | Apps → PostgreSQL | 5432 | Via VNet og privat DNS. TLS med certifikat- og værtsnavnsverifikation (`verify-full`) |
| Internt | Apps → Key Vault | 443 | Via private endpoint |

**Subnets** (afledt af adresserummet, standard `10.80.0.0/22`):

| Subnet | Adresser | Delegeret til |
| --- | --- | --- |
| `snet-apps` | `10.80.0.0/24` | Microsoft.App/environments |
| `snet-postgres` | `10.80.1.0/27` | Microsoft.DBforPostgreSQL/flexibleServers |
| `snet-endpoints` | `10.80.1.32/27` | Private endpoints |

Skal instansen peeres med jeres netværk, så aftal et adresserum, der ikke overlapper. Det angives som parameteren
`vnetAddressPrefix`.

**Udgående trafik** (fra worker'en, medmindre andet er nævnt — alt over HTTPS 443):

| Destination | Formål | Kan slås fra |
| --- | --- | --- |
| `login.microsoftonline.com` | Tokens til managed identities og brugerlogin (webappen) | Nej |
| `api.loganalytics.io` | Læse telemetri fra Application Insights | Nej |
| `api.bap.microsoft.com`, `api.powerplatform.com`, `*.environment.api.powerplatform.com`, `service.powerapps.com` | Miljøliste, kapacitet, backups, opdateringer | Nej |
| `graph.microsoft.com` | Servicetilstand, licensoverblik | Ja (udelad tilladelserne) |
| `api.atlassian.com` | Feedback til AX Operations' Jira — se "Data, der forlader instansen" (webappen: kun AX Operations' forbindelsestest) | Ja (ingen Jira-token) |
| Jeres SMTP-server | Beskeder på e-mail | Kun hvis I opsætter det |
| `*.webhook.office.com` | Beskeder til Teams | Kun hvis I opsætter det |
| `*.azurecr.io` | Hente imaget fra jeres registry (platformen, ved opstart) | Nej |

**Kun under installationen** (fra Azure Cloud Shell, ikke fra instansen): `github.com` og `codeload.github.com`
(installationspakken), `acraxopulse.azurecr.io` (signaturkontrol og import af imaget; selve importen sker i Azure
mellem de to registries) og Azure Resource Manager.

Instansen bruger ikke en udgående firewall eller NAT gateway. Har I krav om at styre udgående trafik med Azure
Firewall eller UDR, skal ovenstående destinationer plus tagget `AzureKeyVault` tillades.

---

## Data

### Hvor data ligger

Alle AXO Pulses egne data ligger i PostgreSQL-databasen i jeres abonnement. Hvad der gemmes, er beskrevet i
opsætningsguiden under "Hvad AXO Pulse gemmer". Kort: aggregerede tal og fund fra telemetrien, miljøoplysninger fra
Power Platform, login-historik (Entra Object ID og visningsnavn) og — hvis I vælger licensoverblikket — brugere med
licens. Telemetrien selv bliver i jeres Application Insights; AXO Pulse gemmer aggregater samt fejltekster og
batchjob-navne, som F&O skriver dem.

### Data, der forlader instansen

| Hvad | Hvortil | Hvornår | Indhold |
| --- | --- | --- | --- |
| Feedback | AX Operations' Jira (Atlassian Cloud) | Kun når en bruger selv sender en henvendelse fra AXO Pulse | Brugerens titel og beskrivelse, eventuelt et skærmbillede (højst 5 MB), som brugeren selv vedhæfter, og en kort teknisk kontekst: side, miljøets navn, valgt periode, sprog, version, browserfamilie, skærmstørrelse, tema og rolle. Brugeren ser konteksten, før der sendes. Uden samtykke til kontakt sendes kun et pseudonym, aldrig navn, e-mail eller Object ID. Aldrig fund, telemetri eller id'er |
| Beskeder | Jeres egen SMTP-server eller Teams-kanal | Kun når I har opsat beskeder | Antal og type af fund — aldrig navne |

Uden en Jira-token fra AX Operations gemmes henvendelser kun i instansen og sendes ikke videre.

### Kryptering, backup og logs

- **I hvile:** PostgreSQL, Key Vault og Container Registry krypteres med Microsoft-administrerede nøgler.
  Kundeadministrerede nøgler (CMK) er ikke slået til.
- **Under transport:** HTTPS til webappen (HSTS), TLS med fuld verifikation til databasen.
- **Hemmeligheder:** databasens adgangskode og, hvis I har aftalt feedback, et Jira-token, der kun kan oprette sager
  i AX Operations' feedbackprojekt. Adgangskoden genereres ved hver udrulning og kendes ikke af AX Operations. Begge
  gemmes kun i Key Vault og læses af app'ene via managed identity.
- **Backup:** PostgreSQL's automatiske backup, 14 dage, lokalt redundant, med point-in-time restore. En gendannelse
  giver en ny server i samme netværk (ca. 10 minutter); `deploy.sh -p <ny server>` peger instansen på den, og den
  gamle server slettes bagefter.
- **Logs:** app-logs og systemlogs fra Container Apps sendes til jeres Log Analytics workspace. Logs indeholder
  ingen adgangskoder eller tokens.

---

## Applikationssikkerhed

- **Login:** OpenID Connect med PKCE mod jeres egen Entra-tenant, så jeres MFA og Conditional Access gælder. Kun
  brugere med en tildelt app-rolle kan logge ind; rettighederne i appen følger rollen (fire niveauer, se guidens
  trin 5.2).
- **Sessioner:** cookie med `HttpOnly`, `Secure` og `SameSite=Lax`. Udløber efter 12 timer og efter 60 minutters
  inaktivitet.
- **HTTP-headere:** Content-Security-Policy, Strict-Transport-Security, `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff` og Referrer-Policy på alle svar.
- **Fejler lukket:** instansen nægter at starte med en ufuldstændig login- eller tenant-opsætning og kan ikke
  startes i udviklertilstand i Azure.
- **Image:** bygget af AX Operations' byggesystem, signeret keyless med Sigstore, med SBOM (SPDX) og byggebevis
  (SLSA provenance). Sådan kontrollerer I det: "Sådan ved I, at det er vores software" (`SIGNERING.md`). Hver
  version scannes for kendte sårbarheder og lækkede hemmeligheder, før den udgives. Containeren kører som en
  ikke-privilegeret bruger.

---

## Azure Policy og egne krav

- **Policies, der ændrer ressourcer:** fx Microsoft Defender for Cloud kan slå *Advanced Threat Protection* til på
  databasen efter udrulningen. Det er uproblematisk; skabelonen overskriver det ikke.
- **Policies, der kan blokere udrulningen:**
  - krav om tags på ressourcer — understøttet: angiv jeres tags i en parameterfil (`deploy.sh -P`), så får alle
    Azure-ressourcer dem;
  - krav om, at private DNS-zoner ligger centralt i et hub-netværk — understøttet: angiv de eksisterende zoner i
    parameterfilen, så opretter skabelonen kun VNet-links til dem (kræver *Private DNS Zone Contributor* på zonerne);
  - forbud mod offentlig ingress på Container Apps;
  - begrænsning af tilladte regioner eller SKU'er.

  Har I sådanne policies, så sig det før udrulningen; de to sidste kræver en tilpasning fra AX Operations.
- **Egen adresse:** webappen kan få jeres eget domæne (fx `pulse.jeresdomæne.dk`) med et managed certifikat. Det er
  ikke en del af standardudrulningen; aftal det med AX Operations.

---

## Levering: installationspakke og image

En installation består af to dele, der leveres hver for sig.

**1. Installationspakken — offentlig, ingen software.** Udrulningsfilerne (`main.bicep`, `registry.bicep`,
`modules/`, `deploy.sh`, `grant-access.sh`, `parameters.example.json`) og kundedokumentationen, også dette dokument,
udgives for hver version i det offentlige repository
[github.com/AXOperations/axo-pulse-install](https://github.com/AXOperations/axo-pulse-install) under tagget
`v<version>`. I henter den i Azure Cloud Shell:

```
curl -fsSL https://github.com/AXOperations/axo-pulse-install/archive/refs/tags/v<version>.tar.gz | tar xz
```

- **Hvem udgiver den:** AX Operations' release-workflow, fra samme commit og i samme kørsel, som bygger og signerer
  imaget. Commit-beskeden i install-repoet nævner kilde-committen, og `release.json` nævner det image-digest,
  pakken hører til.
- **Hvad den indeholder:** kun filerne ovenfor. Ingen kildekode, ingen hemmeligheder, ingen tokens; den eneste
  identifikator er AX Operations' tenant-id (standardværdien for `vendorTenantId`), som ikke er hemmeligt.
- **Hvorfor den er offentlig:** så jeres sikkerhedsteam kan læse præcis, hvad der køres — hver ressource, rettighed
  og kommando — før noget installeres, og sammenligne versioner. Alene installerer pakken intet: imaget kan kun
  hentes med jeres adgangstoken.
- **Integritet:** pakken hentes over HTTPS fra GitHub. En udgivet version udgives aldrig igen (release-workflowet
  afviser et eksisterende tag). Selve pakken er ikke signeret; tillidsankeret er imagets signatur nedenfor, og
  `deploy.sh` importerer kun præcis det digest, I giver den.
- **Hvad scriptsene kører:** `deploy.sh` kører med den indloggede brugers rettigheder og kalder kun `az`:
  `az account show`, `az group show` og `az provider show` (kontrol), `az deployment group create` (de to
  skabeloner), `az acr manifest show-metadata` og `az acr import` (imaget).
  `grant-access.sh` slår worker-identiteten og Microsofts API-apps op med
  `az ad sp show` (og opretter kun et service principal for en Microsoft-API med `az ad sp create`, hvis det mangler
  i jeres tenant), og kalder ellers kun `az rest` for at give eller fjerne de rettigheder, der står under
  "Identiteter og rettigheder". Ingen af dem skriver tokens eller adgangskoder til
  disk eller skærm.

**2. Imaget — privat, signeret.** Selve AXO Pulse er et container-image i AX Operations' private registry
`acraxopulse.azurecr.io`.

- I får et **registry-token** fra AX Operations: et navn (`kunde-<kortnavn>`) og en adgangskode, sendt ad en sikker
  kanal. Tokenet kan kun læse repositoryet `axo-pulse`, kan ikke pushe eller slette, og AX Operations kan
  tilbagekalde det når som helst. Indsæt adgangskoden ved prompten i `deploy.sh`; den vises og gemmes ikke.
- I **kontrollerer signaturen** før importen: imaget signeres keyless med Sigstore af AX Operations' byggeworkflow,
  med SBOM og build-attestation (`SIGNERING.md`).
- `deploy.sh` **importerer præcis det digest** til jeres eget registry. Derefter henter instansen kun fra jeres
  registry med sin managed identity. Der er ingen afhængighed af AX Operations' registry under drift, og AX
  Operations har ingen adgang til jeres registry eller instans.

---

## Opdateringer

1. AX Operations sender versionsnummer og digest på en ny version. I henter installationspakken for den version
   (som ovenfor) og kan sammenligne den med den forrige version i det offentlige repository.
2. I kontrollerer signaturen (`SIGNERING.md`).
3. I kører `deploy.sh` fra den nye pakke med den nye version og digest.
   Imaget importeres til jeres registry, databasens
   adgangskode skiftes, og app'ene genstarter. Databaseændringer køres automatisk, når worker'en starter.

I bestemmer selv, hvornår en opdatering installeres. AX Operations kan ikke opdatere instansen.

---

## Fjernelse

Fjern rettighederne **før** identiteten slettes — ellers kan scriptet ikke længere finde dem:

1. `./grant-access.sh remove <workerIdentityClientId>` (Power Platform- og Graph-rettighederne).
2. Slet resource group'en `rg-axopulse-<kortnavn>`.
3. Slet app-registreringen **AXO Pulse** i Entra ID (**App registrations** → **Deleted applications** for at fjerne
   den helt).
4. Application Insights-ressourcen og F&O-telemetrien fra trin 1-2 er jeres og fjernes separat, hvis I ønsker det.

Key Vault'en ligger derefter som slettet (soft delete) i 90 dage og kan ikke tømmes før, på grund af purge
protection. Den indeholder kun databasens adgangskode til en database, der er slettet.

---

## Omkostninger

Skøn for instansen i North Europe ved almindelig brug, ekskl. moms (Application Insights er beskrevet i
opsætningsguiden):

| Ressource | Ca. pr. måned |
| --- | --- |
| Container Apps (worker altid tændt, web skalerer til nul) | €25-35 |
| PostgreSQL B1ms med 32 GB og backup | €15-20 |
| Container Registry Basic | €5 |
| Private endpoint og private DNS-zoner | €8 |
| Key Vault | under €1 |
| **I alt** | **ca. €55-70** |

Tallene er et skøn; jeres faktiske regning afhænger af region, aftale og forbrug.

---

*AX Operations ApS · AXO Pulse*
