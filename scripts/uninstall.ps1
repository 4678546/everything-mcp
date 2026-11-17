#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstaller for the everything-mcp bundle.

.DESCRIPTION
    Reverts what scripts\setup.ps1 created:
      * stops the bundled Everything instance (if it is running)
      * removes the Everything service if it was installed by this bundle
        (a service pointing outside the bundle is never touched)
      * deletes the index database, the virtual environment, and a Python that
        scripts\setup.ps1 downloaded itself
      * deletes the generated MCP snippets and the install record

    Files shipped in the bundle (es.exe, everything.exe, the MCP source) are
    kept unless -RemoveBundle is given.

.PARAMETER KeepVenv
    Keep runtime\venv (useful before reinstalling).

.PARAMETER KeepPython
    Keep a Python that scripts\setup.ps1 downloaded into runtime\python.

.PARAMETER KeepIndex
    Keep the Everything index database (Everything.db).

.PARAMETER RemoveBundle
    Also delete the bundle's shipped binaries (es.exe, everything.exe, MCP source).

.PARAMETER Yes
    Skip the confirmation prompt.

.PARAMETER DryRun
    Print what would be removed.
#>
[CmdletBinding()]
param(
    [switch]$KeepVenv,
    [switch]$KeepPython,
    [switch]$KeepIndex,
    [switch]$RemoveBundle,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$RuntimeDir = Join-Path $Root 'runtime'
$VenvDir = Join-Path $RuntimeDir 'venv'
$PortablePyDir = Join-Path $RuntimeDir 'python'
$EverythingDir = Join-Path $RuntimeDir 'everything'
$EverythingExe = Join-Path $EverythingDir 'everything.exe'
$EverythingIni = Join-Path $EverythingDir 'Everything.ini'
$EverythingDb = Join-Path $EverythingDir 'Everything.db'
$EsExe = Join-Path $Root 'bin\es.exe'
$HostsDir = Join-Path $Root 'hosts'
$RecordPath = Join-Path $Root 'host-config.json'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Ok([string]$Text) { Write-Host "    OK: $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "    WARN: $Text" -ForegroundColor Yellow }

$record = $null
if (Test-Path -LiteralPath $RecordPath) {
    try {
        $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    } catch {
        $record = $null
    }
}

$instance = 'everything-mcp'
$serviceOurs = $false
$pythonDownloaded = $false
if ($record) {
    if ($record.instance) { $instance = [string]$record.instance }
    if ($record.everything -and $record.everything.service) {
        $serviceOurs = [bool]$record.everything.service.installed_by_this_run
    }
    if ($record.python -and $record.python.source -and "$($record.python.source)" -like 'downloaded-*') {
        $pythonDownloaded = $true
    }
}

# A service whose binary lives inside this bundle can only have been installed by
# an earlier run of this bundle (e.g. scripts\setup.ps1 was re-run for an upgrade and the
# service already existed).  Remove it even when the current record says it
# "existed before", so uninstalling never leaves a service pointing at deleted
# files.  A user's own service points somewhere else and is never touched.
if (-not $serviceOurs) {
    $service = Get-Service -Name 'Everything' -ErrorAction SilentlyContinue
    if ($service) {
        try {
            $serviceRecord = Get-CimInstance -ClassName Win32_Service -Filter "Name='Everything'" -ErrorAction Stop
            $serviceBinary = "$($serviceRecord.PathName)" -replace '"', ''
            if ($serviceBinary -and $serviceBinary.StartsWith($Root, 'OrdinalIgnoreCase')) {
                $serviceOurs = $true
                Write-Info 'the Everything service points into this bundle; it will be removed'
            }
        } catch {
            # Querying the service configuration is best effort only.
        }
    }
}

Write-Host ''
Write-Host 'everything-mcp bundle uninstaller' -ForegroundColor White
Write-Host "  bundle: $Root"
if ($DryRun) { Write-Host '  DRY RUN: nothing will be changed' -ForegroundColor Yellow }
if ($record) {
    Write-Info "install mode: $($record.mode); Everything service installed by setup: $serviceOurs"
} else {
    Write-Warn2 'host-config.json not found; using defaults (existing service is never removed)'
}

if (-not $Yes -and -not $DryRun) {
    $answer = Read-Host 'Remove the bundled runtime/venv/index and generated configs? [y/N]'
    if ($answer -notmatch '^(?i)y(es)?$') {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        exit 0
    }
}

function Remove-PathSafe([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($DryRun) {
        Write-Info "would remove $Label : $Path"
        return
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "removed $Label"
}

Write-Step 'Stopping the bundled Everything instance'
if (Test-Path -LiteralPath $EsExe) {
    $esArgs = @()
    if ($instance) { $esArgs += @('-instance', $instance) }
    $esArgs += '-exit'
    if ($DryRun) {
        Write-Info "would run: $EsExe $($esArgs -join ' ')"
    } else {
        try {
            & $EsExe @esArgs 2>$null | Out-Null
        } catch {
            Write-Warn2 'es.exe -exit failed; the instance may already be stopped'
        }
    }
}
$ownerPath = Join-Path $env:TEMP "everything-mcp\$instance.owner.json"
if (Test-Path -LiteralPath $ownerPath) {
    try {
        $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
        $pid = [int]$owner.pid
        if ($pid -gt 0) {
            if ($DryRun) {
                Write-Info "would terminate bundled Everything pid $pid"
            } else {
                & taskkill.exe /PID $pid /T /F 2>$null | Out-Null
                Remove-Item -LiteralPath $ownerPath -Force -ErrorAction SilentlyContinue
                Write-Ok "stopped pid $pid"
            }
        }
    } catch {
        Write-Warn2 "could not read $ownerPath"
    }
}

Write-Step 'Everything service'
if ($serviceOurs) {
    if (-not (Test-Path -LiteralPath $EverythingExe)) {
        Write-Warn2 "bundled everything.exe not found; remove the 'Everything' service manually if needed"
    } elseif ($DryRun) {
        Write-Info "would run elevated: $EverythingExe -uninstall-service"
    } else {
        Write-Info 'requesting elevation (one UAC prompt) to remove the Everything service'
        try {
            Start-Process -FilePath $EverythingExe -ArgumentList '-uninstall-service' -Verb RunAs -Wait | Out-Null
            Write-Ok 'Everything service removed'
        } catch {
            Write-Warn2 "service removal failed: $($_.Exception.Message)"
        }
    }
} elseif (Get-Service -Name 'Everything' -ErrorAction SilentlyContinue) {
    Write-Info 'Everything service existed before setup; leaving it installed'
} else {
    Write-Info 'no Everything service present'
}

Write-Step 'Removing generated runtime and configs'
if (-not $KeepVenv) { Remove-PathSafe -Path $VenvDir -Label 'virtual environment' }
if ($pythonDownloaded -and -not $KeepPython) {
    Remove-PathSafe -Path $PortablePyDir -Label 'downloaded Python'
    Remove-PathSafe -Path (Join-Path $Root 'vendor\downloads') -Label 'cached Python downloads'
}
if (-not $KeepIndex) { Remove-PathSafe -Path $EverythingDb -Label 'index database' }
Remove-PathSafe -Path (Join-Path $Root 'mcp-config.example.json') -Label 'generated MCP example'
Remove-PathSafe -Path (Join-Path $Root 'dsh-snippet.yml') -Label 'generated DSH snippet'
if (Test-Path -LiteralPath $HostsDir) {
    $generated = Get-ChildItem -LiteralPath $HostsDir -File -ErrorAction SilentlyContinue
    foreach ($file in $generated) {
        if ($file.Name -ne 'README.txt') {
            Remove-PathSafe -Path $file.FullName -Label "generated snippet $($file.Name)"
        }
    }
}
Remove-PathSafe -Path $RecordPath -Label 'install record'

if ($RemoveBundle) {
    Write-Step 'Removing shipped bundle binaries'
    Remove-PathSafe -Path $EsExe -Label 'es.exe'
    Remove-PathSafe -Path $EverythingExe -Label 'everything.exe'
    Remove-PathSafe -Path $EverythingIni -Label 'Everything.ini'
    Remove-PathSafe -Path (Join-Path $Root 'src') -Label 'ES source'
    Remove-PathSafe -Path (Join-Path $Root 'mcp') -Label 'MCP server source'
    Write-Warn2 'keep a copy of the bundle if you may reinstall later'
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run finished.' -ForegroundColor Green
} else {
    Write-Host 'Uninstall complete.' -ForegroundColor Green
}
Write-Host ''
