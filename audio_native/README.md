# MMDRiseAudio

Local streamed music playback for MMD-Rise. Windows x64; static CRT; no Python dependency in the game. Prebuilt DLL and hidden host are in `../播放器/reframework/plugins`.

`build.ps1` builds both binaries using this machine's Visual Studio 2022 and Windows SDK paths. Change the compiler/SDK paths when building elsewhere. Runtime code is `audio_backend.cpp`.

The REFramework plugin starts one worker. The standalone host supports a game that was already running when the importer installed the feature. A per-game-PID named mutex prevents duplicate engines; both use exactly the same playback code. The host exits with the selected game process. Plugin unloading during play is not supported.

Transport: `reframework/data/MMDRise/audio_transport.json`, written at ~20 Hz during playback and ~4 Hz while paused; closed/master-off publishes one stop then performs no Lua transport IO. Distinct session/sequence values constitute a heartbeat; revision marks seeks and transport changes. `time` is audio seconds after applying the track offset. Native v2 checks file time at 10 ms while loaded / 20 ms while unloaded, parses only changed packets, and publishes changed status at up to 5 Hz to `audio_status.json`. Fully idle status is written only on transitions. A heartbeat timeout of 1 second stops audio. Old transport files never autoplay until freshly updated.

The v2 engine uses `noAutoStart`; its audio device runs only while a sound plays. Pause, EOF, stale transport and unload stop the device; resume starts it again without changing the dance clock, seek revision or drift tolerance. A mapped game DLL is backed up under a `.bak` filename when upgrading; the next game launch loads v2. Reset scripts does not reload native DLLs. The per-PID mutex intentionally keeps the existing engine as owner until that launch.

Streaming: WAV/MP3/FLAC via miniaudio. OGG is not enabled. Seek/resume/loop/pitch/volume follow the dance clock. Speed changes affect pitch. Player 0.8 uses the game's temporary Wwise music-mute flag only while the owned music status confirms playback. Only paths below `music/` are accepted. Assets use content-hash filenames; `audio_library.json` maps clip IDs to files, labels and offset seconds. `audio_user.json` stores user volume/enable/offset/loop settings.

The worker catches malformed/partial packets, and RAII frees sound/engine/handles on exit or exceptions. No audio capture or network APIs are used by this implementation.

## Third-party sources

- miniaudio 0.11.23 — https://github.com/mackron/miniaudio/tree/0.11.23 — public domain or MIT-0, choose MIT-0. Full licensing text retained in `vendor/miniaudio.h`.
- nlohmann/json 3.11.3 — https://github.com/nlohmann/json/tree/v3.11.3 — MIT; notice retained in `vendor/json.hpp`, full license alongside it.
- REFramework API header — https://github.com/praydog/REFramework/blob/master/include/reframework/API.h — MIT; full license alongside it.

Validation and game measurements are saved under workspace `_work/round7` and `_work/round8`. The plugin's actual load and initialization were confirmed in `re2_framework_log.txt` on the user's subsequent game launch.

Audio version 3 (player 0.10): `ma_sound_init_from_file_w` opens Windows Unicode paths directly. Verified with a Chinese game-root folder and Chinese WAV filename through the real native host; transport timing/device idle behavior remains unchanged. A mapped v2 DLL is not hot-unloaded: current sessions can use the native path index audio cache, and the next game launch loads v3.
