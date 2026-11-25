<#
.SYNOPSIS
    GitSession — Ephemeral Git Workspace Manager (v2.0)
    PowerShell Engine for Windows CMD

.DESCRIPTION
    High-performance terminal workspace manager for Git & GitHub CLI.
    Features:
    - Strict authentication isolation (GH_CONFIG_DIR) separate from global gh keyring.
    - Auto-discovery & normalization of local repositories (protected vs ephemeral tiers).
    - Workspace Sync Matrix (Scan, Fetch --all --prune, Smart Pull, Commit & Push).
    - Interactive Local Repo Manager (Diff preview, Branch switcher, Terminal/IDE launch).
    - Paginated GitHub repository browser (>100 repos), search, sorting, and resilient cloning.
    - Persistent & optional portable settings.json configuration UI.
    - Safe cleanup engine (path containment, reparse/junction safety, locked-file retry).
#>

[CmdletBinding()]
param(
    [string]$Workspace = "",
    [string]$DefaultWorkspace = "",
    [string]$Action = ""
)

# -----------------------------------------------------------------------------
# Terminal & Console Encoding
# -----------------------------------------------------------------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ANSI Color & Style Escape Codes
$ESC       = [char]27
$C_RESET   = "$ESC[0m"
$C_BOLD    = "$ESC[1m"
$C_DIM     = "$ESC[2m"
$C_CYAN    = "$ESC[96m"
$C_GREEN   = "$ESC[92m"
$C_YELLOW  = "$ESC[93m"
$C_RED     = "$ESC[91m"
$C_GRAY    = "$ESC[90m"
$C_WHITE   = "$ESC[97m"
$C_MAGENTA = "$ESC[95m"

function Write-Cyan    { param([string]$Text, [switch]$NoNewline) Write-Host "$C_CYAN$Text$C_RESET" -NoNewline:$NoNewline }
function Write-Green   { param([string]$Text, [switch]$NoNewline) Write-Host "$C_GREEN$Text$C_RESET" -NoNewline:$NoNewline }
function Write-Yellow  { param([string]$Text, [switch]$NoNewline) Write-Host "$C_YELLOW$Text$C_RESET" -NoNewline:$NoNewline }
function Write-Red     { param([string]$Text, [switch]$NoNewline) Write-Host "$C_RED$Text$C_RESET" -NoNewline:$NoNewline }
function Write-Gray    { param([string]$Text, [switch]$NoNewline) Write-Host "$C_GRAY$Text$C_RESET" -NoNewline:$NoNewline }
function Write-Bold    { param([string]$Text, [switch]$NoNewline) Write-Host "$C_BOLD$Text$C_RESET" -NoNewline:$NoNewline }
function Write-Magenta { param([string]$Text, [switch]$NoNewline) Write-Host "$C_MAGENTA$Text$C_RESET" -NoNewline:$NoNewline }

$script:InputEof = $false

function Read-SafeInput {
    param([string]$Prompt = "")
    if ([Console]::IsInputRedirected) {
        if (-not [string]::IsNullOrEmpty($Prompt)) {
            Write-Host "${Prompt}: " -NoNewline
        }
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) {
            $script:InputEof = $true
            return ""
        }
        return $line.Trim()
    } else {
        if ([string]::IsNullOrEmpty($Prompt)) {
            $raw = Read-Host
        } else {
            $raw = Read-Host $Prompt
        }
        if ($null -eq $raw) { return "" }
        return $raw.Trim()
    }
}

function Pause-Console {
    param([string]$Message = "Press any key to continue...")
    Write-Host ""
    Write-Host "$C_GRAY$Message$C_RESET" -NoNewline
    try {
        if ([Console]::IsInputRedirected) {
            $null = [Console]::In.ReadLine()
        } else {
            $null = [Console]::ReadKey($true)
        }
    } catch {
        Start-Sleep -Milliseconds 400
    }
    Write-Host ""
}

function Format-Truncated {
    param(
        [string]$Text,
        [int]$MaxWidth = 24
    )
    if ([string]::IsNullOrEmpty($Text)) { return "".PadRight($MaxWidth) }
    if ($Text.Length -le $MaxWidth) { return $Text.PadRight($MaxWidth) }
    if ($MaxWidth -le 3) { return $Text.Substring(0, $MaxWidth) }
    return ($Text.Substring(0, $MaxWidth - 3) + "...").PadRight($MaxWidth)
}

function Resolve-CanonicalPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    try {
        return ([System.IO.Path]::GetFullPath($PathValue).TrimEnd('\', '/'))
    } catch {
        return $PathValue.TrimEnd('\', '/')
    }
}

function Test-IsChildOfWorkspace {
    param(
        [string]$CandidatePath,
        [string]$WorkspaceRoot
    )
    $resolvedCandidate = Resolve-CanonicalPath $CandidatePath
    $resolvedRoot = Resolve-CanonicalPath $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($resolvedCandidate) -or [string]::IsNullOrWhiteSpace($resolvedRoot)) {
        return $false
    }
    return $resolvedCandidate.StartsWith($resolvedRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-NormalizedRepoSlug {
    param([string]$RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return "" }
    $clean = $RemoteUrl.Trim()
    # Match HTTPS or SSH GitHub URLs -> canonical "owner/repo"
    if ($clean -match '(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$') {
        return "$($matches[1])/$($matches[2])"
    }
    return $clean
}

# -----------------------------------------------------------------------------
# Directory Paths & Environment Initialization
# -----------------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    if ($MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $ScriptDir = (Get-Location).Path
    }
}

$ConfigDir          = Join-Path $env:LOCALAPPDATA "GitSession"
$IsolatedGhDir      = Join-Path $ConfigDir "gh"
$DataDir            = Join-Path $ConfigDir "data"
$TempDir            = Join-Path $ConfigDir "temp"
$ManifestPath         = Join-Path $DataDir "manifest.json"
$LocalSettingsPath    = Join-Path $DataDir "settings.json"
$PortableSettingsPath = Join-Path $ScriptDir "settings.json"

if ([string]::IsNullOrWhiteSpace($DefaultWorkspace)) {
    $DefaultWorkspace = Join-Path $env:USERPROFILE "GitSession-Workspace"
}

@($ConfigDir, $IsolatedGhDir, $DataDir, $TempDir) | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# Force isolated GitHub CLI configuration for all subsequent gh calls
$env:GH_CONFIG_DIR = $IsolatedGhDir

# In-memory session caches
$script:CachedRepoList   = @()
$script:CachedRepoUser   = ""
$script:LastSyncTime     = $null
$script:LastDiscoveryMsg = ""

# -----------------------------------------------------------------------------
# Settings Management (AppData & Optional Portable Override)
# -----------------------------------------------------------------------------
function Get-DefaultSettings {
    return [PSCustomObject]@{
        version            = "2.0"
        workspacePath      = $DefaultWorkspace
        autoScanOnStartup  = $true
        autoFetchOnSync    = $false
        scanDepth          = 1
        defaultAdoptedMode = "persistent"
        cloneMode          = "full"
        httpPostBufferMB   = 500
        pullStrategy       = "ff-only"
        pageSize           = 8
        preferredEditor    = "auto"
        preferredTerminal  = "auto"
        showDescriptions   = $true
        ignoredFolders     = @("GitSession", "scratch", "node_modules", ".vs", ".venv")
    }
}

function Get-ActiveSettingsPath {
    if (Test-Path -LiteralPath $PortableSettingsPath) {
        return $PortableSettingsPath
    }
    return $LocalSettingsPath
}

function Get-Settings {
    $defaults = Get-DefaultSettings
    $path = Get-ActiveSettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $loaded = ConvertFrom-Json $raw
        foreach ($prop in $defaults.PSObject.Properties) {
            $name = $prop.Name
            if (-not ($loaded.PSObject.Properties[$name])) {
                $loaded | Add-Member -MemberType NoteProperty -Name $name -Value $prop.Value
            }
        }
        $loaded.ignoredFolders = @($loaded.ignoredFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ([string]::IsNullOrWhiteSpace($loaded.workspacePath)) {
            $loaded.workspacePath = $DefaultWorkspace
        }
        return $loaded
    } catch {
        return $defaults
    }
}

function Save-Settings {
    param(
        [PSCustomObject]$SettingsObj,
        [string]$TargetPath = ""
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        $TargetPath = Get-ActiveSettingsPath
    }
    $parent = Split-Path -Parent $TargetPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $SettingsObj -Depth 10
    Set-Content -LiteralPath $TargetPath -Value $json -Encoding UTF8 -Force
}

$script:Settings = Get-Settings

function Set-ActiveWorkspace {
    param([string]$TargetPath)
    $resolved = Resolve-CanonicalPath $TargetPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = Resolve-CanonicalPath $DefaultWorkspace
    }
    if (-not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }
    $script:Workspace = $resolved
    if ($resolved -match '([^\\/]+[\\/][^\\/]+)$') {
        $script:WorkspaceDisplay = $matches[1]
    } else {
        $script:WorkspaceDisplay = $resolved
    }
}

# Resolve effective workspace (explicit CLI param > settings.json > DefaultWorkspace)
$initialWorkspace = if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    $Workspace
} elseif (-not [string]::IsNullOrWhiteSpace($script:Settings.workspacePath)) {
    $script:Settings.workspacePath
} else {
    $DefaultWorkspace
}
Set-ActiveWorkspace -TargetPath $initialWorkspace

# -----------------------------------------------------------------------------
# Manifest v2 & Dual-Tier Tracking (Ephemeral vs Protected/Persistent)
# -----------------------------------------------------------------------------
function Get-Manifest {
    $manifest = $null
    $needsSave = $false

    if (Test-Path -LiteralPath $ManifestPath) {
        try {
            $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
            $manifest = ConvertFrom-Json $raw
        } catch {
            $manifest = $null
        }
    }

    if ($null -eq $manifest) {
        $manifest = [PSCustomObject]@{
            version   = "2.0"
            accounts  = [PSCustomObject]@{}
            protected = @()
        }
        return $manifest
    }

    # Backwards-compatible v1 -> v2 schema migration
    if (-not ($manifest.PSObject.Properties["accounts"]) -or $null -eq $manifest.accounts) {
        $manifest | Add-Member -MemberType NoteProperty -Name "accounts" -Value ([PSCustomObject]@{}) -Force
        $needsSave = $true
    }
    if (-not ($manifest.PSObject.Properties["protected"]) -or $null -eq $manifest.protected) {
        $manifest | Add-Member -MemberType NoteProperty -Name "protected" -Value @() -Force
        $needsSave = $true
    }
    if ($manifest.version -ne "2.0") {
        $manifest.version = "2.0"
        $needsSave = $true
    }

    foreach ($acctProp in $manifest.accounts.PSObject.Properties) {
        $acctObj = $acctProp.Value
        if ($acctObj -and $acctObj.repositories) {
            foreach ($r in @($acctObj.repositories)) {
                if (-not ($r.PSObject.Properties["mode"]) -or [string]::IsNullOrWhiteSpace($r.mode)) {
                    $r | Add-Member -MemberType NoteProperty -Name "mode" -Value "ephemeral" -Force
                    $needsSave = $true
                }
            }
        }
    }

    $manifest.protected = @($manifest.protected)
    foreach ($p in $manifest.protected) {
        if (-not ($p.PSObject.Properties["mode"]) -or [string]::IsNullOrWhiteSpace($p.mode)) {
            $p | Add-Member -MemberType NoteProperty -Name "mode" -Value "persistent" -Force
            $needsSave = $true
        }
    }

    if ($needsSave) {
        Save-Manifest $manifest
    }

    return $manifest
}

function Save-Manifest {
    param([PSCustomObject]$Manifest)
    $json = ConvertTo-Json -InputObject $Manifest -Depth 10
    Set-Content -LiteralPath $ManifestPath -Value $json -Encoding UTF8 -Force
}

function Get-EphemeralRepos {
    param(
        [string]$Account,
        [switch]$CurrentWorkspaceOnly
    )
    if ([string]::IsNullOrWhiteSpace($Account)) { return @() }
    $manifest = Get-Manifest
    if (-not $manifest.accounts -or -not ($manifest.accounts.PSObject.Properties[$Account])) {
        return @()
    }

    $repos = @($manifest.accounts.$Account.repositories)
    $validRepos = @()
    $changed = $false

    foreach ($r in $repos) {
        if ($r.path -and (Test-Path -LiteralPath $r.path)) {
            if (-not ($r.PSObject.Properties["mode"])) {
                $r | Add-Member -MemberType NoteProperty -Name "mode" -Value "ephemeral" -Force
            } else {
                $r.mode = "ephemeral"
            }
            $validRepos += $r
        } else {
            $changed = $true
        }
    }

    if ($changed) {
        $manifest.accounts.$Account.repositories = @($validRepos)
        Save-Manifest $manifest
    }

    if ($CurrentWorkspaceOnly) {
        return @($validRepos | Where-Object { Test-IsChildOfWorkspace -CandidatePath $_.path -WorkspaceRoot $script:Workspace })
    }
    return $validRepos
}

function Get-ProtectedRepos {
    param([switch]$CurrentWorkspaceOnly)
    $manifest = Get-Manifest
    $repos = @($manifest.protected)
    $validRepos = @()
    $changed = $false

    foreach ($r in $repos) {
        if ($r.path -and (Test-Path -LiteralPath $r.path)) {
            if (-not ($r.PSObject.Properties["mode"])) {
                $r | Add-Member -MemberType NoteProperty -Name "mode" -Value "persistent" -Force
            } else {
                $r.mode = "persistent"
            }
            $validRepos += $r
        } else {
            $changed = $true
        }
    }

    if ($changed) {
        $manifest.protected = @($validRepos)
        Save-Manifest $manifest
    }

    if ($CurrentWorkspaceOnly) {
        return @($validRepos | Where-Object { Test-IsChildOfWorkspace -CandidatePath $_.path -WorkspaceRoot $script:Workspace })
    }
    return $validRepos
}

# Backwards-compatible alias for ephemeral managed repos
function Get-ManagedRepos {
    param([string]$Account)
    return @(Get-EphemeralRepos -Account $Account -CurrentWorkspaceOnly)
}

function Get-AllWorkspaceRepos {
    param([string]$Account)
    $ephemeral = @(Get-EphemeralRepos -Account $Account -CurrentWorkspaceOnly)
    $protected = @(Get-ProtectedRepos -CurrentWorkspaceOnly)

    $combined = @()
    $seenPaths = @{}

    foreach ($e in $ephemeral) {
        $key = (Resolve-CanonicalPath $e.path).ToLowerInvariant()
        if (-not $seenPaths.ContainsKey($key)) {
            $seenPaths[$key] = $true
            $combined += $e
        }
    }
    foreach ($p in $protected) {
        $key = (Resolve-CanonicalPath $p.path).ToLowerInvariant()
        if (-not $seenPaths.ContainsKey($key)) {
            $seenPaths[$key] = $true
            $combined += $p
        }
    }

    return @($combined | Sort-Object { $_.name.ToLowerInvariant() })
}

function Add-EphemeralRepo {
    param(
        [string]$Account,
        [PSCustomObject]$RepoInfo
    )
    if (-not ($RepoInfo.PSObject.Properties["mode"])) {
        $RepoInfo | Add-Member -MemberType NoteProperty -Name "mode" -Value "ephemeral" -Force
    } else {
        $RepoInfo.mode = "ephemeral"
    }

    $manifest = Get-Manifest
    if (-not ($manifest.accounts.PSObject.Properties[$Account])) {
        $manifest.accounts | Add-Member -MemberType NoteProperty -Name $Account -Value ([PSCustomObject]@{
            repositories = @()
        })
    }

    $canonNew = (Resolve-CanonicalPath $RepoInfo.path).ToLowerInvariant()
    # Ensure no duplicate entry in protected tier
    $manifest.protected = @($manifest.protected | Where-Object { (Resolve-CanonicalPath $_.path).ToLowerInvariant() -ne $canonNew })

    $existing = @($manifest.accounts.$Account.repositories | Where-Object { (Resolve-CanonicalPath $_.path).ToLowerInvariant() -ne $canonNew })
    $existing += $RepoInfo
    $manifest.accounts.$Account.repositories = @($existing)
    Save-Manifest $manifest
}

function Add-ManagedRepo {
    param(
        [string]$Account,
        [PSCustomObject]$RepoInfo
    )
    Add-EphemeralRepo -Account $Account -RepoInfo $RepoInfo
}

function Add-ProtectedRepo {
    param([PSCustomObject]$RepoInfo)
    if (-not ($RepoInfo.PSObject.Properties["mode"])) {
        $RepoInfo | Add-Member -MemberType NoteProperty -Name "mode" -Value "persistent" -Force
    } else {
        $RepoInfo.mode = "persistent"
    }

    $manifest = Get-Manifest
    $canonNew = (Resolve-CanonicalPath $RepoInfo.path).ToLowerInvariant()

    # Ensure not duplicated in account ephemeral lists
    foreach ($acctProp in $manifest.accounts.PSObject.Properties) {
        if ($acctProp.Value -and $acctProp.Value.repositories) {
            $acctProp.Value.repositories = @($acctProp.Value.repositories | Where-Object { (Resolve-CanonicalPath $_.path).ToLowerInvariant() -ne $canonNew })
        }
    }

    $existing = @($manifest.protected | Where-Object { (Resolve-CanonicalPath $_.path).ToLowerInvariant() -ne $canonNew })
    $existing += $RepoInfo
    $manifest.protected = @($existing)
    Save-Manifest $manifest
}

function Set-RepoMode {
    param(
        [string]$Account,
        [PSCustomObject]$RepoObj,
        [ValidateSet("ephemeral", "persistent")]
        [string]$TargetMode
    )
    $copy = [PSCustomObject]@{
        name          = $RepoObj.name
        nameWithOwner = $RepoObj.nameWithOwner
        path          = $RepoObj.path
        isPrivate     = [bool]$RepoObj.isPrivate
        mode          = $TargetMode
        clonedAt      = if ($RepoObj.clonedAt) { $RepoObj.clonedAt } else { (Get-Date).ToString("o") }
    }
    if ($TargetMode -eq "ephemeral") {
        Add-EphemeralRepo -Account $Account -RepoInfo $copy
    } else {
        Add-ProtectedRepo -RepoInfo $copy
    }
}

function Remove-ManagedRepo {
    param(
        [string]$Account,
        [string]$RepoName,
        [string]$RepoPath = ""
    )
    $manifest = Get-Manifest
    $canonTarget = if ($RepoPath) { (Resolve-CanonicalPath $RepoPath).ToLowerInvariant() } else { "" }

    if ($Account -and $manifest.accounts.PSObject.Properties[$Account]) {
        $manifest.accounts.$Account.repositories = @($manifest.accounts.$Account.repositories | Where-Object {
            if ($canonTarget) { (Resolve-CanonicalPath $_.path).ToLowerInvariant() -ne $canonTarget } else { $_.name -ne $RepoName }
        })
    }
    $manifest.protected = @($manifest.protected | Where-Object {
        if ($canonTarget) { (Resolve-CanonicalPath $_.path).ToLowerInvariant() -ne $canonTarget } else { $_.name -ne $RepoName }
    })
    Save-Manifest $manifest
}

function Clear-ManagedRepos {
    param([string]$Account)
    $manifest = Get-Manifest
    if ($manifest.accounts.PSObject.Properties[$Account]) {
        $manifest.accounts.$Account.repositories = @()
        Save-Manifest $manifest
    }
}

# -----------------------------------------------------------------------------
# Git Wrapper & Status Inspection Helpers
# -----------------------------------------------------------------------------
function Invoke-GitRepoCommand {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$GitArgs,
        [switch]$UseIsolatedAuth,
        [switch]$CaptureOutput
    )

    $prefixArgs = @("-C", $RepoPath)
    if ($UseIsolatedAuth) {
        $prefixArgs += @(
            "-c", "credential.https://github.com.helper=",
            "-c", "credential.https://github.com.helper=!gh auth git-credential"
        )
    }
    $allArgs = $prefixArgs + $GitArgs

    # Temporarily force Continue so PowerShell 5.1 stderr redirection (2>&1)
    # never triggers terminating NativeCommandError under caller Stop policies.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($CaptureOutput) {
            $out = & git @allArgs 2>&1
            $code = $LASTEXITCODE
            $str = (($out | ForEach-Object { "$_" }) -join "`n").Trim()
            return [PSCustomObject]@{
                ExitCode = $code
                Output   = $str
            }
        } else {
            & git @allArgs
            return $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-RepoPrimaryRemoteUrl {
    param([string]$RepoPath)
    $listRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("remote") -CaptureOutput
    if ($listRes.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($listRes.Output)) {
        return ""
    }
    $remotes = @($listRes.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remotes.Count -eq 0) { return "" }
    $preferred = if ($remotes -contains "origin") { "origin" } else { $remotes[0] }
    $remRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("remote", "get-url", $preferred) -CaptureOutput
    if ($remRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($remRes.Output)) {
        return $remRes.Output
    }
    return ""
}

function Get-RepoStatus {
    param([string]$RepoPath)

    $status = [PSCustomObject]@{
        Exists             = (Test-Path -LiteralPath $RepoPath)
        Branch             = "unknown"
        IsDetached         = $false
        IsShallow          = $false
        RemoteSlug         = ""
        RemoteUrl          = ""
        HasUncommitted     = $false
        UncommittedCount   = 0
        HasUntracked       = $false
        UntrackedCount     = 0
        HasUnpushed        = $false
        UnpushedCount      = 0
        BehindCount        = 0
        HasUpstream        = $false
        LastCommitHash     = ""
        LastCommitMessage  = ""
        LastCommitRelative = ""
    }

    if (-not $status.Exists -or -not (Test-Path -LiteralPath (Join-Path $RepoPath ".git"))) {
        return $status
    }

    # Current branch or detached commit hash
    $branchRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("branch", "--show-current") -CaptureOutput
    if ($branchRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($branchRes.Output)) {
        $status.Branch = $branchRes.Output
    } else {
        $headRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("rev-parse", "--short", "HEAD") -CaptureOutput
        if ($headRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($headRes.Output)) {
            $status.Branch = "detached@$($headRes.Output)"
            $status.IsDetached = $true
        }
    }

    # Remote origin info (with non-origin remote fallback)
    $primaryUrl = Get-RepoPrimaryRemoteUrl -RepoPath $RepoPath
    if (-not [string]::IsNullOrWhiteSpace($primaryUrl)) {
        $status.RemoteUrl = $primaryUrl
        $status.RemoteSlug = ConvertTo-NormalizedRepoSlug $primaryUrl
    }

    # Shallow check
    $shallowRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("rev-parse", "--is-shallow-repository") -CaptureOutput
    if ($shallowRes.ExitCode -eq 0 -and $shallowRes.Output -eq "true") {
        $status.IsShallow = $true
    }

    # Porcelain status
    $porcelainRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("status", "--porcelain") -CaptureOutput
    if ($porcelainRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($porcelainRes.Output)) {
        $lines = @($porcelainRes.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $untracked = @($lines | Where-Object { $_.StartsWith("??") })
        $uncommitted = @($lines | Where-Object { -not $_.StartsWith("??") })

        $status.UntrackedCount   = $untracked.Count
        $status.HasUntracked     = ($untracked.Count -gt 0)
        $status.UncommittedCount = $uncommitted.Count
        $status.HasUncommitted   = ($uncommitted.Count -gt 0)
    }

    # Upstream ahead/behind counts (single-quoted refspecs for PS parser safety)
    $upRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("rev-parse", "--abbrev-ref", '@{u}') -CaptureOutput
    if ($upRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($upRes.Output)) {
        $status.HasUpstream = $true
        $aheadRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("rev-list", "--count", '@{u}..HEAD') -CaptureOutput
        if ($aheadRes.ExitCode -eq 0 -and $aheadRes.Output -match '^\d+$') {
            $status.UnpushedCount = [int]$aheadRes.Output
            $status.HasUnpushed = ($status.UnpushedCount -gt 0)
        }
        $behindRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("rev-list", "--count", 'HEAD..@{u}') -CaptureOutput
        if ($behindRes.ExitCode -eq 0 -and $behindRes.Output -match '^\d+$') {
            $status.BehindCount = [int]$behindRes.Output
        }
    }

    # Last commit info
    $logRes = Invoke-GitRepoCommand -RepoPath $RepoPath -GitArgs @("log", "-1", "--format=%h|%s|%cr") -CaptureOutput
    if ($logRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($logRes.Output)) {
        $parts = $logRes.Output -split '\|', 3
        if ($parts.Count -ge 3) {
            $status.LastCommitHash     = $parts[0]
            $status.LastCommitMessage  = $parts[1]
            $status.LastCommitRelative = $parts[2]
        }
    }

    return $status
}

# -----------------------------------------------------------------------------
# Workspace Auto-Discovery Engine (Resolves Undetected Local Repos)
# -----------------------------------------------------------------------------
function Find-GitDirectoriesInWorkspace {
    param(
        [string]$RootPath,
        [int]$MaxDepth = 1,
        [string[]]$IgnoredNames = @("GitSession", "scratch")
    )

    $found = @()
    $ignoredSet = @{}
    foreach ($ig in $IgnoredNames) {
        if (-not [string]::IsNullOrWhiteSpace($ig)) {
            $ignoredSet[$ig.ToLowerInvariant()] = $true
        }
    }
    $canonScriptDir = (Resolve-CanonicalPath $ScriptDir).ToLowerInvariant()

    function Scan-Dir {
        param([string]$Dir, [int]$Depth)
        if ($Depth -gt $MaxDepth) { return }

        $children = @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $nameLower = $child.Name.ToLowerInvariant()
            if ($nameLower -eq ".git" -or $ignoredSet.ContainsKey($nameLower)) { continue }

            $canonChild = (Resolve-CanonicalPath $child.FullName).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($canonScriptDir) -and $canonChild -eq $canonScriptDir) { continue }

            $gitMarker = Join-Path $child.FullName ".git"
            if (Test-Path -LiteralPath $gitMarker) {
                $script:__discoveredGitDirs += $child.FullName
            } elseif ($Depth -lt $MaxDepth) {
                Scan-Dir -Dir $child.FullName -Depth ($Depth + 1)
            }
        }
    }

    $script:__discoveredGitDirs = @()
    if (Test-Path -LiteralPath $RootPath) {
        Scan-Dir -Dir $RootPath -Depth 1
    }
    $found = @($script:__discoveredGitDirs)
    Remove-Variable -Name __discoveredGitDirs -Scope Script -ErrorAction SilentlyContinue
    return $found
}

function Invoke-WorkspaceDiscovery {
    param(
        [string]$Account,
        [switch]$InteractiveAsk
    )

    $manifest = Get-Manifest

    # Index canonical paths already known in manifest
    $knownForAccount = @{}
    $knownProtected  = @{}
    $knownOtherUsers = @{}

    foreach ($acctProp in $manifest.accounts.PSObject.Properties) {
        $acctName = $acctProp.Name
        if ($acctProp.Value -and $acctProp.Value.repositories) {
            foreach ($r in @($acctProp.Value.repositories)) {
                $k = (Resolve-CanonicalPath $r.path).ToLowerInvariant()
                if ($acctName -eq $Account) {
                    $knownForAccount[$k] = $r
                } else {
                    $knownOtherUsers[$k] = $acctName
                }
            }
        }
    }
    foreach ($p in @($manifest.protected)) {
        $k = (Resolve-CanonicalPath $p.path).ToLowerInvariant()
        $knownProtected[$k] = $p
    }

    $depth = if ($script:Settings.scanDepth -ge 2) { 2 } else { 1 }
    $gitDirs = @(Find-GitDirectoriesInWorkspace -RootPath $script:Workspace -MaxDepth $depth -IgnoredNames $script:Settings.ignoredFolders)

    $newlyAdopted = @()
    $skippedOther = @()

    foreach ($dirPath in $gitDirs) {
        $canon = (Resolve-CanonicalPath $dirPath).ToLowerInvariant()
        if ($knownForAccount.ContainsKey($canon) -or $knownProtected.ContainsKey($canon)) {
            continue
        }
        if ($knownOtherUsers.ContainsKey($canon)) {
            $skippedOther += [PSCustomObject]@{ Path = $dirPath; OwnerAccount = $knownOtherUsers[$canon] }
            continue
        }

        $folderName = Split-Path -Leaf $dirPath
        $primaryUrl = Get-RepoPrimaryRemoteUrl -RepoPath $dirPath
        $slug = if (-not [string]::IsNullOrWhiteSpace($primaryUrl)) {
            ConvertTo-NormalizedRepoSlug $primaryUrl
        } else {
            "(local)/$folderName"
        }

        $targetMode = $script:Settings.defaultAdoptedMode
        if ($targetMode -eq "ask" -and $InteractiveAsk) {
            Write-Yellow "Detected untracked local repository: $folderName ($slug)"
            $ans = (Read-SafeInput " Track as [P]rotected (safe on logout), [E]phemeral (clean on logout), or [I]gnore? [P/E/I]").ToUpper()
            if ($ans -eq "E") { $targetMode = "ephemeral" }
            elseif ($ans -eq "I") { continue }
            else { $targetMode = "persistent" }
        } elseif ($targetMode -eq "ask") {
            # Non-interactive startup defaults safely to persistent (Protected)
            $targetMode = "persistent"
        }

        $repoObj = [PSCustomObject]@{
            name          = $folderName
            nameWithOwner = $slug
            path          = $dirPath
            isPrivate     = $false
            mode          = $targetMode
            clonedAt      = (Get-Date).ToString("o")
        }

        if ($targetMode -eq "ephemeral" -and -not [string]::IsNullOrWhiteSpace($Account)) {
            Add-EphemeralRepo -Account $Account -RepoInfo $repoObj
        } else {
            Add-ProtectedRepo -RepoInfo $repoObj
        }
        $newlyAdopted += $repoObj
    }

    return [PSCustomObject]@{
        NewlyAdopted = $newlyAdopted
        SkippedOther = $skippedOther
        ScannedDirs  = $gitDirs.Count
    }
}

# -----------------------------------------------------------------------------
# Authentication Helpers
# -----------------------------------------------------------------------------
function Get-AuthUser {
    # 1. Fast local check from isolated hosts.yml
    $hostsPath = Join-Path $IsolatedGhDir "hosts.yml"
    if (Test-Path -LiteralPath $hostsPath) {
        try {
            $rawHosts = Get-Content -LiteralPath $hostsPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($rawHosts -match '(?m)^\s*user:\s*([^\r\n]+)$') {
                $u = $matches[1].Trim()
                if (-not [string]::IsNullOrWhiteSpace($u)) {
                    return $u
                }
            }
        } catch {
        }
    }

    # 2. Fallback to GitHub CLI call
    try {
        $user = gh api user --jq .login 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($user)) {
            return $user.Trim()
        }
    } catch {
    }
    return $null
}

function Invoke-GitHubLogin {
    Clear-Host
    Write-Cyan "============================================================"
    Write-Cyan "                   GITHUB AUTHENTICATION"
    Write-Cyan "============================================================"
    Write-Host ""
    Write-Host "Opening GitHub in your default browser for authentication..."
    Write-Gray "Credentials are isolated inside $IsolatedGhDir."
    Write-Host ""

    gh auth login --web -h github.com -p https -s repo,read:org --insecure-storage

    Write-Host ""
    $account = Get-AuthUser
    if ($account) {
        Write-Green "[✓] Successfully authenticated as @$account"
        $script:CachedRepoList = @()
        $script:CachedRepoUser = $account
        if ($script:Settings.autoScanOnStartup) {
            $disc = Invoke-WorkspaceDiscovery -Account $account
            if ($disc.NewlyAdopted.Count -gt 0) {
                $names = ($disc.NewlyAdopted | ForEach-Object { $_.name }) -join ", "
                Write-Cyan "[+] Discovered $($disc.NewlyAdopted.Count) local repo(s) in workspace (Protected): $names"
            }
        }
    } else {
        Write-Red "[✗] Authentication failed or was cancelled."
    }
    Pause-Console
}

# -----------------------------------------------------------------------------
# Safe Deletion Engine (Junction Protection & Locked File Handling)
# -----------------------------------------------------------------------------
function Test-SafeDirectoryTarget {
    param(
        [string]$TargetDir,
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($TargetDir)) {
        return @{ IsValid = $false; Reason = "Target path is empty." }
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return @{ IsValid = $false; Reason = "Workspace root is empty." }
    }

    $resolvedTarget = Resolve-CanonicalPath $TargetDir
    $resolvedWorkspace = Resolve-CanonicalPath $WorkspaceRoot

    if (-not $resolvedTarget.StartsWith($resolvedWorkspace + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ IsValid = $false; Reason = "Target is outside designated workspace ($resolvedWorkspace)." }
    }

    if ($resolvedTarget -eq $resolvedWorkspace) {
        return @{ IsValid = $false; Reason = "Target cannot be the root workspace directory." }
    }

    if (-not [string]::IsNullOrWhiteSpace($ScriptDir)) {
        $resolvedScriptDir = Resolve-CanonicalPath $ScriptDir
        if ($resolvedTarget.Equals($resolvedScriptDir, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolvedTarget.StartsWith($resolvedScriptDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ IsValid = $false; Reason = "Target is the GitSession tool directory." }
        }
    }

    return @{ IsValid = $true; Reason = "" }
}

function Remove-SafeDirectory {
    param(
        [string]$TargetDir,
        [string]$WorkspaceRoot
    )

    $validation = Test-SafeDirectoryTarget -TargetDir $TargetDir -WorkspaceRoot $WorkspaceRoot
    if (-not $validation.IsValid) {
        Write-Red "[SAFETY VIOLATION] Refusing to delete path: $TargetDir"
        Write-Red "Reason: $($validation.Reason)"
        return $false
    }

    $resolvedTarget = [System.IO.Path]::GetFullPath($TargetDir)
    if (-not (Test-Path -LiteralPath $resolvedTarget)) {
        return $true
    }

    # Check if target itself is a reparse point (junction / symbolic link)
    $targetItem = Get-Item -LiteralPath $resolvedTarget -Force
    if ($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-Yellow "[!] Target is a junction/symlink. Removing link without following target contents..."
        [System.IO.Directory]::Delete($resolvedTarget, $false)
        return $true
    }

    $retry = $true
    while ($retry) {
        $retry = $false

        # Remove read-only attributes that Git sets on pack files
        try {
            Get-ChildItem -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                }
            }
        } catch {
        }

        $deleteErrMsg = ""
        try {
            # Remove sub-junctions safely before recursive delete
            $subJunctions = Get-ChildItem -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
                $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
            }
            foreach ($junc in $subJunctions) {
                if ($junc.PSIsContainer) {
                    [System.IO.Directory]::Delete($junc.FullName, $false)
                } else {
                    [System.IO.File]::Delete($junc.FullName)
                }
            }

            Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction Stop
        } catch {
            $deleteErrMsg = $_.Exception.Message
        }

        if (Test-Path -LiteralPath $resolvedTarget) {
            Write-Red ""
            Write-Red "[ERROR] Unable to delete: $resolvedTarget"
            if (-not [string]::IsNullOrWhiteSpace($deleteErrMsg)) {
                Write-Yellow "System reason: $deleteErrMsg"
            }
            Write-Red "One or more files appear to be locked or lack permissions."
            $remainingFiles = @(Get-ChildItem -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 5)
            if ($remainingFiles.Count -gt 0) {
                Write-Yellow "Locked / remaining items:"
                foreach ($rf in $remainingFiles) {
                    Write-Red "  • $($rf.FullName)"
                }
            }
            Write-Yellow "Please close any application accessing this folder."
            Write-Host ""
            Write-Host " [R] Retry deletion"
            Write-Host " [S] Skip this directory"
            Write-Host " [C] Cancel cleanup"
            Write-Host ""
            $choice = (Read-SafeInput " Select an option [R/S/C]").ToUpper()
            if ($script:InputEof) { return $false }
            if ($choice -eq "R") {
                $retry = $true
            } elseif ($choice -eq "S") {
                Write-Yellow "Skipped directory: $resolvedTarget"
                return $false
            } else {
                Write-Yellow "Cleanup cancelled by user."
                return $false
            }
        }
    }

    return (-not (Test-Path -LiteralPath $resolvedTarget))
}

# -----------------------------------------------------------------------------
# Shared Git Workflow Helpers (Clone, Pull, Commit & Push)
# -----------------------------------------------------------------------------
function Invoke-SafeCloneRepo {
    param(
        [string]$NameWithOwner,
        [string]$TargetDirectory,
        [string]$Account,
        [bool]$IsPrivate = $false,
        [ValidateSet("ephemeral", "persistent")]
        [string]$Mode = "ephemeral"
    )

    $TargetDirectory = Resolve-CanonicalPath $TargetDirectory

    if (Test-Path -LiteralPath $TargetDirectory) {
        if (Test-Path -LiteralPath (Join-Path $TargetDirectory ".git")) {
            Write-Yellow "Repository directory already exists: $TargetDirectory"
            return $false
        } else {
            Write-Yellow "Found incomplete or empty directory from previous attempt: $TargetDirectory"
            Write-Gray "Cleaning directory for fresh clone..."
            if (-not (Remove-SafeDirectory -TargetDir $TargetDirectory -WorkspaceRoot $script:Workspace)) {
                Write-Red "[✗] Could not clean destination path: $TargetDirectory"
                return $false
            }
        }
    }

    $bufferBytes = [int]([Math]::Max(50, $script:Settings.httpPostBufferMB) * 1024 * 1024)
    $gitFlagArgs = @(
        "-c", "http.postBuffer=$bufferBytes",
        "-c", "core.compression=0",
        "-c", "http.lowSpeedLimit=0",
        "-c", "http.lowSpeedTime=999999",
        "--progress"
    )

    Write-Cyan "Cloning $NameWithOwner into $TargetDirectory..."
    Write-Gray "Transfer mode: $($script:Settings.cloneMode.ToUpper()) | HTTP Buffer: $($script:Settings.httpPostBufferMB)MB"

    $cloneArgs = if ($script:Settings.cloneMode -eq "shallow") { @("--depth", "1") + $gitFlagArgs } else { $gitFlagArgs }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & gh repo clone $NameWithOwner $TargetDirectory -- @cloneArgs
        $success = ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $TargetDirectory ".git")))

        if (-not $success -and $script:Settings.cloneMode -ne "shallow") {
            Write-Yellow ""
            Write-Yellow "[!] Standard clone failed. Verifying repository access..."
            $probeErr = & gh repo view $NameWithOwner --json name 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Yellow "Repository reachable — retrying with shallow clone (--depth 1)..."
                if (Test-Path -LiteralPath $TargetDirectory) {
                    Remove-SafeDirectory -TargetDir $TargetDirectory -WorkspaceRoot $script:Workspace | Out-Null
                }
                $shallowCloneArgs = @("--depth", "1") + $gitFlagArgs
                & gh repo clone $NameWithOwner $TargetDirectory -- @shallowCloneArgs
                $success = ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $TargetDirectory ".git")))
            } else {
                Write-Red "GitHub access check failed: $((($probeErr | ForEach-Object { "$_" }) -join ' ').Trim())"
            }
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }

    if ($success) {
        # Configure isolated credential helper on ephemeral clone (ProcessStartInfo preserves empty "" arg in PS 5.1)
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "git"
            $psi.Arguments = "-C `"$TargetDirectory`" config credential.https://github.com.helper `"`""
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
        } catch {
        }
        Invoke-GitRepoCommand -RepoPath $TargetDirectory -GitArgs @("config", "--add", "credential.https://github.com.helper", "!gh auth git-credential") | Out-Null

        $folderName = Split-Path -Leaf $TargetDirectory
        $repoObj = [PSCustomObject]@{
            name          = $folderName
            nameWithOwner = $NameWithOwner
            path          = $TargetDirectory
            isPrivate     = $IsPrivate
            mode          = $Mode
            clonedAt      = (Get-Date).ToString("o")
        }
        if ($Mode -eq "persistent") {
            Add-ProtectedRepo -RepoInfo $repoObj
        } else {
            Add-EphemeralRepo -Account $Account -RepoInfo $repoObj
        }
        Write-Green "[✓] Successfully cloned $NameWithOwner into $($script:WorkspaceDisplay)\$folderName [$($Mode.ToUpper())]"
        return $true
    } else {
        Write-Red "[✗] Failed to clone $NameWithOwner."
        Write-Yellow "Please verify repository name, permissions, or internet connection."
        if (Test-Path -LiteralPath $TargetDirectory) {
            Remove-SafeDirectory -TargetDir $TargetDirectory -WorkspaceRoot $script:Workspace | Out-Null
        }
        return $false
    }
}

function Invoke-PullRepoWorkflow {
    param(
        [PSCustomObject]$Repo,
        [switch]$FetchFirst,
        [switch]$AutoStashPrompt
    )

    $repoPath = $Repo.path
    if (-not (Test-Path -LiteralPath $repoPath)) {
        Write-Yellow "[!] Directory no longer exists: $repoPath"
        return $false
    }

    if ($FetchFirst) {
        Write-Gray "  Fetching remote refs for $($Repo.name)..."
        $fRes = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("fetch", "--all", "--prune") -UseIsolatedAuth -CaptureOutput
        if ($fRes.ExitCode -ne 0) {
            Write-Red "  [✗] Fetch failed for $($Repo.name): $($fRes.Output)"
            return $false
        }
    }

    $st = Get-RepoStatus -RepoPath $repoPath
    $isDirty = ($st.HasUncommitted -or $st.HasUntracked)
    $strategy = $script:Settings.pullStrategy
    $pullArgs = switch ($strategy) {
        "rebase" { @("pull", "--rebase") }
        "merge"  { @("pull", "--no-rebase") }
        default  { @("pull", "--ff-only") }
    }

    if ($isDirty -and $st.BehindCount -gt 0 -and $AutoStashPrompt) {
        Write-Yellow "  [!] $($Repo.name) is $($st.BehindCount) commit(s) behind AND has local changes ($($st.UncommittedCount) modified, $($st.UntrackedCount) untracked)."
        $ans = (Read-SafeInput "  [S] Stash + Pull --rebase + Pop, [P] Pull anyway, or [K] Skip? [S/P/K]").ToUpper()
        if ($ans -eq "K" -or [string]::IsNullOrWhiteSpace($ans)) {
            Write-Gray "  Skipped $($Repo.name)."
            return $true
        } elseif ($ans -eq "S") {
            Write-Gray "  Stashing local changes (including untracked)..."
            $beforeStash = (Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("rev-parse", "--verify", "-q", "refs/stash") -CaptureOutput).Output
            $stashRes = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("stash", "push", "-u", "-m", "GitSession auto-stash") -CaptureOutput
            if ($stashRes.ExitCode -ne 0) {
                Write-Red "  [✗] Stash failed: $($stashRes.Output)"
                return $false
            }
            $afterStash = (Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("rev-parse", "--verify", "-q", "refs/stash") -CaptureOutput).Output
            $createdNewStash = (-not [string]::IsNullOrWhiteSpace($afterStash)) -and ($afterStash -ne $beforeStash)

            $pullExit = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("pull", "--rebase") -UseIsolatedAuth
            if ($pullExit -ne 0) {
                Write-Red "  [✗] Pull --rebase failed (exit $pullExit)."
                if ($createdNewStash) {
                    Write-Yellow "  Your local edits remain safely preserved in git stash (run 'git stash pop' after resolving)."
                }
                return $false
            }

            if ($createdNewStash) {
                $popRes = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("stash", "pop") -CaptureOutput
                if ($popRes.ExitCode -eq 0) {
                    Write-Green "  [✓] Rebased & restored local changes cleanly for $($Repo.name)."
                    return $true
                } else {
                    Write-Red "  [✗] Rebase succeeded, but stash pop had conflicts in $($Repo.name)."
                    if ($popRes.Output) { Write-Yellow "  $($popRes.Output)" }
                    return $false
                }
            }
            Write-Green "  [✓] Rebased $($Repo.name) cleanly."
            return $true
        }
    } elseif ($isDirty) {
        Write-Yellow "  [!] Note: $($Repo.name) has uncommitted/untracked changes."
    }

    $exitCode = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs $pullArgs -UseIsolatedAuth
    if ($exitCode -eq 0) {
        Write-Green "[✓] $($Repo.name) updated cleanly ($strategy)."
        return $true
    } else {
        Write-Red "[✗] Pull failed for $($Repo.name) (exit code $exitCode). Try Pull Strategy 'merge'/'rebase' or Resolve conflicts."
        return $false
    }
}

function Invoke-PushRepoWorkflow {
    param(
        [PSCustomObject]$Repo,
        [string]$DefaultCommitMessage = "",
        [switch]$AutoCommitAll
    )

    $repoPath = $Repo.path
    if (-not (Test-Path -LiteralPath $repoPath)) {
        Write-Red "[✗] Directory missing: $repoPath"
        return $false
    }

    $st = Get-RepoStatus -RepoPath $repoPath
    if ([string]::IsNullOrWhiteSpace($DefaultCommitMessage)) {
        $DefaultCommitMessage = "GitSession save $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }

    if ($st.HasUncommitted -or $st.HasUntracked) {
        $doCommit = $AutoCommitAll.IsPresent
        $commitMsg = $DefaultCommitMessage

        if (-not $doCommit) {
            Write-Yellow "Repository '$($Repo.name)' has $($st.UncommittedCount) modified and $($st.UntrackedCount) untracked item(s)."
            $commitChoice = (Read-SafeInput " Stage and commit all changes before pushing? [Y/N]").ToUpper()
            if ($commitChoice -eq "Y") {
                $customMsg = Read-SafeInput " Enter commit message [Default: $DefaultCommitMessage]"
                if (-not [string]::IsNullOrWhiteSpace($customMsg)) {
                    $commitMsg = $customMsg
                }
                $doCommit = $true
            }
        }

        if ($doCommit) {
            $addRes = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("add", "-A") -CaptureOutput
            if ($addRes.ExitCode -ne 0) {
                Write-Red "[✗] Failed to stage changes: $($addRes.Output)"
                return $false
            }
            $cmtRes = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("commit", "-m", $commitMsg) -CaptureOutput
            if ($cmtRes.ExitCode -ne 0 -and ($cmtRes.Output -like "*Please tell me who you are*" -or $cmtRes.Output -like "*Author identity unknown*")) {
                Write-Yellow "[!] Git author identity (user.name / user.email) is not configured yet."
                $ghAcct = Get-AuthUser
                $defName = if ($ghAcct) { $ghAcct } else { $env:USERNAME }
                $defMail = if ($ghAcct) { "$ghAcct@users.noreply.github.com" } else { "$env:USERNAME@users.noreply.github.com" }
                $inName = Read-SafeInput " Enter Git Author Name [Default: $defName]"
                if ([string]::IsNullOrWhiteSpace($inName)) { $inName = $defName }
                $inMail = Read-SafeInput " Enter Git Author Email [Default: $defMail]"
                if ([string]::IsNullOrWhiteSpace($inMail)) { $inMail = $defMail }

                Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("config", "user.name", $inName) | Out-Null
                Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("config", "user.email", $inMail) | Out-Null
                Write-Gray "Saved repository-local author identity ($inName <$inMail>). Retrying commit..."
                $cmtRes = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("commit", "-m", $commitMsg) -CaptureOutput
            }
            if ($cmtRes.ExitCode -ne 0) {
                if ($cmtRes.Output -notlike "*nothing to commit*") {
                    Write-Red "[✗] Commit failed: $($cmtRes.Output)"
                    return $false
                }
            } else {
                Write-Green "[✓] Committed changes to $($st.Branch)."
            }
        }
    }

    # Refresh upstream status after potential commit
    $st = Get-RepoStatus -RepoPath $repoPath
    if ($st.IsDetached) {
        Write-Red "[✗] Repository '$($Repo.name)' is in detached HEAD state. Switch to a branch before pushing."
        return $false
    }

    Write-Host "Pushing $($Repo.name) [$($st.Branch)] to remote..."
    $pushRes = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("push") -UseIsolatedAuth -CaptureOutput
    if ($pushRes.ExitCode -eq 0) {
        Write-Green "[✓] Successfully pushed $($Repo.name)."
        return $true
    }

    if ($pushRes.Output -like "*no upstream branch*" -or $pushRes.Output -like "*--set-upstream*" -or (-not $st.HasUpstream)) {
        Write-Yellow "No upstream branch configured. Pushing and tracking origin/$($st.Branch)..."
        $upPushCode = Invoke-GitRepoCommand -RepoPath $repoPath -GitArgs @("push", "-u", "origin", $st.Branch) -UseIsolatedAuth
        if ($upPushCode -eq 0) {
            Write-Green "[✓] Successfully pushed $($Repo.name) with upstream tracking."
            return $true
        }
        Write-Red "[✗] Git push failed for $($Repo.name)."
        return $false
    } else {
        if (-not [string]::IsNullOrWhiteSpace($pushRes.Output)) {
            Write-Gray $pushRes.Output
        }
        Write-Red "[✗] Git push failed for $($Repo.name). Check permissions or pull remote changes first."
        return $false
    }
}

# -----------------------------------------------------------------------------
# Integration Helpers (Explorer, Terminal, Editor, Web)
# -----------------------------------------------------------------------------
function Open-RepoTerminal {
    param([string]$TargetPath)
    $pref = $script:Settings.preferredTerminal
    try {
        if ($pref -eq "wt" -or ($pref -eq "auto" -and (Get-Command wt.exe -ErrorAction SilentlyContinue))) {
            Start-Process wt.exe -ArgumentList @("-d", "`"$TargetPath`"") -ErrorAction Stop
            return
        }
        if ($pref -eq "pwsh" -and (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
            Start-Process pwsh.exe -WorkingDirectory $TargetPath -ErrorAction Stop
            return
        }
    } catch {
    }
    Start-Process cmd.exe -ArgumentList @("/k", "cd /d `"$TargetPath`"")
}

function Start-EditorProcess {
    param(
        [string]$Executable,
        [string]$TargetPath
    )
    $cmdInfo = Get-Command $Executable -ErrorAction SilentlyContinue
    if (-not $cmdInfo) { return $false }
    try {
        if ($cmdInfo.Source -match '\.(cmd|bat)$') {
            Start-Process $cmdInfo.Source -ArgumentList @("`"$TargetPath`"") -WindowStyle Hidden -ErrorAction Stop
        } else {
            Start-Process $cmdInfo.Source -ArgumentList @("`"$TargetPath`"") -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

function Open-RepoEditor {
    param([string]$TargetPath)
    $pref = $script:Settings.preferredEditor
    if ($pref -ne "auto") {
        if (Start-EditorProcess -Executable $pref -TargetPath $TargetPath) { return $true }
        Write-Yellow "[!] Configured editor '$pref' was not found in PATH."
        return $false
    }

    foreach ($cand in @("code", "cursor", "windsurf", "codium")) {
        if (Start-EditorProcess -Executable $cand -TargetPath $TargetPath) { return $true }
    }

    Write-Yellow "[!] No supported CLI editor (code/cursor/windsurf) found in PATH. Opening Explorer instead."
    Start-Process explorer.exe -ArgumentList "`"$TargetPath`""
    return $true
}

# -----------------------------------------------------------------------------
# [1] Browse & Clone Repository (Paginated >100, Smart Local Badges, Sorting)
# -----------------------------------------------------------------------------
function Get-AccessibleGitHubRepos {
    param(
        [string]$Account,
        [switch]$ForceRefresh
    )

    if (-not $ForceRefresh -and $script:CachedRepoUser -eq $Account -and $script:CachedRepoList.Count -gt 0) {
        return $script:CachedRepoList
    }

    Clear-Host
    Write-Cyan "============================================================"
    Write-Cyan "                 BROWSE & CLONE REPOSITORY"
    Write-Cyan "============================================================"
    Write-Host ""
    Write-Gray "Fetching all accessible repositories for @$Account (paginated)..."

    $allRepos = @()
    $lastErr = ""
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    # Step 1: Fetch via gh api --paginate --jq '.[]' (supports >100 repos cleanly as NDJSON)
    try {
        $rawApi = & gh api --paginate "user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=updated" --jq '.[] | {name: .name, full_name: .full_name, owner: .owner.login, private: .private, fork: .fork, updated_at: .updated_at, description: .description}' 2>&1
        if ($LASTEXITCODE -eq 0 -and $rawApi) {
            foreach ($line in @($rawApi)) {
                $sLine = "$line"
                if ([string]::IsNullOrWhiteSpace($sLine)) { continue }
                try {
                    $r = ConvertFrom-Json $sLine
                    if ($r.full_name) {
                        $allRepos += [PSCustomObject]@{
                            name          = [string]$r.name
                            nameWithOwner = [string]$r.full_name
                            owner         = if ($r.owner) { [string]$r.owner } else { ($r.full_name -split '/')[0] }
                            isPrivate     = [bool]$r.private
                            isFork        = [bool]$r.fork
                            updatedAt     = if ($r.updated_at) { [string]$r.updated_at } else { "" }
                            description   = if ($r.description) { [string]$r.description } else { "" }
                        }
                    }
                } catch {
                }
            }
        } elseif ($rawApi) {
            $lastErr = (($rawApi | ForEach-Object { "$_" }) -join " ").Trim()
        }
    } catch {
        $lastErr = $_.Exception.Message
    }

    # Step 2: Fallback to gh repo list if API failed
    if ($allRepos.Count -eq 0) {
        try {
            $rawList = gh repo list --limit 500 --json nameWithOwner,name,owner,isPrivate,isFork,updatedAt,description 2>&1
            if ($LASTEXITCODE -eq 0 -and $rawList) {
                $jsonStr = ($rawList | ForEach-Object { "$_" }) -join "`n"
                $parsedList = ConvertFrom-Json $jsonStr
                foreach ($r in @($parsedList)) {
                    if ($r.nameWithOwner) {
                        $allRepos += [PSCustomObject]@{
                            name          = [string]$r.name
                            nameWithOwner = [string]$r.nameWithOwner
                            owner         = if ($r.owner -and $r.owner.login) { [string]$r.owner.login } else { ($r.nameWithOwner -split '/')[0] }
                            isPrivate     = [bool]$r.isPrivate
                            isFork        = [bool]$r.isFork
                            updatedAt     = if ($r.updatedAt) { [string]$r.updatedAt } else { "" }
                            description   = if ($r.description) { [string]$r.description } else { "" }
                        }
                    }
                }
            } elseif ($rawList -and [string]::IsNullOrWhiteSpace($lastErr)) {
                $lastErr = (($rawList | ForEach-Object { "$_" }) -join " ").Trim()
            }
        } catch {
            if ([string]::IsNullOrWhiteSpace($lastErr)) { $lastErr = $_.Exception.Message }
        }
    }
    $ErrorActionPreference = $prevEap

    if ($allRepos.Count -eq 0) {
        Write-Red "[ERROR] Could not fetch repositories from GitHub."
        if (-not [string]::IsNullOrWhiteSpace($lastErr)) {
            Write-Yellow "Details: $lastErr"
        }
        Write-Yellow "Please verify your internet connection or re-authenticate."
        Pause-Console
        return @()
    }

    # Deduplicate by nameWithOwner
    $uniqueRepos = @()
    $seen = @{}
    foreach ($r in $allRepos) {
        $k = $r.nameWithOwner.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) {
            $seen[$k] = $true
            $uniqueRepos += $r
        }
    }

    $script:CachedRepoList = $uniqueRepos
    $script:CachedRepoUser = $Account
    return $uniqueRepos
}

function Invoke-ExistingRepoPrompt {
    param(
        [string]$Account,
        [PSCustomObject]$RepoMeta,
        [PSCustomObject]$ExistingEntry,
        [string]$TargetPath,
        [int]$IndexLabel = 1,
        [int]$TotalLabel = 1
    )

    $dispName = Split-Path -Leaf $TargetPath
    Write-Yellow ""
    Write-Yellow "[$IndexLabel/$TotalLabel] '$($RepoMeta.nameWithOwner)' already exists locally at '$dispName'."
    if ($ExistingEntry) {
        Write-Gray "Current Tracking Mode: $($ExistingEntry.mode.ToUpper())"
    } else {
        Write-Gray "Note: Existing folder was not yet tracked in manifest."
    }
    Write-Host " [P] Pull / Update latest changes"
    Write-Host " [O] Open in Repo Inspector"
    Write-Host " [T] Set Mode to Protected (kept on logout)"
    Write-Host " [E] Set Mode to Ephemeral (deleted on logout)"
    Write-Host " [S] Skip"
    Write-Host ""
    $existChoice = (Read-SafeInput " Select an option [P/O/T/E/S]").ToUpper()

    $repoObj = [PSCustomObject]@{
        name          = $dispName
        nameWithOwner = $RepoMeta.nameWithOwner
        path          = $TargetPath
        isPrivate     = [bool]$RepoMeta.isPrivate
        mode          = if ($ExistingEntry) { $ExistingEntry.mode } else { "persistent" }
        clonedAt      = (Get-Date).ToString("o")
    }

    switch ($existChoice) {
        "P" {
            Invoke-PullRepoWorkflow -Repo $repoObj -FetchFirst -AutoStashPrompt | Out-Null
            return "acted"
        }
        "O" {
            Invoke-RepoInspector -Account $Account -Repo $repoObj
            return "inspected"
        }
        "T" {
            Add-ProtectedRepo -RepoInfo $repoObj
            Write-Green "[✓] Marked '$dispName' as PROTECTED."
            return "acted"
        }
        "E" {
            Add-EphemeralRepo -Account $Account -RepoInfo $repoObj
            Write-Green "[✓] Marked '$dispName' as EPHEMERAL."
            return "acted"
        }
        default {
            return "skipped"
        }
    }
}

function Invoke-ActionBrowseClone {
    param([string]$Account)

    $allRepos = @(Get-AccessibleGitHubRepos -Account $Account)
    if ($allRepos.Count -eq 0) { return }

    $searchQuery = ""
    $sortMode    = "updated" # updated, name, private, local
    $currentPage = 1

    while ($true) {
        if ($script:InputEof) { return }
        $pageSize = [Math]::Max(5, [int]$script:Settings.pageSize)
        # Index local workspace repos by remote slug AND folder name (handles custom folder names)
        $localRepos = @(Get-AllWorkspaceRepos -Account $Account)
        $localBySlug = @{}
        $localByName = @{}
        foreach ($lr in $localRepos) {
            if (-not [string]::IsNullOrWhiteSpace($lr.nameWithOwner)) {
                $localBySlug[$lr.nameWithOwner.ToLowerInvariant()] = $lr
            }
            $localByName[$lr.name.ToLowerInvariant()] = $lr
        }

        Clear-Host
        Write-Cyan "============================================================"
        Write-Cyan "                 BROWSE & CLONE REPOSITORY"
        Write-Cyan "============================================================"
        Write-Host ""

        $filtered = $allRepos
        if (-not [string]::IsNullOrWhiteSpace($searchQuery)) {
            $filtered = @($allRepos | Where-Object {
                $_.nameWithOwner -like "*$searchQuery*" -or
                $_.name -like "*$searchQuery*" -or
                ($_.description -and $_.description -like "*$searchQuery*")
            })
            Write-Yellow "Filter: '$searchQuery' ($($filtered.Count) matches) | Sort: $sortMode  [Type '/' to reset]"
            Write-Host ""
        } else {
            Write-Gray "Accessible Repositories: $($allRepos.Count) total | Sort: $sortMode | Clone: $($script:Settings.cloneMode)"
            Write-Host ""
        }

        if ($filtered.Count -eq 0) {
            Write-Yellow "No repositories match '$searchQuery'."
            Write-Host ""
            Write-Gray "Type '/' to clear filter, [R] to Refresh, or [0] Back."
            $emptyChoice = Read-SafeInput " Select an option"
            if ($script:InputEof) { return }
            $emptyLower = $emptyChoice.ToLowerInvariant()
            if ($emptyLower -eq "0" -or $emptyLower -eq "b" -or $emptyLower -eq "q") { return }
            if ($emptyLower -eq "r" -or $emptyLower -eq "refresh") {
                $refreshed = @(Get-AccessibleGitHubRepos -Account $Account -ForceRefresh)
                if ($refreshed.Count -gt 0) { $allRepos = $refreshed }
                continue
            }
            $searchQuery = ""
            $currentPage = 1
            continue
        }

        # Apply sorting
        $sorted = switch ($sortMode) {
            "name"    { @($filtered | Sort-Object { $_.name.ToLowerInvariant() }) }
            "private" { @($filtered | Sort-Object @{Expression = { -not $_.isPrivate }}, @{Expression = { $_.name.ToLowerInvariant() }}) }
            "local"   {
                @($filtered | Sort-Object @{
                    Expression = {
                        $s = $_.nameWithOwner.ToLowerInvariant()
                        if ($localBySlug.ContainsKey($s) -or $localByName.ContainsKey($_.name.ToLowerInvariant())) { 0 } else { 1 }
                    }
                }, @{Expression = { $_.name.ToLowerInvariant() }})
            }
            default   { $filtered }
        }

        $totalPages = [Math]::Max(1, [int][Math]::Ceiling($sorted.Count / $pageSize))
        if ($currentPage -gt $totalPages) { $currentPage = $totalPages }
        if ($currentPage -lt 1) { $currentPage = 1 }

        $startIndex = ($currentPage - 1) * $pageSize
        $endIndex = [Math]::Min($startIndex + $pageSize - 1, $sorted.Count - 1)

        for ($i = $startIndex; $i -le $endIndex; $i++) {
            $r = $sorted[$i]
            $numStr = "[$($i + 1)]".PadRight(5)
            $visStr = if ($r.isPrivate) { "$C_YELLOW[Private]$C_RESET" } else { "$C_GREEN[Public ]$C_RESET" }

            $slugKey = $r.nameWithOwner.ToLowerInvariant()
            $localTag = ""
            if ($localBySlug.ContainsKey($slugKey)) {
                $matchedLocal = $localBySlug[$slugKey]
                $modeTag = if ($matchedLocal.mode -eq "persistent") { "PROTECTED" } else { "EPHEMERAL" }
                $folderSuffix = if ($matchedLocal.name -ne $r.name) { ": $($matchedLocal.name)" } else { "" }
                $localTag = " $C_CYAN[LOCAL$folderSuffix | $modeTag]$C_RESET"
            } else {
                $defaultFolder = if ($r.owner.ToLower() -ne $Account.ToLower()) { "$($r.owner)_$($r.name)" } else { $r.name }
                $candPath = Join-Path $script:Workspace $defaultFolder
                if (Test-Path -LiteralPath $candPath) {
                    $localTag = " $C_YELLOW[DIR IN USE: $defaultFolder]$C_RESET"
                }
            }

            $forkTag = if ($r.isFork) { " ${C_GRAY}(fork)${C_RESET}" } else { "" }
            Write-Host "$numStr $visStr $C_BOLD$($r.nameWithOwner)$C_RESET$forkTag$localTag"

            if ($script:Settings.showDescriptions -and $r.description) {
                $descPreview = if ($r.description.Length -gt 72) { $r.description.Substring(0, 69) + "..." } else { $r.description }
                Write-Gray "      $descPreview"
            }
        }

        Write-Host ""
        Write-Gray "--- Page $currentPage of $totalPages (Showing $($startIndex + 1)-$($endIndex + 1) of $($sorted.Count)) ---"
        Write-Host "Commands: " -NoNewline
        if ($currentPage -lt $totalPages) { Write-Host "[N] Next  " -NoNewline }
        if ($currentPage -gt 1)           { Write-Host "[P] Prev  " -NoNewline }
        Write-Host "[S] Sort  [R] Refresh  [/query] Filter  [0] Back"
        Write-Host ""

        $selection = Read-SafeInput " Enter number(s) (e.g. 1 or 1,3 or 1-4), repo name, URL, or command"
        if ($script:InputEof) { return }
        $selLower = $selection.ToLowerInvariant()

        if ($selLower -eq "0" -or $selLower -eq "b" -or $selLower -eq "back" -or $selLower -eq "q") { return }
        if ($selLower -eq "r" -or $selLower -eq "refresh") {
            $refreshed = @(Get-AccessibleGitHubRepos -Account $Account -ForceRefresh)
            if ($refreshed.Count -gt 0) {
                $allRepos = $refreshed
                $currentPage = 1
            }
            continue
        }
        if ($selLower -eq "n" -or $selLower -eq "next") {
            if ($currentPage -lt $totalPages) { $currentPage++ }
            continue
        }
        if ($selLower -eq "p" -or $selLower -eq "prev") {
            if ($currentPage -gt 1) { $currentPage-- }
            continue
        }
        if ($selLower -eq "s" -or $selLower -eq "sort") {
            $sortMode = switch ($sortMode) {
                "updated" { "name" }
                "name"    { "private" }
                "private" { "local" }
                default   { "updated" }
            }
            $currentPage = 1
            continue
        }
        if ($selection.StartsWith("/")) {
            $searchQuery = $selection.Substring(1).Trim()
            $currentPage = 1
            continue
        }
        if ($selLower -eq "clear" -or $selLower -eq "all" -or $selection -eq "*") {
            $searchQuery = ""
            $currentPage = 1
            continue
        }

        $selectedList = @()

        # Direct GitHub URL -> normalize into Meta & go through unified clone/existing path
        if ($selection -match '^https?://github\.com/([a-zA-Z0-9_\-\.]+)/([a-zA-Z0-9_\-\.]+)((/|\.git)?)$') {
            $directOwner = $matches[1]
            $directRepo  = $matches[2] -replace '\.git$', ''
            $directFull  = "$directOwner/$directRepo"
            $matchedCached = @($allRepos | Where-Object { $_.nameWithOwner.ToLowerInvariant() -eq $directFull.ToLowerInvariant() })
            if ($matchedCached.Count -eq 1) {
                $selectedList = $matchedCached
            } else {
                $selectedList = @([PSCustomObject]@{
                    name          = $directRepo
                    nameWithOwner = $directFull
                    owner         = $directOwner
                    isPrivate     = $false
                })
            }
        } else {
            # Exact name or owner/repo match inside accessible list
            $exactMatches = @($allRepos | Where-Object {
                $_.name.ToLowerInvariant() -eq $selLower -or $_.nameWithOwner.ToLowerInvariant() -eq $selLower
            })
            if ($exactMatches.Count -eq 1) {
                $selectedList = $exactMatches
            } elseif ($exactMatches.Count -gt 1) {
                # Multiple repos share this name (e.g. personal + fork): filter list so user picks cleanly
                $searchQuery = $selection
                $currentPage = 1
                continue
            } elseif ($selection -match '^([a-zA-Z0-9_\-\.]+)/([a-zA-Z0-9_\-\.]+)$') {
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    $probe = & gh repo view $selection --json nameWithOwner,isPrivate 2>$null
                    $probeOk = ($LASTEXITCODE -eq 0 -and $probe)
                } finally {
                    $ErrorActionPreference = $prevEap
                }
                if ($probeOk) {
                    $pJson = ConvertFrom-Json ($probe -join "`n")
                    $parts = $pJson.nameWithOwner -split '/'
                    $selectedList = @([PSCustomObject]@{
                        name          = $parts[1]
                        nameWithOwner = $pJson.nameWithOwner
                        owner         = $parts[0]
                        isPrivate     = [bool]$pJson.isPrivate
                    })
                } else {
                    $searchQuery = $selection
                    $currentPage = 1
                    continue
                }
            } else {
                # Numeric selection (1 or 1,3 or 1-4)
                $selectedNumbers = @()
                $tokens = @($selection -split '[,; ]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                foreach ($tok in $tokens) {
                    if ($tok -match '^(\d+)-(\d+)$') {
                        $sNum = [int]$matches[1]; $eNum = [int]$matches[2]
                        if ($sNum -le $eNum) { $sNum..$eNum | ForEach-Object { $selectedNumbers += $_ } }
                    } elseif ($tok -match '^\d+$') {
                        $selectedNumbers += [int]$tok
                    }
                }
                $validIndices = @()
                foreach ($n in $selectedNumbers) {
                    $idx = $n - 1
                    if ($idx -ge 0 -and $idx -lt $sorted.Count -and (-not ($validIndices -contains $idx))) {
                        $validIndices += $idx
                    }
                }
                if ($validIndices.Count -eq 0) {
                    if (-not [string]::IsNullOrWhiteSpace($selection)) {
                        $searchQuery = $selection
                        $currentPage = 1
                        continue
                    }
                    Write-Yellow "Invalid selection."
                    Start-Sleep -Milliseconds 500
                    continue
                }
                $selectedList = @($validIndices | ForEach-Object { $sorted[$_] })
            }
        }

        Write-Host ""
        $lastActionOutcome = "acted"
        for ($k = 0; $k -lt $selectedList.Count; $k++) {
            $selectedRepo = $selectedList[$k]
            $slugKey = $selectedRepo.nameWithOwner.ToLowerInvariant()

            $existingEntry = if ($localBySlug.ContainsKey($slugKey)) { $localBySlug[$slugKey] } else { $null }
            $folderName = if ($selectedRepo.owner.ToLower() -ne $Account.ToLower()) {
                "$($selectedRepo.owner)_$($selectedRepo.name)"
            } else {
                $selectedRepo.name
            }
            $targetPath = if ($existingEntry) { $existingEntry.path } else { Join-Path $script:Workspace $folderName }

            if (Test-Path -LiteralPath $targetPath) {
                $lastActionOutcome = Invoke-ExistingRepoPrompt -Account $Account -RepoMeta $selectedRepo -ExistingEntry $existingEntry -TargetPath $targetPath -IndexLabel ($k + 1) -TotalLabel $selectedList.Count
                continue
            }

            Write-Host ""
            Write-Cyan "[$($k + 1)/$($selectedList.Count)] Preparing clone for $($selectedRepo.nameWithOwner)..."
            Invoke-SafeCloneRepo -NameWithOwner $selectedRepo.nameWithOwner -TargetDirectory $targetPath -Account $Account -IsPrivate ([bool]$selectedRepo.isPrivate) -Mode "ephemeral" | Out-Null
            $lastActionOutcome = "acted"
        }

        if ($lastActionOutcome -ne "inspected") {
            Write-Host ""
            $afterClone = (Read-SafeInput "Press Enter to continue browsing, or [0] to return to Dashboard").ToLowerInvariant()
            if ($script:InputEof -or $afterClone -eq "0" -or $afterClone -eq "b" -or $afterClone -eq "q") {
                return
            }
        }
    }
}

# -----------------------------------------------------------------------------
# [2] Workspace Sync Matrix (Discover, Fetch All, Pull Behind, Push Ahead)
# -----------------------------------------------------------------------------
function Invoke-ActionSync {
    param([string]$Account)

    # Initial scan on entering Sync
    $disc = Invoke-WorkspaceDiscovery -Account $Account -InteractiveAsk
    if ($disc.NewlyAdopted.Count -gt 0) {
        $names = ($disc.NewlyAdopted | ForEach-Object { "$($_.name) [$($_.mode.ToUpper())]" }) -join ", "
        $script:LastDiscoveryMsg = "+$($disc.NewlyAdopted.Count) newly detected: $names"
    } else {
        $script:LastDiscoveryMsg = ""
    }

    while ($true) {
        if ($script:InputEof) { return }
        $repos = @(Get-AllWorkspaceRepos -Account $Account)
        Clear-Host
        Write-Cyan "============================================================"
        Write-Cyan "              WORKSPACE SYNC & UPDATE CENTER"
        Write-Cyan "============================================================"
        Write-Host ""
        Write-Gray "Workspace: $($script:Workspace) | Pull Strategy: $($script:Settings.pullStrategy)"
        if ($script:LastSyncTime) {
            Write-Gray "Last Fetch/Sync: $($script:LastSyncTime.ToString('HH:mm:ss'))"
        }
        if (-not [string]::IsNullOrWhiteSpace($script:LastDiscoveryMsg)) {
            Write-Green "[+] $($script:LastDiscoveryMsg)"
            $script:LastDiscoveryMsg = ""
        }
        Write-Host ""

        if ($repos.Count -eq 0) {
            Write-Yellow "No repositories detected inside $($script:WorkspaceDisplay)."
            Write-Gray "Clone a repository via [1] Browse & Clone or press [D] to scan deeper."
            Write-Host ""
            Write-Host " [D] Re-scan Workspace    [0] Back to Dashboard"
            $emptyAct = (Read-SafeInput " Select").ToUpper()
            if ($script:InputEof) { return }
            if ($emptyAct -eq "D") {
                $disc = Invoke-WorkspaceDiscovery -Account $Account -InteractiveAsk
                continue
            }
            return
        }

        $statuses = @()
        $behindList = @()
        $aheadOrDirtyList = @()

        Write-Host (" {0,-4} {1,-22} {2,-11} {3,-12} {4,-12} {5}" -f "#", "Folder", "Branch", "Sync", "Tree", "Mode")
        Write-Gray " ----------------------------------------------------------------------------"

        for ($i = 0; $i -lt $repos.Count; $i++) {
            $r = $repos[$i]
            $st = Get-RepoStatus -RepoPath $r.path
            $statuses += [PSCustomObject]@{ Repo = $r; Status = $st }

            $numCol = "[$($i + 1)]".PadRight(4)
            $folderCol = Format-Truncated $r.name 22
            $branchCol = Format-Truncated $st.Branch 11

            # Ahead / Behind string
            $syncText = ""
            $syncColor = $C_GREEN
            if (-not $st.HasUpstream) {
                $syncText = "no-upstream"
                $syncColor = $C_GRAY
            } elseif ($st.UnpushedCount -gt 0 -and $st.BehindCount -gt 0) {
                $syncText = "↑$($st.UnpushedCount) ↓$($st.BehindCount)"
                $syncColor = $C_YELLOW
                $behindList += $r
                $aheadOrDirtyList += $r
            } elseif ($st.BehindCount -gt 0) {
                $syncText = "↓$($st.BehindCount) behind"
                $syncColor = $C_YELLOW
                $behindList += $r
            } elseif ($st.UnpushedCount -gt 0) {
                $syncText = "↑$($st.UnpushedCount) ahead"
                $syncColor = $C_CYAN
                $aheadOrDirtyList += $r
            } else {
                $syncText = "≡ synced"
                $syncColor = $C_GREEN
            }
            $syncCol = $syncText.PadRight(12)

            # Working tree string
            $wtParts = @()
            if ($st.HasUncommitted) { $wtParts += "$($st.UncommittedCount)M" }
            if ($st.HasUntracked)   { $wtParts += "$($st.UntrackedCount)?" }
            if ($wtParts.Count -eq 0) {
                $wtText = "clean"
                $wtColor = $C_GREEN
            } else {
                $wtText = ($wtParts -join " ")
                $wtColor = $C_YELLOW
                if (-not ($aheadOrDirtyList -contains $r)) { $aheadOrDirtyList += $r }
            }
            $wtCol = $wtText.PadRight(12)

            $modeBadge = if ($r.mode -eq "persistent") { "${C_GREEN}[PROT ]${C_RESET}" } else { "${C_CYAN}[EPHEM]${C_RESET}" }

            Write-Host " $numCol $folderCol $C_CYAN$branchCol$C_RESET $syncColor$syncCol$C_RESET $wtColor$wtCol$C_RESET $modeBadge"
            if ($r.nameWithOwner -and $r.nameWithOwner -ne "(local)/$($r.name)") {
                Write-Gray "      -> $($r.nameWithOwner)"
            }
        }

        Write-Host ""
        Write-Host " [A] Full Sync (Fetch + Pull Behind)   [F] Fetch All Remotes"
        Write-Host " [P] Pull Behind ($($behindList.Count))                    [U] Push Ahead/Dirty ($($aheadOrDirtyList.Count))"
        Write-Host " [D] Re-scan / Discover Local Repos    [1-$($repos.Count)] Inspect / Manage Repo"
        Write-Host " [0] Back to Dashboard"
        Write-Host ""

        $act = (Read-SafeInput " Select sync action").ToUpper()
        if ($script:InputEof -or $act -eq "0" -or $act -eq "B" -or $act -eq "Q") { return }

        if ($act -eq "D") {
            $disc = Invoke-WorkspaceDiscovery -Account $Account -InteractiveAsk
            Write-Host ""
            if ($disc.NewlyAdopted.Count -gt 0) {
                Write-Green "[+] Discovered and added $($disc.NewlyAdopted.Count) repository(ies)."
            } else {
                Write-Green "[✓] Workspace scan complete ($($disc.ScannedDirs) repositories checked, 0 new)."
            }
            Pause-Console
            continue
        }

        if ($act -eq "F" -or $act -eq "A") {
            Write-Host ""
            Write-Cyan "Fetching remote updates across all repositories..."
            foreach ($item in $statuses) {
                $r = $item.Repo
                $st = $item.Status
                if ([string]::IsNullOrWhiteSpace($st.RemoteUrl)) {
                    Write-Gray "  [-] $($r.name): no remote configured (skipped)"
                    continue
                }
                Write-Host "  Fetching $($r.name)..." -NoNewline
                $fRes = Invoke-GitRepoCommand -RepoPath $r.path -GitArgs @("fetch", "--all", "--prune") -UseIsolatedAuth -CaptureOutput
                if ($fRes.ExitCode -eq 0) {
                    Write-Green " [OK]"
                } else {
                    Write-Red " [ERR: $($fRes.Output)]"
                }
            }
            $script:LastSyncTime = Get-Date

            if ($act -eq "A") {
                Write-Host ""
                Write-Cyan "Applying smart pull ($($script:Settings.pullStrategy)) to behind repositories..."
                $pulledCount = 0
                foreach ($r in $repos) {
                    $freshSt = Get-RepoStatus -RepoPath $r.path
                    if ($freshSt.BehindCount -gt 0) {
                        Invoke-PullRepoWorkflow -Repo $r -AutoStashPrompt | Out-Null
                        $pulledCount++
                    }
                }
                if ($pulledCount -eq 0) {
                    Write-Green "[✓] All tracked repositories are already up to date with their remotes."
                }
            }
            Pause-Console
            continue
        }

        if ($act -eq "P") {
            Write-Host ""
            $fetchHadErrors = $false
            if ($behindList.Count -eq 0) {
                Write-Yellow "No cached behind-remote counts. Running fetch check first..."
                foreach ($item in $statuses) {
                    if ($item.Status.RemoteUrl) {
                        $fRes = Invoke-GitRepoCommand -RepoPath $item.Repo.path -GitArgs @("fetch", "--all", "--prune") -UseIsolatedAuth -CaptureOutput
                        if ($fRes.ExitCode -ne 0) {
                            Write-Red "  [✗] Fetch failed for $($item.Repo.name): $($fRes.Output)"
                            $fetchHadErrors = $true
                        }
                    }
                }
                $script:LastSyncTime = Get-Date
                $behindList = @($repos | Where-Object { (Get-RepoStatus -RepoPath $_.path).BehindCount -gt 0 })
            }
            if ($behindList.Count -eq 0) {
                if ($fetchHadErrors) {
                    Write-Yellow "[!] One or more repositories could not be fetched; check network or credentials."
                } else {
                    Write-Green "[✓] All repositories are up to date."
                }
            } else {
                foreach ($r in $behindList) {
                    Invoke-PullRepoWorkflow -Repo $r -AutoStashPrompt | Out-Null
                }
            }
            Pause-Console
            continue
        }

        if ($act -eq "U") {
            Write-Host ""
            if ($aheadOrDirtyList.Count -eq 0) {
                Write-Green "[✓] All workspace repositories are clean and pushed."
                Pause-Console
                continue
            }
            foreach ($r in $aheadOrDirtyList) {
                Invoke-PushRepoWorkflow -Repo $r | Out-Null
                Write-Host ""
            }
            Pause-Console
            continue
        }

        if ($act -match '^\d+$') {
            $idx = [int]$act - 1
            if ($idx -ge 0 -and $idx -lt $repos.Count) {
                Invoke-RepoInspector -Account $Account -Repo $repos[$idx]
                continue
            }
        }

        Write-Yellow "Invalid option."
        Start-Sleep -Milliseconds 500
    }
}

# -----------------------------------------------------------------------------
# [3] Local Repositories & Interactive Repo Inspector
# -----------------------------------------------------------------------------
function Invoke-RepoInspector {
    param(
        [string]$Account,
        [PSCustomObject]$Repo
    )

    while ($true) {
        if ($script:InputEof) { return }
        if (-not (Test-Path -LiteralPath $Repo.path)) {
            Write-Yellow "Repository folder no longer exists on disk."
            Pause-Console
            return
        }

        $st = Get-RepoStatus -RepoPath $Repo.path
        Clear-Host
        Write-Cyan "============================================================"
        Write-Cyan "             REPOSITORY INSPECTOR: $($Repo.name)"
        Write-Cyan "============================================================"
        Write-Host ""
        Write-Host " Path       : " -NoNewline; Write-Gray "$($Repo.path)"
        Write-Host " Remote     : " -NoNewline; Write-Bold "$($Repo.nameWithOwner)"
        Write-Host " Tracking   : " -NoNewline
        if ($Repo.mode -eq "persistent") {
            Write-Green "PROTECTED (Persistent — kept on logout)"
        } else {
            Write-Cyan "EPHEMERAL (Session-managed — cleaned on logout)"
        }
        Write-Host " Branch     : " -NoNewline; Write-Cyan "$($st.Branch)" -NoNewline
        if ($st.IsShallow) { Write-Yellow " [Shallow Clone]" } else { Write-Host "" }

        Write-Host " Worktree   : " -NoNewline
        if (-not $st.HasUncommitted -and -not $st.HasUntracked) {
            Write-Green "Clean"
        } else {
            Write-Yellow "$($st.UncommittedCount) modified, $($st.UntrackedCount) untracked"
        }

        Write-Host " Remote Sync: " -NoNewline
        if (-not $st.HasUpstream) {
            Write-Gray "No upstream tracking branch"
        } elseif ($st.UnpushedCount -gt 0 -or $st.BehindCount -gt 0) {
            Write-Yellow "Ahead $($st.UnpushedCount) / Behind $($st.BehindCount)"
        } else {
            Write-Green "Up to date"
        }

        if ($st.LastCommitHash) {
            Write-Host " Last Commit: " -NoNewline; Write-Gray "$($st.LastCommitHash) - $($st.LastCommitMessage) ($($st.LastCommitRelative))"
        }

        Write-Host ""
        Write-Cyan " Actions:"
        Write-Host "  [P] Pull latest       [F] Fetch remote       [C] Commit & Push"
        Write-Host "  [D] Diff & Status     [B] Switch / New Branch"
        Write-Host "  [T] Open Terminal     [V] Open in Editor     [E] Open Explorer"
        Write-Host "  [G] Open on GitHub    [M] Toggle Protected/Ephemeral"
        if ($st.IsShallow) {
            Write-Host "  [U] Unshallow history [X] Remove Folder      [0] Back"
        } else {
            Write-Host "  [X] Remove Folder     [0] Back"
        }
        Write-Host ""

        $opt = (Read-SafeInput " Select action").ToUpper()
        if ($script:InputEof) { return }
        switch ($opt) {
            "0" { return }
            "B" {
                Clear-Host
                Write-Cyan "=== BRANCHES IN $($Repo.name) ==="
                Write-Host ""
                $brRes = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("branch", "-a", "--no-color") -CaptureOutput
                if ($brRes.ExitCode -eq 0) {
                    Write-Host $brRes.Output
                }
                Write-Host ""
                $targetBr = Read-SafeInput " Enter branch name to switch/create (or leave blank to go back)"
                if (-not [string]::IsNullOrWhiteSpace($targetBr)) {
                    $chkLocal  = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("show-ref", "--verify", "--quiet", "refs/heads/$targetBr")
                    $chkRemote = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("show-ref", "--verify", "--quiet", "refs/remotes/origin/$targetBr")
                    if ($chkLocal -eq 0 -or $chkRemote -eq 0) {
                        $coCode = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("checkout", $targetBr)
                        if ($coCode -eq 0) { Write-Green "[✓] Switched to branch '$targetBr'." }
                        else { Write-Red "[✗] Could not switch to '$targetBr'." }
                    } else {
                        $createAns = (Read-SafeInput " Branch '$targetBr' doesn't exist locally or on origin. Create new branch? [Y/N]").ToUpper()
                        if ($createAns -eq "Y") {
                            $cbCode = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("checkout", "-b", $targetBr)
                            if ($cbCode -eq 0) { Write-Green "[✓] Created and switched to '$targetBr'." }
                            else { Write-Red "[✗] Failed to create branch '$targetBr'." }
                        }
                    }
                    Pause-Console
                }
            }
            "P" {
                Write-Host ""
                Invoke-PullRepoWorkflow -Repo $Repo -FetchFirst -AutoStashPrompt | Out-Null
                Pause-Console
            }
            "F" {
                Write-Host ""
                Write-Gray "Fetching..."
                $fRes = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("fetch", "--all", "--prune") -UseIsolatedAuth -CaptureOutput
                if ($fRes.ExitCode -eq 0) { Write-Green "[✓] Fetch complete." } else { Write-Red "[✗] $($fRes.Output)" }
                Pause-Console
            }
            "C" {
                Write-Host ""
                Invoke-PushRepoWorkflow -Repo $Repo | Out-Null
                Pause-Console
            }
            "D" {
                Clear-Host
                Write-Cyan "=== STATUS & DIFF SUMMARY: $($Repo.name) ==="
                Write-Host ""
                $stShort = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("status", "-s") -CaptureOutput
                if ($stShort.Output) {
                    Write-Yellow "Changed / Untracked Files:"
                    Write-Host $stShort.Output
                } else {
                    Write-Green "Working tree is clean."
                }
                Write-Host ""
                $diffStat = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("diff", "--stat") -CaptureOutput
                if ($diffStat.Output) {
                    Write-Cyan "Diff Statistics:"
                    Write-Host $diffStat.Output
                    Write-Host ""
                }
                Write-Cyan "Recent Commits:"
                $logs = Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("log", "-5", "--oneline") -CaptureOutput
                Write-Host $logs.Output
                Pause-Console
            }
            "T" { Open-RepoTerminal -TargetPath $Repo.path }
            "V" { Open-RepoEditor -TargetPath $Repo.path | Out-Null }
            "E" { Start-Process explorer.exe -ArgumentList "`"$($Repo.path)`"" }
            "G" {
                $targetUrl = ""
                if ($Repo.nameWithOwner -and $Repo.nameWithOwner -notlike "(local)/*" -and $Repo.nameWithOwner -notmatch '^(git@|ssh://)') {
                    if ($Repo.nameWithOwner -match '^https?://') {
                        $targetUrl = $Repo.nameWithOwner
                    } else {
                        $targetUrl = "https://github.com/$($Repo.nameWithOwner)"
                    }
                } elseif ($st.RemoteUrl -match '^https?://') {
                    $targetUrl = $st.RemoteUrl
                }
                if ($targetUrl -match '^https?://') {
                    try {
                        Start-Process $targetUrl
                    } catch {
                        Write-Red "[✗] Could not launch browser for $targetUrl"
                        Start-Sleep -Milliseconds 700
                    }
                } else {
                    Write-Yellow "No web-accessible HTTPS remote URL found."
                    Start-Sleep -Milliseconds 700
                }
            }
            "M" {
                $newMode = if ($Repo.mode -eq "persistent") { "ephemeral" } else { "persistent" }
                Set-RepoMode -Account $Account -RepoObj $Repo -TargetMode $newMode
                $Repo.mode = $newMode
                Write-Green "[✓] Tracking mode updated to $($newMode.ToUpper())."
                Start-Sleep -Milliseconds 600
            }
            "U" {
                if ($st.IsShallow) {
                    Write-Cyan "Fetching full commit history (--unshallow)..."
                    Invoke-GitRepoCommand -RepoPath $Repo.path -GitArgs @("fetch", "--unshallow") -UseIsolatedAuth | Out-Null
                    Pause-Console
                }
            }
            "X" {
                $removed = Invoke-RemoveSingleRepoPrompt -Account $Account -TargetRepo $Repo
                if ($removed) { return }
            }
            default {
                Write-Yellow "Unknown action."
                Start-Sleep -Milliseconds 400
            }
        }
    }
}

function Invoke-ActionViewLocal {
    param([string]$Account)

    if ($script:Settings.autoScanOnStartup) {
        Invoke-WorkspaceDiscovery -Account $Account | Out-Null
    }

    while ($true) {
        if ($script:InputEof) { return }
        Clear-Host
        Write-Cyan "============================================================"
        Write-Cyan "                LOCAL REPOSITORIES MANAGER"
        Write-Cyan "============================================================"
        Write-Host ""

        $repos = @(Get-AllWorkspaceRepos -Account $Account)
        if ($repos.Count -eq 0) {
            Write-Yellow "No repositories detected inside $($script:WorkspaceDisplay)."
            Write-Gray "Use [1] Browse & Clone or [2] Sync Workspace to discover/clone repositories."
            Pause-Console
            return
        }

        $ephemCount = @($repos | Where-Object { $_.mode -ne "persistent" }).Count
        $protCount  = @($repos | Where-Object { $_.mode -eq "persistent" }).Count
        Write-Gray "Workspace: $($script:Workspace)"
        Write-Gray "Repositories: $($repos.Count) total ($ephemCount Ephemeral, $protCount Protected)"
        Write-Host ""

        for ($i = 0; $i -lt $repos.Count; $i++) {
            $r = $repos[$i]
            $st = Get-RepoStatus -RepoPath $r.path

            Write-Cyan "------------------------------------------------------------"
            Write-Host " [$($i + 1)] " -NoNewline
            Write-Bold "$($r.name)" -NoNewline
            Write-Gray " ($($r.nameWithOwner)) " -NoNewline
            if ($r.mode -eq "persistent") { Write-Green "[PROTECTED]" } else { Write-Cyan "[EPHEMERAL]" }

            Write-Host "     Branch     : " -NoNewline; Write-Cyan "$($st.Branch)"
            Write-Host "     Status     : " -NoNewline
            if (-not $st.HasUncommitted -and -not $st.HasUntracked) {
                Write-Green "Clean"
            } else {
                $dirtyParts = @()
                if ($st.HasUncommitted) { $dirtyParts += "$($st.UncommittedCount) modified" }
                if ($st.HasUntracked)   { $dirtyParts += "$($st.UntrackedCount) untracked" }
                Write-Yellow "[!] $($dirtyParts -join ', ')"
            }

            Write-Host "     Sync       : " -NoNewline
            if (-not $st.HasUpstream) {
                Write-Gray "No upstream branch"
            } elseif ($st.HasUnpushed -or $st.BehindCount -gt 0) {
                Write-Yellow "[!] Ahead $($st.UnpushedCount) / Behind $($st.BehindCount)"
            } else {
                Write-Green "Up to date with remote"
            }

            if ($st.LastCommitHash) {
                Write-Host "     Last Commit: " -NoNewline; Write-Gray "$($st.LastCommitHash) - $($st.LastCommitMessage) ($($st.LastCommitRelative))"
            }
        }
        Write-Cyan "------------------------------------------------------------"
        Write-Host ""
        $pick = (Read-SafeInput " Enter [1-$($repos.Count)] to inspect/manage, [S] Sync, or [0] Back").ToUpper()
        if ($script:InputEof -or $pick -eq "0" -or $pick -eq "B" -or $pick -eq "Q" -or [string]::IsNullOrWhiteSpace($pick)) { return }
        if ($pick -eq "S") {
            Invoke-ActionSync -Account $Account
            continue
        }
        if ($pick -match '^\d+$') {
            $idx = [int]$pick - 1
            if ($idx -ge 0 -and $idx -lt $repos.Count) {
                Invoke-RepoInspector -Account $Account -Repo $repos[$idx]
            }
        }
    }
}

# -----------------------------------------------------------------------------
# [4] Open Workspace in Explorer / Terminal
# -----------------------------------------------------------------------------
function Invoke-ActionOpenExplorer {
    Clear-Host
    Write-Cyan "Opening workspace directory..."
    Write-Gray "Path: $($script:Workspace)"
    Start-Process explorer.exe -ArgumentList "`"$($script:Workspace)`""
    Start-Sleep -Milliseconds 500
}

# -----------------------------------------------------------------------------
# [5] Push Local Changes (Covers Ephemeral + Protected Repos)
# -----------------------------------------------------------------------------
function Invoke-ActionPush {
    param([string]$Account)

    Clear-Host
    Write-Cyan "============================================================"
    Write-Cyan "                    PUSH LOCAL CHANGES"
    Write-Cyan "============================================================"
    Write-Host ""

    $repos = @(Get-AllWorkspaceRepos -Account $Account)
    if ($repos.Count -eq 0) {
        Write-Yellow "No repositories detected in workspace."
        Pause-Console
        return
    }

    $dirtyRepos = @()
    foreach ($r in $repos) {
        $st = Get-RepoStatus -RepoPath $r.path
        if ($st.HasUncommitted -or $st.HasUntracked -or $st.HasUnpushed) {
            $dirtyRepos += [PSCustomObject]@{ Repo = $r; Status = $st }
        }
    }

    if ($dirtyRepos.Count -eq 0) {
        Write-Green "[✓] All workspace repositories are clean and fully pushed to remote."
        Pause-Console
        return
    }

    Write-Host "Repositories with local modifications or unpushed commits:"
    Write-Host ""
    for ($i = 0; $i -lt $dirtyRepos.Count; $i++) {
        $item = $dirtyRepos[$i]
        $r = $item.Repo; $st = $item.Status

        $details = @()
        if ($st.HasUncommitted) { $details += "$($st.UncommittedCount) modified" }
        if ($st.HasUntracked)   { $details += "$($st.UntrackedCount) untracked" }
        if ($st.HasUnpushed)    { $details += "$($st.UnpushedCount) unpushed" }
        $badge = if ($r.mode -eq "persistent") { "[PROT]" } else { "[EPHEM]" }

        Write-Host " [$($i + 1)] $($r.name) [$($st.Branch)] $badge" -NoNewline
        Write-Yellow " ($($details -join ', '))"
    }
    Write-Host ""
    Write-Host " [A] Push all pending repositories"
    Write-Host " [0] Back"
    Write-Host ""

    $choice = (Read-SafeInput " Select repository to push").ToUpper()
    if ($choice -eq "0" -or $choice -eq "B" -or [string]::IsNullOrWhiteSpace($choice)) { return }

    $selectedItems = @()
    if ($choice -eq "A") {
        $selectedItems = $dirtyRepos
    } elseif ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $dirtyRepos.Count) {
            $selectedItems = @($dirtyRepos[$idx])
        }
    }

    if ($selectedItems.Count -eq 0) {
        Write-Yellow "Invalid selection."
        Pause-Console
        return
    }

    foreach ($item in $selectedItems) {
        Write-Host ""
        Write-Cyan "Processing $($item.Repo.name) [$($item.Status.Branch)]..."
        Invoke-PushRepoWorkflow -Repo $item.Repo | Out-Null
    }

    Pause-Console
}

# -----------------------------------------------------------------------------
# [6] Remove Local Repository (Safety Guards & Confirmation)
# -----------------------------------------------------------------------------
function Invoke-RemoveSingleRepoPrompt {
    param(
        [string]$Account,
        [PSCustomObject]$TargetRepo
    )

    $st = Get-RepoStatus -RepoPath $TargetRepo.path
    Write-Host ""

    if ($TargetRepo.mode -eq "persistent") {
        Write-Yellow "[!] NOTE: '$($TargetRepo.name)' is marked as a PROTECTED (persistent) repository."
    }

    if ($st.HasUncommitted -or $st.HasUntracked -or $st.HasUnpushed) {
        Write-Red "============================================================"
        Write-Red "[WARNING] UNSAVED OR UNPUSHED CHANGES DETECTED"
        Write-Red "============================================================"
        if ($st.HasUncommitted) { Write-Yellow " • $($st.UncommittedCount) uncommitted change(s)" }
        if ($st.HasUntracked)   { Write-Yellow " • $($st.UntrackedCount) untracked file(s)" }
        if ($st.HasUnpushed)    { Write-Yellow " • $($st.UnpushedCount) unpushed commit(s)" }
        Write-Host ""
        Write-Yellow "Removing this repository will PERMANENTLY delete local changes."
        $confirm = Read-SafeInput " Type 'CONFIRM' to proceed with deletion"
        if ($confirm -ne "CONFIRM") {
            Write-Gray "Removal cancelled."
            Pause-Console
            return $false
        }
    } elseif ($TargetRepo.mode -eq "persistent") {
        $confirm = Read-SafeInput " Type '$($TargetRepo.name)' to confirm deleting this PROTECTED repository"
        if ($confirm -ne $TargetRepo.name) {
            Write-Gray "Removal cancelled."
            Pause-Console
            return $false
        }
    } else {
        $confirm = (Read-SafeInput " Are you sure you want to remove '$($TargetRepo.name)'? [Y/N]").ToUpper()
        if ($confirm -ne "Y") {
            Write-Gray "Removal cancelled."
            Pause-Console
            return $false
        }
    }

    Write-Cyan "Removing repository directory $($TargetRepo.path)..."
    $deleted = Remove-SafeDirectory -TargetDir $TargetRepo.path -WorkspaceRoot $script:Workspace
    if ($deleted) {
        Remove-ManagedRepo -Account $Account -RepoName $TargetRepo.name -RepoPath $TargetRepo.path
        Write-Green "[✓] Successfully removed '$($TargetRepo.name)' from workspace and tracking."
        Pause-Console
        return $true
    } else {
        Write-Red "[✗] Failed to completely remove directory."
        Pause-Console
        return $false
    }
}

function Invoke-ActionRemoveLocal {
    param([string]$Account)

    Clear-Host
    Write-Cyan "============================================================"
    Write-Cyan "                  REMOVE LOCAL REPOSITORY"
    Write-Cyan "============================================================"
    Write-Host ""

    $repos = @(Get-AllWorkspaceRepos -Account $Account)
    if ($repos.Count -eq 0) {
        Write-Yellow "No local repositories detected for removal."
        Pause-Console
        return
    }

    for ($i = 0; $i -lt $repos.Count; $i++) {
        $r = $repos[$i]
        $badge = if ($r.mode -eq "persistent") { "${C_GREEN}[PROTECTED]${C_RESET}" } else { "${C_CYAN}[EPHEMERAL]${C_RESET}" }
        Write-Host " [$($i + 1)] $($r.name) " -NoNewline
        Write-Gray "($($r.nameWithOwner)) " -NoNewline
        Write-Host $badge
    }
    Write-Host ""
    Write-Host " [0] Back"
    Write-Host ""

    $choice = Read-SafeInput " Select repository to remove [1-$($repos.Count), 0]"
    if ($choice -eq "0" -or $choice.ToLower() -eq "b" -or $choice.ToLower() -eq "q" -or [string]::IsNullOrWhiteSpace($choice)) { return }

    if (-not ($choice -match '^\d+$')) {
        Write-Yellow "Invalid selection."
        Pause-Console
        return
    }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $repos.Count) {
        Write-Yellow "Invalid selection."
        Pause-Console
        return
    }

    Invoke-RemoveSingleRepoPrompt -Account $Account -TargetRepo $repos[$idx] | Out-Null
}

# -----------------------------------------------------------------------------
# [7] Settings & Preferences
# -----------------------------------------------------------------------------
function Test-ValidWorkspacePath {
    param([string]$CandidatePath)
    $resolved = Resolve-CanonicalPath $CandidatePath
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved.Length -le 3) {
        return @{ Valid = $false; Reason = "Refusing root drive or empty path." }
    }
    if ((Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return @{ Valid = $false; Reason = "Path points to an existing file, not a directory." }
    }
    $forbidden = @(
        (Resolve-CanonicalPath $ScriptDir),
        (Resolve-CanonicalPath $ConfigDir),
        (Resolve-CanonicalPath $env:windir),
        (Resolve-CanonicalPath $env:ProgramFiles),
        (Resolve-CanonicalPath ${env:ProgramFiles(x86)})
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($fb in $forbidden) {
        if ($resolved.Equals($fb, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolved.StartsWith($fb + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ Valid = $false; Reason = "Cannot use protected/system/app directory ($fb)." }
        }
    }
    return @{ Valid = $true; Resolved = $resolved }
}

function Invoke-ActionSettings {
    param([string]$Account)

    while ($true) {
        if ($script:InputEof) { return }
        $s = $script:Settings
        $activeFile = Get-ActiveSettingsPath
        $isPortable = ($activeFile -eq $PortableSettingsPath)

        Clear-Host
        Write-Cyan "============================================================"
        Write-Cyan "                   SETTINGS & PREFERENCES"
        Write-Cyan "============================================================"
        Write-Host ""
        Write-Gray "Config Location: $activeFile ($(if ($isPortable) { 'PORTABLE' } else { 'AppData' }))"
        Write-Host ""

        Write-Host " [1] Workspace Path       : " -NoNewline; Write-Bold "$($s.workspacePath)"
        Write-Host " [2] Auto-Scan on Startup : " -NoNewline; if ($s.autoScanOnStartup) { Write-Green "ON" } else { Write-Yellow "OFF" }
        Write-Host " [3] Scan Depth           : " -NoNewline; Write-Cyan "$($s.scanDepth) level(s)"
        Write-Host " [4] Newly Detected Mode  : " -NoNewline; Write-Green "$($s.defaultAdoptedMode.ToUpper())"
        Write-Host " [5] Clone Strategy       : " -NoNewline; Write-Cyan "$($s.cloneMode.ToUpper()) (HTTP Buffer: $($s.httpPostBufferMB) MB)"
        Write-Host " [6] Sync Pull Strategy   : " -NoNewline; Write-Cyan "$($s.pullStrategy)"
        Write-Host " [7] Browse Page / Desc   : " -NoNewline; Write-Cyan "$($s.pageSize) items/page | Descriptions: $(if ($s.showDescriptions) { 'ON' } else { 'OFF' })"
        Write-Host " [8] Preferred Editor/Term: " -NoNewline; Write-Cyan "Editor=$($s.preferredEditor) | Term=$($s.preferredTerminal)"
        Write-Host " [9] Ignored Folders      : " -NoNewline; Write-Gray "$($s.ignoredFolders -join ', ')"
        Write-Host " [P] Toggle Portable Mode : " -NoNewline; if ($isPortable) { Write-Green "Portable (GitSession\settings.json)" } else { Write-Gray "Standard (AppData)" }
        Write-Host " [R] Reset to Defaults"
        Write-Host " [0] Save & Back"
        Write-Host ""

        $opt = (Read-SafeInput " Select setting to change").ToUpper()
        if ($script:InputEof) { return }
        switch ($opt) {
            "0" {
                Save-Settings $s
                return
            }
            "1" {
                $newWs = Read-SafeInput " Enter new Workspace directory path (or leave blank to cancel)"
                if (-not [string]::IsNullOrWhiteSpace($newWs)) {
                    $chk = Test-ValidWorkspacePath -CandidatePath $newWs
                    if (-not $chk.Valid) {
                        Write-Red "[✗] $($chk.Reason)"
                        Pause-Console
                    } else {
                        $s.workspacePath = $chk.Resolved
                        Set-ActiveWorkspace -TargetPath $chk.Resolved
                        Save-Settings $s
                        $script:LastSyncTime = $null
                        if ($s.autoScanOnStartup -and $Account) {
                            Invoke-WorkspaceDiscovery -Account $Account | Out-Null
                        }
                        Write-Green "[✓] Workspace updated to $($chk.Resolved)"
                        Start-Sleep -Milliseconds 700
                    }
                }
            }
            "2" {
                $s.autoScanOnStartup = -not $s.autoScanOnStartup
                Save-Settings $s
            }
            "3" {
                $s.scanDepth = if ($s.scanDepth -eq 1) { 2 } else { 1 }
                Save-Settings $s
            }
            "4" {
                $s.defaultAdoptedMode = switch ($s.defaultAdoptedMode) {
                    "persistent" { "ask" }
                    "ask"        { "ephemeral" }
                    default      { "persistent" }
                }
                Save-Settings $s
            }
            "5" {
                $s.cloneMode = if ($s.cloneMode -eq "full") { "shallow" } else { "full" }
                $bufIn = Read-SafeInput " HTTP Buffer in MB [Current: $($s.httpPostBufferMB)] (Enter to keep)"
                if ($bufIn -match '^\d+$' -and [int]$bufIn -ge 50) {
                    $s.httpPostBufferMB = [int]$bufIn
                }
                Save-Settings $s
            }
            "6" {
                $s.pullStrategy = switch ($s.pullStrategy) {
                    "ff-only" { "merge" }
                    "merge"   { "rebase" }
                    default   { "ff-only" }
                }
                Save-Settings $s
            }
            "7" {
                $s.pageSize = switch ([int]$s.pageSize) {
                    8  { 12 }
                    12 { 15 }
                    default { 8 }
                }
                $descToggle = (Read-SafeInput " Show repo descriptions in Browse? [Y/N, Enter to keep $($s.showDescriptions)]").ToUpper()
                if ($descToggle -eq "Y") { $s.showDescriptions = $true }
                elseif ($descToggle -eq "N") { $s.showDescriptions = $false }
                Save-Settings $s
            }
            "8" {
                $ed = Read-SafeInput " Preferred editor command (auto, code, cursor, windsurf) [Enter to keep $($s.preferredEditor)]"
                if (-not [string]::IsNullOrWhiteSpace($ed)) { $s.preferredEditor = $ed.Trim() }
                $tm = (Read-SafeInput " Preferred terminal (auto, wt, cmd, pwsh) [Enter to keep $($s.preferredTerminal)]").ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($tm)) {
                    if ($tm -in @("auto", "wt", "cmd", "pwsh")) {
                        $s.preferredTerminal = $tm
                    } else {
                        Write-Yellow "[!] Invalid terminal '$tm'. Supported: auto, wt, cmd, pwsh."
                        Start-Sleep -Milliseconds 800
                    }
                }
                Save-Settings $s
            }
            "9" {
                Write-Gray "Current ignored folders: $($s.ignoredFolders -join ', ')"
                $rawIg = Read-SafeInput " Enter comma-separated folder names to ignore (or Enter to cancel)"
                if (-not [string]::IsNullOrWhiteSpace($rawIg)) {
                    $list = @($rawIg -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if (-not ($list -contains "GitSession")) { $list = @("GitSession") + $list }
                    $s.ignoredFolders = $list
                    Save-Settings $s
                }
            }
            "P" {
                if ($isPortable) {
                    Save-Settings -SettingsObj $s -TargetPath $LocalSettingsPath
                    Remove-Item -LiteralPath $PortableSettingsPath -Force -ErrorAction SilentlyContinue
                    Write-Green "[✓] Switched back to AppData settings storage."
                } else {
                    Save-Settings -SettingsObj $s -TargetPath $PortableSettingsPath
                    Write-Green "[✓] Exported portable settings to $PortableSettingsPath"
                }
                Start-Sleep -Milliseconds 800
            }
            "R" {
                $conf = (Read-SafeInput " Reset all settings to defaults? [Y/N]").ToUpper()
                if ($conf -eq "Y") {
                    $script:Settings = Get-DefaultSettings
                    Save-Settings $script:Settings
                    Set-ActiveWorkspace -TargetPath $script:Settings.workspacePath
                    Write-Green "[✓] Settings restored to defaults."
                    Start-Sleep -Milliseconds 700
                }
            }
            default {
                Write-Yellow "Invalid option."
                Start-Sleep -Milliseconds 400
            }
        }
    }
}

# -----------------------------------------------------------------------------
# [8] Logout & Clean Workspace (Strictly Deletes Ephemeral Repos ONLY)
# -----------------------------------------------------------------------------
function Invoke-ActionLogout {
    param([string]$Account)

    Clear-Host
    Write-Cyan "============================================================"
    Write-Cyan "                 LOGOUT & CLEAN WORKSPACE"
    Write-Cyan "============================================================"
    Write-Host ""

    # Strictly fetch ONLY ephemeral repos belonging to this account
    $ephemeralRepos = @(Get-EphemeralRepos -Account $Account -CurrentWorkspaceOnly)
    $protectedRepos = @(Get-ProtectedRepos -CurrentWorkspaceOnly)

    if ($protectedRepos.Count -gt 0) {
        $protNames = ($protectedRepos | ForEach-Object { $_.name }) -join ", "
        Write-Gray "Protected workspace repos preserved untouched ($($protectedRepos.Count)): $protNames"
        Write-Host ""
    }

    $dirtyRepos = @()
    foreach ($r in $ephemeralRepos) {
        $st = Get-RepoStatus -RepoPath $r.path
        if ($st.HasUncommitted -or $st.HasUntracked -or $st.HasUnpushed) {
            $dirtyRepos += [PSCustomObject]@{ Repo = $r; Status = $st }
        }
    }

    if ($dirtyRepos.Count -gt 0) {
        Write-Red "============================================================"
        Write-Red "[!] WARNING: UNSAVED OR UNPUSHED EPHEMERAL WORK DETECTED"
        Write-Red "============================================================"
        Write-Host ""
        foreach ($d in $dirtyRepos) {
            $r = $d.Repo; $st = $d.Status
            $details = @()
            if ($st.HasUncommitted) { $details += "$($st.UncommittedCount) uncommitted" }
            if ($st.HasUntracked)   { $details += "$($st.UntrackedCount) untracked" }
            if ($st.HasUnpushed)    { $details += "$($st.UnpushedCount) unpushed" }
            Write-Yellow "  • $($r.name) [$($st.Branch)]: $($details -join ', ')"
        }
        Write-Host ""
        Write-Host " [P] Push changes now (auto-commit and push to GitHub)"
        Write-Host " [C] Cancel logout (preserve session and files)"
        Write-Host " [F] Force deletion & Logout (DISCARD LOCAL CHANGES)"
        Write-Host ""

        $decision = (Read-SafeInput " Select an option [P/C/F]").ToUpper()
        if ($script:InputEof -or $decision -eq "C" -or [string]::IsNullOrWhiteSpace($decision)) {
            Write-Gray "Logout cancelled."
            if (-not $script:InputEof) { Pause-Console }
            return $false
        } elseif ($decision -eq "P") {
            foreach ($d in $dirtyRepos) {
                Write-Host ""
                $ok = Invoke-PushRepoWorkflow -Repo $d.Repo -DefaultCommitMessage "GitSession: auto-save before logout" -AutoCommitAll
                if (-not $ok) {
                    Write-Red "[✗] Push failed for $($d.Repo.name). Aborting cleanup to prevent data loss."
                    Pause-Console
                    return $false
                }
            }
        } elseif ($decision -eq "F") {
            $confirmForce = Read-SafeInput " Type 'CONFIRM' to permanently discard unsaved ephemeral work"
            if ($confirmForce -ne "CONFIRM") {
                Write-Gray "Logout cancelled."
                Pause-Console
                return $false
            }
        } else {
            Write-Yellow "Invalid option. Logout cancelled."
            Pause-Console
            return $false
        }
    } else {
        if ($ephemeralRepos.Count -gt 0) {
            Write-Yellow "This will delete $($ephemeralRepos.Count) EPHEMERAL repository directory(ies) in $($script:WorkspaceDisplay)."
        } else {
            Write-Gray "No ephemeral directories queued for deletion."
        }
        $confirm = (Read-SafeInput " Are you sure you want to log out and clean workspace? [Y/N]").ToUpper()
        if ($script:InputEof -or $confirm -ne "Y") {
            Write-Gray "Logout cancelled."
            if (-not $script:InputEof) { Pause-Console }
            return $false
        }
    }

    Write-Host ""
    Write-Cyan "Cleaning ephemeral workspace repositories..."

    $allCleaned = $true
    foreach ($r in $ephemeralRepos) {
        Write-Host "  Removing $($r.name)..." -NoNewline
        $deleted = Remove-SafeDirectory -TargetDir $r.path -WorkspaceRoot $script:Workspace
        if ($deleted) {
            Write-Green " [DELETED]"
        } else {
            Write-Red " [FAILED/SKIPPED]"
            $allCleaned = $false
        }
    }

    Clear-ManagedRepos $Account
    $script:CachedRepoList = @()
    $script:CachedRepoUser = ""

    if (Test-Path -LiteralPath $TempDir) {
        Get-ChildItem -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Cyan "Clearing isolated GitSession authentication files..."
    # Remove isolated hosts/state files rather than invoking 'gh auth logout'
    # so global Windows Credential Manager keyring sessions are never modified.
    foreach ($ghFile in @("hosts.yml", "state.yml")) {
        $p = Join-Path $IsolatedGhDir $ghFile
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    if ($allCleaned) {
        Write-Green "[✓] Workspace successfully cleaned and logged out."
        if ($protectedRepos.Count -gt 0) {
            Write-Gray "Protected repositories ($($protectedRepos.Count)) remain untouched."
        }
    } else {
        Write-Yellow "[!] Logged out, but one or more ephemeral directories could not be deleted."
    }

    Pause-Console
    return $true
}

# -----------------------------------------------------------------------------
# Main Loop and Dashboard
# -----------------------------------------------------------------------------
function Start-GitSession {
    $startupScanDone = $false

    while ($true) {
        if ($script:InputEof) { exit 0 }
        $account = Get-AuthUser

        if ($account) {
            if (-not $startupScanDone -and $script:Settings.autoScanOnStartup) {
                $disc = Invoke-WorkspaceDiscovery -Account $account
                $startupScanDone = $true
                if ($disc.NewlyAdopted.Count -gt 0) {
                    $names = ($disc.NewlyAdopted | ForEach-Object { $_.name }) -join ", "
                    $script:LastDiscoveryMsg = "Auto-discovered $($disc.NewlyAdopted.Count) Protected repo(s): $names"
                }
            }

            $ephemRepos = @(Get-EphemeralRepos -Account $account -CurrentWorkspaceOnly)
            $protRepos  = @(Get-ProtectedRepos -CurrentWorkspaceOnly)
            $allLocal   = @($ephemRepos) + @($protRepos)

            Clear-Host
            Write-Cyan "============================================"
            Write-Cyan "                 GITSESSION"
            Write-Cyan "       Ephemeral Git Workspace Manager"
            Write-Cyan "============================================"
            Write-Host ""
            Write-Host " Status     : " -NoNewline; Write-Green "Authenticated"
            Write-Host " Account    : " -NoNewline; Write-Bold "@$account"
            Write-Host " Workspace  : " -NoNewline; Write-Host "$($script:WorkspaceDisplay)"
            Write-Host " Local Repos: " -NoNewline
            Write-Bold "$($allLocal.Count) " -NoNewline
            Write-Gray "($($ephemRepos.Count) Ephemeral, $($protRepos.Count) Protected)"
            if (-not [string]::IsNullOrWhiteSpace($script:LastDiscoveryMsg)) {
                Write-Green " Notice     : $($script:LastDiscoveryMsg)"
                $script:LastDiscoveryMsg = ""
            }
            Write-Host ""
            Write-Host " [1] Browse & Clone Repository"
            Write-Host " [2] Sync & Pull Workspace"
            Write-Host " [3] Local Repositories & Repo Actions"
            Write-Host " [4] Open Workspace in Explorer"
            Write-Host " [5] Push Local Changes"
            Write-Host " [6] Remove Local Repository"
            Write-Host " [7] Settings & Preferences"
            Write-Host " [8] Logout & Clean Workspace"
            Write-Host " [0] Exit"
            Write-Host ""

            $choice = Read-SafeInput " Select an option [0-8]"
            if ($script:InputEof) { exit 0 }

            switch ($choice) {
                "1" { Invoke-ActionBrowseClone -Account $account }
                "2" { Invoke-ActionSync -Account $account }
                "3" { Invoke-ActionViewLocal -Account $account }
                "4" { Invoke-ActionOpenExplorer }
                "5" { Invoke-ActionPush -Account $account }
                "6" { Invoke-ActionRemoveLocal -Account $account }
                "7" { Invoke-ActionSettings -Account $account }
                "8" {
                    $loggedOut = Invoke-ActionLogout -Account $account
                    if ($loggedOut) { $startupScanDone = $false }
                }
                "0" {
                    Clear-Host
                    Write-Cyan "Exiting GitSession."
                    Write-Gray "Your active session and local repositories are preserved."
                    Write-Host ""
                    exit 0
                }
                default {
                    Write-Yellow "Invalid option. Please choose between [0] and [8]."
                    Start-Sleep -Milliseconds 500
                }
            }
        } else {
            $startupScanDone = $false
            Clear-Host
            Write-Cyan "============================================"
            Write-Cyan "                 GITSESSION"
            Write-Cyan "============================================"
            Write-Host ""
            Write-Host " Status: " -NoNewline; Write-Yellow "Not authenticated"
            Write-Host ""
            Write-Host " [1] Login with GitHub"
            Write-Host " [0] Exit"
            Write-Host ""

            $choice = Read-SafeInput " Select an option [0-1]"
            if ($script:InputEof) { exit 0 }

            switch ($choice) {
                "1" { Invoke-GitHubLogin }
                "0" {
                    Clear-Host
                    Write-Cyan "Exiting GitSession."
                    Write-Host ""
                    exit 0
                }
                default {
                    Write-Yellow "Invalid option. Please choose [1] or [0]."
                    Start-Sleep -Milliseconds 500
                }
            }
        }
    }
}

# Run main session unless loaded in test/module mode
if (-not $env:GITSESSION_TEST_MODE) {
    Start-GitSession
}
