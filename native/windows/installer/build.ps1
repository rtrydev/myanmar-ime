# Build the Myangler Burmese IME MSI.
#
# Stages every file the MSI ships into build\staging\, then invokes
# `wix build` against Package.wxs. The staging step is deliberate --
# Package.wxs is declarative (Files Include="staging\*"), so we
# never need to teach it where in the source tree the artefacts
# live.
#
# Prerequisites:
#   * VS Developer PowerShell loaded (for cmake/cl/link).
#   * Swift 6.3+ on PATH.
#   * vcpkg sqlite3 installed at vcpkg_installed\x64-windows\ at the
#     repo root (the project's vcpkg.json manifest install).
#   * WiX 7 as a .NET global tool (dotnet tool install --global wix).
#
# Outputs:
#   build\Myangler-Burmese-IME.msi
#
# Run from native\windows\installer\.

# NOTE: don't set $ErrorActionPreference = 'Stop' globally — native
# build tools (swift, cmake, wix) write warnings to stderr, which
# would be re-interpreted as terminating errors and abort the
# script. We check $LASTEXITCODE explicitly after every native call.

Set-StrictMode -Version Latest

function Invoke-Native {
    param([scriptblock]$cmd, [string]$label)
    & $cmd 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        throw "$label failed: exit $LASTEXITCODE"
    }
}

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo    = Resolve-Path (Join-Path $here '..\..\..')
$staging = Join-Path $here 'build\staging'
$out     = Join-Path $here 'build'

if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging              | Out-Null
New-Item -ItemType Directory -Path "$staging\Data"       | Out-Null
New-Item -ItemType Directory -Path "$staging\runtime"    | Out-Null
New-Item -ItemType Directory -Path "$staging\preferences" | Out-Null

# --- Build the Swift shim ----------------------------------------
Write-Host '==> swift build BurmeseIMEFFI (release)'
$vcpkg = Join-Path $repo 'vcpkg_installed\x64-windows'
$env:INCLUDE = "$vcpkg\include;$env:INCLUDE"
$env:LIB     = "$vcpkg\lib;$env:LIB"
$env:PATH    = "$vcpkg\bin;$env:PATH"

Push-Location (Join-Path $repo 'native\windows\swift-shim')
try {
    Invoke-Native { swift build -c release --product BurmeseIMEFFI } 'swift build'
} finally { Pop-Location }

$shimDll = Join-Path $repo 'native\windows\swift-shim\.build\x86_64-unknown-windows-msvc\release\BurmeseIMEFFI.dll'
if (-not (Test-Path $shimDll)) { throw "Missing $shimDll" }

# --- Build the TIP DLL + register_profile.exe --------------------
Write-Host '==> cmake build BurmeseIMETIP (release)'
$cmake = 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$env:PATH = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;$env:PATH"
Push-Location (Join-Path $repo 'native\windows\tsf-engine')
try {
    Invoke-Native { & $cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release } 'cmake configure'
    Invoke-Native { & $cmake --build build } 'cmake build'
} finally { Pop-Location }

$tipDll      = Join-Path $repo 'native\windows\tsf-engine\build\BurmeseIMETIP.dll'
$registerExe = Join-Path $repo 'native\windows\tsf-engine\build\register_profile.exe'

# --- Build the Preferences app (WPF + .NET 9) --------------------
Write-Host '==> dotnet publish BurmeseIMEPreferences (self-contained)'
Push-Location (Join-Path $repo 'native\windows\preferences')
try {
    # NOTE: do NOT use /p:PublishSingleFile=true here. Single-file
    # publish for WPF on .NET 9 doesn't reliably extract the WPF
    # native sidecars (wpfgfx_cor3, PresentationNative_cor3,
    # PenImc_cor3, vcruntime140_cor3, D3DCompiler_47_cor3,
    # e_sqlite3) on first launch — the app crashes deep inside
    # HwndSubclass with a DllNotFoundException before our
    # OnStartup-time logger can record anything. Multi-file
    # publish drops every sidecar as a loose file next to the exe,
    # which the OS DLL loader picks up via the normal search path
    # and avoids the runtime-extraction failure mode entirely.
    # The MSI ships the whole publish directory.
    Invoke-Native {
        dotnet publish -c Release -r win-x64 `
            /p:SelfContained=true
    } 'dotnet publish'
} finally { Pop-Location }
$prefsPublishDir = Join-Path $repo 'native\windows\preferences\bin\Release\net9.0-windows\win-x64\publish'
if (-not (Test-Path $prefsPublishDir)) { throw "Missing $prefsPublishDir" }

# --- Stage shipping payload --------------------------------------
Write-Host "==> staging payload at $staging"
Copy-Item -LiteralPath $tipDll       -Destination $staging
Copy-Item -LiteralPath $shimDll      -Destination $staging
Copy-Item -LiteralPath $registerExe  -Destination $staging
Copy-Item -LiteralPath (Join-Path $vcpkg 'bin\sqlite3.dll') -Destination $staging

# Engine data: lexicon + LM. Source today is native\macos\Data\
# because the corpus pipeline still emits there; the installer just
# copies. If the pipeline output later moves to a shared location,
# update the source paths here.
$dataSrc = Join-Path $repo 'native\macos\Data'
foreach ($name in 'BurmeseLexicon.sqlite','BurmeseLM.bin') {
    $p = Join-Path $dataSrc $name
    if (-not (Test-Path $p)) {
        throw "Missing data file $p -- generate via Tools\corpus_builder first."
    }
    Copy-Item -LiteralPath $p -Destination (Join-Path $staging 'Data')
}

# Swift runtime: all DLLs under %LOCALAPPDATA%\Programs\Swift\
# Runtimes\<version>\usr\bin\. The whole directory is the
# documented redistributable bundle on Windows; bundle it verbatim.
$swiftRuntimes = Get-ChildItem 'C:\Users\rtry\AppData\Local\Programs\Swift\Runtimes' -Directory -ErrorAction SilentlyContinue
if (-not $swiftRuntimes) {
    throw "Swift runtimes not installed at %LOCALAPPDATA%\Programs\Swift\Runtimes\"
}
# Pick the highest-numbered runtime so dev-host upgrades don't break
# this script silently.
$swiftBin = Join-Path ($swiftRuntimes | Sort-Object Name -Descending | Select-Object -First 1).FullName 'usr\bin'
Write-Host "==> bundling Swift runtime from $swiftBin"
Copy-Item -Path (Join-Path $swiftBin '*.dll') -Destination "$staging\runtime"

# Preferences app: copy the entire publish dir. WPF self-contained
# leaves several native sidecar DLLs (D3DCompiler, wpfgfx,
# PresentationNative, e_sqlite3, ...) alongside the single-file
# exe; the MSI needs to ship every one of them.
Write-Host "==> bundling preferences app from $prefsPublishDir"
Copy-Item -Path (Join-Path $prefsPublishDir '*') -Destination "$staging\preferences" -Recurse

# --- Build the MSI ------------------------------------------------
Write-Host '==> wix build'
$msi = Join-Path $out 'Myangler-Burmese-IME.msi'
Push-Location $here
try {
    # -arch x64 marks the MSI itself as 64-bit so msiexec runs the
    # install in the 64-bit context. Without it, the MSI is 32-bit
    # by default, msiexec runs under WoW64, and even paths declared
    # under ProgramFiles64Folder get silently redirected to
    # C:\Program Files (x86)\Myangler\. Files install correctly to
    # that path but the install layout is unconventional and some
    # COM / TSF surfaces don't expect a 64-bit TIP DLL to live
    # under the (x86) tree.
    Invoke-Native { wix build -arch x64 Package.wxs -out $msi } 'wix build'
} finally { Pop-Location }

if (Test-Path $msi) {
    $sizeMB = '{0:N1}' -f ((Get-Item $msi).Length / 1MB)
    Write-Host ""
    Write-Host "Built $msi ($sizeMB MB)"
    Write-Host "Install: msiexec /i $msi  (must be elevated)"
    Write-Host "Uninstall: via Control Panel -> Programs and Features"
}
