[CmdletBinding()]
param(
  [switch]$Uninstall,
  [switch]$RestoreBaseTheme,
  [switch]$RecoverConfigBackup,
  [switch]$PromptRestart,
  [switch]$ForceRestart,
  [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common-windows.ps1')

$operationLock = Enter-DreamSkinOperationLock
try {
  if ($RestoreBaseTheme -and $RecoverConfigBackup) {
    throw 'Choose either -RestoreBaseTheme or -RecoverConfigBackup, not both.'
  }

  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $StatePath = Join-Path $StateRoot 'state.json'
  $state = $null
  $invalidStateRecovery = $false
  try {
    $state = Read-DreamSkinState -Path $StatePath
  } catch {
    if (-not $RecoverConfigBackup) { throw }
    $invalidStateRecovery = $true
    Write-Warning 'State is invalid. Exact config recovery will continue only if every registered Codex process is closed; the invalid state will be archived unchanged.'
  }
  $registeredInstalls = @()
  if ($invalidStateRecovery) {
    $registeredInstalls = @(Get-DreamSkinRegisteredCodexInstalls)
  } else {
    try { $registeredInstalls = @(Get-DreamSkinRegisteredCodexInstalls) } catch { Write-Warning $_.Exception.Message }
  }
  $currentCodex = if ($registeredInstalls.Count -gt 0) { $registeredInstalls[0] } else { $null }
  $savedCodex = Resolve-DreamSkinCodexInstallFromState -State $state -RegisteredInstalls $registeredInstalls
  $savedCandidate = Get-DreamSkinCodexStatePathCandidate -State $state
  if ($null -ne $savedCandidate -and $null -eq $savedCodex -and
    (Get-DreamSkinCodexProcesses -Codex $savedCandidate).Count -gt 0) {
    throw 'The saved Codex executable is active but no longer matches a registered Store package. Close it manually; state and config were preserved.'
  }

  $backup = Join-Path $StateRoot 'config.before-dream-skin.toml'
  $config = Join-Path $HOME '.codex\config.toml'
  if ($RecoverConfigBackup) {
    if (-not (Test-Path -LiteralPath $backup)) { throw 'No pre-install config backup is available.' }
    $null = Read-DreamSkinUtf8File -Path $backup
  } elseif ($RestoreBaseTheme) {
    if (-not (Test-Path -LiteralPath $backup)) { throw 'No pre-install config backup is available.' }
    $null = Read-DreamSkinUtf8File -Path $backup
    $null = Read-DreamSkinUtf8File -Path $config
  }

  $hostProcess = $null
  $recordedChild = $null
  if ($null -ne $state -and [int]$state.schemaVersion -eq 4) {
    $hostProcess = Get-DreamSkinRecordedInjectorProcess -State $state
    $recordedChild = Get-DreamSkinRecordedCodexProcess -State $state
    if ($hostProcess -is [bool] -or $recordedChild -is [bool]) {
      throw 'A recorded private-pipe PID is active with a different identity. State and config were preserved.'
    }
  }

  $activeInstalls = @($registeredInstalls | Where-Object { (Get-DreamSkinCodexProcesses -Codex $_).Count -gt 0 })
  if ($activeInstalls.Count -gt 1) {
    throw 'Multiple registered Codex versions are active. Close them manually before restore.'
  }
  if ($invalidStateRecovery -and $activeInstalls.Count -gt 0) {
    throw 'Close every registered Codex process before recovering config with an invalid state file.'
  }
  $hadRunningCodex = $activeInstalls.Count -gt 0 -or $null -ne $recordedChild
  $forceAuthorized = [bool]$ForceRestart
  if ($hadRunningCodex -and $PromptRestart) {
    $restartMessage = if ($NoRelaunch) {
      'Restore will close Codex and its private Dream Skin session. If normal close fails, Yes authorizes forced termination and unsaved input may be lost. Continue?'
    } else {
      'Restore will close Codex and its private Dream Skin session, then reopen the official app. If normal close fails, Yes authorizes forced termination and unsaved input may be lost. Continue?'
    }
    $forceAuthorized = Confirm-DreamSkinRestart -Message $restartMessage
    if (-not $forceAuthorized) {
      Write-Host 'Restore was cancelled; no state or configuration was changed.'
      exit 0
    }
  }

  $restoreError = $null
  $invalidStateArchive = $null
  try {
    if ($null -ne $state -and [int]$state.schemaVersion -eq 4) {
      if ($null -ne $hostProcess) {
        if (-not (Stop-DreamSkinRecordedInjector -State $state)) {
          throw 'The private-pipe supervisor could not be stopped with exact identity validation.'
        }
      }
      if (-not (Wait-DreamSkinRecordedCodexExit -State $state -TimeoutSeconds 8)) {
        $child = Get-DreamSkinRecordedCodexProcess -State $state
        if ($child -is [bool]) { throw 'The recorded Codex PID changed identity during restore.' }
        if ($null -ne $child) {
          try { [void](Get-Process -Id ([int]$state.codexPid) -ErrorAction Stop).CloseMainWindow() } catch {}
          if (-not (Wait-DreamSkinRecordedCodexExit -State $state -TimeoutSeconds 7)) {
            if (-not $forceAuthorized) {
              throw 'Codex did not exit after its private pipe closed. Close it manually or explicitly use -ForceRestart.'
            }
            if (-not (Stop-DreamSkinRecordedCodex -State $state)) {
              throw 'The exact recorded Codex process could not be stopped.'
            }
          }
        }
      }
    } elseif ($null -ne $state) {
      foreach ($install in $activeInstalls) {
        Stop-DreamSkinCodex -Codex $install -AllowForce:$forceAuthorized
      }
      if (-not (Stop-DreamSkinRecordedInjector -State $state)) {
        throw 'The legacy saved injector PID no longer matches its visible identity; state was preserved.'
      }
    }

    if ($null -ne $state -and [int]$state.schemaVersion -eq 4) {
      foreach ($install in $registeredInstalls) {
        $null = Wait-DreamSkinCodexInstallExit -Codex $install -TimeoutSeconds 3
        if ((Get-DreamSkinCodexProcesses -Codex $install).Count -gt 0) {
          throw 'A new unrecorded Codex process appeared during restore. Close it manually; state and config were preserved.'
        }
      }
    } else {
      foreach ($install in $registeredInstalls) {
        if ((Get-DreamSkinCodexProcesses -Codex $install).Count -gt 0) {
          Stop-DreamSkinCodex -Codex $install -AllowForce:$forceAuthorized
        }
      }
    }

    if ($invalidStateRecovery) {
      $invalidStateArchive = Archive-DreamSkinStateFile -Path $StatePath
      if (-not $invalidStateArchive -or -not (Test-Path -LiteralPath $invalidStateArchive)) {
        throw 'The invalid state file could not be archived safely; config recovery was not attempted.'
      }
      Write-Warning "Invalid state was archived unchanged at $invalidStateArchive"
    }

    if ($RecoverConfigBackup) {
      $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N')
      $recoveryBackup = Join-Path $StateRoot "config.before-recovery-$stamp.toml"
      Restore-DreamSkinConfigBackup -ConfigPath $config -BackupPath $backup -RecoveryBackupPath $recoveryBackup
      Write-Host "Recovered the exact pre-install config; previous current config saved at $recoveryBackup"
    } elseif ($RestoreBaseTheme) {
      Restore-DreamSkinBaseTheme -ConfigPath $config -BackupPath $backup
    }
    if ($RecoverConfigBackup -or $RestoreBaseTheme) {
      $archiveStamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N')
      $archivePath = Join-Path $StateRoot "config.restored-$archiveStamp.toml"
      Archive-DreamSkinConfigBackup -BackupPath $backup -ArchivePath $archivePath
      Write-Host "Archived the completed pre-install backup at $archivePath"
    }

    if ($null -ne $state -and [int]$state.schemaVersion -eq 4) {
      foreach ($evidencePath in @("$($state.handshakePath)", "$($state.statusPath)")) {
        if (Test-Path -LiteralPath $evidencePath) {
          Remove-Item -LiteralPath $evidencePath -Force -ErrorAction Stop
          if (Test-Path -LiteralPath $evidencePath) {
            throw "Private-pipe evidence could not be removed: $evidencePath"
          }
        }
      }
    }
    if (Test-Path -LiteralPath $StatePath) {
      Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
      if (Test-Path -LiteralPath $StatePath) {
        throw "Dream Skin state could not be removed: $StatePath"
      }
    }
    if ($Uninstall) {
      $desktop = [Environment]::GetFolderPath('Desktop')
      $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
      @(
        (Join-Path $desktop 'Codex Dream Skin.lnk'),
        (Join-Path $desktop 'Codex Dream Skin - Restore.lnk'),
        (Join-Path $startMenu 'Codex Dream Skin.lnk')
      ) | ForEach-Object {
        if (Test-Path -LiteralPath $_) {
          Remove-Item -LiteralPath $_ -Force -ErrorAction Stop
          if (Test-Path -LiteralPath $_) { throw "Dream Skin shortcut could not be removed: $_" }
        }
      }
    }

    if ($hadRunningCodex -and -not $NoRelaunch) {
      if ($null -eq $currentCodex -or -not (Test-Path -LiteralPath $currentCodex.Executable)) {
        throw 'Codex cannot be reopened because its current official executable is unavailable.'
      }
      $null = Start-DreamSkinNormalCodex -Codex $currentCodex
    }
  } catch {
    $restoreError = $_
    if ($hadRunningCodex -and -not $NoRelaunch -and $null -ne $currentCodex -and
      (Get-DreamSkinCodexProcesses -Codex $currentCodex).Count -eq 0 -and
      (Test-Path -LiteralPath $currentCodex.Executable)) {
      try { $null = Start-DreamSkinNormalCodex -Codex $currentCodex } catch {
        Write-Warning 'Restore failed and Codex could not be reopened automatically.'
      }
    }
    throw $restoreError
  }

  Write-Host 'Dream Skin restore actions completed; the private pipe session is closed.'
} finally {
  Exit-DreamSkinOperationLock -Mutex $operationLock
}
