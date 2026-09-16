$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Targets = @('Start-Auditor.ps1','Scan-Worker.ps1')
$Failed = $false

foreach ($Name in $Targets) {
    $Target = Join-Path $BaseDir $Name
    $Tokens = $null
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Target, [ref]$Tokens, [ref]$Errors)
    if ($null -eq $Errors -or $Errors.Count -eq 0) {
        Write-Host ("SYNTAX OK - " + $Name) -ForegroundColor Green
    } else {
        $Failed = $true
        Write-Host ("SYNTAX ERROR - " + $Name) -ForegroundColor Red
        foreach ($Item in $Errors) {
            Write-Host ('Line {0}, column {1}: {2}' -f $Item.Extent.StartLineNumber, $Item.Extent.StartColumnNumber, $Item.Message) -ForegroundColor Red
        }
    }
}
if ($Failed) { exit 1 }

function Test-PathRootRuntime([string]$Value, [string]$ExpectedKind) {
    try {
        $normalized = $Value.Replace('/', '\').Trim()
        $root = [System.IO.Path]::GetPathRoot($normalized)
        if ([string]::IsNullOrWhiteSpace([string]$root)) { throw 'GetPathRoot returned an empty root' }
        $kind = 'OTHER'
        if ($root.Length -ge 3 -and $root[1] -eq ':' -and $root[2] -eq '\') { $kind = 'LOCAL_DRIVE' }
        elseif ($root.StartsWith('\\')) { $kind = 'UNC' }
        if ($kind -ne $ExpectedKind) { throw ("Expected kind {0}, got {1}, root={2}" -f $ExpectedKind,$kind,$root) }
        Write-Host ("PATH ROOT OK - {0} -> {1} [{2}]" -f $Value,$root,$kind) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ("PATH ROOT ERROR - {0}: {1}" -f $Value,$_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Write-TestAtomicJson([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($json)
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $stream = $null
        try {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, $share)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $stream.Dispose()
            $stream = $null
            return
        } catch {
            if ($null -ne $stream) { try { $stream.Dispose() } catch {}; $stream = $null }
            if ($attempt -ge 12) { throw }
            Start-Sleep -Milliseconds 75
        } finally {
            if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        }
    }
}

$PathTestsOk = $true
$PathTestsOk = (Test-PathRootRuntime 'C:\Windows' 'LOCAL_DRIVE') -and $PathTestsOk
$PathTestsOk = (Test-PathRootRuntime 'G:\1c_web' 'LOCAL_DRIVE') -and $PathTestsOk
$PathTestsOk = (Test-PathRootRuntime 'V:\8.2\buh166' 'LOCAL_DRIVE') -and $PathTestsOk
$PathTestsOk = (Test-PathRootRuntime '\\server\share\base' 'UNC') -and $PathTestsOk
if (-not $PathTestsOk) { exit 2 }
Write-Host 'RUNTIME PATH SELF-TEST PASSED' -ForegroundColor Green

function Get-CanonicalPathKeyForTest([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Replace('/', '\').Trim()
    try { $normalized = [System.IO.Path]::GetFullPath($normalized) } catch {}
    $root = $null
    try { $root = [System.IO.Path]::GetPathRoot($normalized) } catch {}
    if (-not [string]::IsNullOrWhiteSpace([string]$root) -and $normalized.Length -gt $root.Length) {
        $normalized = $normalized.TrimEnd('\')
    }
    return $normalized.ToLowerInvariant()
}

function Test-PathInsideDirectoryRuntime([string]$Path, [string]$Directory, [bool]$Expected) {
    try {
        $pathKey = Get-CanonicalPathKeyForTest $Path
        $dirKey = Get-CanonicalPathKeyForTest $Directory
        $actual = $false
        if (-not [string]::IsNullOrWhiteSpace($pathKey) -and -not [string]::IsNullOrWhiteSpace($dirKey)) {
            $actual = ($pathKey -eq $dirKey) -or $pathKey.StartsWith(($dirKey + '\'), [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ($actual -ne $Expected) { throw ("Expected {0}, got {1}" -f $Expected,$actual) }
        Write-Host ("VRD PATH OK - {0} inside {1} = {2}" -f $Path,$Directory,$actual) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ("VRD PATH ERROR - {0} / {1}: {2}" -f $Path,$Directory,$_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

$VrdPathTestsOk = $true
$VrdPathTestsOk = (Test-PathInsideDirectoryRuntime 'G:\1c_web\buh\default.vrd' 'G:\1c_web\buh' $true) -and $VrdPathTestsOk
$VrdPathTestsOk = (Test-PathInsideDirectoryRuntime 'G:\1c_web\buh\default.vrd' 'G:\1c_web\buh\' $true) -and $VrdPathTestsOk
$VrdPathTestsOk = (Test-PathInsideDirectoryRuntime 'g:\1C_WEB\BUH\DEFAULT.VRD' 'G:\1c_web\buh' $true) -and $VrdPathTestsOk
$VrdPathTestsOk = (Test-PathInsideDirectoryRuntime 'G:/1c_web/buh/default.vrd' 'G:\1c_web\buh' $true) -and $VrdPathTestsOk
$VrdPathTestsOk = (Test-PathInsideDirectoryRuntime 'G:\1c_web\buh\sub\custom.vrd' 'G:\1c_web\buh' $true) -and $VrdPathTestsOk
$VrdPathTestsOk = (Test-PathInsideDirectoryRuntime 'G:\1c_web\buh2\default.vrd' 'G:\1c_web\buh' $false) -and $VrdPathTestsOk
$VrdPathTestsOk = (Test-PathInsideDirectoryRuntime 'G:\other\default.vrd' 'G:\1c_web\buh' $false) -and $VrdPathTestsOk
if (-not $VrdPathTestsOk) { exit 4 }
Write-Host 'VRD DIRECTORY SELF-TEST PASSED' -ForegroundColor Green

$TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ('1c-auditor-v18-' + [Guid]::NewGuid().ToString('N'))
$TestFile = Join-Path $TestDir 'atomic.json'
try {
    New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
    for ($i = 1; $i -le 5; $i++) {
        Write-TestAtomicJson $TestFile ([pscustomobject]@{ iteration=$i; text=('test-' + $i) })
        $obj = [System.IO.File]::ReadAllText($TestFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([int]$obj.iteration -ne $i) { throw ('Shared JSON mismatch at iteration ' + $i) }
    }
    $readerStream = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $readerStream = [System.IO.File]::Open($TestFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        Write-TestAtomicJson $TestFile ([pscustomobject]@{ iteration=6; text='concurrent-reader-test' })
    } finally {
        if ($null -ne $readerStream) { $readerStream.Dispose() }
    }
    $obj = [System.IO.File]::ReadAllText($TestFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$obj.iteration -ne 6) { throw 'Concurrent reader/write JSON mismatch' }
    Write-Host 'SHARED JSON WRITE SELF-TEST PASSED - rewrites + concurrent reader' -ForegroundColor Green
} catch {
    Write-Host ('SHARED JSON WRITE SELF-TEST FAILED - ' + $_.Exception.Message) -ForegroundColor Red
    exit 3
} finally {
    if (Test-Path -LiteralPath $TestDir) { Remove-Item -LiteralPath $TestDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host 'ALL POWERSHELL CHECKS PASSED' -ForegroundColor Green
exit 0
