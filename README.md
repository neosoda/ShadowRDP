# ShadowRDP

> Toolkit PowerShell pour deploiement GPO et assistance RDP Shadow.

## Apercu rapide

| Module | Fichier principal | Objectif |
|---|---|---|
| Deploiement | `Deploy-RDPShadow-GPO.ps1` | Configure RDP, Shadow, WinRM et pare-feu |
| Assistant | `RemoteDesktopAssistantV1.4.ps1` | UI operateur: sessions Shadow + scan reseau |
| Versionning | `New-ScriptVersion.ps1` | Cree des versions incrementales sans ecrasement |

## Arborescence

```text
SHADOW RDP/
|- Deploy-RDPShadow-GPO.ps1
|- RemoteDesktopAssistantV1.4.ps1
|- New-ScriptVersion.ps1
|- README.md
|- _OLD/
```

## Fonctionnalites

- Assistance RDP Shadow (visualisation, controle, no-consent)
- Lancement RDP classique
- Scan reseau en onglet dedie (IP + nom d'hote)
- Progression temps reel + annulation de scan
- Deploiement GPO idempotent

## Scan reseau (CIDR)

Le champ scan accepte les syntaxes:

```text
x.x.x.x/x
x.x.x.x
x.x.x
```

Exemples:

- `192.168.1.0/24`
- `192.168.1.0` (auto converti en `/24`)
- `192.168.1` (auto converti en `192.168.1.0/24`)
- `10.20.30.0/24`
- `172.16.5.0/26`

Comportement:

- Le scan teste les hotes utilisables du reseau
- La fenetre reste reactive (scan non bloquant via `DispatcherTimer`)
- Le bouton `Annuler` interrompt proprement le scan en cours
- Journalisation des erreurs scan dans `%TEMP%\\RemoteDesktopAssistant-scan.log`

## Versionning intelligent

Creer une nouvelle version de script:

```powershell
.\New-ScriptVersion.ps1 -SourceFile .\RemoteDesktopAssistantV1.4.ps1
.\New-ScriptVersion.ps1 -SourceFile .\Deploy-RDPShadow-GPO.ps1
```

Regles:

- Detecte les versions existantes (`NomVx.y.ps1`)
- Incremente automatiquement la version mineure
- N'ecrit rien si le contenu est identique a la derniere version
- Forcer une version: ajouter `-Force`

## Execution rapide

```powershell
# Assistant operateur
powershell -ExecutionPolicy Bypass -File .\RemoteDesktopAssistantV1.4.ps1

# Script de deploiement
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPShadow-GPO.ps1
```

## Prerequis

- Windows PowerShell 5.1+
- Droits administrateur local
- Contexte AD/GPO selon votre organisation

## Bonnes pratiques

- Tester en preproduction avant diffusion large
- Limiter les ouvertures pare-feu au strict necessaire
- Journaliser les executions en environnement de prod

## Support

Pour un diagnostic rapide, inclure:

- Version du script utilisee
- Version de Windows / PowerShell
- Message d'erreur exact
- Contexte reseau (VLAN, routage, firewall)
