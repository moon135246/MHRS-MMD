"""Small standard-library front end for convert_vmd.py."""
import hashlib
import json
from pathlib import Path
import queue
import shutil
import tempfile
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from convert_vmd import convert
from audio_assets import stage_music, install_music
from audio_install import install_audio
from camera_assets import stage_camera, install_cameras
from asset_names import nickname as clean_nickname, asset_stem
from export_assets import install_export, export_mod
from library_install import install_library

HERE = Path(__file__).resolve().parent


def update_player(game):
    dest=game/'reframework/autorun/DSH_MMDRise_Player.lua'
    source=HERE/'播放器/reframework/autorun/DSH_MMDRise_Player.lua'
    camera_source=HERE/'播放器/reframework/autorun/MMDRise/Camera.lua'
    expression_source=HERE/'播放器/reframework/autorun/MMDRise/Expressions.lua'
    session_source=HERE/'播放器/reframework/autorun/MMDRise/Session.lua'
    hotkey_source=HERE/'播放器/reframework/autorun/MMDRise/Hotkeys.lua'
    package_source=HERE/'播放器/reframework/autorun/MMDRise/Packages.lua'
    extra=[HERE/'播放器/reframework/autorun/MMDRise'/name for name in ('Paths.lua','FrameStore.lua')]
    if not all(p.is_file() for p in (source,camera_source,expression_source,session_source,hotkey_source,package_source,*extra)):
        raise ValueError('播放器组件不完整，请完整复制1.0.0版转换工具文件夹')
    changed=False
    backup=game/'reframework/data/MMDRise/import_backups';backup.mkdir(parents=True,exist_ok=True)
    for source,dest in [(p,game/'reframework/autorun/MMDRise'/p.name) for p in extra]+[(camera_source,game/'reframework/autorun/MMDRise/Camera.lua'),
                        (expression_source,game/'reframework/autorun/MMDRise/Expressions.lua'),
                        (session_source,game/'reframework/autorun/MMDRise/Session.lua'),
                        (hotkey_source,game/'reframework/autorun/MMDRise/Hotkeys.lua'),
                        (package_source,game/'reframework/autorun/MMDRise/Packages.lua'),(source,dest)]:
        if dest.exists() and dest.read_bytes()==source.read_bytes():continue
        if dest.exists():
            digest=hashlib.sha256(dest.read_bytes()).hexdigest()[:16]
            saved=backup/(dest.stem+'_'+digest+'.lua')
            if not saved.exists():shutil.copy2(dest,saved)
        dest.parent.mkdir(parents=True,exist_ok=True)
        temporary=dest.with_suffix('.lua.importing');shutil.copy2(source,temporary);temporary.replace(dest)
        changed=True
    return changed


class App:
    def __init__(self, root):
        self.root=root;root.title('崛起 MMD · 导入 VMD 1.0.0');root.geometry('860x780');root.minsize(800,760)
        self.events=queue.Queue()
        self.motion=tk.StringVar();self.label=tk.StringVar();self.slug=tk.StringVar()
        self.pmx=tk.StringVar();self.output=tk.StringVar()
        self.output_auto=True;self.setting_output=False;self.last_motion=None;self.motion_job=None
        self.last_slug=''
        self.output.trace_add('write',self.output_changed)
        self.motion.trace_add('write',self.motion_changed)
        self.music=tk.StringVar();self.camera=tk.StringVar();self.expression=tk.StringVar()
        default='F:/SteamLibrary/steamapps/common/MonsterHunterRise'
        self.game=tk.StringVar(value=default if Path(default).is_dir() else '')
        self.install=tk.BooleanVar(value=Path(default).is_dir())
        self.height=tk.StringVar(value='还原动作高度（推荐）')
        box=ttk.Frame(root,padding=15);box.pack(fill='both',expand=True)
        box.columnconfigure(1,weight=1)
        for row,(label,var,kind) in enumerate([
            ('模型动作 VMD',self.motion,'vmd'),('曲目名称',self.label,None),
            ('曲目 ID（自动）',self.slug,None),('可选：配套 PMX',self.pmx,'pmx'),
            ('可选：配套音乐',self.music,'audio'),
            ('可选：镜头 VMD',self.camera,'camera'),
            ('可选：表情 VMD',self.expression,'expression'),
            ('导出文件夹',self.output,'dir'),('崛起游戏文件夹',self.game,'dir')]):
            ttk.Label(box,text=label).grid(row=row,column=0,sticky='w',pady=6)
            ttk.Entry(box,textvariable=var).grid(row=row,column=1,sticky='ew',padx=8)
            if kind:
                ttk.Button(box,text='选择…',command=lambda v=var,k=kind:self.pick(v,k)).grid(row=row,column=2)
        ttk.Button(box,text='默认',command=self.default_output).grid(row=7,column=3,padx=(5,0))
        ttk.Label(box,text='动作高度').grid(row=9,column=0,sticky='w',pady=6)
        ttk.Combobox(box,textvariable=self.height,state='readonly',values=['还原动作高度（推荐）','首帧高度归零（兼容旧版）']).grid(row=9,column=1,sticky='ew',padx=8)
        ttk.Checkbutton(box,text='转换成功后导入所选游戏（自动更新播放器、音乐与曲库组件并备份）',variable=self.install).grid(row=10,columnspan=4,sticky='w',pady=10)
        ttk.Label(box,text='按曲目名称创建“名称MMD_Dance”文件夹和 ZIP，里面已按游戏 MOD 目录排好。\n默认输出位置为动作所在目录的 MMD_Converted；可手选，点击“默认”可恢复。\n曲目名称同时用于所有资源文件名；安装说明放在 MOD 文件夹和 ZIP 旁边。\n表情留空读取动作内表情；选择独立文件则替代。需要 ShapeKeySystem 与支持的模型。',wraplength=790).grid(row=11,columnspan=4,sticky='w')
        self.button=ttk.Button(box,text='转换并导出 MOD 包',command=self.run);self.button.grid(row=12,columnspan=4,pady=15)
        self.status=tk.StringVar(value='选择“模型动作”文件；镜头、表情文件不能代替身体动作。')
        ttk.Label(box,textvariable=self.status,wraplength=790).grid(row=13,columnspan=4,sticky='w')
        root.after(150,self.poll)

    def pick(self,var,kind):
        types=[('音乐','*.wav *.mp3 *.flac')] if kind=='audio' else [('VMD','*.vmd')] if kind in ('camera','expression') else [(kind.upper(),'*.'+kind)]
        path=filedialog.askdirectory() if kind=='dir' else filedialog.askopenfilename(filetypes=types)
        if path:
            var.set(path)

    def output_changed(self,*_):
        if not self.setting_output:self.output_auto=False

    def default_output(self):
        self.output_auto=True
        self.setting_output=True
        try:
            self.output.set(str(Path(self.motion.get()).parent/'MMD_Converted') if self.motion.get().strip() else '')
        finally:self.setting_output=False

    def motion_changed(self,*_):
        if self.motion_job:self.root.after_cancel(self.motion_job)
        self.motion_job=self.root.after(250,self.sync_motion)

    def sync_motion(self):
        self.motion_job=None
        path=Path(self.motion.get().strip())
        if not path.is_file() or path==self.last_motion:return
        self.label.set(path.stem)
        slug='vmd_'+hashlib.sha256(path.read_bytes()).hexdigest()[:12]
        self.slug.set(slug)
        self.last_slug=slug;self.last_motion=path
        if self.output_auto:self.default_output()

    def run(self):
        self.sync_motion()
        motion,label,slug,pmx,output,game=[v.get().strip() for v in (self.motion,self.label,self.slug,self.pmx,self.output,self.game)]
        install=self.install.get()
        music=self.music.get().strip()
        camera=self.camera.get().strip()
        expression=self.expression.get().strip()
        vertical_reference='first_frame' if self.height.get().startswith('首帧') else 'rest'
        if not Path(motion).is_file() or not output:
            messagebox.showerror('尚未开始','请先选择模型动作 VMD 和导出文件夹。');return
        try:nickname=clean_nickname(label or Path(motion).stem)
        except ValueError as exc:
            messagebox.showerror('曲目名称无效',str(exc));return
        if install and (not (Path(game)/'MonsterHunterRise.exe').is_file() or not (Path(game)/'reframework/autorun/DSH_MMDRise_Player.lua').is_file()):
            messagebox.showerror('游戏目录不完整','请选择包含 MonsterHunterRise.exe 且已安装本项目播放器的文件夹。');return
        self.button.state(['disabled']);self.status.set('正在解析与转换，请稍候…')
        def worker():
            try:
                player_updated=False
                with tempfile.TemporaryDirectory(prefix='mhrs_vmd_') as temp:
                    staged=Path(temp)
                    try: report=convert(motion,slug,staged,label or None,pmx or None,vertical_reference=vertical_reference,expression_path=expression or None)
                    except ValueError:
                        # Preserve diagnostic reports even when IK prevents exporting.
                        if staged.exists():
                            Path(output).mkdir(parents=True,exist_ok=True)
                            for p in staged.glob('*_report.json'):shutil.copy2(p,Path(output)/(asset_stem(nickname,slug)+'_report.json'))
                        raise
                    if music:stage_music(music,staged,slug,label or Path(motion).stem)
                    camera_data=stage_camera(camera,staged,slug) if camera else None
                    bundle=export_mod(staged,Path(output),label or Path(motion).stem,nickname=nickname)
                    if install:
                        player_updated=update_player(Path(game))
                        install_export(staged,Path(game)/'reframework/data/MMDRise',nickname=nickname)
                        install_audio(Path(game))
                        install_library(Path(game))
                profile=report['source_profile']
                msg=f"已保存 {report['count']} 帧（{report['duration_seconds']:.1f} 秒）。\nMOD 文件夹：{bundle['folder']}\n"
                msg+=f"安装说明：{bundle['readme']}\n"
                if bundle['zip']:msg+=f"ZIP 压缩包：{bundle['zip']}\n"
                elif bundle['zip_error']:msg+='文件夹已导出；ZIP 未生成：'+bundle['zip_error']+'\n'
                msg+=f"将文件夹内的 reframework 合并到游戏目录即可使用（需播放器 1.0.0+）。\n手臂：{profile['label']}。"
                if install:
                    msg+=(' 播放器已升级，请在游戏Reset Scripts后选曲。' if player_updated else ' 游戏内点击“刷新曲库”，再选择曲目。')
                if music:msg+=' 配套音乐已绑定，将随舞蹈同步播放。'
                if report['expressions']['tracks']:msg+=f" 已保存表情（{report['expressions']['active_tracks']} 个有效通道），随舞蹈同步播放。"
                if camera_data:msg+=f" 镜头已绑定（{camera_data['start']/30:.1f}～{camera_data['end']/30:.1f} 秒），片段结束后恢复游戏相机。"
                if profile.get('confidence','').startswith(('assumed','inferred')):msg+=' 请抽查手臂姿态。'
                if report['warnings']:msg+='\n'+'\n'.join(report['warnings'])
                self.events.put((True,msg))
            except Exception as exc:self.events.put((False,str(exc)))
        threading.Thread(target=worker,daemon=True).start()

    def poll(self):
        try:
            ok,msg=self.events.get_nowait();self.button.state(['!disabled']);self.status.set(msg)
            (messagebox.showinfo if ok else messagebox.showerror)('转换完成' if ok else '未完成转换',msg)
        except queue.Empty:pass
        self.root.after(150,self.poll)


if __name__=='__main__':
    root=tk.Tk();App(root);root.mainloop()
