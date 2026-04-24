@echo off
setlocal EnableExtensions DisableDelayedExpansion

if "%~1"=="" (
    tree /f /a
    exit /b 0
)

set "DEPTH=%~1"
if /I "%DEPTH%"=="all" set "DEPTH=0"

powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock ([ScriptBlock]::Create(((Get-Content -LiteralPath '%~f0' -Raw) -split '#POWERSHELL_START')[-1])) -ArgumentList '%DEPTH%', '%~2'"
exit /b %errorlevel%

#POWERSHELL_START
param (
    [string]$Depth,
    [string]$Filter
)

$script:targetDepth = [int]$Depth
$script:Filter = $Filter

if ($script:Filter -and $script:Filter -notmatch '^\*') {
    $script:Filter = "*" + $script:Filter
}

$basePath = (Get-Item .).FullName
if (-not $basePath.EndsWith("\")) {
    $basePath += "\"
}

Write-Host "Folder PATH listing"
Write-Host $basePath

# Phase 1: Abstract Syntax Tree Generation
function Build-Tree {
    param (
        [System.IO.DirectoryInfo]$Dir,
        [int]$CurrentDepth
    )

    $dirNodes = [System.Collections.Generic.List[object]]::new()
    $fileNodes = [System.Collections.Generic.List[object]]::new()
    $hasMatches = $false

    try {
        # 1. Process Files (Terminal Nodes)
        $files = @($Dir.GetFiles())
        if ($files.Count -gt 0) {
            $fileNames = [string[]]::new($files.Count)
            for ($i = 0; $i -lt $files.Count; $i++) { $fileNames[$i] = $files[$i].Name }
            [System.Array]::Sort($fileNames, $files)
            
            foreach ($f in $files) {
                if (-not $script:Filter -or ($f.Name -like $script:Filter)) {
                    $fileNodes.Add(@{ Name = $f.Name; IsDirectory = $false; Children = $null })
                    $hasMatches = $true
                }
            }
        }

        # 2. Evaluate Boundary Condition
        if ($script:targetDepth -eq 0 -or $CurrentDepth -lt $script:targetDepth) {
            
            # 3. Process Directories (Traversal Nodes)
            $dirs = @($Dir.GetDirectories())
            if ($dirs.Count -gt 0) {
                $dirNames = [string[]]::new($dirs.Count)
                for ($i = 0; $i -lt $dirs.Count; $i++) { $dirNames[$i] = $dirs[$i].Name }
                [System.Array]::Sort($dirNames, $dirs)

                foreach ($d in $dirs) {
                    $childResult = Build-Tree -Dir $d -CurrentDepth ($CurrentDepth + 1)
                    
                    if (-not $script:Filter -or $childResult.HasMatches) {
                        $dirNodes.Add(@{
                            Name = $d.Name + "\"
                            IsDirectory = $true
                            Children = $childResult.Children
                        })
                        $hasMatches = $true
                    }
                }
            }
        }
    } catch {
        # Silently bypass access restricted system volumes
    }

    # Append terminal nodes to traversal nodes to match standard tree topography
    $dirNodes.AddRange($fileNodes)

    return @{
        Children = $dirNodes
        HasMatches = $hasMatches
    }
}

# Phase 2: Structural Rendering Engine
function Print-Tree {
    param (
        $NodeList,
        [string]$Prefix
    )

    $count = $NodeList.Count
    for ($i = 0; $i -lt $count; $i++) {
        $child = $NodeList[$i]
        $isLast = ($i -eq ($count - 1))
        
        $connector = if ($isLast) { "\---" } else { "+---" }
        Write-Host ("{0}{1}{2}" -f $Prefix, $connector, $child.Name)

        if ($child.IsDirectory -and $child.Children.Count -gt 0) {
            $extension = if ($isLast) { "    " } else { "|   " }
            Print-Tree -NodeList $child.Children -Prefix ($Prefix + $extension)
        }
    }
}

$rootResult = Build-Tree -Dir (Get-Item .) -CurrentDepth 0

if ($rootResult.Children.Count -gt 0) {
    Print-Tree -NodeList $rootResult.Children -Prefix ""
} else {
    Write-Host "No matching files found."
}