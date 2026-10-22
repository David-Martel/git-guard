#Requires -Version 7.1
<#
.SYNOPSIS
Updates known Windows Git SSH wrapper predecessors from an installed git-guard release.
.DESCRIPTION
Default is a read-only plan. Apply changes only the existing JavaScript file,
preserving its ACL and the legacy CMD launcher. Git configuration is never changed.
See docs/QA_TOOLING.md#optional-windows-git-ssh-adapter and tests/33-windows-ssh-adapter.t.sh.
.PARAMETER SourceRoot
Already-materialized git-guard release; defaults to the installed current release.
.PARAMETER BinDirectory
Directory containing both existing, known legacy wrapper files.
.PARAMETER Apply
Promotes validated source bytes after exclusive target revalidation.
.EXAMPLE
./tools/windows/install-git-ssh-wrapper.ps1
Shows the planned migration without changing wrappers or Git configuration.
.EXAMPLE
./tools/windows/install-git-ssh-wrapper.ps1 -Apply
Updates known legacy JavaScript from the installed current release.
#>
[CmdletBinding()]
param(
    [string]$SourceRoot = (Join-Path $HOME '.local/share/git-guard/current'),
    [string]$BinDirectory = (Join-Path $HOME 'bin'),
    [switch]$Apply
)

function Get-WrapperStreamHash {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    # HashData(Stream) is newer than .NET5; ComputeHash preserves PowerShell7.1.
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToHexString($algorithm.ComputeHash($Stream)) }
    finally { $algorithm.Dispose() }
}

function Receive-WrapperSyntaxOutput {
    param(
        [Parameter(Mandatory)][Threading.Tasks.Task[string]]$Stdout,
        [Parameter(Mandatory)][Threading.Tasks.Task[string]]$Stderr,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$TimeoutMilliseconds
    )
    # Exited parent does not imply EOF: another process may retain a pipe handle.
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Stdout, $Stderr), $TimeoutMilliseconds)) {
        throw 'Node syntax validation output drain timed out before any target write.'
    }
    # Completed tasks cannot wait for handles; faults surface before any target opens.
    $null = $Stdout.GetAwaiter().GetResult()
    $Stderr.GetAwaiter().GetResult()
}

function Invoke-WrapperSyntaxCheck {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$TimeoutMilliseconds
    )
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    try {
        if (-not $process.Start()) { throw 'Node syntax validation did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $cleanupMilliseconds = [Math]::Min(1000, $TimeoutMilliseconds)
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            if (-not $process.WaitForExit($cleanupMilliseconds)) {
                throw 'Node syntax validation timed out; owned child did not exit within bounded cleanup.'
            }
            throw 'Node syntax validation timed out before any target write.'
        }
        $diagnostic = Receive-WrapperSyntaxOutput -Stdout $stdout -Stderr $stderr -TimeoutMilliseconds $cleanupMilliseconds
        if ($process.ExitCode -ne 0) { throw "Materialized JavaScript failed syntax validation: $diagnostic" }
    } finally { $process.Dispose() }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This optional adapter installer requires native Windows.' }
$legacyJsHash = '46D2615192CB8EBAADBF2FA43DAB8B1C93FEFE79260F61FB8571FDBAFE7A2EF1'
# Reviewed predecessor with preserved quoting and the former 5min push budget.
$pushBaselineJsHash = '27758C691F894F76EEFCFC59ED2939E90D15993682C872F1F464B0195B678183'
$launcherHash = 'A7C81A417092D46D2F4F56F57E36B679B15A451F6C0A44F973A66DAA96ED542B'
$marker = Join-Path $SourceRoot '.git-guard-commit'
if (-not [IO.File]::Exists($marker) -or -not [IO.File]::Exists((Join-Path $SourceRoot 'VERSION'))) {
    throw 'SourceRoot must be an already-materialized git-guard release with a commit marker and VERSION.'
}
$commit = [IO.File]::ReadAllText($marker).Trim()
if ($commit -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid materialized release commit marker.' }
$sourceJs = Join-Path $SourceRoot 'tools/windows/git-ssh-wrapper.js'
$sourceCmd = Join-Path $SourceRoot 'tools/windows/git-ssh-wrapper.cmd'
$sourceBytes = [IO.File]::ReadAllBytes($sourceJs)
$sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes))
if ((Get-FileHash -LiteralPath $sourceCmd -Algorithm SHA256).Hash -ne $launcherHash) {
    throw 'Materialized launcher differs from the known legacy launcher; refusing migration.'
}

# Check the actual source without a shell, visible console or network connection.
$node = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
if ([IO.Path]::GetExtension($node) -ine '.exe') { throw 'Node syntax validation requires a native node.exe executable.' }
$start = [Diagnostics.ProcessStartInfo]::new($node)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.ArgumentList.Add('--check')
$start.ArgumentList.Add($sourceJs)
Invoke-WrapperSyntaxCheck -StartInfo $start -TimeoutMilliseconds 10000

$targetCmd = Join-Path $BinDirectory 'git-ssh-wrapper.cmd'
$targetJs = Join-Path $BinDirectory 'git-ssh-wrapper.js'
foreach ($path in @($targetCmd, $targetJs)) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Existing wrapper must be a regular file; unknown link/directory preserved.'
    }
}
$cmdStream = $null
$jsStream = $null
try {
    # Hold both targets against concurrent writers/deletion; preserve their existing ACLs.
    $cmdStream = [IO.File]::Open($targetCmd, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $access = if ($Apply) { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }
    $jsStream = [IO.File]::Open($targetJs, [IO.FileMode]::Open, $access, [IO.FileShare]::None)
    if ((Get-WrapperStreamHash -Stream $cmdStream) -ne $launcherHash) {
        throw 'Existing CMD has unknown bytes; preserving local work.'
    }
    $targetHash = Get-WrapperStreamHash -Stream $jsStream
    if ($targetHash -eq $sourceHash) {
        return [pscustomobject]@{ Status = 'Current'; Commit = $commit; SHA256 = $sourceHash }
    }
    if ($targetHash -notin @($legacyJsHash, $pushBaselineJsHash)) {
        throw 'Existing JavaScript has unknown bytes; only exact known wrapper predecessors are accepted.'
    }
    if (-not $Apply) {
        return [pscustomobject]@{ Status = 'Planned'; Commit = $commit; SHA256 = $sourceHash }
    }
    $jsStream.Position = 0
    $original = [byte[]]::new([int]$jsStream.Length)
    $read = 0
    while ($read -lt $original.Length) {
        $count = $jsStream.Read($original, $read, $original.Length - $read)
        if ($count -eq 0) { throw 'Legacy JavaScript ended unexpectedly before any write.' }
        $read += $count
    }
    try {
        $jsStream.Position = 0
        $jsStream.Write($sourceBytes, 0, $sourceBytes.Length)
        $jsStream.SetLength($sourceBytes.Length)
        $jsStream.Flush($true)
        $jsStream.Position = 0
        if ((Get-WrapperStreamHash -Stream $jsStream) -ne $sourceHash) {
            throw 'Installed JavaScript readback failed.'
        }
    } catch {
        # Known legacy bytes stay only in memory, never as a redundant backup file.
        $jsStream.Position = 0
        $jsStream.Write($original, 0, $original.Length)
        $jsStream.SetLength($original.Length)
        $jsStream.Flush($true)
        throw
    }
    [pscustomobject]@{ Status = 'Installed'; Commit = $commit; SHA256 = $sourceHash }
} finally {
    if ($null -ne $jsStream) { $jsStream.Dispose() }
    if ($null -ne $cmdStream) { $cmdStream.Dispose() }
}
