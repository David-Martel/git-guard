#Requires -Version 7.1
<#
.SYNOPSIS
Publishes the Windows installer's hooksPath without losing config security.
.DESCRIPTION
Internal install.sh helper. Native Git serializes a private payload. A normal
Git .lock fences writers; a same-parent stage qualifies the exact owner, group
and DACL before atomic replacement. Successful transactions retain no originals.
See tests/27-install-native-links.t.sh and docs/QA_TOOLING.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GitExecutable,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$HooksPath,
    [string]$DefaultsScript,
    [string]$GitShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The native config publisher requires Windows.' }
$inputLeaf = [IO.Path]::GetFileName($ConfigPath)
if ([string]::IsNullOrEmpty($inputLeaf) -or $inputLeaf.EndsWith(' ') -or $inputLeaf.EndsWith('.')) {
    throw 'Ambiguous trailing-dot/space config destination refused before normalization.'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$HooksPath = [IO.Path]::GetFullPath($HooksPath)
$parent = [IO.Path]::GetDirectoryName($ConfigPath)
$leaf = [IO.Path]::GetFileName($ConfigPath).TrimEnd(' ', '.')
$stem = $leaf.Split('.')[0].TrimEnd(' ')
if ($leaf -ceq '$null' -or $stem -match '^(?i:AUX|CON|NUL|PRN|COM[1-9]|LPT[1-9])$') {
    throw 'Reserved Windows config destination refused.'
}
if (-not [IO.Directory]::Exists($parent)) { throw 'Global config parent does not exist.' }
if ([string]::IsNullOrEmpty($DefaultsScript) -xor [string]::IsNullOrEmpty($GitShell)) {
    throw 'Defaults publication requires both the maintained script and native Git shell.'
}
if ($DefaultsScript -and (-not [IO.Path]::IsPathFullyQualified($DefaultsScript) -or
        -not [IO.File]::Exists($DefaultsScript) -or -not [IO.Path]::IsPathFullyQualified($GitShell) -or
        -not [IO.File]::Exists($GitShell))) {
    throw 'Defaults script and native shell must be existing absolute paths.'
}

function Invoke-ConfigProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$EnvironmentValues = @{}
    )
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($key in $EnvironmentValues.Keys) { $start.Environment[$key] = $EnvironmentValues[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Native Git config process did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill($true)
            if (-not $process.WaitForExit(1000)) { throw 'Owned Git config child did not reap.' }
            throw 'Native Git config operation timed out.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 1000)) {
            throw 'Native Git config output drain timed out.'
        }
        [pscustomobject]@{ Exit = $process.ExitCode; Out = $stdout.Result; Error = $stderr.Result }
    } finally { $process.Dispose() }
}

function Initialize-PrivateConfigStage {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    $actual = Get-Acl -LiteralPath $Path
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    $rules = $actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    if (-not $actual.AreAccessRulesProtected -or @($rules | Where-Object {
                $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed
            }).Count -ne 0) {
        throw 'Private staging permissions did not qualify before content.'
    }
}

function Test-ConfigCopyDescriptor {
    param(
        [Parameter(Mandatory)][byte[]]$Expected,
        [Parameter(Mandatory)][byte[]]$Actual
    )
    if ($Expected.Length -lt 4 -or $Expected.Length -ne $Actual.Length) { return $false }
    if ([Convert]::ToBase64String($Expected) -ceq [Convert]::ToBase64String($Actual)) { return $true }
    # Windows can add only SE_DACL_AUTO_INHERITED when copying a descriptor.
    # Compare the whole returned serialization, including represented opaque/
    # SACL fields, after removing only that forward-added bit from Actual.
    $beforeControl = [BitConverter]::ToUInt16($Expected, 2)
    $afterControl = [BitConverter]::ToUInt16($Actual, 2)
    if (($beforeControl -band 0x0400) -ne 0 -or $afterControl -ne ($beforeControl -bor 0x0400)) {
        return $false
    }
    $copy = [byte[]]$Actual.Clone()
    $copy[3] = $copy[3] -band 0xfb
    [Convert]::ToBase64String($Expected) -ceq [Convert]::ToBase64String($copy)
}

# No parser or path spelling rewrite: Git for Windows stores a native path.
$current = Invoke-ConfigProcess -Executable $GitExecutable -Arguments @('config', '--global', '--get', 'core.hooksPath')
$hooksEquivalent = $current.Exit -eq 0 -and [IO.Path]::IsPathFullyQualified($current.Out.Trim()) -and
    [IO.Path]::GetFullPath($current.Out.Trim()).TrimEnd('\', '/') -ieq $HooksPath.TrimEnd('\', '/')
if ($hooksEquivalent -and -not $DefaultsScript) {
    Write-Output '  core.hooksPath already equivalent; global config untouched'
    return
}
if ($current.Exit -notin @(0, 1)) { throw "Cannot read global hooksPath: $($current.Error)" }

$lockPath = $ConfigPath + '.lock'
$workspace = Join-Path $parent ('.git-guard-config.' + [guid]::NewGuid().ToString('N'))
$serialized = Join-Path $workspace 'serialized.config'
# Keep the displaced original in its existing inheritance context. A backup in
# the private staging directory can itself acquire different inheritance flags.
$original = Join-Path $parent ('.git-guard-config-original.' + [guid]::NewGuid().ToString('N'))
$lock = $null
$ownedLock = $false
$workspaceCreated = $false
$publicationAttempted = $false
$validated = $false
try {
    # CreateNew is Git's normal cooperative lock. Existing locks are never removed.
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $ownedLock = $true
    $newFileDescriptor = (Get-Acl -LiteralPath $lockPath).GetSecurityDescriptorBinaryForm()
    Initialize-PrivateConfigStage -Path $lockPath
    $exists = [IO.File]::Exists($ConfigPath)
    $before = [byte[]]::new(0)
    $expectedDescriptor = $newFileDescriptor
    if ($exists) {
        $item = Get-Item -LiteralPath $ConfigPath -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Global config must be a regular file; existing link/directory preserved.'
        }
        $expectedDescriptor = (Get-Acl -LiteralPath $ConfigPath).GetSecurityDescriptorBinaryForm()
        $before = [IO.File]::ReadAllBytes($ConfigPath)
    } elseif (Test-Path -LiteralPath $ConfigPath) {
        throw 'Unknown global config destination type preserved.'
    }
    $null = [IO.Directory]::CreateDirectory($workspace)
    $workspaceCreated = $true
    Initialize-PrivateConfigStage -Path $workspace
    [IO.File]::WriteAllBytes($serialized, $before)
    # Recompute from the actual captured preimage under our lock. An earlier
    # global read can become stale before a cooperative writer releases it.
    $capturedHooks = Invoke-ConfigProcess -Executable $GitExecutable -Arguments @('config', '--file', $serialized, '--get', 'core.hooksPath')
    if ($capturedHooks.Exit -notin @(0, 1)) { throw "Cannot read captured hooksPath: $($capturedHooks.Error)" }
    $capturedEquivalent = $capturedHooks.Exit -eq 0 -and [IO.Path]::IsPathFullyQualified($capturedHooks.Out.Trim()) -and
        [IO.Path]::GetFullPath($capturedHooks.Out.Trim()).TrimEnd('\', '/') -ieq $HooksPath.TrimEnd('\', '/')
    if (-not $capturedEquivalent) {
        $result = Invoke-ConfigProcess -Executable $GitExecutable -Arguments @('config', '--file', $serialized, 'core.hooksPath', $HooksPath)
        if ($result.Exit -ne 0) { throw "Git could not serialize config stage: $($result.Error)" }
    }
    if ($DefaultsScript) {
        # Reuse the maintained defaults and preserve its existing-choice policy.
        # Only this child's global destination changes; native tools precede
        # home shims without changing the caller or machine environment.
        $toolPath = [IO.Path]::GetDirectoryName($GitExecutable) + ';' +
            [IO.Path]::GetDirectoryName($GitShell) + ';' + $env:PATH
        $result = Invoke-ConfigProcess -Executable $GitShell -Arguments @($DefaultsScript, 'defaults') -EnvironmentValues @{
            GIT_CONFIG_GLOBAL = $serialized
            PATH = $toolPath
        }
        if ($result.Exit -ne 0 -or -not [string]::IsNullOrWhiteSpace($result.Error)) {
            throw "Defaults could not serialize private config stage: $($result.Error)"
        }
        Write-Output $result.Out.TrimEnd()
    }
    $payload = [IO.File]::ReadAllBytes($serialized)
    if ($exists -and [Convert]::ToBase64String($payload) -ceq [Convert]::ToBase64String($before)) {
        Write-Output '  hooksPath and defaults already equivalent; global config untouched'
        return
    }
    $lock.Write($payload, 0, $payload.Length)
    $lock.Flush($true)

    # A sibling stage gets the same inherited ACEs. Refuse before publication if
    # owner/group cannot be assigned. Avoid Set-Acl normalization when exact.
    $actualStage = (Get-Acl -LiteralPath $lockPath).GetSecurityDescriptorBinaryForm()
    if (-not (Test-ConfigCopyDescriptor -Expected $expectedDescriptor -Actual $actualStage)) {
        $descriptor = [Security.AccessControl.FileSecurity]::new()
        $sections = [Security.AccessControl.AccessControlSections]::Owner -bor
            [Security.AccessControl.AccessControlSections]::Group -bor
            [Security.AccessControl.AccessControlSections]::Access
        $descriptor.SetSecurityDescriptorBinaryForm($expectedDescriptor, $sections)
        Set-Acl -LiteralPath $lockPath -AclObject $descriptor
    }
    $actualStage = (Get-Acl -LiteralPath $lockPath).GetSecurityDescriptorBinaryForm()
    if (-not (Test-ConfigCopyDescriptor -Expected $expectedDescriptor -Actual $actualStage)) {
        throw 'Stage owner/group/DACL differs; original config untouched.'
    }
    if ($exists) {
        if (-not [IO.File]::Exists($ConfigPath) -or
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($ConfigPath)) -cne [Convert]::ToBase64String($before) -or
                [Convert]::ToBase64String((Get-Acl -LiteralPath $ConfigPath).GetSecurityDescriptorBinaryForm()) -cne
                    [Convert]::ToBase64String($expectedDescriptor)) {
            throw 'Original config bytes or descriptor changed; preserving concurrent work.'
        }
    } elseif (Test-Path -LiteralPath $ConfigPath) {
        throw 'Global config appeared concurrently; preserving it.'
    }
    $lock.Dispose()
    $lock = $null
    if (Test-Path -LiteralPath $original) { throw 'Transaction original destination already exists; preserving it.' }
    $publicationAttempted = $true
    if ($exists) {
        # ReplaceFile preserves DACL, not O/G: the stage already has all three.
        # Its transaction original is removed only after verified publication.
        [IO.File]::Replace($lockPath, $ConfigPath, $original, $false)
        # The actual displaced file, not a prior read, owns unique concurrent
        # work. Never normalize it or delete it without exact preimage equality.
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($original)) -cne [Convert]::ToBase64String($before) -or
                [Convert]::ToBase64String((Get-Acl -LiteralPath $original).GetSecurityDescriptorBinaryForm()) -cne
                    [Convert]::ToBase64String($expectedDescriptor)) {
            throw 'Actual displaced original differs from captured bytes or descriptor; preserve transaction.'
        }
    } else {
        [IO.File]::Move($lockPath, $ConfigPath)
    }
    $ownedLock = $false
    $actualPublished = (Get-Acl -LiteralPath $ConfigPath).GetSecurityDescriptorBinaryForm()
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ConfigPath)) -cne [Convert]::ToBase64String($payload) -or
            -not (Test-ConfigCopyDescriptor -Expected $expectedDescriptor -Actual $actualPublished)) {
        throw 'Published config bytes or descriptor differ; transaction evidence retained.'
    }
    $validated = $true
    Write-Output '  core.hooksPath published atomically with original owner/group/DACL'
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if ($validated -and $exists -and (
            -not [IO.File]::Exists($original) -or
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($original)) -cne [Convert]::ToBase64String($before) -or
            [Convert]::ToBase64String((Get-Acl -LiteralPath $original).GetSecurityDescriptorBinaryForm()) -cne
                [Convert]::ToBase64String($expectedDescriptor))) {
        $validated = $false
        throw 'Transaction original changed before cleanup; preserve transaction.'
    }
    if ($validated -or -not $publicationAttempted) {
        if ($ownedLock -and [IO.File]::Exists($lockPath)) { [IO.File]::Delete($lockPath) }
        if ($workspaceCreated) {
            foreach ($path in @($serialized, ($serialized + '.lock'))) {
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            }
            [IO.Directory]::Delete($workspace)
        }
        if ($validated -and $exists) { [IO.File]::Delete($original) }
    } else {
        Write-Warning "Unexpected publication failure; preserve $original, $lockPath and $workspace for diagnosis."
    }
}
