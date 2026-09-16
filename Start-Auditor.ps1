$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $BaseDir 'config.json'
$WebDir = Join-Path $BaseDir 'web'
$DataDir = Join-Path $BaseDir 'data'
$LogsDir = Join-Path $BaseDir 'logs'
$StatePath = Join-Path $DataDir 'scan-state.json'
$LastScanPath = Join-Path $DataDir 'scan-result.json'
$HistoryPath = Join-Path $DataDir 'history.json'
$LivePath = Join-Path $DataDir 'scan-live.json'
$StopPath = Join-Path $DataDir 'stop.request'
$WorkerPath = Join-Path $BaseDir 'Scan-Worker.ps1'
$LogPath = Join-Path $LogsDir 'scan.log'
$WorkerStdoutPath = Join-Path $LogsDir 'worker-stdout.log'
$WorkerStderrPath = Join-Path $LogsDir 'worker-stderr.log'

foreach ($Dir in @($DataDir,$LogsDir)) { if (-not (Test-Path $Dir -PathType Container)) { New-Item -ItemType Directory -Path $Dir | Out-Null } }
if (-not (Test-Path $ConfigPath -PathType Leaf)) { throw "config.json not found: $ConfigPath" }
$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Read-JsonSafe([string]$Path, $Fallback) {
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            if (-not [System.IO.File]::Exists($Path)) { return $Fallback }
            $stream = $null; $reader = $null
            try {
                $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
                $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,$share)
                $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($stream,[System.Text.Encoding]::UTF8,$true)
                $text = $reader.ReadToEnd()
            } finally { if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() } }
            if ([string]::IsNullOrWhiteSpace($text)) { throw 'JSON file is temporarily empty' }
            return ($text | ConvertFrom-Json)
        } catch { if ($attempt -ge 8) { return $Fallback }; Start-Sleep -Milliseconds 40 }
    }
    return $Fallback
}
function Send-Json($Context,$Object,[int]$Status=200) { $json=$Object|ConvertTo-Json -Depth 20; $bytes=[Text.Encoding]::UTF8.GetBytes($json); $Context.Response.StatusCode=$Status; $Context.Response.ContentType='application/json; charset=utf-8'; $Context.Response.ContentLength64=$bytes.Length; $Context.Response.OutputStream.Write($bytes,0,$bytes.Length); $Context.Response.Close() }
function Send-File($Context,[string]$Path,[string]$ContentType) { if(-not(Test-Path $Path -PathType Leaf)){$Context.Response.StatusCode=404;$Context.Response.Close();return};$bytes=[IO.File]::ReadAllBytes($Path);$Context.Response.ContentType=$ContentType;$Context.Response.ContentLength64=$bytes.Length;$Context.Response.OutputStream.Write($bytes,0,$bytes.Length);$Context.Response.Close() }
function Get-Tail([string]$Path,[int]$Lines=120){if(-not(Test-Path $Path -PathType Leaf)){return @()};try{return @(Get-Content $Path -Tail $Lines -Encoding UTF8)}catch{return @($_.Exception.Message)}}
function Append-ScanLog([string]$Message,[string]$Level='INFO'){try{$line=('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message);Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8}catch{}}
function Write-StateDirect([string]$Status,[string]$Stage,[string]$Action,$ErrorObject=$null){try{$obj=[pscustomobject]@{status=$Status;stage=$Stage;current=$null;processed=0;total=0;percent=0;elapsedSeconds=0;lastAction=$Action;startedAt=(Get-Date).ToString('s');updatedAt=(Get-Date).ToString('s');error=$ErrorObject};$json=$obj|ConvertTo-Json -Depth 8;[System.IO.File]::WriteAllText($StatePath,$json,(New-Object System.Text.UTF8Encoding($false)))}catch{Append-ScanLog ('Unable to write startup state: '+$_.Exception.Message) 'ERROR'}}
function Start-ScanWorkerProcess {
    foreach($f in @($WorkerStdoutPath,$WorkerStderrPath)){try{if(Test-Path -LiteralPath $f -PathType Leaf){Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue}}catch{}}
    $quotedWorker='"'+$WorkerPath.Replace('"','\"')+'"';$argLine='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+$quotedWorker
    Append-ScanLog ('Launching worker: powershell.exe '+$argLine);Write-StateDirect 'STARTING' 'STARTING' 'Launching background worker'
    try{$proc=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru -RedirectStandardOutput $WorkerStdoutPath -RedirectStandardError $WorkerStderrPath}catch{$err=[pscustomobject]@{message=$_.Exception.Message;category='WORKER_LAUNCH_FAILED';scriptLine=$_.InvocationInfo.ScriptLineNumber;position=$_.InvocationInfo.PositionMessage;stack=[string]$_.ScriptStackTrace};Write-StateDirect 'FAILED' 'FAILED' 'Worker launch failed' $err;Append-ScanLog ('Worker launch failed: '+$_.Exception.Message) 'ERROR';return [pscustomobject]@{ok=$false;pid=$null;error=$_.Exception.Message}}
    Start-Sleep -Milliseconds 500;try{$proc.Refresh()}catch{}
    if($proc.HasExited){$stderr='';try{if(Test-Path -LiteralPath $WorkerStderrPath -PathType Leaf){$stderr=(Get-Content -LiteralPath $WorkerStderrPath -Raw -ErrorAction SilentlyContinue)}}catch{};if([string]::IsNullOrWhiteSpace($stderr)){$stderr='Worker exited immediately with code '+$proc.ExitCode};$err=[pscustomobject]@{message=$stderr.Trim();category='WORKER_EXITED_EARLY';scriptLine=$null;position=$null;stack=$null};Write-StateDirect 'FAILED' 'FAILED' 'Worker exited before scan started' $err;Append-ScanLog ('Worker exited immediately. ExitCode='+$proc.ExitCode+'; '+$stderr.Trim()) 'ERROR';return [pscustomobject]@{ok=$false;pid=$proc.Id;error=$stderr.Trim()}}
    Append-ScanLog ('Worker started. PID='+$proc.Id);return [pscustomobject]@{ok=$true;pid=$proc.Id;error=$null}
}
$listener=New-Object System.Net.HttpListener;$listener.Prefixes.Add([string]$config.ListenPrefix)
try{$listener.Start()}catch{Write-Host ('Failed to start web server on '+$config.ListenPrefix) -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red;exit 1}
Write-Host '1C Publication Auditor V2.0 started.' -ForegroundColor Green;Write-Host ('Open: '+$config.ListenPrefix) -ForegroundColor Cyan;Write-Host 'Background scan worker enabled. Stop web server with Ctrl+C.' -ForegroundColor DarkGray
try{Start-Process ([string]$config.ListenPrefix) -ErrorAction Stop;Write-Host ('Browser opened: '+[string]$config.ListenPrefix) -ForegroundColor DarkGray}catch{Write-Host ('Could not open browser automatically: '+$_.Exception.Message) -ForegroundColor Yellow;Write-Host ('Open manually: '+[string]$config.ListenPrefix) -ForegroundColor Cyan}
while($listener.IsListening){try{$ctx=$listener.GetContext();$path=$ctx.Request.Url.AbsolutePath
if($path -eq '/' -or $path -eq '/index.html'){Send-File $ctx (Join-Path $WebDir 'index.html') 'text/html; charset=utf-8';continue};if($path -eq '/app.js'){Send-File $ctx (Join-Path $WebDir 'app.js') 'application/javascript; charset=utf-8';continue};if($path -eq '/styles.css'){Send-File $ctx (Join-Path $WebDir 'styles.css') 'text/css; charset=utf-8';continue}
if($path -eq '/api/scan' -and $ctx.Request.HttpMethod -eq 'POST'){$state=Read-JsonSafe $StatePath $null;if($null -ne $state -and $state.status -eq 'RUNNING'){Send-Json $ctx ([pscustomobject]@{accepted=$false;reason='ALREADY_RUNNING';state=$state}) 409;continue};if(Test-Path $StopPath -PathType Leaf){Remove-Item $StopPath -Force -ErrorAction SilentlyContinue};if(Test-Path $LivePath -PathType Leaf){Remove-Item $LivePath -Force -ErrorAction SilentlyContinue};$launch=Start-ScanWorkerProcess;if(-not $launch.ok){Send-Json $ctx ([pscustomobject]@{accepted=$false;status='FAILED';error=$launch.error}) 500;continue};Send-Json $ctx ([pscustomobject]@{accepted=$true;status='STARTING';pid=$launch.pid}) 202;continue}
if($path -eq '/api/stop' -and $ctx.Request.HttpMethod -eq 'POST'){[IO.File]::WriteAllText($StopPath,(Get-Date).ToString('o'),[Text.Encoding]::UTF8);Send-Json $ctx ([pscustomobject]@{accepted=$true;status='STOP_REQUESTED'}) 202;continue}
if($path -eq '/api/status'){$fallback=[pscustomobject]@{status='IDLE';stage='IDLE';current=$null;processed=0;total=0;percent=0;elapsedSeconds=0;lastAction='';error=$null};Send-Json $ctx (Read-JsonSafe $StatePath $fallback);continue}
if($path -eq '/api/live'){$fallback=[pscustomobject]@{status='IDLE';scanDate=$null;updatedAt=$null;stats=$null;publications=@();orphanDirectories=@();currentAlias=$null;currentItem=$null};Send-Json $ctx (Read-JsonSafe $LivePath $fallback);continue}
if($path -eq '/api/results'){$fallback=[pscustomobject]@{scanDate=$null;durationSeconds=$null;stats=$null;publications=@();orphanDirectories=@()};Send-Json $ctx (Read-JsonSafe $LastScanPath $fallback);continue}
if($path -eq '/api/history'){Send-Json $ctx (Read-JsonSafe $HistoryPath @());continue};if($path -eq '/api/log'){Send-Json $ctx ([pscustomobject]@{lines=@(Get-Tail $LogPath 150)});continue}
if($path -eq '/api/config'){Send-Json $ctx ([pscustomobject]@{ApacheConfigPath=$config.ApacheConfigPath;PublicationRoots=$config.PublicationRoots;ListenPrefix=$config.ListenPrefix;ExpectedHtaccessRules=$config.ExpectedHtaccessRules;PathTimeoutSeconds=$config.PathTimeoutSeconds});continue}
$ctx.Response.StatusCode=404;$ctx.Response.Close()}catch{Write-Host $_.Exception.Message -ForegroundColor Red;try{if($null -ne $ctx -and $ctx.Response.OutputStream.CanWrite){Send-Json $ctx ([pscustomobject]@{error=$_.Exception.Message}) 500}}catch{}}}
