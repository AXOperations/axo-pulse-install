# AXO Pulse — opsætningsguide

**Til:** jeres Azure-administrator, Entra-administrator og F&O-administrator.
**Tidsforbrug:** ca. 2 timer i alt, fordelt på de tre roller. Hvert ekstra F&O-miljø tager derefter ca. 15 minutter.

AXO Pulse overvåger jeres Dynamics 365 Finance & Operations-miljøer: X++-fejl, batchjobs, formularer, lange
forespørgsler, kapacitet og Microsofts planlagte opdateringer — samlet i ét overblik med en sundhedsvurdering og
konkrete anbefalinger. Data kommer fra F&O's indbyggede telemetri i Application Insights og fra Power Platform.

AXO Pulse kører som jeres egen instans i jeres eget Azure-abonnement. Instansen deles aldrig med andre kunder, og AXO
Pulse har kun læseadgang — det kan ikke ændre noget i F&O, Azure eller Power Platform. Data forlader kun instansen,
når en bruger selv sender feedback til AX Operations, eller når I opsætter beskeder på e-mail eller Teams (se "Hvad
AXO Pulse gemmer").

Guiden fører jer gennem seks trin. AX Operations er med undervejs og leverer de værdier, I skal bruge. Jeres sikkerheds-
og infrastrukturteam finder præcis, hvad der installeres, hvilke rettigheder der gives, og hvilken netværkstrafik der
er, i "Teknisk beskrivelse til sikkerhed og infrastruktur" (`TEKNISK-BESKRIVELSE.md`).

---

## Overblik

| Trin | Hvad | Udføres af | Tid |
| --- | --- | --- | --- |
| 1 | Opret Application Insights-ressourcen | Azure-administrator | 10 min |
| 2 | Slå telemetri til i F&O | F&O-administrator | 15 min pr. miljø |
| 3 | Udrul AXO Pulse-instansen i jeres Azure-abonnement | Azure-administrator sammen med AX Operations | 30 min |
| 4 | Giv AXO Pulse læseadgang til telemetri og Power Platform | Azure-, Entra- og Power Platform-administrator | 20 min |
| 5 | Opsæt login og roller | Entra-administrator | 20 min |
| 6 | Kontrollér, at data kommer ind | AX Operations sammen med jer | 15 min |

## Før I starter

### Roller, I skal have adgang til

| Rolle | Bruges i |
| --- | --- |
| **Owner** på den resource group, AXO Pulse udrulles i (eller Contributor + User Access Administrator) | Trin 1 og 3 |
| **Contributor** eller **Owner** på abonnementet — kun én gang, til at registrere resource providers | Før I starter |
| **Global Administrator** eller **Privileged Role Administrator** i Entra ID | Trin 4 (app-tilladelser) |
| **Power Platform-administrator** | Trin 4 |
| **Application Administrator** eller **Cloud Application Administrator** i Entra ID | Trin 3 (login-appen) og 5 |
| **System administrator** i hvert F&O-miljø, der skal overvåges | Trin 2 |

### Registrér resource providers

Abonnementet skal have disse resource providers registreret: `Microsoft.App`, `Microsoft.ContainerRegistry`,
`Microsoft.DBforPostgreSQL`, `Microsoft.KeyVault`, `Microsoft.ManagedIdentity`, `Microsoft.Network`,
`Microsoft.OperationalInsights`, `Microsoft.Insights` og `Microsoft.AlertsManagement`. Det er en engangshandling, som
kræver **Contributor** eller **Owner** på abonnementet — ikke kun på resource group'en:

- I portalen: **Subscriptions** → abonnementet → **Settings** → **Resource providers** → vælg hver af dem →
  **Register**.
- Eller i Azure Cloud Shell: `az provider register --namespace <navn> --wait` for hver af dem.

Mangler `Microsoft.AlertsManagement`, oprettes Application Insights i trin 1 stadig, men portalens automatiske
alarmregel *Failure Anomalies* fejler og vises som en fejlet udrulning i resource group'en. AXO Pulse bruger ikke
alarmreglen.

### Det aftaler vi på forhånd

| Emne | Eksempel | Hvem |
| --- | --- | --- |
| Azure-abonnement og resource group til AXO Pulse | `rg-axopulse` | I |
| Azure-region | West Europe | I (skrives i databehandleraftalen) |
| Adresse til AXO Pulse | `https://pulse.jeresdomæne.dk` | I |
| Hvilke F&O-miljøer der overvåges | Produktion, UAT, Test | I |
| Kortnavn til navngivning af ressourcer | `contoso` | AX Operations foreslår |

---

## Trin 1 — Opret Application Insights-ressourcen

**Udføres af:** jeres Azure-administrator.

F&O sender sin telemetri til en Application Insights-ressource i jeres abonnement. AXO Pulse læser derfra. Ressourcen
oprettes først, så telemetrien kan begynde at løbe ind, mens resten sættes op.

Rækkefølgen betyder noget: Application Insights-formularen kan kun vælge et Log Analytics workspace, der allerede
findes, og workspacet kan kun lægges i en resource group, der allerede findes.

### 1.1 Opret resource group

1. [Azure Portal](https://portal.azure.com) → **Resource groups** → **Create**.
2. **Resource group:** den aftalte, fx `rg-axopulse-<kortnavn>`. **Region:** den aftalte region.
3. **Review + create** → **Create**.

AXO Pulse-instansen udrulles i samme resource group i trin 3.

### 1.2 Opret Log Analytics workspace

1. **Create a resource** → søg efter **Log Analytics Workspace** → **Create**.
2. Udfyld:
   - **Resource group:** den fra 1.1.
   - **Name:** `law-<kortnavn>-fo`, fx `law-contoso-fo`.
   - **Region:** den aftalte region.
3. **Review + create** → **Create**.

Har I allerede et workspace til F&O-telemetri i samme region, kan I bruge det og springe dette punkt over.

### 1.3 Opret Application Insights

1. **Create a resource** → søg efter **Application Insights** → **Create**.
2. Udfyld:
   - **Resource group:** den fra 1.1.
   - **Name:** `appi-<kortnavn>-fo`, fx `appi-contoso-fo`.
   - **Region:** den aftalte region.
   - **OTLP support:** lad den stå på **Off**.
   - **Log Analytics Workspace:** vælg workspacet fra 1.2. Står der et foreslået navn med *(new)* og et langt id,
     er det ikke jeres — vælg `law-<kortnavn>-fo` på listen.
3. **Review + create** → **Create**.

### 1.4 Sæt et dagligt loft på datamængden

Sæt loftet **begge steder** — Microsoft bruger det laveste af de to:

1. Log Analytics workspacet fra trin 1.2 → **Usage and estimated costs** → **Daily cap** → **On**.
2. Application Insights-ressourcen fra trin 1.3 → **Usage and estimated costs** → **Daily cap**.

2 GB/dag er et fornuftigt udgangspunkt (se "Omkostninger" sidst i guiden). Loftet er ikke præcist, og data ud over
loftet faktureres stadig; når det er nået, stopper indsamlingen resten af døgnet, så sæt det over det normale forbrug.

### 1.5 Notér to værdier

- **Connection String** fra ressourcens **Overview** — bruges i trin 2.
- **Resource ID**: på **Overview** → **JSON View** øverst til højre → feltet *Resource ID* — bruges i trin 3.

> Alle de F&O-miljøer, der skal overvåges, sender til denne ene ressource. Miljøerne holdes adskilt af et miljø-id
> inde i telemetrien.

---

## Trin 2 — Slå telemetri til i F&O

**Udføres af:** jeres F&O-administrator, i hvert miljø, der skal overvåges.

### 2.1 Aktivér funktionen

1. I F&O: åbn **Feature management**.
2. Søg efter **Monitoring and Telemetry**, markér den, og klik **Enable**.

### 2.2 Find miljøets Environment ID

1. Åbn **Settings** (tandhjulet øverst til højre) → **About**.
2. Notér **Environment ID**.

> **Pas på:** for miljøer, der er oprettet i Power Platform admin center, er Environment ID det samme som
> miljø-id'et i Power Platform. For ældre miljøer oprettet via Lifecycle Services er det et andet id — brug altid
> værdien fra **Settings → About**.

### 2.3 Udfyld Monitoring and Telemetry parameters

1. Gå til **System administration** → **Monitoring and Telemetry parameters**.
2. Fanen **Environments:** tilføj en linje med
   - **Environment ID:** værdien fra 3.2
   - **Environment Mode:** miljøets type (Production, Test eller Development)
3. Fanen **Application Insights Registry:** tilføj en linje for samme Environment Mode med
   - **Connection String:** værdien fra trin 1
   - Lad **Instrumentation Key** stå tomt.

   Findes der allerede en linje for miljøets mode, så kontrollér blot, at den peger på den rigtige ressource.

### 2.4 Vælg, hvad der sendes

Fanen **Configure** — slå følgende til:

- X++ exceptions
- Form runs
- Long running queries
- Batch
- DMF
- User sessions

Der går typisk 5-15 minutter, før de første data dukker op.

---

## Trin 3 — Udrul AXO Pulse-instansen

**Udføres af:** jeres Azure-administrator sammen med AX Operations. Den, der kører udrulningen, skal være **Owner** på
resource group'en fra trin 1.1 og **Application Administrator** (eller Cloud Application Administrator) i Entra ID,
fordi udrulningen også opretter login-appen.

### 3.1 Før udrulningen

1. **Kontrollér, at resource providers er registreret** (se "Før I starter"). Udrulningen tjekker det selv og
   skriver præcis de kommandoer, der mangler.
2. **Kontrollér signaturen** på den version, AX Operations har sendt jer, som beskrevet i "Sådan ved I, at det er vores
   software" (`SIGNERING.md`). I får versionen, imagets digest og et adgangstoken, der kun kan læse AXO Pulse.
3. **Kræver jeres Azure Policy tags eller centrale private DNS-zoner?** Skriv dem i en kopi af
   `parameters.example.json`, og tilføj `-P parameters.json` til kommandoen i 3.2. Uden sådanne krav springes dette
   over. Se "Azure Policy og egne krav" i den tekniske beskrivelse.

### 3.2 Kør udrulningen

Åbn [Azure Cloud Shell](https://shell.azure.com) (Bash) med jeres egen konto, og hent installationspakken for den
version, AX Operations har sendt jer (her `<version>`, fx `0.1.0`):

```
curl -fsSL https://github.com/AXOperations/axo-pulse-install/archive/refs/tags/v<version>.tar.gz | tar xz
cd axo-pulse-install-<version>
```

Pakken er offentlig og indeholder kun udrulningsfilerne og denne dokumentation — I kan læse den igennem på
[github.com/AXOperations/axo-pulse-install](https://github.com/AXOperations/axo-pulse-install), før I kører den. Selve
AXO Pulse hentes af `deploy.sh` med jeres adgangstoken. Kør derefter:

```
./deploy.sh -g rg-axopulse-<kortnavn> -n <kortnavn> \
  -a <Resource ID fra trin 1.5> \
  -d sha256:<digest> -v <version> -u <tokennavn>
```

Scriptet beder om tokenets adgangskode: indsæt den adgangskode, AX Operations har sendt jer ad en sikker kanal, ved
prompten. Den vises ikke og gemmes ikke. Skriv den aldrig ind i selve kommandoen og vis den ikke på skærmen først —
så havner den i Cloud Shells historik. Scriptet importerer derefter den kontrollerede version til jeres eget registry
og udruller instansen. Første gang tager det 10-20 minutter. Det kan køres igen for at opdatere; hver gang skiftes databasens
adgangskode automatisk, og AXO Pulse genstarter.

Udrulningen opretter:

| Ressource | Formål |
| --- | --- |
| To Azure Container Apps (web og worker) | Selve AXO Pulse: webappen, I logger ind på, og worker'en, der henter data |
| To managed identities (`id-axopulse-web` og `id-axopulse-worker`) | Instansens identiteter — der findes ingen client secrets |
| Azure Container Registry | Jeres egen kopi af den kontrollerede AXO Pulse-version |
| Azure Database for PostgreSQL | AXO Pulses egne data (fund, historik, opsætning) |
| Azure Key Vault | Databasens adgangskode, som kun instansen kan læse |
| Et virtuelt netværk | Databasen og Key Vault'en kan kun nås fra instansen, ikke fra internettet |
| Login-appen **AXO Pulse** i Entra ID | Login med jeres egne konti — se trin 5 |
| Læseadgang på Application Insights-ressourcen | `id-axopulse-worker` får *Log Analytics Data Reader* og *Monitoring Reader* på netop den ressource |

Alle ressourcer ejes af jer og faktureres på jeres abonnement. Webappen svarer kun over HTTPS, og instansens logs
sendes til jeres Log Analytics workspace fra trin 1.2.

### 3.3 Notér resultatet

Scriptet slutter med fire værdier. Notér dem — de bruges i trin 4 og 5:

- **webUrl** — AXO Pulses adresse
- **workerIdentityClientId** — client ID for `id-axopulse-worker`
- **webIdentityClientId** — client ID for `id-axopulse-web`
- **loginAppClientId** — login-appens client ID

---

## Trin 4 — Giv AXO Pulse læseadgang

Al adgang gives til worker-identiteten `id-axopulse-worker` fra trin 3. Den får kun læserettigheder, og kun på det,
AXO Pulse har brug for.

### 4.1 Application Insights

Klares af udrulningen i trin 3. Vil I kontrollere det: åbn Application Insights-ressourcen fra trin 1 → **Access
control (IAM)** → **Role assignments**. `id-axopulse-worker` har *Log Analytics Data Reader* og *Monitoring Reader* —
på selve ressourcen, ikke på resource group eller abonnement, så AXO Pulse kun kan læse netop denne telemetri.

### 4.2 Power Platform

**Udføres af:** en Power Platform-administrator.

AXO Pulse læser miljølisten, kapacitet, backups og Microsofts planlagte opdateringer fra Power Platform. Adgangen
gives to steder, som endnu ikke kan klikkes i Power Platform admin center. Kør dette i
[Azure Cloud Shell](https://shell.azure.com) med jeres egen konto, i samme mappe som udrulningsfilerne fra trin 3:

```
./grant-access.sh power-platform <workerIdentityClientId fra trin 3.3>
```

Scriptet giver:

| Adgang | Giver |
| --- | --- |
| Registrering som Power Platform management-app | Miljøliste, kapacitet, F&O-version og planlagte opdateringer |
| Rollen **Power Platform reader** (læseadgang) | Backups, disaster recovery og livscyklushistorik |

Se, hvad identiteten har, med `./grant-access.sh show <client ID>`, og fjern det hele igen med
`./grant-access.sh remove <client ID>`.

### 4.3 Microsoft Graph og Log Analytics

**Udføres af:** en Global Administrator eller Privileged Role Administrator.

En managed identity kan ikke få API-tilladelser via portalen. Kør i Azure Cloud Shell:

```
./grant-access.sh graph <workerIdentityClientId fra trin 3.3> --licenses --auditlog
```

Udelad `--licenses` og `--auditlog`, hvis I ikke ønsker licensoverblikket (se tabellen). Scriptet tildeler
`id-axopulse-worker` disse læsetilladelser:

| Tilladelse | Bruges til | Påkrævet |
| --- | --- | --- |
| Microsoft Graph — `ServiceHealth.Read.All` | Microsofts servicetilstand på forsiden | Anbefalet |
| Microsoft Graph — `Organization.Read.All` | Licensoverblik: jeres Microsoft-licenser og fornyelser | Valgfri (`--licenses`) |
| Microsoft Graph — `User.Read.All` | Licensoverblik: brugere med licens eller tildelingsfejl | Valgfri (`--licenses`) |
| Microsoft Graph — `AuditLog.Read.All` | Licensoverblik: seneste login (kræver Entra ID P1/P2) | Valgfri (`--auditlog`) |

Microsoft cacher en managed identitys adgangstoken i op til 24 timer, så nye Graph-tilladelser kan være så længe om
at slå igennem. Indtil da melder AXO Pulse servicetilstand og licensoverblik som "kræver adgang" — det retter sig
selv.

Ingen af tilladelserne kan skrive noget. I kan se og fjerne dem under **Entra admin center** → **Enterprise
applications** → filter *Managed Identities* → `id-axopulse-worker` → **Permissions**.

---

## Trin 5 — Opsæt login og roller

**Udføres af:** jeres Entra-administrator.

I logger ind på AXO Pulse med jeres almindelige Microsoft-konto. Login sker via en app-registrering i jeres egen
tenant, så jeres MFA og Conditional Access gælder. Login-appen kan kun læse navn og brugernavn på den, der logger ind
— aldrig andre data.

### 5.1 Login-appen

Login-appen **AXO Pulse** blev oprettet af udrulningen i trin 3 — med de fire roller, redirect-adressen, en federated
credential for `id-axopulse-web` (ingen client secret) og *Assignment required* = **Yes**, så kun brugere med en
tildelt rolle kan logge ind. Den kan ses under [Entra admin center](https://entra.microsoft.com) → **Identity** →
**Applications** → **App registrations** → **AXO Pulse**.

| Display name | Value | Typisk til |
| --- | --- | --- |
| AXO Pulse kunde-admin | `Pulse.CustomerAdmin` | Jeres administratorer af AXO Pulse |
| AXO Pulse kunde-læser | `Pulse.CustomerReader` | Øvrige brugere, der skal kunne se overblikket |
| AXO Pulse konsulent | `Pulse.Consultant` | AX Operations' konsulenter (gæster, se 5.3) |
| AXO Pulse AXO-admin | `Pulse.AxoAdmin` | Højst én navngiven ansvarlig hos AX Operations, hvis I ønsker det |

### 5.2 Rollerne

| Må | Kunde-læser | Konsulent | Kunde-admin | AXO-admin |
| --- | :---: | :---: | :---: | :---: |
| Se miljøer, fund og grafer | ✓ | ✓ | ✓ | ✓ |
| Behandle fund: kvittere, udsætte, dæmpe og kommentere | | ✓ | ✓ | ✓ |
| Ændre opsætning: indstillinger, tærskler, opdateringsvagter og testbeskeder | | ✓ | ✓ | ✓ |
| Se licensoverblikket (indeholder personoplysninger) | | | ✓ | ✓ |
| Se Logins — hvem der har logget ind (indeholder personoplysninger) | | | ✓ | ✓ |
| Bestemme, hvem der må se et miljø (5.4) | | | ✓ | ✓ |
| Se et miljø, der er begrænset til grupper, uden at være medlem | | | | ✓ |

**Kunde-læser** er til dem, der skal følge med. **Kunde-admin** er til jeres egne ansvarlige for AXO Pulse og F&O-driften.
**Konsulent** er til AX Operations' konsulenter: de kan arbejde med fund og opsætning, men ser ikke personoplysninger og
kan ikke ændre, hvem der har adgang. **AXO-admin** ser altid alle miljøer, så en fejl i en gruppebegrænsning aldrig låser
alle ude; giv den til højst én navngiven person. Har en bruger flere roller, gælder den højeste.

### 5.3 Tildel roller

1. **Enterprise applications** → **AXO Pulse** → **Users and groups** → **Add user/group** → vælg bruger eller gruppe
   og rolle → **Assign**. Brug gerne grupper (kræver Entra ID P1 eller P2).
2. **AX Operations' konsulenter** inviteres som gæster: **Users** → **New user** → **Invite external user**. Tildel
   derefter gæsten rollen *Konsulent* som ovenfor. Jeres egne regler for MFA og Conditional Access gælder også for
   gæsterne.
3. Når samarbejdet ophører, fjernes rolletildelingen eller gæsten. Adgangen lukker ved næste login, og en åben
   session udløber senest efter 60 minutters inaktivitet.

### 5.4 Begræns et miljø til bestemte grupper (valgfrit)

Som udgangspunkt ser alle med en rolle alle miljøer. Skal fx produktionsmiljøet kun ses af en bestemt gruppe:

1. På login-appen: **Token configuration** → **Add groups claim** → **Groups assigned to the application**, format
   **Group ID** → **Add**.
2. Tildel gruppen til appen (5.3).
3. I AXO Pulse: **Opsætning** → miljøet → **Adgang** → indsæt gruppens Object ID.

---

## Trin 6 — Kontrollér, at data kommer ind

**Udføres af:** AX Operations sammen med jer.

1. Log ind på AXO Pulse med en bruger, der har rollen *Kunde-admin*.
2. Jeres F&O-miljøer dukker op af sig selv under **Opsætning** inden for 15 minutter, hentet fra Power Platform.
3. For hvert miljø: kontrollér under **Identitet og telemetri**, at Environment ID svarer til værdien fra trin 2.2.
4. Efter 15-30 minutter viser **Overblik** de første data.

Vil I selv se, at telemetrien når frem: åbn Application Insights-ressourcen → **Logs**, og kør

```
AppExceptions
| take 10
```

Kommer der rækker retur, flyder data. Der skal være sket mindst én fejl i F&O, før der er noget at vise —
`AppPageViews | take 10` viser formularåbninger.

---

## Hvis noget ikke virker

| Symptom | Sandsynlig årsag | Løsning |
| --- | --- | --- |
| Miljøet vises i AXO Pulse, men uden telemetri | Forkert Environment ID i F&O eller AXO Pulse | Slå id'et op igen under **Settings → About** (trin 2.2), og ret det begge steder |
| Ingen data overhovedet, heller ikke i Application Insights | Funktionen er ikke slået til, eller Configure-fanen står fra | Gennemgå trin 2.1 og 2.4 |
| Data for nogle miljøer, men ikke for ét bestemt | Registry-fanen mangler en linje for netop dette miljøs mode | Trin 2.3 |
| AXO Pulse melder manglende adgang til telemetri | En af de to roller mangler, eller tildelingen er ikke slået igennem endnu | Vent 10 minutter; kontrollér trin 4.1 |
| Ingen miljøer i AXO Pulse | Power Platform-adgangen mangler | Trin 4.2 |
| Licensoverblikket eller servicetilstanden viser "kræver adgang" | Graph-tilladelserne er ikke givet, eller de er givet for under 24 timer siden | Trin 4.3, og vent op til 24 timer — eller lad det være; resten virker |
| Login-fejl `AADSTS50105` | Brugeren har ingen rolle på AXO Pulse | Trin 5.3 |
| "Du har ikke adgang endnu" efter login | Brugeren er logget ind, men har ingen af de fire roller | Trin 5.3 |
| En bruger uden rolle afvises ikke af Microsoft, men lander på "Du har ikke adgang endnu" | Brugeren er Global Administrator — Entra afviser ikke administratorer, selv med *Assignment required* = Yes. AXO Pulse giver stadig ingen adgang uden en rolle | Ingen handling. Test afvisningen med en almindelig bruger |
| Et gruppebegrænset miljø vises ikke | Groups claim mangler, eller gruppen er ikke tildelt appen | Trin 5.4 |

---

## Hvad AXO Pulse gemmer

Alle data ligger i jeres egen instans i jeres eget abonnement.

- **Telemetri og fund:** aggregerede tal og fund fra Application Insights og Power Platform. Fejltekster og
  batchjob-navne gemmes, som F&O skriver dem.
- **Login:** hvert login, logout og afvist login registreres med brugerens Entra Object ID og visningsnavn, så I kan
  se, hvem der har gjort hvad.
- **Licensoverblik (kun hvis I giver tilladelserne i trin 4.3):** kun brugere med mindst én licens eller en
  tildelingsfejl — Entra Object ID, brugernavn, visningsnavn, om kontoen er aktiv, brugertype, licenser og seneste login
  som dato. Aldrig gruppemedlemskaber, roller eller kontaktoplysninger. Rækker slettes 30 dage efter, at brugeren ikke
  længere findes.
- **Beskeder** på e-mail og Teams indeholder aldrig navne — kun antal, fx "5 brugere har fejl i licenstildelingen".
- **Feedback**, som en bruger selv sender fra AXO Pulse, går til AX Operations' Jira: brugerens tekst, et eventuelt
  skærmbillede og en kort teknisk kontekst, som brugeren ser, før der sendes. Uden samtykke til kontakt kun med et
  pseudonym — aldrig navn, e-mail, fund eller telemetri. Detaljer i den tekniske beskrivelse.

---

## Tjekliste

- [ ] Resource providers er registreret (Før I starter)
- [ ] Application Insights-ressourcen er oprettet med daily cap (trin 1)
- [ ] For hvert F&O-miljø: funktionen er slået til, Environment ID og connection string er udfyldt, og de seks
      signaler er slået til (trin 2)
- [ ] Signaturen er kontrolleret (trin 3.1)
- [ ] AXO Pulse-instansen er udrullet, og de fire værdier er noteret (trin 3.3)
- [ ] Power Platform-adgangen er givet (trin 4.2)
- [ ] De ønskede Graph-tilladelser er givet (trin 4.3)
- [ ] Roller er tildelt jeres brugere og AX Operations' konsulenter (trin 5.3)
- [ ] Miljøerne vises med data i AXO Pulse (trin 6)

---

## Omkostninger

**Application Insights** koster ca. €2,57 pr. GB data, med de første 5 GB pr. måned gratis. Et typisk F&O-miljø med
moderat telemetri sender ca. 0,5 GB pr. dag, svarende til ca. 15 GB pr. måned:

15 GB − 5 GB gratis = 10 GB × €2,57 ≈ **€26 pr. måned pr. miljø**, inklusive 90 dages opbevaring.

Det daglige loft fra trin 1 sikrer mod uventede mængder.

**AXO Pulse-instansen** (Container Apps, PostgreSQL og Key Vault) faktureres også på jeres abonnement. AX Operations
oplyser et estimat for den valgte region før udrulningen.

---

*AX Operations ApS · AXO Pulse*
