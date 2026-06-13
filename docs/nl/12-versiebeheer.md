# 12 — Versiebeheer & Releases

## Overzicht

PIM Monitor gebruikt [Conventional Commits](https://www.conventionalcommits.org/) met automatische releases via [Release Please](https://github.com/googleapis/release-please). Dit zorgt voor consistente versie-updates en release notes op basis van commit-berichten.

## Format Commitbericht

Alle commits moeten het volgende format gebruiken:

```
<type>: <beschrijving>
```

### Commit-types

| Type | Betekenis | Versie-update | Voorbeeld |
|---|---|---|---|
| `fix:` | Bugfix | Patch (0.1.0 → 0.1.1) | `fix: null assignments in diff afhandelen` |
| `feat:` | Nieuwe feature | Minor (0.1.0 → 0.2.0) | `feat: activation event detection toevoegen` |
| `feat!:` | Breaking change | Major (0.1.0 → 1.0.0) | `feat!: inventory JSON schema wijzigen` |
| `docs:` | Documentatie | Geen release | `docs: webhook gids bijwerken` |
| `chore:` | Onderhoud | Geen release | `chore: dependencies bijwerken` |
| `test:` | Tests | Geen release | `test: diff engine tests toevoegen` |
| `refactor:` | Code refactoring | Geen release | `refactor: git operaties vereenvoudigen` |

### Wat triggert een Release

Een release wordt geactiveerd **alleen** wanneer een `feat:` of `fix:` commit aanraakt:
- `src/**` (PowerShell-scripts)
- `monitor-pipeline.yml` (Azure DevOps-pipeline)
- `scan.yml` (GitHub Actions workflow)

Wijzigingen in documentatie, inventory-bestanden, README, of `.github/` configuratie triggeren **geen** releases.

## Release-proces

### 1. Commit & Push

Push een `feat:` of `fix:` commit dat core-bestanden aanraakt:

```bash
git add src/
git commit -m "feat: nieuw notificatiekanaal toevoegen"
git push origin main
```

### 2. Release Please Opent PR

Release Please GitHub Action opent automatisch een Release PR die:
- Het `VERSION` bestand bumpt (patch, minor of major)
- `CHANGELOG.md` genereert/bijwerkt met release notes
- Alle commits sinds de vorige release vermeldt

### 3. Review & Merge

Controleer de Release PR op:
- Correcte versie-update
- Goede CHANGELOG.md
- Geen ongewenste commits

Merge vervolgens de PR.

### 4. GitHub Release Aangemaakt

Wanneer de Release PR gemerged wordt, maakt Release Please automatisch een GitHub Release aan met:
- Semantic version tag (bijv. `v0.2.0`)
- Release notes uit CHANGELOG.md
- Link naar release-pagina

## VERSION Bestand

Het `VERSION` bestand bevat de huidige versie en dient als single source of truth:

```
0.1.0 # x-release-please-version
```

De comment-marker `# x-release-please-version` vertelt Release Please waar het versienummer moet worden bijgewerkt.

De pipeline leest dit bestand om te weten welke versie de gebruiker draait, en vergelijkt het met de nieuwste GitHub Release om updates te detecteren.

## Meldingen voor Gebruikers

Wanneer een gebruiker PIM Monitor implementeert (Azure DevOps of GitHub Actions):

1. Leest de pipeline hun `VERSION` bestand (huidige versie)
2. Roept GitHub API aan om de nieuwste release op te halen
3. Vergelijkt versies met semantic versioning
4. Stuurt notificatie (mail/webhook) als er nieuwere versie beschikbaar is, met:
   - Huidige versie
   - Nieuwste beschikbare versie
   - Release notes
   - Link naar release-pagina

Dit betekent dat gebruikers automatisch worden geïnformeerd over updates zonder GitHub handmatig te hoeven checken.

## Best Practices

- **Eén ding per commit**: Elk commit vertegenwoordigt één logische wijziging
- **Duidelijke berichten**: Commitberichten moeten helder en beschrijvend zijn
- **Squash indien nodig**: Squash work-in-progress commits voor push
- **Feature branches**: Werk op feature branches, create PRs voor review
- **Geen handmatige versie-updates**: Laat Release Please versioning afhandelen
