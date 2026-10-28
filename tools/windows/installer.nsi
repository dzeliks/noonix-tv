; noonix tv for windows: a per-user install (no admin) in %LOCALAPPDATA%\Programs\Noonix TV,
; a start menu entry and an uninstaller. /S installs quietly (app updates). the app keeps its
; data in %LOCALAPPDATA%\Noonix TV, which an uninstall leaves alone
;   makensis -DVERSION=0.1.0 -DVERSION_NUM=0.1.0 -DSRC=<app folder> -DOUT=<setup.exe> tools/windows/installer.nsi
Unicode true
ManifestDPIAware true
RequestExecutionLevel user
SetCompressor /SOLID lzma

!include MUI2.nsh
!include FileFunc.nsh

!define NAME "Noonix TV"
!define EXE "noonix-tv.exe"
!define UNINST "Software\Microsoft\Windows\CurrentVersion\Uninstall\NoonixTV"

Name "${NAME}"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\Programs\${NAME}"
InstallDirRegKey HKCU "${UNINST}" "InstallLocation"
BrandingText "${NAME} ${VERSION}"

VIProductVersion "${VERSION_NUM}.0"
VIAddVersionKey "ProductName" "${NAME}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${NAME} setup"
VIAddVersionKey "CompanyName" "aleksa.sh"
VIAddVersionKey "LegalCopyright" "GPL-3.0-or-later"

!define MUI_ICON "${__FILEDIR__}\..\..\dist\windows\noonix-tv.ico"
!define MUI_UNICON "${__FILEDIR__}\..\..\dist\windows\noonix-tv.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; the first is the default, windows' own language picks the other
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SerbianLatin"

Section
    SetShellVarContext current
    SetOutPath "$INSTDIR"
    ; an older version's files go first: nothing stale stays behind
    RMDir /r "$INSTDIR\qml"
    RMDir /r "$INSTDIR\services"
    File /r "${SRC}\*"
    WriteUninstaller "$INSTDIR\uninstall.exe"
    CreateShortcut "$SMPROGRAMS\${NAME}.lnk" "$INSTDIR\${EXE}"

    WriteRegStr HKCU "${UNINST}" "DisplayName" "${NAME}"
    WriteRegStr HKCU "${UNINST}" "DisplayVersion" "${VERSION}"
    WriteRegStr HKCU "${UNINST}" "Publisher" "aleksa.sh"
    WriteRegStr HKCU "${UNINST}" "URLInfoAbout" "https://aleksa.sh"
    WriteRegStr HKCU "${UNINST}" "DisplayIcon" "$INSTDIR\${EXE}"
    WriteRegStr HKCU "${UNINST}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINST}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr HKCU "${UNINST}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegDWORD HKCU "${UNINST}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINST}" "NoRepair" 1
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    WriteRegDWORD HKCU "${UNINST}" "EstimatedSize" $0
SectionEnd

Section "Uninstall"
    SetShellVarContext current
    ; what the app set up for itself: open at login and the daily keepalive task
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${NAME}"
    nsExec::Exec 'schtasks /Delete /TN "Noonix TV keepalive" /F'
    Delete "$SMPROGRAMS\${NAME}.lnk"
    RMDir /r "$INSTDIR"
    DeleteRegKey HKCU "${UNINST}"
SectionEnd
