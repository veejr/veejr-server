[CmdletBinding()]
param(
  [string]$BackupRoot = "C:\ProgramData\Veejr\backups",
  [string]$PassphraseFile = "C:\ProgramData\Veejr\backup-keys\google-drive.dpapi",
  [string]$PrimaryRepo = "",
  [string]$PythonExe = "C:\Users\eded1\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Security
if ([string]::IsNullOrWhiteSpace($PrimaryRepo)) {
  $PrimaryRepo = Split-Path -Parent $PSScriptRoot
}
$Services = @("veej_fable", "veejr_veejr0_dyndns_server_com")
$Containers = @("veej_caddy", "veej_coturn", "veej_postfix")
$ProgramDataRoot = "C:\ProgramData\Veejr"
$InstanceRoot = Join-Path $ProgramDataRoot "instances\veejr_veejr0_dyndns_server_com"
$CryptoScript = Join-Path $PSScriptRoot "veejr_backup_crypto.py"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRootFull = [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd("\")
$AllowedRoot = [System.IO.Path]::GetFullPath("C:\ProgramData\Veejr\backups").TrimEnd("\")

if ($BackupRootFull -ne $AllowedRoot -and -not $BackupRootFull.StartsWith("$AllowedRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "BackupRoot must be C:\ProgramData\Veejr\backups or one of its children."
}
if (-not (Test-Path -LiteralPath (Join-Path $PrimaryRepo "mix.exs"))) {
  throw "PrimaryRepo does not look like the Veejr repository: $PrimaryRepo"
}
foreach ($Required in @($PassphraseFile, $PythonExe, $CryptoScript)) {
  if (-not (Test-Path -LiteralPath $Required)) {
    throw "Required file is missing: $Required"
  }
}

function Invoke-Docker {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $PreviousErrorAction = $ErrorActionPreference
  try {
    # Native tools legitimately use stderr for warnings (for example, tar
    # skips Postfix's transient Unix sockets). Their exit code is authoritative.
    $ErrorActionPreference = "Continue"
    $Output = & docker @Arguments 2>&1
    $DockerExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorAction
  }
  if ($DockerExitCode -ne 0) {
    throw "docker $($Arguments[0]) failed: $($Output -join [Environment]::NewLine)"
  }
  return $Output
}

function Wait-ServiceReplicas {
  param([string]$Service, [int]$Wanted, [int]$TimeoutSeconds = 90)
  $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $Replicas = (Invoke-Docker @("service", "ls", "--filter", "name=$Service", "--format", "{{.Replicas}}") | Select-Object -First 1).Trim()
    if ($Replicas -match "^(\d+)/(\d+)$" -and [int]$Matches[1] -eq $Wanted -and [int]$Matches[2] -eq $Wanted) {
      return
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $Deadline)
  throw "Timed out waiting for $Service to reach $Wanted/$Wanted (last state: $Replicas)."
}

function Copy-RequiredItem {
  param([string]$Source, [string]$Destination)
  if (-not (Test-Path -LiteralPath $Source)) {
    throw "Required backup source is missing: $Source"
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

New-Item -ItemType Directory -Path $BackupRootFull -Force | Out-Null
$Staging = Join-Path $BackupRootFull "staging-$Stamp-$([guid]::NewGuid().ToString('N'))"
$PlainArchive = Join-Path $BackupRootFull "veejr-full-$Stamp.tar.gz"
$EncryptedArchive = Join-Path $BackupRootFull "veejr-full-$Stamp.veejrbak"
$VerifyArchive = Join-Path $BackupRootFull "verify-$Stamp-$([guid]::NewGuid().ToString('N')).tar.gz"
$ReplicaCounts = @{}
$ContainerWasRunning = @{}
$StoppedServices = $false
$StoppedContainers = $false
$Passphrase = $null
$PlainPassphraseBytes = $null

try {
try {
  New-Item -ItemType Directory -Path $Staging -Force | Out-Null
  foreach ($Directory in @("primary", "instances\veejr_veejr0_dyndns_server_com", "host", "docker\services", "docker\containers", "docker\volumes", "source", "recovery-tooling")) {
    New-Item -ItemType Directory -Path (Join-Path $Staging $Directory) -Force | Out-Null
  }

  foreach ($Service in $Services) {
    $ReplicaCounts[$Service] = [int]((Invoke-Docker @("service", "inspect", $Service, "--format", "{{.Spec.Mode.Replicated.Replicas}}") | Select-Object -First 1).Trim())
    $Spec = Invoke-Docker @("service", "inspect", $Service)
    $Spec | Set-Content -LiteralPath (Join-Path $Staging "docker\services\$Service.json") -Encoding UTF8
  }

  $VolumeRecords = @()
  foreach ($Container in $Containers) {
    $ContainerWasRunning[$Container] = ((Invoke-Docker @("inspect", $Container, "--format", "{{.State.Running}}") | Select-Object -First 1).Trim() -eq "true")
    $Spec = Invoke-Docker @("inspect", $Container)
    $Spec | Set-Content -LiteralPath (Join-Path $Staging "docker\containers\$Container.json") -Encoding UTF8
    $MountsJson = (Invoke-Docker @("inspect", $Container, "--format", "{{json .Mounts}}")) -join ""
    foreach ($Mount in ($MountsJson | ConvertFrom-Json)) {
      if ($Mount.Type -eq "volume") {
        $VolumeRecords += [pscustomobject]@{ Container = $Container; Name = $Mount.Name; Destination = $Mount.Destination }
      }
    }
  }

  $PrimaryCommit = (& git -C $PrimaryRepo rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw "Could not read the primary source commit." }
  & git -C $PrimaryRepo bundle create (Join-Path $Staging "source\veejr-source.bundle") --all
  if ($LASTEXITCODE -ne 0) { throw "Could not create the Veejr source bundle." }
  foreach ($RecoveryFile in @(
    "docs\OPERATIONS.md",
    "docs\HOST_RUNBOOK.md",
    "scripts\veejr_backup_crypto.py",
    "scripts\veejr_full_backup.ps1",
    "scripts\veejr_set_backup_passphrase.ps1"
  )) {
    Copy-RequiredItem (Join-Path $PrimaryRepo $RecoveryFile) (Join-Path $Staging "recovery-tooling")
  }

  $SecondContainer = Invoke-Docker @("ps", "--filter", "label=com.docker.swarm.service.name=veejr_veejr0_dyndns_server_com", "--format", "{{.ID}}") | Select-Object -First 1
  $SecondCommit = if ($SecondContainer) { (Invoke-Docker @("exec", $SecondContainer.Trim(), "git", "-C", "/app", "rev-parse", "HEAD") | Select-Object -First 1).Trim() } else { "unavailable" }

  $Manifest = [ordered]@{
    format = "veejr-full-backup-v1"
    created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    host = $env:COMPUTERNAME
    primary_commit = $PrimaryCommit
    provisioned_instance_commit = $SecondCommit
    services = $ReplicaCounts
    containers = $Containers
    encrypted_format = "AES-256-GCM; scrypt N=131072 r=8 p=1"
  }
  $Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Staging "manifest.json") -Encoding UTF8

  Write-Host "Pausing Veejr and supporting services for a consistent snapshot..." -ForegroundColor Cyan
  foreach ($Service in $Services) {
    Invoke-Docker @("service", "scale", "$Service=0") | Out-Null
  }
  $StoppedServices = $true
  foreach ($Service in $Services) { Wait-ServiceReplicas $Service 0 }

  $RunningContainers = @($Containers | Where-Object { $ContainerWasRunning[$_] })
  if ($RunningContainers.Count -gt 0) {
    Invoke-Docker (@("stop") + $RunningContainers) | Out-Null
    $StoppedContainers = $true
  }

  Copy-RequiredItem (Join-Path $PrimaryRepo "veejr_prod.db") (Join-Path $Staging "primary\veejr_prod.db")
  Copy-RequiredItem (Join-Path $PrimaryRepo "priv\static\uploads") (Join-Path $Staging "primary\uploads")
  foreach ($Suffix in @("-wal", "-shm")) {
    $Sidecar = Join-Path $PrimaryRepo "veejr_prod.db$Suffix"
    if (Test-Path -LiteralPath $Sidecar) { Copy-Item -LiteralPath $Sidecar -Destination (Join-Path $Staging "primary") -Force }
  }

  Copy-RequiredItem (Join-Path $InstanceRoot "data") (Join-Path $Staging "instances\veejr_veejr0_dyndns_server_com\data")
  foreach ($InstanceFile in @("veejr.env", "import-receipt.json")) {
    $Source = Join-Path $InstanceRoot $InstanceFile
    if (Test-Path -LiteralPath $Source) {
      Copy-Item -LiteralPath $Source -Destination (Join-Path $Staging "instances\veejr_veejr0_dyndns_server_com") -Force
    }
  }
  Copy-RequiredItem (Join-Path $ProgramDataRoot "secrets") (Join-Path $Staging "host\secrets")
  Copy-RequiredItem (Join-Path $ProgramDataRoot "caddy\Caddyfile") (Join-Path $Staging "host\Caddyfile")

  foreach ($Volume in $VolumeRecords) {
    $SafeName = "$($Volume.Container)--$($Volume.Name).tar.gz"
    Invoke-Docker @(
      "run", "--rm",
      "--mount", "type=volume,source=$($Volume.Name),target=/source,readonly",
      "--mount", "type=bind,source=$(Join-Path $Staging 'docker\volumes'),target=/backup",
      "elixir:1.20-otp-28", "tar", "-czf", "/backup/$SafeName", "-C", "/source", "."
    ) | Out-Null
  }
} finally {
  if ($StoppedContainers) {
    foreach ($Container in $Containers) {
      if ($ContainerWasRunning[$Container]) {
        try { Invoke-Docker @("start", $Container) | Out-Null } catch { Write-Warning $_ }
      }
    }
  }
  if ($StoppedServices) {
    foreach ($Service in $Services) {
      try { Invoke-Docker @("service", "scale", "$Service=$($ReplicaCounts[$Service])") | Out-Null } catch { Write-Warning $_ }
    }
  }
}

try {
  foreach ($Service in $Services) { Wait-ServiceReplicas $Service $ReplicaCounts[$Service] 180 }
  foreach ($Container in $Containers) {
    if ($ContainerWasRunning[$Container]) {
      $Running = (Invoke-Docker @("inspect", $Container, "--format", "{{.State.Running}}") | Select-Object -First 1).Trim()
      if ($Running -ne "true") { throw "$Container did not restart." }
    }
  }

  & $PythonExe $CryptoScript check-sqlite (Join-Path $Staging "primary\veejr_prod.db")
  if ($LASTEXITCODE -ne 0) { throw "Primary SQLite integrity check failed." }
  & $PythonExe $CryptoScript check-sqlite (Join-Path $Staging "instances\veejr_veejr0_dyndns_server_com\data\veejr_prod.db")
  if ($LASTEXITCODE -ne 0) { throw "Provisioned-instance SQLite integrity check failed." }

  & tar.exe -czf $PlainArchive -C $Staging .
  if ($LASTEXITCODE -ne 0) { throw "Could not create the compressed backup archive." }

  $ProtectedPassphraseBytes = [System.Convert]::FromBase64String((Get-Content -LiteralPath $PassphraseFile -Raw).Trim())
  $PassphraseEntropy = [System.Text.Encoding]::UTF8.GetBytes("Veejr backup key v1")
  $PlainPassphraseBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $ProtectedPassphraseBytes,
    $PassphraseEntropy,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
  )
  $Passphrase = [System.Text.Encoding]::UTF8.GetString($PlainPassphraseBytes)
  $env:VEEJR_BACKUP_PASSPHRASE = $Passphrase
  & $PythonExe $CryptoScript self-test
  if ($LASTEXITCODE -ne 0) { throw "Backup encryption self-test failed." }
  & $PythonExe $CryptoScript encrypt $PlainArchive $EncryptedArchive
  if ($LASTEXITCODE -ne 0) { throw "Backup encryption failed." }
  & $PythonExe $CryptoScript decrypt $EncryptedArchive $VerifyArchive
  if ($LASTEXITCODE -ne 0) { throw "Encrypted backup verification failed." }

  $Listing = & tar.exe -tzf $VerifyArchive
  if ($LASTEXITCODE -ne 0) { throw "Verified archive could not be read." }
  foreach ($RequiredEntry in @("manifest.json", "primary/veejr_prod.db", "primary/uploads/", "host/secrets/", "docker/services/veej_fable.json", "recovery-tooling/veejr_backup_crypto.py")) {
    if (-not ($Listing -match [regex]::Escape($RequiredEntry))) {
      throw "Verified archive is missing required entry: $RequiredEntry"
    }
  }

  $Hash = Get-FileHash -LiteralPath $EncryptedArchive -Algorithm SHA256
  "$($Hash.Hash.ToLowerInvariant())  $([System.IO.Path]::GetFileName($EncryptedArchive))" |
    Set-Content -LiteralPath "$EncryptedArchive.sha256" -Encoding ASCII

  Write-Host "Encrypted backup created and verified:" -ForegroundColor Green
  Write-Output $EncryptedArchive
  Write-Output "$EncryptedArchive.sha256"
} finally {
  $env:VEEJR_BACKUP_PASSPHRASE = $null
  $Passphrase = $null
  if ($PlainPassphraseBytes) { [System.Array]::Clear($PlainPassphraseBytes, 0, $PlainPassphraseBytes.Length) }
}
} finally {
  $env:VEEJR_BACKUP_PASSPHRASE = $null
  $Passphrase = $null
  if ($PlainPassphraseBytes) { [System.Array]::Clear($PlainPassphraseBytes, 0, $PlainPassphraseBytes.Length) }
  if (Test-Path -LiteralPath $PlainArchive) { Remove-Item -LiteralPath $PlainArchive -Force }
  if (Test-Path -LiteralPath $VerifyArchive) { Remove-Item -LiteralPath $VerifyArchive -Force }
  if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
}
