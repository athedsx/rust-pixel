#ifndef AppVersion
  #define AppVersion "0.5.1"
#endif
#ifndef SourceRoot
  #define SourceRoot ".."
#endif

[Setup]
AppId={{46D4E724-7AE7-4BB1-8BCB-B488E8981C01}
AppName=Rust Pixel Bridge
AppVersion={#AppVersion}
AppPublisher=Rust Pixel contributors
DefaultDirName={localappdata}\Programs\Rust Pixel Bridge
DefaultGroupName=Rust Pixel Bridge
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile={#SourceRoot}\LICENSE
OutputDir={#SourceRoot}\dist
OutputBaseFilename=RustPixelBridge-{#AppVersion}-windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UninstallDisplayName=Rust Pixel Bridge
UninstallDisplayIcon={app}\asprite-mcp.exe
SetupLogging=yes

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "claude"; Description: "Configurar Claude Desktop"; Check: ClaudeInstalled

[Files]
Source: "{#SourceRoot}\target\release\asprite-mcp.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\target\release\rust-pixel-agent.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Configuração MCP"; Filename: "{app}\mcp.json"
Name: "{group}\Verificar conexão"; Filename: "{cmd}"; Parameters: "/k """"{app}\asprite-mcp.exe"" doctor --aseprite-dir ""{code:GetAsepriteDir}"""""; WorkingDir: "{app}"
Name: "{group}\Desinstalar Rust Pixel Bridge"; Filename: "{uninstallexe}"

[UninstallRun]
Filename: "{app}\asprite-mcp.exe"; Parameters: "uninstall --install-dir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveRustPixelExtension"

[UninstallDelete]
Type: files; Name: "{app}\mcp.json"
Type: files; Name: "{app}\installation.json"

[Code]
var
  AsepritePage: TInputDirWizardPage;

function ClaudeInstalled: Boolean;
begin
  Result := DirExists(ExpandConstant('{userappdata}\Claude'));
end;

function GetAsepriteDir(Param: String): String;
begin
  Result := AsepritePage.Values[0];
end;

procedure InitializeWizard;
begin
  AsepritePage := CreateInputDirPage(wpSelectDir,
    'Aseprite', 'Onde salvar a extensão?',
    'Use a pasta de configuração do Aseprite. Para instalações portáteis, selecione a pasta que contém aseprite.ini.',
    False, '');
  AsepritePage.Add('Pasta de configuração:');
  AsepritePage.Values[0] := ExpandConstant('{param:ASEPRITEDIR|' +
    GetPreviousData('AsepriteDir', ExpandConstant('{userappdata}\Aseprite')) + '}');
  WizardForm.FinishedLabel.Caption :=
    'Rust Pixel Bridge foi instalado. Reinicie o Aseprite e o cliente MCP. ' +
    'No primeiro uso, marque "Don''t show this specific alert again for this script" antes de permitir cada acesso. ' +
    'A configuração para outros clientes está em mcp.json na pasta do programa.';
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'AsepriteDir', AsepritePage.Values[0]);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Arguments: String;
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    Arguments := 'install --install-dir "' + ExpandConstant('{app}') +
      '" --aseprite-dir "' + AsepritePage.Values[0] + '"';
    if WizardIsTaskSelected('claude') then
      Arguments := Arguments + ' --claude';
    if not Exec(ExpandConstant('{app}\asprite-mcp.exe'), Arguments,
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Não foi possível configurar a extensão do Aseprite.');
    if ResultCode <> 0 then
      RaiseException('Falha ao configurar a extensão. Execute asprite-mcp.exe install na pasta do programa para ver o erro.');
  end;
end;
