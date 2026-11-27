# Eigener Windows-Runner (`win-runner`, VM 142)

> **Stand 27.11.2026: Der Runner ist für rosenweg-vm `windows.yml` noch nicht
> brauchbar.** `msys2/setup-msys2` hängt bei `pacman-key --init`, weil gpg im
> MSYS2-Laufzeitsystem (3.6.10/3.6.12) keine Verbindung zum gpg-agent bekommt.
> Der gpg-agent läuft mit 100 % CPU, oder gpg meldet „IPC connect
> fehlgeschlagen“. Gleich verhält sich die systemweite MSYS2-Installation.
> Vermutete Ursache: Windows 11 26H1 (Build 28000) des Klons. Die
> GitHub-Runner laufen auf Server 2025 (Build 26100). Der CPU-Typ `host` half
> nicht. Was ohne MSYS2 auskommt (checkout, setup-go, flutter-action, VS, Inno
> Setup), läuft. Mögliche Auswege: ein Windows mit Build 26100 (Server 2025 oder
> 11 24H2) oder eine neuere MSYS2-Laufzeit.

Zweiter selbst gehosteter Runner der Organisation neben `rosenweg-runner-1`
(Linux, CT 140, siehe [ci.md](ci.md)). Er ist für die Windows-Läufe der
privaten Repos gedacht (Flutter Windows-Desktop, MSYS2 mit spice-gtk, Inno
Setup), damit sie keine GitHub-Minuten kosten. Ein Workflow nutzt ihn mit

```yaml
runs-on: [self-hosted, rosenweg-windows]
```

Sonst braucht es keine Änderung: Die Schritte von `windows.yml` (rosenweg-vm,
rosenweg-salz) laufen dort unverändert. Das Repo muss in der Runner-Gruppe
`rosenweg-privat` stehen (Organisationseinstellungen → Actions → Runner groups).

## Maschine

| Was | Wert |
|---|---|
| Proxmox | VM 142 `win-runner` auf pve2, Speicher `vms` (Ceph), onboot=1 |
| Herkunft | Vollklon von VM 107 `win11-1` aus dem Snapshot `vor-rosenweg-agent`, 27.11.2026 (win11-1 blieb unverändert) |
| System | Windows 11 Enterprise (Build 28000), Arbeitsgruppe `ROSENWEG-RUNNER`, Name `WIN-RUNNER`, **nicht in der Domäne** |
| Ressourcen | 8 vCPU (CPU-Typ `host`), 16 GB RAM (ohne Ballooning), 150 GB |
| Netz | `vmbr2` (VLAN 2, Servernetz) wie CT 140: 100.64.2.62/24, Gateway und DNS 100.64.2.1 |
| Fernzugang | RDP aus. Zugriff über die Proxmox-Konsole oder `qm guest exec 142 …` (QEMU-Gast-Agent und VirtIO-Treiber stammen von win11-1) |
| Sicherung | im vzdump-Auftrag „Alle Gaeste, täglich“ (01:00, PBS-Rosenweg, `all 1`) |
| Lizenz | **nicht aktiviert** (Entscheid von Stefan, 27.11.2026). Der Produktschlüssel wurde vor dem ersten Netzstart entfernt (`slmgr /upk`, `/cpky`), damit der Klon die MAK-Aktivierung von win11-1 nicht beansprucht. |

Die Maschinen-SID ist dieselbe wie bei win11-1. Das stört nicht, solange der
Klon nie in die Domäne kommt. **Darum nie in die Domäne aufnehmen**; dafür
müsste man ihn neu aufsetzen (oder `sysprep /generalize`). Den AD-Eintrag von
win11-1 hat das Ablösen nicht berührt (offline, `UnjoinDomainOrWorkgroup` ohne
Konto-Deaktivierung).

Entfernt wurden: die Profile `stefan.mueller` (Domäne) und `Stefan` (lokal)
samt Konto `Stefan`, die geplanten Aufgaben `Rosenweg *` (Laufwerke, Drucker,
Programme, BGInfo, Aufräumen, AD Photo Sync), die AppLocker-Regeln und die
übrigen Domänen-Richtlinien. Den Rosenweg-Agent gibt es im Klon nicht, weil
der Snapshot vor seiner Installation entstand.

Konten:
- `rwadmin`: lokaler Administrator für die Technik
- `gh-runner`: Dienstkonto des Runners, normaler Benutzer ohne Administratorrechte

Die Passwörter beider Konten liegen auf pve2 in `/root/win-runner-zugang.txt`
(nur root).

Windows Update und Defender sind eingeschaltet. Ausnahmen gibt es keine.

## Werkzeuge (systemweit)

| Werkzeug | Ort |
|---|---|
| Git for Windows (bash für `shell: bash`) | `C:\Program Files\Git` |
| GitHub CLI `gh` (Release-Schritte) | `C:\Program Files\GitHub CLI` |
| PowerShell 7 | `C:\Program Files\PowerShell\7` |
| 7-Zip | `C:\Program Files\7-Zip` |
| Inno Setup 6 (`ISCC.exe`) | `C:\Program Files (x86)\Inno Setup 6` |
| Visual Studio 2022 Build Tools, Desktop C++ (MSVC, Redist, Windows SDK, CMake) | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |
| MSYS2 (**unvollständig**, siehe unten) | `C:\msys64` |
| jq (braucht `subosito/flutter-action`) | `C:\tools\bin\jq.exe` |

Alle Ordner stehen im System-PATH. **Nach einer Änderung am PATH den Dienst
`actions.runner.Rosenweg.win-runner` neu starten**, sonst sieht der Runner
den alten PATH (erster Testlauf: `bash`/`pwsh: command not found`).

Dazu sind der Entwicklermodus (symbolische Links ohne Admin, nötig für
`flutter pub get` mit Plugins) und lange Pfade eingeschaltet.

Die Workflows holen Go, Flutter und MSYS2 weiterhin selbst
(`actions/setup-go`, `subosito/flutter-action` in den Tool-Cache,
`msys2/setup-msys2` mit `release: true` in den Arbeitsordner). Die
systemweiten Kopien braucht man für Arbeiten von Hand oder für Läufe, die
`release: false` setzen.

Eingerichtet wurde alles mit einem PowerShell-Skript, das als SYSTEM über den
Gast-Agent lief: jeweils die neueste Fassung von den Herstellerseiten bzw. aus
GitHub-Releases, Visual Studio mit
`vs_BuildTools.exe --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`.

## Runner

- Ordner `C:\actions-runner`, Arbeitsordner `C:\actions-runner\_work`
- Dienst `actions.runner.Rosenweg.win-runner`, läuft als `.\gh-runner` und startet automatisch
- Organisation Rosenweg, Gruppe `rosenweg-privat`, Labels `self-hosted, Windows, X64, rosenweg-windows`

Neu registrieren (z. B. nachdem er in GitHub entfernt wurde), in einer
Administrator-PowerShell auf der VM:

```powershell
cd C:\actions-runner
.\config.cmd remove --token <Entfernungs-Token>
.\config.cmd --unattended --url https://github.com/Rosenweg --token <Registrierungs-Token> `
  --name win-runner --runnergroup rosenweg-privat --labels rosenweg-windows `
  --work _work --runasservice --windowslogonaccount '.\gh-runner' --windowslogonpassword '<Passwort>'
```

Die Tokens holt man mit `gh api -X POST orgs/Rosenweg/actions/runners/registration-token`
bzw. `.../remove-token`. Sie sind eine Stunde gültig.

## Wie er entstand (27.11.2026)

1. `qm clone 107 142 --snapname vor-rosenweg-agent --full 1 --target pve2 --storage vms`.
   Der Klon bekam eine neue MAC und vor dem ersten Start `link_down=1`.
2. Der Gast-Agent startete im Klon nicht. Abhilfe: einmal von der
   Windows-ISO starten (mit frischer EFI-Disk, sonst startet OVMF direkt den
   Windows Boot Manager). In der Setup-Konsole `drvload vioscsi.inf`, dann
   offline einen einmaligen Dienst eintragen, der den Agent neu einrichtet.
   Danach kam die Original-EFI-Disk wieder zurück.
3. Offline als SYSTEM über den Gast-Agent: Produktschlüssel entfernen,
   Domäne verlassen, Arbeitsgruppe und Name setzen, Rosenweg-Aufgaben,
   AppLocker und Richtlinien entfernen, Autologon und RDP ausschalten, `rwadmin`
   anlegen. Nach dem Neustart die Profile löschen.
4. Netz auf `vmbr2` mit fester Adresse, Wiederherstellungspartition entfernen
   und C: auf 150 GB erweitern (WinRE liegt jetzt auf C:), Werkzeuge, Runner.
