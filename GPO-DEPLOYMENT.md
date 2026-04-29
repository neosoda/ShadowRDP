# Deploiement GPO - RDP Shadow

Ce document explique comment deployer `Deploy-RDPGPO.ps1` par GPO Computer Startup.

## Fichiers a deployer

Copier ces deux fichiers dans un dossier accessible par les ordinateurs du domaine,
idealement dans `SYSVOL`:

```text
\\<domaine>\SYSVOL\<domaine>\scripts\RDPShadow\
|- Deploy-RDPGPO-Startup.cmd
|- Deploy-RDPGPO.ps1
```

Le `.cmd` et le `.ps1` doivent rester dans le meme dossier.

## Creation de la GPO

1. Ouvrir `Group Policy Management`.
2. Creer une nouvelle GPO, par exemple `CMIL - RDP Shadow Deploy`.
3. Lier la GPO a l'OU qui contient les postes cibles.
4. Editer la GPO.
5. Aller dans:

```text
Computer Configuration
> Policies
> Windows Settings
> Scripts (Startup/Shutdown)
> Startup
```

6. Cliquer sur `Add`.
7. Selectionner le script:

```text
Deploy-RDPGPO-Startup.cmd
```

8. Ne pas appeler directement le `.ps1` dans la GPO.

## Pourquoi utiliser le wrapper CMD

Le wrapper lance PowerShell avec:

```text
-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass
```

Cela evite les blocages lies a la politique d'execution PowerShell locale.
Le bypass ne s'applique qu'a ce processus et ne modifie pas la machine.

Le wrapper force aussi PowerShell 64 bits:

```text
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
```

## Parametres par defaut

Le wrapper execute:

```cmd
Deploy-RDPGPO.ps1 ^
  -ShadowMode 2 ^
  -AllowedRemoteAddresses "LocalSubnet" ^
  -NetworkWaitTimeoutSeconds 0 ^
  -NetworkRetryIntervalSeconds 5 ^
  -MaxAgeDays 7
```

Effet:

- RDP active.
- NLA active.
- Shadow RDP autorise en controle sans consentement.
- `qwinsta /server:<poste>` rendu possible.
- Ping entrant autorise pour le scan reseau.
- Pare-feu limite a `LocalSubnet`.
- Pas d'activation WinRM par defaut.
- Pas de redemarrage `TermService` par defaut.

## Filtrage et securite

Recommandations:

- Appliquer la GPO uniquement aux OU de postes concernes.
- Eviter `Authenticated Users` si le perimetre doit etre strict.
- Utiliser un groupe de securite ordinateur si necessaire.
- Garder `AllowedRemoteAddresses` a `LocalSubnet` ou definir des sous-reseaux precis.
- Ne pas utiliser `Any` sauf besoin temporaire de diagnostic.

Exemple de restriction par sous-reseaux:

```cmd
-AllowedRemoteAddresses "10.10.0.0/16,10.20.0.0/16"
```

## Verification sur un poste cible

Forcer l'application des GPO:

```cmd
gpupdate /force
shutdown /r /t 0
```

Apres redemarrage, verifier le log:

```powershell
Get-Content C:\Windows\Logs\RDP-Shadow-Deploy.log -Tail 80
```

Verifier l'etat de deploiement:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\GrandEst\CMIL\RDPShadowDeploy'
```

Verifier les cles principales:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
  -Name fDenyTSConnections,AllowRemoteRPC

Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
  -Name UserAuthentication

Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
  -Name Shadow
```

Valeurs attendues:

```text
fDenyTSConnections = 0
AllowRemoteRPC     = 1
UserAuthentication = 1
Shadow             = 2
```

Verifier les services:

```powershell
Get-Service TermService,RemoteRegistry
```

Verifier les regles pare-feu:

```powershell
Get-NetFirewallRule -Name 'RemoteDesktop-*','RemoteSvc*','RemoteEventLog*','WMI-*','FPS-SMB-In*','FPS-ICMP4-ERQ-In*' `
  -ErrorAction SilentlyContinue |
  Select-Object Name,Enabled,Profile
```

## Test depuis le poste operateur

Depuis le poste qui lance `RemoteDesktopAssistantV1.4.ps1`:

```cmd
ping <poste-cible>
qwinsta /server:<poste-cible>
mstsc /v:<poste-cible>
```

Puis tester dans l'application:

- scan reseau;
- chargement des sessions;
- connexion RDP classique;
- Shadow en mode `NoConsent`.

## Codes retour

Le script retourne:

```text
0 = succes
1 = erreur critique
2 = droits insuffisants
```

En contexte GPO Startup, le script s'execute normalement sous:

```text
NT AUTHORITY\SYSTEM
```

## Depannage rapide

Si le log indique une ancienne version:

- verifier que le bon fichier a ete copie dans `SYSVOL`;
- verifier que le poste execute bien le wrapper `.cmd`;
- supprimer l'ancienne copie locale eventuelle;
- forcer `gpupdate /force` puis redemarrer.

Si `ping` echoue:

- verifier la regle `FPS-ICMP4-ERQ-In*`;
- verifier que le pare-feu applique le bon profil reseau;
- verifier que `AllowedRemoteAddresses` inclut le poste operateur.

Si `qwinsta /server:<poste>` echoue:

- verifier que `RemoteRegistry` est demarre;
- verifier les regles `RemoteSvc*`, `RemoteEventLog*`, `WMI-*`, `FPS-SMB-In*`;
- verifier les droits de l'utilisateur operateur sur le poste cible.

Si le Shadow affiche une erreur de strategie de groupe:

- verifier que `Shadow=2`;
- verifier qu'aucune autre GPO ne remet une valeur differente;
- lancer `gpresult /h C:\Temp\gpresult.html` sur le poste cible.

## Notes importantes

Les parametres stables comme RDP, NLA et certaines regles pare-feu peuvent aussi
etre configures par GPO native. Le script reste utile pour tracer, corriger les
ecarts de parc et garantir une configuration minimale compatible avec
`RemoteDesktopAssistantV1.4.ps1`.
