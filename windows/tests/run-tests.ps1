[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'scripts\common-windows.ps1')

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-dream-skin-tests-$PID-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
  $savedLocalAppData = $env:LOCALAPPDATA
  try {
    $env:LOCALAPPDATA = $temporaryRoot
    $firstOperationLock = Enter-DreamSkinOperationLock
    try {
      $secondLockRejected = $false
      try { $null = Enter-DreamSkinOperationLock } catch { $secondLockRejected = $true }
      if (-not $secondLockRejected) { throw 'The operation lock allowed a second exclusive file handle.' }
    } finally {
      Exit-DreamSkinOperationLock -Mutex $firstOperationLock
    }
    $reopenedOperationLock = Enter-DreamSkinOperationLock
    Exit-DreamSkinOperationLock -Mutex $reopenedOperationLock
  } finally {
    $env:LOCALAPPDATA = $savedLocalAppData
  }

  $configPath = Join-Path $temporaryRoot 'config.toml'
  $backupPath = Join-Path $temporaryRoot 'config.before-dream-skin.toml'
  $projectName = -join @([char]0x4EE3, [char]0x7801, [char]0x9879, [char]0x76EE, [char]0x7532)
  $laterValue = -join @([char]0x4FDD, [char]0x7559)
  $sample = "model = `"gpt-5`"`r`n`r`n[other]`r`nappearanceTheme = `"keep-other`"`r`n`r`n[projects.'C:\$projectName']`r`ntrust_level = `"trusted`"`r`n`r`n[desktop]`r`nappearanceTheme = `"system`"`r`nappearanceLightCodeThemeId = `"theme-`$special`"`r`n"
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
  [System.IO.File]::WriteAllText($configPath, $sample, $utf8NoBom)
  $originalBytes = [System.IO.File]::ReadAllBytes($configPath)

  Install-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  $installed = Read-DreamSkinUtf8File -Path $configPath
  if (-not $installed.Contains($projectName) -or $installed -notmatch 'appearanceTheme = "light"') {
    throw 'Install changed a non-ASCII project name or missed the base theme.'
  }
  $backupBytes = [System.IO.File]::ReadAllBytes($backupPath)
  if ([Convert]::ToBase64String($backupBytes) -cne [Convert]::ToBase64String($originalBytes)) {
    throw 'Install did not preserve an exact pre-change config backup.'
  }

  $written = [System.IO.File]::ReadAllBytes($configPath)
  if ($written.Length -ge 3 -and $written[0] -eq 0xEF -and $written[1] -eq 0xBB -and $written[2] -eq 0xBF) {
    throw 'Config writer added an unexpected UTF-8 BOM.'
  }

  $installed += "afterInstall = `"$laterValue`"`r`n"
  Write-DreamSkinUtf8FileAtomically -Path $configPath -Content $installed
  Restore-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  $restored = Read-DreamSkinUtf8File -Path $configPath
  if (-not $restored.Contains($projectName) -or -not $restored.Contains($laterValue)) {
    throw 'Restore changed a project name or unrelated post-install setting.'
  }
  if ($restored -notmatch 'appearanceTheme = "system"' -or -not $restored.Contains('appearanceLightCodeThemeId = "theme-$special"')) {
    throw 'Restore did not put the original base theme keys back.'
  }
  if ($restored -notmatch '(?ms)^\[other\].*?appearanceTheme = "keep-other"') {
    throw 'Restore changed an appearance key outside the desktop section.'
  }

  $lfConfigPath = Join-Path $temporaryRoot 'config-lf.toml'
  $lfBackupPath = Join-Path $temporaryRoot 'config-lf.before.toml'
  $lfOriginal = "model = `"gpt-5`"`n[projects.'C:\$projectName']`ntrust_level = `"trusted`"`n"
  [System.IO.File]::WriteAllText($lfConfigPath, $lfOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $lfConfigPath -BackupPath $lfBackupPath
  $lfInstalled = Read-DreamSkinUtf8File -Path $lfConfigPath
  if ($lfInstalled.Contains("`r") -or $lfInstalled -notmatch '(?m)^\[desktop\]$') {
    throw 'Install did not preserve LF line endings or create the desktop section.'
  }
  Restore-DreamSkinBaseTheme -ConfigPath $lfConfigPath -BackupPath $lfBackupPath
  $lfRestored = Read-DreamSkinUtf8File -Path $lfConfigPath
  if ($lfRestored.Contains("`r") -or $lfRestored -match '(?m)^\[desktop\]$' -or -not $lfRestored.Contains($projectName)) {
    throw 'Restore did not preserve LF content or remove the generated empty desktop section.'
  }

  $quotedConfigPath = Join-Path $temporaryRoot 'config-quoted.toml'
  $quotedBackupPath = Join-Path $temporaryRoot 'config-quoted.before.toml'
  $quotedOriginal = "[`"desktop`"] # retained comment`r`n`"appearanceTheme`" = `"system`"`r`n'appearanceLightCodeThemeId' = `"theme-`$special`"`r`n"
  [System.IO.File]::WriteAllText($quotedConfigPath, $quotedOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $quotedConfigPath -BackupPath $quotedBackupPath
  $quotedInstalled = Read-DreamSkinUtf8File -Path $quotedConfigPath
  if ([regex]::Matches($quotedInstalled, '(?m)^\s*\[(?:"desktop"|desktop)\]').Count -ne 1) {
    throw 'A commented or quoted desktop table was duplicated during install.'
  }
  Restore-DreamSkinBaseTheme -ConfigPath $quotedConfigPath -BackupPath $quotedBackupPath
  $quotedRestored = Read-DreamSkinUtf8File -Path $quotedConfigPath
  if ($quotedRestored -cne $quotedOriginal) {
    $expectedBase64 = [Convert]::ToBase64String($utf8NoBom.GetBytes($quotedOriginal))
    $actualBase64 = [Convert]::ToBase64String($utf8NoBom.GetBytes($quotedRestored))
    throw "Quoted desktop keys or a table-header comment were not restored exactly. ExpectedBase64=$expectedBase64 ActualBase64=$actualBase64"
  }

  $singleLineArrayPath = Join-Path $temporaryRoot 'config-single-line-array.toml'
  $singleLineArrayBackup = Join-Path $temporaryRoot 'config-single-line-array.before.toml'
  $singleLineArray = "labels = [`"name[1]`", `"#tag]`"]`r`n"
  [System.IO.File]::WriteAllText($singleLineArrayPath, $singleLineArray, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $singleLineArrayPath -BackupPath $singleLineArrayBackup
  if (-not (Read-DreamSkinUtf8File -Path $singleLineArrayPath).Contains($singleLineArray.TrimEnd())) {
    throw 'A safe single-line array containing bracket text was changed or rejected.'
  }

  foreach ($unsupported in @(
    'desktop.appearanceTheme = "system"',
    'desktop = { appearanceTheme = "system" }',
    '[[desktop]]',
    '[desktop.appearanceTheme]',
    '["desktop".layout]',
    '["desk\u0074op".layout]',
    '["desk\u0074op"]',
    "note = `"`"`"fake`r`n[desktop]`r`nappearanceTheme = `"dark`"`r`n`"`"`"",
    "[desktop]`r`nappearanceTheme = [`r`n  `"light`"`r`n]",
    "[desktop]`r`nlayout = [`r`n  [1, 2],`r`n  [3, 4],`r`n]`r`nappearanceTheme = `"dark`"",
    "[desktop]`r`nlayout = [`"]`",`r`n  [`"[`", `"]`"],`r`n]`r`nappearanceTheme = `"dark`""
  )) {
    $unsupportedPath = Join-Path $temporaryRoot ("unsupported-$([guid]::NewGuid().ToString('N')).toml")
    $unsupportedBackup = "$unsupportedPath.before"
    [System.IO.File]::WriteAllText($unsupportedPath, $unsupported, $utf8NoBom)
    $unsupportedRejected = $false
    try { Install-DreamSkinBaseTheme -ConfigPath $unsupportedPath -BackupPath $unsupportedBackup } catch { $unsupportedRejected = $true }
    if (-not $unsupportedRejected -or (Test-Path -LiteralPath $unsupportedBackup)) {
      throw "Unsupported TOML desktop representation was not rejected safely: $unsupported"
    }
  }

  $recoveryPath = Join-Path $temporaryRoot 'config.before-recovery.toml'
  Write-DreamSkinUtf8FileAtomically -Path $configPath -Content 'intentionally changed'
  Restore-DreamSkinConfigBackup -ConfigPath $configPath -BackupPath $backupPath -RecoveryBackupPath $recoveryPath
  $recoveredBytes = [System.IO.File]::ReadAllBytes($configPath)
  if ([Convert]::ToBase64String($recoveredBytes) -cne [Convert]::ToBase64String($originalBytes)) {
    throw 'Exact config recovery did not restore the original bytes.'
  }
  if ((Read-DreamSkinUtf8File -Path $recoveryPath) -cne 'intentionally changed') {
    throw 'Exact config recovery did not preserve the replaced current config.'
  }
  $archivePath = Join-Path $temporaryRoot 'config.restored.toml'
  Archive-DreamSkinConfigBackup -BackupPath $backupPath -ArchivePath $archivePath
  if ((Test-Path -LiteralPath $backupPath) -or -not (Test-Path -LiteralPath $archivePath)) {
    throw 'Completed config backup was not archived for a safe future reinstall.'
  }
  $secondBaseline = "[desktop]`r`nappearanceTheme = `"dark`"`r`n"
  [System.IO.File]::WriteAllText($configPath, $secondBaseline, $utf8NoBom)
  $secondBaselineBytes = [System.IO.File]::ReadAllBytes($configPath)
  Install-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  if (-not (Test-DreamSkinBytesEqual -Left $secondBaselineBytes -Right ([System.IO.File]::ReadAllBytes($backupPath)))) {
    throw 'Reinstall did not capture a fresh config baseline after completed restore.'
  }

  $invalidPath = Join-Path $temporaryRoot 'invalid.toml'
  $invalidBackupPath = Join-Path $temporaryRoot 'invalid.before.toml'
  [System.IO.File]::WriteAllBytes($invalidPath, [byte[]](0x66, 0x6f, 0x80))
  $rejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $invalidPath -BackupPath $invalidBackupPath } catch { $rejected = $true }
  if (-not $rejected -or (Test-Path -LiteralPath $invalidBackupPath)) {
    throw 'Invalid UTF-8 input was not rejected before backup creation.'
  }
  $utf16Path = Join-Path $temporaryRoot 'utf16.toml'
  $utf16BackupPath = Join-Path $temporaryRoot 'utf16.before.toml'
  [System.IO.File]::WriteAllText($utf16Path, 'model = "gpt-5"', [System.Text.Encoding]::Unicode)
  $utf16Rejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $utf16Path -BackupPath $utf16BackupPath } catch { $utf16Rejected = $true }
  if (-not $utf16Rejected -or (Test-Path -LiteralPath $utf16BackupPath)) {
    throw 'A UTF-16 config was silently transcoded instead of being rejected.'
  }
  $utf16NoBomPath = Join-Path $temporaryRoot 'utf16-no-bom.toml'
  $utf16NoBomBackupPath = Join-Path $temporaryRoot 'utf16-no-bom.before.toml'
  [System.IO.File]::WriteAllBytes($utf16NoBomPath, [System.Text.Encoding]::Unicode.GetBytes('model = "gpt-5"'))
  $utf16NoBomRejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $utf16NoBomPath -BackupPath $utf16NoBomBackupPath } catch { $utf16NoBomRejected = $true }
  if (-not $utf16NoBomRejected -or (Test-Path -LiteralPath $utf16NoBomBackupPath)) {
    throw 'A BOM-less UTF-16 config was silently treated as UTF-8 instead of being rejected.'
  }
  $racePath = Join-Path $temporaryRoot 'race.toml'
  [System.IO.File]::WriteAllText($racePath, 'before', $utf8NoBom)
  $raceExpected = [System.IO.File]::ReadAllBytes($racePath)
  [System.IO.File]::WriteAllText($racePath, 'after', $utf8NoBom)
  $raceRejected = $false
  try { Assert-DreamSkinFileUnchanged -Path $racePath -ExpectedBytes $raceExpected } catch { $raceRejected = $true }
  if (-not $raceRejected) { throw 'Concurrent config modification was not detected.' }
  $conditionalWriteRejected = $false
  try {
    Write-DreamSkinUtf8FileAtomically -Path $racePath -Content 'replacement' -ExpectedBytes $raceExpected
  } catch {
    $conditionalWriteRejected = $true
  }
  if (-not $conditionalWriteRejected -or (Read-DreamSkinUtf8File -Path $racePath) -cne 'after') {
    throw 'Conditional atomic write replaced newer config content.'
  }

  $watchCommand = '"C:\Program Files\nodejs\node.exe" "C:\Dream Skin\injector.mjs" --watch --session-id 0123456789abcdef0123456789abcdef'
  if (-not (Test-DreamSkinCommandLineToken -CommandLine $watchCommand -Token 'C:\Dream Skin\injector.mjs') -or
    (Test-DreamSkinCommandLineToken -CommandLine $watchCommand -Token 'Dream Skin\injector.mjs')) {
    throw 'Injector command-line token validation is not boundary-safe.'
  }
  if (-not (Test-DreamSkinCommandLineOptionValue -CommandLine $watchCommand -Option '--session-id' `
    -Value '0123456789abcdef0123456789abcdef') -or
    (Test-DreamSkinCommandLineOptionValue -CommandLine $watchCommand -Option '--session-id' -Value '0123')) {
    throw 'Private-pipe command-line value validation is not boundary-safe.'
  }
  $quotedOptionCommand = 'node.exe injector.mjs --codex-exe "C:\Dream Skin\ChatGPT.exe"'
  if (-not (Test-DreamSkinCommandLineOptionValue -CommandLine $quotedOptionCommand `
    -Option '--codex-exe' -Value 'C:\Dream Skin\ChatGPT.exe')) {
    throw 'A correctly quoted process option was rejected.'
  }
  foreach ($malformedCommand in @(
    'node.exe injector.mjs --codex-exe "C:\Dream Skin\ChatGPT.exe',
    'node.exe injector.mjs --codex-exe C:\Dream Skin\ChatGPT.exe"',
    'node.exe injector.mjs --codex-exe C:\Dream Skin\ChatGPT.exe'
  )) {
    if (Test-DreamSkinCommandLineOptionValue -CommandLine $malformedCommand `
      -Option '--codex-exe' -Value 'C:\Dream Skin\ChatGPT.exe') {
      throw "An unpaired or missing process-option quote was accepted: $malformedCommand"
    }
  }
  if (-not (Test-DreamSkinSessionId -Value '0123456789abcdef0123456789abcdef') -or
    (Test-DreamSkinSessionId -Value 'browser-123')) {
    throw 'Private-pipe session ID validation is not boundary-safe.'
  }
  $quotedProfile = ConvertTo-DreamSkinProcessArgument -Value '--user-data-dir=C:\Dream Skin\Profile\'
  if ($quotedProfile -cne '"--user-data-dir=C:\Dream Skin\Profile\\"') {
    throw 'Process argument quoting did not protect spaces and a trailing backslash.'
  }
  if ((ConvertTo-DreamSkinProcessArgument -Value '') -cne '""') {
    throw 'An empty process argument would disappear from the child command line.'
  }
  foreach ($validProcessNumber in @([int]1, [long]2345, [double]42.0)) {
    if (-not (Test-DreamSkinPositiveInt32Value -Value $validProcessNumber)) {
      throw "A valid integral process number was rejected: $validProcessNumber"
    }
  }
  foreach ($invalidProcessNumber in @('1', [double]1.5, 0, [long]2147483648)) {
    if (Test-DreamSkinPositiveInt32Value -Value $invalidProcessNumber) {
      throw "An invalid process number was accepted: $invalidProcessNumber"
    }
  }

  $statePath = Join-Path $temporaryRoot 'state.json'
  Write-DreamSkinUtf8FileAtomically -Path $statePath -Content '{}'
  $emptyJsonObject = Read-DreamSkinJsonObject -Path $statePath -Description 'Test JSON object'
  $emptyLegacyState = Read-DreamSkinState -Path $statePath
  if (-not (Test-DreamSkinJsonObjectValue -Value $emptyJsonObject) -or
    -not (Test-DreamSkinJsonObjectValue -Value $emptyLegacyState)) {
    throw 'An empty JSON object was not preserved as a PSCustomObject.'
  }
  foreach ($invalidRoot in @('true', '123', '[]', '[{}]')) {
    Write-DreamSkinUtf8FileAtomically -Path $statePath -Content $invalidRoot
    $jsonObjectRejected = $false
    $stateRootRejected = $false
    try {
      $null = Read-DreamSkinJsonObject -Path $statePath -Description 'Test JSON object'
    } catch {
      $jsonObjectRejected = $true
    }
    try { $null = Read-DreamSkinState -Path $statePath } catch { $stateRootRejected = $true }
    if (-not $jsonObjectRejected -or -not $stateRootRejected) {
      throw "A non-object JSON root was accepted: $invalidRoot"
    }
  }

  $state = [pscustomobject]@{
    schemaVersion = 4
    platform = 'windows'
    transport = 'pipe'
    sessionId = '0123456789abcdef0123456789abcdef'
    injectorPid = 1234
    injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
    injectorPath = 'C:\Dream Skin\injector.mjs'
    nodePath = 'C:\Program Files\nodejs\node.exe'
    nodeVersion = '22.1.0'
    codexPid = 2345
    codexStartedAt = '2026-01-01T00:00:01.0000000Z'
    codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex\app\ChatGPT.exe'
    codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex'
    codexPackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
    codexPackageFamilyName = 'OpenAI.Codex_test'
    codexVersion = '1.2.3.4'
    handshakePath = Join-Path $temporaryRoot 'handshake-0123456789abcdef0123456789abcdef.json'
    statusPath = Join-Path $temporaryRoot 'status-0123456789abcdef0123456789abcdef.json'
    createdAt = '2026-01-01T00:00:02.0000000Z'
  }
  Write-DreamSkinState -Path $statePath -State $state
  $loadedState = Read-DreamSkinState -Path $statePath
  if ($loadedState.schemaVersion -ne 4 -or $loadedState.transport -cne 'pipe' -or
    $loadedState.sessionId -cne $state.sessionId) { throw 'Schema 4 state round-trip failed.' }

  $handshakeValue = [pscustomobject]@{
    schemaVersion = 1
    transport = 'pipe'
    sessionId = $state.sessionId
    hostPid = $state.injectorPid
    codexPid = $state.codexPid
    createdAt = [DateTimeOffset]::UtcNow.ToString('o')
  }
  Write-DreamSkinUtf8FileAtomically -Path $state.handshakePath `
    -Content (($handshakeValue | ConvertTo-Json -Depth 4) + "`r`n")
  $loadedHandshake = Read-DreamSkinPipeHandshake -Path $state.handshakePath `
    -SessionId $state.sessionId -ExpectedHostPid $state.injectorPid
  if ([int]$loadedHandshake.codexPid -ne $state.codexPid) { throw 'Private-pipe handshake round-trip failed.' }

  $verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
  $statusValue = [pscustomobject]@{
    schemaVersion = 1
    transport = 'pipe'
    sessionId = $state.sessionId
    version = 'test-version'
    hostPid = $state.injectorPid
    codexPid = $state.codexPid
    healthy = $true
    error = $null
    targets = @([pscustomobject]@{
      targetId = 'target-1'
      markers = [pscustomobject]@{ shell = $true }
      lastVerifiedAt = $verifiedAt
      appProtocol = 'app:'
      appIdentity = $true
      result = [pscustomobject]@{
        pass = $true
        installed = $true
        version = 'test-version'
        expectedVersion = 'test-version'
        stylePresent = $true
        chromePresent = $true
        chromePointerEvents = 'none'
        composer = [pscustomobject]@{ x = 300; y = 700; width = 600; height = 120 }
        sidebar = [pscustomobject]@{ x = 0; y = 0; width = 260; height = 900 }
      }
    })
    updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
  }
  Write-DreamSkinUtf8FileAtomically -Path $state.statusPath `
    -Content (($statusValue | ConvertTo-Json -Depth 8) + "`r`n")
  $loadedStatus = Read-DreamSkinPipeStatus -Path $state.statusPath -SessionId $state.sessionId `
    -HostPid $state.injectorPid -CodexPid $state.codexPid
  if (-not (Test-DreamSkinPipeStatusHealthy -Status $loadedStatus)) {
    throw 'A fresh passing private-pipe status was rejected.'
  }
  $loadedStatus.targets[0].result.stylePresent = $false
  if (Test-DreamSkinPipeStatusHealthy -Status $loadedStatus) {
    throw 'Status health accepted a passing flag without the required renderer evidence.'
  }
  $loadedStatus.targets[0].result.stylePresent = $true
  $loadedStatus.targets[0].appIdentity = $false
  if (Test-DreamSkinPipeStatusHealthy -Status $loadedStatus) {
    throw 'Status health accepted a target that failed the app identity check.'
  }
  $loadedStatus.targets[0].appIdentity = $true
  $loadedStatus.targets[0].appProtocol = 'https:'
  if (Test-DreamSkinPipeStatusHealthy -Status $loadedStatus) {
    throw 'Status health accepted a non-app renderer protocol.'
  }
  $loadedStatus.targets[0].appProtocol = 'app:'
  $loadedStatus.targets[0].result.composer.width = 0
  if (Test-DreamSkinPipeStatusHealthy -Status $loadedStatus) {
    throw 'Status health accepted an invalid renderer geometry object.'
  }
  $loadedStatus.targets[0].result.composer.width = 600
  $loadedStatus.targets[0].lastVerifiedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
  if (Test-DreamSkinPipeStatusHealthy -Status $loadedStatus) {
    throw 'Status health accepted stale renderer evidence under a fresh root heartbeat.'
  }

  $statusValue.targets[0].appProtocol = 'https:'
  $statusValue.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
  Write-DreamSkinUtf8FileAtomically -Path $state.statusPath `
    -Content (($statusValue | ConvertTo-Json -Depth 8) + "`r`n")
  $invalidProtocolRejected = $false
  try {
    $null = Read-DreamSkinPipeStatus -Path $state.statusPath -SessionId $state.sessionId `
      -HostPid $state.injectorPid -CodexPid $state.codexPid
  } catch {
    $invalidProtocolRejected = $true
  }
  if (-not $invalidProtocolRejected) { throw 'Status parsing accepted a non-app renderer protocol.' }
  $statusValue.targets[0].appProtocol = 'app:'

  $savedTarget = $statusValue.targets[0]
  $statusValue.targets = @('not-an-object')
  $statusValue.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
  Write-DreamSkinUtf8FileAtomically -Path $state.statusPath `
    -Content (($statusValue | ConvertTo-Json -Depth 8) + "`r`n")
  $scalarTargetRejected = $false
  try {
    $null = Read-DreamSkinPipeStatus -Path $state.statusPath -SessionId $state.sessionId `
      -HostPid $state.injectorPid -CodexPid $state.codexPid
  } catch {
    $scalarTargetRejected = $true
  }
  if (-not $scalarTargetRejected) { throw 'Status parsing accepted a scalar target entry.' }
  $statusValue.targets = @($savedTarget)

  $savedResult = $statusValue.targets[0].result
  $statusValue.targets[0].result = $true
  Write-DreamSkinUtf8FileAtomically -Path $state.statusPath `
    -Content (($statusValue | ConvertTo-Json -Depth 8) + "`r`n")
  $scalarResultRejected = $false
  try {
    $null = Read-DreamSkinPipeStatus -Path $state.statusPath -SessionId $state.sessionId `
      -HostPid $state.injectorPid -CodexPid $state.codexPid
  } catch {
    $scalarResultRejected = $true
  }
  if (-not $scalarResultRejected) { throw 'Status parsing accepted a scalar renderer result.' }
  $statusValue.targets[0].result = $savedResult

  $statusValue.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
  $statusValue.targets[0].lastVerifiedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
  Write-DreamSkinUtf8FileAtomically -Path $state.statusPath `
    -Content (($statusValue | ConvertTo-Json -Depth 8) + "`r`n")
  $staleTargetRejected = $false
  try {
    $null = Read-DreamSkinPipeStatus -Path $state.statusPath -SessionId $state.sessionId `
      -HostPid $state.injectorPid -CodexPid $state.codexPid
  } catch {
    $staleTargetRejected = $true
  }
  if (-not $staleTargetRejected) { throw 'A fresh heartbeat accepted stale target verification.' }
  $statusValue.targets[0].lastVerifiedAt = [DateTimeOffset]::UtcNow.ToString('o')

  $statusValue.updatedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
  Write-DreamSkinUtf8FileAtomically -Path $state.statusPath `
    -Content (($statusValue | ConvertTo-Json -Depth 8) + "`r`n")
  $staleStatusRejected = $false
  try {
    $null = Read-DreamSkinPipeStatus -Path $state.statusPath -SessionId $state.sessionId `
      -HostPid $state.injectorPid -CodexPid $state.codexPid
  } catch {
    $staleStatusRejected = $true
  }
  if (-not $staleStatusRejected) { throw 'A stale private-pipe heartbeat was accepted.' }

  $missingIdentityState = [pscustomobject]@{ schemaVersion = 4; platform = 'windows'; transport = 'pipe' }
  Write-DreamSkinState -Path $statePath -State $missingIdentityState
  $missingIdentityRejected = $false
  try { $null = Read-DreamSkinState -Path $statePath } catch { $missingIdentityRejected = $true }
  if (-not $missingIdentityRejected) { throw 'Schema 4 accepted state missing private-pipe identity.' }

  $legacySchema3 = [pscustomobject]@{
    schemaVersion = 3
    platform = 'windows'
    port = 9335
    injectorPid = 1234
    injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
    injectorPath = 'C:\Dream Skin\injector.mjs'
    nodePath = 'C:\Program Files\nodejs\node.exe'
    codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex\app\ChatGPT.exe'
    codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex'
    codexPackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
    codexPackageFamilyName = 'OpenAI.Codex_test'
    browserId = 'browser-123'
  }
  Write-DreamSkinState -Path $statePath -State $legacySchema3
  if ((Read-DreamSkinState -Path $statePath).schemaVersion -ne 3) {
    throw 'A supported legacy schema 3 state was rejected.'
  }
  $legacyState = [pscustomobject]@{ schemaVersion = 2; platform = 'windows'; port = 9335; injectorPid = 1234 }
  Write-DreamSkinState -Path $statePath -State $legacyState
  if ((Read-DreamSkinState -Path $statePath).schemaVersion -ne 2) {
    throw 'A supported schema 2 state was rejected.'
  }

  $fakePackageRoot = Join-Path $temporaryRoot 'OpenAI.Codex_1.2.3.4_x64__test'
  $fakeExecutable = Join-Path $fakePackageRoot 'app\ChatGPT.exe'
  New-Item -ItemType Directory -Path (Split-Path -Parent $fakeExecutable) -Force | Out-Null
  [System.IO.File]::WriteAllBytes($fakeExecutable, [byte[]]@())
  $fakePackage = [pscustomobject]@{
    Name = 'OpenAI.Codex'
    InstallLocation = $fakePackageRoot
    PackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
    PackageFamilyName = 'OpenAI.Codex_test'
    SignatureKind = 'Store'
    IsDevelopmentMode = $false
    Version = [version]'1.2.3.4'
  }
  $fakeInstall = ConvertTo-DreamSkinCodexInstall -Package $fakePackage
  if ($null -eq $fakeInstall -or $fakeInstall.PackageFullName -cne $fakePackage.PackageFullName -or
    -not (Test-DreamSkinPathEqual -Left $fakeInstall.Executable -Right $fakeExecutable)) {
    throw 'Registered Appx package identity conversion failed.'
  }
  $fakePackage.SignatureKind = 'Developer'
  if ($null -ne (ConvertTo-DreamSkinCodexInstall -Package $fakePackage)) {
    throw 'A non-Store Appx package was accepted as official Codex.'
  }
  $fakePackage.SignatureKind = 'Store'
  $pathOnlyState = [pscustomobject]@{
    codexExe = $fakeExecutable
    codexPackageRoot = $fakePackageRoot
    codexVersion = '1.2.3.4'
  }
  if ($null -eq (Get-DreamSkinCodexStatePathCandidate -State $pathOnlyState)) {
    throw 'A structurally valid legacy Codex path was not recognized for read-only activity checks.'
  }
  if ($null -eq (Resolve-DreamSkinCodexInstallFromState -State $pathOnlyState `
    -RegisteredInstalls @($fakeInstall))) {
    throw 'A legacy state path was not revalidated against a registered Store package.'
  }
  $verifiedPackageState = [pscustomobject]@{
    codexExe = $fakeExecutable
    codexPackageRoot = $fakePackageRoot
    codexVersion = '1.2.3.4'
    codexPackageFullName = $fakePackage.PackageFullName
    codexPackageFamilyName = $fakePackage.PackageFamilyName
  }
  $resolvedInstall = Resolve-DreamSkinCodexInstallFromState -State $verifiedPackageState `
    -RegisteredInstalls @($fakeInstall)
  if ($null -eq $resolvedInstall -or -not $resolvedInstall.RegisteredPackageVerified) {
    throw 'State package identity did not resolve against the registered Appx package.'
  }
  $verifiedPackageState.codexPackageFamilyName = 'OpenAI.Codex_wrong'
  if ($null -ne (Resolve-DreamSkinCodexInstallFromState -State $verifiedPackageState `
    -RegisteredInstalls @($fakeInstall))) {
    throw 'A mismatched Appx package family was accepted from state.'
  }
  Write-DreamSkinUtf8FileAtomically -Path $statePath -Content '[]'
  $badStateRejected = $false
  try { $null = Read-DreamSkinState -Path $statePath } catch { $badStateRejected = $true }
  if (-not $badStateRejected) { throw 'A non-object state file was accepted.' }
  $staleStatePath = Archive-DreamSkinStateFile -Path $statePath
  if ((Test-Path -LiteralPath $statePath) -or -not (Test-Path -LiteralPath $staleStatePath)) {
    throw 'Stale state was not preserved under an archive name.'
  }

  $hadNodeOptions = Test-Path Env:NODE_OPTIONS
  $savedNodeOptions = $env:NODE_OPTIONS
  $hadOpenSslConfig = Test-Path Env:OPENSSL_CONF
  $savedOpenSslConfig = $env:OPENSSL_CONF
  try {
    $env:NODE_OPTIONS = '--definitely-not-a-valid-node-option'
    $env:OPENSSL_CONF = 'C:\definitely-not-a-real-openssl-config.cnf'
    $node = Get-DreamSkinNodeRuntime
  } finally {
    if ($hadNodeOptions) { $env:NODE_OPTIONS = $savedNodeOptions }
    else { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
    if ($hadOpenSslConfig) { $env:OPENSSL_CONF = $savedOpenSslConfig }
    else { Remove-Item Env:OPENSSL_CONF -ErrorAction SilentlyContinue }
  }
  if ([System.IO.Path]::GetExtension($node.Path) -ine '.exe' -or
    -not (Test-Path -LiteralPath $node.Path -PathType Leaf)) {
    throw 'Node runtime discovery did not return a real Windows executable.'
  }
  $windowsPowerShell = Get-DreamSkinWindowsPowerShellPath
  if ([System.IO.Path]::GetFileName($windowsPowerShell) -ine 'powershell.exe' -or
    -not [System.IO.Path]::IsPathRooted($windowsPowerShell) -or
    -not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw 'Windows PowerShell discovery did not return a trusted executable path.'
  }

  $powerShellSources = @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -File -Recurse)
  foreach ($powerShellSource in $powerShellSources) {
    $parseTokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
      $powerShellSource.FullName,
      [ref]$parseTokens,
      [ref]$parseErrors
    )
    if (@($parseErrors).Count -gt 0) {
      $parseDetails = @($parseErrors | ForEach-Object {
        "line $($_.Extent.StartLineNumber): $($_.Message)"
      }) -join '; '
      throw "PowerShell parser errors in $($powerShellSource.FullName): $parseDetails"
    }
  }

  $activeSources = @(
    (Join-Path $Root 'scripts\common-windows.ps1'),
    (Join-Path $Root 'scripts\start-dream-skin.ps1'),
    (Join-Path $Root 'scripts\install-dream-skin.ps1'),
    (Join-Path $Root 'scripts\verify-dream-skin.ps1'),
    (Join-Path $Root 'scripts\restore-dream-skin.ps1'),
    (Join-Path $Root 'scripts\injector.mjs'),
    (Join-Path $Root 'scripts\pipe-transport.mjs')
  )
  foreach ($sourcePath in $activeSources) {
    $sourceText = Read-DreamSkinUtf8File -Path $sourcePath
    foreach ($forbidden in @('--remote-debugging-port', '--remote-debugging-address', 'WebSocket', 'Invoke-RestMethod')) {
      if ($sourceText.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Active private-pipe source contains forbidden network debugging token '$forbidden': $sourcePath"
      }
    }
  }
  $startSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\start-dream-skin.ps1')
  foreach ($requiredToken in @('schemaVersion = 4', "transport = 'pipe'", '--handshake', '--status', '--session-id')) {
    if (-not $startSource.Contains($requiredToken)) { throw "Secure start path is missing: $requiredToken" }
  }

  & $node.Path (Join-Path $Root 'scripts\injector.mjs') --self-test *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Injector CDP self-test failed.' }
  & $node.Path (Join-Path $Root 'scripts\injector.mjs') --check-payload *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Injector self-test failed.' }
  & $node.Path (Join-Path $PSScriptRoot 'renderer-inject.test.mjs')
  if ($LASTEXITCODE -ne 0) { throw 'Renderer auxiliary-window regression test failed.' }
  & $node.Path (Join-Path $PSScriptRoot 'pipe-transport.test.mjs')
  if ($LASTEXITCODE -ne 0) { throw 'Private-pipe transport regression test failed.' }

  Write-Host 'PASS: config transactions, restore scoping, schema 4 state safety, and private-pipe validation.'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
