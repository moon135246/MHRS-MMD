# MHRS-MMD

怪物猎人：崛起 MMD 转换器与播放器 · **1.0.3** · 作者 **moon**

将 MMD VMD 动作转换为《怪物猎人：崛起》可播放的数据，支持身体、手指、音乐、透视镜头和形态键表情。
MMD VMD converter and player for Monster Hunter Rise (Windows x64).

## 下载与安装

从 [Releases](https://github.com/moon135246/MHRS-MMD/releases) 下载成品，不熟悉源码的用户请选择附件中的转换器 ZIP 与播放器 ZIP。

1. 播放器：将 ZIP 内的 `reframework` 合并到游戏目录，或交给 MOD 管理器安装。游戏需已安装 REFramework。
2. 转换器：完整解压后运行 `启动转换器.cmd`。需要 Python 3.9+，包含 tkinter / Tcl/Tk，无额外 pip 依赖。
3. 选择模型动作 VMD，可选配套 PMX、音乐、镜头 VMD 与独立表情 VMD，再导出单曲 MOD 包。
4. 游戏内 REFramework → Script Generated UI → MMD 播放器，打开总开关、选曲并播放。

详细步骤与适配范围见 [使用说明](使用说明.md)。表情需要用户另行安装 ShapeKeySystem 及支持对应形态键的角色模型。

## 版本

本标签版本：**1.0.3**。兼容在完整段落边界省略尾部空段的 VMD；保留残缺计数和关键帧检查。修复 Conqueror 独立表情文件读取失败。

[版本记录](CHANGELOG.md) · [提交记录](https://github.com/moon135246/MHRS-MMD/commits/main/)

## 适配范围

普通 FK 动作按原流程转换。腿部 IK 支持范围以当前版本使用说明为准；补算是近似还原，配套 PMX 可提供骨架数据。
镜头需实际相机关键帧；表情通道还需角色模型支持。不同来源动作请自行核对效果。
本项目不附带舞蹈、模型、音乐、参考视频或游戏资源。

## 源码与构建

根目录为 Python 转换器，`播放器/reframework/autorun` 为 Lua 播放器。
成品中的 DLL/Host 为 Windows x64 原生组件。最新标签中的 `audio_native` 和 `library_native` 提供对应 C++ 源码，依赖头文件在 `audio_native/vendor`。
编译需 Visual Studio 2022 C++ 工具及 Windows SDK；先按本机版本调整 `build.ps1` 的编译器与 SDK 路径，再运行脚本。
较早标签保留当时分发的转换器源码及已编译组件。

## 反馈

请在 Issues 中填写播放器/转换器版本、操作步骤、完整报错与动作类型（身体/表情/镜头）。分享测试素材前请确认作者允许。

## 授权与第三方声明

项目源码已公开，项目自身尚未指定开源许可证；公开源码不代表额外授予修改或再分发许可。
第三方组件遵循各自许可证，见 [第三方声明](THIRD_PARTY_NOTICES.md) 及 `播放器/reframework/plugins/licenses/MMDRise`。
