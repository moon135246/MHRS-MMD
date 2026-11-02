// Local library maintenance. File operations stay below one MMDRise directory.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <filesystem>
#include <fstream>
#include <thread>
#include <chrono>
#include <regex>
#include <set>
#include <vector>
#include <iostream>
#include <ctime>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include "../audio_native/vendor/json.hpp"
#include "../audio_native/vendor/API.h"
using json=nlohmann::json;
namespace fs=std::filesystem;

static json read_json(const fs::path& p,json fallback=json::object()) {
    if(!fs::exists(p))return fallback;
    std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("Cannot read library file");
    json v;f>>v;return v;
}
static void write_json(const fs::path& p,const json& v) {
    auto temp=p;temp+=L".library_tmp";
    {std::ofstream f(temp,std::ios::binary|std::ios::trunc);f<<v.dump(2);f.flush();if(!f)throw std::runtime_error("Cannot save library file");}
    if(!MoveFileExW(temp.c_str(),p.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Cannot publish library file");
}
static fs::path inside(const fs::path& root,const std::string& relative) {
    fs::path p=fs::u8path(relative);
    if(p.is_absolute() || relative.find(':')!=std::string::npos || relative.find('\\')!=std::string::npos)throw std::runtime_error("Invalid asset path");
    for(auto& part:p)if(part==L".." || part==L".")throw std::runtime_error("Invalid asset path");
    auto full=fs::weakly_canonical(root/p),base=fs::weakly_canonical(root);
    auto b=base.begin(),f=full.begin();for(;b!=base.end();++b,++f)if(f==full.end()||*f!=*b)throw std::runtime_error("Asset path leaves library");
    if(fs::is_symlink(root/p))throw std::runtime_error("Linked assets cannot be removed");
    return root/p;
}
struct LibraryLock {
    HANDLE handle=INVALID_HANDLE_VALUE;
    explicit LibraryLock(const fs::path& root) {
        auto path=inside(root,".library.lock");
        for(int i=0;i<100;++i) {
            handle=CreateFileW(path.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,0,nullptr);
            if(handle!=INVALID_HANDLE_VALUE)return;
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        throw std::runtime_error("Library is being updated; please retry");
    }
    ~LibraryLock(){if(handle!=INVALID_HANDLE_VALUE)CloseHandle(handle);}
};
// Lua's narrow file API uses the process ANSI codepage. Keep UTF-8 logical
// names in manifests and publish lossless native byte paths separately.
static std::string hex_bytes(const std::string& s) {
    std::ostringstream out;for(unsigned char c:s)out<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(c);return out.str();
}
static std::string key_for(const std::string& name) {
    unsigned long long h=14695981039346656037ULL;for(unsigned char c:name){h^=c;h*=1099511628211ULL;}
    std::ostringstream out;out<<std::hex<<std::setw(16)<<std::setfill('0')<<h;return out.str();
}
static bool asset_name(const std::string& name) {
    if(name.empty() || name.find('\0')!=std::string::npos)return false;
    auto p=fs::u8path(name);auto ext=p.extension().u8string();
    if(p.parent_path()==L"music")return ext==".wav"||ext==".mp3"||ext==".flac";
    if(!p.parent_path().empty() || ext!=".json")return false;
    return name.rfind("dance_",0)==0 || name.rfind("camera_",0)==0 ||
        std::regex_match(name,std::regex(".+_(motion|fingers|report|camera)\\.json"));
}
static void cleanup_caches(const fs::path& root,const json& paths) {
    std::set<std::string> live;
    for(auto& row:paths)if(row.is_object())live.insert(row.value("media",""));
    for(auto folder:{".runtime","music/.runtime"}) {
        auto dir=inside(root,folder);if(!fs::is_directory(dir))continue;
        for(auto& e:fs::directory_iterator(dir)) {
            auto name=e.path().filename().u8string();
            if(!std::regex_match(name,std::regex("[0-9a-f]{16}\\.(json|wav|mp3|flac)")))continue;
            auto relative=std::string(folder)+"/"+name;
            if(!live.count(relative)) {std::error_code ec;fs::remove(inside(root,relative),ec);}
        }
    }
}
static std::string asset_fingerprint(const fs::path& root) {
    std::vector<std::string> rows;
    for(auto folder:{"","music"}) {
        auto dir=root/fs::u8path(folder);if(!fs::is_directory(dir))continue;
        for(auto& e:fs::directory_iterator(dir))if(e.is_regular_file()) {
            auto name=fs::relative(e.path(),root).generic_u8string();
            bool descriptor=folder[0]=='\0' && name.rfind("package_",0)==0 && e.path().extension()==L".json";
            if(!descriptor&&!asset_name(name))continue;
            rows.push_back(name+":"+std::to_string(e.file_size())+":"+std::to_string(e.last_write_time().time_since_epoch().count()));
        }
    }
    std::sort(rows.begin(),rows.end());std::string result;
    for(auto& row:rows)result+=row+"\n";
    return result;
}
static json index_paths(const fs::path& root) {
    LibraryLock lock(root);
    json result={{"version",1},{"codepage",GetACP()},{"paths",json::object()},{"packages",json::array()}};
    FILETIME ft;GetSystemTimeAsFileTime(&ft);ULARGE_INTEGER stamp;stamp.LowPart=ft.dwLowDateTime;stamp.HighPart=ft.dwHighDateTime;
    result["revision"]=std::to_string(stamp.QuadPart)+"_"+std::to_string(GetCurrentProcessId());
    std::vector<fs::path> entries;
    for(auto& e:fs::directory_iterator(root))if(e.is_regular_file())entries.push_back(e.path());
    auto music=root/L"music";
    if(fs::is_directory(music))for(auto& e:fs::directory_iterator(music))if(e.is_regular_file())entries.push_back(e.path());
    for(auto& p:entries) {
        auto relative=fs::relative(p,root).generic_u8string();
        bool package=p.parent_path()==root && relative.rfind("package_",0)==0 && p.extension()==L".json";
        if(!package&&!asset_name(relative))continue;
        inside(root,relative);
        auto wide=fs::u8path(relative).generic_wstring();BOOL replaced=FALSE;
        auto cp=GetACP();DWORD flags=cp==CP_UTF8?0:WC_NO_BEST_FIT_CHARS;
        int n=WideCharToMultiByte(cp,flags,wide.data(),int(wide.size()),nullptr,0,nullptr,cp==CP_UTF8?nullptr:&replaced);
        std::string bytes(n,'\0');
        WideCharToMultiByte(cp,flags,wide.data(),int(wide.size()),bytes.data(),n,nullptr,cp==CP_UTF8?nullptr:&replaced);
        // Older audio engines consume UTF-8 through a narrow CRT API too.
        // Only unrepresentable JSON paths and non-ASCII audio need a cache.
        bool audio=p.parent_path()==music;
        bool non_ascii=std::any_of(relative.begin(),relative.end(),[](unsigned char c){return c>=128;});
        std::string media=relative;
        if(replaced || n==0 || (audio&&non_ascii)) {
            std::string cache_relative=audio?"music/.runtime/":".runtime/";
            auto cache=root/fs::u8path(cache_relative);fs::create_directories(cache);
            SetFileAttributesW(cache.c_str(),FILE_ATTRIBUTE_HIDDEN);
            auto filename=key_for(relative)+p.extension().u8string();auto dest=inside(root,cache_relative+filename);
            if(!fs::exists(dest)||fs::file_size(dest)!=fs::file_size(p)||fs::last_write_time(dest)!=fs::last_write_time(p)) {
                auto temp=dest;temp+=L".indexing";fs::copy_file(p,temp,fs::copy_options::overwrite_existing);
                if(!MoveFileExW(temp.c_str(),dest.c_str(),MOVEFILE_REPLACE_EXISTING))throw std::runtime_error("Cannot publish Unicode cache");
                fs::last_write_time(dest,fs::last_write_time(p));
            }
            bytes=cache_relative+filename;media=bytes;
        }
        result["paths"][relative]={{"hex",hex_bytes(bytes)},{"size",fs::file_size(p)},{"media",media}};
        if(package)result["packages"].push_back(relative);
    }
    write_json(root/L"paths.json",result);cleanup_caches(root,result["paths"]);
    return {{"ok",true},{"indexed",result["paths"].size()},{"index_revision",result["revision"]}};
}
static void move_asset(const fs::path& from,const fs::path& to) {
    fs::create_directories(to.parent_path());
    for(int i=0;i<40;++i) {
        std::error_code e;fs::rename(from,to,e);if(!e)return;
        if(e.value()!=ERROR_SHARING_VIOLATION && e.value()!=ERROR_ACCESS_DENIED)break;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    throw std::runtime_error("Cannot move asset; it may still be in use");
}
static json delete_track(const fs::path& input,const std::string& slug,const std::string& id) {
    if(!std::regex_match(slug,std::regex("[A-Za-z0-9][A-Za-z0-9_-]{0,63}")) ||
       !std::regex_match(id,std::regex("[A-Za-z0-9_-]{1,64}")))throw std::runtime_error("Invalid track or request ID");
    const auto root=fs::weakly_canonical(input);
    if(root.filename()!=L"MMDRise")throw std::runtime_error("Expected MMDRise library directory");
    LibraryLock lock(root);
    auto library=read_json(inside(root,"library.json"),{{"version",1},{"clips",json::array()}});
    if(!library.is_object()||!library.contains("clips")||!library["clips"].is_array())throw std::runtime_error("Invalid motion library");
    bool registered=slug=="smile_rise" && fs::is_regular_file(inside(root,"dance_smile_rise.json"));
    std::set<std::string> files;
    for(auto& c:library["clips"])if(c.value("slug","")==slug) {
        registered=true;
        for(auto field:{"file","fingers","report"})if(c.contains(field)) {
            auto name=c[field].get<std::string>();if(!asset_name(name))throw std::runtime_error("Invalid motion asset path");files.insert(name);
        }
    }
    if(!registered)throw std::runtime_error("Track is no longer in the library");
    std::vector<std::pair<std::string,json>> manifests;
    auto& clips=library["clips"];
    for(auto it=clips.begin();it!=clips.end();)if(it->value("slug","")==slug)it=clips.erase(it);else ++it;
    manifests.push_back({"library.json",library});
    for(auto suffix:{".json","_fingers.json","_report.json"})files.insert("dance_"+slug+suffix);
    files.insert(slug+"_fingers.json");
    for(auto& e:fs::directory_iterator(root)) {
        auto name=e.path().filename().u8string();
        if(e.is_regular_file()&&name.rfind("package_",0)==0&&e.path().extension()==L".json") {
            auto pkg=read_json(e.path());
            if(pkg.contains("clip")&&pkg["clip"].value("slug","")==slug)files.insert(name);
        }
    }
    for(auto kind:{"audio","camera"}) {
        std::string name=std::string(kind)+"_library.json";
        auto doc=read_json(inside(root,name),{{"version",1},{"tracks",json::object()}});
        if(!doc.is_object() || !doc.contains("tracks") || !doc["tracks"].is_object())throw std::runtime_error("Invalid media library");
        auto& tracks=doc["tracks"];
        std::string asset;
        if(tracks.contains(slug))asset=tracks[slug].value("file","");
        tracks.erase(slug);
        bool shared=false;for(auto& t:tracks)if(t.value("file","")==asset)shared=true;
        if(!asset.empty()&&!shared) {
            if(!asset_name(asset))throw std::runtime_error("Invalid media asset path");
            files.insert(asset);
        }
        if(fs::exists(root/name))manifests.push_back({name,doc});
        name=std::string(kind)+"_user.json";
        if(fs::exists(inside(root,name))) {
            auto user=read_json(root/name);
            if(!user.is_object())throw std::runtime_error("Invalid user settings");
            const char* field=std::string(kind)=="audio"?"offsets":"options";
            if(user.contains(field)&&user[field].is_object())user[field].erase(slug);
            manifests.push_back({name,user});
        }
    }
    // Cache aliases belong to the same recoverable removal, unless another
    // logical resource still references the alias. Never trust arbitrary paths.
    auto paths=read_json(root/L"paths.json").value("paths",json::object());
    std::vector<std::string> caches;
    for(auto& name:files)if(paths.contains(name)&&paths[name].is_object()) {
        auto cached=paths[name].value("media","");
        if(!std::regex_match(cached,std::regex("(music/\\.runtime/[0-9a-f]{16}\\.(wav|mp3|flac)|\\.runtime/[0-9a-f]{16}\\.json)")))continue;
        bool shared=false;
        for(auto it=paths.begin();it!=paths.end();++it)if(!files.count(it.key())&&it.value().value("media","")==cached)shared=true;
        if(!shared)caches.push_back(cached);
    }
    files.insert(caches.begin(),caches.end());
    for(auto& f:files)inside(root,f); // Validate the entire plan before mutation.
    // A short-lived transaction permits rollback on a locked file. Successful
    // deletion purges it; it is never retained as a user-facing backup.
    auto archive=inside(root,".delete_"+id+"_"+slug);
    if(fs::exists(archive))throw std::runtime_error("Duplicate deletion request");
    fs::create_directories(archive);
    std::vector<std::pair<fs::path,fs::path>> moved;
    std::vector<std::pair<fs::path,bool>> snapshots;
    try {
        for(auto& item:manifests) {
            auto p=root/item.first;bool exists=fs::exists(p);
            if(exists)fs::copy_file(p,archive/item.first);
            snapshots.push_back({p,exists});
        }
        write_json(archive/"deletion.json",{{"slug",slug},{"id",id},{"state","moving"}});
        for(auto& name:files) {
            auto from=inside(root,name);if(!fs::is_regular_file(from))continue;
            auto to=archive/"assets"/fs::u8path(name);move_asset(from,to);moved.push_back({from,to});
        }
        for(auto& item:manifests)write_json(root/item.first,item.second);
        write_json(archive/"deletion.json",{{"slug",slug},{"id",id},{"state","complete"},{"files",moved.size()}});
    } catch(...) {
        bool restored=true;
        for(auto it=moved.rbegin();it!=moved.rend();++it) {std::error_code e;fs::rename(it->second,it->first,e);restored=restored&&!e;}
        for(auto& snap:snapshots) {std::error_code e;if(snap.second)fs::copy_file(archive/snap.first.filename(),snap.first,fs::copy_options::overwrite_existing,e);else fs::remove(snap.first,e);restored=restored&&!e;}
        if(restored){std::error_code e;fs::remove_all(archive,e);}
        throw;
    }
    std::error_code cleanup;fs::remove_all(archive,cleanup);
    if(cleanup)throw std::runtime_error("Track unregistered; temporary deletion files are still in use. Refresh and retry cleanup after closing the game.");
    return {{"ok",true},{"id",id},{"slug",slug},{"files",moved.size()}};
}
static void run_library(fs::path game,DWORD pid) {
    HANDLE process=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return;
    wchar_t executable[32768]{};DWORD size=32768;
    if(!QueryFullProcessImageNameW(process,0,executable,&size)||fs::weakly_canonical(executable)!=fs::weakly_canonical(game/L"MonsterHunterRise.exe")){CloseHandle(process);return;}
    auto mutex_name=L"Local\\MMDRiseLibrary3_"+std::to_wstring(pid);
    HANDLE mutex=CreateMutexW(nullptr,TRUE,mutex_name.c_str());
    if(!mutex||GetLastError()==ERROR_ALREADY_EXISTS){if(mutex)CloseHandle(mutex);CloseHandle(process);return;}
    try {
        auto root=game/L"reframework/data/MMDRise";fs::create_directories(root);
        auto request=root/L"library3_request.json",status=root/L"library3_status.json";
        std::string last=read_json(request).value("id","");
        json outcome=json::object();std::string revision,fingerprint;
        try{auto indexed=index_paths(root);revision=indexed.value("index_revision","");fingerprint=asset_fingerprint(root);}catch(...){}
        auto next_write=std::chrono::steady_clock::time_point{};
        auto next_scan=std::chrono::steady_clock::now()+std::chrono::seconds(2);
        fs::file_time_type last_mtime{};
        while(WaitForSingleObject(process,0)==WAIT_TIMEOUT) {
            try {
                std::error_code ec;auto mtime=fs::last_write_time(request,ec);
                auto c=(!ec&&mtime!=last_mtime)?read_json(request):json::object();
                if(!ec)last_mtime=mtime;
                auto id=c.value("id","");
                if(!id.empty() && id!=last) {
                    last=id;
                    try {
                        auto action=c.value("action","");
                        if(action=="delete"){outcome=delete_track(root,c.value("slug",""),id);auto indexed=index_paths(root);revision=indexed.value("index_revision",revision);}
                        else if(action=="index"){outcome=index_paths(root);outcome["id"]=id;}
                        else throw std::runtime_error("Unknown library action");
                        revision=outcome.value("index_revision",revision);fingerprint=asset_fingerprint(root);
                    } catch(const std::exception& e) {outcome={{"id",id},{"ok",false},{"error",e.what()}};}
                    next_write={};
                }
            } catch(...) {} // A partial request is retried on the next poll.
            auto now=std::chrono::steady_clock::now();
            if(now>=next_scan) {
                try {
                    auto current=asset_fingerprint(root);
                    if(current!=fingerprint){auto indexed=index_paths(root);revision=indexed.value("index_revision",revision);fingerprint=current;next_write={};}
                    else cleanup_caches(root,read_json(root/L"paths.json").value("paths",json::object()));
                }catch(...){}
                next_scan=now+std::chrono::seconds(2);
            }
            if(now>=next_write) {
                auto value=outcome;value["ready"]=true;value["version"]=3;value["index_revision"]=revision;value["pid"]=pid;value["timestamp"]=time(nullptr);
                write_json(status,value);next_write=now+std::chrono::seconds(2);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
    } catch(...) {}
    ReleaseMutex(mutex);CloseHandle(mutex);CloseHandle(process);
}
#ifdef MMDRISE_LIBRARY_HOST
int wmain(int argc,wchar_t** argv) {
    if(argc==3&&std::wstring(argv[1])==L"--index") {
        try{std::cout<<index_paths(argv[2]).dump();return 0;}
        catch(const std::exception& e){std::cout<<json({{"ok",false},{"error",e.what()}}).dump();return 1;}
    }
    if(argc==5 && std::wstring(argv[1])==L"--delete") {
        try {auto s=fs::path(argv[3]).u8string(),id=fs::path(argv[4]).u8string();std::cout<<delete_track(argv[2],s,id).dump();return 0;}
        catch(const std::exception& e){std::cout<<json({{"ok",false},{"error",e.what()}}).dump();return 1;}
    }
    if(argc!=3)return 2;
    run_library(argv[1],wcstoul(argv[2],nullptr,10));return 0;
}
#else
extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* v) {v->major=1;v->minor=0;v->patch=0;v->game_name=nullptr;}
extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* p) {
    wchar_t name[32768]{};GetModuleFileNameW(nullptr,name,32768);auto game=fs::path(name).parent_path();
    try{std::thread([game](){run_library(game,GetCurrentProcessId());}).detach();}catch(...){return false;}
    p->functions->log_info("[MMDRiseLibrary] Local library maintenance initialized.");return true;
}
#endif
