param(
  [Parameter(Mandatory = $true)][string]$VcpkgRoot,
  [string]$WorkRoot = (Join-Path $PSScriptRoot '..\arm64-work')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)

function Run([string]$Exe, [string[]]$Arguments) {
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Exe exited with code $LASTEXITCODE" }
}
function Require([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing $Name. Run from a VS ARM64 Native Tools prompt with ARM64 Node.js, Python 3, CMake, Ninja, Git, Yarn, and protoc installed."
  }
}

if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
  throw 'Run this script on Windows ARM64.'
}
foreach ($cmd in @('node', 'npm', 'yarn', 'git', 'cmake', 'ninja', 'python', 'protoc', 'cl')) {
  Require $cmd
}
if ((& node -p 'process.arch') -ne 'arm64') { throw 'The Node.js executable must be ARM64.' }
if (-not (Test-Path (Join-Path $VcpkgRoot 'vcpkg.exe'))) {
  throw 'Pass an initialized vcpkg root containing vcpkg.exe.'
}
New-Item -ItemType Directory -Force $WorkRoot | Out-Null
Push-Location $AppRoot
try {
  Run (Get-Command yarn).Source @('install', '--ignore-scripts', '--frozen-lockfile')
  Run node @('node_modules\electron\install.js')
  Run (Get-Command yarn).Source @('electron-builder', 'install-app-deps', '--arch', 'arm64')
}
finally { Pop-Location }

# vcpkg provides ARM64 OpenSSL, curl and zlib. The chiaki-lib bundled
# OpenSSL 1.1.1s configuration selects the x64 target on Windows ARM64.
Run (Join-Path $VcpkgRoot 'vcpkg.exe') @(
  'install', 'openssl:arm64-windows-static', 'curl:arm64-windows-static',
  'zlib:arm64-windows-static'
)
$toolchain = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'

$chiaki = Join-Path $WorkRoot 'chiaki-lib'
if (-not (Test-Path $chiaki)) {
  Run git @('clone', 'https://github.com/capstone-design-HII/chiaki-lib.git', $chiaki)
}
Push-Location $chiaki
try {
  Run npm @('ci')
  # cmake-js supplies Electron's Windows delay-load hook in CMAKE_JS_SRC.
  # chiaki-lib's CMake target omits it, leaving a hard dependency on node.exe.
  $nodeCmake = Join-Path $chiaki 'node\CMakeLists.txt'
  $nodeCmakeText = [IO.File]::ReadAllText($nodeCmake)
  $oldTarget = 'add_library(chiaki_node MODULE addon.cc wrappers.cc)'
  if (-not $nodeCmakeText.Contains($oldTarget)) {
    throw 'Unexpected chiaki-lib node/CMakeLists.txt; inspect the Electron delay-load hook.'
  }
  Copy-Item (Join-Path $AppRoot 'scripts\chiaki-remote-arm64.cc') (Join-Path $chiaki 'node\remote_arm64.cc')
  $replacement = 'add_library(chiaki_node MODULE addon.cc wrappers.cc remote_arm64.cc ${CMAKE_JS_SRC})' + "`n" +
    'target_link_options(chiaki_node PRIVATE "/DELAYLOAD:node.exe")' + "`n" +
    'target_link_libraries(chiaki_node PRIVATE delayimp)'
  [IO.File]::WriteAllText($nodeCmake, $nodeCmakeText.Replace($oldTarget, $replacement))
  $addonFile = Join-Path $chiaki 'node\addon.cc'
  $addonText = [IO.File]::ReadAllText($addonFile)
  $addonMarker = 'extern napi_status RegisterCoreApiClasses(napi_env env, napi_value exports);'
  $registerMarker = 'NAPI_CALL_OR_RETURN_NULL(env, RegisterCoreApiClasses(env, exports));'
  if (-not $addonText.Contains($addonMarker) -or -not $addonText.Contains($registerMarker)) {
    throw 'Unexpected chiaki-lib addon.cc; inspect the remote bridge integration.'
  }
  $addonText = $addonText.Replace($addonMarker,
    "$addonMarker`nextern napi_status RegisterArm64Remote(napi_env env, napi_value exports);")
  $addonText = $addonText.Replace($registerMarker,
    "$registerMarker`n`tNAPI_CALL_OR_RETURN_NULL(env, RegisterArm64Remote(env, exports));")
  [IO.File]::WriteAllText($addonFile, $addonText)
  $wrapperFile = Join-Path $chiaki 'node\wrappers.cc'
  $wrapperText = [IO.File]::ReadAllText($wrapperFile)
  $includeMarker = '#include <chiaki/session.h>'
  $sessionMarker = 'ChiakiErrorCode err = chiaki_session_init(&wrap->session, &connect_info, &wrap->log);'
  if (-not $wrapperText.Contains($includeMarker) -or -not $wrapperText.Contains($sessionMarker)) {
    throw 'Unexpected chiaki-lib wrappers.cc; inspect the remote session handoff.'
  }
  $wrapperText = $wrapperText.Replace($includeMarker,
    "$includeMarker`n`nChiakiHolepunchSession TakeArm64PreparedRemote(napi_env env, napi_value value);")
  $handoff = @'
{
    napi_value prepared;
    bool has_prepared = false;
    if(!GetNamedProperty(env, argv[0], "preparedRemote", &prepared, &has_prepared))
    {
        SessionCloseInternal(wrap);
        delete wrap;
        return nullptr;
    }
    if(has_prepared && !IsNullOrUndefined(env, prepared))
    {
        connect_info.holepunch_session = TakeArm64PreparedRemote(env, prepared);
        if(!connect_info.holepunch_session)
        {
            SessionCloseInternal(wrap);
            delete wrap;
            return nullptr;
        }
    }
}

'@
  $wrapperText = $wrapperText.Replace($sessionMarker, "$handoff`t$sessionMarker")
  [IO.File]::WriteAllText($wrapperFile, $wrapperText)
  $env:npm_config_arch = 'arm64'
  $env:VCPKG_TARGET_TRIPLET = 'arm64-windows-static'
  $electronVersion = (Get-Content (Join-Path $AppRoot 'node_modules\electron\package.json') -Raw |
    ConvertFrom-Json).version
  Run (Join-Path $chiaki 'node_modules\.bin\cmake-js.cmd') @(
    'rebuild', '--runtime=electron', "--runtime-version=$electronVersion",
    '--arch=arm64', '--generator=Ninja',
    '--CDCHIAKI_USE_BUNDLED_DESKTOP_DEPS=OFF',
    '--CDCHIAKI_USE_SYSTEM_CURL=ON',
    "--CDCMAKE_TOOLCHAIN_FILE=$toolchain",
    '--CDVCPKG_TARGET_TRIPLET=arm64-windows-static'
  )
  $addon = Get-ChildItem (Join-Path $chiaki 'build') -Recurse -Filter 'chiaki.node' |
    Select-Object -First 1
  if (-not $addon) { throw 'chiaki.node was not produced.' }
  Copy-Item $addon.FullName (Join-Path $AppRoot 'peasyo-lib\native\1.0.10\peasyo-lib.win32-arm64-msvc.node')
}
finally { Pop-Location }

# Match the API and SDL2 version bundled in peasyo-sdl-lib 1.0.2.
$sdlSource = Join-Path $WorkRoot 'SDL'
if (-not (Test-Path $sdlSource)) {
  Run git @('clone', '--branch', 'release-2.32.8', '--depth', '1',
    'https://github.com/libsdl-org/SDL.git', $sdlSource)
}
$sdlInstall = Join-Path $WorkRoot 'sdl-install'
Run cmake @('-S', $sdlSource, '-B', (Join-Path $WorkRoot 'sdl-build'),
  '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_INSTALL_PREFIX=$sdlInstall",
  '-DCMAKE_C_FLAGS=/forceInterlockedFunctions-',
  '-DSDL_SHARED=ON', '-DSDL_STATIC=OFF', '-DSDL_TESTS=OFF')
Run cmake @('--build', (Join-Path $WorkRoot 'sdl-build'), '--parallel')
Run cmake @('--install', (Join-Path $WorkRoot 'sdl-build'))

$sdlNode = Join-Path $WorkRoot 'node-sdl'
if (-not (Test-Path $sdlNode)) {
  Run git @('clone', '--branch', 'v0.11.13', '--depth', '1',
    'https://github.com/kmamal/node-sdl.git', $sdlNode)
}
Push-Location $sdlNode
try {
  Run npm @('ci', '--ignore-scripts')
  $env:SDL_INC = Join-Path $sdlInstall 'include\SDL2'
  $env:SDL_LIB = Join-Path $sdlInstall 'lib'
  Run (Join-Path $sdlNode 'node_modules\.bin\node-gyp.cmd') @('rebuild', '--arch=arm64')
  $sdlDest = Join-Path $AppRoot 'node_modules\peasyo-sdl-lib\sdl.node-v0.11.13-win32-arm64'
  New-Item -ItemType Directory -Force $sdlDest | Out-Null
  Copy-Item (Join-Path $sdlNode 'build\Release\sdl.node') $sdlDest
  Copy-Item (Join-Path $sdlInstall 'bin\SDL2.dll') $sdlDest
}
finally { Pop-Location }

$bindings = Join-Path $AppRoot 'node_modules\peasyo-sdl-lib\src\javascript\bindings.js'
$source = [IO.File]::ReadAllText($bindings)
$old = "if (arch === 'x64') return 'win32-x64'"
if (-not $source.Contains($old)) { throw 'Unexpected peasyo-sdl-lib bindings.js; inspect before patching.' }
$source = $source.Replace($old, "$old`n`t`tif (arch === 'arm64') return 'win32-arm64'")
[IO.File]::WriteAllText($bindings, $source)

# An x64 FFmpeg executable can run as a child process under Windows ARM64.
# The package is copied into extraResources by electron-builder.yml.
$ffmpegDest = Join-Path $AppRoot 'node_modules\@ffmpeg-installer\win32-x64'
if (-not (Test-Path (Join-Path $ffmpegDest 'ffmpeg.exe'))) {
  $ffmpegTmp = Join-Path $WorkRoot 'ffmpeg-x64'
  New-Item -ItemType Directory -Force $ffmpegTmp, $ffmpegDest | Out-Null
  Push-Location $ffmpegTmp
  try {
    Run npm @('pack', '@ffmpeg-installer/win32-x64@4.1.0', '--silent')
    Run tar @('-xzf', 'ffmpeg-installer-win32-x64-4.1.0.tgz')
    Copy-Item (Join-Path $ffmpegTmp 'package\ffmpeg.exe') $ffmpegDest
  }
  finally { Pop-Location }
}

Push-Location $AppRoot
try {
  Run (Get-Command yarn).Source @('nextron', 'build', '--no-pack')
  Run (Get-Command yarn).Source @('electron-builder', '--win', '--arm64', '--dir')
  # vcpkg's static libraries still use the dynamic MSVC runtime. Bundle the
  # redistributable ARM64 CRT beside the Electron executable for clean hosts.
  $crtDir = Join-Path $env:VCToolsRedistDir 'arm64\Microsoft.VC143.CRT'
  $outDir = Join-Path $AppRoot 'dist\win-arm64-unpacked'
  foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll')) {
    $source = Join-Path $crtDir $dll
    if (-not (Test-Path $source)) { throw "ARM64 VC runtime is missing: $source" }
    Copy-Item $source $outDir
  }
  Write-Host "Package: $(Join-Path $AppRoot 'dist\win-arm64-unpacked')"
  Write-Warning 'chiaki-lib has no peasyo remote.* API; LAN streaming must be tested separately.'
}
finally { Pop-Location }
