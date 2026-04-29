# ShadowRDP

Scripts PowerShell pour **déployer** et **assister** des sessions **RDP** (Shadow / prise en main à distance) : mise en place via **GPO**, outil d’assistance, ressources associées.

---

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Contenu du dépôt](#contenu-du-dépôt)
- [Pré-requis](#pré-requis)
- [Démarrage rapide](#démarrage-rapide)
- [Bonnes pratiques & sécurité](#bonnes-pratiques--sécurité)
- [Support](#support)

---

## Fonctionnalités

- Déploiement/paramétrage “Shadow RDP” via **GPO**
- Script d’assistance “Remote Desktop Assistant”
- Ressources (icône + documentation)

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `Deploy-RDPShadow-GPO.ps1` | Déploiement / paramétrage via GPO |
| `RemoteDesktopAssistantV1.ps1` | Script d’assistance (v1) |
| `RemoteDesktopAssistantV1.2.ps1` | Script d’assistance (v1.2) |
| `Remoteicon.ico` | Icône |
| `Remote_Desktop_Assistant_Documentation.pdf` | Documentation |

## Pré-requis

- Windows + PowerShell (**Windows PowerShell 5.1** ou **PowerShell 7+**)
- Droits adaptés à votre contexte (GPO / admin local / délégations)

## Démarrage rapide

1) Cloner :

```powershell
git clone https://github.com/neosoda/ShadowRDP
cd ShadowRDP
```

2) Ouvrir/consulter les scripts :

- `Deploy-RDPShadow-GPO.ps1` pour le volet GPO
- `RemoteDesktopAssistantV1.2.ps1` (ou v1) pour l’assistance

3) Lire la doc :

- `Remote_Desktop_Assistant_Documentation.pdf`

## Bonnes pratiques & sécurité

- Tester **en environnement de recette** avant production.
- Appliquer le **principe du moindre privilège** (droits, GPO, délégations).
- Tracer/valider les usages (journalisation, processus interne) selon votre politique SI.

## Support

- Ouvrir une issue sur GitHub : décrire le contexte (OS, version PowerShell, domaine/AD, erreurs exactes).
