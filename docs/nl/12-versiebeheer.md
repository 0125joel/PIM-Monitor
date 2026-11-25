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

Release Please controleert conventionele commits op public `main`. Een `feat:`- of `fix:`-commit kan tot een release-PR leiden; een `docs:`-commit op zichzelf niet.

De configuratie sluit `docs/**` en `inventory/**` uit. Een mirrorcommit kan ook het synchronisatiebestand wijzigen. Beoordeel daarom de release-PR en vertrouw niet alleen op de bestandspaden.

## Release-proces

### 1. Beoordeel de wijziging

Beoordeel de wijziging en de commitboodschap voordat ze public `main` bereiken.

### 2. Release Please Opent PR

Als een release nodig is, opent de Release Please GitHub Action een release-PR of werkt die bij. De PR:
- Het `VERSION` bestand bumpt (patch, minor of major)
- `CHANGELOG.md` genereert/bijwerkt met release notes
- Relevante wijzigingen sinds de vorige release vermeldt

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

## Catalogusversiebeheer

De gepubliceerde EAM-catalogus (`/catalog/v1/eam-catalog.json`) heeft een eigen `schemaVersion`, los van de appversie:

- Een brekende wijziging van de catalogus (een verwijderd of hernoemd veld, een veranderde betekenis) is een `feat!:`-commit en een nieuw pad, `/catalog/v2/`. v1 blijft online tot consumenten zijn overgestapt.
- Een optioneel veld toevoegen is een `feat:`-commit en een minor bump van `schemaVersion`. Een tekstwijziging is een patch.
- `catalogVersion` is de versie van de inhoud (een datum). Die verandert als rollen of beleid veranderen en raakt `schemaVersion` niet.

`docs-site/src/constants.ts` heeft dezelfde `x-release-please-version`-marker als `VERSION`, dus ook de appversie op de voorpagina wordt door Release Please bijgewerkt.

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
