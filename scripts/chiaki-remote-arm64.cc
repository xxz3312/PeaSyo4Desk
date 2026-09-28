// Windows on ARM bridge for the upstream Chiaki PSN hole-punching API.
// Compiled into the chiaki-lib Node addon by build-win-arm64.ps1.
#include <node_api.h>

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/remote/holepunch.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

struct PreparedRemote {
    ChiakiHolepunchSession session = nullptr;
};

struct Device {
    ChiakiHolepunchConsoleType type;
    std::array<uint8_t, 32> uid;
    std::string name;
};

struct RemoteWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string token;
    std::string uid;
    std::string nickname;
    std::string stage;
    ChiakiErrorCode error = CHIAKI_ERR_SUCCESS;
    ChiakiHolepunchSession session = nullptr;
    napi_threadsafe_function progress = nullptr;
};

struct ProgressEvent {
    const char *stage;
    int progress;
};

void DeliverProgress(napi_env env, napi_value callback, void *, void *data) {
    auto *event = static_cast<ProgressEvent *>(data);
    if(env && callback) {
        napi_value payload, stage, progress, state, global;
        if(napi_create_object(env, &payload) == napi_ok &&
           napi_create_string_utf8(env, event->stage, NAPI_AUTO_LENGTH, &stage) == napi_ok &&
           napi_create_int32(env, event->progress, &progress) == napi_ok &&
           napi_create_int32(env, 0, &state) == napi_ok &&
           napi_get_global(env, &global) == napi_ok) {
            napi_set_named_property(env, payload, "stage", stage);
            napi_set_named_property(env, payload, "progress", progress);
            napi_set_named_property(env, payload, "state", state);
            napi_value ignored;
            napi_call_function(env, global, callback, 1, &payload, &ignored);
        }
    }
    delete event;
}

void ReportProgress(RemoteWork *work, const char *stage, int progress) {
    work->stage = stage;
    if(work->progress) {
        auto *event = new ProgressEvent{stage, progress};
        if(napi_call_threadsafe_function(work->progress, event, napi_tsfn_nonblocking) != napi_ok)
            delete event;
    }
}

std::mutex diagnostic_mutex;
std::string websocket_diagnostic;

void DiagnosticLog(ChiakiLogLevel, const char *message, void *) {
    if(!message)
        return;
    const std::string line(message);
    // Chiaki also logs the OAuth header. Only retain known WebSocket failure
    // messages; never include arbitrary native logs or PSN credentials.
    if(line.find("Connecting to push notification WebSocket") == std::string::npos &&
       line.find("websocket_thread_func: Curl could not init") == std::string::npos)
        return;
    const auto failure = line.find("failed with ");
    if(failure == std::string::npos)
        return;
    std::lock_guard<std::mutex> lock(diagnostic_mutex);
    websocket_diagnostic = line.substr(failure, 200);
}

ChiakiLog *RemoteLog() {
    static ChiakiLog log;
    static std::once_flag once;
    std::call_once(once, [] { chiaki_log_init(&log, CHIAKI_LOG_ERROR, DiagnosticLog, nullptr); });
    return &log;
}

bool ReadString(napi_env env, napi_value value, std::string *out) {
    napi_valuetype type;
    if(napi_typeof(env, value, &type) != napi_ok || type != napi_string)
        return false;
    size_t length = 0;
    if(napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok)
        return false;
    out->resize(length + 1);
    if(napi_get_value_string_utf8(env, value, &(*out)[0], out->size(), &length) != napi_ok)
        return false;
    out->resize(length);
    return true;
}

bool ReadOption(napi_env env, napi_value options, const char *name, std::string *out) {
    bool has = false;
    if(napi_has_named_property(env, options, name, &has) != napi_ok)
        return false;
    if(!has)
        return true;
    napi_value value;
    return napi_get_named_property(env, options, name, &value) == napi_ok && ReadString(env, value, out);
}

std::string Lower(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return std::tolower(c); });
    return text;
}

std::string HexUid(const std::array<uint8_t, 32> &uid) {
    static const char digits[] = "0123456789abcdef";
    std::string text;
    text.reserve(64);
    for(uint8_t byte : uid) {
        text.push_back(digits[byte >> 4]);
        text.push_back(digits[byte & 15]);
    }
    return text;
}

bool ListDevices(RemoteWork *work, ChiakiHolepunchConsoleType type, std::vector<Device> *all) {
    ChiakiHolepunchDeviceInfo *items = nullptr;
    size_t count = 0;
    ChiakiErrorCode err = chiaki_holepunch_list_devices(work->token.c_str(), type, &items, &count, RemoteLog());
    if(err != CHIAKI_ERR_SUCCESS) {
        work->error = err;
        return false;
    }
    for(size_t i = 0; i < count; ++i) {
        Device device;
        device.type = type;
        std::memcpy(device.uid.data(), items[i].device_uid, device.uid.size());
        const char *name_begin = items[i].device_name;
        const char *name_end = name_begin + sizeof(items[i].device_name);
        device.name.assign(name_begin, std::find(name_begin, name_end, '\0'));
        if(items[i].remoteplay_enabled)
            all->push_back(std::move(device));
    }
    chiaki_holepunch_free_device_list(&items);
    return true;
}

void ExecuteRemote(napi_env, void *data) {
    auto *work = static_cast<RemoteWork *>(data);
    {
        std::lock_guard<std::mutex> lock(diagnostic_mutex);
        websocket_diagnostic.clear();
    }
    ReportProgress(work, "holepunchInit", 20);
    std::vector<Device> devices;
    bool ps5 = ListDevices(work, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices);
    bool ps4 = ListDevices(work, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4, &devices);
    if(!ps5 && !ps4)
        return;

    const Device *selected = nullptr;
    if(!work->uid.empty()) {
        const std::string wanted = Lower(work->uid);
        for(const auto &device : devices) {
            if(HexUid(device.uid) == wanted) { selected = &device; break; }
        }
    } else if(!work->nickname.empty()) {
        for(const auto &device : devices) {
            if(device.name == work->nickname) {
                if(selected) { work->stage = "ambiguousDevice"; work->error = CHIAKI_ERR_INVALID_DATA; return; }
                selected = &device;
            }
        }
    } else if(devices.size() == 1) {
        selected = &devices.front();
    }
    if(!selected) {
        work->stage = "deviceNotFound";
        work->error = CHIAKI_ERR_INVALID_DATA;
        return;
    }

    ReportProgress(work, "holepunchWebSocketOpen", 35);
    work->session = chiaki_holepunch_session_init(work->token.c_str(), RemoteLog());
    if(!work->session) { work->error = CHIAKI_ERR_MEMORY; return; }
    ReportProgress(work, "holepunchWebSocketOpen", 45);
    work->error = chiaki_holepunch_session_create(work->session);
    if(work->error != CHIAKI_ERR_SUCCESS) return;
    ReportProgress(work, "holepunchClientJoined", 55);
    work->error = holepunch_session_create_offer(work->session);
    if(work->error != CHIAKI_ERR_SUCCESS) return;
    ReportProgress(work, "holepunchOfferSent", 65);
    work->error = chiaki_holepunch_session_start(work->session, selected->uid.data(), selected->type);
    if(work->error != CHIAKI_ERR_SUCCESS) return;
    ReportProgress(work, "holepunchCtrlOfferReceived", 80);
    work->error = chiaki_holepunch_session_punch_hole(work->session, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
    if(work->error == CHIAKI_ERR_SUCCESS)
        ReportProgress(work, "holepunchCtrlEstablished", 90);
}

void PreparedFinalizer(napi_env, void *data, void *) {
    auto *prepared = static_cast<PreparedRemote *>(data);
    if(prepared->session)
        chiaki_holepunch_session_fini(prepared->session);
    delete prepared;
}

void CompleteRemote(napi_env env, napi_status status, void *data) {
    auto *work = static_cast<RemoteWork *>(data);
    if(work->progress) napi_release_threadsafe_function(work->progress, napi_tsfn_release);
    if(status != napi_ok || work->error != CHIAKI_ERR_SUCCESS) {
        std::string message = "[REMOTE_PREPARE_FAILED] stage=" + work->stage +
            " nativeCode=" + std::to_string(static_cast<int>(work->error)) +
            " message=" + chiaki_error_string(work->error);
        if(work->stage == "holepunchWebSocketOpen") {
            std::lock_guard<std::mutex> lock(diagnostic_mutex);
            if(!websocket_diagnostic.empty())
                message += "; websocket=" + websocket_diagnostic;
        }
        if(work->session)
            chiaki_holepunch_session_fini(work->session);
        napi_value text, error;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &text);
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        auto *prepared = new PreparedRemote();
        prepared->session = work->session;
        napi_value external;
        if(napi_create_external(env, prepared, PreparedFinalizer, nullptr, &external) == napi_ok)
            napi_resolve_deferred(env, work->deferred, external);
        else {
            PreparedFinalizer(env, prepared, nullptr);
            napi_value error;
            napi_create_string_utf8(env, "Could not create prepared remote handle", NAPI_AUTO_LENGTH, &error);
            napi_reject_deferred(env, work->deferred, error);
        }
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value PrepareRemote(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    if(napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "prepareSession(options) requires an options object");
        return nullptr;
    }
    auto *work = new RemoteWork();
    if(!ReadOption(env, args[0], "accessToken", &work->token) ||
       !ReadOption(env, args[0], "remoteDeviceUid", &work->uid) ||
       (work->uid.empty() && !ReadOption(env, args[0], "deviceUid", &work->uid)) ||
       !ReadOption(env, args[0], "nickName", &work->nickname) ||
       (work->nickname.empty() && !ReadOption(env, args[0], "nickname", &work->nickname)) ||
       work->token.empty()) {
        delete work;
        napi_throw_type_error(env, nullptr, "accessToken and valid device selection are required");
        return nullptr;
    }
    napi_value callback;
    bool has_callback = false;
    if(napi_has_named_property(env, args[0], "onProgress", &has_callback) == napi_ok && has_callback &&
       napi_get_named_property(env, args[0], "onProgress", &callback) == napi_ok) {
        napi_valuetype callback_type;
        if(napi_typeof(env, callback, &callback_type) == napi_ok && callback_type == napi_function) {
            napi_value label;
            napi_create_string_utf8(env, "ChiakiRemoteProgress", NAPI_AUTO_LENGTH, &label);
            if(napi_create_threadsafe_function(env, callback, nullptr, label, 0, 1, nullptr,
                                               nullptr, nullptr, DeliverProgress, &work->progress) != napi_ok) {
                delete work;
                napi_throw_error(env, nullptr, "Could not create remote progress callback");
                return nullptr;
            }
        }
    }
    napi_value promise, name;
    if(napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
       napi_create_string_utf8(env, "ChiakiRemotePrepare", NAPI_AUTO_LENGTH, &name) != napi_ok ||
       napi_create_async_work(env, nullptr, name, ExecuteRemote, CompleteRemote, work, &work->work) != napi_ok ||
       napi_queue_async_work(env, work->work) != napi_ok) {
        if(work->work) napi_delete_async_work(env, work->work);
        if(work->progress) napi_release_threadsafe_function(work->progress, napi_tsfn_release);
        delete work;
        napi_throw_error(env, nullptr, "Could not start remote preparation");
        return nullptr;
    }
    return promise;
}

} // namespace

ChiakiHolepunchSession TakeArm64PreparedRemote(napi_env env, napi_value value) {
    PreparedRemote *prepared = nullptr;
    if(napi_get_value_external(env, value, reinterpret_cast<void **>(&prepared)) != napi_ok ||
       !prepared || !prepared->session) {
        napi_throw_type_error(env, nullptr, "preparedRemote must be an unused remote session handle");
        return nullptr;
    }
    ChiakiHolepunchSession session = prepared->session;
    prepared->session = nullptr; // ChiakiSession owns it from this point onward.
    return session;
}

napi_status RegisterArm64Remote(napi_env env, napi_value exports) {
    napi_property_descriptor descriptor = {
        "remotePrepareSession", nullptr, PrepareRemote, nullptr, nullptr, nullptr, napi_default, nullptr
    };
    return napi_define_properties(env, exports, 1, &descriptor);
}
