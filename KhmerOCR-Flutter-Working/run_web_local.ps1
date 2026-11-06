$ErrorActionPreference = 'Stop'

$apiBaseUrl = 'http://127.0.0.1:3000'
$apiDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'auth-api'
$apiEnvFile = Join-Path $apiDir '.env.local'
$flutterEnvFile = Join-Path $PSScriptRoot '.env.local'
$modalClientEnvFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env.modal-client'
$serverProcess = $null
$serverStarted = $false
$flutterExitCode = 0
$serverStartupMessage = 'Local auth API listening at http://127.0.0.1:3000'

function Test-TcpListener {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync($Address, $Port)
        if (-not $connect.Wait(300)) { return $false }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Stop-OwnedAuthServer {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) { return }

    try {
        $hasExited = $true
        try { $hasExited = $Process.HasExited }
        catch { return }

        if (-not $hasExited) {
            $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (-not (Test-Path -LiteralPath $taskkill)) {
                Write-Warning "Could not find taskkill.exe to stop the local auth server (PID $($Process.Id)). Stop that process manually."
                return
            }

            # This PID is the cmd.exe process created below; /T limits cleanup to
            # its process tree, which contains only this launch's npm/server.
            $null = & $taskkill /PID $Process.Id /T /F 2>$null
            $Process.WaitForExit(5000) | Out-Null
            if (-not $Process.HasExited) {
                Write-Warning "Could not stop the local auth server process tree (PID $($Process.Id))."
            }
        }
    }
    catch {
        Write-Warning "Could not stop the local auth server process tree (PID $($Process.Id)): $($_.Exception.Message)"
    }
    finally {
        $Process.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $flutterEnvFile)) {
    throw "Missing $flutterEnvFile. Add the Firebase web client settings for this Flutter app, then rerun this launcher."
}
if (-not (Test-Path -LiteralPath $apiDir -PathType Container)) {
    throw "Missing auth-api folder: $apiDir"
}
if (-not (Test-Path -LiteralPath $apiEnvFile)) {
    throw "Missing $apiEnvFile. Configure the local auth API environment before launching."
}
if (-not (Test-Path -LiteralPath (Join-Path $apiDir 'node_modules') -PathType Container)) {
    throw "The auth API dependencies are missing. Install them in $apiDir before launching."
}

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCommand) {
    throw 'Node.js 20 or newer is required. Install Node.js (including npm) and reopen PowerShell.'
}
$nodeVersionText = (& node --version 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($nodeVersionText)) {
    throw 'Could not read the installed Node.js version. Repair the Node.js installation and retry.'
}
try {
    $nodeVersion = [Version](($nodeVersionText -replace '^v', '').Split('-')[0])
}
catch {
    throw "Could not parse the installed Node.js version '$nodeVersionText'. Install Node.js 20 or newer."
}
if ($nodeVersion.Major -lt 20) {
    throw "Node.js 20 or newer is required; found $nodeVersionText."
}
if ($null -eq (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    throw 'npm was not found. Install Node.js with npm and reopen PowerShell.'
}
if ($null -eq (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter was not found on PATH. Install Flutter or add its bin folder to PATH, then reopen PowerShell.'
}

$apiPackageFile = Join-Path $apiDir 'package.json'
if (-not (Test-Path -LiteralPath $apiPackageFile)) {
    throw "Missing auth API package file: $apiPackageFile"
}
$apiPackage = Get-Content -LiteralPath $apiPackageFile -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($apiPackage.scripts.local)) {
    throw "The auth API has no 'local' npm script yet. Update auth-api/package.json and retry."
}

$defineNames = @(
    'FIREBASE_API_KEY',
    'FIREBASE_PROJECT_ID',
    'FIREBASE_MESSAGING_SENDER_ID',
    'FIREBASE_WEB_APP_ID',
    'FIREBASE_AUTH_DOMAIN',
    'FIREBASE_STORAGE_BUCKET'
)
$firebaseConfig = @{}
foreach ($line in Get-Content -LiteralPath $flutterEnvFile) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { continue }

    $name = $parts[0].Trim()
    if ($defineNames -notcontains $name) { continue }

    $value = $parts[1].Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    $firebaseConfig[$name] = $value
}
$missing = @($defineNames | Where-Object { [string]::IsNullOrWhiteSpace($firebaseConfig[$_]) })
if ($missing.Count -gt 0) {
    throw "Missing Firebase web client settings in .env.local: $($missing -join ', ')"
}

$ocrApiKey = $null
if (Test-Path -LiteralPath $modalClientEnvFile) {
    foreach ($line in Get-Content -LiteralPath $modalClientEnvFile) {
        if ($line -notmatch '^\s*OCR_API_KEY\s*=') { continue }
        $ocrApiKey = ($line -split '=', 2)[1].Trim()
        if ($ocrApiKey.Length -ge 2 -and $ocrApiKey.StartsWith('"') -and $ocrApiKey.EndsWith('"')) {
            $ocrApiKey = $ocrApiKey.Substring(1, $ocrApiKey.Length - 2)
        }
        break
    }
}
if ([string]::IsNullOrWhiteSpace($ocrApiKey)) {
    Write-Warning 'The Modal OCR key is missing from .env.modal-client. Sign-in can work, but the Modal OCR service may reject requests.'
}

if (Test-TcpListener -Address '127.0.0.1' -Port 3000) {
    throw 'Port 3000 on 127.0.0.1 is already in use. Stop the service you started and rerun this launcher. This launcher will not stop existing processes.'
}

Write-Host 'Starting the local auth API and Flutter Chrome app...'
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $env:ComSpec
$startInfo.Arguments = '/d /s /c "set NODE_ENV=development&& set LOCAL_ADMIN_OTP_BYPASS=1&& set LOCAL_AUTH_API_PORT=3000&& npm run local"'
$startInfo.WorkingDirectory = $apiDir
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
# Keep server output away from the console so local environment values cannot
# be accidentally exposed by startup diagnostics.
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

try {
    $serverProcess = New-Object System.Diagnostics.Process
    $serverProcess.StartInfo = $startInfo
    if (-not $serverProcess.Start()) {
        $serverProcess.Dispose()
        $serverProcess = $null
        throw 'Could not start the local auth API process.'
    }
    $serverStarted = $true
    $serverProcess.BeginErrorReadLine()
    $stdoutLineTask = $serverProcess.StandardOutput.ReadLineAsync()
    $stdoutClosed = $false

    $serverAnnouncedListening = $false
    $serverReady = $false
    $startupDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $startupDeadline) {
        if ($serverProcess.HasExited) {
            throw 'The local auth API exited before announcing readiness on 127.0.0.1:3000. Check auth-api/.env.local. To inspect startup diagnostics, run npm run local from auth-api in a separate PowerShell window and keep its output private.'
        }

        if (-not $stdoutClosed -and $stdoutLineTask.IsCompleted) {
            $outputLine = $stdoutLineTask.Result
            if ($null -eq $outputLine) {
                $stdoutClosed = $true
            }
            else {
                if ($outputLine -ceq $serverStartupMessage) {
                    $serverAnnouncedListening = $true
                }
                $stdoutLineTask = $serverProcess.StandardOutput.ReadLineAsync()
            }
        }

        if ($serverAnnouncedListening -and (Test-TcpListener -Address '127.0.0.1' -Port 3000)) {
            if ($serverProcess.HasExited) {
                throw 'The local auth API exited just after announcing readiness. Check auth-api/.env.local and its local npm script.'
            }
            $serverReady = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $serverReady) {
        throw 'The local auth API did not announce that it was listening on 127.0.0.1:3000 within 20 seconds. Check auth-api/.env.local and its local npm script.'
    }

    # Modal permits this fixed local web origin. The API key is embedded in
    # this development build, so it must not be used for a public release.
    $flutterArgs = @('run', '-d', 'chrome', '--web-hostname=localhost', '--web-port=8080')
    foreach ($name in $defineNames) {
        $flutterArgs += "--dart-define=$name=$($firebaseConfig[$name])"
    }
    $flutterArgs += "--dart-define=AUTH_API_BASE_URL=$apiBaseUrl"
    if (-not [string]::IsNullOrWhiteSpace($ocrApiKey)) {
        $flutterArgs += "--dart-define=OCR_API_KEY=$ocrApiKey"
    }

    Push-Location $PSScriptRoot
    try {
        & flutter @flutterArgs
        $flutterExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($serverStarted) {
        Stop-OwnedAuthServer -Process $serverProcess
    }
    elseif ($null -ne $serverProcess) {
        $serverProcess.Dispose()
    }
}

exit $flutterExitCode
