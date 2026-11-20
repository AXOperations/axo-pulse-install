# AXO Pulse — sådan ved I, at det er vores software

**Til:** jeres IT-sikkerhed og den Azure-administrator, der installerer AXO Pulse.
**Kort fortalt:** hver version af AXO Pulse er signeret digitalt i det øjeblik, den bygges. Før I tager en version i
brug, kører I én kommando, som bekræfter, at den er bygget af AX Operations' eget byggesystem ud fra vores kildekode —
og at ingen har ændret den siden. Der findes ingen hemmelig nøgle, der kan blive stjålet.

---

## Hvad signaturen beviser — og hvad den ikke beviser

| Signaturen beviser | Signaturen beviser ikke |
| --- | --- |
| At imaget er bygget af AX Operations' byggesystem (GitHub Actions) ud fra AX Operations' kode-repository | At koden er fejlfri eller uden sårbarheder — det dækker vores test og sårbarhedsscanning |
| At det er bygget fra en udgivet version (et versions-tag), ikke fra et udkast | Hvem hos AX Operations der besluttede udgivelsen |
| At ikke én byte er ændret, siden det blev bygget — heller ikke i et registry undervejs | — |
| At ingen andre kan udgive sig for at være AX Operations | — |

Signaturen sidder på imagets **digest**: et fingeraftryk (SHA-256) af hele imaget. Ændres blot én byte, får imaget et
andet digest, og signaturen passer ikke længere.

---

## Sådan bliver en version til

```
 AX Operations           GitHub Actions                     Sigstore (offentlig)       AX Operations' registry
 ─────────────           ──────────────                     ────────────────────       ───────────────────────
 1. tagger v0.1.0  ──►   2. bygger imaget
                         3. beder om et certifikat   ──►    4. bekræfter, at det er
                            (beviser hvem den er)              præcis dette byggejob,
                                                               og udsteder et certifikat,
                                                               der gælder i 10 minutter
                         5. signerer imagets digest
                            med certifikatet         ──►    6. noterer signaturen i en
                                                               offentlig, uforanderlig log
                         7. lægger image, signatur,  ─────────────────────────────────►  acraxopulse.azurecr.io
                            SBOM og byggebevis i                                          /axo-pulse:0.1.0
                            registret
```

1. En udgivelse starter, når AX Operations sætter et versions-tag (fx `v0.1.0`) på en godkendt version af koden.
2. GitHub Actions bygger imaget i et frisk, midlertidigt byggemiljø hos GitHub.
3. Byggejobbet beviser over for Sigstore, hvem det er — med et token, som GitHub udsteder til netop dette job, og som
   nævner AX Operations' repository, byggefilen og versions-tagget.
4. Sigstore (et åbent projekt under Linux Foundation, som også bruges af bl.a. Kubernetes og npm) udsteder et
   certifikat med de oplysninger. Certifikatet gælder i 10 minutter, og nøglen til det findes kun i byggejobbets
   hukommelse — bagefter eksisterer den ikke.
5. Byggejobbet signerer imagets digest.
6. Signaturen noteres i Sigstores offentlige transparenslog (Rekor). Loggen kan kun tilføjes til, aldrig ændres, så
   en signatur kan ikke tilbagedateres eller skjules.
7. Image, signatur, SBOM og byggebevis lægges i AX Operations' container registry.

Byggesystemet har ingen gemte adgangskoder: det logger ind i Azure med en kortlivet identitet, som kun virker for
versions-tags og kun kan skrive til netop dette registry.

---

## Hvad der er offentligt

Certifikatet i den offentlige log indeholder:

- navnet på AX Operations' repository (`AXOperations/axo-pulse`) og byggefilen (`release.yml`)
- versions-tagget og den commit (fingeraftryk af koden), der blev bygget
- tidspunktet og et link til byggejobbet (som kun AX Operations kan åbne)

Kildekoden, selve imaget og jeres data er **ikke** offentlige. Imaget ligger i et privat registry, som kun kunder med
et adgangstoken fra AX Operations kan læse fra.

---

## Sådan kontrollerer I en version

I får fra AX Operations:

| | Eksempel |
| --- | --- |
| Versionen | `0.1.0` |
| Imagets digest | `sha256:d01e2c1c…` (det fulde fingeraftryk, 64 tegn) |
| Et adgangstoken, der kun kan læse AXO Pulse | navn `kunde-contoso` og en adgangskode, sendt ad en sikker kanal |

### 1. Installér cosign

cosign er Sigstores officielle værktøj (open source). Installér det efter
[vejledningen](https://docs.sigstore.dev/cosign/system_config/installation/) — fx `brew install cosign` på Mac eller
`winget install sigstore.cosign` på Windows. Brug version 3 eller nyere.

### 2. Log ind med jeres token

```
cosign login acraxopulse.azurecr.io -u kunde-contoso --password-stdin
```

Indsæt adgangskoden, tryk Enter og derefter Ctrl+D (Mac/Linux) eller Ctrl+Z og Enter (Windows). Adgangskoden vises
ikke og havner ikke i kommandohistorikken.

### 3. Kontrollér signaturen

Kontrollér altid ud fra **digestet**, ikke versionsnummeret — så kontrollerer I præcis det image, I importerer bagefter.

```
cosign verify acraxopulse.azurecr.io/axo-pulse@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/AXOperations/axo-pulse/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

De to sidste linjer siger: "kun signaturer fra AX Operations' byggefil `release.yml`, kørt for et versions-tag
`vX.Y.Z`, og bevidnet af GitHub". Versioner, der kun er til AX Operations' egen afprøvning (fx `v0.1.0-rc.1`), bliver
afvist af netop den kommando.

**Når det er i orden**, skriver cosign:

```
Verification for acraxopulse.azurecr.io/axo-pulse@sha256:<digest> --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

**Når det ikke er i orden**, slutter cosign med en fejl og exit-kode 1, fx:

```
error during command execution: no matching attestations: failed to verify certificate identity:
no matching CertificateIdentity found, last error: expected SAN value to match regex "…", got "…"
```

Så skal imaget **ikke** tages i brug. Kontakt AX Operations.

### 4. Importér den kontrollerede version til jeres eget registry

```
az acr import --name <jeres-registry> \
  --source acraxopulse.azurecr.io/axo-pulse@sha256:<digest> \
  --image axo-pulse:0.1.0 \
  --username kunde-contoso --password '<adgangskode>'
```

Imaget får samme digest hos jer, så signaturen gælder stadig. Peg derefter jeres Container Apps på
`<jeres-registry>.azurecr.io/axo-pulse@sha256:<digest>` — med digest, så de altid kører præcis den kontrollerede
version. Jeres Container Apps henter fra jeres eget registry med deres managed identity; adgangstokenet bruges kun til
importen og skal ikke ligge i jeres miljø.

---

## Indholdsfortegnelse og byggebevis

Hver version har to ekstra oplysninger knyttet til sig, som jeres sikkerhedsafdeling kan læse:

- **SBOM** (software bill of materials): en liste over alle komponenter og deres versioner i imaget, i det åbne format
  SPDX. Brug den til at slå op, om en nyopdaget sårbarhed rammer AXO Pulse.
- **Byggebevis** (provenance, SLSA): hvilket byggejob der byggede imaget, fra hvilken kode og med hvilke indstillinger.

```
docker buildx imagetools inspect acraxopulse.azurecr.io/axo-pulse@sha256:<digest> --format '{{json .SBOM}}'
docker buildx imagetools inspect acraxopulse.azurecr.io/axo-pulse@sha256:<digest> --format '{{json .Provenance}}'
```

(Log først Docker ind med `docker login acraxopulse.azurecr.io -u kunde-contoso`.)

---

## Spørgsmål, vi ofte får

**Hvorfor ikke en almindelig signeringsnøgle?**
En nøgle kan blive stjålet, og så kan tyven signere i vores navn, indtil vi opdager det. Med keyless signering findes
der ingen nøgle: hver signatur laves med et certifikat, der kun gælder i 10 minutter og kun for ét byggejob.

**Hvad hvis nogen bryder ind hos GitHub eller Sigstore?**
En signatur er kun gyldig, hvis den både er udstedt til AX Operations' repository og noteret i den offentlige log.
Loggen overvåges af uafhængige parter, så en falsk signatur ville blive opdaget. Og I kontrollerer altid mod det
digest, AX Operations har sendt jer.

**Kan AX Operations ændre en version, efter vi har kontrolleret den?**
Nej. En ændring giver et nyt digest, og I kører det digest, I har kontrolleret og importeret til jeres eget registry.

**Hvem kan udgive en version?**
Kun AX Operations' egne udviklere med skriveadgang til repositoriet, og kun fra den godkendte hovedlinje af koden.

**Kommer der en signatur i AX Operations' firmanavn?**
Ja. Vi tilføjer en signatur fra Microsoft Artifact Signing, hvor Microsoft har valideret AX Operations ApS som firma.
Den kommer oven i den nuværende signatur, så versioner, I allerede har kontrolleret, forbliver gyldige.

---

*AX Operations ApS · AXO Pulse*
