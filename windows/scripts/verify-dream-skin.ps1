[CmdletBinding()]
param(
  [string]$ScreenshotPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common-windows.ps1')

$operationLock = Enter-DreamSkinOperationLock
try {
  if ($ScreenshotPath) {
    throw 'Screenshots are unsupported in private-pipe mode because verification cannot open a second debugging connection.'
  }

  $StatePath = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\state.json'
  $state = Read-DreamSkinState -Path $StatePath
  if ($null -eq $state) { throw 'No saved Dream Skin session exists.' }
  if ([int]$state.schemaVersion -ne 4 -or "$($state.transport)" -cne 'pipe') {
    throw 'The saved session uses a legacy transport. Restore it, then start the private-pipe version.'
  }
  $savedCodex = Get-DreamSkinCodexInstallFromState -State $state
  if ($null -eq $savedCodex) {
    throw 'The saved Codex package identity no longer matches a registered official Store package.'
  }

  $hostProcess = Get-DreamSkinRecordedInjectorProcess -State $state
  if ($hostProcess -is [bool] -or $null -eq $hostProcess) {
    throw 'The saved private-pipe supervisor is not running with its exact recorded identity.'
  }
  $codexProcess = Get-DreamSkinRecordedCodexProcess -State $state
  if ($codexProcess -is [bool] -or $null -eq $codexProcess) {
    throw 'The saved Codex process is not running as the exact recorded child of the supervisor.'
  }
  $handshake = Read-DreamSkinPipeHandshake -Path "$($state.handshakePath)" `
    -SessionId "$($state.sessionId)" -ExpectedHostPid ([int]$state.injectorPid)
  if ([int]$handshake.codexPid -ne [int]$state.codexPid) {
    throw 'The private-pipe handshake Codex PID does not match saved state.'
  }
  $status = Read-DreamSkinPipeStatus -Path "$($state.statusPath)" -SessionId "$($state.sessionId)" `
    -HostPid ([int]$state.injectorPid) -CodexPid ([int]$state.codexPid) -MaximumAgeSeconds 15
  if (-not (Test-DreamSkinPipeStatusHealthy -Status $status)) {
    throw 'No attached Codex renderer currently passes Dream Skin verification.'
  }

  $status | ConvertTo-Json -Depth 8
} finally {
  Exit-DreamSkinOperationLock -Mutex $operationLock
}
