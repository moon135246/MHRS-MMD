# -*- coding: utf-8 -*-
"""Bilingual startup checks; no third-party Python packages are required."""
import os
import sys

MIN_PYTHON = (3, 9)
REQUIRED_FILES = ('import_gui.pyw', 'convert_vmd.py', 'vmd_lib.py', 'leg_ik.py',
    'pmx_skeleton.py', 'motion_translation.py', 'source_skeleton_profiles.py',
    'retarget_smile_arms.py', 'arm_inference.py', 'expression_assets.py',
    'audio_assets.py', 'audio_install.py', 'camera_assets.py', 'asset_names.py',
    'export_assets.py', 'library_install.py', 'library_lock.py')


def problem_message(code, detail=''):
    messages = {
        9: ('Python 版本不符合要求：需要 Python 3.9 或更高版本。\n请安装完整的 Python 3，并勾选 Tcl/Tk 和 IDLE 组件。',
            'Python 3.9 or newer is required. Install a complete Python 3 distribution with Tcl/Tk and IDLE.'),
        10: ('缺少 tkinter 图形界面组件。\n请修改或重新安装当前 Python，勾选 Tcl/Tk 和 IDLE；不需要使用 pip 安装本工具的依赖。',
             'The tkinter GUI component is missing. Modify or reinstall this Python with Tcl/Tk and IDLE. This tool does not require pip packages.'),
        11: ('转换器文件不完整：\n'+detail+'\n请重新解压完整的 MMD转换器_1.0.2 文件夹，不要只复制启动文件。',
             'Converter files are missing: '+detail+'\nExtract the complete MMD converter 1.0.2 folder; do not copy only the launcher.'),
        12: ('Tcl/Tk 图形环境无法初始化。\n请修复当前 Python 安装，确认 Tcl/Tk 和 IDLE 组件完整。',
             'Tcl/Tk could not initialize. Repair this Python installation and its Tcl/Tk and IDLE components.'),
        13: ('缺少 Python 标准库组件：'+detail+'\n请安装完整的 Python 3.9 或更高版本。',
             'A Python standard-library component is missing: '+detail+'\nInstall a complete Python 3.9 or newer distribution.'),
        14: ('转换器启动失败，请核对以下错误。', 'The converter could not start. Check the error below.')}
    cn,en=messages.get(code,messages[14])
    if detail and code not in (11,13):en+='\nDetails: '+detail
    return cn+'\n\n'+en


def check_environment():
    if sys.version_info < MIN_PYTHON:return 9,sys.version.split()[0]
    folder=os.path.dirname(os.path.abspath(__file__))
    missing=[name for name in REQUIRED_FILES if not os.path.isfile(os.path.join(folder,name))]
    if missing:return 11,', '.join(missing)
    try:
        import tkinter as tk
        from tkinter import ttk, filedialog, messagebox
    except ImportError as exc:return 10,str(exc)
    try:
        root=tk.Tk();root.withdraw();root.update_idletasks();root.destroy()
    except Exception as exc:return 12,str(exc)
    try:
        for name in ('ctypes','ctypes.wintypes','json','queue','tempfile','threading','shutil','subprocess','hashlib','pathlib','struct','math'):
            __import__(name)
    except ImportError as exc:return 13,getattr(exc,'name',str(exc))
    return 0,''


def show_startup_error(code, detail):
    message=problem_message(code,detail)
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(None,message,'启动失败 / Startup error',0x10)
    except Exception:
        print(message,file=sys.stderr)


def main():
    if '--gui' in sys.argv:
        try:
            import importlib.machinery
            import importlib.util
            filename=os.path.join(os.path.dirname(os.path.abspath(__file__)),'import_gui.pyw')
            loader=importlib.machinery.SourceFileLoader('mmdrise_import_gui',filename)
            spec=importlib.util.spec_from_loader(loader.name,loader)
            gui=importlib.util.module_from_spec(spec);loader.exec_module(gui)
            root=gui.tk.Tk();gui.App(root);root.mainloop()
            return 0
        except ModuleNotFoundError as exc:
            name=exc.name or ''
            show_startup_error(10 if name.startswith(('tkinter','_tkinter')) else 13,name)
        except Exception as exc:show_startup_error(14,str(exc))
        return 1
    code,detail=check_environment()
    if '--check' in sys.argv:return code
    if code:
        print(problem_message(code,detail))
        return code
    if '--explain' in sys.argv:return 0
    import subprocess
    pythonw=os.path.join(os.path.dirname(sys.executable),'pythonw.exe')
    executable=pythonw if os.path.isfile(pythonw) else sys.executable
    subprocess.Popen([executable,os.path.abspath(__file__),'--gui'],
        creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    return 0


if __name__=='__main__':
    try:sys.exit(main())
    except Exception as exc:
        show_startup_error(14,str(exc));sys.exit(1)
