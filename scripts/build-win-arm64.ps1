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
  'install', 'openssl:arm64-windows-static', 'curl[websockets]:arm64-windows-static',
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
  # Upstream waits indefinitely when the PSN push WebSocket cannot open.
  # Bound the wait so the UI receives a useful error on restricted networks.
  $holepunchFile = Join-Path $chiaki 'lib\src\remote\holepunch.c'
  $holepunchText = [IO.File]::ReadAllText($holepunchFile)
  $waitRegex = [regex]::new('err = chiaki_cond_wait\(&session->state_cond, &session->state_mutex\);\r?\n[ \t]*assert\(err == CHIAKI_ERR_SUCCESS\);')
  $waitNew = @'
err = chiaki_cond_timedwait(&session->state_cond, &session->state_mutex, 15000);
        if(err != CHIAKI_ERR_SUCCESS)
        {
            chiaki_mutex_unlock(&session->state_mutex);
            return err;
        }
'@
  $waitNew = $waitNew.TrimEnd()
  if (-not $waitRegex.IsMatch($holepunchText)) {
    throw 'Unexpected Chiaki WebSocket wait; inspect the PSN timeout patch.'
  }
  $holepunchText = $waitRegex.Replace($holepunchText, $waitNew, 1)
  $startTimeout = 'CHIAKI_LOGE(session->log, "chiaki_holepunch_session_start: Timed out waiting for holepunch session start notifications.");'
  $startTimeoutDetail = @'
chiaki_mutex_lock(&session->state_mutex);
            CHIAKI_LOGE(session->log, "arm64 remote start timeout consoleJoined=%d customDataReceived=%d",
                !!(session->state & SESSION_STATE_CONSOLE_JOINED),
                !!(session->state & SESSION_STATE_CUSTOMDATA1_RECEIVED));
            chiaki_mutex_unlock(&session->state_mutex);
'@
  if (-not $holepunchText.Contains($startTimeout)) {
    throw 'Unexpected Chiaki session-start timeout handling.'
  }
  $holepunchText = $holepunchText.Replace($startTimeout, $startTimeoutDetail.TrimEnd() + "`n            " + $startTimeout)
  # PSN member notifications may include the client or multiple members.
  # The older Chiaki code checks only members[0] and aborts before processing
  # the console's customData1 notification when that entry is not the PS5.
  $memberRegex = [regex]::new('json_object \*member_duid_json = NULL;.*?session->state \|= SESSION_STATE_CONSOLE_JOINED;', [Text.RegularExpressions.RegexOptions]::Singleline)
  $memberReplacement = @'
json_object *members = NULL;
            json_pointer_get(notif->json, "/body/data/members", &members);
            bool console_member_found = false;
            if (members && json_object_is_type(members, json_type_array))
            {
                for (size_t member_index = 0; member_index < json_object_array_length(members); ++member_index)
                {
                    json_object *member = json_object_array_get_idx(members, member_index);
                    json_object *member_duid_json = NULL;
                    if (!member || !json_object_object_get_ex(member, "deviceUniqueId", &member_duid_json) ||
                        !json_object_is_type(member_duid_json, json_type_string))
                        continue;
                    const char *member_duid = json_object_get_string(member_duid_json);
                    if (strlen(member_duid) != 64)
                        continue;
                    uint8_t duid_bytes[32];
                    if (hex_to_bytes(member_duid, duid_bytes, sizeof(duid_bytes)) != CHIAKI_ERR_SUCCESS)
                        continue;
                    if (console_type == CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5 &&
                        memcmp(duid_bytes, session->console_uid, sizeof(session->console_uid)) != 0)
                        continue;
                    if (console_type == CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4)
                        memcpy(session->console_uid, duid_bytes, sizeof(duid_bytes));
                    console_member_found = true;
                    break;
                }
            }
            if (!console_member_found)
            {
                CHIAKI_LOGE(session->log, "arm64 remote ignored unrelated member notification");
                clear_notification(session, notif);
                chiaki_mutex_unlock(&session->state_mutex);
                continue;
            }
            CHIAKI_LOGE(session->log, "arm64 remote target console joined");
            session->state |= SESSION_STATE_CONSOLE_JOINED;
'@
  if ($memberRegex.Matches($holepunchText).Count -ne 1) {
    throw 'Unexpected Chiaki console member parsing.'
  }
  $holepunchText = $memberRegex.Replace($holepunchText, $memberReplacement.TrimEnd(), 1)
  $customRegex = [regex]::new('json_object \*custom_data1_json = NULL;.*?session->state \|= SESSION_STATE_CUSTOMDATA1_RECEIVED;', [Text.RegularExpressions.RegexOptions]::Singleline)
  $customReplacement = @'
json_object *custom_data1_json = NULL;
            json_pointer_get(notif->json, "/body/data/customData1", &custom_data1_json);
            if (!custom_data1_json || !json_object_is_type(custom_data1_json, json_type_string))
            {
                CHIAKI_LOGE(session->log, "arm64 remote ignored customData1 notification without string field");
                clear_notification(session, notif);
                chiaki_mutex_unlock(&session->state_mutex);
                continue;
            }
            const char *custom_data1 = json_object_get_string(custom_data1_json);
            size_t custom_data1_len = strlen(custom_data1);
            if (custom_data1_len == 32)
                err = decode_customdata1(custom_data1, session->custom_data1, sizeof(session->custom_data1));
            else if (custom_data1_len == 24)
            {
                size_t decoded_len = sizeof(session->custom_data1);
                err = chiaki_base64_decode(custom_data1, custom_data1_len, session->custom_data1, &decoded_len);
                if (err == CHIAKI_ERR_SUCCESS && decoded_len != sizeof(session->custom_data1))
                    err = CHIAKI_ERR_INVALID_DATA;
            }
            else
            {
                CHIAKI_LOGE(session->log, "arm64 remote ignored customData1 length=%zu", custom_data1_len);
                clear_notification(session, notif);
                chiaki_mutex_unlock(&session->state_mutex);
                continue;
            }
            if (err != CHIAKI_ERR_SUCCESS)
            {
                CHIAKI_LOGE(session->log, "arm64 remote ignored customData1 decode error=%d length=%zu", err, custom_data1_len);
                clear_notification(session, notif);
                chiaki_mutex_unlock(&session->state_mutex);
                continue;
            }
            CHIAKI_LOGE(session->log, "arm64 remote customData1 decoded length=%zu", custom_data1_len);
            session->state |= SESSION_STATE_CUSTOMDATA1_RECEIVED;
'@
  if ($customRegex.Matches($holepunchText).Count -ne 1) {
    throw 'Unexpected Chiaki customData1 parsing.'
  }
  $holepunchText = $customRegex.Replace($holepunchText, $customReplacement.TrimEnd(), 1)
  # Newer Chiaki accepts up to four trailing bytes in PSN customData1.
  # Older chiaki-lib rejects the whole value when the decoded size is not 16.
  $decodeRegex = [regex]::new('static ChiakiErrorCode decode_customdata1\(const char \*customdata1, uint8_t \*out, size_t out_len\)\s*\{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
  $decodeReplacement = @'
static ChiakiErrorCode decode_customdata1(const char *customdata1, uint8_t *out, size_t out_len)
{
    uint8_t round1[24];
    uint8_t round2[24];
    size_t round1_len = sizeof(round1);
    size_t round2_len = sizeof(round2);
    ChiakiErrorCode err = chiaki_base64_decode(customdata1, strlen(customdata1), round1, &round1_len);
    if (err != CHIAKI_ERR_SUCCESS)
        return err;
    err = chiaki_base64_decode((const char *)round1, round1_len, round2, &round2_len);
    if (err != CHIAKI_ERR_SUCCESS)
        return err;
    if (round2_len < out_len || round2_len > out_len + 4)
        return CHIAKI_ERR_INVALID_DATA;
    memcpy(out, round2, out_len);
    return CHIAKI_ERR_SUCCESS;
}
'@
  if ($decodeRegex.Matches($holepunchText).Count -ne 1) {
    throw 'Unexpected Chiaki customData1 decoder.'
  }
  $holepunchText = $decodeRegex.Replace($holepunchText, $decodeReplacement.TrimEnd(), 1)
  $commandAccepted = 'session->state |= SESSION_STATE_DATA_SENT;'
  if (-not $holepunchText.Contains($commandAccepted)) {
    throw 'Unexpected Chiaki PSN remote command handling.'
  }
  $holepunchText = $holepunchText.Replace($commandAccepted,
    'long arm64_remote_http_code = 0;' + "`n    " +
    'curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &arm64_remote_http_code);' + "`n    " +
    'CHIAKI_LOGE(session->log, "arm64 remote command accepted http=%ld", arm64_remote_http_code);' + "`n    " +
    $commandAccepted)
  # Record only notification types and transport failures. Never log PSN payloads.
  $notificationMarker = 'NotificationType type = parse_notification_type(session->log, json);'
  if (-not $holepunchText.Contains($notificationMarker)) {
    throw 'Unexpected Chiaki notification parsing.'
  }
  $holepunchText = $holepunchText.Replace($notificationMarker,
    $notificationMarker + "`n            " +
    'CHIAKI_LOGE(session->log, "arm64 remote notification type=%d", type);')
  $wsCleanupMarker = 'session->ws_open = false;'
  if (-not $holepunchText.Contains($wsCleanupMarker)) {
    throw 'Unexpected Chiaki WebSocket cleanup.'
  }
  $holepunchText = $holepunchText.Replace($wsCleanupMarker,
    'CHIAKI_LOGE(session->log, "arm64 remote websocket closed");' + "`n    " + $wsCleanupMarker)
  $connectMarker = 'res = curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 2L);'
  if (-not $holepunchText.Contains($connectMarker)) {
    throw 'Unexpected Chiaki WebSocket connect setup.'
  }
  $holepunchText = $holepunchText.Replace($connectMarker,
    'curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);' + "`n    " + $connectMarker)
  [IO.File]::WriteAllText($holepunchFile, $holepunchText)

  # Retry INIT and COOKIE only on timeout, keeping the same tags and cookie.
  # Cancellation, malformed replies and socket errors still fail immediately.
  $takionFile = Join-Path $chiaki 'lib\src\takion.c'
  $takionText = [IO.File]::ReadAllText($takionFile)
  $handshakeRegex = [regex]::new('static ChiakiErrorCode takion_handshake\(ChiakiTakion \*takion, uint32_t \*seq_num_remote_initial\)\s*\{.*?\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
  $handshakeReplacement = @'
static ChiakiErrorCode takion_handshake(ChiakiTakion *takion, uint32_t *seq_num_remote_initial)
{
	ChiakiErrorCode err;

	// INIT ->

	TakionMessagePayloadInit init_payload;
	init_payload.tag = takion->tag_local;
	init_payload.a_rwnd = TAKION_A_RWND;
	init_payload.outbound_streams = TAKION_OUTBOUND_STREAMS;
	init_payload.inbound_streams = TAKION_INBOUND_STREAMS;
	init_payload.initial_seq_num = takion->seq_num_local;
	int tries = 0;
	TakionMessagePayloadInitAck init_ack_payload;
	for(; tries < 3; tries++)
	{
		if(tries > 0)
			CHIAKI_LOGW(takion->log, "Takion hasn't received init ack yet, retrying init [attempt %d] ...", tries + 1);
		memset(&init_ack_payload, 0, sizeof(TakionMessagePayloadInitAck));
		err = takion_send_message_init(takion, &init_payload);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(takion->log, "Takion failed to send init");
			return err;
		}

		CHIAKI_LOGI(takion->log, "Takion sent init");

		// INIT_ACK <-
		err = takion_recv_message_init_ack(takion, &init_ack_payload);
		if(err != CHIAKI_ERR_TIMEOUT)
			break;
	}
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to receive init ack");
		return err;
	}

	if(init_ack_payload.tag == 0)
	{
		CHIAKI_LOGE(takion->log, "Takion remote tag in init ack is 0");
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	CHIAKI_LOGI(takion->log, "Takion received init ack with remote tag %#x, outbound streams: %#x, inbound streams: %#x",
		init_ack_payload.tag, init_ack_payload.outbound_streams, init_ack_payload.inbound_streams);

	takion->tag_remote = init_ack_payload.tag;
	*seq_num_remote_initial = takion->tag_remote; //init_ack_payload.initial_seq_num;

	if(init_ack_payload.outbound_streams == 0 || init_ack_payload.inbound_streams == 0 || init_ack_payload.outbound_streams > TAKION_INBOUND_STREAMS || init_ack_payload.inbound_streams < TAKION_OUTBOUND_STREAMS)
	{
		CHIAKI_LOGE(takion->log, "Takion min/max check failed");
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	// COOKIE ->
	tries = 0;
	for(; tries < 3; tries++)
	{
		if(tries > 0)
			CHIAKI_LOGW(takion->log, "Takion hasn't received cookie ack yet, resending cookie [attempt %d] ...", tries + 1);
		err = takion_send_message_cookie(takion, init_ack_payload.cookie);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(takion->log, "Takion failed to send cookie");
			return err;
		}

		CHIAKI_LOGI(takion->log, "Takion sent cookie");


		// COOKIE_ACK <-

		err = takion_recv_message_cookie_ack(takion);
		if(err != CHIAKI_ERR_TIMEOUT)
			break;
	}
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to receive cookie ack");
		return err;
	}

	CHIAKI_LOGI(takion->log, "Takion received cookie ack");


	// done!

	CHIAKI_LOGI(takion->log, "Takion connected");

	return CHIAKI_ERR_SUCCESS;
}
'@
  if ($handshakeRegex.Matches($takionText).Count -ne 1) {
    throw 'Unexpected Chiaki Takion handshake; inspect the retry patch.'
  }
  $takionText = $handshakeRegex.Replace($takionText, $handshakeReplacement.TrimEnd(), 1)
  [IO.File]::WriteAllText($takionFile, $takionText)
  # INIT and COOKIE can each wait 3 * 5 seconds. Extend only the initial
  # connection wait; preserve normal timeouts for later protocol messages.
  foreach ($relativePath in @('lib\src\streamconnection.c', 'lib\src\senkusha.c')) {
    $connectionFile = Join-Path $chiaki $relativePath
    $connectionText = [IO.File]::ReadAllText($connectionFile)
    $connectionWaitRegex = [regex]::new('chiaki_cond_timedwait_pred\(([^;\r\n]*?), EXPECT_TIMEOUT_MS, state_finished_cond_check, ([^;\r\n]*?)\);')
    if (-not $connectionWaitRegex.IsMatch($connectionText)) {
      throw "Unexpected initial Takion connection wait in $relativePath."
    }
    $connectionText = $connectionWaitRegex.Replace($connectionText,
      'chiaki_cond_timedwait_pred($1, 35000, state_finished_cond_check, $2);', 1)
    [IO.File]::WriteAllText($connectionFile, $connectionText)
  }

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
  # node-gyp 11 bundled by node-sdl cannot discover Visual Studio 2026.
  Run npm @('install', '--no-save', '--package-lock=false', '--ignore-scripts', 'node-gyp@13.0.2')
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
  $crtArm64 = Join-Path $env:VCToolsRedistDir 'arm64'
  $crtDir = Get-ChildItem $crtArm64 -Directory -Filter 'Microsoft.VC*.CRT' |
    Where-Object {
      (Test-Path (Join-Path $_.FullName 'msvcp140.dll')) -and
      (Test-Path (Join-Path $_.FullName 'vcruntime140.dll'))
    } | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
  if (-not $crtDir) { throw "ARM64 VC runtime directory is missing under $crtArm64." }
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
