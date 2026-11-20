# AXO Pulse — installationspakke 0.1.0-rc.3

Udrulningsfilerne til en kundehostet AXO Pulse-instans i jeres eget Azure-abonnement, udgivet af AX Operations ApS.
Pakken indeholder ingen software: AXO Pulse-imaget hentes fra AX Operations' registry med det adgangstoken, I får
fra AX Operations, og I kontrollerer dets signatur før installationen.

| | |
| --- | --- |
| Version | `0.1.0-rc.3` |
| Image-digest | `sha256:e794150660174a0a70a9b437d95630384403da7609d24f1e07c2c64db24103e2` |

- **Installationsguide:** [docs/OPSAETNING.md](docs/OPSAETNING.md)
- **Teknisk beskrivelse til sikkerheds- og infrastrukturteams:** [dansk](docs/TEKNISK-BESKRIVELSE.md) ·
  [English](docs/TECHNICAL-DESCRIPTION.md)
- **Kontrol af signaturen:** [docs/SIGNERING.md](docs/SIGNERING.md)

Hent pakken i Azure Cloud Shell (Bash):

```
curl -fsSL https://github.com/AXOperations/axo-pulse-install/archive/refs/tags/v0.1.0-rc.3.tar.gz | tar xz
cd axo-pulse-install-0.1.0-rc.3
```

Spørgsmål: kontakt AX Operations.
