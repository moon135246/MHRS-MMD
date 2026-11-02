// Local playback only. The same engine is used by the REFramework plugin and
// the current-session host. No sockets, injected Lua APIs, or capture devices.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <cstdio>
#include <exception>
#include "vendor/json.hpp"
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_ENCODING
#include "vendor/miniaudio.h"
#include "vendor/API.h"

using json=nlohmann::json;
namespace fs=std::filesystem;
using Clock=std::chrono::steady_clock;
static std::atomic<bool> stop_requested{false};
struct HandleGuard {
    HANDLE handle; bool mutex=false;
    ~HandleGuard(){if(handle){if(mutex)ReleaseMutex(handle);CloseHandle(handle);}}
};
struct AudioGuard {
    ma_engine* engine;ma_sound* sound;bool* loaded;
    ~AudioGuard(){if(*loaded)ma_sound_uninit(sound);ma_engine_uninit(engine);}
};

static void save_status(const fs::path& path,const json& value) {
    try {
        auto temp=path;temp+=L".tmp";
        {std::ofstream stream(temp,std::ios::binary|std::ios::trunc);stream<<value.dump();}
        MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING);
    } catch (...) {}
}

static bool safe_file(const std::string& name) {
    if(name.empty()||name.size()>180||name.find("..")!=std::string::npos||name[0]=='/'||name.find(':')!=std::string::npos||name.find('\\')!=std::string::npos)return false;
    return name.rfind("music/",0)==0;
}

static void run_audio(const fs::path& game,DWORD pid) {
    std::wstring mutex_name=L"Local\\MMDRiseAudio_"+std::to_wstring(pid);
    HANDLE mutex=CreateMutexW(nullptr,TRUE,mutex_name.c_str());
    if(!mutex||GetLastError()==ERROR_ALREADY_EXISTS){if(mutex)CloseHandle(mutex);return;}
    HandleGuard mutex_guard{mutex,true};
    HANDLE process=OpenProcess(SYNCHRONIZE,FALSE,pid);
    if(!process)return;
    HandleGuard process_guard{process};
    fs::path dir=game/L"reframework/data/MMDRise";
    fs::create_directories(dir);
    auto command_file=dir/L"audio_transport.json",status_file=dir/L"audio_status.json";
    save_status(status_file,{{"ready",false},{"error","Opening audio device"},{"pid",pid}});
    ma_engine engine{};auto config=ma_engine_config_init();
    config.periodSizeInMilliseconds=20;
    config.noAutoStart=MA_TRUE;
    ma_result init=ma_engine_init(&config,&engine);
    if(init!=MA_SUCCESS){save_status(status_file,{{"ready",false},{"error","Audio device initialization failed"},{"code",init},{"pid",pid}});return;}
    ma_sound sound{};bool loaded=false;
    AudioGuard audio_guard{&engine,&sound,&loaded};
    std::string file,error,session;json command=json::object();
    uint64_t last_seq=0,last_revision=0,seeks=0,packets_parsed=0;
    double duration=0,last_drift=0;bool previous_playing=false;
    bool device_started=false,status_dirty=true,previous_stale=true;
    auto last_packet=Clock::now()-std::chrono::seconds(5),last_status=Clock::now()-std::chrono::seconds(1);
    // A stale packet from a previous game/script run must never autoplay.
    std::error_code ec;auto initial_mtime=fs::last_write_time(command_file,ec);
    while(!stop_requested && WaitForSingleObject(process,0)==WAIT_TIMEOUT) {
        auto now=Clock::now();
        auto mtime=fs::last_write_time(command_file,ec);
        if(!ec && mtime!=initial_mtime) {
            try {
                std::ifstream stream(command_file,std::ios::binary);json next;stream>>next;
                initial_mtime=mtime;++packets_parsed;
                auto next_seq=next.value("seq",uint64_t{0});auto next_session=next.value("session",std::string{});
                if(next_seq!=last_seq||next_session!=session) {
                    last_seq=next_seq;session=next_session;last_packet=now;command=next;status_dirty=true;
                    std::string requested=next.value("file",std::string{});
                    bool enabled=next.value("enabled",false);
                    bool playing=enabled&&next.value("playing",false);
                    if(requested!=file) {
                        if(loaded){ma_sound_uninit(&sound);loaded=false;}
                        file=requested;error.clear();duration=0;previous_playing=false;
                        if(!file.empty()) {
                            if(!safe_file(file))error="Invalid music path";
                            else {
                                auto path=dir/fs::u8path(file);
                                auto result=ma_sound_init_from_file_w(&engine,path.c_str(),MA_SOUND_FLAG_STREAM|MA_SOUND_FLAG_NO_SPATIALIZATION,nullptr,nullptr,&sound);
                                loaded=result==MA_SUCCESS;
                                if(loaded){float seconds=0;ma_sound_get_length_in_seconds(&sound,&seconds);duration=seconds;}
                                else error="Cannot open music (WAV/MP3/FLAC supported)";
                            }
                        }
                    }
                    if(loaded) {
                        double target=next.value("time",0.0);
                        double speed=std::clamp(next.value("speed",1.0),.1,3.0);
                        float volume=float(std::clamp(next.value("volume",.65),0.0,1.0));
                        if(!std::isfinite(target))target=0;
                        auto revision=next.value("revision",uint64_t{0});
                        float position=0;ma_sound_get_cursor_in_seconds(&sound,&position);
                        last_drift=target-position;
                        bool force=revision!=last_revision||playing!=previous_playing;
                        if(!enabled||target<0||target>=duration){ma_sound_stop(&sound);playing=false;}
                        else {
                            ma_sound_set_pitch(&sound,float(speed));ma_sound_set_volume(&sound,volume);
                            if(force||std::abs(last_drift)>.18) {
                                ma_sound_stop(&sound);
                                ma_uint32 rate=0;ma_sound_get_data_format(&sound,nullptr,nullptr,&rate,nullptr,0);
                                ma_sound_seek_to_pcm_frame(&sound,ma_uint64(std::max(0.0,target)*rate));++seeks;
                            }
                            if(playing){
                                if(!device_started){
                                    auto result=ma_engine_start(&engine);
                                    device_started=result==MA_SUCCESS;
                                    if(!device_started){error="Cannot start audio device";playing=false;}
                                }
                                if(playing&&!ma_sound_is_playing(&sound))ma_sound_start(&sound);
                            }
                            else ma_sound_stop(&sound);
                        }
                        previous_playing=playing;last_revision=revision;
                    }
                }
            }catch(...){} // Ignore a partly-written packet; never drop the last valid one.
        }
        bool stale=std::chrono::duration<double>(now-last_packet).count()>1.0;
        if(stale&&loaded){ma_sound_stop(&sound);previous_playing=false;}
        if(stale!=previous_stale){status_dirty=true;previous_stale=stale;}
        bool audible=loaded&&bool(ma_sound_is_playing(&sound))&&!stale;
        if(device_started&&!audible){ma_engine_stop(&engine);device_started=false;status_dirty=true;}
        // Idle/off: publish transitions once, then no repeated JSON reads or
        // status writes. Keep the existing 10 ms synchronization while loaded.
        if(status_dirty&&std::chrono::duration<double>(now-last_status).count()>.2) {
            float position=0;if(loaded)ma_sound_get_cursor_in_seconds(&sound,&position);
            save_status(status_file,{{"ready",true},{"version",3},{"pid",pid},{"file",file},{"loaded",loaded},
                {"playing",loaded&&bool(ma_sound_is_playing(&sound))},{"position",position},{"duration",duration},
                {"error",error},{"stale",stale},{"seq",last_seq},{"session",session},{"seeks",seeks},
                {"drift_seconds",last_drift},{"transport",command},{"packets_parsed",packets_parsed},
                {"device_started",bool(ma_engine_get_device(&engine)&&ma_device_is_started(ma_engine_get_device(&engine)))}});
            last_status=now;status_dirty=false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(loaded?10:20));
    }
    save_status(status_file,{{"ready",false},{"error","Audio host stopped"},{"pid",pid}});
}

static void safe_run_audio(const fs::path& game,DWORD pid) noexcept {
    try{run_audio(game,pid);}
    catch(const std::exception& e){
        try{save_status(game/L"reframework/data/MMDRise/audio_status.json",{{"ready",false},{"error",e.what()},{"pid",pid}});}catch(...){}
    }catch(...){}
}

#ifdef MMDRISE_AUDIO_HOST
int wmain(int argc,wchar_t** argv) {
    if(argc!=3)return 2;
    safe_run_audio(fs::path(argv[1]),wcstoul(argv[2],nullptr,10));return 0;
}
#else
extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* v) {
    v->major=1;v->minor=0;v->patch=0;v->game_name=nullptr;
}
extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* p) {
    wchar_t name[32768]{};GetModuleFileNameW(nullptr,name,32768);
    auto game=fs::path(name).parent_path();
    try{std::thread([game](){safe_run_audio(game,GetCurrentProcessId());}).detach();}
    catch(...){return false;}
    p->functions->log_info("[MMDRiseAudio] Local music playback initialized.");return true;
}
#endif
