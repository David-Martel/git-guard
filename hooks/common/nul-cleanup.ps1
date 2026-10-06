<#
.SYNOPSIS
    Safely audit Windows-invalid paths within the active Git worktree.
.DESCRIPTION
    One traversal; no reparse-point descent or foreign Git/worktree cleanup.
    Nonempty and ambiguous matches are always preserved and reported. This
    PowerShell entry point intentionally preserves even zero-byte matches until
    native Windows handle-based deletion has been implemented and qualified.
    FileInfo followed by File.Delete cannot bind deletion to the inspected file
    identity. It must not provide an unsafe fallback to the POSIX hook.
    Normal pre-commit invokes nul-cleanup.sh through Git's POSIX environment.
    NukeNul and force/rename/cmd deletion fallbacks are deliberately unsupported.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Path,
    [switch] $DryRun,
    [switch] $Quiet
)
$ErrorActionPreference = 'Stop'

function Write-Result([string] $Kind, [string] $Value) {
    # Errors and preserved matches are never suppressed by Quiet.
    [Console]::Error.WriteLine('{0}: {1}', $Kind, $Value)
}

function Test-ReservedLeaf([string] $Name) {
    $leaf = $Name.TrimEnd(' ', '.')
    $stem = (($leaf -split '\.', 2)[0]).TrimEnd(' ', '.')
    return $stem -match '^(?i:\$null|nul|con|prn|aux|com[1-9]|lpt[1-9])$'
}

try {
    $gitRoot = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $gitRoot -or $gitRoot -is [array]) {
        throw 'cannot determine one active Git worktree'
    }
    $root = [IO.Path]::GetFullPath([string] $gitRoot).TrimEnd('\', '/')
    if ($Path -and [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') -ne $root) {
        throw 'Path must equal the active Git worktree; arbitrary roots are refused'
    }
    if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\', '/') -or $root -eq $HOME) {
        throw 'broad workspace root refused'
    }
    if (([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'reparse-point workspace root refused'
    }
    $gitDirectory = & git rev-parse --absolute-git-dir
    if ($LASTEXITCODE -ne 0) { throw 'cannot resolve Git metadata directory' }
    $gitCommon = & git rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0) { throw 'cannot resolve common Git metadata directory' }
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push([IO.DirectoryInfo]::new($root))
    $blocked = $false
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        # Recheck an enumerated directory before descent; never follow a new
        # junction/symlink. No deletion occurs even if replacement races this read.
        $directory.Refresh()
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Result 'PRESERVED_SCOPE' $directory.FullName
            continue
        }
        foreach ($entry in $directory.EnumerateFileSystemInfos()) {
            $entry.Refresh()
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (Test-ReservedLeaf $entry.Name) {
                    Write-Result 'PRESERVED_NONREGULAR' $entry.FullName
                    $blocked = $true
                }
                continue
            }
            if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                if ($entry.Name -in @('.git', 'worktrees', '.worktrees') -or
                    $entry.FullName -eq $gitDirectory -or $entry.FullName -eq $gitCommon -or
                    [IO.File]::Exists([IO.Path]::Combine($entry.FullName, '.git')) -or
                    [IO.Directory]::Exists([IO.Path]::Combine($entry.FullName, '.git')) -or
                    ([IO.File]::Exists([IO.Path]::Combine($entry.FullName, 'HEAD')) -and
                     [IO.Directory]::Exists([IO.Path]::Combine($entry.FullName, 'objects')) -and
                     [IO.Directory]::Exists([IO.Path]::Combine($entry.FullName, 'refs')))) {
                    if ($entry.Name -ne '.git') { Write-Result 'PRESERVED_SCOPE' $entry.FullName }
                    continue
                }
                $pending.Push([IO.DirectoryInfo] $entry)
                continue
            }
            if (-not (Test-ReservedLeaf $entry.Name)) { continue }
            if ([IO.FileInfo]::new($entry.FullName).Length -ne 0) {
                Write-Result 'PRESERVED_NONEMPTY' $entry.FullName
            }
            elseif ($DryRun) { Write-Result 'PRESERVED_DRY_RUN' $entry.FullName }
            else { Write-Result 'PRESERVED_UNQUALIFIED_DELETE' $entry.FullName }
            $blocked = $true
        }
    }
    if ($blocked -and -not $DryRun) { exit 1 }
    exit 0
}
catch {
    Write-Result 'ERROR_TRAVERSAL' $_.Exception.Message
    exit 1
}
