"""Install local library maintenance, including support for a running game."""
import ctypes
import hashlib
from ctypes import wintypes
from pathlib import Path
import shutil
import subprocess


def install_library(game):
    game=Path(game).resolve()
    source=Path(__file__).resolve().parent/'播放器/reframework/plugins'
    dest=game/'reframework/plugins';dest.mkdir(parents=True,exist_ok=True)
    for name in ('MMDRiseLibrary.dll','MMDRiseLibraryHost.exe'):
        src,dst=source/name,dest/name
        if not src.is_file():raise ValueError('缺少曲库组件：'+name+'\n请重新解压完整的 1.0.2 转换器文件夹。\n\nMissing library component: '+name+'\nExtract the complete converter 1.0.2 folder.')
        if dst.exists() and dst.read_bytes()==src.read_bytes():continue
        temp=dst.with_suffix(dst.suffix+'.importing');shutil.copy2(src,temp)
        try:temp.replace(dst)
        except PermissionError:
            saved=dst.with_name(dst.name+'.'+hashlib.sha256(dst.read_bytes()).hexdigest()[:16]+'.bak')
            if saved.exists():raise ValueError('曲库组件升级备份已存在，请关闭游戏后重试。')
            dst.rename(saved)
            try:temp.replace(dst)
            except Exception:
                saved.rename(dst);raise
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    psapi=ctypes.WinDLL('psapi',use_last_error=True)
    kernel.OpenProcess.restype=wintypes.HANDLE
    kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    kernel.QueryFullProcessImageNameW.argtypes=[wintypes.HANDLE,wintypes.DWORD,wintypes.LPWSTR,ctypes.POINTER(wintypes.DWORD)]
    ids=(wintypes.DWORD*16384)();count=wintypes.DWORD()
    if not psapi.EnumProcesses(ids,ctypes.sizeof(ids),ctypes.byref(count)):return
    for pid in ids[:count.value//ctypes.sizeof(wintypes.DWORD)]:
        h=kernel.OpenProcess(0x1000,False,pid)
        if not h:continue
        try:
            name=ctypes.create_unicode_buffer(32768);size=wintypes.DWORD(len(name))
            if kernel.QueryFullProcessImageNameW(h,0,name,ctypes.byref(size)) and name.value.casefold()==str(game/'MonsterHunterRise.exe').casefold():
                subprocess.Popen([str(dest/'MMDRiseLibraryHost.exe'),str(game),str(pid)],creationflags=subprocess.CREATE_NO_WINDOW)
                return
        finally:kernel.CloseHandle(h)
