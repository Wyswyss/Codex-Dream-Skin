. (Join-Path $PSScriptRoot 'config-utf8.ps1')

function Enter-DreamSkinOperationLock {
  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  [System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
  $lockPath = Join-Path $stateRoot 'operation.lock'
  try {
    return [System.IO.File]::Open(
      $lockPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    throw 'Another Codex Dream Skin install, start, restore, or verify operation is already running.'
  }
}

function Exit-DreamSkinOperationLock {
  param([Parameter(Mandatory = $true)][System.IO.FileStream]$Mutex)
  $Mutex.Dispose()
}

function Assert-DreamSkinPort {
  param([Parameter(Mandatory = $true)][int]$Port)
  if ($Port -lt 1024 -or $Port -gt 65535) { throw "Port must be between 1024 and 65535: $Port" }
}

function Test-DreamSkinPathEqual {
  param([string]$Left, [string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    return ([System.IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($Right).TrimEnd('\'))
  } catch {
    return $false
  }
}

function Test-DreamSkinPathWithin {
  param([string]$Path, [string]$Root)
  if (-not $Path -or -not $Root) { return $false }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Test-DreamSkinCommandLineToken {
  param([string]$CommandLine, [string]$Token)
  if (-not $CommandLine -or -not $Token) { return $false }
  $pattern = '(?i)(?:^|[\s"])' + [regex]::Escape($Token) + '(?=$|[\s"])'
  return [regex]::IsMatch($CommandLine, $pattern)
}

function ConvertTo-DreamSkinProcessArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  if ($Value.Contains('"')) { throw 'Process arguments containing a double quote are not supported.' }
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '\s') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function Get-DreamSkinProcessExecutablePath {
  param([Parameter(Mandatory = $true)][object]$ProcessInfo)
  if ($ProcessInfo.ExecutablePath) { return "$($ProcessInfo.ExecutablePath)" }
  try {
    $process = Get-Process -Id ([int]$ProcessInfo.ProcessId) -ErrorAction Stop
    if ($process.Path) { return "$($process.Path)" }
    return "$($process.MainModule.FileName)"
  } catch {
    return $null
  }
}

function Remove-DreamSkinUnsafeEnvironmentVariables {
  param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo)
  $unsafeExact = @('ALL_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'SSL_CERT_DIR', 'SSL_CERT_FILE')
  $unsafePrefixes = @('CHROME_', 'DYLD_', 'ELECTRON_', 'LD_', 'NODE_', 'OPENSSL_')
  foreach ($key in @($StartInfo.EnvironmentVariables.Keys)) {
    $upperKey = "$key".ToUpperInvariant()
    $unsafe = $upperKey -in $unsafeExact
    if (-not $unsafe) {
      foreach ($prefix in $unsafePrefixes) {
        if ($upperKey.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
          $unsafe = $true
          break
        }
      }
    }
    if ($unsafe) {
      $StartInfo.EnvironmentVariables.Remove("$key")
    }
  }
}

function Invoke-DreamSkinNodeExpression {
  param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [Parameter(Mandatory = $true)][ValidateSet('process.versions.node', 'process.execPath')][string]$Expression
  )
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $NodePath
  $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($NodePath))
  $startInfo.Arguments = "-p $Expression"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  Remove-DreamSkinUnsafeEnvironmentVariables -StartInfo $startInfo

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw 'Node.js could not be started for validation.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) {
      try { $process.Kill() } catch {}
      try { [void]$process.WaitForExit(5000) } catch {}
      throw 'The Node.js runtime validation timed out after 10 seconds.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $null = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or -not $stdout) { throw 'The Node.js runtime could not be validated.' }
    return "$stdout".Trim()
  } finally {
    $process.Dispose()
  }
}

function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22)

  $command = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue
  if (-not $command) { $command = Get-Command node -CommandType Application -ErrorAction SilentlyContinue }
  if (-not $command) { throw "Node.js $MinimumMajor or newer is required and was not found in PATH." }
  $commandPath = if ($command.Path) { "$($command.Path)" } else { "$($command.Source)" }
  if (-not [System.IO.Path]::IsPathRooted($commandPath) -or
    [System.IO.Path]::GetExtension($commandPath) -ine '.exe' -or
    -not (Test-Path -LiteralPath $commandPath -PathType Leaf)) {
    $commandType = $command.GetType().FullName
    $commandCount = @($command).Count
    $pathBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($commandPath))
    $sourceBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($command.Source)"))
    $isRooted = [System.IO.Path]::IsPathRooted($commandPath)
    $extension = [System.IO.Path]::GetExtension($commandPath)
    $exists = Test-Path -LiteralPath $commandPath -PathType Leaf
    throw "The Node.js command in PATH is not a real Windows executable. Type=$commandType Count=$commandCount PathBase64=$pathBase64 SourceBase64=$sourceBase64 Rooted=$isRooted Extension=$extension Exists=$exists"
  }
  $version = Invoke-DreamSkinNodeExpression -NodePath $commandPath -Expression 'process.versions.node'
  $runtimePath = Invoke-DreamSkinNodeExpression -NodePath $commandPath -Expression 'process.execPath'
  if (-not $runtimePath -or -not [System.IO.Path]::IsPathRooted($runtimePath) -or
    [System.IO.Path]::GetExtension($runtimePath) -ine '.exe' -or
    -not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
    throw 'The Node.js executable path could not be validated.'
  }
  $major = 0
  if (-not [int]::TryParse(($version -split '\.')[0], [ref]$major) -or $major -lt $MinimumMajor) {
    throw "Node.js $MinimumMajor or newer is required; found $version at $runtimePath."
  }
  return [pscustomobject]@{ Path = $runtimePath; Version = $version; Major = $major }
}

function Start-DreamSkinNormalCodex {
  param([Parameter(Mandatory = $true)][object]$Codex)
  if (-not $Codex.Executable -or -not (Test-Path -LiteralPath "$($Codex.Executable)")) {
    throw 'The official Codex executable is unavailable.'
  }
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = "$($Codex.Executable)"
  $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName(
    [System.IO.Path]::GetFullPath("$($Codex.Executable)")
  )
  $startInfo.UseShellExecute = $false
  Remove-DreamSkinUnsafeEnvironmentVariables -StartInfo $startInfo
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'The official Codex app could not be started.' }
  return $process
}

function ConvertTo-DreamSkinCodexInstall {
  param([Parameter(Mandatory = $true)][object]$Package)
  if ("$($Package.Name)" -ine 'OpenAI.Codex' -or -not $Package.InstallLocation -or
    -not $Package.PackageFullName -or -not $Package.PackageFamilyName -or
    "$($Package.SignatureKind)" -ine 'Store' -or [bool]$Package.IsDevelopmentMode) {
    return $null
  }
  $packageRoot = "$($Package.InstallLocation)"
  $executable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $executable)) { return $null }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($Package.Version)"
    PackageFullName = "$($Package.PackageFullName)"
    PackageFamilyName = "$($Package.PackageFamilyName)"
    SignatureKind = "$($Package.SignatureKind)"
  }
}

function Get-DreamSkinRegisteredCodexInstalls {
  $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Sort-Object Version -Descending)
  $installs = @()
  foreach ($package in $packages) {
    $install = ConvertTo-DreamSkinCodexInstall -Package $package
    if ($null -ne $install) { $installs += $install }
  }
  return $installs
}

function Get-DreamSkinCodexInstall {
  $installs = @(Get-DreamSkinRegisteredCodexInstalls)
  if ($installs.Count -eq 0) { throw 'The official OpenAI.Codex Store package is not installed or its identity cannot be validated.' }
  return $installs[0]
}

function Get-DreamSkinCodexStatePathCandidate {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.codexExe -or -not $State.codexPackageRoot) { return $null }
  $executable = "$($State.codexExe)"
  $packageRoot = "$($State.codexPackageRoot)"
  $expectedExecutable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-DreamSkinPathEqual -Left $executable -Right $expectedExecutable)) { return $null }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($State.codexVersion)"
    FromState = $true
    RegisteredPackageVerified = $false
  }
}

function Resolve-DreamSkinCodexInstallFromState {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$RegisteredInstalls
  )
  $candidate = Get-DreamSkinCodexStatePathCandidate -State $State
  if ($null -eq $candidate) { return $null }

  $hasFullName = [bool]$State.codexPackageFullName
  $hasFamilyName = [bool]$State.codexPackageFamilyName
  if ($hasFullName -xor $hasFamilyName) { return $null }
  foreach ($install in $RegisteredInstalls) {
    $pathMatches = (Test-DreamSkinPathEqual -Left $candidate.PackageRoot -Right $install.PackageRoot) -and
      (Test-DreamSkinPathEqual -Left $candidate.Executable -Right $install.Executable)
    if (-not $pathMatches) { continue }
    if ($hasFullName -and ("$($State.codexPackageFullName)" -ine $install.PackageFullName -or
      "$($State.codexPackageFamilyName)" -ine $install.PackageFamilyName)) {
      continue
    }
    return [pscustomobject]@{
      PackageRoot = $install.PackageRoot
      Executable = $install.Executable
      Version = $install.Version
      PackageFullName = $install.PackageFullName
      PackageFamilyName = $install.PackageFamilyName
      SignatureKind = $install.SignatureKind
      FromState = $true
      RegisteredPackageVerified = $true
    }
  }
  return $null
}

function Get-DreamSkinCodexInstallFromState {
  param([AllowNull()][object]$State)
  try { $installs = @(Get-DreamSkinRegisteredCodexInstalls) } catch { return $null }
  return Resolve-DreamSkinCodexInstallFromState -State $State -RegisteredInstalls $installs
}

function Test-DreamSkinBrowserId {
  param([string]$Value)
  return [bool]($Value -and $Value.Length -le 200 -and $Value -cmatch '^[A-Za-z0-9._-]+$')
}

function Test-DreamSkinSessionId {
  param([string]$Value)
  return [bool]($Value -and $Value -cmatch '^[a-f0-9]{32}$')
}

function Test-DreamSkinCommandLineOptionValue {
  param(
    [string]$CommandLine,
    [Parameter(Mandatory = $true)][string]$Option,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )
  if (-not $CommandLine -or $Option -notmatch '^--[a-z0-9-]+$' -or $Value.Contains('"')) { return $false }
  $escapedValue = [regex]::Escape($Value)
  $argumentPattern = '"' + $escapedValue + '"'
  if ($Value.Length -gt 0 -and $Value -notmatch '\s') {
    $argumentPattern = '(?:' + $argumentPattern + '|' + $escapedValue + ')'
  }
  $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Option) +
    '(?:=' + $argumentPattern + '|\s+' + $argumentPattern + ')(?=$|\s)'
  return [regex]::IsMatch($CommandLine, $pattern)
}

function ConvertFrom-DreamSkinTimestamp {
  param([AllowNull()][object]$Value)
  if ($Value -isnot [string] -or -not $Value) { return $null }
  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse(
    $Value,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal,
    [ref]$parsed
  )) { return $null }
  return $parsed.ToUniversalTime()
}

function Test-DreamSkinJsonObjectValue {
  param([AllowNull()][object]$Value)
  return [bool]($null -ne $Value -and
    $Value.GetType().FullName -ceq 'System.Management.Automation.PSCustomObject')
}

function Test-DreamSkinFiniteNumber {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $false }
  $typeCode = [System.Type]::GetTypeCode($Value.GetType())
  if ($typeCode -notin @(
    [System.TypeCode]::Byte, [System.TypeCode]::SByte,
    [System.TypeCode]::Int16, [System.TypeCode]::UInt16,
    [System.TypeCode]::Int32, [System.TypeCode]::UInt32,
    [System.TypeCode]::Int64, [System.TypeCode]::UInt64,
    [System.TypeCode]::Single, [System.TypeCode]::Double, [System.TypeCode]::Decimal
  )) { return $false }
  try {
    $number = [double]$Value
    return [bool](-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number))
  } catch {
    return $false
  }
}

function Test-DreamSkinPositiveInt32Value {
  param([AllowNull()][object]$Value)
  if (-not (Test-DreamSkinFiniteNumber -Value $Value)) { return $false }
  try {
    $number = [double]$Value
    return [bool]($number -ge 1 -and $number -le [int]::MaxValue -and
      [Math]::Truncate($number) -eq $number)
  } catch {
    return $false
  }
}

function Test-DreamSkinRendererBox {
  param([AllowNull()][object]$Value)
  if (-not (Test-DreamSkinJsonObjectValue -Value $Value)) { return $false }
  $properties = @($Value.PSObject.Properties.Name)
  foreach ($field in @('x', 'y', 'width', 'height')) {
    if ($properties -notcontains $field -or -not (Test-DreamSkinFiniteNumber -Value $Value.$field)) {
      return $false
    }
  }
  return [bool]([double]$Value.width -gt 0 -and [double]$Value.height -gt 0)
}

function Test-DreamSkinPipeStatusTarget {
  param(
    [AllowNull()][object]$Target,
    [Parameter(Mandatory = $true)][string]$StatusVersion,
    [int]$MaximumAgeSeconds = 15,
    [switch]$RequirePassing
  )
  if (-not (Test-DreamSkinJsonObjectValue -Value $Target)) { return $false }
  $targetProperties = @($Target.PSObject.Properties.Name)
  foreach ($required in @(
    'targetId', 'markers', 'result', 'lastVerifiedAt', 'appProtocol', 'appIdentity'
  )) {
    if ($targetProperties -notcontains $required) { return $false }
  }
  if ($Target.targetId -isnot [string] -or
    -not (Test-DreamSkinBrowserId -Value $Target.targetId) -or
    -not (Test-DreamSkinJsonObjectValue -Value $Target.markers) -or
    -not (Test-DreamSkinJsonObjectValue -Value $Target.result) -or
    $Target.lastVerifiedAt -isnot [string] -or
    $Target.appProtocol -isnot [string] -or $Target.appProtocol -cne 'app:' -or
    $Target.appIdentity -isnot [bool]) {
    return $false
  }
  $lastVerifiedAt = ConvertFrom-DreamSkinTimestamp -Value $Target.lastVerifiedAt
  if ($null -eq $lastVerifiedAt) { return $false }
  $verificationAge = [DateTimeOffset]::UtcNow - $lastVerifiedAt
  if ($verificationAge.TotalSeconds -gt $MaximumAgeSeconds -or $verificationAge.TotalSeconds -lt -5) {
    return $false
  }

  $result = $Target.result
  $resultProperties = @($result.PSObject.Properties.Name)
  foreach ($required in @(
    'pass', 'installed', 'version', 'expectedVersion', 'stylePresent', 'chromePresent',
    'chromePointerEvents', 'composer', 'sidebar'
  )) {
    if ($resultProperties -notcontains $required) { return $false }
  }
  if ($result.pass -isnot [bool] -or $result.installed -isnot [bool] -or
    $result.version -isnot [string] -or $result.expectedVersion -isnot [string] -or
    $result.stylePresent -isnot [bool] -or $result.chromePresent -isnot [bool] -or
    $result.chromePointerEvents -isnot [string] -or
    -not (Test-DreamSkinRendererBox -Value $result.composer) -or
    -not (Test-DreamSkinRendererBox -Value $result.sidebar)) {
    return $false
  }
  if ($RequirePassing -and (-not [bool]$Target.appIdentity -or -not [bool]$result.pass -or
    -not [bool]$result.installed -or $result.version -cne $StatusVersion -or
    $result.expectedVersion -cne $StatusVersion -or -not [bool]$result.stylePresent -or
    -not [bool]$result.chromePresent -or $result.chromePointerEvents -cne 'none')) {
    return $false
  }
  return $true
}

function Read-DreamSkinJsonObject {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Description)
  try {
    $content = Read-DreamSkinUtf8File -Path $Path
    if (-not $content.TrimStart().StartsWith('{')) { throw "$Description root must be an object." }
    $value = $content | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-DreamSkinJsonObjectValue -Value $value)) {
      throw "$Description root must be an object."
    }
    return $value
  } catch {
    throw "$Description is unreadable or invalid; it was preserved for inspection: $Path"
  }
}

function Read-DreamSkinState {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $content = Read-DreamSkinUtf8File -Path $Path
    if (-not $content.TrimStart().StartsWith('{')) { throw 'State root must be an object.' }
    $state = $content | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-DreamSkinJsonObjectValue -Value $state)) { throw 'State root must be an object.' }
    $properties = @($state.PSObject.Properties.Name)
    if ($properties -contains 'platform' -and "$($state.platform)" -ine 'windows') {
      throw 'State platform is not Windows.'
    }
    $schemaVersion = 1
    if ($properties -contains 'schemaVersion') {
      $schemaVersion = 0
      if (-not [int]::TryParse("$($state.schemaVersion)", [ref]$schemaVersion) -or
        $schemaVersion -lt 1 -or $schemaVersion -gt 4) {
        throw 'State schema is not supported.'
      }
    }
    if ($schemaVersion -eq 3) {
      foreach ($required in @(
        'platform', 'port', 'injectorPid', 'injectorStartedAt', 'injectorPath', 'nodePath',
        'codexExe', 'codexPackageRoot', 'codexPackageFullName', 'codexPackageFamilyName', 'browserId'
      )) {
        if ($properties -notcontains $required -or -not $state.$required) {
          throw "State schema 3 is missing required field: $required"
        }
      }
    }
    if ($schemaVersion -eq 4) {
      foreach ($required in @(
        'platform', 'transport', 'sessionId', 'injectorPid', 'injectorStartedAt', 'injectorPath',
        'nodePath', 'nodeVersion', 'codexPid', 'codexStartedAt', 'codexExe', 'codexPackageRoot',
        'codexPackageFullName', 'codexPackageFamilyName', 'codexVersion', 'handshakePath',
        'statusPath', 'createdAt'
      )) {
        if ($properties -notcontains $required -or $null -eq $state.$required -or "$($state.$required)" -eq '') {
          throw "State schema 4 is missing required field: $required"
        }
      }
      if ("$($state.transport)" -cne 'pipe') { throw 'State schema 4 transport is not the private pipe.' }
      if (-not (Test-DreamSkinSessionId -Value "$($state.sessionId)")) { throw 'State session ID is invalid.' }
      if ($properties -contains 'port' -or $properties -contains 'browserId') {
        throw 'State schema 4 contains a legacy network debugging field.'
      }
      foreach ($pidField in @('injectorPid', 'codexPid')) {
        $statePid = 0
        if (-not [int]::TryParse("$($state.$pidField)", [ref]$statePid) -or $statePid -le 0) {
          throw "State $pidField is invalid."
        }
      }
      if ([int]$state.injectorPid -eq [int]$state.codexPid) { throw 'State process IDs are inconsistent.' }
      foreach ($timeField in @('injectorStartedAt', 'codexStartedAt', 'createdAt')) {
        if ($null -eq (ConvertFrom-DreamSkinTimestamp -Value $state.$timeField)) {
          throw "State $timeField is invalid."
        }
      }
      foreach ($pathField in @('injectorPath', 'nodePath', 'codexExe', 'codexPackageRoot', 'handshakePath', 'statusPath')) {
        if (-not [System.IO.Path]::IsPathRooted("$($state.$pathField)")) {
          throw "State $pathField is not absolute."
        }
      }
      if ($null -eq (Get-DreamSkinCodexStatePathCandidate -State $state)) {
        throw 'State Codex executable is not the expected app under its package root.'
      }
      $stateDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
      foreach ($fileField in @('handshakePath', 'statusPath')) {
        $filePath = [System.IO.Path]::GetFullPath("$($state.$fileField)")
        if (-not (Test-DreamSkinPathEqual -Left ([System.IO.Path]::GetDirectoryName($filePath)) -Right $stateDirectory)) {
          throw "State $fileField is outside the private state directory."
        }
      }
      if ([System.IO.Path]::GetFileName("$($state.handshakePath)") -cne "handshake-$($state.sessionId).json" -or
        [System.IO.Path]::GetFileName("$($state.statusPath)") -cne "status-$($state.sessionId).json") {
        throw 'State private-pipe files are not bound to the saved session ID.'
      }
    }
    if ($properties -contains 'port') {
      $statePort = 0
      if (-not [int]::TryParse("$($state.port)", [ref]$statePort)) { throw 'State port is invalid.' }
      Assert-DreamSkinPort -Port $statePort
    }
    if ($properties -contains 'injectorPid' -and $null -ne $state.injectorPid) {
      $statePid = 0
      if (-not [int]::TryParse("$($state.injectorPid)", [ref]$statePid) -or $statePid -le 0) {
        throw 'State injector PID is invalid.'
      }
    }
    if ($properties -contains 'browserId' -and $state.browserId -and
      -not (Test-DreamSkinBrowserId -Value "$($state.browserId)")) {
      throw 'State browser ID is invalid.'
    }
    return $state
  } catch {
    throw "Dream Skin state is unreadable; it was preserved for inspection: $Path"
  }
}

function Read-DreamSkinPipeHandshake {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [int]$ExpectedHostPid = 0
  )
  $value = Read-DreamSkinJsonObject -Path $Path -Description 'Dream Skin pipe handshake'
  $properties = @($value.PSObject.Properties.Name)
  foreach ($required in @('schemaVersion', 'transport', 'sessionId', 'hostPid', 'codexPid', 'createdAt')) {
    if ($properties -notcontains $required) { throw "Dream Skin pipe handshake is missing: $required" }
  }
  $handshakeSchemaVersion = 0
  if (-not [int]::TryParse("$($value.schemaVersion)", [ref]$handshakeSchemaVersion) -or
    $handshakeSchemaVersion -ne 1 -or "$($value.transport)" -cne 'pipe' -or
    "$($value.sessionId)" -cne $SessionId -or -not (Test-DreamSkinSessionId -Value $SessionId)) {
    throw 'Dream Skin pipe handshake identity does not match the launch.'
  }
  foreach ($pidField in @('hostPid', 'codexPid')) {
    $parsedPid = 0
    if (-not [int]::TryParse("$($value.$pidField)", [ref]$parsedPid) -or $parsedPid -le 0) {
      throw "Dream Skin pipe handshake $pidField is invalid."
    }
  }
  if ($ExpectedHostPid -gt 0 -and [int]$value.hostPid -ne $ExpectedHostPid) {
    throw 'Dream Skin pipe handshake host PID does not match the launched supervisor.'
  }
  if ([int]$value.hostPid -eq [int]$value.codexPid -or
    $null -eq (ConvertFrom-DreamSkinTimestamp -Value $value.createdAt)) {
    throw 'Dream Skin pipe handshake process identity is invalid.'
  }
  return $value
}

function Read-DreamSkinPipeStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Parameter(Mandatory = $true)][int]$HostPid,
    [Parameter(Mandatory = $true)][int]$CodexPid,
    [int]$MaximumAgeSeconds = 15
  )
  $value = Read-DreamSkinJsonObject -Path $Path -Description 'Dream Skin pipe status'
  $properties = @($value.PSObject.Properties.Name)
  foreach ($required in @(
    'schemaVersion', 'transport', 'sessionId', 'version', 'hostPid', 'codexPid',
    'healthy', 'error', 'targets', 'updatedAt'
  )) {
    if ($properties -notcontains $required) { throw "Dream Skin pipe status is missing: $required" }
  }
  if (-not (Test-DreamSkinPositiveInt32Value -Value $value.schemaVersion) -or
    [int]$value.schemaVersion -ne 1 -or
    -not (Test-DreamSkinPositiveInt32Value -Value $value.hostPid) -or
    -not (Test-DreamSkinPositiveInt32Value -Value $value.codexPid) -or
    $value.transport -isnot [string] -or $value.transport -cne 'pipe' -or
    $value.sessionId -isnot [string] -or $value.sessionId -cne $SessionId -or
    [int]$value.hostPid -ne $HostPid -or [int]$value.codexPid -ne $CodexPid) {
    throw 'Dream Skin pipe status identity does not match the saved session.'
  }
  if ($value.version -isnot [string] -or -not $value.version -or
    $value.healthy -isnot [bool] -or
    ($null -ne $value.error -and $value.error -isnot [string]) -or
    $value.targets -isnot [array] -or $value.updatedAt -isnot [string]) {
    throw 'Dream Skin pipe status has invalid health fields.'
  }
  $updatedAt = ConvertFrom-DreamSkinTimestamp -Value $value.updatedAt
  if ($null -eq $updatedAt) { throw 'Dream Skin pipe status timestamp is invalid.' }
  $age = [DateTimeOffset]::UtcNow - $updatedAt
  if ($age.TotalSeconds -gt $MaximumAgeSeconds -or $age.TotalSeconds -lt -5) {
    throw 'Dream Skin pipe status heartbeat is stale or from the future.'
  }
  foreach ($target in $value.targets) {
    if (-not (Test-DreamSkinPipeStatusTarget -Target $target -StatusVersion $value.version `
      -MaximumAgeSeconds $MaximumAgeSeconds)) {
      throw 'Dream Skin pipe status contains invalid renderer evidence.'
    }
  }
  return $value
}

function Test-DreamSkinPipeStatusHealthy {
  param([AllowNull()][object]$Status)
  if (-not (Test-DreamSkinJsonObjectValue -Value $Status) -or
    $Status.healthy -isnot [bool] -or -not [bool]$Status.healthy -or
    $Status.version -isnot [string] -or -not $Status.version -or
    $Status.targets -isnot [array]) { return $false }
  foreach ($target in $Status.targets) {
    if (Test-DreamSkinPipeStatusTarget -Target $target -StatusVersion $Status.version `
      -MaximumAgeSeconds 15 -RequirePassing) { return $true }
  }
  return $false
}

function Write-DreamSkinState {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$State)
  $json = $State | ConvertTo-Json -Depth 6
  Write-DreamSkinUtf8FileAtomically -Path $Path -Content ($json + "`r`n")
}

function Archive-DreamSkinStateFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $archivePath = Join-Path $directory "state.stale-$stamp-$([guid]::NewGuid().ToString('N')).json"
  Move-Item -LiteralPath $Path -Destination $archivePath -ErrorAction Stop
  return $archivePath
}

function Get-DreamSkinProcessStartedAt {
  param([int]$ProcessId)
  try {
    return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
  } catch {
    return $null
  }
}

function Get-DreamSkinRecordedInjectorProcess {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.injectorPid) { return $null }
  $processId = [int]$State.injectorPid
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
  if (-not $process) { return $null }

  $expectedInjector = if ($State.injectorPath) {
    "$($State.injectorPath)"
  } elseif ($State.skillRoot) {
    Join-Path "$($State.skillRoot)" 'scripts\injector.mjs'
  } else {
    $null
  }
  $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $process
  $commandLine = "$($process.CommandLine)"
  $startedAt = Get-DreamSkinProcessStartedAt -ProcessId $processId
  if (-not $processPath -or -not $commandLine -or -not $startedAt) { return $false }
  $isNodeExecutable = [System.IO.Path]::GetFileName("$processPath") -iin @('node.exe', 'node')
  $matches = [bool]($isNodeExecutable -and $expectedInjector -and
    (-not $State.nodePath -or (Test-DreamSkinPathEqual -Left $processPath -Right "$($State.nodePath)")) -and
    (Test-DreamSkinCommandLineToken -CommandLine $commandLine -Token $expectedInjector) -and
    (Test-DreamSkinCommandLineToken -CommandLine $commandLine -Token '--watch') -and
    (-not $State.injectorStartedAt -or $startedAt -ceq "$($State.injectorStartedAt)"))

  if ([int]$State.schemaVersion -eq 4) {
    $matches = $matches -and "$($State.transport)" -ceq 'pipe' -and
      (Test-DreamSkinCommandLineOptionValue -CommandLine $commandLine -Option '--codex-exe' -Value "$($State.codexExe)") -and
      (Test-DreamSkinCommandLineOptionValue -CommandLine $commandLine -Option '--handshake' -Value "$($State.handshakePath)") -and
      (Test-DreamSkinCommandLineOptionValue -CommandLine $commandLine -Option '--status' -Value "$($State.statusPath)") -and
      (Test-DreamSkinCommandLineOptionValue -CommandLine $commandLine -Option '--session-id' -Value "$($State.sessionId)")
  } else {
    if ($State.port) {
      $portPattern = '(?i)(?:^|\s)--port(?:=|\s+)' + [regex]::Escape("$($State.port)") + '(?=$|\s)'
      $matches = $matches -and [regex]::IsMatch($commandLine, $portPattern)
    } else {
      $matches = $false
    }
    if ($State.browserId) {
      $browserPattern = '(?:^|\s)(?i:--browser-id)(?:=|\s+)' + [regex]::Escape("$($State.browserId)") + '(?=$|\s)'
      $matches = $matches -and [regex]::IsMatch($commandLine, $browserPattern)
    }
  }
  if (-not $matches) { return $false }
  return $process
}

function Get-DreamSkinRecordedCodexProcess {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or [int]$State.schemaVersion -ne 4 -or -not $State.codexPid) { return $null }
  $processId = [int]$State.codexPid
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
  if (-not $process) { return $null }
  $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $process
  $commandLine = "$($process.CommandLine)"
  $startedAt = Get-DreamSkinProcessStartedAt -ProcessId $processId
  if (-not $processPath -or -not $commandLine -or -not $startedAt) { return $false }
  $hasPrivatePipe = [regex]::IsMatch($commandLine, '(?i)(?:^|\s)--remote-debugging-pipe(?=$|\s)')
  $hasNetworkDebugging = [regex]::IsMatch($commandLine, '(?i)(?:^|\s)--remote-debugging-(?:port|address)(?:=|\s|$)')
  if (-not (Test-DreamSkinPathEqual -Left $processPath -Right "$($State.codexExe)") -or
    $startedAt -cne "$($State.codexStartedAt)" -or [int]$process.ParentProcessId -ne [int]$State.injectorPid -or
    -not $hasPrivatePipe -or $hasNetworkDebugging) { return $false }
  return $process
}

function Wait-DreamSkinRecordedCodexExit {
  param([AllowNull()][object]$State, [int]$TimeoutSeconds = 8)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $recorded = Get-DreamSkinRecordedCodexProcess -State $State
    if ($null -eq $recorded) { return $true }
    if ($recorded -is [bool]) { return $false }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Stop-DreamSkinRecordedCodex {
  param([AllowNull()][object]$State)
  $recorded = Get-DreamSkinRecordedCodexProcess -State $State
  if ($null -eq $recorded) { return $true }
  if ($recorded -is [bool]) { throw 'The recorded Codex PID is active but its exact private-pipe identity no longer matches.' }
  Stop-Process -Id ([int]$State.codexPid) -Force -ErrorAction Stop
  try { Wait-Process -Id ([int]$State.codexPid) -Timeout 5 -ErrorAction Stop } catch {}
  return $null -eq (Get-Process -Id ([int]$State.codexPid) -ErrorAction SilentlyContinue)
}

function Stop-DreamSkinRecordedInjector {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.injectorPid) { return $true }
  $processId = [int]$State.injectorPid
  $process = Get-DreamSkinRecordedInjectorProcess -State $State
  if ($null -eq $process) { return $true }
  if ($process -is [bool]) {
    Write-Warning "Skipped stale injector PID $processId because its visible identity does not match the saved Dream Skin process."
    return $false
  }

  Stop-Process -Id $processId -Force -ErrorAction Stop
  try { Wait-Process -Id $processId -Timeout 5 -ErrorAction Stop } catch {}
  if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
    throw "The recorded Dream Skin injector did not stop: PID $processId"
  }
  return $true
}

function Get-DreamSkinCodexProcesses {
  param([Parameter(Mandatory = $true)][object]$Codex)
  return @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $_
      Test-DreamSkinPathEqual -Left $processPath -Right $Codex.Executable
  })
}

function Wait-DreamSkinCodexInstallExit {
  param([Parameter(Mandatory = $true)][object]$Codex, [int]$TimeoutSeconds = 3)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if ((Get-DreamSkinCodexProcesses -Codex $Codex).Count -eq 0) { return $true }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Stop-DreamSkinCodex {
  param([Parameter(Mandatory = $true)][object]$Codex, [switch]$AllowForce)
  $processes = Get-DreamSkinCodexProcesses -Codex $Codex
  if ($processes.Count -eq 0) { return }
  foreach ($item in $processes) {
    try { [void](Get-Process -Id $item.ProcessId -ErrorAction Stop).CloseMainWindow() } catch {}
  }

  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-DreamSkinCodexProcesses -Codex $Codex).Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
  }
  $remaining = Get-DreamSkinCodexProcesses -Codex $Codex
  if ($remaining.Count -eq 0) { return }
  if (-not $AllowForce) {
    throw 'Codex did not close within 15 seconds. Close it manually or explicitly authorize a forced restart.'
  }
  foreach ($item in $remaining) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$item.ProcessId)" -ErrorAction SilentlyContinue
    $currentPath = if ($current) { Get-DreamSkinProcessExecutablePath -ProcessInfo $current } else { $null }
    if ($currentPath -and (Test-DreamSkinPathEqual -Left $currentPath -Right $Codex.Executable)) {
      Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  Start-Sleep -Milliseconds 500
  if ((Get-DreamSkinCodexProcesses -Codex $Codex).Count -gt 0) { throw 'Codex could not be stopped safely.' }
}

function Confirm-DreamSkinRestart {
  param([string]$Message)
  $shell = New-Object -ComObject WScript.Shell
  return $shell.Popup($Message, 0, 'Codex Dream Skin', 308) -eq 6
}
