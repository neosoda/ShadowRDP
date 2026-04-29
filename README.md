# ShadowRDP

> Toolkit PowerShell pour deploiement GPO et assistance RDP Shadow.

## Apercu rapide

| Module | Fichier principal | Objectif |
|---|---|---|
| Deploiement | `Deploy-RDPGPO-Startup.cmd` -> `Deploy-RDPGPO.ps1` | Configure RDP, Shadow, RemoteRegistry et pare-feu |
| Assistant | `RemoteDesktopAssistantV1.4.ps1` | UI operateur: sessions Shadow + scan reseau |
| Versionning | `New-ScriptVersion.ps1` | Cree des versions incrementales sans ecrasement |

## Arborescence

```text
SHADOW RDP/
|- Deploy-RDPGPO-Startup.cmd
|- Deploy-RDPGPO.ps1
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
- Deploiement GPO idempotent avec marqueur de version
- Wrapper `.cmd` pour forcer `ExecutionPolicy Bypass` uniquement au lancement
- Mode audit `-WhatIf` et mode retrait `-Uninstall`
- WinRM optionnel via `-EnableWinRM`
- Pas de redemarrage `TermService` par defaut

## Compatibilite RemoteDesktopAssistant

`Deploy-RDPGPO.ps1` prepare les postes cibles pour les appels utilises par
`RemoteDesktopAssistantV1.4.ps1`:

| Fonction client | Prerequis cible configure |
|---|---|
| Ping / scan reseau | Regle pare-feu `FPS-ICMP4-ERQ-In*` |
| `qwinsta.exe /server:<poste>` | `RemoteRegistry` demarre + regles `RemoteSvc*`, `RemoteEventLog*`, `WMI-*`, `FPS-SMB-In*` |
| `mstsc.exe /v:<poste>` | RDP active + regles `RemoteDesktop-*` |
| `mstsc.exe /shadow:<id> /control /noConsentPrompt` | `AllowRemoteRPC=1` + policy `Shadow=2` par defaut |

WinRM n'est pas requis par l'application et reste desactive par defaut.

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
.\New-ScriptVersion.ps1 -SourceFile .\Deploy-RDPGPO.ps1
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

# Script de deploiement manuel (console admin)
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -MaxAgeDays 0

# Audit sans modification (console admin)
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -WhatIf -MaxAgeDays 0

# Retrait de la configuration (console admin)
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -Uninstall

# Activer aussi WinRM si necessaire
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -EnableWinRM -MaxAgeDays 0
```

## Deploiement GPO Startup

Dans la GPO, referencer le wrapper:

```text
Deploy-RDPGPO-Startup.cmd
```

Le wrapper lance PowerShell en `-NoProfile -NonInteractive -ExecutionPolicy Bypass`
et appelle `Deploy-RDPGPO.ps1` dans le meme dossier.

Procedure detaillee:

```text
GPO-DEPLOYMENT.md
```

Parametres par defaut du wrapper:

- `ShadowMode 2`
- `AllowedRemoteAddresses LocalSubnet`
- `NetworkWaitTimeoutSeconds 0`
- `MaxAgeDays 7`
- pas de redemarrage `TermService`
- pas d'activation WinRM

Codes retour:

- `0`: succes
- `1`: erreur critique
- `2`: droits insuffisants

## Prerequis

- Windows PowerShell 5.1+
- Droits administrateur local
- Execution conseillee en PowerShell 64 bits
- Contexte AD/GPO selon votre organisation
- Windows 10 / 11 / Windows Server avec module `NetSecurity`

## Tests rapides

```powershell
# Syntaxe PowerShell
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\Deploy-RDPGPO.ps1), [ref]$tokens, [ref]$errors
)
$errors

# Audit sans modification, console admin
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -WhatIf -MaxAgeDays 0

# Deploiement force, console admin
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -MaxAgeDays 0
```

Verifications poste cible:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\GrandEst\CMIL\RDPShadowDeploy'
Get-Service RemoteRegistry,TermService
Get-NetFirewallRule -Name 'RemoteDesktop-*','RemoteSvc*','FPS-ICMP4-ERQ-In*','FPS-SMB-In*' -ErrorAction SilentlyContinue
```

## Bonnes pratiques

- Tester en preproduction avant diffusion large
- Limiter les ouvertures pare-feu au strict necessaire
- Journaliser les executions en environnement de prod
- Preferer les GPO natives pour les parametres stables (RDP, NLA, firewall)
- Garder le script pour l'idempotence, les ecarts de parc et l'observabilite

## Support

Pour un diagnostic rapide, inclure:

- Version du script utilisee
- Version de Windows / PowerShell
- Message d'erreur exact
- Contexte reseau (VLAN, routage, firewall)
