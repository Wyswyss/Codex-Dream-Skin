[CmdletBinding()]
param(
  [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common-windows.ps1')

$operationLock = Enter-DreamSkinOperationLock
try {
  $null = Get-DreamSkinNodeRuntime
  $registeredInstalls = @(Get-DreamSkinRegisteredCodexInstalls)
  if ($registeredInstalls.Count -eq 0) {
    throw 'The official OpenAI.Codex Store package is not installed or its identity cannot be validated.'
  }
  foreach ($registeredCodex in $registeredInstalls) {
    if ((Get-DreamSkinCodexProcesses -Codex $registeredCodex).Count -gt 0) {
      throw 'Close Codex before installing Dream Skin so config.toml cannot change during the transaction.'
    }
  }

  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $StatePath = Join-Path $StateRoot 'state.json'
  $existingState = Read-DreamSkinState -Path $StatePath
  if ($null -ne $existingState -and [int]$existingState.schemaVersion -eq 4) {
    $savedHost = Get-DreamSkinRecordedInjectorProcess -State $existingState
    $savedChild = Get-DreamSkinRecordedCodexProcess -State $existingState
    if ($savedHost -is [bool] -or $savedChild -is [bool]) {
      throw 'Saved private-pipe process identity is inconsistent. Restore or inspect the saved state before installing.'
    }
    if ($null -ne $savedHost -or $null -ne $savedChild) {
      throw 'A Dream Skin private-pipe session is still active. Restore it before installing again.'
    }
  }
  $savedPathCandidate = Get-DreamSkinCodexStatePathCandidate -State $existingState
  $savedCodex = Resolve-DreamSkinCodexInstallFromState -State $existingState -RegisteredInstalls $registeredInstalls
  if ($null -ne $savedPathCandidate -and $null -eq $savedCodex -and
    (Get-DreamSkinCodexProcesses -Codex $savedPathCandidate).Count -gt 0) {
    throw 'The saved Codex path is still running but no longer matches a registered Store package. Close it manually before installing.'
  }
  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  $ConfigPath = Join-Path $HOME '.codex\config.toml'
  $BackupPath = Join-Path $StateRoot 'config.before-dream-skin.toml'
  $shortcutStageRoot = $null
  $shortcutPlans = @()

  try {
    if (-not $NoShortcuts) {
      $shell = New-Object -ComObject WScript.Shell
      $desktop = [Environment]::GetFolderPath('Desktop')
      $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
      $powershellCommand = Get-Command powershell.exe -CommandType Application -ErrorAction Stop
      $powershell = $powershellCommand.Source
      $startScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
      $restoreScript = Join-Path $PSScriptRoot 'restore-dream-skin.ps1'
      $shortcutStageRoot = Join-Path $StateRoot "shortcut-stage-$([guid]::NewGuid().ToString('N'))"
      New-Item -ItemType Directory -Path $shortcutStageRoot -ErrorAction Stop | Out-Null

      $shortcutDefinitions = @(
        [pscustomobject]@{
          Destination = Join-Path $desktop 'Codex Dream Skin.lnk'
          Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -PromptRestart"
          Description = 'Launch official Codex with Dream Skin over a private inherited pipe'
        },
        [pscustomobject]@{
          Destination = Join-Path $startMenu 'Codex Dream Skin.lnk'
          Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -PromptRestart"
          Description = 'Launch official Codex with Dream Skin over a private inherited pipe'
        },
        [pscustomobject]@{
          Destination = Join-Path $desktop 'Codex Dream Skin - Restore.lnk'
          Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$restoreScript`" -RestoreBaseTheme -PromptRestart"
          Description = 'Restore the official Codex appearance and close the private pipe session'
        }
      )

      for ($index = 0; $index -lt $shortcutDefinitions.Count; $index++) {
        $definition = $shortcutDefinitions[$index]
        $stagedPath = Join-Path $shortcutStageRoot "$index.lnk"
        $shortcut = $shell.CreateShortcut($stagedPath)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = $definition.Arguments
        $shortcut.WorkingDirectory = $SkillRoot
        $shortcut.Description = $definition.Description
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $stagedPath)) {
          throw "Shortcut could not be staged: $($definition.Destination)"
        }
        $originalBytes = if (Test-Path -LiteralPath $definition.Destination) {
          [System.IO.File]::ReadAllBytes($definition.Destination)
        } else {
          $null
        }
        $shortcutPlans += [pscustomobject]@{
          Destination = $definition.Destination
          NewBytes = [System.IO.File]::ReadAllBytes($stagedPath)
          OriginalBytes = $originalBytes
          Applied = $false
        }
      }
    }

    $configInstalled = $false
    $configBackupCreated = $false
    $configBeforeBytes = $null
    $configAfterBytes = $null
    try {
      $configTransaction = Install-DreamSkinBaseTheme -ConfigPath $ConfigPath -BackupPath $BackupPath -PassThru
      $configInstalled = $true
      $configBackupCreated = [bool]$configTransaction.BackupCreated
      $configBeforeBytes = [byte[]]$configTransaction.OriginalBytes
      $configAfterBytes = [byte[]]$configTransaction.InstalledBytes

      foreach ($plan in $shortcutPlans) {
        Write-DreamSkinBytesAtomically -Path $plan.Destination -Bytes $plan.NewBytes `
          -ExpectedBytes $plan.OriginalBytes
        $plan.Applied = $true
      }
    } catch {
      $installError = $_
      $rollbackFailures = @()
      for ($index = $shortcutPlans.Count - 1; $index -ge 0; $index--) {
        $plan = $shortcutPlans[$index]
        if (-not $plan.Applied) { continue }
        try {
          if ($null -eq $plan.OriginalBytes) {
            Assert-DreamSkinFileUnchanged -Path $plan.Destination -ExpectedBytes $plan.NewBytes
            [System.IO.File]::Delete($plan.Destination)
            if (Test-Path -LiteralPath $plan.Destination) {
              throw "Created shortcut still exists: $($plan.Destination)"
            }
          } else {
            Write-DreamSkinBytesAtomically -Path $plan.Destination -Bytes $plan.OriginalBytes `
              -ExpectedBytes $plan.NewBytes
          }
        } catch {
          $rollbackFailures += "shortcut $($plan.Destination): $($_.Exception.Message)"
        }
      }

      if ($configInstalled) {
        try {
          if ($null -eq $configAfterBytes) { throw 'Installed config bytes could not be captured.' }
          Write-DreamSkinBytesAtomically -Path $ConfigPath -Bytes $configBeforeBytes `
            -ExpectedBytes $configAfterBytes
          if ($configBackupCreated -and (Test-Path -LiteralPath $BackupPath)) {
            Assert-DreamSkinFileUnchanged -Path $BackupPath -ExpectedBytes $configBeforeBytes
            [System.IO.File]::Delete($BackupPath)
          }
        } catch {
          $rollbackFailures += "config: $($_.Exception.Message)"
        }
      }

      if ($rollbackFailures.Count -gt 0) {
        throw "Dream Skin install failed and rollback was incomplete ($($rollbackFailures -join '; ')). Original error: $($installError.Exception.Message)"
      }
      throw $installError
    }
  } finally {
    if ($shortcutStageRoot -and (Test-Path -LiteralPath $shortcutStageRoot)) {
      Remove-Item -LiteralPath $shortcutStageRoot -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $shortcutStageRoot) {
        Write-Warning "Temporary shortcut staging directory remains: $shortcutStageRoot"
      }
    }
  }

  if ($NoShortcuts) {
    Write-Host 'Codex Dream Skin base theme installed. Run start-dream-skin.ps1 to launch it.'
  } else {
    Write-Host 'Codex Dream Skin installed. The launch shortcut asks before restarting an open Codex window.'
  }
} finally {
  Exit-DreamSkinOperationLock -Mutex $operationLock
}
