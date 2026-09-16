$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $BaseDir 'config.json'
$DataDir = Join-Path $BaseDir 'data'
$LogsDir = Join-Path $BaseDir 'logs'
$StatePath = Join-Path $DataDir 'scan-state.json'
$ResultPath = Join-Path $DataDir 'scan-result.json'
$LivePath = Join-Path $DataDir 'scan-live.json'
$HistoryPath = Join-Path $DataDir 'history.json'
$StopPath = Join-Path $DataDir 'stop.request'
$LogPath = Join-Path $LogsDir 'scan.log'
$StartTime = Get-Date
$config = $null
$Timeout = 5
$processed = 0
$total = 0

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = ('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message)
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Write-AtomicJson([string]$Path, $Object, [int]$Depth = 15) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth $Depth
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
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch {}
                $stream = $null
            }
            if ($attempt -ge 12) { throw }
            Start-Sleep -Milliseconds 75
        } finally {
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch {}
            }
        }
    }
}

function Get-LiveStats($Items, $Orphans) {
    $a = @($Items)
    $o = @($Orphans)
    return [pscustomobject]@{
        total=$a.Count
        ok=@($a | Where-Object { $_.overall -eq 'OK' }).Count
        critical=@($a | Where-Object { $_.overall -eq 'CRITICAL' }).Count
        warning=@($a | Where-Object { $_.overall -eq 'WARNING' }).Count
        protected=@($a | Where-Object { $_.exposure.status -eq 'PROTECTED' -or $_.exposure.status -eq 'PROTECTED_APACHE' }).Count
        external=@($a | Where-Object { $_.exposure.status -eq 'POTENTIAL_EXTERNAL' }).Count
        missingPublicationDir=@($a | Where-Object { -not $_.directoryExists }).Count
        missingDatabases=@($a | Where-Object { $_.database.type -eq 'FILE' -and $_.database.status -ne 'OK' }).Count
        timeouts=@($a | Where-Object { $_.directoryProbe.code -eq 'TIMEOUT' -or $_.vrd.status -eq 'TIMEOUT' -or $_.htaccess.reasonCode -eq 'HTACCESS_TIMEOUT' -or $_.database.status -eq 'TIMEOUT' }).Count
        orphans=$o.Count
    }
}

function Write-LiveSnapshot([string]$Status, [string]$CurrentAlias = $null, $CurrentItem = $null) {
    $items = @($script:Results)
    $orphans = @($script:Orphans)
    $live = [pscustomobject]@{
        status=$Status
        scanDate=$StartTime.ToString('s')
        updatedAt=(Get-Date).ToString('s')
        stats=(Get-LiveStats $items $orphans)
        publications=$items
        orphanDirectories=$orphans
        currentAlias=$CurrentAlias
        currentItem=$CurrentItem
    }
    Write-AtomicJson $LivePath $live 20
}

function Update-State([string]$Status, [string]$Stage, [string]$Current, [int]$Processed, [int]$Total, [string]$LastAction, $ErrorObject = $null) {
    $pct = 0
    if ($Total -gt 0) { $pct = [math]::Min(100, [math]::Round(($Processed * 100.0) / $Total, 1)) }
    $s = [pscustomobject]@{
        status=$Status; stage=$Stage; current=$Current; processed=$Processed; total=$Total; percent=$pct;
        elapsedSeconds=[math]::Round(((Get-Date)-$StartTime).TotalSeconds,1); lastAction=$LastAction;
        startedAt=$StartTime.ToString('s'); updatedAt=(Get-Date).ToString('s'); error=$ErrorObject
    }
    Write-AtomicJson $StatePath $s 8
}

function Stop-Requested { return (Test-Path $StopPath -PathType Leaf) }

function Normalize-PathString([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return (($Path -replace '/', '\').Trim())
}

function Invoke-PathProbe([string]$Operation, [string]$Path, [int]$Seconds) {
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($Op,$P)
            $ErrorActionPreference='Stop'
            try {
                if ($Op -eq 'ContainerExists') {
                    return [pscustomobject]@{ ok=$true; exists=(Test-Path -LiteralPath $P -PathType Container); code='OK'; message=$null }
                }
                if ($Op -eq 'LeafExists') {
                    return [pscustomobject]@{ ok=$true; exists=(Test-Path -LiteralPath $P -PathType Leaf); code='OK'; message=$null }
                }
                if ($Op -eq 'GetFileInfo') {
                    if (-not (Test-Path -LiteralPath $P -PathType Leaf)) { return [pscustomobject]@{ ok=$true; exists=$false; code='OK'; message=$null } }
                    $f=Get-Item -LiteralPath $P -ErrorAction Stop
                    return [pscustomobject]@{ ok=$true; exists=$true; length=[int64]$f.Length; lastWriteTime=$f.LastWriteTime.ToString('s'); code='OK'; message=$null }
                }
                if ($Op -eq 'ReadText') {
                    if (-not (Test-Path -LiteralPath $P -PathType Leaf)) { return [pscustomobject]@{ ok=$true; exists=$false; code='OK'; lines=@(); text=$null; message=$null } }
                    $lines=@(Get-Content -LiteralPath $P -Encoding UTF8 -ErrorAction Stop)
                    return [pscustomobject]@{ ok=$true; exists=$true; code='OK'; lines=$lines; text=($lines -join "`n"); message=$null }
                }
                if ($Op -eq 'ListDirectories') {
                    if (-not (Test-Path -LiteralPath $P -PathType Container)) { return [pscustomobject]@{ ok=$true; exists=$false; code='OK'; items=@(); message=$null } }
                    $items=@(Get-ChildItem -LiteralPath $P -Directory -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ name=$_.Name; fullName=$_.FullName } })
                    return [pscustomobject]@{ ok=$true; exists=$true; code='OK'; items=$items; message=$null }
                }
                return [pscustomobject]@{ ok=$false; exists=$false; code='BAD_OPERATION'; message=$Op }
            } catch [System.UnauthorizedAccessException] {
                return [pscustomobject]@{ ok=$false; exists=$false; code='ACCESS_DENIED'; message=$_.Exception.Message }
            } catch {
                return [pscustomobject]@{ ok=$false; exists=$false; code='ERROR'; message=$_.Exception.Message }
            }
        } -ArgumentList $Operation,$Path
        $done = Wait-Job -Job $job -Timeout $Seconds
        if ($null -eq $done) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return [pscustomobject]@{ ok=$false; exists=$false; code='TIMEOUT'; message=('Timeout after ' + $Seconds + ' seconds') }
        }
        $r = Receive-Job -Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($null -eq $r) { return [pscustomobject]@{ ok=$false; exists=$false; code='ERROR'; message='Empty probe result' } }
        return $r
    } catch {
        return [pscustomobject]@{ ok=$false; exists=$false; code='ERROR'; message=$_.Exception.Message }
    } finally {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PathRootInfo([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ kind='INVALID'; root=$null; normalized=$null }
    }

    $normalized = Normalize-PathString $Path
    try {
        $root = [System.IO.Path]::GetPathRoot($normalized)
    } catch {
        return [pscustomobject]@{ kind='INVALID'; root=$null; normalized=$normalized }
    }

    if ([string]::IsNullOrWhiteSpace([string]$root)) {
        return [pscustomobject]@{ kind='INVALID'; root=$null; normalized=$normalized }
    }

    $kind = 'OTHER'
    if ($root.Length -ge 3 -and $root[1] -eq ':' -and $root[2] -eq '\') {
        $kind = 'LOCAL_DRIVE'
    } elseif ($root.StartsWith('\\')) {
        $kind = 'UNC'
    }

    return [pscustomobject]@{ kind=$kind; root=$root; normalized=$normalized }
}

function Get-DriveState([string]$Path) {
    $info = Get-PathRootInfo $Path
    if ($info.kind -eq 'INVALID') { return 'PATH_INVALID' }

    # Probe only the root. This prevents a missing database folder from being
    # misclassified as an unavailable drive/share.
    $p = Invoke-PathProbe 'ContainerExists' ([string]$info.root) $Timeout
    if ($p.code -eq 'TIMEOUT') { return 'TIMEOUT' }
    if ($p.code -eq 'ACCESS_DENIED') { return 'ACCESS_DENIED' }
    if (-not $p.ok -or -not $p.exists) {
        if ($info.kind -eq 'LOCAL_DRIVE') { return 'DRIVE_UNAVAILABLE' }
        if ($info.kind -eq 'UNC') { return 'PATH_UNAVAILABLE' }
        return 'PATH_UNAVAILABLE'
    }
    return 'AVAILABLE'
}

function Parse-ApachePublications([string]$ApacheConfigPath) {
    $probe = Invoke-PathProbe 'ReadText' $ApacheConfigPath $Timeout
    if ($probe.code -eq 'TIMEOUT') { throw 'Apache config read timeout' }
    if ($probe.code -eq 'ACCESS_DENIED') { throw 'Apache config access denied' }
    if (-not $probe.ok -or -not $probe.exists) { throw ('httpd.conf not available: ' + $ApacheConfigPath) }
    $lines = @($probe.lines)
    $items = New-Object System.Collections.ArrayList
    for ($i=0;$i -lt $lines.Count;$i++) {
        if ($lines[$i] -notmatch '^\s*Alias\s+"([^"]+)"\s+"([^"]+)"') { continue }
        $alias=$Matches[1]; $aliasPath=$Matches[2]
        $j=$i+1
        while ($j -lt $lines.Count -and $lines[$j] -match '^\s*(#.*)?$') { $j++ }
        if ($j -ge $lines.Count -or $lines[$j] -notmatch '^\s*<Directory\s+"([^"]+)"\s*>') { continue }
        $dirPath=$Matches[1]
        $block=New-Object System.Collections.ArrayList
        $k=$j+1
        while ($k -lt $lines.Count -and $lines[$k] -notmatch '^\s*</Directory>') { [void]$block.Add($lines[$k]); $k++ }
        $is1c=$false
        foreach($b in $block){ if($b -match '^\s*SetHandler\s+1c-application\s*$'){ $is1c=$true; break } }
        if(-not $is1c){ continue }
        $vrd=$null; $allow=$null; $req=@()
        foreach($b in $block){
            if($b -match '^\s*ManagedApplicationDescriptor\s+"([^"]+)"'){ $vrd=$Matches[1] }
            elseif($b -match '^\s*AllowOverride\s+(.+?)\s*$'){ $allow=$Matches[1].Trim() }
            elseif($b -match '^\s*Require\s+(.+?)\s*$'){ $req += ('Require ' + $Matches[1].Trim()) }
        }
        [void]$items.Add([pscustomobject]@{ alias=$alias; directory=(Normalize-PathString $dirPath); aliasTarget=(Normalize-PathString $aliasPath); vrd=(Normalize-PathString $vrd); allowOverride=$allow; apacheRequire=@($req); configLine=($i+1) })
        $i=$k
    }
    return @($items)
}

function Test-HtAccess([string]$Directory) {
    $r=[ordered]@{ status='ERROR'; reasonCode='UNKNOWN'; path=$null; content=@(); missingRules=@(); probeCode=$null; error=$null }
    if([string]::IsNullOrWhiteSpace($Directory)){ $r.reasonCode='DIRECTORY_NOT_SET'; return [pscustomobject]$r }
    $file=Join-Path $Directory '.htaccess'; $r.path=$file
    $p=Invoke-PathProbe 'ReadText' $file $Timeout; $r.probeCode=$p.code
    if($p.code -eq 'TIMEOUT'){ $r.status='WARNING'; $r.reasonCode='HTACCESS_TIMEOUT'; return [pscustomobject]$r }
    if($p.code -eq 'ACCESS_DENIED'){ $r.status='ERROR'; $r.reasonCode='HTACCESS_ACCESS_DENIED'; return [pscustomobject]$r }
    if(-not $p.ok){ $r.status='ERROR'; $r.reasonCode='HTACCESS_READ_ERROR'; $r.error=$p.message; return [pscustomobject]$r }
    if(-not $p.exists){ $r.status='EXTERNAL'; $r.reasonCode='HTACCESS_MISSING'; return [pscustomobject]$r }
    $lines=@($p.lines); $r.content=$lines
    $effective=@($lines|ForEach-Object{$_.Trim()}|Where-Object{$_ -and -not $_.StartsWith('#')})
    if($effective.Count -eq 0){ $r.status='EXTERNAL'; $r.reasonCode='HTACCESS_EMPTY'; return [pscustomobject]$r }
    $missing=@()
    foreach($rule in @($config.ExpectedHtaccessRules)){ $found=$false; foreach($line in $effective){ if($line -ieq $rule){$found=$true;break} }; if(-not $found){$missing+=$rule} }
    $r.missingRules=@($missing)
    if($missing.Count -eq 0){$r.status='PROTECTED';$r.reasonCode='EXPECTED_RULES_FOUND'}else{$r.status='WARNING';$r.reasonCode='EXPECTED_RULES_MISSING'}
    return [pscustomobject]$r
}

function Parse-Vrd([string]$VrdPath) {
    $r=[ordered]@{status='MISSING';base=$null;ib=$null;databaseType='UNKNOWN';databasePath=$null;databaseServer=$null;databaseRef=$null;attributes=[ordered]@{};elementSummary=[ordered]@{};parseError=$null;probeCode=$null}
    if([string]::IsNullOrWhiteSpace($VrdPath)){return [pscustomobject]$r}
    $p=Invoke-PathProbe 'ReadText' $VrdPath $Timeout; $r.probeCode=$p.code
    if($p.code -eq 'TIMEOUT'){$r.status='TIMEOUT';return [pscustomobject]$r}
    if($p.code -eq 'ACCESS_DENIED'){$r.status='ACCESS_DENIED';return [pscustomobject]$r}
    if(-not $p.ok){$r.status='READ_ERROR';$r.parseError=$p.message;return [pscustomobject]$r}
    if(-not $p.exists){return [pscustomobject]$r}
    if([string]::IsNullOrWhiteSpace([string]$p.text)){$r.status='EMPTY';return [pscustomobject]$r}
    try{
        [xml]$xml=[string]$p.text; $point=$xml.DocumentElement
        $r.status='OK'; $r.base=$point.GetAttribute('base'); $r.ib=$point.GetAttribute('ib'); $ib=$r.ib
        foreach($attr in @($point.Attributes)){ $r.attributes[$attr.Name]=[string]$attr.Value }
        foreach($child in @($point.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })){
            $name=[string]$child.Name
            if($r.elementSummary.Contains($name)){ $r.elementSummary[$name]=[int]$r.elementSummary[$name]+1 } else { $r.elementSummary[$name]=1 }
        }
        if($ib -match '(?i)(?:^|;)\s*File\s*=\s*"([^"]+)"'){ $r.databaseType='FILE'; $r.databasePath=Normalize-PathString $Matches[1] }
        elseif($ib -match '(?i)(?:^|;)\s*Srvr\s*=\s*"([^"]+)"'){ $r.databaseType='SERVER';$r.databaseServer=$Matches[1];if($ib -match '(?i)(?:^|;)\s*Ref\s*=\s*"([^"]+)"'){$r.databaseRef=$Matches[1]} }
    }catch{$r.status='PARSE_ERROR';$r.parseError=$_.Exception.Message}
    return [pscustomobject]$r
}

function Check-FileDatabase([string]$DbPath) {
    $db=[ordered]@{type='FILE';path=$DbPath;driveState=$null;directoryExists=$null;fileExists=$null;filePath=$null;sizeBytes=$null;sizeGB=$null;lastWriteTime=$null;status='UNKNOWN';probeCode=$null;message=$null}
    $db.driveState=Get-DriveState $DbPath
    if($db.driveState -eq 'TIMEOUT'){$db.status='TIMEOUT';return [pscustomobject]$db}
    if($db.driveState -eq 'ACCESS_DENIED'){$db.status='ACCESS_DENIED';return [pscustomobject]$db}
    if($db.driveState -eq 'DRIVE_UNAVAILABLE'){$db.status='DRIVE_UNAVAILABLE';return [pscustomobject]$db}
    if($db.driveState -eq 'PATH_UNAVAILABLE'){$db.status='PATH_UNAVAILABLE';return [pscustomobject]$db}
    if($db.driveState -eq 'PATH_INVALID'){$db.status='PATH_INVALID';return [pscustomobject]$db}
    $pd=Invoke-PathProbe 'ContainerExists' $DbPath $Timeout; $db.probeCode=$pd.code
    if($pd.code -eq 'TIMEOUT'){$db.status='TIMEOUT';return [pscustomobject]$db}
    if($pd.code -eq 'ACCESS_DENIED'){$db.status='ACCESS_DENIED';return [pscustomobject]$db}
    if(-not $pd.ok){$db.status='ERROR';$db.message=$pd.message;return [pscustomobject]$db}
    $db.directoryExists=[bool]$pd.exists
    if(-not $db.directoryExists){$db.status='DIRECTORY_MISSING';return [pscustomobject]$db}
    $db.filePath=Join-Path $DbPath '1Cv8.1CD'
    $pf=Invoke-PathProbe 'GetFileInfo' $db.filePath $Timeout; $db.probeCode=$pf.code
    if($pf.code -eq 'TIMEOUT'){$db.status='TIMEOUT';return [pscustomobject]$db}
    if($pf.code -eq 'ACCESS_DENIED'){$db.status='ACCESS_DENIED';return [pscustomobject]$db}
    if(-not $pf.ok){$db.status='ERROR';$db.message=$pf.message;return [pscustomobject]$db}
    $db.fileExists=[bool]$pf.exists
    if(-not $db.fileExists){$db.status='FILE_MISSING';return [pscustomobject]$db}
    $db.sizeBytes=[int64]$pf.length; $db.sizeGB=[math]::Round($db.sizeBytes/1GB,2); $db.lastWriteTime=$pf.lastWriteTime
    if($db.sizeBytes -gt 0){$db.status='OK'}else{$db.status='EMPTY_FILE'}
    return [pscustomobject]$db
}

function Make-Result($p,[bool]$dirExists,$dirProbe,$vrd,$ht,$db){
    $issues=New-Object System.Collections.ArrayList
    if(-not $dirExists){[void]$issues.Add('PUBLICATION_DIRECTORY_MISSING')}
    if($dirProbe.code -eq 'TIMEOUT'){[void]$issues.Add('PUBLICATION_DIRECTORY_TIMEOUT')}
    if($dirProbe.code -eq 'ACCESS_DENIED'){[void]$issues.Add('PUBLICATION_DIRECTORY_ACCESS_DENIED')}
    if($vrd.status -ne 'OK'){[void]$issues.Add('VRD_' + $vrd.status)}
    if($ht.status -eq 'WARNING'){[void]$issues.Add('HTACCESS_' + $ht.reasonCode)}elseif($ht.status -eq 'ERROR'){[void]$issues.Add('HTACCESS_' + $ht.reasonCode)}
    if($p.allowOverride -and $p.allowOverride -ieq 'None' -and $ht.status -eq 'PROTECTED'){[void]$issues.Add('ALLOWOVERRIDE_NONE')}
    if($db.type -eq 'FILE' -and $db.status -ne 'OK'){[void]$issues.Add('FILE_DB_' + $db.status)}

    $apacheRestrictive=@($p.apacheRequire | Where-Object { $_ -and ($_ -notmatch '(?i)^Require\s+all\s+granted\s*$') })
    $exposureStatus='UNKNOWN'; $exposureReason='UNDETERMINED'
    if(-not $dirExists){
        $exposureStatus='NOT_APPLICABLE'; $exposureReason='PUBLICATION_DIRECTORY_MISSING'
    } elseif($apacheRestrictive.Count -gt 0) {
        $exposureStatus='PROTECTED_APACHE'; $exposureReason='DIRECT_APACHE_RESTRICTION'
    } elseif($p.allowOverride -and $p.allowOverride -ieq 'None') {
        $exposureStatus='POTENTIAL_EXTERNAL';$exposureReason='ALLOWOVERRIDE_DISABLED';[void]$issues.Add('POTENTIAL_EXTERNAL_ACCESS')
    } elseif($ht.status -eq 'PROTECTED') {
        $exposureStatus='PROTECTED'; $exposureReason='HTACCESS_EXPECTED_RULES_FOUND'
    } elseif($ht.status -eq 'EXTERNAL') {
        $exposureStatus='POTENTIAL_EXTERNAL'; $exposureReason=$ht.reasonCode; [void]$issues.Add('POTENTIAL_EXTERNAL_ACCESS')
    } elseif($ht.status -eq 'WARNING') {
        $exposureStatus='REVIEW'; $exposureReason=$ht.reasonCode
    } elseif($ht.status -eq 'ERROR') {
        $exposureStatus='UNKNOWN'; $exposureReason=$ht.reasonCode
    }
    $exposure=[pscustomobject]@{status=$exposureStatus;reasonCode=$exposureReason;allowOverride=$p.allowOverride;apacheRequire=@($p.apacheRequire);directApacheRestrictions=@($apacheRestrictive)}

    $critical=@('DIRECTORY_MISSING','FILE_MISSING','EMPTY_FILE','ACCESS_DENIED','DRIVE_UNAVAILABLE','PATH_UNAVAILABLE')
    if($issues.Count -eq 0){$overall='OK'}elseif($exposure.status -eq 'POTENTIAL_EXTERNAL' -or -not $dirExists -or ($db.type -eq 'FILE' -and $critical -contains $db.status)){$overall='CRITICAL'}else{$overall='WARNING'}
    $group='OTHER'
    if(-not [string]::IsNullOrWhiteSpace([string]$p.directory)){
        $dirForGroup=(Normalize-PathString ([string]$p.directory)).TrimEnd('\').ToLowerInvariant()
        $parts=@($dirForGroup.Split('\') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if($parts -contains '1c_web_local'){$group='LOCAL'}elseif($parts -contains '1c_web'){$group='WEB'}
    }
    $resultVrdPath = $p.vrd
    if ([string]::IsNullOrWhiteSpace([string]$resultVrdPath)) { $resultVrdPath = Join-Path $p.directory 'default.vrd' }
    return [pscustomobject]@{rowState='DONE';alias=$p.alias;aliasTarget=$p.aliasTarget;group=$group;directory=$p.directory;directoryExists=$dirExists;directoryProbe=$dirProbe;vrdPath=$resultVrdPath;vrd=$vrd;htaccess=$ht;exposure=$exposure;allowOverride=$p.allowOverride;apacheRequire=$p.apacheRequire;database=$db;overall=$overall;issues=@($issues);configLine=$p.configLine;audit=[pscustomobject]@{flags=@();duplicateAliases=@();duplicateDirectories=@();duplicateBases=@();duplicateDatabases=@();aliasDirectoryMatch=$null;vrdInsideDirectory=$null;databaseIdentity=$null}}
}


function Get-NormalizedKey([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = (Normalize-PathString $Value)
    try { $normalized = [System.IO.Path]::GetFullPath($normalized) } catch {}
    $root = $null
    try { $root = [System.IO.Path]::GetPathRoot($normalized) } catch {}
    if (-not [string]::IsNullOrWhiteSpace([string]$root) -and $normalized.Length -gt $root.Length) {
        $normalized = $normalized.TrimEnd('\')
    }
    return $normalized.ToLowerInvariant()
}

function Test-PathInsideDirectory([string]$Path, [string]$Directory) {
    $pathKey = Get-NormalizedKey $Path
    $dirKey = Get-NormalizedKey $Directory
    if ([string]::IsNullOrWhiteSpace($pathKey) -or [string]::IsNullOrWhiteSpace($dirKey)) { return $false }
    if ($pathKey -eq $dirKey) { return $true }
    return $pathKey.StartsWith(($dirKey + '\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-DatabaseIdentity($Item) {
    if ($null -eq $Item -or $null -eq $Item.database) { return $null }
    if ($Item.database.type -eq 'FILE' -and $Item.database.path) {
        return ('FILE|' + (Get-NormalizedKey ([string]$Item.database.path)))
    }
    if ($Item.database.type -eq 'SERVER' -and ($Item.database.server -or $Item.database.ref)) {
        return ('SERVER|' + ([string]$Item.database.server).Trim().ToLowerInvariant() + '|' + ([string]$Item.database.ref).Trim().ToLowerInvariant())
    }
    return $null
}

function Add-AuditIssue($Item, [string]$Code, [bool]$Critical = $false) {
    $issues = New-Object System.Collections.ArrayList
    foreach ($x in @($Item.issues)) { if ($issues -notcontains $x) { [void]$issues.Add($x) } }
    if ($issues -notcontains $Code) { [void]$issues.Add($Code) }
    $Item.issues = @($issues)
    $flags = New-Object System.Collections.ArrayList
    foreach ($x in @($Item.audit.flags)) { if ($flags -notcontains $x) { [void]$flags.Add($x) } }
    if ($flags -notcontains $Code) { [void]$flags.Add($Code) }
    $Item.audit.flags = @($flags)
    if ($Critical) { $Item.overall = 'CRITICAL' } elseif ($Item.overall -eq 'OK') { $Item.overall = 'WARNING' }
}

function Apply-DeepAudit($Items) {
    $all = @($Items)
    foreach ($item in $all) {
        $aliasKey = Get-NormalizedKey ([string]$item.alias)
        $dirKey = Get-NormalizedKey ([string]$item.directory)
        $targetKey = Get-NormalizedKey ([string]$item.aliasTarget)
        if ($dirKey -and $targetKey) {
            $item.audit.aliasDirectoryMatch = ($dirKey -eq $targetKey)
            if (-not $item.audit.aliasDirectoryMatch) { Add-AuditIssue $item 'ALIAS_DIRECTORY_MISMATCH' $true }
        }
        if ($item.vrdPath -and $item.directory) {
            $item.audit.vrdInsideDirectory = Test-PathInsideDirectory ([string]$item.vrdPath) ([string]$item.directory)
            if (-not $item.audit.vrdInsideDirectory) { Add-AuditIssue $item 'VRD_OUTSIDE_PUBLICATION_DIRECTORY' $false }
        }
        $item.audit.databaseIdentity = Get-DatabaseIdentity $item

        $req = @($item.apacheRequire | ForEach-Object { ([string]$_).Trim() })
        $hasAllGranted = @($req | Where-Object { $_ -match '(?i)^Require\s+all\s+granted\s*$' }).Count -gt 0
        $hasRestrictive = @($req | Where-Object { $_ -and ($_ -notmatch '(?i)^Require\s+all\s+granted\s*$') }).Count -gt 0
        if ($hasAllGranted -and $hasRestrictive) { Add-AuditIssue $item 'APACHE_REQUIRE_CONFLICT' $true }
    }

    foreach ($item in $all) {
        $ak = Get-NormalizedKey ([string]$item.alias)
        if ($ak) {
            $dups = @($all | Where-Object { (Get-NormalizedKey ([string]$_.alias)) -eq $ak -and $_.configLine -ne $item.configLine })
            if ($dups.Count -gt 0) { $item.audit.duplicateAliases=@($dups|ForEach-Object{$_.alias + ' @' + $_.configLine}); Add-AuditIssue $item 'DUPLICATE_ALIAS' $true }
        }
        $dk = Get-NormalizedKey ([string]$item.directory)
        if ($dk) {
            $dups = @($all | Where-Object { (Get-NormalizedKey ([string]$_.directory)) -eq $dk -and $_.configLine -ne $item.configLine })
            if ($dups.Count -gt 0) { $item.audit.duplicateDirectories=@($dups|ForEach-Object{$_.alias}); Add-AuditIssue $item 'DUPLICATE_DIRECTORY' $false }
        }
        $base = Get-NormalizedKey ([string]$item.vrd.base)
        if ($base) {
            $dups = @($all | Where-Object { (Get-NormalizedKey ([string]$_.vrd.base)) -eq $base -and $_.configLine -ne $item.configLine })
            if ($dups.Count -gt 0) { $item.audit.duplicateBases=@($dups|ForEach-Object{$_.alias}); Add-AuditIssue $item 'DUPLICATE_VRD_BASE' $true }
        }
        $dbid = [string]$item.audit.databaseIdentity
        if ($dbid) {
            $dups = @($all | Where-Object { [string]$_.audit.databaseIdentity -eq $dbid -and $_.configLine -ne $item.configLine })
            if ($dups.Count -gt 0) { $item.audit.duplicateDatabases=@($dups|ForEach-Object{$_.alias}); Add-AuditIssue $item 'DATABASE_PUBLISHED_MULTIPLE_TIMES' $false }
        }
    }

    $summary=[pscustomobject]@{
        duplicateAliasPublications=@($all|Where-Object{$_.audit.flags -contains 'DUPLICATE_ALIAS'}).Count
        duplicateDirectoryPublications=@($all|Where-Object{$_.audit.flags -contains 'DUPLICATE_DIRECTORY'}).Count
        duplicateBasePublications=@($all|Where-Object{$_.audit.flags -contains 'DUPLICATE_VRD_BASE'}).Count
        sharedDatabasePublications=@($all|Where-Object{$_.audit.flags -contains 'DATABASE_PUBLISHED_MULTIPLE_TIMES'}).Count
        aliasDirectoryMismatch=@($all|Where-Object{$_.audit.flags -contains 'ALIAS_DIRECTORY_MISMATCH'}).Count
        requireConflicts=@($all|Where-Object{$_.audit.flags -contains 'APACHE_REQUIRE_CONFLICT'}).Count
        vrdOutsideDirectory=@($all|Where-Object{$_.audit.flags -contains 'VRD_OUTSIDE_PUBLICATION_DIRECTORY'}).Count
    }
    return $summary
}

try {
    foreach ($Dir in @($DataDir,$LogsDir)) {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    }
    Write-Log ('Worker bootstrap. PID=' + $PID)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw ('config.json not found: ' + $ConfigPath) }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Timeout = [int]$config.PathTimeoutSeconds
    if ($Timeout -lt 1) { $Timeout = 5 }
    Write-Log ('Configuration loaded. Timeout=' + $Timeout + ' sec')
    if(Test-Path $StopPath -PathType Leaf){Remove-Item $StopPath -Force -ErrorAction SilentlyContinue}
    $script:Results = New-Object System.Collections.ArrayList
    $script:Orphans = New-Object System.Collections.ArrayList
    Write-Log 'Scan started'
    Write-LiveSnapshot 'RUNNING'
    Update-State 'RUNNING' 'READ_APACHE' '' 0 0 'Reading Apache configuration'
    $pubs=@(Parse-ApachePublications $config.ApacheConfigPath)
    $total=$pubs.Count
    Write-Log ('Found publications: ' + $total)
    Update-State 'RUNNING' 'PUBLICATIONS' '' 0 $total 'Apache configuration parsed'
    $processed=0

    foreach($p in $pubs){
        if(Stop-Requested){ throw [System.OperationCanceledException]::new('Stop requested') }
        $currentItem=[pscustomobject]@{rowState='CHECKING';alias=$p.alias;group='';directory=$p.directory;configLine=$p.configLine;overall='CHECKING';issues=@()}
        Write-LiveSnapshot 'RUNNING' $p.alias $currentItem
        Update-State 'RUNNING' 'PUBLICATIONS' $p.alias $processed $total ('Checking publication: ' + $p.alias)
        Write-Log ('Checking ' + $p.alias + ' -> ' + $p.directory)

        $dirProbe=Invoke-PathProbe 'ContainerExists' $p.directory $Timeout
        $dirExists=($dirProbe.ok -and $dirProbe.exists)
        $vrdPath=$p.vrd
        if ([string]::IsNullOrWhiteSpace([string]$vrdPath)) { $vrdPath=Join-Path $p.directory 'default.vrd' }
        $vrd=Parse-Vrd $vrdPath
        $ht=Test-HtAccess $p.directory
        if($vrd.databaseType -eq 'FILE' -and $vrd.databasePath){
            Update-State 'RUNNING' 'DATABASES' $p.alias $processed $total ('Checking database: ' + $vrd.databasePath)
            $db=Check-FileDatabase $vrd.databasePath
        } elseif($vrd.databaseType -eq 'SERVER') {
            $db=[pscustomobject]@{type='SERVER';path=$null;server=$vrd.databaseServer;ref=$vrd.databaseRef;driveState=$null;directoryExists=$null;fileExists=$null;filePath=$null;sizeBytes=$null;sizeGB=$null;lastWriteTime=$null;status='NOT_CHECKED_V1';probeCode=$null;message=$null}
        } else {
            $db=[pscustomobject]@{type='UNKNOWN';path=$null;server=$null;ref=$null;driveState=$null;directoryExists=$null;fileExists=$null;filePath=$null;sizeBytes=$null;sizeGB=$null;lastWriteTime=$null;status='UNKNOWN';probeCode=$null;message=$null}
        }

        $result=Make-Result $p $dirExists $dirProbe $vrd $ht $db
        [void]$script:Results.Add($result)
        $processed++
        Write-LiveSnapshot 'RUNNING' $null $null
        Update-State 'RUNNING' 'PUBLICATIONS' $p.alias $processed $total ('Completed: ' + $p.alias)
    }

    Update-State 'RUNNING' 'ORPHANS' '' $processed $total 'Checking orphan directories'
    Write-LiveSnapshot 'RUNNING'
    $known=@($script:Results|ForEach-Object{if($_.directory){$_.directory.TrimEnd('\').ToLowerInvariant()}})
    foreach($root in @($config.PublicationRoots)){
        if(Stop-Requested){ throw [System.OperationCanceledException]::new('Stop requested') }
        Write-Log ('Checking orphan root: ' + $root)
        $lr=Invoke-PathProbe 'ListDirectories' $root $Timeout
        if($lr.code -eq 'TIMEOUT'){
            [void]$script:Orphans.Add([pscustomobject]@{root=$root;directory=$root;name='[ROOT TIMEOUT]';status='TIMEOUT';hasVrd=$false;hasHtaccess=$false})
            Write-LiveSnapshot 'RUNNING'; continue
        }
        if($lr.code -eq 'ACCESS_DENIED'){
            [void]$script:Orphans.Add([pscustomobject]@{root=$root;directory=$root;name='[ACCESS DENIED]';status='ACCESS_DENIED';hasVrd=$false;hasHtaccess=$false})
            Write-LiveSnapshot 'RUNNING'; continue
        }
        if(-not $lr.ok -or -not $lr.exists){continue}
        foreach($d in @($lr.items)){
            if(Stop-Requested){ throw [System.OperationCanceledException]::new('Stop requested') }
            $full=$d.fullName.TrimEnd('\').ToLowerInvariant()
            if($known -notcontains $full){
                $v=Invoke-PathProbe 'LeafExists' (Join-Path $d.fullName 'default.vrd') $Timeout
                $h=Invoke-PathProbe 'LeafExists' (Join-Path $d.fullName '.htaccess') $Timeout
                [void]$script:Orphans.Add([pscustomobject]@{root=$root;directory=$d.fullName;name=$d.name;status='ORPHAN';hasVrd=($v.ok -and $v.exists);hasHtaccess=($h.ok -and $h.exists)})
                Write-LiveSnapshot 'RUNNING'
            }
        }
    }

    Update-State 'RUNNING' 'DEEP_AUDIT' '' $processed $total 'Analyzing duplicates and Apache/VRD relationships'
    $deepAudit=Apply-DeepAudit $script:Results
    Write-LiveSnapshot 'RUNNING'
    $stats=Get-LiveStats $script:Results $script:Orphans
    $scan=[pscustomobject]@{version='2.0';scanDate=(Get-Date).ToString('s');durationSeconds=[math]::Round(((Get-Date)-$StartTime).TotalSeconds,2);stats=$stats;deepAudit=$deepAudit;publications=@($script:Results);orphanDirectories=@($script:Orphans)}
    Write-AtomicJson $ResultPath $scan 20
    Write-LiveSnapshot 'COMPLETED'

    $history=@()
    if(Test-Path $HistoryPath -PathType Leaf){
        try{$history=@(Get-Content $HistoryPath -Raw -Encoding UTF8|ConvertFrom-Json)}catch{$history=@()}
    }
    $history=@([pscustomobject]@{scanDate=$scan.scanDate;durationSeconds=$scan.durationSeconds;stats=$scan.stats})+$history
    $limit=[int]$config.HistoryLimit
    if($limit -lt 1){$limit=50}
    if($history.Count -gt $limit){$history=$history[0..($limit-1)]}
    Write-AtomicJson $HistoryPath $history 8
    Update-State 'COMPLETED' 'DONE' '' $total $total 'Scan completed'
    Write-Log ('Scan completed in ' + $scan.durationSeconds + ' sec')
} catch [System.OperationCanceledException] {
    try { Write-LiveSnapshot 'STOPPED' } catch {}
    Update-State 'STOPPED' 'STOPPED' '' $processed $total 'Scan stopped by user'
    Write-Log 'Scan stopped by user' 'WARN'
} catch {
    $e=[pscustomobject]@{message=$_.Exception.Message;category=[string]$_.CategoryInfo.Category;scriptLine=$_.InvocationInfo.ScriptLineNumber;position=$_.InvocationInfo.PositionMessage;stack=[string]$_.ScriptStackTrace}
    try { if ($null -ne $script:Results -and $null -ne $script:Orphans) { Write-LiveSnapshot 'FAILED' } } catch {}
    try { Update-State 'FAILED' 'FAILED' '' ([int]$processed) ([int]$total) 'Scan failed' $e } catch {}
    try { Write-Log ('Scan failed: ' + $_.Exception.Message) 'ERROR' } catch {}
    Write-Log ([string]$_.InvocationInfo.PositionMessage) 'ERROR'
} finally {
    if(Test-Path $StopPath -PathType Leaf){Remove-Item $StopPath -Force -ErrorAction SilentlyContinue}
}
