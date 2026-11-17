#Requires -Version 5.1
<#
.SYNOPSIS
    Installer for the everything-mcp bundle (Windows 10+, MCP over stdio).

.DESCRIPTION
    Steps:
      1. choose how everything-mcp should reach Everything (A/B/C, default B)
      2. find a suitable Python (>= 3.10) or download one (official python.org
         first, then the Huawei Cloud / TUNA mirrors as fallbacks)
      3. install the pinned MCP dependencies into a virtual environment
         (falls back to a --target site-packages directory when a venv cannot
         be created, e.g. when ensurepip is unavailable)
      4. option B: reuse the local Everything installation when one exists.
         Setup detects it and shows a dialog (reuse it / browse for
         everything.exe / use the bundled copy).  Reusing keeps the user's
         existing index: nothing is prewarmed and no second database is built.
      5. option B with the bundled copy: install voidtools' Everything service
         (one UAC prompt) and prewarm the bundled index so the first tool call
         is instant.
      6. write ready-to-copy MCP configuration snippets under .\hosts\

    Instances started by everything-mcp are invisible (no window / taskbar /
    tray icon), run under their own instance name when the bundled copy is
    used, and are stopped when idle or when the MCP server exits.  The user's
    own Everything installation is never stopped or modified.  See README.md
    for the full design.

.PARAMETER Mode
    A = connect to an existing Everything only
    B = reuse the local Everything when possible, fall back to the bundled copy (default)
    C = never start anything; print connection hints only

.PARAMETER PythonVersion
    Python version to download when no suitable interpreter is found.  Default 3.13.17.

.PARAMETER UserEverythingExe
    Reuse this everything.exe directly; skips the detection choice dialog.

.PARAMETER UseBundledEverything
    Do not ask; always use the bundled Everything copy (builds its own index).

.PARAMETER NoEverythingDialog
    Skip the WinForms choice dialog and use the console prompt instead.

.PARAMETER InstallForm
    portable  = extract the official install-manager zip into runtime\python (default)
    installer = run the official per-user installer silently

.PARAMETER NoPrewarm
    Skip the index prewarm step (only relevant when the bundled copy is used).

.PARAMETER DryRun
    Print what would happen; do not change the system.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Mode A -PythonExe "C:\Python313\python.exe"
#>
[CmdletBinding()]
param(
    [ValidateSet('A', 'B', 'C')]
    [string]$Mode,

    [string]$PythonExe,

    [string]$PythonVersion = '3.13.17',

    # Reuse the user's own Everything installation instead of the bundled copy.
    # When omitted, setup detects it and shows a choice dialog.
    [string]$UserEverythingExe,

    # Force the bundled fallback even if an Everything installation is found.
    [switch]$UseBundledEverything,

    # Skip the choice dialog (console prompt instead).
    [switch]$NoEverythingDialog,

    [ValidateSet('portable', 'installer')]
    [string]$InstallForm = 'portable',

    [switch]$NoPrewarm,

    [switch]$DryRun,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # Older PowerShell may already be fine.
}

# ── Paths and constants ───────────────────────────────────────────────────

$Root = Split-Path -Parent $PSScriptRoot
$RuntimeDir = Join-Path $Root 'runtime'
$VenvDir = Join-Path $RuntimeDir 'venv'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
$PortablePyDir = Join-Path $RuntimeDir 'python'
$EverythingDir = Join-Path $RuntimeDir 'everything'
$EverythingExe = Join-Path $EverythingDir 'everything.exe'
$EsExe = Join-Path $Root 'bin\es.exe'
$HostsDir = Join-Path $Root 'hosts'
$Instance = 'everything-mcp'
$IdleTimeout = 600
$Deps = @('mcp==2.3.0', 'pydantic==2.14.1')
$PipIndexes = @(
    'https://pypi.org/simple',
    'https://pypi.tuna.tsinghua.edu.cn/simple',
    'https://mirrors.aliyun.com/pypi/simple'
)
$PythonBases = @(
    'https://www.python.org/ftp/python',
    'https://mirrors.huaweicloud.com/python',
    'https://mirrors.tuna.tsinghua.edu.cn/python'
)

$script:OwnService = $false
$script:ServiceExisted = $false
$script:PythonSource = 'system'
$script:PythonFound = $null
$script:RunPython = $null
$script:UseSitePackages = $false
$script:PrewarmOk = $false
$script:UserEverythingExe = $null       # reuse this installation (index already built)
$script:UseBundledFallback = $false     # true = bundled copy builds its own index
$script:DeclinedUserInstall = $false    # user saw an install but chose the bundled copy
$script:EverythingDetection = $null     # last Find-UserEverythingExe result

# ── Output helpers ───────────────────────────────────────────────────────

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Ok([string]$Text) { Write-Host "    OK: $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    WARN: $Text" -ForegroundColor Yellow }

function Fail([string]$Text) {
    Write-Host ''
    Write-Host "ERROR: $Text" -ForegroundColor Red
    exit 1
}

# Run a native executable while keeping $ErrorActionPreference = 'Stop' for the
# rest of the script.  With 'Stop', PowerShell turns any stderr line of a native
# program (pip warnings, Python logging, ...) into a terminating error; this
# helper collects stderr instead and returns the exit code.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [object[]]$Arguments = @(),
        [switch]$Quiet
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if (-not $Quiet) {
        foreach ($line in @($output)) { Write-Host "    $line" }
    }
    return $code
}

# ── URL / download helpers ───────────────────────────────────────────────

function Get-MirrorUrls {
    param([string]$Version, [string]$FileName, [string]$PrimaryUrl)
    $urls = New-Object System.Collections.ArrayList
    if ($PrimaryUrl) { [void]$urls.Add($PrimaryUrl) }
    foreach ($base in $PythonBases) { [void]$urls.Add("$base/$Version/$FileName") }
    return ($urls | Select-Object -Unique)
}

function Save-Download {
    param(
        [string[]]$Urls,
        [string]$Dest,
        [string]$Sha256
    )
    foreach ($url in $Urls) {
        try {
            Write-Info "download: $url"
            Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec 60
            $item = Get-Item -LiteralPath $Dest
            if ($item.Length -le 0) { throw 'empty file' }
            if ($Sha256) {
                $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $Dest).Hash.ToLower()
                if ($got -ne $Sha256.ToLower()) {
                    throw "SHA256 mismatch (expected $($Sha256.ToLower()), got $got)"
                }
                Write-Ok "SHA256 verified: $got"
            } else {
                Write-Warn 'no published SHA256 available for this file; size only verified'
            }
            return $true
        } catch {
            Write-Warn "source failed: $($_.Exception.Message)"
            Remove-Item -LiteralPath $Dest -ErrorAction SilentlyContinue
        }
    }
    return $false
}

function Get-PythonReleaseInfo {
    param([string]$Version)
    $parts = $Version.Split('.')
    if ($parts.Length -lt 2) { return $null }
    $releaseId = "pythoncore-$($parts[0]).$($parts[1])-64"
    foreach ($base in $PythonBases) {
        $url = "$base/$Version/windows-$Version.json"
        try {
            Write-Info "release manifest: $url"
            $doc = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 20
            foreach ($entry in $doc.versions) {
                if ($entry.id -eq $releaseId) {
                    return [pscustomobject]@{
                        Url    = $entry.url
                        Sha256 = $entry.hash.sha256
                    }
                }
            }
            Write-Warn "manifest has no $releaseId entry"
        } catch {
            Write-Warn "release manifest unavailable: $($_.Exception.Message)"
        }
    }
    return $null
}

# ── Python detection ─────────────────────────────────────────────────────

function Get-PythonVersion {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = & $Path -c "import sys;sys.stdout.write('%d.%d.%d' % sys.version_info[:3])" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $text = ($raw | Out-String).Trim()
        if ($text -match '^\d+\.\d+\.\d+$') { return [version]$text }
    } catch {
        return $null
    }
    return $null
}

function Get-PythonCandidates {
    $candidates = New-Object System.Collections.ArrayList
    if ($PythonExe) {
        [void]$candidates.Add([pscustomobject]@{ Path = $PythonExe; Version = $null })
        return $candidates
    }

    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $lines = & $py.Source '-0p' 2>$null
        } catch {
            $lines = @()
        }
        foreach ($line in $lines) {
            if ($line -match '^\s*-V:(\d+\.\d+)\s+\*?\s+(.+?)\s*$') {
                $path = $Matches[2]
                if (Test-Path -LiteralPath $path) {
                    [void]$candidates.Add([pscustomobject]@{ Path = $path; Version = $Matches[1] })
                }
            }
        }
    }

    foreach ($name in @('python.exe', 'python3.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and (Test-Path -LiteralPath $cmd.Source)) {
            [void]$candidates.Add([pscustomobject]@{ Path = $cmd.Source; Version = $null })
        }
    }

    $seen = @{}
    $unique = New-Object System.Collections.ArrayList
    foreach ($candidate in $candidates) {
        $key = $candidate.Path.ToLower()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$unique.Add($candidate)
        }
    }
    return $unique
}

function Select-Python {
    param($Candidates, [string]$PreferredMinor = '13')
    $valid = New-Object System.Collections.ArrayList
    foreach ($candidate in $Candidates) {
        $version = Get-PythonVersion -Path $candidate.Path
        if (-not $version) { continue }
        if ($version -lt [version]'3.10.0' -or $version -ge [version]'4.0.0') { continue }
        [void]$valid.Add([pscustomobject]@{ Path = $candidate.Path; Version = $version })
    }
    if ($valid.Count -eq 0) { return $null }

    $best = $null
    $bestRank = $null
    foreach ($candidate in $valid) {
        if ($candidate.Version.Major -ne 3) { continue }
        $isPreferred = ($candidate.Version.Minor -eq [int]$PreferredMinor)
        $isExperimental = ($candidate.Version.Minor -ge 15)
        $rank = '{0},{1},{2:D2}' -f `
            $(if ($isPreferred) { 0 } else { 1 }), `
            $(if ($isExperimental) { 1 } else { 0 }), `
            (99 - $candidate.Version.Minor)
        if (-not $best -or $rank -lt $bestRank) {
            $best = $candidate
            $bestRank = $rank
        }
    }
    return $best
}

# ── Python installation ─────────────────────────────────────────────────

function Expand-PythonZip {
    param([string]$ZipPath, [string]$DestDir)
    if (Test-Path -LiteralPath $DestDir) {
        Remove-Item -LiteralPath $DestDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    Write-Info "extracting: $ZipPath"
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $DestDir -Force
    $exe = Join-Path $DestDir 'python.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        $nested = Get-ChildItem -LiteralPath $DestDir -Directory | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName 'python.exe')
        } | Select-Object -First 1
        if ($nested) {
            Get-ChildItem -LiteralPath $nested.FullName -Force | Move-Item -Destination $DestDir -Force
            Remove-Item -LiteralPath $nested.FullName -Recurse -Force
            $exe = Join-Path $DestDir 'python.exe'
        }
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "python.exe was not found after extracting $ZipPath"
    }
    return $exe
}

function Install-Python {
    Write-Step "No suitable Python found; preparing Python $PythonVersion ($InstallForm)"

    $release = Get-PythonReleaseInfo -Version $PythonVersion
    if ($release) {
        $fileName = Split-Path -Leaf $release.Url
        $sha256 = $release.Sha256
    } else {
        Write-Warn 'official release manifest unavailable; falling back to hand-built URLs (no SHA256)'
        if ($InstallForm -eq 'portable') {
            $fileName = "python-$PythonVersion-amd64.zip"
        } else {
            $fileName = "python-$PythonVersion-amd64.exe"
        }
        $sha256 = $null
    }
    $urls = Get-MirrorUrls -Version $PythonVersion -FileName $fileName -PrimaryUrl $(if ($release) { $release.Url } else { $null })
    $downloadsDir = Join-Path $Root 'vendor\downloads'
    $dest = Join-Path $downloadsDir $fileName

    if ($DryRun) {
        Write-Info "would download $fileName from:"
        foreach ($url in $urls) { Write-Info "  $url" }
        Write-Info "would install into: $(if ($InstallForm -eq 'portable') { $PortablePyDir } else { 'per-user Python installation' })"
        return $null
    }

    New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
    if (-not (Test-Path -LiteralPath $dest)) {
        if (-not (Save-Download -Urls $urls -Dest $dest -Sha256 $sha256)) {
            Fail "could not download $fileName from any source. Download it manually and re-run: scripts\setup.ps1 -PythonVersion $PythonVersion (mirror: https://mirrors.huaweicloud.com/python/$PythonVersion/)"
        }
    } else {
        Write-Ok "using cached download: $dest"
        if ($sha256) {
            $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower()
            if ($got -ne $sha256.ToLower()) {
                Remove-Item -LiteralPath $dest -Force
                Fail 'cached download failed SHA256 verification; re-run scripts\setup.ps1'
            }
        }
    }

    $script:PythonSource = if ($InstallForm -eq 'portable') { 'downloaded-portable' } else { 'downloaded-installer' }

    if ($InstallForm -eq 'portable') {
        $python = Expand-PythonZip -ZipPath $dest -DestDir $PortablePyDir
        Write-Ok "portable Python installed: $python"
        return $python
    }

    Write-Step 'Running the per-user Python installer (silent)'
    $arguments = @(
        '/quiet', 'InstallAllUsers=0', 'PrependPath=0', 'Include_pip=1',
        'Include_launcher=1', 'Include_test=0', 'SimpleInstall=1'
    )
    $proc = Start-Process -FilePath $dest -ArgumentList $arguments -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Fail "Python installer exited with code $($proc.ExitCode)"
    }
    $candidates = Get-PythonCandidates
    $selected = Select-Python -Candidates $candidates
    if (-not $selected) { Fail 'Python installer finished but no interpreter was found in the expected locations' }
    Write-Ok "installed Python: $($selected.Path) ($($selected.Version))"
    return $selected.Path
}

# ── Python environment and dependencies ─────────────────────────────────

function Test-VenvPip {
    param([string]$Python)
    if (-not (Test-Path -LiteralPath $Python)) { return $false }
    $code = Invoke-NativeCommand -FilePath $Python -Arguments @('-m', 'pip', '--version') -Quiet
    return ($code -eq 0)
}

function Install-PipDeps {
    param([string]$Python, [string]$Target)
    Write-Step 'Installing Python dependencies'
    if ($DryRun) {
        Write-Info "would run: $Python -m pip install $($Deps -join ' ')"
        return
    }
    foreach ($index in $PipIndexes) {
        Write-Info "pip index: $index"
        $arguments = @(
            '-m', 'pip', 'install', '--disable-pip-version-check',
            '--no-warn-script-location', '--timeout', '30', '--retries', '1',
            '-i', $index
        )
        if ($Target) { $arguments += @('--target', $Target, '--upgrade') }
        $arguments += $Deps
        $pipExit = Invoke-NativeCommand -FilePath $Python -Arguments $arguments
        if ($pipExit -eq 0) {
            Write-Ok 'dependencies installed'
            return
        }
        Write-Warn "pip index failed (exit $pipExit); trying the next source"
    }
    Fail "could not install dependencies from any pip index. Run manually: `"$Python`" -m pip install $($Deps -join ' ')"
}

function Initialize-PythonEnvironment {
    param([string]$BasePython)

    $sitePackages = Join-Path $RuntimeDir 'site-packages'
    $script:UseSitePackages = $false

    if ($DryRun) {
        Write-Info "would create a virtual environment: $VenvDir"
        $script:RunPython = $VenvPython
        return
    }

    if ($Force -and (Test-Path -LiteralPath $VenvDir)) {
        Write-Info "removing existing venv: $VenvDir"
        Remove-Item -LiteralPath $VenvDir -Recurse -Force
    }

    if (Test-VenvPip -Python $VenvPython) {
        Write-Ok "using existing virtual environment: $VenvDir"
        $script:RunPython = $VenvPython
        Install-PipDeps -Python $VenvPython
        return
    }

    if (-not (Test-Path -LiteralPath $VenvPython)) {
        Write-Step "Creating virtual environment: $VenvDir"
        $venvExit = Invoke-NativeCommand -FilePath $BasePython -Arguments @('-m', 'venv', $VenvDir)
        if ($venvExit -ne 0) {
            Write-Warn "venv creation failed (exit $venvExit)"
        }
    }
    if (Test-VenvPip -Python $VenvPython) {
        Write-Ok 'virtual environment ready'
        $script:RunPython = $VenvPython
        Install-PipDeps -Python $VenvPython
        return
    }

    # Some Python builds (and restricted environments) cannot bootstrap pip
    # through ensurepip.  Install the same pinned packages into a dedicated
    # --target directory and point PYTHONPATH at it instead.
    Write-Warn 'virtual environment is unavailable; falling back to a --target site-packages directory'
    New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
    $script:RunPython = $BasePython
    $script:UseSitePackages = $true
    Install-PipDeps -Python $BasePython -Target $sitePackages
}

# ── Mode selection ──────────────────────────────────────────────────────

function Select-RunMode {
    if ($Mode) { return $Mode }
    Write-Host ''
    Write-Host 'How should everything-mcp connect to Everything?' -ForegroundColor White
    Write-Host ''
    Write-Host '  A  Existing Everything only'
    Write-Host '     Connect to an Everything the user already runs (default or named instance).'
    Write-Host '     The bundle never starts anything; you must run Everything yourself.'
    Write-Host ''
    Write-Host '  B  Reuse your Everything index, bundled copy as last resort  (recommended)'
    Write-Host '     If an Everything is already running, use it.  Otherwise start your own'
    Write-Host '     installed Everything invisibly so it loads the index it already has.'
    Write-Host '     Only when no installation exists does the bundled copy build a new index.'
    Write-Host '     Nothing is prewarmed when an existing index is reused.'
    Write-Host ''
    Write-Host '  C  Connect only; never start anything'
    Write-Host '     Same as A but with no fallback attempts.  Useful on locked-down PCs.'
    Write-Host ''
    while ($true) {
        $answer = Read-Host 'Choose A, B or C [B]'
        if ([string]::IsNullOrWhiteSpace($answer)) { return 'B' }
        $answer = $answer.Trim().ToUpperInvariant()
        if ($answer -in @('A', 'B', 'C')) { return $answer }
        Write-Host 'Please type A, B or C.' -ForegroundColor Yellow
    }
}

# ── Everything service and prewarm (option B) ──────────────────────────

function Ensure-EverythingService {
    param([string]$PreferredExe)
    $serviceExe = $EverythingExe
    if ($PreferredExe -and (Test-Path -LiteralPath $PreferredExe -PathType Leaf)) {
        $serviceExe = $PreferredExe
    }
    Write-Step 'Everything service (lets Everything index without admin rights)'
    if (-not (Test-Path -LiteralPath $serviceExe)) {
        Write-Warn "everything.exe is missing: $serviceExe"
        return $false
    }
    $service = Get-Service -Name 'Everything' -ErrorAction SilentlyContinue
    if ($service) {
        $script:ServiceExisted = $true
        Write-Ok "Everything service already installed ($($service.Status))"
        return $true
    }
    if ($DryRun) {
        Write-Info "would request elevation and run: $serviceExe -install-service"
        return $false
    }
    Write-Info 'one UAC prompt is required to install the Everything service'
    Write-Info "service binary: $serviceExe -svc"
    try {
        Start-Process -FilePath $serviceExe -ArgumentList '-install-service' -Verb RunAs -Wait -PassThru | Out-Null
    } catch {
        Write-Warn "elevation was cancelled or failed: $($_.Exception.Message)"
        return $false
    }
    Start-Sleep -Seconds 2
    $service = Get-Service -Name 'Everything' -ErrorAction SilentlyContinue
    if ($service) {
        $script:OwnService = $true
        Write-Ok "Everything service installed ($($service.Status))"
        return $true
    }
    Write-Warn 'the service was not detected after the install attempt'
    return $false
}

function Get-BundlePythonPath {
    $parts = @((Join-Path $Root 'mcp'))
    if ($script:UseSitePackages) {
        $parts += (Join-Path $RuntimeDir 'site-packages')
    }
    return ($parts -join ';')
}

# ── Reuse the user's own Everything installation ───────────────────────

function Find-PortableEverything {
    # Last resort: scan local drives for a portable Everything.exe.  The system
    # drive is scanned only two levels deep (it holds Windows and the profile);
    # other drives are scanned six levels deep, which finds tool collections
    # such as "D:\Tools\<vendor>\<app>\Everything\Everything.exe".
    $results = New-Object System.Collections.ArrayList
    $systemRoot = ($env:SystemDrive + '\').ToUpperInvariant()
    $drives = @()
    try {
        $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
            ForEach-Object { $_.DeviceID + '\' })
    } catch {
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Root -match '^[A-Za-z]:\\$' } |
            ForEach-Object { $_.Root })
    }
    foreach ($rootPath in $drives) {
        if (-not $rootPath) { continue }
        $depth = if ($rootPath.ToUpperInvariant() -eq $systemRoot) { 2 } else { 6 }
        try {
            $found = Get-ChildItem -LiteralPath $rootPath -Filter 'everything*.exe' -File -Recurse -Depth $depth -ErrorAction SilentlyContinue
        } catch {
            $found = @()
        }
        foreach ($item in @($found)) {
            if ($item.Name -match '^(?i)everything(64)?\.exe$') {
                [void]$results.Add($item.FullName)
            }
        }
        foreach ($path in $results) {
            $dbPath = Join-Path (Split-Path -Parent $path) 'Everything.db'
            if (Test-Path -LiteralPath $dbPath -PathType Leaf) { return , $results }
        }
    }
    return , $results
}

function Find-UserEverythingExe {
    # Locate an existing Everything installation (never the bundled copy).
    $candidates = New-Object System.Collections.ArrayList
    if ($UserEverythingExe) {
        [void]$candidates.Add([pscustomobject]@{ Path = $UserEverythingExe; Source = 'command line' })
    }
    if ($env:EVERYTHING_USER_EXE) {
        [void]$candidates.Add([pscustomobject]@{ Path = $env:EVERYTHING_USER_EXE; Source = 'EVERYTHING_USER_EXE' })
    }
    $recordPath = Join-Path $Root 'host-config.json'
    if (Test-Path -LiteralPath $recordPath) {
        try {
            $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
            if ($record.everything -and $record.everything.user_install) {
                [void]$candidates.Add([pscustomobject]@{ Path = [string]$record.everything.user_install; Source = 'previous install' })
            }
        } catch {
            # a damaged install record is not a reason to stop the setup
        }
    }
    foreach ($proc in (Get-Process -Name 'everything', 'Everything64' -ErrorAction SilentlyContinue)) {
        try {
            $procPath = $proc.Path
            if ($procPath) {
                [void]$candidates.Add([pscustomobject]@{ Path = $procPath; Source = 'running process' })
            }
        } catch {
            # process path may be unreadable for other users' processes
        }
    }
    foreach ($hive in @(
        'HKLM:\SOFTWARE\voidtools\Everything',
        'HKCU:\SOFTWARE\voidtools\Everything',
        'HKLM:\SOFTWARE\WOW6432Node\voidtools\Everything'
    )) {
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        $key = Get-ItemProperty -LiteralPath $hive -ErrorAction SilentlyContinue
        foreach ($value in @($key.InstallLocation, $key.InstallPath)) {
            if ($value) {
                [void]$candidates.Add([pscustomobject]@{ Path = (Join-Path $value 'everything.exe'); Source = 'registry' })
            }
        }
    }
    $commonDirs = @(
        (Join-Path $env:ProgramFiles 'Everything'),
        (Join-Path ${env:ProgramFiles(x86)} 'Everything'),
        (Join-Path $env:LOCALAPPDATA 'Everything'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Everything'),
        (Join-Path $env:USERPROFILE 'Everything')
    )
    foreach ($dir in $commonDirs) {
        if (-not $dir) { continue }
        foreach ($name in @('Everything64.exe', 'Everything.exe')) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                [void]$candidates.Add([pscustomobject]@{ Path = $candidate; Source = 'common location' })
            }
        }
    }

    # Portable installations have no registry entry and live outside the
    # common folders: scan the drives once when nothing else was found.
    $anyValid = $false
    foreach ($candidate in $candidates) {
        if (-not $candidate.Path) { continue }
        try {
            if (Test-Path -LiteralPath ([string]$candidate.Path) -PathType Leaf) {
                $anyValid = $true
                break
            }
        } catch {
            # unreadable candidate path: keep looking
        }
    }
    if (-not $anyValid) {
        Write-Info 'scanning local drives for a portable Everything (this can take a few seconds)'
        foreach ($foundPath in (Find-PortableEverything)) {
            [void]$candidates.Add([pscustomobject]@{ Path = $foundPath; Source = 'drive scan' })
        }
    }

    $rootPrefix = $Root.ToLowerInvariant().TrimEnd('\') + '\'
    $best = $null
    $bestScore = -1
    $seen = @{}
    foreach ($candidate in $candidates) {
        if (-not $candidate.Path) { continue }
        try {
            $full = [IO.Path]::GetFullPath([string]$candidate.Path)
        } catch {
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        if ([IO.Path]::GetExtension($full).ToLowerInvariant() -ne '.exe') { continue }
        if ($full.ToLowerInvariant().StartsWith($rootPrefix)) { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $dbPath = Join-Path (Split-Path -Parent $full) 'Everything.db'
        $hasDb = Test-Path -LiteralPath $dbPath -PathType Leaf
        $score = if ($hasDb) { 2 } else { 1 }
        if ($score -le $bestScore) { continue }
        $bestScore = $score
        $best = [pscustomobject]@{
            Path         = $full
            Source       = $candidate.Source
            Version      = (Get-Item -LiteralPath $full).VersionInfo.FileVersion
            HasDatabase  = $hasDb
            DatabaseMB   = $(if ($hasDb) { [math]::Round((Get-Item -LiteralPath $dbPath).Length / 1MB, 1) } else { 0 })
        }
    }
    return $best
}

function Show-EverythingChoiceDialog {
    param($Detection)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    } catch {
        return $null
    }
    if (-not [Environment]::UserInteractive) { return $null }
    try {
        if (-not [System.Windows.Forms.SystemInformation]::UserInteractive) { return $null }
    } catch {
        return $null
    }

    $script:EverythingDialogChoice = $null
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'everything-mcp - choose the Everything source'
    $form.ClientSize = New-Object System.Drawing.Size(660, 340)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object System.Drawing.Point(14, 12)
    $title.Size = New-Object System.Drawing.Size(630, 24)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $title.Text = 'Let the agent reuse the file index you already have'
    $form.Controls.Add($title)

    $details = New-Object System.Windows.Forms.TextBox
    $details.Location = New-Object System.Drawing.Point(14, 42)
    $details.Size = New-Object System.Drawing.Size(630, 148)
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = 'Vertical'
    $details.Font = New-Object System.Drawing.Font('Consolas', 9)
    if ($Detection) {
        $lines = @(
            "Detected : $($Detection.Path)",
            "Version  : $($Detection.Version)",
            ("Index    : {0} MB (Everything.db)" -f $Detection.DatabaseMB),
            "Source   : $($Detection.Source)"
        )
    } else {
        $lines = @(
            'No Everything installation was found on this machine.',
            'Browse to everything.exe, or let the bundled copy build its own index.'
        )
    }
    $details.Text = ($lines -join "`r`n")
    $form.Controls.Add($details)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Location = New-Object System.Drawing.Point(14, 198)
    $hint.Size = New-Object System.Drawing.Size(630, 74)
    $hint.Text = 'Reuse: the first agent search is instant - your existing index is kept and no second database is built.' + "`r`n" + 'Bundled copy: a separate index is built on this machine (slow first run, extra disk use).'
    $form.Controls.Add($hint)

    $reuse = New-Object System.Windows.Forms.Button
    $reuse.Location = New-Object System.Drawing.Point(14, 288)
    $reuse.Size = New-Object System.Drawing.Size(200, 34)
    $reuse.Text = 'Reuse this installation'
    $reuse.Enabled = [bool]$Detection
    $reuse.Add_Click({ $script:EverythingDialogChoice = 'reuse'; $this.FindForm().Close() })

    $browse = New-Object System.Windows.Forms.Button
    $browse.Location = New-Object System.Drawing.Point(228, 288)
    $browse.Size = New-Object System.Drawing.Size(180, 34)
    $browse.Text = 'Browse for everything.exe...'
    $browse.Add_Click({ $script:EverythingDialogChoice = 'browse'; $this.FindForm().Close() })

    $bundled = New-Object System.Windows.Forms.Button
    $bundled.Location = New-Object System.Drawing.Point(422, 288)
    $bundled.Size = New-Object System.Drawing.Size(220, 34)
    $bundled.Text = 'Use the bundled copy'
    $bundled.Add_Click({ $script:EverythingDialogChoice = 'bundled'; $this.FindForm().Close() })

    $form.Controls.AddRange(@($reuse, $browse, $bundled))
    $form.AcceptButton = $reuse
    $form.CancelButton = $bundled
    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:EverythingDialogChoice
}

function Select-EverythingExecutable {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select everything.exe'
        $dialog.Filter = 'Everything (everything*.exe)|everything*.exe|Executables (*.exe)|*.exe'
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
    } catch {
        Write-Warn "file dialog unavailable: $($_.Exception.Message)"
    }
    return $null
}

function Read-EverythingChoiceConsole {
    param($Detection)
    Write-Host ''
    if ($Detection) {
        Write-Host "  Reuse: $($Detection.Path)  (index $($Detection.DatabaseMB) MB)"
    } else {
        Write-Host '  No Everything installation was found on this machine.'
    }
    Write-Host '  [1] Reuse the existing installation (recommended when present)'
    Write-Host '  [2] Browse for everything.exe'
    Write-Host '  [3] Use the bundled copy (builds a separate index)'
    while ($true) {
        $answer = Read-Host 'Choose 1, 2 or 3 [1]'
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = '1' }
        switch ($answer.Trim()) {
            '1' {
                if ($Detection) { return 'reuse' }
                Write-Host 'No installation was found; choose 2 or 3.' -ForegroundColor Yellow
            }
            '2' { return 'browse' }
            '3' { return 'bundled' }
            default { Write-Host 'Please type 1, 2 or 3.' -ForegroundColor Yellow }
        }
    }
}

function Get-EverythingChoice {
    Write-Step 'Everything source (reuse the existing index when possible)'
    $detection = Find-UserEverythingExe
    $script:EverythingDetection = $detection
    if ($detection) {
        Write-Ok "found Everything $($detection.Version) at $($detection.Path)"
        if ($detection.HasDatabase) {
            Write-Info "existing index: $($detection.DatabaseMB) MB in Everything.db"
        } else {
            Write-Warn 'no Everything.db next to that executable; the index is built on first use'
        }
    } else {
        Write-Info 'no existing Everything installation was found'
    }

    if ($UserEverythingExe) {
        $chosen = [IO.Path]::GetFullPath($UserEverythingExe)
        if (-not (Test-Path -LiteralPath $chosen -PathType Leaf)) {
            Fail "the -UserEverythingExe path does not exist: $chosen"
        }
        $script:UserEverythingExe = $chosen
        Write-Ok "reusing (command line): $chosen"
        return
    }
    if ($UseBundledEverything) {
        $script:UseBundledFallback = $true
        $script:DeclinedUserInstall = [bool]$detection
        Write-Warn 'using the bundled Everything copy (-UseBundledEverything)'
        return
    }
    if ($DryRun) {
        if ($detection) {
            $script:UserEverythingExe = $detection.Path
            Write-Info 'would ask: reuse this installation, browse, or use the bundled copy'
        } else {
            Write-Info 'nothing to reuse: would use the bundled copy and build its index'
        }
        $script:UseBundledFallback = -not $detection
        return
    }

    $choice = $null
    if (-not $NoEverythingDialog) {
        $choice = Show-EverythingChoiceDialog -Detection $detection
    }
    if (-not $choice) {
        $choice = Read-EverythingChoiceConsole -Detection $detection
    }
    while ($choice -eq 'browse') {
        $picked = Select-EverythingExecutable
        if ($picked) {
            $script:UserEverythingExe = $picked
            $choice = 'reuse'
        } else {
            $choice = Read-EverythingChoiceConsole -Detection $detection
        }
    }
    if ($choice -eq 'reuse' -and $detection) {
        $script:UserEverythingExe = $detection.Path
    }

    if ($script:UserEverythingExe) {
        $script:UseBundledFallback = $false
        $script:DeclinedUserInstall = $false
        $dbPath = Join-Path (Split-Path -Parent $script:UserEverythingExe) 'Everything.db'
        $size = 0
        if (Test-Path -LiteralPath $dbPath -PathType Leaf) {
            $size = [math]::Round((Get-Item -LiteralPath $dbPath).Length / 1MB, 1)
        }
        Write-Ok "reuse: $($script:UserEverythingExe)"
        Write-Info 'existing index reused: no prewarm and no second database'
        if ($size -gt 0) { Write-Info "index size: $size MB" }
    } else {
        $script:UseBundledFallback = $true
        $script:DeclinedUserInstall = [bool]$detection
        Write-Warn 'the bundled Everything copy will build its own index (this can take a while)'
    }
}

function Invoke-Prewarm {
    param([string]$TargetPython)
    if ($NoPrewarm) {
        Write-Info 'prewarm skipped (-NoPrewarm)'
        return
    }
    Write-Step "Prewarming the bundled copy's index (the first build can take several minutes)"
    if ($DryRun) {
        Write-Info "would run: $TargetPython -m everything_mcp.supervisor --prewarm --timeout 900"
        return
    }
    $oldValues = @{
        PYTHONPATH                        = $env:PYTHONPATH
        EVERYTHING_ES_PATH                = $env:EVERYTHING_ES_PATH
        EVERYTHING_EXE                    = $env:EVERYTHING_EXE
        EVERYTHING_MCP_INSTANCE           = $env:EVERYTHING_MCP_INSTANCE
        EVERYTHING_AUTOSTART              = $env:EVERYTHING_AUTOSTART
        EVERYTHING_USER_EXE               = $env:EVERYTHING_USER_EXE
        EVERYTHING_DISABLE_USER_INSTALL   = $env:EVERYTHING_DISABLE_USER_INSTALL
    }
    $code = 1
    try {
        $env:PYTHONPATH = Get-BundlePythonPath
        $env:EVERYTHING_ES_PATH = $EsExe
        $env:EVERYTHING_EXE = $EverythingExe
        $env:EVERYTHING_MCP_INSTANCE = $Instance
        $env:EVERYTHING_AUTOSTART = '1'
        $env:EVERYTHING_USER_EXE = ''
        $env:EVERYTHING_DISABLE_USER_INSTALL = '1'
        $code = Invoke-NativeCommand -FilePath $TargetPython -Arguments @(
            '-m', 'everything_mcp.supervisor', '--prewarm', '--timeout', '900'
        )
    } finally {
        foreach ($key in $oldValues.Keys) {
            Set-Item -Path "env:$key" -Value $oldValues[$key]
        }
    }
    if ($code -eq 0) {
        $script:PrewarmOk = $true
        Write-Ok 'index is ready'
    } else {
        Write-Warn "prewarm did not finish (exit $code); the first tool call will build the index instead"
    }
}

# ── Host configuration snippets ─────────────────────────────────────────

function Get-EnvMapRaw {
    $autostart = if ($script:Mode -eq 'B') { '1' } else { '0' }
    $map = [ordered]@{
        PYTHONPATH              = (Get-BundlePythonPath)
        EVERYTHING_ES_PATH      = $EsExe
        EVERYTHING_EXE          = $EverythingExe
        EVERYTHING_MCP_INSTANCE = $Instance
        EVERYTHING_AUTOSTART    = $autostart
        EVERYTHING_IDLE_TIMEOUT = "$IdleTimeout"
    }
    if ($script:UserEverythingExe) {
        $map['EVERYTHING_USER_EXE'] = $script:UserEverythingExe
    }
    if ($script:DeclinedUserInstall) {
        # The user explicitly declined a detected installation: always use the
        # bundled copy so a later Everything install does not silently change
        # which index the agent searches.
        $map['EVERYTHING_DISABLE_USER_INSTALL'] = '1'
    }
    return $map
}

function Get-EnvMap {
    $raw = Get-EnvMapRaw
    $escaped = [ordered]@{}
    foreach ($key in $raw.Keys) {
        $escaped[$key] = ("$($raw[$key])" -replace '\\', '\\')
    }
    return $escaped
}

function Write-JsonHostConfig {
    param([string]$Path)
    $config = [ordered]@{
        mcpServers = [ordered]@{
            everything = [ordered]@{
                command = $script:RunPython
                args    = @('-m', 'everything_mcp')
                env     = (Get-EnvMap)
            }
        }
    }
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Ok $Path
}

function Write-CodexConfig {
    param([string]$Path)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('[mcp_servers.everything]')
    [void]$lines.Add("command = `"$($script:RunPython -replace '\\', '\\\\')`"")
    [void]$lines.Add('args = ["-m", "everything_mcp"]')
    [void]$lines.Add('')
    [void]$lines.Add('[mcp_servers.everything.env]')
    $envMap = Get-EnvMapRaw
    foreach ($key in $envMap.Keys) {
        $value = "$($envMap[$key])" -replace '\\', '\\\\'
        [void]$lines.Add("$key = `"$value`"")
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
    Write-Ok $Path
}

function Write-DshConfig {
    param([string]$Path)
    $envMap = Get-EnvMapRaw
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('# everything-mcp - DSH MCP row.  Append to the profile''s cordis.patch.yml')
    [void]$lines.Add('# (top-level YAML array; keep the two-space indentation).')
    [void]$lines.Add('- insert:')
    [void]$lines.Add('    - id: mcp-everything')
    [void]$lines.Add('      name: "@deepseek-ai/dsh-mcp-client"')
    [void]$lines.Add('      config:')
    [void]$lines.Add('        serverName: everything')
    [void]$lines.Add('        transport: stdio')
    [void]$lines.Add("        command: '$($script:RunPython)'")
    [void]$lines.Add('        args:')
    [void]$lines.Add("          - '-m'")
    [void]$lines.Add("          - 'everything_mcp'")
    [void]$lines.Add('        env:')
    foreach ($key in $envMap.Keys) {
        [void]$lines.Add("          ${key}: '$($envMap[$key])'")
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
    Write-Ok $Path
}

function Write-HostConfigs {
    Write-Step 'Writing MCP configuration snippets'
    if ($DryRun) {
        Write-Info "would write snippets under: $HostsDir"
        return
    }
    New-Item -ItemType Directory -Force -Path $HostsDir | Out-Null
    Write-JsonHostConfig -Path (Join-Path $HostsDir 'claude-desktop.json')
    Write-JsonHostConfig -Path (Join-Path $HostsDir 'cursor.json')
    Write-JsonHostConfig -Path (Join-Path $HostsDir 'gemini-cli.json')
    Write-CodexConfig -Path (Join-Path $HostsDir 'codex.toml')
    Write-DshConfig -Path (Join-Path $HostsDir 'dsh-snippet.yml')
    Write-JsonHostConfig -Path (Join-Path $Root 'mcp-config.example.json')
    Write-DshConfig -Path (Join-Path $Root 'dsh-snippet.yml')
}

function Write-InstallRecord {
    if ($DryRun) { return }
    $record = [ordered]@{
        mode                 = $script:Mode
        instance             = $Instance
        idle_timeout_seconds = $IdleTimeout
        python               = [ordered]@{
            source       = $script:PythonSource
            interpreter  = $script:RunPython
            base         = $script:PythonFound
            requested    = "$PythonVersion"
            dependencies = $Deps
            installed_to = $(if ($script:UseSitePackages) { (Join-Path $RuntimeDir 'site-packages') } else { $VenvDir })
        }
        everything = [ordered]@{
            bundled_exe  = $EverythingExe
            es           = $EsExe
            user_install = $script:UserEverythingExe
            uses         = $(if ($script:UserEverythingExe) { 'user-install' } else { 'bundled-fallback' })
            service      = [ordered]@{
                name                   = 'Everything'
                existed_before_install = $script:ServiceExisted
                installed_by_this_run  = $script:OwnService
            }
        }
        prewarm      = [ordered]@{
            needed = [bool]$script:UseBundledFallback
            done   = $script:PrewarmOk
        }
        installed_at = (Get-Date).ToString('o')
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Root 'host-config.json') -Encoding UTF8
    Write-Ok (Join-Path $Root 'host-config.json')
}

# ── Main ────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host 'everything-mcp bundle installer' -ForegroundColor White
Write-Host "  bundle: $Root"
if ($DryRun) { Write-Host '  DRY RUN: nothing will be changed' -ForegroundColor Yellow }

$script:Mode = Select-RunMode
Write-Ok "run mode: $($script:Mode)"

if ($script:Mode -eq 'B') {
    Get-EverythingChoice
} else {
    Write-Info 'mode A/C: the bundled Everything copy is not used; skipping the source choice'
}

Write-Step 'Looking for a Python interpreter (>= 3.10)'
$candidates = Get-PythonCandidates
$selected = Select-Python -Candidates $candidates
if ($selected) {
    $script:PythonFound = $selected.Path
    Write-Ok "found Python $($selected.Version): $($selected.Path)"
} else {
    Write-Info 'no suitable Python found on this machine'
    $installed = Install-Python
    if ($installed) {
        $script:PythonFound = $installed
        $selected = [pscustomobject]@{ Path = $installed; Version = (Get-PythonVersion -Path $installed) }
        Write-Ok "Python ready: $installed ($($selected.Version))"
    }
}

if ($DryRun) {
    Write-Step 'Plan'
    Write-Info "mode: $($script:Mode)"
    Write-Info "python: $(if ($script:PythonFound) { $script:PythonFound } else { "would download $PythonVersion" })"
    Write-Info "venv: $VenvDir (falls back to runtime\site-packages if ensurepip is unavailable)"
    Write-Info "dependencies: $($Deps -join ', ')"
    if ($script:Mode -eq 'B') {
        if ($script:UserEverythingExe) {
            Write-Info "everything: reuse $($script:UserEverythingExe) (existing index, no prewarm)"
        } else {
            Write-Info 'everything: bundled copy (its own index has to be built)'
        }
        Write-Info "service: ensure 'Everything' service is installed (UAC once)"
        $prewarmPlan = if (-not $script:UseBundledFallback) {
            'not needed (existing index reused)'
        } elseif ($NoPrewarm) {
            'skipped (-NoPrewarm)'
        } else {
            'enabled (builds the bundled index now)'
        }
        Write-Info "prewarm: $prewarmPlan"
    }
    Write-Host ''
    Write-Host 'Dry run finished; re-run without -DryRun to install.' -ForegroundColor Green
    exit 0
}

Initialize-PythonEnvironment -BasePython $script:PythonFound
if (-not $script:RunPython -or -not (Test-Path -LiteralPath $script:RunPython)) {
    Fail 'no Python interpreter is available to run the MCP server'
}

$serviceOk = $false
if ($script:Mode -eq 'B') {
    $preferredExe = if ($script:UserEverythingExe) { $script:UserEverythingExe } else { $EverythingExe }
    $serviceOk = Ensure-EverythingService -PreferredExe $preferredExe

    if (-not $script:UseBundledFallback) {
        Write-Info 'reusing your existing Everything index: no prewarm and no second database'
    } elseif (-not $serviceOk) {
        Write-Warn 'prewarm skipped because the Everything service is not available'
    } else {
        Invoke-Prewarm -TargetPython $script:RunPython
    }
} else {
    Write-Info 'mode A/C: bundled Everything will not be started; service install skipped'
}

Write-HostConfigs
Write-InstallRecord

Write-Host ''
Write-Host 'Installation complete.' -ForegroundColor Green
Write-Host ''
Write-Host "  mode           : $($script:Mode)"
Write-Host "  python         : $($script:RunPython)"
Write-Host "  dependencies   : $(if ($script:UseSitePackages) { 'runtime\site-packages' } else { 'runtime\venv' })"
if ($script:Mode -eq 'B') {
    if ($script:UserEverythingExe) {
        Write-Host "  everything     : reuse $($script:UserEverythingExe)"
        Write-Host '  index          : your existing index (no prewarm, no second database)'
    } else {
        Write-Host '  everything     : bundled copy (own index)'
    }
    Write-Host "  service        : $(if ($serviceOk) { 'Everything (installed or reused)' } else { 'NOT available; indexing may be limited' })"
    $prewarmText = if (-not $script:UseBundledFallback) {
        'not needed (existing index reused)'
    } elseif ($script:PrewarmOk) {
        'ready'
    } else {
        'not run'
    }
    Write-Host "  prewarm        : $prewarmText"
}
Write-Host "  config snippets: $(Join-Path $Root 'hosts')"
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host "  1. copy the snippet for your MCP host from $(Join-Path $Root 'hosts')"
Write-Host '  2. restart the host application so it spawns the MCP server'
Write-Host '  3. ask the agent to search a file (e.g. everything_search "*.pptx")'
Write-Host ''
