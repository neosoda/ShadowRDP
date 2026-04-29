# ShadowRDP

<div align="center">

### Toolkit PowerShell pour déploiement GPO et assistance RDP Shadow

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell&logoColor=white)](#prerequis)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011%20%7C%20Server-0078D4?logo=windows&logoColor=white)](#prerequis)
[![Type](https://img.shields.io/badge/Projet-Administration%20RDP-0A7E8C)](#fonctionnalites)
[![Etat](https://img.shields.io/badge/Etat-Production-2EA043)](#execution-rapide)

</div>

---

## Navigation

- [Éthique et usage responsable](#ethique-et-usage-responsable)
- [Vue d'ensemble](#vue-densemble)
- [Fonctionnalités](#fonctionnalites)
- [Compatibilité Assistant <-> Déploiement](#compatibilite-assistant----deploiement)
- [Démarrage rapide](#demarrage-rapide)
- [Déploiement GPO (startup)](#deploiement-gpo-startup)
- [Scan réseau (CIDR)](#scan-reseau-cidr)
- [Prérequis](#prerequis)
- [Tests et vérifications](#tests-et-verifications)
- [Bonnes pratiques](#bonnes-pratiques)

---

## Ethique et usage responsable

> Ce toolkit est destiné uniquement à l'administration légitime, au support utilisateur autorisé et à la maintenance d'un parc maîtrisé.

- Utiliser uniquement sur des machines et sessions pour lesquelles vous avez une autorisation explicite.
- Informer les utilisateurs quand une prise en main distante est engagée, surtout en mode Shadow sans consentement.
- Respecter les politiques internes, la charte SI, et la réglementation applicable (RGPD, journalisation, traçabilité).
- Limiter les règles réseau et permissions au strict nécessaire (principe du moindre privilège).
- Activer et conserver des logs d'exploitation pour audit, sécurité et investigations.

### Dérives à éviter

- Surveillance discrète ou accès non justifié à des sessions utilisateur.
- Déploiement massif hors cadre de validation sécurité/DSI.
- Exposition réseau excessive (pare-feu trop permissif, WinRM activé sans besoin).
- Utilisation du script à des fins offensives, d'espionnage ou de contournement de contrôle.

En cas de doute, suspendre l'usage et valider avec le RSSI/équipe sécurité avant déploiement.

---

## Vue d'ensemble

| Module | Fichier principal | Objectif |
|---|---|---|
| Déploiement | `Deploy-RDPGPO-Startup.cmd` -> `Deploy-RDPGPO.ps1` | Configure RDP, Shadow, RemoteRegistry et pare-feu |
| Assistant | `RemoteDesktopAssistantV1.4.ps1` | UI opérateur: sessions Shadow + scan réseau |

<details>
<summary><strong>Arborescence du projet</strong></summary>

```text
SHADOW RDP/
|- Deploy-RDPGPO-Startup.cmd
|- Deploy-RDPGPO.ps1
|- RemoteDesktopAssistantV1.4.ps1
|- GPO-DEPLOYMENT.md
|- README.md
|- _OLD/
```

</details>

---

## Fonctionnalites

- Assistance RDP Shadow (visualisation, contrôle, no-consent)
- Lancement RDP classique
- Scan réseau en onglet dédié (IP + nom d'hôte)
- Progression temps réel + annulation de scan
- Déploiement GPO idempotent avec marqueur de version
- Wrapper `.cmd` pour forcer `ExecutionPolicy Bypass` uniquement au lancement
- Mode audit `-WhatIf` et mode retrait `-Uninstall`
- WinRM optionnel via `-EnableWinRM`
- Pas de redémarrage `TermService` par défaut

---

## Compatibilite Assistant <-> Deploiement

`Deploy-RDPGPO.ps1` prépare les postes cibles pour les appels utilisés par `RemoteDesktopAssistantV1.4.ps1`.

| Fonction client | Prérequis cible configuré |
|---|---|
| Ping / scan réseau | Règle pare-feu `FPS-ICMP4-ERQ-In*` |
| `qwinsta.exe /server:<poste>` | `RemoteRegistry` démarré + règles `RemoteSvc*`, `RemoteEventLog*`, `WMI-*`, `FPS-SMB-In*` |
| `mstsc.exe /v:<poste>` | RDP activé + règles `RemoteDesktop-*` |
| `mstsc.exe /shadow:<id> /control /noConsentPrompt` | `AllowRemoteRPC=1` + policy `Shadow=2` par défaut |

> WinRM n'est pas requis par l'application et reste désactivé par défaut.

---

## Demarrage rapide

### Assistant opérateur

```powershell
powershell -ExecutionPolicy Bypass -File .\RemoteDesktopAssistantV1.4.ps1
```

### Déploiement manuel (admin)

```powershell
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -MaxAgeDays 0
```

### Audit sans modification

```powershell
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -WhatIf -MaxAgeDays 0
```

### Retrait de la configuration

```powershell
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -Uninstall
```

### Activation WinRM (optionnel)

```powershell
powershell -ExecutionPolicy Bypass -File .\Deploy-RDPGPO.ps1 -EnableWinRM -MaxAgeDays 0
```

---

## Deploiement GPO Startup

Dans la GPO, référencer le wrapper:

```text
Deploy-RDPGPO-Startup.cmd
```

Le wrapper lance PowerShell en `-NoProfile -NonInteractive -ExecutionPolicy Bypass` et appelle `Deploy-RDPGPO.ps1` dans le même dossier.

Documentation détaillée:

```text
GPO-DEPLOYMENT.md
```

<details>
<summary><strong>Paramètres par défaut du wrapper</strong></summary>

- `ShadowMode 2`
- `AllowedRemoteAddresses LocalSubnet`
- `NetworkWaitTimeoutSeconds 0`
- `MaxAgeDays 7`
- Pas de redémarrage `TermService`
- Pas d'activation WinRM

</details>

<details>
<summary><strong>Codes retour</strong></summary>

- `0`: succès
- `1`: erreur critique
- `2`: droits insuffisants

</details>

---

## Scan reseau CIDR

Le champ scan accepte:

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

- Le scan teste les hôtes utilisables du réseau
- La fenêtre reste réactive (scan non bloquant via `DispatcherTimer`)
- Le bouton `Annuler` interrompt proprement le scan en cours
- Journalisation des erreurs scan dans `%TEMP%\RemoteDesktopAssistant-scan.log`

---

## Prerequis

- Windows PowerShell 5.1+
- Droits administrateur local
- Exécution conseillée en PowerShell 64 bits
- Contexte AD/GPO selon votre organisation
- Windows 10 / 11 / Windows Server avec module `NetSecurity`

---

## Tests et verifications

### Validation syntaxe PowerShell

```powershell
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\Deploy-RDPGPO.ps1), [ref]$tokens, [ref]$errors
)
$errors
```

### Vérifications post-déploiement (poste cible)

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\GrandEst\CMIL\RDPShadowDeploy'
Get-Service RemoteRegistry,TermService
Get-NetFirewallRule -Name 'RemoteDesktop-*','RemoteSvc*','FPS-ICMP4-ERQ-In*','FPS-SMB-In*' -ErrorAction SilentlyContinue
```

---

## Bonnes pratiques

- Tester en préproduction avant diffusion large
- Limiter les ouvertures pare-feu au strict nécessaire
- Journaliser les exécutions en environnement de prod
- Préférer les GPO natives pour les paramètres stables (RDP, NLA, firewall)
- Garder le script pour l'idempotence, les écarts de parc et l'observabilité
