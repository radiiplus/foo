#ifndef AppVersion
  #define AppVersion "0.2.3"
#endif

#ifndef SourceDir
  #error SourceDir must point to the staged Windows release directory.
#endif

#ifndef OutputDir
  #define OutputDir "."
#endif

#ifndef ProjectRoot
  #error ProjectRoot must point to the FOO repository root.
#endif

[Setup]
AppId={{E3BFAEE7-920F-4D93-AEA4-32764273820C}
AppName=FOO
AppVersion={#AppVersion}
AppPublisher=radiiplus
AppPublisherURL=https://github.com/radiiplus/foo
AppSupportURL=https://github.com/radiiplus/foo/issues
AppUpdatesURL=https://github.com/radiiplus/foo/releases
DefaultDirName={localappdata}\Programs\FOO
DefaultGroupName=FOO
DisableProgramGroupPage=yes
LicenseFile={#ProjectRoot}\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=foo-windows-x64
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\bin\foo.exe
UninstallDisplayName=FOO
Uninstallable=yes
SetupIconFile=..\assets\logo-installer.ico
WizardStyle=modern
WizardSizePercent=110
WizardSmallImageFile=..\assets\logo-installer.png
ChangesEnvironment=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "addtopath"; Description: "Add FOO to my PATH"; GroupDescription: "Command line:"; Flags: checkedonce

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ProjectRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\LICENSE-MIT"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\LICENSE-APACHE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\FOO Command Prompt"; Filename: "{cmd}"; Parameters: "/K ""set PATH={app}\bin;%PATH%&& cd /d {userdocs}&& foo version"""; WorkingDir: "{userdocs}"
Name: "{group}\FOO Documentation"; Filename: "https://github.com/radiiplus/foo/tree/v{#AppVersion}/docs"
Name: "{group}\Uninstall FOO"; Filename: "{uninstallexe}"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\.artifacts\toolchain"

[Run]
Filename: "{cmd}"; Parameters: "/K ""set PATH={app}\bin;%PATH%&& cd /d {userdocs}&& foo version"""; Description: "Open a FOO command prompt"; WorkingDir: "{userdocs}"; Flags: postinstall nowait skipifsilent unchecked

[Code]
const
  EnvironmentKey = 'Environment';
  EnvironmentValue = 'Path';
  InstallerKey = 'Software\FOO';
  PathAddedValue = 'InstallerAddedPath';

function NormalizePathEntry(Value: String): String;
begin
  Value := RemoveQuotes(Trim(Value));
  while (Length(Value) > 3) and (Value[Length(Value)] = '\') do
    Delete(Value, Length(Value), 1);
  Result := Lowercase(Value);
end;

function PathContains(const CurrentPath, Entry: String): Boolean;
var
  Remaining, Part: String;
  Separator: Integer;
begin
  Result := False;
  Remaining := CurrentPath;
  while Remaining <> '' do
  begin
    Separator := Pos(';', Remaining);
    if Separator = 0 then
    begin
      Part := Remaining;
      Remaining := '';
    end
    else
    begin
      Part := Copy(Remaining, 1, Separator - 1);
      Delete(Remaining, 1, Separator);
    end;
    if NormalizePathEntry(Part) = NormalizePathEntry(Entry) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function RemovePathEntry(const CurrentPath, Entry: String): String;
var
  Remaining, Part: String;
  Separator: Integer;
begin
  Result := '';
  Remaining := CurrentPath;
  while Remaining <> '' do
  begin
    Separator := Pos(';', Remaining);
    if Separator = 0 then
    begin
      Part := Remaining;
      Remaining := '';
    end
    else
    begin
      Part := Copy(Remaining, 1, Separator - 1);
      Delete(Remaining, 1, Separator);
    end;
    Part := Trim(Part);
    if (Part <> '') and (NormalizePathEntry(Part) <> NormalizePathEntry(Entry)) then
    begin
      if Result <> '' then
        Result := Result + ';';
      Result := Result + Part;
    end;
  end;
end;

procedure SetUserPath(AddEntry: Boolean);
var
  CurrentPath, BinDirectory: String;
  AddedPath: Cardinal;
begin
  BinDirectory := ExpandConstant('{app}\bin');
  if not RegQueryStringValue(HKCU, EnvironmentKey, EnvironmentValue, CurrentPath) then
    CurrentPath := '';

  if AddEntry then
  begin
    if not PathContains(CurrentPath, BinDirectory) then
    begin
      if (CurrentPath <> '') and (CurrentPath[Length(CurrentPath)] <> ';') then
        CurrentPath := CurrentPath + ';';
      CurrentPath := CurrentPath + BinDirectory;
      RegWriteExpandStringValue(HKCU, EnvironmentKey, EnvironmentValue, CurrentPath);
      RegWriteDWordValue(HKCU, InstallerKey, PathAddedValue, 1);
    end;
  end
  else
  begin
    if RegQueryDWordValue(HKCU, InstallerKey, PathAddedValue, AddedPath) and
      (AddedPath = 1) and PathContains(CurrentPath, BinDirectory) then
      RegWriteExpandStringValue(HKCU, EnvironmentKey, EnvironmentValue,
        RemovePathEntry(CurrentPath, BinDirectory));
    RegDeleteValue(HKCU, InstallerKey, PathAddedValue);
    RegDeleteKeyIfEmpty(HKCU, InstallerKey);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    SetUserPath(True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    SetUserPath(False);
end;
