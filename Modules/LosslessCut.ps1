#requires -Version 7.0

#region LosslessCut 連携

if (-not (Get-Command -Name Ensure-Directory -CommandType Function -ErrorAction SilentlyContinue)) {
    function global:Ensure-Directory {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $Path -Force
        }
    }
}

if (-not (Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue)) {
    function global:Write-Log {
        param(
            [string]$Message,
            [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
            [string]$Level = "INFO"
        )
        $logMessage = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        switch ($Level) {
            "ERROR" { Write-Host $logMessage -ForegroundColor Red }
            "WARN" { Write-Host $logMessage -ForegroundColor Yellow }
            "DEBUG" { Write-Host $logMessage -ForegroundColor DarkGray }
            default { Write-Host $logMessage }
        }
    }
}

function Get-LosslessCutDir {
    $dir = Join-Path $global:AppCacheDir 'losslesscut'
    Ensure-Directory -Path $dir
    return $dir
}

function Get-LatestLosslessCutAppImage {
    param([switch]$ForceUpdate, [switch]$NoUpdate)
    $dir = Get-LosslessCutDir
    $appImage = Join-Path $dir 'LosslessCut-linux-x86_64.AppImage'
    $versionFile = Join-Path $dir 'version.txt'
    if ($NoUpdate -and (Test-Path -LiteralPath $appImage)) { return $appImage }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $yml = Invoke-WebRequest -Uri 'https://github.com/mifi/lossless-cut/releases/latest/download/latest-linux.yml' -UseBasicParsing -TimeoutSec 30
        $ymlText = if ($yml.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($yml.Content) } else { [string]$yml.Content }
        $version = ''
        if ($ymlText -match '(?m)^version:\s*([^\r\n]+)') { $version = [string]$Matches[1].Trim() }
        if (-not $version) { throw '最新リリースのバージョンを読み取れませんでした。' }
        $current = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '' }
        if ($ForceUpdate -or $current -ne $version -or -not (Test-Path -LiteralPath $appImage)) {
            Write-Log "LosslessCut $version の AppImage を取得します..."
            $tmp = [string](Join-Path $dir 'download.AppImage')
            $url = "https://github.com/mifi/lossless-cut/releases/download/v$version/LosslessCut-linux-x86_64.AppImage"
            $null = Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 600
            if ((Get-Item -LiteralPath $tmp).Length -lt 1000000) { throw 'AppImage のダウンロードが不完全です。' }
            Move-Item -LiteralPath $tmp -Destination $appImage -Force
        }
        $null = & chmod +x $appImage
        [IO.File]::WriteAllText($versionFile, $version)
        Write-Log "LosslessCut の AppImage を使用可能: $appImage ($version)"
        return $appImage
    }
    catch {
        Write-Log "LosslessCut の AppImage 取得に失敗しました: $_" -Level 'WARN'
        if (Test-Path -LiteralPath $appImage) { return $appImage }
        return $null
    }
}

function Resolve-LosslessCutPath {
    param([switch]$ForceUpdate, [switch]$NoUpdate)
    $configured = [string]$global:Settings.LosslessCutPath
    if ($configured) {
        if ($IsWindows -or $configured -notmatch '\.(exe|bat|cmd)$') {
            if (Test-Path -LiteralPath $configured) { return $configured }
            $command = Get-Command -Name $configured -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { return ([string]$command.Source) }
        }
    }
    if (-not $IsWindows) {
        foreach ($name in @('losslesscut', 'LosslessCut')) {
            $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { return ([string]$command.Source) }
        }
        return Get-LatestLosslessCutAppImage -ForceUpdate:$ForceUpdate -NoUpdate:$NoUpdate
    }
    return $null
}

function Start-LosslessCut {
    param(
        [string[]]$Path = @(),
        [switch]$ForceUpdate,
        [switch]$NoUpdate,
        [switch]$Quiet
    )
    $exe = [string](Resolve-LosslessCutPath -ForceUpdate:$ForceUpdate -NoUpdate:$NoUpdate | Select-Object -First 1)
    if (-not $exe) { return $false }
    $fileArgs = @($Path | ForEach-Object { '"' + $_ + '"' })
    $quotedExe = '"' + $exe + '"'
    $launcher = ''
    try {
        if ($Quiet) {
            $inner = (@($quotedExe) + $fileArgs) -join ' '
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            if ($IsWindows) {
                $psi.FileName = 'cmd.exe'
                $psi.ArgumentList.Add('/d')
                $psi.ArgumentList.Add('/c')
                $psi.ArgumentList.Add("$inner >NUL 2>&1")
            }
            else {
                $psi.FileName = '/bin/sh'
                $psi.ArgumentList.Add('-c')
                $psi.ArgumentList.Add("$inner >/dev/null 2>&1")
            }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $null = [System.Diagnostics.Process]::Start($psi)
            return $true
        }
        if ($IsWindows) {
            $cmdArgs = @('/d', '/c', 'start', '"LosslessCut"', $quotedExe) + $fileArgs
            Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs
            $launcher = 'cmd.exe start'
        }
        else {
            $terminals = @(
                @{ Name = 'gnome-terminal'; Style = 'dashdash' },
                @{ Name = 'xfce4-terminal'; Style = 'command' },
                @{ Name = 'konsole'; Style = 'exe' },
                @{ Name = 'xterm'; Style = 'exe' },
                @{ Name = 'lxterminal'; Style = 'exe' }
            )
            foreach ($term in $terminals) {
                $found = Get-Command -Name $term.Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $found) { continue }
                $launch = switch ($term.Style) {
                    'command' { @('-e', ((@($quotedExe) + $fileArgs) -join ' ')) }
                    'dashdash' { @('--') + @($exe) + $fileArgs }
                    default { @('-e', $exe) + $fileArgs }
                }
                Start-Process -FilePath ([string]$found.Source) -ArgumentList $launch
                $launcher = $term.Name
                break
            }
        }
        if (-not $launcher) {
            Start-Process -FilePath $exe -ArgumentList $fileArgs
            $launcher = '親コンソール'
        }
        Write-Log "LosslessCutを起動しました: $exe (コンソール: $launcher)"
        return $true
    }
    catch {
        if (-not $Quiet) { Write-Log "LosslessCutの起動に失敗しました: $_" -Level 'WARN' }
        return $false
    }
}
#endregion
