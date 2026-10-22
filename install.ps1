[CmdletBinding()]
param(
    [ValidatePattern('^(latest|v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)$')]
    [string]$Version = "latest",
    [string]$InstallPath = (Join-Path $env:ProgramData "KomariAgent")
)

$ErrorActionPreference = "Stop"
$Repository = "AlisaCat-S/komari-zig-agent-without-ssh"
$TaskName = "Komari Agent"
$BinaryPath = Join-Path $InstallPath "komari-agent.exe"
$ConfigPath = Join-Path $InstallPath "config.json"
$StatePath = Join-Path $InstallPath "state"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "Run this installer from an elevated PowerShell session."
    }
}

function Get-AssetArchitecture {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        "X64" { return "amd64" }
        "Arm64" { return "arm64" }
        "X86" { return "386" }
        default { throw "Unsupported Windows architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
    }
}

function Download-ReleaseAsset {
    param([string]$BaseUrl, [string]$Name, [string]$Destination)

    Invoke-WebRequest -Uri "$BaseUrl/$Name" -OutFile $Destination -UseBasicParsing
}

function Get-ExpectedSha256 {
    param([string]$SumsPath, [string]$Name)

    foreach ($line in Get-Content -LiteralPath $SumsPath) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($Name))$") {
            return $Matches[1].ToLowerInvariant()
        }
    }
    throw "SHA256SUMS does not contain $Name"
}

function Assert-ReleaseAssetHash {
    param([string]$Path, [string]$SumsPath, [string]$Name)

    $expected = Get-ExpectedSha256 $SumsPath $Name
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA-256 verification failed for $Name"
    }
}

function Set-InstallPermissions {
    param([string]$Directory, [string]$Config, [string]$StateDirectory)

    & icacls.exe $Directory /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" "*S-1-5-19:(OI)(CI)(RX)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set permissions on $Directory"
    }
    & icacls.exe $Config /inheritance:r /grant:r "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" "*S-1-5-19:(R)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set permissions on $Config"
    }
    & icacls.exe $StateDirectory /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" "*S-1-5-19:(OI)(CI)(M)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set permissions on $StateDirectory"
    }
}

Assert-Administrator
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$arch = Get-AssetArchitecture
$asset = "komari-agent-windows-$arch.exe"
$releaseBase = if ($Version -eq "latest") {
    "https://github.com/$Repository/releases/latest/download"
} else {
    "https://github.com/$Repository/releases/download/$Version"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) "komari-agent-install-$PID"
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $sumsPath = Join-Path $temp "SHA256SUMS"
    $assetPath = Join-Path $temp $asset
    $examplePath = Join-Path $temp "config.json.example"

    Write-Host "Downloading release assets from $Repository ($Version)"
    Download-ReleaseAsset $releaseBase "SHA256SUMS" $sumsPath
    Download-ReleaseAsset $releaseBase $asset $assetPath
    Download-ReleaseAsset $releaseBase "config.json.example" $examplePath
    Assert-ReleaseAssetHash $assetPath $sumsPath $asset
    Assert-ReleaseAssetHash $examplePath $sumsPath "config.json.example"

    $hadConfig = Test-Path -LiteralPath $ConfigPath
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    Copy-Item -LiteralPath $assetPath -Destination "$BinaryPath.new" -Force
    Move-Item -LiteralPath "$BinaryPath.new" -Destination $BinaryPath -Force
    if (-not $hadConfig) {
        Copy-Item -LiteralPath $examplePath -Destination $ConfigPath -Force
    }
    New-Item -ItemType Directory -Path $StatePath -Force | Out-Null
    Set-InstallPermissions $InstallPath $ConfigPath $StatePath

    $action = New-ScheduledTaskAction -Execute $BinaryPath -Argument "--config `"$ConfigPath`" --state-dir `"$StatePath`"" -WorkingDirectory $StatePath
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\LocalService" -LogonType ServiceAccount -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    if ($hadConfig) {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Installed $asset and started the $TaskName scheduled task." -ForegroundColor Green
    } else {
        Disable-ScheduledTask -TaskName $TaskName | Out-Null
        Write-Host "Installed $asset. Edit $ConfigPath with the panel endpoint and token." -ForegroundColor Yellow
        Write-Host "Then run: Enable-ScheduledTask -TaskName '$TaskName'; Start-ScheduledTask -TaskName '$TaskName'"
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
