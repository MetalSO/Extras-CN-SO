<#
.SYNOPSIS
    Generate a Scoop manifest from a download URL.
.DESCRIPTION
    Takes a download URL (GitHub Releases supported best), derives version / app name / hash and
    description / homepage / license, optionally downloads the archive and inspects it to detect
    extract_dir / bin / shortcuts / WebView2 requirement, then writes bucket\<app>.json and
    normalises it with bin\formatjson.ps1.

    Messages are intentionally ASCII so the script behaves the same under Windows PowerShell 5.1
    and PowerShell 7 (a BOM-less UTF-8 file with non-ASCII text would be misread by 5.1).
.PARAMETER Url
    Download URL, e.g. https://github.com/owner/repo/releases/download/v1.0/app-1.0-win-x64.zip
.PARAMETER App
    Manifest / app name. Defaults to the GitHub repository name, or is derived from the file name.
.PARAMETER Version
    Version, without the leading "v". Defaults to the GitHub tag or is parsed from the file name.
.PARAMETER Description
    Override the auto-detected description.
.PARAMETER Homepage
    Override the auto-detected homepage.
.PARAMETER License
    Override the auto-detected SPDX license.
.PARAMETER ExtractDir
    Force an extract_dir (skips auto-detection).
.PARAMETER Bin
    Force the value of the "bin" field (relative path inside the install dir).
.PARAMETER ShortcutName
    Override the Start Menu shortcut display name.
.PARAMETER FromFile
    Use an already-downloaded local archive instead of fetching the URL (the URL is still used for url/version/checkver fields).
.PARAMETER Force
    Overwrite an existing bucket\<app>.json.
.PARAMETER DryRun
    Print the manifest instead of writing it.
.PARAMETER NoFormat
    Do not run formatjson.ps1 afterwards.
.EXAMPLE
    bin\new-manifest.ps1 "https://github.com/Fervent-Tempo/AF-Media-Bar/releases/download/v1.3.1/AFMediaBar-v1.3.1-win-x64.zip"
.EXAMPLE
    bin\new-manifest.ps1 "<url>" -App myapp -ShortcutName "My App" -Force
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Url,

    [string] $App,
    [string] $Version,
    [string] $Description,
    [string] $Homepage,
    [string] $License,
    [string] $ExtractDir,
    [string] $Bin,
    [string] $ShortcutName,
    [string] $FromFile,
    [switch] $WebView2,
    [switch] $Force,
    [switch] $DryRun,
    [switch] $NoFormat
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Script:BucketDir = Convert-Path (Join-Path $PSScriptRoot '..\bucket')
$Script:UserAgent = 'Scoop-Extras-CN/new-manifest'
$Script:WorkDir = $null

function Write-Note { param([string] $Message) Write-Host $Message -ForegroundColor DarkGray }
function Write-Warn2 { param([string] $Message) Write-Host "WARN  $Message" -ForegroundColor DarkYellow }
function Write-Fail { param([string] $Message) Write-Host "ERROR $Message" -ForegroundColor DarkRed; exit 1 }

function Show-Usage {
    Write-Host @'
Usage:
  bin\new-manifest.ps1 <download-url> [-App name] [-Version ver] [-Description text]
      [-Homepage url] [-License spdx] [-ExtractDir dir] [-Bin exe] [-ShortcutName name]
      [-FromFile path] [-WebView2] [-Force] [-DryRun] [-NoFormat]

Examples:
  bin\new-manifest.ps1 "https://github.com/Fervent-Tempo/AF-Media-Bar/releases/download/v1.3.1/AFMediaBar-v1.3.1-win-x64.zip"
  bin\new-manifest.ps1 "<url>" -App myapp -ShortcutName "My App" -Force
'@ -ForegroundColor Gray
}

if (-not $Url) { Show-Usage; exit 1 }

# ------------------------------------------------------------------ helpers

function Get-GitHubToken {
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    try {
        $t = (scoop config gh_token) 2>$null
        if ($t) { return [string]$t }
    } catch { }
    return $null
}

function Invoke-GitHubApi {
    param([string] $Path)
    $headers = @{ 'User-Agent' = $Script:UserAgent; 'Accept' = 'application/vnd.github+json' }
    $token = Get-GitHubToken
    if ($token) { $headers['Authorization'] = "token $token" }
    try {
        return Invoke-RestMethod -Uri ("https://api.github.com" + $Path) -Headers $headers -Method Get
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 403 -or $status -eq 429) {
            Write-Warn2 "GitHub API rate limit (HTTP $status). Set `$env:GITHUB_TOKEN to raise it."
        }
        throw
    }
}

function Get-SubsystemFromBytes {
    param([byte[]] $Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 0x40) { return $null }
    $peOffset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($peOffset -le 0 -or ($peOffset + 94) -gt $Bytes.Length) { return $null }
    if ([BitConverter]::ToUInt32($Bytes, $peOffset) -ne 0x00004550) { return $null }
    return [BitConverter]::ToUInt16($Bytes, $peOffset + 92)
}

function Get-ArchiveKind {
    param([string] $Path)
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 8
        $n = $fs.Read($buf, 0, 8)
        if ($n -lt 4) { return 'unknown' }
        if ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B) { return 'zip' }
        if ($buf[0] -eq 0x37 -and $buf[1] -eq 0x7A -and $buf[2] -eq 0xBC -and $buf[3] -eq 0xAF) { return '7z' }
        return 'unknown'
    } finally { $fs.Dispose() }
}

function Read-StreamBytes {
    param($Stream, [int] $Count)
    $buf = New-Object byte[] $Count
    $total = 0
    while ($total -lt $Count) {
        $read = $Stream.Read($buf, $total, $Count - $total)
        if ($read -le 0) { break }
        $total += $read
    }
    if ($total -eq $Count) { return $buf }
    $out = New-Object byte[] $total
    [Array]::Copy($buf, $out, $total)
    return $out
}

function Get-SevenZipPath {
    $cmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:SCOOP_HOME\apps\7zip\current\7z.exe", 'C:\Scoop\apps\7zip\current\7z.exe')) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    try {
        $prefix = (scoop prefix 7zip) 2>$null
        if ($prefix) { $p = Join-Path $prefix '7z.exe'; if (Test-Path $p) { return $p } }
    } catch { }
    return $null
}

function Select-MainExe {
    param([string[]] $RelativeExes, [string] $AppName)
    if (-not $RelativeExes -or $RelativeExes.Count -eq 0) { return $null }
    $want = ($AppName -replace '[^A-Za-z0-9]', '').ToLower()
    foreach ($x in $RelativeExes) {
        $b = ([IO.Path]::GetFileNameWithoutExtension($x) -replace '[^A-Za-z0-9]', '').ToLower()
        if ($b -eq $want) { return $x }
    }
    foreach ($x in $RelativeExes) {
        $b = ([IO.Path]::GetFileNameWithoutExtension($x) -replace '[^A-Za-z0-9]', '').ToLower()
        if ($b.StartsWith($want) -or ($want.Length -ge 4 -and $want.StartsWith($b))) { return $x }
    }
    return ($RelativeExes | Sort-Object @{ Expression = { $_.Split('/').Count } }, @{ Expression = { $_.Length } } | Select-Object -First 1)
}

function Get-CandidateExes {
    # Drop helper binaries inside "$PLUGINSDIR"/"$R0" and uninstallers, as long as a real
    # application binary remains.
    param([string[]] $RelativePaths)
    $all = @($RelativePaths | Where-Object { $_ -match '(?i)\.exe$' })
    $clean = @($all | Where-Object {
            $_ -notmatch '(?i)(^|/)\$(PLUGINSDIR|R0|TEMP)/' -and
            ([IO.Path]::GetFileName($_) -notmatch '(?i)^uninstall')
        })
    if ($clean.Count -gt 0) { return $clean }
    return $all
}

function Get-WindowsAssetArch {
    param([string] $Name)
    if ($Name -match '(?i)(arm64|aarch64)') { return 'arm64' }
    if ($Name -match '(?i)(x86_64|amd64|x64)') { return '64bit' }
    if ($Name -match '(?i)(i686|i386|win32|x86)') { return '32bit' }
    return $null
}

function Remove-ArchToken {
    param([string] $Name)
    return ($Name -replace '(?i)(arm64|aarch64|x86_64|amd64|x64|i686|i386|win32|x86)', '')
}

function Get-InnerArchiveForArch {
    # "app-64.7z" -> arm64 => "app-arm64.7z"
    param([string] $InnerArchive, [string] $Arch)
    $token = switch ($Arch) { 'arm64' { 'arm64' } '32bit' { '32' } default { '64' } }
    return ($InnerArchive -replace '(?i)(arm64|64|32)(\.7z)$', ($token + '$2'))
}

function Inspect-ZipArchive {
    param([string] $Path, [string] $AppName)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @()
        foreach ($e in $zip.Entries) { if ($e.Name) { $names += ($e.FullName -replace '\\', '/') } }

        $extractDir = $null
        $tops = @($names | ForEach-Object { $_.Split('/')[0] } | Select-Object -Unique)
        if ($tops.Count -eq 1 -and $names.Count -gt 0) {
            $prefix = $tops[0] + '/'
            $allInside = $true
            foreach ($n in $names) { if (-not $n.StartsWith($prefix)) { $allInside = $false; break } }
            if ($allInside) { $extractDir = $tops[0] }
        }

        $rel = @()
        foreach ($n in $names) {
            if ($extractDir) { $rel += $n.Substring($extractDir.Length + 1) } else { $rel += $n }
        }
        $exes = Get-CandidateExes -RelativePaths $rel

        $main = Select-MainExe -RelativeExes $exes -AppName $AppName

        $subsystem = $null
        if ($main) {
            $full = $main
            if ($extractDir) { $full = $extractDir + '/' + $main }
            $entry = $zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq $full } | Select-Object -First 1
            if ($entry -and $entry.Length -gt 0) {
                $take = [int][Math]::Min($entry.Length, 8192)
                $stream = $entry.Open()
                try { $bytes = Read-StreamBytes -Stream $stream -Count $take } finally { $stream.Dispose() }
                $subsystem = Get-SubsystemFromBytes -Bytes $bytes
            }
        }

        $webview2 = @($names | Where-Object { $_ -match '(?i)WebView2Loader\.dll$' }).Count -gt 0

        return @{
            ExtractDir = $extractDir
            ExeFiles   = $exes
            MainExe    = $main
            Subsystem  = $subsystem
            WebView2   = $webview2
        }
    } finally { $zip.Dispose() }
}

function Inspect-SevenZipArchive {
    param([string] $Path, [string] $AppName)
    $sevenZip = Get-SevenZipPath
    if (-not $sevenZip) {
        Write-Warn2 '7z.exe not found - skipping archive inspection for .7z input.'
        return $null
    }
    $raw = & $sevenZip l -slt -- $Path 2>$null
    $names = @()
    $selfPath = $Path -replace '\\', '/'
    foreach ($line in $raw) {
        if ($line -match '^Path = (.+)$') {
            $p = $Matches[1].Trim() -replace '\\', '/'
            if ($p -and $p -ne $selfPath) { $names += $p }
        }
    }
    $names = @($names | Where-Object { $_ })
    if ($names.Count -eq 0) { return $null }

    # NSIS / electron-builder installers keep the real payload in an inner archive such as
    # "$PLUGINSDIR/app-64.7z". 7-Zip can list the outer .exe and reveal it.
    $innerArchive = $names | Where-Object { $_ -match '(?i)^\$PLUGINSDIR/.+\.7z$' } | Select-Object -First 1

    $extractDir = $null
    $tops = @($names | ForEach-Object { $_.Split('/')[0] } | Select-Object -Unique)
    if ($tops.Count -eq 1 -and $names.Count -gt 0) {
        $prefix = $tops[0] + '/'
        $allInside = $true
        foreach ($n in $names) { if (-not $n.StartsWith($prefix)) { $allInside = $false; break } }
        if ($allInside) { $extractDir = $tops[0] }
    }

    $rel = @()
    foreach ($n in $names) {
        if ($extractDir) { $rel += $n.Substring($extractDir.Length + 1) } else { $rel += $n }
    }
    $exes = Get-CandidateExes -RelativePaths $rel
    $main = Select-MainExe -RelativeExes $exes -AppName $AppName

    $subsystem = $null
    if ($main) {
        $inner = $main
        if ($extractDir) { $inner = $extractDir + '/' + $main }
        $outDir = Join-Path $Script:WorkDir 'exeprobe'
        $null = New-Item -ItemType Directory -Path $outDir -Force
        & $sevenZip e -y ("-o" + $outDir) -- $Path $inner 2>$null | Out-Null
        $probe = Join-Path $outDir ([IO.Path]::GetFileName($main))
        if (Test-Path $probe) {
            $fs = [IO.File]::OpenRead($probe)
            try {
                $take = [int][Math]::Min($fs.Length, 8192)
                $bytes = Read-StreamBytes -Stream $fs -Count $take
            } finally { $fs.Dispose() }
            $subsystem = Get-SubsystemFromBytes -Bytes $bytes
        }
    }

    $webview2 = @($names | Where-Object { $_ -match '(?i)WebView2Loader\.dll$' }).Count -gt 0

    return @{
        ExtractDir = $extractDir
        ExeFiles   = $exes
        MainExe    = $main
        Subsystem  = $subsystem
        WebView2   = $webview2
        InnerArchive = $innerArchive
    }
}

function ConvertTo-AutoupdateUrl {
    param([string] $OriginalUrl, [string] $Tag, [string] $Version)
    $result = $OriginalUrl
    # Replace the bare version FIRST: a tag like "v1.3.1" then becomes "v$version", and a file
    # name like "app-1.3.1-win-x64.zip" becomes "app-$version-win-x64.zip". Replacing the whole
    # tag would drop the leading "v".
    if ($Version) { $result = $result -replace [regex]::Escape($Version), '$$version' }
    if ($Tag -and ($result -match [regex]::Escape($Tag))) {
        # Unusual tag that does not embed the bare version (e.g. "latest") - replace it verbatim.
        $result = $result -replace [regex]::Escape($Tag), '$$version'
    }
    return $result
}

# ------------------------------------------------------------------ 1. parse URL

try { $uri = [Uri]$Url } catch { Write-Fail "Not a valid URL: $Url" }

$gh = $null
$segments = $uri.AbsolutePath.Trim('/').Split('/')
if ($uri.Host -eq 'github.com' -and $segments.Count -ge 6 -and $segments[2] -eq 'releases' -and $segments[3] -eq 'download') {
    $gh = @{ Owner = $segments[0]; Repo = $segments[1]; Tag = $segments[4]; Asset = $segments[5] }
    Write-Note "GitHub release detected: $($gh.Owner)/$($gh.Repo) @ $($gh.Tag)"
} else {
    Write-Warn2 'Not a GitHub release URL - version/hash may be less accurate and checkver/autoupdate will be skipped.'
}

# ------------------------------------------------------------------ 2. version

if (-not $Version) {
    if ($gh -and $gh.Tag) {
        $Version = $gh.Tag -replace '^[vV]', ''
    } else {
        $stemName = [IO.Path]::GetFileNameWithoutExtension($uri.Segments[-1])
        $m = [regex]::Match($stemName, '(\d+\.\d+(?:\.\d+)*)')
        if ($m.Success) { $Version = $m.Groups[1].Value }
    }
}
if (-not $Version) { Write-Fail 'Could not derive a version. Pass -Version explicitly.' }
Write-Note "version = $Version"

# ------------------------------------------------------------------ 3. app name

if (-not $App) {
    if ($gh) {
        $App = $gh.Repo
    } else {
        $App = [IO.Path]::GetFileNameWithoutExtension($uri.Segments[-1])
        if ($Version) { $App = $App -replace [regex]::Escape($Version), '' }
        $App = $App -replace '(?i)[-_.]?(windows|win|linux|darwin|osx|macos|x64|amd64|x86|arm64|win64|portable|setup|installer)[-_.]?', '-'
        $App = $App.Trim('-_. ')
    }
}
if (-not $App) { Write-Fail 'Could not derive an app name. Pass -App explicitly.' }
Write-Note "app     = $App"

$manifestPath = Join-Path $Script:BucketDir ($App + '.json')
if ((Test-Path $manifestPath) -and -not $Force -and -not $DryRun) {
    Write-Fail "Manifest already exists: $manifestPath  (use -Force to overwrite, or -DryRun to preview)."
}

# ------------------------------------------------------------------ 4. GitHub metadata + hash digest

$repoMeta = $null
$apiHash = $null
if ($gh) {
    try {
        $repoMeta = Invoke-GitHubApi "/repos/$($gh.Owner)/$($gh.Repo)"
    } catch {
        Write-Warn2 "Could not read repository metadata: $($_.Exception.Message)"
    }
    try {
        $release = Invoke-GitHubApi "/repos/$($gh.Owner)/$($gh.Repo)/releases/tags/$($gh.Tag)"
        $asset = $release.assets | Where-Object { $_.name -eq $gh.Asset -or $_.browser_download_url -eq $Url } | Select-Object -First 1
        if ($asset) {
            $Script:AssetId = $asset.id
            if ($asset.digest -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
                $apiHash = $Matches[1].ToLower()
                Write-Note "hash from GitHub digest: $apiHash"
            }
        } else {
            Write-Warn2 "Release '$($gh.Tag)' has no asset named '$($gh.Asset)' - it may have been removed upstream."
        }
    } catch {
        Write-Warn2 "Could not read release metadata: $($_.Exception.Message)"
    }
}

if (-not $Description -and $repoMeta -and $repoMeta.description) {
    # \u3002 is the CJK full stop. Kept as an escape so the script stays pure ASCII and therefore
    # is read identically by Windows PowerShell 5.1 (which treats a BOM-less UTF-8 file as ANSI).
    $Description = ($repoMeta.description -split '\||\u3002|\r?\n')[0].Trim()
}
if (-not $Homepage -and $repoMeta) {
    if ($repoMeta.homepage) { $Homepage = $repoMeta.homepage } else { $Homepage = $repoMeta.html_url }
}
if (-not $License -and $repoMeta -and $repoMeta.license -and $repoMeta.license.spdx_id) {
    $License = $repoMeta.license.spdx_id
}
if (-not $Description) { $Description = $App; Write-Warn2 "No description found - defaulted to '$App' (-Description to override)." }
if (-not $Homepage -and $gh) { $Homepage = "https://github.com/$($gh.Owner)/$($gh.Repo)" }
if (-not $Homepage) { $Homepage = "$($uri.Scheme)://$($uri.Host)" }
if (-not $License) { $License = 'Unknown'; Write-Warn2 'No license detected - set to "Unknown" (-License to override).' }

# ------------------------------------------------------------------ 5. download + inspect

$Script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('newmanifest-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Script:WorkDir -Force

$hash = $apiHash
$inspection = $null

try {
    $fileName = [IO.Path]::GetFileName($uri.LocalPath)
    if (-not $fileName) { $fileName = 'download.bin' }
    $localFile = Join-Path $Script:WorkDir $fileName

    $downloaded = $false
    if ($FromFile) {
        if (-not (Test-Path -LiteralPath $FromFile)) { Write-Fail "File not found: $FromFile" }
        Copy-Item -LiteralPath $FromFile -Destination $localFile -Force
        $downloaded = $true
        Write-Note "Using local file (no download): $FromFile"
    } else {
        Write-Note "Downloading $Url"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $localFile -UseBasicParsing -Headers @{ 'User-Agent' = $Script:UserAgent }
            $downloaded = $true
        } catch {
            Write-Warn2 "Direct download failed: $($_.Exception.Message)"
        }
    }

    if (-not $downloaded -and $gh -and $Script:AssetId) {
        Write-Note 'Retrying via the GitHub API asset endpoint...'
        try {
            $dlHeaders = @{ 'User-Agent' = $Script:UserAgent; 'Accept' = 'application/octet-stream' }
            $token = Get-GitHubToken
            if ($token) { $dlHeaders['Authorization'] = "token $token" }
            $assetUri = "https://api.github.com/repos/$($gh.Owner)/$($gh.Repo)/releases/assets/$($Script:AssetId)"
            Invoke-WebRequest -Uri $assetUri -OutFile $localFile -UseBasicParsing -Headers $dlHeaders
            $downloaded = $true
        } catch {
            Write-Warn2 "API download failed: $($_.Exception.Message)"
        }
    }

    if (-not $downloaded -and $gh -and -not $repoMeta) {
        Write-Warn2 "Repository '$($gh.Owner)/$($gh.Repo)' could not be read (404) - it may have been deleted or renamed."
    }

    if ($downloaded) {
        if (-not $hash) {
            $hash = (Get-FileHash -Path $localFile -Algorithm SHA256).Hash.ToLower()
            Write-Note "hash computed from download: $hash"
        } else {
            $localHash = (Get-FileHash -Path $localFile -Algorithm SHA256).Hash.ToLower()
            if ($localHash -ne $hash) {
                Write-Warn2 "Local SHA256 ($localHash) differs from GitHub digest ($hash). Using the downloaded file."
                $hash = $localHash
            }
        }

        $kind = Get-ArchiveKind -Path $localFile
        Write-Note "Archive kind: $kind"
        if ($kind -eq 'zip') {
            $inspection = Inspect-ZipArchive -Path $localFile -AppName $App
        } else {
            # .7z, or an .exe that 7-Zip can read (NSIS / electron-builder installers).
            $inspection = Inspect-SevenZipArchive -Path $localFile -AppName $App
            if (-not $inspection) {
                Write-Warn2 'Not a zip/7z/NSIS archive - skipping extract_dir/bin/shortcuts detection (other installer formats need a custom installer block).'
            }
        }
    }

    if (-not $hash) { Write-Fail 'Could not obtain a SHA256 hash (download failed and no GitHub digest available).' }

    # -------------------------------------------------------------- 5b. installer payload + sibling architectures

    $sevenZipReadable = ($null -ne $inspection)
    $installerInnerName = $null
    $installerScript = $null
    if ($inspection -and $inspection.InnerArchive) {
        $installerInnerName = [IO.Path]::GetFileName($inspection.InnerArchive)
        $sevenZip = Get-SevenZipPath
        $innerDir = Join-Path $Script:WorkDir 'inner'
        $null = New-Item -ItemType Directory -Path $innerDir -Force
        if ($sevenZip) {
            # "e" flattens paths: "x" would keep the "$PLUGINSDIR" prefix.
            & $sevenZip e -y ("-o" + $innerDir) -- $localFile ($inspection.InnerArchive -replace '/', '\') 2>$null | Out-Null
            $innerFile = Join-Path $innerDir $installerInnerName
            if (-not (Test-Path $innerFile)) {
                $innerFile = Get-ChildItem -Path $innerDir -Recurse -Filter $installerInnerName -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty FullName
            }
            if ($innerFile -and (Test-Path $innerFile)) {
                $innerInspection = Inspect-SevenZipArchive -Path $innerFile -AppName $App
                if ($innerInspection) { $inspection = $innerInspection }
                Write-Note "Installer payload inspected: $installerInnerName"
            } else {
                Write-Warn2 "Could not extract the inner archive '$installerInnerName' - bin/shortcuts left empty."
                $inspection = $null
            }
        } else {
            $inspection = $null
        }
        $installerScript = '7z x $original_dir/`$PLUGINSDIR/' + $installerInnerName + ' -o"$original_dir"'
    }

    # An .exe that 7-Zip can read is an (NSIS) installer payload: Scoop must extract it instead
    # of running it, so the URL needs the "#/dl.7z" suffix.
    $treatAsArchive = ($uri.AbsolutePath -match '(?i)\.exe$') -and $sevenZipReadable

    $primaryArch = '64bit'
    if ($gh -and $gh.Asset) {
        $detected = Get-WindowsAssetArch -Name $gh.Asset
        if ($detected) { $primaryArch = $detected }
    }

    $siblingArchs = @()
    if ($gh -and $release) {
        $stem = Remove-ArchToken -Name $gh.Asset
        foreach ($a in $release.assets) {
            if ($a.name -eq $gh.Asset) { continue }
            if ($a.name -notmatch '(?i)\.exe$') { continue }
            if ((Remove-ArchToken -Name $a.name) -ne $stem) { continue }
            $sibArch = Get-WindowsAssetArch -Name $a.name
            if (-not $sibArch -or $sibArch -eq $primaryArch) { continue }
            if (-not ($a.digest -and $a.digest -match '^sha256:([0-9a-fA-F]{64})$')) { continue }
            $sibHash = $Matches[1].ToLower()
            $sibUrl = $a.browser_download_url
            if ($sibUrl -notmatch '#') { $sibUrl = $sibUrl + '#/dl.7z' }
            $siblingArchs += [ordered]@{ Arch = $sibArch; Url = $sibUrl; Hash = $sibHash; Asset = $a.name }
            Write-Note "Sibling architecture added: $sibArch ($($a.name), hash from GitHub digest)"
        }
    }

    # -------------------------------------------------------------- 6. derived fields

    if ($inspection) {
        if (-not $ExtractDir -and $inspection.ExtractDir) { $ExtractDir = $inspection.ExtractDir }

        if (-not $Bin -and $inspection.MainExe) {
            $sub = $inspection.Subsystem
            if ($sub -eq 3) {
                $Bin = $inspection.MainExe -replace '/', '\'
            } elseif ($null -eq $sub -and $inspection.ExeFiles.Count -gt 1) {
                Write-Note ("Console/GUI unclear; exe candidates: " + ($inspection.ExeFiles -join ', '))
            }
        }
    }

    $shortcutEntry = $null
    if ($inspection -and $inspection.MainExe) {
        $isGui = ($inspection.Subsystem -ne 3)
        if ($isGui -and -not $Bin) {
            if (-not $ShortcutName) { $ShortcutName = ($App -replace '[-_]', ' ') }
            $shortcutEntry = @(($inspection.MainExe -replace '/', '\'), $ShortcutName)
        }
    }

    # -------------------------------------------------------------- 7. checkver / autoupdate

    $autoExtractDir = $null
    if ($gh) {
        if ($ExtractDir -and $ExtractDir -match [regex]::Escape($Version)) {
            $autoExtractDir = $ExtractDir -replace [regex]::Escape($Version), '$$version'
        }
    }

    # -------------------------------------------------------------- 8. build manifest

    $primaryUrl = $Url
    if ($treatAsArchive -and $primaryUrl -notmatch '#') { $primaryUrl = $primaryUrl + '#/dl.7z' }

    $primaryEntry = [ordered]@{ 'url' = $primaryUrl; 'hash' = $hash }
    if ($installerScript) { $primaryEntry['installer'] = [ordered]@{ 'script' = $installerScript } }

    $architecture = [ordered]@{}
    $architecture[$primaryArch] = $primaryEntry
    foreach ($sib in $siblingArchs) {
        $sibEntry = [ordered]@{ 'url' = $sib.Url; 'hash' = $sib.Hash }
        if ($installerScript) {
            $sibInner = Get-InnerArchiveForArch -InnerArchive $installerInnerName -Arch $sib.Arch
            $sibScript = '7z x $original_dir/`$PLUGINSDIR/' + $sibInner + ' -o"$original_dir"'
            $sibEntry['installer'] = [ordered]@{ 'script' = $sibScript }
        }
        $architecture[$sib.Arch] = $sibEntry
    }

    $manifest = [ordered]@{}
    $manifest['version'] = $Version
    $manifest['description'] = $Description
    $manifest['homepage'] = $Homepage
    $manifest['license'] = $License
    $manifest['architecture'] = $architecture
    if ($ExtractDir) { $manifest['extract_dir'] = $ExtractDir }
    if ($Bin) { $manifest['bin'] = $Bin }
    if ($shortcutEntry) {
        $shortcuts = @()
        $shortcuts += , $shortcutEntry
        $manifest['shortcuts'] = $shortcuts
    }
    if ($WebView2 -or ($inspection -and $inspection.WebView2)) {
        $manifest['suggest'] = [ordered]@{ 'Microsoft Edge WebView2' = 'extras/webview2' }
    }
    if ($gh) {
        $manifest['checkver'] = [ordered]@{ 'github' = "https://github.com/$($gh.Owner)/$($gh.Repo)" }
        $autoArch = [ordered]@{}
        $autoArch[$primaryArch] = [ordered]@{ 'url' = (ConvertTo-AutoupdateUrl -OriginalUrl $primaryUrl -Tag $gh.Tag -Version $Version) }
        foreach ($sib in $siblingArchs) {
            $autoArch[$sib.Arch] = [ordered]@{ 'url' = (ConvertTo-AutoupdateUrl -OriginalUrl $sib.Url -Tag $gh.Tag -Version $Version) }
        }
        $autoupdate = [ordered]@{ 'architecture' = $autoArch }
        if ($autoExtractDir) { $autoupdate['extract_dir'] = $autoExtractDir }
        $manifest['autoupdate'] = $autoupdate
    }

    $json = $manifest | ConvertTo-Json -Depth 10

    # -------------------------------------------------------------- 9. write

    if ($DryRun) {
        Write-Host ''
        Write-Host "----- $App.json (dry run) -----" -ForegroundColor Cyan
        Write-Host $json
        Write-Host ''
        Write-Note 'Dry run: nothing was written.'
    } else {
        [IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object Text.UTF8Encoding $false))
        Write-Host "Written: $manifestPath" -ForegroundColor Green

        if (-not $NoFormat) {
            try {
                & (Join-Path $PSScriptRoot 'formatjson.ps1') -App $App
            } catch {
                Write-Warn2 "formatjson.ps1 failed: $($_.Exception.Message)"
            }
        }

        Write-Note 'Next: bin\checkurls.ps1 and bin\test.ps1 to validate.'
    }
} finally {
    if ($Script:WorkDir -and (Test-Path $Script:WorkDir)) {
        Remove-Item -Path $Script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
