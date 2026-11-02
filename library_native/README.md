# MMDRiseLibrary v3 · player 1.0.3

Local Windows x64 maintenance; prebuilt DLL/host in 播放器/reframework/plugins. build.ps1 builds C++17 with the existing REFramework API and nlohmann/json headers and licenses under audio_native/vendor. No network service is used.

The DLL starts at game launch. The converter can start the same worker as a hidden host for a running game. Local\MMDRiseLibrary3_<PID> and library3_request.json / library3_status.json isolate the new worker from a still-mapped v2 DLL. Requests are deduplicated; stale startup requests are ignored. Version 3 is required for permanent deletion.

Deletion validates the complete plan within MMDRise, takes the shared .library.lock, releases playback first, removes only the requested bindings/settings, and retains shared media. Files are moved into a short-lived .delete_<request>_<slug> transaction while manifests are published; success purges the transaction. Locked-file failure rolls back, with no successful-deletion archive. An exceptional failed rollback/cleanup is reported and may leave temporary recovery data; it is not a normal backup feature.

Every two seconds the native worker compares relevant top-level asset/descriptor and music filename/size/mtime metadata. Changes rebuild paths.json and publish its revision; Lua watches at a throttled interval only while enabled (or while an explicit refresh is pending). No asset contents are polled per game frame. Disappeared package registrations are reconciled by managed_packages.json, while missing legacy motion/media sources are also pruned. Missing optional music/camera unbinds that media without removing an intact motion. Corrupt or partial present files still fail integrity checks.

UTF-8 logical names map to exact ANSI byte paths or hidden .runtime aliases where necessary. Cache copies support older loaded audio engines; they are temporary, excluded from exports, and pruned when originals disappear. Wide Unicode game paths remain supported by audio v3.

Evidence: _work/round31/test_library.py, library_validation.json, live_lifecycle.json. Tests cover native deletion without retained backups, shared media, locked-file rollback, Unicode aliases, full/descriptor-only/music-only MOD removal, restoration and reinstallation. The live fixture is independent of user songs.
