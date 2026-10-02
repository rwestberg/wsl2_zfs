[CmdletBinding()]
param([string] $BashPath)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$installerPath = Join-Path $repoRoot 'scripts/install-wsl2-zfs.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors) {
    throw ($parseErrors | Out-String)
}

# Load the image resolver without running the installer or any WSL commands.
$resolver = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-StockModulesVhd'
}, $true)
if (-not $resolver) { throw 'Stock image resolver not found.' }
. ([scriptblock]::Create($resolver.Extent.Text))

$assignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$mergeScript'
}, $true)
if (-not $assignment) { throw 'Embedded merge script not found.' }
$mergeString = $assignment.Right.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
}, $true)
if (-not $mergeString) { throw 'Embedded merge script is not a literal string.' }

$replacementTry = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and
        $node.Extent.Text -match '^try\s*\{\s*Move-Item -LiteralPath \$modulesBuildPath'
}, $true)
if (-not $replacementTry) { throw 'VHD replacement try/catch not found.' }
$replacementBlock = [scriptblock]::Create($replacementTry.Extent.Text)

$workflowText = Get-Content (Join-Path $repoRoot '.github/workflows/build.yml') -Raw
$containerMatch = [regex]::Match($workflowText, "(?s)bash -lc '(.+?)\r?\n\s*'\r?\n")
if (-not $containerMatch.Success) { throw 'Container build shell body not found.' }

if (-not $BashPath) {
    if ($env:OS -eq 'Windows_NT') {
        $BashPath = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
    } else {
        $BashPath = (Get-Command bash -ErrorAction Stop).Source
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -ne $Expected) { throw "${Message}: expected '$Expected', got '$Actual'" }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected an error matching '$Pattern'."
}

# The replacement block runs real file operations on fixtures; ACL resets are simulated.
function Reset-FileAcl {
    param([string] $Path)
    if ($failAclReset) { throw 'Simulated icacls failure' }
}

function Test-VhdReplacement {
    param([string] $Name, [bool] $ExistingVhd, [bool] $FailAcl, [bool] $MissingStagedVhd)

    $caseRoot = Join-Path $workRoot $Name
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $destinationPath = Join-Path $caseRoot 'modules.vhdx'
    $modulesBuildPath = Join-Path $caseRoot 'staged.vhdx'
    $destinationBackupPath = $null
    if ($ExistingVhd) {
        $destinationBackupPath = "$destinationPath.bak"
        [System.IO.File]::WriteAllText($destinationBackupPath, 'old working VHD')
    }
    if (-not $MissingStagedVhd) {
        [System.IO.File]::WriteAllText($modulesBuildPath, 'new VHD')
    }
    $failAclReset = $FailAcl
    if ($FailAcl) {
        Assert-Throws { & $replacementBlock } '*Simulated icacls failure*'
    } elseif ($MissingStagedVhd) {
        Assert-Throws { & $replacementBlock } '*does not exist*'
    } else {
        & $replacementBlock
    }
    if ($FailAcl -or $MissingStagedVhd) {
        if ($ExistingVhd) {
            Assert-Equal (Get-Content -LiteralPath $destinationPath -Raw) 'old working VHD' 'Restore previous VHD'
            Assert-Equal (Test-Path -LiteralPath $destinationBackupPath) $false 'Backup restored to active path'
        } else {
            Assert-Equal (Test-Path -LiteralPath $destinationPath) $false 'Remove failed first installation'
        }
    } else {
        Assert-Equal (Get-Content -LiteralPath $destinationPath -Raw) 'new VHD' 'Install new VHD'
        Assert-Equal (Test-Path -LiteralPath $modulesBuildPath) $false 'Move staged VHD to active path'
        if ($ExistingVhd) {
            Assert-Equal (Get-Content -LiteralPath $destinationBackupPath -Raw) 'old working VHD' 'Retain rollback backup'
        }
    }
    Write-Host "PASS: $Name"
}

$tempDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$workRoot = Join-Path $tempDirectory "wsl2-zfs-tests-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $workRoot | Out-Null
    $installScriptPath = Join-Path $workRoot 'runtime-line-endings.sh'
    $mergeScriptPath = Join-Path $workRoot 'merge-line-endings.sh'
    $installScript = "set -euo pipefail`r`nprintf 'runtime ok\n'`r`n"
    $mergeScript = "set -euo pipefail`r`nprintf 'merge ok\n'`r`n"
    $bashWriters = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Value -eq 'WriteAllText' -and
            $node.Arguments[0].Extent.Text -in @('$installScriptPath', '$mergeScriptPath')
    }, $true))
    Assert-Equal $bashWriters.Count 2 'Find both generated Bash script writers'
    foreach ($writer in $bashWriters) {
        & ([scriptblock]::Create($writer.Extent.Text))
    }
    foreach ($bashScriptPath in @($installScriptPath, $mergeScriptPath)) {
        Assert-Equal ([System.IO.File]::ReadAllText($bashScriptPath).Contains("`r")) $false 'Generated Bash uses LF'
        & $BashPath $bashScriptPath
        if ($LASTEXITCODE -ne 0) { throw 'Generated Bash line-ending check failed.' }
    }
    Write-Host 'PASS: generated Bash handles CRLF source strings'
    $toolsDirectory = Join-Path $workRoot 'tools with spaces'
    New-Item -ItemType Directory -Path $toolsDirectory | Out-Null
    $kernelPath = Join-Path $toolsDirectory 'kernel'
    $artifactsPath = Join-Path $toolsDirectory 'artifacts.vhd'
    $modulesPath = Join-Path $toolsDirectory 'modules.vhd'
    $explicitPath = Join-Path $workRoot 'custom.vhd'
    foreach ($path in @($kernelPath, $artifactsPath, $modulesPath, $explicitPath)) {
        [System.IO.File]::WriteAllText($path, 'fixture')
    }
    Assert-Equal (Resolve-StockModulesVhd -KernelPath $kernelPath) $artifactsPath 'Prefer current stock image'
    Assert-Equal (Resolve-StockModulesVhd -KernelPath $kernelPath -StockModulesVhd $explicitPath) $explicitPath 'Honor explicit image'
    Assert-Throws { Resolve-StockModulesVhd -KernelPath $kernelPath -StockModulesVhd "$explicitPath.missing" } '*does not exist*'
    Remove-Item -LiteralPath $artifactsPath
    Assert-Equal (Resolve-StockModulesVhd -KernelPath $kernelPath) $modulesPath 'Fall back to legacy stock image'
    Remove-Item -LiteralPath $modulesPath
    Assert-Throws { Resolve-StockModulesVhd -KernelPath $kernelPath } '*Could not find artifacts.vhd or modules.vhd*'
    Write-Host 'PASS: stock image selection (5 cases)'

    Test-VhdReplacement 'replace-success' $true $false $false
    Test-VhdReplacement 'replace-acl-failure' $true $true $false
    Test-VhdReplacement 'replace-move-failure' $true $false $true
    Test-VhdReplacement 'first-install-acl-failure' $false $true $false
    Test-VhdReplacement 'first-install-success' $false $false $false

    $containerScriptPath = Join-Path $workRoot 'container-build.sh'
    [System.IO.File]::WriteAllText($containerScriptPath, $containerMatch.Groups[1].Value.Replace("`r`n", "`n"), [System.Text.Encoding]::ASCII)
    & $BashPath (Join-Path $PSScriptRoot 'test-build-wrapper.sh') $containerScriptPath
    if ($LASTEXITCODE -ne 0) { throw 'Container build failure tests failed.' }

    $mergePath = Join-Path $workRoot 'merge-overlay.sh'
    [System.IO.File]::WriteAllText($mergePath, $mergeString.Value.Replace("`r`n", "`n"), [System.Text.Encoding]::ASCII)
    & $BashPath -n $mergePath
    if ($LASTEXITCODE -ne 0) { throw 'Embedded Bash syntax check failed.' }
    & $BashPath -n (Join-Path $repoRoot 'scripts/build-zfs-overlay.sh')
    if ($LASTEXITCODE -ne 0) { throw 'Build script Bash syntax check failed.' }
    & $BashPath (Join-Path $PSScriptRoot 'test-merge-overlay.sh') $mergePath
    if ($LASTEXITCODE -ne 0) { throw 'Merge fixture tests failed.' }
} finally {
    $resolvedWorkRoot = [System.IO.Path]::GetFullPath($workRoot)
    $tempPrefix = $tempDirectory.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove test workspace outside the temporary directory: $resolvedWorkRoot"
    }
    if (Test-Path -LiteralPath $resolvedWorkRoot) {
        Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force
    }
}
