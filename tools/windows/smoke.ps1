# checks a windows setup end to end in a throwaway folder: a quiet install, the core (library,
# extensions), and the ui drawing a frame (mesa's opengl when there's no gpu). never run this
# on a pc where noonix tv is open
#   powershell -ExecutionPolicy Bypass -File tools\windows\smoke.ps1 <setup.exe>
param([Parameter(Mandatory = $true)][string]$Setup)
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "noonix-smoke-$PID"
$app = "$tmp\app"
$env:NOONIX_HOME = "$tmp\home"
$env:NOONIX_MUTE = '1'
$env:QT_FORCE_STDERR_LOGGING = '1'
New-Item -ItemType Directory -Force $env:NOONIX_HOME | Out-Null

function Invoke-Cli {
    # the cli logs to stderr: powershell 5 would take that for a failure
    $ErrorActionPreference = 'Continue'
    # powershell 5 hands json's quotes over unescaped, and the exe never sees them
    $a = @(if ($PSVersionTable.PSVersion.Major -lt 7) { $args | ForEach-Object { $_ -replace '"', '\"' } } else { $args })
    $out = & "$app\noonix-tv-cli.exe" @a 2>"$tmp\cli.err"
    if ($LASTEXITCODE -ne 0) { Get-Content "$tmp\cli.err" -Tail 10 | Write-Host; throw "noonix-tv-cli $args failed" }
    $out
}

try {
    Write-Host '== install'
    # /D= is the last argument, unquoted, by nsis' rules
    $p = Start-Process -Wait -PassThru (Resolve-Path $Setup).Path -ArgumentList '/S', "/D=$app"
    if ($p.ExitCode -ne 0 -or -not (Test-Path "$app\noonix-tv.exe")) { throw "setup failed ($($p.ExitCode))" }

    Write-Host '== core'
    Invoke-Cli ping | Out-Null
    New-Item -ItemType Directory -Force "$tmp\videos" | Out-Null
    $folder = ("$tmp\videos" -replace '\\', '/')
    $text = (Invoke-Cli library.addFolder "{`"path`":`"$folder`"}" extensions.list) -join "`n"
    # one json document per call: the last is extensions.list
    $ext = ($text.Substring($text.LastIndexOf("`n[") + 1)) | ConvertFrom-Json
    if (@($ext).Count -ne 0) { throw "extensions: $text" }
    if ($text -notmatch '"folders":\[\{') { throw "library: $text" }

    Write-Host '== ui'
    $shot = "$tmp\frame.png"
    $env:NOONIX_GRAB = "$shot@8000"
    $ui = Start-Process -PassThru "$app\noonix-tv.exe" -RedirectStandardError "$tmp\ui.log"
    $deadline = (Get-Date).AddSeconds(40)
    while (-not (Test-Path $shot) -and (Get-Date) -lt $deadline -and -not $ui.HasExited) { Start-Sleep 1 }
    Start-Sleep 2
    $alive = -not $ui.HasExited
    if ($alive) { Stop-Process -Id $ui.Id -Force }
    Get-Content "$tmp\ui.log" -Tail 15
    if (-not $alive) { throw "the ui exited ($($ui.ExitCode))" }
    if (-not (Test-Path $shot) -or (Get-Item $shot).Length -lt 10000) { throw 'the ui drew no frame' }
    Write-Host 'ok'
}
finally {
    Get-Process noonix-tv -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$tmp\*" } | Stop-Process -Force
    Start-Sleep 1
    cmd /c rd /s /q "$tmp"
}
