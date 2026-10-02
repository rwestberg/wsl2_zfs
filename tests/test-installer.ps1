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

# Load only the image resolver; never execute the installer or its disk operations.
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

$tempDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$workRoot = Join-Path $tempDirectory "wsl2-zfs-tests-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $workRoot | Out-Null
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
