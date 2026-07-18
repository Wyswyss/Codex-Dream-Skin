[CmdletBinding()]
param(
  [switch]$RestartExisting,
  [switch]$PromptRestart,
  [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'
$Injector = Join-Path $PSScriptRoot 'injector.mjs'
. (Join-Path $PSScriptRoot 'common-windows.ps1')

$operationLock = Enter-DreamSkinOperationLock
try {
  if ($ProfilePath) { $ProfilePath = [System.IO.Path]::GetFullPath($ProfilePath) }
  $node = Get-DreamSkinNodeRuntime
  $registeredInstalls = @(Get-DreamSkinRegisteredCodexInstalls)
  if ($registeredInstalls.Count -eq 0) {
    throw 'The official OpenAI.Codex Store package is not installed or its identity cannot be validated.'
  }
  $codex = $registeredInstalls[0]

  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $StatePath = Join-Path $StateRoot 'state.json'
  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  $previousState = Read-DreamSkinState -Path $StatePath

  $activeInstalls = @($registeredInstalls | Where-Object { (Get-DreamSkinCodexProcesses -Codex $_).Count -gt 0 })
  if ($activeInstalls.Count -gt 1) {
    throw 'Multiple registered Codex package versions are active. Close them manually before starting Dream Skin.'
  }
  $savedPathCandidate = Get-DreamSkinCodexStatePathCandidate -State $previousState
  $savedCodex = Resolve-DreamSkinCodexInstallFromState -State $previousState -RegisteredInstalls $registeredInstalls
  if ($null -ne $savedPathCandidate -and $null -eq $savedCodex -and
    (Get-DreamSkinCodexProcesses -Codex $savedPathCandidate).Count -gt 0) {
    throw 'The saved Codex executable is active but no longer matches a registered Store package. Close it manually; state was preserved.'
  }

  $recordedHost = $null
  $recordedChild = $null
  $recordedSessionWasActive = $false
  if ($null -ne $previousState -and [int]$previousState.schemaVersion -eq 4) {
    $recordedHost = Get-DreamSkinRecordedInjectorProcess -State $previousState
    $recordedChild = Get-DreamSkinRecordedCodexProcess -State $previousState
    if ($recordedHost -is [bool] -or $recordedChild -is [bool]) {
      throw 'The saved private-pipe process identity no longer matches its PID. Close the affected process manually; state was preserved.'
    }
    $recordedSessionWasActive = [bool]($null -ne $recordedHost -or $null -ne $recordedChild)
  }

  $hasRunningCodex = $activeInstalls.Count -gt 0 -or $null -ne $recordedChild
  $restartAuthorized = [bool]$RestartExisting
  if ($hasRunningCodex -and -not $restartAuthorized -and $PromptRestart) {
    $restartAuthorized = Confirm-DreamSkinRestart -Message 'Codex must restart once to start Dream Skin over its private pipe. Unsaved input may be lost. Restart now?'
    if (-not $restartAuthorized) {
      Write-Host 'Dream Skin launch was cancelled; Codex was not changed.'
      exit 0
    }
  }
  if ($hasRunningCodex -and -not $restartAuthorized) {
    throw 'Codex is already open. Close it first or explicitly use -RestartExisting.'
  }

  $restartRecoveryNeeded = $hasRunningCodex
  $closedExistingCodex = $false
  $sessionId = $null
  $HandshakePath = $null
  $StatusPath = $null
  $argumentValues = $null
  $daemon = $null
  $daemonStarted = $false
  $injectorStartedAt = $null
  $handshake = $null
  $provisionalState = $null
  try {
    if ($null -ne $recordedHost) {
      if (-not (Stop-DreamSkinRecordedInjector -State $previousState)) {
        throw 'The saved private-pipe supervisor could not be stopped safely; state was preserved.'
      }
      $closedExistingCodex = $true
      if (-not (Wait-DreamSkinRecordedCodexExit -State $previousState -TimeoutSeconds 8)) {
        if (-not $restartAuthorized -or -not (Stop-DreamSkinRecordedCodex -State $previousState)) {
          throw 'The recorded Codex process did not exit after its private pipe closed.'
        }
      }
    } elseif ($null -ne $recordedChild) {
      $closedExistingCodex = $true
      if (-not $restartAuthorized -or -not (Stop-DreamSkinRecordedCodex -State $previousState)) {
        throw 'The orphaned recorded Codex process could not be stopped safely.'
      }
    }

    if ($recordedSessionWasActive) {
      foreach ($activeInstall in $activeInstalls) {
        $null = Wait-DreamSkinCodexInstallExit -Codex $activeInstall -TimeoutSeconds 3
      }
    }
    if ($activeInstalls.Count -eq 1 -and (Get-DreamSkinCodexProcesses -Codex $activeInstalls[0]).Count -gt 0) {
      if ($recordedSessionWasActive) {
        throw 'A new unrecorded Codex process appeared while the saved private-pipe session was closing. Close it manually before starting again.'
      }
      $closedExistingCodex = $true
      Stop-DreamSkinCodex -Codex $activeInstalls[0] -AllowForce:$restartAuthorized
    }
    if ($null -ne $previousState -and [int]$previousState.schemaVersion -lt 4) {
      if (-not (Stop-DreamSkinRecordedInjector -State $previousState)) {
        throw 'The legacy saved injector PID no longer matches its visible identity; state was preserved.'
      }
    }

    # Keep the previous state and its evidence until the replacement state is atomically committed.
    $sessionId = [guid]::NewGuid().ToString('N')
    $HandshakePath = Join-Path $StateRoot "handshake-$sessionId.json"
    $StatusPath = Join-Path $StateRoot "status-$sessionId.json"
    Remove-Item -LiteralPath $HandshakePath, $StatusPath -Force -ErrorAction SilentlyContinue

    $argumentValues = @(
      (ConvertTo-DreamSkinProcessArgument -Value $Injector),
      '--watch',
      '--codex-exe', (ConvertTo-DreamSkinProcessArgument -Value $codex.Executable),
      '--handshake', (ConvertTo-DreamSkinProcessArgument -Value $HandshakePath),
      '--status', (ConvertTo-DreamSkinProcessArgument -Value $StatusPath),
      '--session-id', $sessionId,
      '--timeout-ms', '60000'
    )
    if ($ProfilePath) {
      $argumentValues += @('--profile-path', (ConvertTo-DreamSkinProcessArgument -Value $ProfilePath))
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $node.Path
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.Arguments = $argumentValues -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    Remove-DreamSkinUnsafeEnvironmentVariables -StartInfo $startInfo
    $daemon = [System.Diagnostics.Process]::new()
    $daemon.StartInfo = $startInfo
    if (-not $daemon.Start()) { throw 'The private-pipe supervisor could not be started.' }
    $daemonStarted = $true
    $injectorStartedAt = Get-DreamSkinProcessStartedAt -ProcessId $daemon.Id
    if (-not $injectorStartedAt) { throw 'The supervisor process start time could not be recorded.' }

    $deadline = (Get-Date).AddSeconds(65)
    while ($null -eq $handshake) {
      if ($daemon.HasExited) { throw "The private-pipe supervisor exited during startup with code $($daemon.ExitCode)." }
      if ((Get-Date) -ge $deadline) { throw 'Codex did not publish a private-pipe handshake within 65 seconds.' }
      if (Test-Path -LiteralPath $HandshakePath) {
        $handshake = Read-DreamSkinPipeHandshake -Path $HandshakePath -SessionId $sessionId -ExpectedHostPid $daemon.Id
        break
      }
      Start-Sleep -Milliseconds 250
    }

    $codexStartedAt = Get-DreamSkinProcessStartedAt -ProcessId ([int]$handshake.codexPid)
    if (-not $codexStartedAt) { throw 'The launched Codex process start time could not be recorded.' }
    $provisionalState = [pscustomobject]@{
      schemaVersion = 4
      platform = 'windows'
      transport = 'pipe'
      sessionId = $sessionId
      injectorPid = $daemon.Id
      injectorStartedAt = $injectorStartedAt
      injectorPath = $Injector
      nodePath = $node.Path
      nodeVersion = $node.Version
      codexPid = [int]$handshake.codexPid
      codexStartedAt = $codexStartedAt
      codexExe = $codex.Executable
      codexPackageRoot = $codex.PackageRoot
      codexPackageFullName = $codex.PackageFullName
      codexPackageFamilyName = $codex.PackageFamilyName
      codexVersion = $codex.Version
      handshakePath = $HandshakePath
      statusPath = $StatusPath
      profilePath = $ProfilePath
      createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $verifiedHost = Get-DreamSkinRecordedInjectorProcess -State $provisionalState
    $verifiedChild = Get-DreamSkinRecordedCodexProcess -State $provisionalState
    if ($null -eq $verifiedHost -or $verifiedHost -is [bool] -or
      $null -eq $verifiedChild -or $verifiedChild -is [bool]) {
      throw 'The launched private-pipe process tree did not pass exact identity validation.'
    }

    $status = $null
    while ($null -eq $status -or -not (Test-DreamSkinPipeStatusHealthy -Status $status)) {
      if ($daemon.HasExited) { throw "The private-pipe supervisor exited during verification with code $($daemon.ExitCode)." }
      if ((Get-Date) -ge $deadline) { throw 'No Codex renderer passed Dream Skin verification within 65 seconds.' }
      if (Test-Path -LiteralPath $StatusPath) {
        $status = Read-DreamSkinPipeStatus -Path $StatusPath -SessionId $sessionId `
          -HostPid $daemon.Id -CodexPid ([int]$handshake.codexPid) -MaximumAgeSeconds 15
      }
      if ($null -eq $status -or -not (Test-DreamSkinPipeStatusHealthy -Status $status)) {
        Start-Sleep -Milliseconds 300
      }
    }

    $verifiedHost = Get-DreamSkinRecordedInjectorProcess -State $provisionalState
    $verifiedChild = Get-DreamSkinRecordedCodexProcess -State $provisionalState
    if ($null -eq $verifiedHost -or $verifiedHost -is [bool] -or
      $null -eq $verifiedChild -or $verifiedChild -is [bool]) {
      throw 'The verified private-pipe process tree changed before state could be committed.'
    }
    Write-DreamSkinState -Path $StatePath -State $provisionalState
  } catch {
    $startupError = $_
    if ($null -eq $provisionalState -and $null -ne $handshake -and $daemonStarted) {
      $cleanupCodexStartedAt = Get-DreamSkinProcessStartedAt -ProcessId ([int]$handshake.codexPid)
      if ($cleanupCodexStartedAt) {
        $provisionalState = [pscustomobject]@{
          schemaVersion = 4; platform = 'windows'; transport = 'pipe'; sessionId = $sessionId
          injectorPid = $daemon.Id; injectorStartedAt = $injectorStartedAt; injectorPath = $Injector
          nodePath = $node.Path; nodeVersion = $node.Version; codexPid = [int]$handshake.codexPid
          codexStartedAt = $cleanupCodexStartedAt; codexExe = $codex.Executable
          codexPackageRoot = $codex.PackageRoot; codexPackageFullName = $codex.PackageFullName
          codexPackageFamilyName = $codex.PackageFamilyName; codexVersion = $codex.Version
          handshakePath = $HandshakePath; statusPath = $StatusPath; profilePath = $ProfilePath
          createdAt = (Get-Date).ToUniversalTime().ToString('o')
        }
      }
    }
    $cleanupConfirmed = $true
    if ($null -ne $provisionalState) {
      try { $null = Stop-DreamSkinRecordedInjector -State $provisionalState } catch {
        $cleanupConfirmed = $false
        Write-Warning $_.Exception.Message
      }
    }
    if ($daemonStarted) {
      try {
        if (-not $daemon.HasExited) {
          $daemon.Kill()
          [void]$daemon.WaitForExit(5000)
        }
      } catch {
        $cleanupConfirmed = $false
        Write-Warning 'Startup rollback could not stop the exact supervisor process handle.'
      }
      try {
        if (-not $daemon.HasExited) { $cleanupConfirmed = $false }
      } catch {
        $cleanupConfirmed = $false
      }
    }
    if ($null -ne $provisionalState) {
      if (-not (Wait-DreamSkinRecordedCodexExit -State $provisionalState -TimeoutSeconds 8)) {
        try { $null = Stop-DreamSkinRecordedCodex -State $provisionalState } catch {
          $cleanupConfirmed = $false
          Write-Warning $_.Exception.Message
        }
      }
      if (-not (Wait-DreamSkinRecordedCodexExit -State $provisionalState -TimeoutSeconds 2)) {
        $cleanupConfirmed = $false
      }
    }
    if ($null -eq $provisionalState -and $null -ne $handshake) {
      $cleanupChildPid = [int]$handshake.codexPid
      $cleanupChild = Get-CimInstance Win32_Process -Filter "ProcessId = $cleanupChildPid" -ErrorAction SilentlyContinue
      if ($cleanupChild) {
        $cleanupChildPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $cleanupChild
        $cleanupChildCommand = "$($cleanupChild.CommandLine)"
        $cleanupHasPipe = [regex]::IsMatch($cleanupChildCommand, '(?i)(?:^|\s)--remote-debugging-pipe(?=$|\s)')
        $cleanupHasNetwork = [regex]::IsMatch(
          $cleanupChildCommand,
          '(?i)(?:^|\s)--remote-debugging-(?:port|address)(?:=|\s|$)'
        )
        if ((Test-DreamSkinPathEqual -Left $cleanupChildPath -Right $codex.Executable) -and
          [int]$cleanupChild.ParentProcessId -eq $daemon.Id -and $cleanupHasPipe -and -not $cleanupHasNetwork) {
          Stop-Process -Id $cleanupChildPid -Force -ErrorAction SilentlyContinue
          try { Wait-Process -Id $cleanupChildPid -Timeout 5 -ErrorAction Stop } catch {}
        } else {
          $cleanupConfirmed = $false
          Write-Warning 'Startup rollback skipped a Codex PID whose private-pipe identity could not be revalidated.'
        }
      }
      if (Get-Process -Id $cleanupChildPid -ErrorAction SilentlyContinue) { $cleanupConfirmed = $false }
    } elseif ($null -eq $handshake -and $daemonStarted) {
      # A child may have started just before handshake publication failed. Do not guess which
      # unrecorded Store process is ours; preserve evidence and require manual inspection.
      if ((Get-DreamSkinCodexProcesses -Codex $codex).Count -gt 0) { $cleanupConfirmed = $false }
    }

    if ($cleanupConfirmed) {
      $newEvidencePaths = @($HandshakePath, $StatusPath) | Where-Object { $_ }
      if ($newEvidencePaths.Count -gt 0) {
        Remove-Item -LiteralPath $newEvidencePaths -Force -ErrorAction SilentlyContinue
      }
    } elseif ($null -ne $provisionalState) {
      try {
        Write-DreamSkinState -Path $StatePath -State $provisionalState
        Write-Warning "Startup rollback was incomplete; recovery state was preserved at $StatePath."
      } catch {
        Write-Warning 'Startup rollback was incomplete and recovery state could not be written; runtime evidence was preserved.'
      }
    } else {
      Write-Warning 'Startup rollback could not confirm every launched process exited; existing state and runtime evidence were preserved.'
    }

    if ($cleanupConfirmed -and ($restartRecoveryNeeded -or $closedExistingCodex -or $null -ne $handshake) -and
      (Get-DreamSkinCodexProcesses -Codex $codex).Count -eq 0) {
      try { $null = Start-DreamSkinNormalCodex -Codex $codex } catch {
        Write-Warning 'Dream Skin startup failed and Codex could not be reopened automatically.'
      }
    } elseif (-not $cleanupConfirmed -and ($restartRecoveryNeeded -or $closedExistingCodex)) {
      Write-Warning 'Codex was not reopened because startup rollback could not prove that the private-pipe process tree exited.'
    }
    throw $startupError
  }

  if ($null -ne $previousState -and [int]$previousState.schemaVersion -eq 4) {
    foreach ($oldEvidencePath in @("$($previousState.handshakePath)", "$($previousState.statusPath)")) {
      if ($oldEvidencePath -and
        -not (Test-DreamSkinPathEqual -Left $oldEvidencePath -Right $HandshakePath) -and
        -not (Test-DreamSkinPathEqual -Left $oldEvidencePath -Right $StatusPath)) {
        Remove-Item -LiteralPath $oldEvidencePath -Force -ErrorAction SilentlyContinue
      }
    }
  }

  Write-Host 'Codex Dream Skin is active over a private inherited debugging pipe.'
} finally {
  Exit-DreamSkinOperationLock -Mutex $operationLock
}
