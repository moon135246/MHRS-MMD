# 源手臂配置工具

本目录不是完整的任意VMD导入器，而是现有烘焙管线的源方向校准模块。

- 默认配置：标准MMD水平手臂，不默认施加45度。
- 已知动作：通过VMD的SHA256自动匹配已有实机配置，不依赖文件名。
- 可选PMX：读取静止关节位置，生成六段手臂方向配置；不自动宣称PMX与VMD匹配，也不执行完整IK/继承骨烘焙。
- 游戏外观：配置中不包含Shinano、DSM部件或游戏安装目录，目标比例适配独立处理。

`source_skeleton_profiles.py --pmx 模型.pmx --output 配置.json` 可自动提取源方向。

`retarget_smile_arms.py 原始动画.json 输出动画.json --profile 配置.json` 可用于Rise单位绑定格式动画。也可直接使用 `--pmx 模型.pmx`；没有选项则使用标准T-pose。它的输入是中间动画JSON，不是VMD。


目标bind/restw保持崛起单位阵；每骨方向纠正右乘到源世界旋转，并同步换算局部旋转，避免父子通道不一致。输出带来源和校准性质，拒绝重复转换。
