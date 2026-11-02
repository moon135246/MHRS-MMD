"""Install the audio plugin; a hidden host supports an already-running game."""
import ctypes
from ctypes import wintypes
import hashlib
from pathlib import Path
import shutil
import subprocess


def install_audio(game):
    game = Path(game).resolve()
    source = Path(__file__).resolve().parent / '播放器/reframework/plugins'
    dest = game / 'reframework/plugins'
    dest.mkdir(parents=True, exist_ok=True)
    for name in ('MMDRiseAudio.dll', 'MMDRiseAudioHost.exe'):
        src, dst = source / name, dest / name
        if not src.is_file():
            raise ValueError('缺少音乐组件：'+name+'\n请重新解压完整的 1.0.3 转换器文件夹。\n\nMissing audio component: '+name+'\nExtract the complete converter 1.0.3 folder.')
        if dst.exists() and hashlib.sha256(src.read_bytes()).digest() == hashlib.sha256(dst.read_bytes()).digest():
            continue
        temporary = dst.with_suffix(dst.suffix + '.importing')
        shutil.copy2(src, temporary)
        try:
            temporary.replace(dst)
        except PermissionError:
            # Loaded DLLs cannot be overwritten. Keep the mapped image under a
            # backup name; the next game launch loads the new official name.
            digest=hashlib.sha256(dst.read_bytes()).hexdigest()[:16]
            saved=dst.with_name(dst.name+'.'+digest+'.bak')
            if saved.exists():
                raise ValueError('音乐组件仍在使用且升级备份已存在，请关闭游戏后重新导入。')
            try:
                dst.rename(saved)
                temporary.replace(dst)
            except Exception:
                if saved.exists() and not dst.exists():saved.rename(dst)
                raise
    # The plugin loads at game start. For an existing game use the same engine
    # out of process; a per-PID mutex prevents duplicate playback.
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    psapi = ctypes.WinDLL('psapi', use_last_error=True)
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    ids = (wintypes.DWORD * 16384)()
    count = wintypes.DWORD()
    if not psapi.EnumProcesses(ids, ctypes.sizeof(ids), ctypes.byref(count)):
        return
    wanted = str(game / 'MonsterHunterRise.exe').casefold()
    for pid in ids[:count.value // ctypes.sizeof(wintypes.DWORD)]:
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            continue
        try:
            buffer = ctypes.create_unicode_buffer(32768)
            size = wintypes.DWORD(len(buffer))
            if kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)) and buffer.value.casefold() == wanted:
                subprocess.Popen([str(dest / 'MMDRiseAudioHost.exe'), str(game), str(pid)], creationflags=subprocess.CREATE_NO_WINDOW)
                return
        finally:
            kernel.CloseHandle(handle)
