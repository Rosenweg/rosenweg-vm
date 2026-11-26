; SPDX-License-Identifier: GPL-3.0-or-later
; Installer fuer Rosenweg Virtuelle Computer (Inno Setup 6).
; Aufruf ueber windows/installer/bauen.sh, das Version, Buendel, UsbDk-MSI und
; Symbol mit /D uebergibt.
;
; - Installation pro Person nach %LOCALAPPDATA%\Programs, ohne Administrator-
;   rechte (wie die App selbst: kein Dienst, kein Treiber, kein VPN).
; - Optional UsbDk (Treiber fuer USB-Durchreichen, Apache-2.0): nur dieser
;   Schritt fragt einmal nach Administratorrechten (msiexec, UAC).
; - Gleiche AppId = Update an Ort und Stelle; Anmeldung und Geraete-Kennung
;   liegen im Benutzerprofil (flutter_secure_storage) und bleiben.

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef Baunummer
  #define Baunummer "0"
#endif

[Setup]
AppId={{84037510-F685-42B1-9911-C68BD2560B44}
AppName=Rosenweg Virtuelle Computer
AppVersion={#Version}
AppVerName=Rosenweg Virtuelle Computer {#Version}
VersionInfoVersion={#Version}.{#Baunummer}
AppPublisher=Rosenweg
AppPublisherURL=https://www.rosenweg4303.ch/apps
AppSupportURL=https://www.rosenweg4303.ch/apps
AppCopyright=Rosenweg, GPL-3.0-or-later
DefaultDirName={autopf}\Rosenweg Virtuelle Computer
DefaultGroupName=Rosenweg
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
SetupIconFile={#Symbol}
UninstallDisplayIcon={app}\rosenweg_vm.exe
UninstallDisplayName=Rosenweg Virtuelle Computer
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "Symbol auf dem Desktop"; Flags: unchecked
Name: "usbdk"; Description: "USB-Geraete an Computer durchreichen (Treiber UsbDk, fragt einmal nach Administratorrechten)"; Flags: unchecked

[Files]
Source: "{#Buendel}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#UsbDk}"; DestDir: "{tmp}"; DestName: "UsbDk_x64.msi"; Tasks: usbdk; Flags: deleteafterinstall

[InstallDelete]
; alte DLLs einer frueheren Fassung (andere MSYS2-Versionen) nicht liegen lassen
Type: files; Name: "{app}\*.dll"

[Icons]
Name: "{autoprograms}\Rosenweg Virtuelle Computer"; Filename: "{app}\rosenweg_vm.exe"
Name: "{autodesktop}\Rosenweg Virtuelle Computer"; Filename: "{app}\rosenweg_vm.exe"; Tasks: desktopicon

[Run]
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\UsbDk_x64.msi"" /passive /norestart"; StatusMsg: "Treiber UsbDk wird installiert ..."; Tasks: usbdk; Flags: shellexec waituntilterminated; Verb: "runas"
Filename: "{app}\rosenweg_vm.exe"; Description: "Rosenweg Virtuelle Computer starten"; Flags: nowait postinstall skipifsilent
