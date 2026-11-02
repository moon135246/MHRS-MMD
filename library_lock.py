"""One writer for imports and in-game deletions of a library."""
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
from pathlib import Path
import time


@contextmanager
def library_lock(root):
    path=Path(root)/'.library.lock'
    if path.is_symlink():raise ValueError('曲库锁不能是链接文件')
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,wintypes.LPVOID,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
    kernel.CreateFileW.restype=wintypes.HANDLE
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    invalid=ctypes.c_void_p(-1).value
    deadline=time.monotonic()+5
    while True:
        handle=kernel.CreateFileW(str(path),0xC0000000,0,None,4,0,None)
        if handle!=invalid:break
        if time.monotonic()>=deadline:raise ValueError('曲库正在更新，请稍后重试。')
        time.sleep(.05)
    try:yield
    finally:kernel.CloseHandle(handle)
