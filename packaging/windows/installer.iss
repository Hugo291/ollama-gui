; Inno Setup script for Ollama GUI. Built by CI with:
;   iscc /DAppVersion=2.0.0 packaging\windows\installer.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F1C2B7E-3D4A-4E8B-9C1D-0A2B3C4D5E6F}
AppName=Ollama GUI
AppVersion={#AppVersion}
AppPublisher=Hugo Ferreira
AppPublisherURL=https://github.com/Hugo291/ollama-gui
DefaultDirName={autopf}\Ollama GUI
DefaultGroupName=Ollama GUI
DisableProgramGroupPage=yes
; Per-user install by default: no administrator rights needed.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=OllamaGUI-Windows-Setup
SetupIconFile=app.ico
UninstallDisplayIcon={app}\ollama-gui.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\target\release\ollama-gui.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Ollama GUI"; Filename: "{app}\ollama-gui.exe"
Name: "{autodesktop}\Ollama GUI"; Filename: "{app}\ollama-gui.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ollama-gui.exe"; Description: "{cm:LaunchProgram,Ollama GUI}"; Flags: nowait postinstall skipifsilent
