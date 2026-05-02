# ShadowRDP

<div align="center">

### Toolkit PowerShell pour déploiement GPO et assistance RDP Shadow

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell&logoColor=white)](#prerequis)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011%20%7C%20Server-0078D4?logo=windows&logoColor=white)](#prerequis)
[![Type](https://img.shields.io/badge/Projet-Administration%20RDP-0A7E8C)](#fonctionnalites)
[![État](https://img.shields.io/badge/Etat-Production-2EA043)](#demarrage-rapide)

</div>

---

## Navigation

- [Éthique et usage responsable](#ethique-et-usage-responsable)
- [Aperçu visuel](#apercu-visuel)
- [Vue d'ensemble](#vue-densemble)
- [Fonctionnalités](#fonctionnalites)
- [Compatibilité Assistant <-> Déploiement](#compatibilite-assistant----deploiement)
- [Démarrage rapide](#demarrage-rapide)
- [Déploiement GPO (startup)](#deploiement-gpo-startup)
- [Scan réseau (CIDR)](#scan-reseau-cidr)
- [EDR et faux positifs](#edr-et-faux-positifs)
- [Prérequis](#prerequis)
- [Tests et vérifications](#tests-et-verifications)
- [Bonnes pratiques](#bonnes-pratiques)

---

## Éthique et usage responsable

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

## Aperçu visuel

<p align="center">
  <img src="public/Capture1.png" alt="Capture 1 - interface ShadowRDP" width="48%" />
  <img src="public/Capture2.png" alt="Capture 2 - interface ShadowRDP" width="48%" />
</p>

---

## Vue d'ensemble

| Module | Fichier principal | Objectif |
|---|---|---|
| Déploiement | `Deploy-RDPGPO-Startup.cmd` → `Deploy-RDPGPO.ps1` | Configure RDP, Shadow, RemoteRegistry et pare-feu |
| Assistant | `RemoteDesktopAssistant.cmd` → `RemoteDesktopAssistantV1.4.ps1` | UI opérateur : sessions Shadow + scan réseau |

<details>
<summary><strong>Arborescence du projet</strong></summary>

```text
SHADOW RDP/
|- RemoteDesktopAssistant.cmd          ← lanceur (élévation + appel du .ps1)
|- RemoteDesktopAssistantV1.4.ps1
|- Deploy-RDPGPO-Startup.cmd
|- Deploy-RDPGPO.ps1
|- GPO-DEPLOYMENT.md
|- README.md
|- _OLD/
```

</details>

---

## Fonctionnalités

**Assistant opérateur**

- Assistance RDP Shadow (visualisation, contrôle, no-consent)
- Double-clic sur une session pour lancer Shadow directement
- Lancement RDP classique
- Badge opérateur dynamique (`DOMAINE\utilisateur` connecté)
- Tri des colonnes dans les tableaux de sessions et de scan

**Scan réseau**

- Scan parallèle (`PingAsync` × 16) — /24 en ~16 s au lieu de ~200 s
- Résultats affichés en temps réel au fur et à mesure de la détection
- Annulation propre avec libération des ressources réseau
- Export CSV des résultats via boîte de dialogue native
- Bascule automatique vers l'onglet Assistant RDP après « Utiliser la sélection »
- Touche Entrée sur le champ CIDR pour lancer le scan
- Journalisation des erreurs dans `%TEMP%\RemoteDesktopAssistant-scan.log`

**Déploiement GPO**

- Script idempotent avec marqueur de version
- Wrapper `.cmd` pour forcer `ExecutionPolicy Bypass` uniquement au lancement
- Mode audit `-WhatIf` et mode retrait `-Uninstall`
- WinRM optionnel via `-EnableWinRM`
- Pas de redémarrage `TermService` par défaut

---

## Compatibilité Assistant <-> Déploiement

`Deploy-RDPGPO.ps1` prépare les postes cibles pour les appels utilisés par `RemoteDesktopAssistantV1.4.ps1`.

| Fonction client | Prérequis cible configuré |
|---|---|
| Ping / scan réseau | Règle pare-feu `FPS-ICMP4-ERQ-In*` |
| `qwinsta.exe /server:<poste>` | `RemoteRegistry` démarré + règles `RemoteSvc*`, `RemoteEventLog*`, `WMI-*`, `FPS-SMB-In*` |
| `mstsc.exe /v:<poste>` | RDP activé + règles `RemoteDesktop-*` |
| `mstsc.exe /shadow:<id> /control /noConsentPrompt` | `AllowRemoteRPC=1` + policy `Shadow=2` par défaut |

> WinRM n'est pas requis par l'application et reste désactivé par défaut.

---

## Démarrage rapide

### Assistant opérateur

```text
RemoteDesktopAssistant.cmd   ← double-cliquer (élévation gérée par le wrapper)
```

Ou en ligne de commande :

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

## Déploiement GPO Startup

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

## Scan réseau CIDR

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

- Le scan teste les hôtes utilisables du réseau via **16 pings asynchrones en parallèle**
- La fenêtre reste réactive (scan non bloquant via `DispatcherTimer` + `PingAsync`)
- Les hôtes en ligne apparaissent **en temps réel** dans le tableau
- Le bouton `Annuler` interrompt proprement le scan en cours et libère les ressources
- Le bouton `Exporter CSV` sauvegarde les résultats via une boîte de dialogue native
- Le bouton `Utiliser la sélection` copie l'IP vers l'Assistant RDP et bascule l'onglet automatiquement
- Journalisation des erreurs scan dans `%TEMP%\RemoteDesktopAssistant-scan.log`

---

## EDR et faux positifs

Ce toolkit manipule des primitives surveillées par les EDR (RDP shadow, énumération de sessions distantes, scan réseau). Des alertes de type _suspicious PowerShell_ ou _network reconnaissance_ sont possibles selon la politique de l'EDR. Les mesures ci-dessous réduisent significativement l'exposition.

### Signaux déclencheurs connus

| Signal | Règle type | Mitigation |
|---|---|---|
| `powershell.exe` se re-spawn avec `-Verb RunAs` | `proc_creation_win_powershell_privilege_escalation` | Utiliser `RemoteDesktopAssistant.cmd` (élévation portée par `cmd.exe`) |
| `-ExecutionPolicy Bypass` dans les args d'un processus enfant | `proc_creation_win_powershell_exec_bypass` | Idem — le Bypass reste dans le `.cmd`, pas dans le `.ps1` |
| Pings ICMP en masse (16+ simultanés) | `net_connection_win_susp_mass_icmp` | Batch limité à 16 — réduire si nécessaire via `$Script:NetworkScanBatchSize` |
| `qwinsta.exe /server:<remote>` | `proc_creation_win_qwinsta_remote` | Inhérent à la fonction — justifié par le contexte support |
| `mstsc.exe /shadow /noConsentPrompt` | `proc_creation_win_mstsc_shadow_noconsent` | Inhérent — à whitelister après validation RSSI |
| Script PS non signé exécuté avec Bypass | Heuristique générique | **Signer le script** avec le CA interne (voir ci-dessous) |

### Démarrage sécurisé : utiliser le wrapper CMD

```text
RemoteDesktopAssistant.cmd   ← double-cliquer ici (ou raccourci Admin)
```

Ce wrapper élève via `cmd.exe → ShellExecute runas` plutôt que `powershell.exe → powershell.exe`. La chaîne de processus résultante est moins ambiguë pour un EDR.

### Signature Authenticode (recommandé)

Signer le script avec un certificat de code de la PKI interne élimine les alertes heuristiques sur les scripts non signés :

```powershell
# Récupérer le certificat de signature de code (PKI interne)
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1

# Signer le script
Set-AuthenticodeSignature -FilePath .\RemoteDesktopAssistantV1.4.ps1 -Certificate $cert -TimestampServer "http://timestamp.votredomaine.local"

# Vérifier
Get-AuthenticodeSignature .\RemoteDesktopAssistantV1.4.ps1
```

Une fois signé, passer la politique d'exécution de `Bypass` à `AllSigned` dans le wrapper.

### Traçabilité opérateur (audit log)

Chaque action sensible est journalisée dans `C:\Windows\Logs\RemoteDesktopAssistant-audit.log` :

```text
2026-05-02 14:23:11 | DOMAINE\jdupont | PC-SUPPORT | DEMARRAGE         |
2026-05-02 14:23:18 | DOMAINE\jdupont | PC-SUPPORT | SESSIONS_ENUM     | 192.168.1.45
2026-05-02 14:23:21 | DOMAINE\jdupont | PC-SUPPORT | SHADOW_NoConsent  | 192.168.1.45 (SessionID=2, Utilisateur=jmartin)
```

Ce log constitue la preuve d'usage légitime lors d'une investigation SOC.

### Exclusion HarfangLab

Après signature et validation RSSI, ajouter une exclusion basée sur le hash SHA-256 du script ou sur la signature Authenticode dans la console HarfangLab (**Politique > Exclusions > Processus**).

```powershell
# Obtenir le hash pour l'exclusion
Get-FileHash .\RemoteDesktopAssistantV1.4.ps1 -Algorithm SHA256
```

---

## Prérequis

- Windows PowerShell 5.1+
- Droits administrateur local
- Exécution conseillée en PowerShell 64 bits
- Contexte AD/GPO selon votre organisation
- Windows 10 / 11 / Windows Server avec module `NetSecurity`

---

## Tests et vérifications

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
