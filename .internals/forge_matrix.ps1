param (
    [string]$AutoTarget = "",
    [switch]$ForceRebuild
)

$ErrorActionPreference = "Stop"
# SOTA FIX: Obliterate PowerShell's UI rendering loop for unthrottled network I/O
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# SOTA FIX: Load native .NET Compression assemblies to bypass %TEMP% buffering
Add-Type -AssemblyName System.IO.Compression.FileSystem

$InternalsDir = $PSScriptRoot
$BaseDir = Split-Path $InternalsDir -Parent

$BasePythonDir = Join-Path $InternalsDir ".python_base"
$VenvDir = Join-Path $InternalsDir ".venv"
$BinDir = Join-Path $InternalsDir "bin"
$LibDir = Join-Path $InternalsDir "library"
$ReqFile = Join-Path $BaseDir "requirements.txt"

$PyCdcExe = Join-Path $BinDir "pycdc.exe"
$PyInstExtScript = Join-Path $LibDir "pyinstxtractor.py"

if ($ForceRebuild) {
    Write-Host "[!] Force Rebuild Initiated. Eradicating previous matrix..." -ForegroundColor Yellow
    if (Test-Path $VenvDir) { Remove-Item $VenvDir -Recurse -Force }
    if (Test-Path $BasePythonDir) { Remove-Item $BasePythonDir -Recurse -Force }
}

if (-Not $ForceRebuild -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe")) -and (Test-Path $PyCdcExe)) {
    exit 0
}

if (-Not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
if (-Not (Test-Path $LibDir)) { New-Item -ItemType Directory -Path $LibDir -Force | Out-Null }

# ==========================================
# PHASE 1: TARGET ACQUISITION & MENU
# ==========================================
$TargetVersion = $AutoTarget

if ($TargetVersion -eq "") {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Magenta
    Write-Host "  EXTRACTORATOR: PYTHON ARCHITECTURE SELECTION" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Magenta
    Write-Host "Select the Python runtime matching your lost .exe:`n"
    
    $Versions = @("3.8.10", "3.9.13", "3.10.11", "3.11.9", "3.12.3")
    for ($i = 0; $i -lt $Versions.Count; $i++) {
        Write-Host " [$($i + 1)] Python $($Versions[$i])"
    }
    Write-Host ""
    
    $Selection = Read-Host "Enter Selection (Default 2)"
    if ($Selection -match '^[1-5]$') {
        $TargetVersion = $Versions[[int]$Selection - 1]
    } else {
        $TargetVersion = "3.9.13" 
    }
}

# ==========================================
# PHASE 2: VENV HYDRATION (.NET STREAMING)
# ==========================================
if (-Not (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) {
    Write-Host "`n[*] Bootstrapping Hermetic Python $TargetVersion Environment..." -ForegroundColor Cyan
    if (-Not (Test-Path $BasePythonDir)) {
        $NugetCache = Join-Path $InternalsDir "python.$TargetVersion.zip"
        $DownloadUrl = "https://www.nuget.org/api/v2/package/python/$TargetVersion"
        
        try {
            if (Test-Path $NugetCache) { Remove-Item $NugetCache -Force }
            if (Test-Path $BasePythonDir) { Remove-Item $BasePythonDir -Recurse -Force }
            
            Write-Host "  -> Fetching Remote Payload (High Velocity)..." -ForegroundColor Blue
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $NugetCache
            
            Write-Host "  -> Extracting Core Interpreter (Direct RAM Stream)..." -ForegroundColor Blue
            # SOTA FIX: Native .NET extraction. Bypasses %TEMP%.
            # Prevented IOException by allowing .NET to create the target folder inherently.
            [System.IO.Compression.ZipFile]::ExtractToDirectory($NugetCache, $BasePythonDir)
            
            Remove-Item $NugetCache -Force
        } catch {
            Write-Host "`n[!] Fatal: Failed to acquire/extract Python $TargetVersion." -ForegroundColor Red
            Write-Host "[!] System Telemetry: $($_.Exception.Message)" -ForegroundColor Yellow
            exit 1
        }
    }
    
    Write-Host "  -> Generating Virtual Execution Environment..." -ForegroundColor Blue
    $PortablePython = Join-Path $BasePythonDir "tools\python.exe"
    & $PortablePython -m venv $VenvDir --prompt "Extractorator-$TargetVersion"
    
    if (Test-Path $ReqFile) {
        $VenvPython = Join-Path $VenvDir "Scripts\python.exe"
        & $VenvPython -m pip install -r $ReqFile --disable-pip-version-check -q
    }
}

# ==========================================
# PHASE 3: DEPENDENCY MATRICES
# ==========================================
if (-Not (Test-Path $PyCdcExe)) {
    Write-Host "`n[*] C++ Matrix Missing. Initiating SOTA Toolchain Hydration..." -ForegroundColor Blue
    $ToolchainDir = Join-Path $InternalsDir "toolchain"
    if (Test-Path $ToolchainDir) { Remove-Item $ToolchainDir -Recurse -Force }
    New-Item -ItemType Directory -Path $ToolchainDir -Force | Out-Null

    function Fetch-Asset ($Repo, $Pattern, $Dest, $IsTar) {
        Write-Host "  -> Hydrating $Dest..." -ForegroundColor DarkGray
        $Rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{"User-Agent"="Extractorator"}
        $Asset = $Rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        
        if (-not $Asset) { throw "Fatal: Failed to resolve asset matching $Pattern in $Repo" }

        $Archive = Join-Path $ToolchainDir $Asset.name
        $OutPath = Join-Path $ToolchainDir $Dest
        
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Archive
        if ($IsTar) {
            New-Item -ItemType Directory -Path $OutPath -Force | Out-Null
            & tar.exe -xf $Archive -C $OutPath --strip-components=1
        } else {
            # SOTA FIX: Native .NET extraction for Toolchain dependencies without preemptive folder creation
            [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $OutPath)
            
            $Unpacked = Get-ChildItem -Path $OutPath -Directory
            if ($Unpacked.Count -eq 1) { Move-Item -Path "$($Unpacked[0].FullName)\*" -Destination $OutPath -Force; Remove-Item $Unpacked[0].FullName -Force }
        }
        Remove-Item $Archive -Force
    }

    Fetch-Asset "Kitware/CMake" "windows-x86_64\.zip$" "cmake" $false
    Fetch-Asset "ninja-build/ninja" "ninja-win\.zip$" "ninja" $false
    Fetch-Asset "llvm/llvm-project" "clang\+llvm-.*-x86_64-pc-windows-msvc\.tar\.xz$" "llvm" $true

    Write-Host "[*] Forging PyCDC Binaries..." -ForegroundColor Blue
    $PycdcSrc = Join-Path $InternalsDir "pycdc_src"
    $BuildDir = Join-Path $InternalsDir ".forge_cache"
    
    if (Test-Path $PycdcSrc) { Remove-Item $PycdcSrc -Recurse -Force }
    
    # SOTA FIX: Shallow clone bypasses pulling unnecessary repository history, optimizing network and disk I/O.
    & git clone --depth 1 https://github.com/zrax/pycdc.git $PycdcSrc -q

    $CMake = Join-Path $ToolchainDir "cmake\bin\cmake.exe"
    $Ninja = Join-Path $ToolchainDir "ninja\ninja.exe"
    $ClangC = Join-Path $ToolchainDir "llvm\bin\clang.exe"
    $ClangCxx = Join-Path $ToolchainDir "llvm\bin\clang++.exe"
    $LlvmRc = Join-Path $ToolchainDir "llvm\bin\llvm-rc.exe"

    $SrcPosix = $PycdcSrc -replace '\\', '/'
    $BuildPosix = $BuildDir -replace '\\', '/'

    & $CMake -G "Ninja" -S $SrcPosix -B $BuildPosix "-DCMAKE_MAKE_PROGRAM=$($Ninja -replace '\\', '/')" "-DCMAKE_C_COMPILER=$($ClangC -replace '\\', '/')" "-DCMAKE_CXX_COMPILER=$($ClangCxx -replace '\\', '/')" "-DCMAKE_RC_COMPILER=$($LlvmRc -replace '\\', '/')" "-DCMAKE_BUILD_TYPE=Release" "-DCMAKE_CXX_FLAGS=-D_CRT_SECURE_NO_WARNINGS" "-DCMAKE_C_FLAGS=-D_CRT_SECURE_NO_WARNINGS" | Out-Null
    & $Ninja -C $BuildPosix | Out-Null

    Copy-Item (Join-Path $BuildDir "pycdc.exe") -Destination $BinDir -Force
    Copy-Item (Join-Path $BuildDir "pycdas.exe") -Destination $BinDir -Force

    Write-Host "[*] Executing Absolute Garbage Collection..." -ForegroundColor Yellow
    Remove-Item $ToolchainDir -Recurse -Force
    Remove-Item $PycdcSrc -Recurse -Force
    Remove-Item $BuildDir -Recurse -Force
}

if (-Not (Test-Path $PyInstExtScript)) {
    Write-Host "[*] Acquiring ExtremeCoders PyInstxtractor..." -ForegroundColor Blue
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/extremecoders-re/pyinstxtractor/master/pyinstxtractor.py" -OutFile $PyInstExtScript
}

Write-Host "`n[+] Hermetic Matrix Online." -ForegroundColor Green
exit 0
