-- MMD-Rise Player 1.0.3: readable assets, bounded frame storage, full master-off release.
-- Motion conventions are clip metadata; experimental controls are hidden.
-- REFramework > Script Generated UI > MMD 播放器.
log.info("[MMD-Rise Player] START 1.0.3 (Unicode assets and lifecycle memory)")
local PACKAGES = require("MMDRise.Packages")
local PATHS=require('MMDRise.Paths')
local FRAMESTORE=require('MMDRise.FrameStore')
local CAMERA = require("MMDRise.Camera")
local EXPRESSIONS = require("MMDRise.Expressions")
local SESSION = require("MMDRise.Session")
local HOTKEY = require("MMDRise.Hotkeys")

-- ================================================================ 常量
local IDENT = { 0.0, 0.0, 0.0, 1.0 }
local Y180  = { 0.0, 1.0, 0.0, 0.0 }   -- 180° 绕 Y（舞蹈整体偏航修正）
local SRCAX = { 0.0, 1.0, 0.0 }
local DEG = 57.29577951308232
local EPS = 1e-9

-- ================================================================ 数学
local function qmul(a, b)
    local ax, ay, az, aw = a[1], a[2], a[3], a[4]
    local bx, by, bz, bw = b[1], b[2], b[3], b[4]
    return {
        aw*bx + ax*bw + ay*bz - az*by,
        aw*by - ax*bz + ay*bw + az*bx,
        aw*bz + ax*by - ay*bx + az*bw,
        aw*bw - ax*bx - ay*by - az*bz,
    }
end
local function qinv(a) return { -a[1], -a[2], -a[3], a[4] } end
local function qrot(q, v)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local tx = 2 * (y*v[3] - z*v[2])
    local ty = 2 * (z*v[1] - x*v[3])
    local tz = 2 * (x*v[2] - y*v[1])
    return { v[1] + w*tx + (y*tz - z*ty), v[2] + w*ty + (z*tx - x*tz), v[3] + w*tz + (x*ty - y*tx) }
end
local function vnorm(v)
    local n = math.sqrt(v[1]*v[1] + v[2]*v[2] + v[3]*v[3])
    if n < EPS then return { 0, 0, 0 } end
    return { v[1]/n, v[2]/n, v[3]/n }
end
local function axis_angle(axis, rad)
    local h = rad * 0.5
    local s = math.sin(h)
    return { axis[1]*s, axis[2]*s, axis[3]*s, math.cos(h) }
end
local function qbetween(a, b)
    local d = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
    if d > 0.999999 then return { 0, 0, 0, 1 } end
    if d < -0.999999 then
        local ax = math.abs(a[1]) < 0.9 and { 1, 0, 0 } or { 0, 1, 0 }
        local c = { a[2]*ax[3] - a[3]*ax[2], a[3]*ax[1] - a[1]*ax[3], a[1]*ax[2] - a[2]*ax[1] }
        c = vnorm(c)
        return { c[1], c[2], c[3], 0.0 }
    end
    local c = { a[2]*b[3] - a[3]*b[2], a[3]*b[1] - a[1]*b[3], a[1]*b[2] - a[2]*b[1] }
    local q = { c[1], c[2], c[3], 1 + d }
    local n = math.sqrt(q[1]*q[1] + q[2]*q[2] + q[3]*q[3] + q[4]*q[4])
    if n < EPS then return { 0, 0, 0, 1 } end
    return { q[1]/n, q[2]/n, q[3]/n, q[4]/n }
end
local function qdiff(a, b)
    if a == nil or b == nil then return nil end
    local d = math.abs(a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4])
    if d > 1 then d = 1 end
    return 2 * math.acos(d) * DEG
end
-- 两个"单位向量"之间的夹角（度）。注意：不能拿 qdiff 当向量夹角用
-- （qdiff 会把 w 分量也点进去，永远返回 0 —— 那是个静默通过的自检陷阱）
local function vang(a, b)
    if a == nil or b == nil then return nil end
    -- 必须各自归一化：舞蹈数据的四元数并非严格单位（模长 0.999992~1.000008），
    -- qrot 对非单位四元数会按 |q|^2 缩放向量，不归一化会把缩放误算成 ~0.5° 的夹角
    local na = math.sqrt(a[1]*a[1] + a[2]*a[2] + a[3]*a[3])
    local nb = math.sqrt(b[1]*b[1] + b[2]*b[2] + b[3]*b[3])
    if na < EPS or nb < EPS then return nil end
    local d = (a[1]*b[1] + a[2]*b[2] + a[3]*b[3]) / (na * nb)
    if d > 1 then d = 1 end
    if d < -1 then d = -1 end
    return math.acos(d) * DEG
end
-- 单位化：源数据 w 与引擎返回的四元数都可能带 ~1e-5 的模长误差，
-- 直接写进 set_LocalRotation 会留下非单位四元数（引擎侧可能累积出缩放/漂移）
local function qnorm(q)
    if q == nil then return nil end
    local n = math.sqrt(q[1]*q[1] + q[2]*q[2] + q[3]*q[3] + q[4]*q[4])
    if n < EPS then return { 0.0, 0.0, 0.0, 1.0 } end
    return { q[1]/n, q[2]/n, q[3]/n, q[4]/n }
end
-- Shortest-arc spherical interpolation; q and -q represent the same rotation.
local function qslerp(a,b,t)
    a,b=qnorm(a),qnorm(b)
    if a==nil then return b end
    if b==nil then return a end
    local dot=a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4]
    if dot<0 then b={-b[1],-b[2],-b[3],-b[4]};dot=-dot end
    if dot>0.9995 then
        return qnorm({a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t,
            a[3]+(b[3]-a[3])*t,a[4]+(b[4]-a[4])*t})
    end
    local angle=math.acos(math.max(-1,math.min(1,dot)))
    local den=math.sin(angle)
    local u,v=math.sin((1-t)*angle)/den,math.sin(t*angle)/den
    return {u*a[1]+v*b[1],u*a[2]+v*b[2],u*a[3]+v*b[3],u*a[4]+v*b[4]}
end
-- Rise's neck skinning cannot carry large MMD neck bends without lifting the
-- collar/neck base. Keep small bends and Y-axis twist, then smoothly transfer
-- excess swing to Head. The product neck*head (and head world orientation)
-- stays unchanged. Stateless: seeking and fractional playback give the same pose.
local function rebalance_neck(neck,head)
    if neck==nil or head==nil then return neck,head,false end
    local n,h=qnorm(neck),qnorm(head)
    if n[4]<0 then n={-n[1],-n[2],-n[3],-n[4]} end
    local twist=qnorm({0,n[2],0,n[4]})
    local swing=qnorm(qmul(n,qinv(twist)))
    local angle=2*math.acos(math.max(-1,math.min(1,swing[4])))
    local start,span=25/DEG,10/DEG
    if angle<=start then return neck,head,false end
    local limited=start+span*(1-math.exp(-(angle-start)/span))
    local adjusted=qnorm(qmul(qslerp(IDENT,swing,limited/angle),twist))
    return adjusted,qnorm(qmul(qinv(adjusted),qmul(n,h))),true
end
-- Axial skin rotation, without changing the animation's main chain. Blending
-- rotation directions (40% moving, 60% neutral) keeps the shared roll bounded
-- and 2*pi periodic: unlike half-angle quaternions it cannot flip 180 degrees
-- when the main joint's twist crosses +/-pi. The small pole fade is important
-- for wrist poses whose swing makes axial twist undefined.
local function skin_twist_rotation(q,axis,counter)
    if q==nil or axis==nil then return nil end
    q=qnorm(q)
    local v=q[1]*axis[1]+q[2]*axis[2]+q[3]*axis[3]
    local w=q[4]
    local n2=v*v+w*w
    if n2<1e-12 then
        if counter then return nil end
        return IDENT
    end
    local roll=math.atan(2*v*w,1.5*n2+w*w-v*v)
    roll=roll*n2/(n2+0.0004)
    local shared=axis_angle(axis,roll)
    if not counter then return shared end
    local n=math.sqrt(n2)
    local twist={axis[1]*v/n,axis[2]*v/n,axis[3]*v/n,w/n}
    return qnorm(qmul(qinv(twist),shared))
end
-- Move the upper-arm axial correction into the main chain, then compensate
-- the forearm. This preserves elbow/wrist positions, forearm/hand world rotation
-- and the corrected upper-arm skin root, but removes the corkscrew between the
-- main upper-arm skin and its counter-rotated _T helper. Requires aligned axes.
local function rebalance_arm(upper,forearm,axis)
    if not upper or not forearm then return nil end
    local correction=skin_twist_rotation(upper,axis,true)
    if not correction then return nil end
    return qnorm(qmul(upper,correction)),qnorm(qmul(qinv(correction),forearm))
end
local function elbow_skin_rotation(q,axis)
    if not q or not axis then return nil end
    q=qnorm(q)
    local v=q[1]*axis[1]+q[2]*axis[2]+q[3]*axis[3]
    local n2=v*v+q[4]*q[4]
    if n2<1e-12 then return IDENT end
    local n=math.sqrt(n2)
    local twist={axis[1]*v/n,axis[2]*v/n,axis[3]*v/n,q[4]/n}
    local swing=qnorm(qmul(q,qinv(twist)))
    -- Fade the undefined twist pole, rather than selecting an arbitrary axis.
    return qslerp(IDENT,swing,0.5*n2/(n2+0.0004))
end
-- 轴角：轴(单位), 角(弧度, (-pi,pi])
local function quat_axis_angle(q)
    local vx, vy, vz, qw = q[1], q[2], q[3], q[4]
    local n = math.sqrt(vx*vx + vy*vy + vz*vz)
    if n < EPS then return nil, 0.0 end
    return { vx/n, vy/n, vz/n }, 2 * math.atan(n, qw)
end
-- 绕 axis 的带符号旋转角（用于旧模式与源步长统计）
local function signed_angle_about(q, axis)
    local a, ang = quat_axis_angle(q)
    if a == nil then return 0.0 end
    local s = a[1]*axis[1] + a[2]*axis[2] + a[3]*axis[3]
    if s < 0 then return -ang end
    return ang
end
-- C14 的可选"源步长限幅"：把 cur 朝 prev 方向收窄到 max_deg 以内（不动 prev 之前的历史）
local function limit_step(prev, cur, max_deg)
    if prev == nil or cur == nil or max_deg <= 0.0 then return cur end
    local d = qdiff(prev, cur)
    if d == nil or d <= max_deg then return cur end
    local r = qmul(cur, qinv(prev))
    if r[4] < 0 then r = { -r[1], -r[2], -r[3], -r[4] } end
    local half = math.acos(math.max(-1.0, math.min(1.0, r[4])))
    local s = math.sin(half)
    if s < EPS then return { prev[1], prev[2], prev[3], prev[4] } end
    local th = half * (max_deg / d)
    local k = math.sin(th) / s
    local qs = { r[1]*k, r[2]*k, r[3]*k, math.cos(th) }
    return qmul(qs, prev)
end
-- 崩溃防护：曾因 glm::qua 返回 nil 分量导致 string.format 崩，必须逐分量判定
local function asq(v)
    if v == nil then return nil end
    local ok, x = pcall(function() return v.x end)
    if not ok or type(x) ~= "number" then return nil end
    local ok2, y = pcall(function() return v.y end)
    local ok3, z = pcall(function() return v.z end)
    local ok4, w = pcall(function() return v.w end)
    if type(y) ~= "number" or type(z) ~= "number" or type(w) ~= "number" then return nil end
    return { x, y, z, w }
end
local function jget(j, m)
    if j == nil then return nil end
    local ok, v = pcall(j.call, j, m)
    if not ok then return nil end
    return asq(v)
end

-- Vector3f 版（位移通道用）
local function jget3(j, m)
    if j == nil then return nil end
    local ok, v = pcall(j.call, j, m)
    if not ok or v == nil then return nil end
    local okx, x = pcall(function() return v.x end)
    local oky, y = pcall(function() return v.y end)
    local okz, z = pcall(function() return v.z end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { x, y, z }
end

-- ================================================================ 状态（全部在函数之前声明）
local MMDRISE_AUDIO_VERSION = 1
local DIAGNOSTICS = false
local S = {
    enable = false, clip = "smile_rise", speed = 1.0,
    t = 0.0, playing = false, loop = true, rest_hold = false,
    mode = "dll",               -- "dll"(默认, 原作者原版公式) / "c14" / "abs" / "rest" / "f1"
    g_x180 = false,             -- DLL 模式的全局 G：false = identity (smile 纯正口径)
    use_twist = true,           -- 旧模式: 是否附加 roll
    reset_others = true,        -- 未映射关节清零
    helper_follow = true,       -- 扭曲/蒙皮辅助骨(<主链>_W/_T)与同级主链骨共用同一局部旋转（leg-solver 建议）
    root_zero = false,          -- ★根骨骼全局零位修正：smile 开场为背对(177.3°)，保持 false 不消除开场背对姿态
    pos_on = true,              -- ★位移通道：写 Cog 的局部位置（修"人物像被固定住 + 倾斜"）
    pos_scale = 0.08023,        -- MMD 单位 -> 米（vmd-smith 标定：源 Hip.wpos.y 0.6779 / 标准センター高度 8.45）
    pos_horiz = true,           -- 是否也写水平位移（原生舞蹈的水平位移在 actor 世界位置，不写进 Cog.lp，故不争夺）
    pos_subframe_lerp = true,   -- ★高刷子帧插值：消除游戏高帧率(120/144fps)与动画(30fps)失配导致的阶梯抽搐
    pos_smooth = true,          -- ★抗频闪平滑滤波：消除物理引擎与渲染帧率竞争产生的肉眼频闪
    pos_smooth_factor = 0.85,   -- 平滑滤波响应系数 (0.1 极柔和 ~ 1.0 纯直通)
    pos_mirror = false,         -- ★位置镜像：旋转用了 G=R_x180 镜像时，位置通道可能也需要镜像（动作"反向"的嫌疑）
    pos_z_flip = true,          -- ★位移前后反向：MMD的-Z前进映射到崛起的+Z前进（消除倒退太空步）
    pos_yaw_offset = 0.0,       -- ★位移独立偏航微调（度，解耦位移走位与骨骼姿态）
    reflect_z = true,           -- ★前后反射 Mz：使舞蹈动作与模型正面同向（必须开启，保持模型与动作一致朝向）
    use_fingers = true,         -- ★手指动捕通道：从伴生文件加载并驱动全部 30 根手指（五指张开/挥手/手势）
    arm_pure_local = true,      -- ★方案A：手臂纯净局部通道（跳过父子世界除法，直接采用纯净局部旋转）
    reflect_x = false,          -- ★左右镜像 Mx：翻转舞蹈左右走向（默认关；关=向镜头左边转身；开=向镜头右边转身）
    fix_foot = false,           -- ★修复脚部垂直朝天（纯净数据已无此畸变，默认关；旧数据自动激活）
    fix_arm = false,            -- ★自然手臂与躯干形态（默认关；纯净动捕数据叠加此项会导致耸肩前倾畸变）
    foot_pitch = 0.0,           -- ★脚部俯仰微调（度）：允许面板微调脚掌触地贴合角（±45°）
    shoulder_pitch = 0.0,       -- ★沉肩/肩高微调（度）：正=沉肩，负=耸肩（±30°）
    arm_width = 0.0,            -- ★大臂开合微调（默认 0.0，消除对抬手挥手/后腰动作的压制）
    elbow_pitch = 0.0,          -- ★肘部弯曲微调（度）：正/负调节小臂开合（±30°）
    yaw180 = false,             -- ★舞蹈整体偏航 180°（模型朝向对、舞蹈朝向反时勾）：左乘绕Y的180°到所有 target
    yaw_deg = 0.0,              -- ★舞蹈偏航微调（度，可扫描找正确角度）
    yaw_limb180 = false,        -- ★只把【肢体】转 180°（躯干不动）：模型对但肢体在背后时勾
    flip_fb = {},               -- 兼容旧字段
    flip_axis = {},             -- ★逐骨反射轴：bone -> "x"(左右) / "y"(上下) / "z"(前后)
    flip_mode = "z",            -- 当前编辑的反射轴（面板选择），"bend" = 弯曲方向翻转
    bendflip = {},              -- ★逐骨「弯曲方向翻转」：target ← target · axis_angle(SRCAX, π)（右乘、绕源轴）
                                --   来源：auditor 实测「腿部错向 100% → 0%」，且保持关节角保真 E1=0
                                --   与旧的 rollflip 区别：那个是【左乘】= 只转 roll 零点、方向不变（无效）
    absroot = false,            -- 绝对根修正：TRUE 会把 Cog 的世界旋转除掉 ⟹ 舞蹈被钉死在世界方向、不随角色自身朝向。
                                -- 用户实测指出这是错的：舞蹈必须表达在"角色本体坐标系"里 ⟹ 保持 FALSE（DLL 原版语义）。
                                --   （DLL 原版在荒野取 IDENT 是对的：那边根骨父级=模型空间；
                                --     照搬到崛起会让可见朝向 = Cog世界 ⊗ target，引擎的 Cog 一直乘在上面。
                                --     C14(L599)/M25(L692) 两个模式本来就是取 Cog.get_Rotation()，
                                --     只有 DLL 模式漏了 —— 这里补齐。默认开，可 A/B 关掉。）
    ik_off = true,              -- ★接管脚 IK：防止地面 TwoBoneIK 压制单脚独立抬腿
    ref_mode = "rest",          -- 旧 M25 的锚点: "rest" / "f1"
    limit_on = false,           -- 源步长限幅开关
    limit_deg = 12.0,           -- 限幅值（度/帧）
    rollflip = {},              -- [源骨骼名] = true  → R_b 右乘 axis_angle(axis,π)
    flip_input = "",
    written = 0, missing = 0, msg = "not loaded",
}
local function logmsg(s)
    S.msg = tostring(s)
    log.info("[MMD-Rise Player] " .. S.msg)
end

-- C14 的锚定状态
local CF = {
    inited = false, last_fi = nil, anchor_fi = nil,
    w0 = {}, wtp_ref = {}, Wt_ref = {}, Rfix = {}, Wt = {}, Qt = {},
    prevw_raw = {}, src_step = {},
    src_n = 0, src_max = 0.0, src_over30 = 0,
    anchor_check = 0.0, reanchors = 0,
}
-- 旧模式（M25 家族）的增量 twist 状态
local ST = { prev_w = {}, twist = {}, prev_fi = nil, max_inc = 0.0, max_n = 0, sum_n = 0 }
local TIME = { fps = 60.0, frames = 0, last_sec = os.time(), ticks = 0, clock = os.clock(), dt = 0 }
local AUDIO = {session = tostring(os.time()) .. ":" .. tostring(os.clock()), seq = 0,
    revision = 0, last_send = -10, last_read = -10, tracks = {}, status = {},
    enabled = true, volume = 0.65, offsets = {}}
local function audio_load_library()
    local ok, data = pcall(json.load_file, "MMDRise/audio_library.json")
    AUDIO.tracks = ok and type(data) == "table" and type(data.tracks) == "table" and data.tracks or {}
end
local function audio_save_settings()
    pcall(json.dump_file, "MMDRise/audio_user.json", {enabled=AUDIO.enabled, volume=AUDIO.volume,
        offsets=AUDIO.offsets, loop=S.loop})
end
do
    local ok, data = pcall(json.load_file, "MMDRise/audio_user.json")
    if ok and type(data) == "table" then
        if type(data.enabled) == "boolean" then AUDIO.enabled = data.enabled end
        if type(data.volume) == "number" then AUDIO.volume = math.max(0,math.min(1,data.volume)) end
        if type(data.offsets) == "table" then AUDIO.offsets = data.offsets end
        if type(data.loop) == "boolean" then S.loop = data.loop end
    end
    audio_load_library()
end

local anim = nil
local READY = false
-- All channels sample one fractional VMD frame, reused across repeated engine
-- callbacks. At integral frames the original approved samples are unchanged.
local SAMPLE = {}
local function sampled_body(fi)
    if SAMPLE.anim==anim and SAMPLE.t==S.t and SAMPLE.hold==S.rest_hold then return SAMPLE.body end
    local first=anim.frames[fi]
    local last=anim.frames[math.min(fi+1,anim.count or #anim.frames)]
    local alpha=S.rest_hold and 0 or (S.t-math.floor(S.t))
    local fg=anim.fingers and anim.fingers[fi]
    SAMPLE={anim=anim,t=S.t,hold=S.rest_hold,body=first,fingers=fg}
    if alpha<1e-7 or last==nil or first==nil or first==last then return first end
    local body={pos=first.pos}
    for _,bone in ipairs(anim.order) do
        local a,b=first[bone],last[bone]
        if a and b then
            body[bone]={w=qslerp(a.w,b.w,alpha),r=qslerp(a.r,b.r,alpha)}
        else body[bone]=a end
    end
    SAMPLE.body=body
    local next_fg=anim.fingers and anim.fingers[fi+1]
    if fg and next_fg then
        local fingers={}
        for name,q in pairs(fg) do fingers[name]=next_fg[name] and qslerp(q,next_fg[name],alpha) or q end
        SAMPLE.fingers=fingers
    end
    return body
end
-- The dance clock is authoritative; the native audio engine follows the same time.
local function audio_tick(force, shutdown)
    local now = os.clock()
    local track = AUDIO.tracks[S.clip]
    local media=type(track)=="table" and PATHS.media(track.file)
    local valid = type(track) == "table" and type(track.file) == "string"
    local offset = AUDIO.offsets[S.clip] or (valid and track.offset) or 0
    local enabled = SESSION.enabled and not shutdown and S.enable and AUDIO.enabled and valid
    if not enabled and not AUDIO.transport_active and not force then SESSION.music(false);return end
    -- Paused transport needs a heartbeat, but no moving-clock packets. Idle
    -- and master-off sessions publish one stop packet and then do no file IO.
    local interval=S.playing and 0.05 or 0.25
    if not force and now - AUDIO.last_send < interval then return end
    AUDIO.last_send = now;AUDIO.transport_active=enabled
    AUDIO.seq = AUDIO.seq + 1
    local ok, result = pcall(json.dump_file, "MMDRise/audio_transport.json", {
        seq=AUDIO.seq, session=AUDIO.session, revision=AUDIO.revision,
        file=enabled and media or "", enabled=enabled == true,
        playing=enabled and S.playing and READY == true,
        time=(anim and S.t/(anim.fps or 30) or 0)-offset,
        speed=S.speed, volume=AUDIO.volume, clip=S.clip, frame=S.t,
        written=S.written, missing=S.missing, clock_dt=TIME.dt})
    AUDIO.write_error = (not ok or result==false) and tostring(result) or nil
    if now - AUDIO.last_read > 0.25 then
        AUDIO.last_read = now
        local good, status = pcall(json.load_file, "MMDRise/audio_status.json")
        if good and type(status) == "table" then
            if status.seq~=AUDIO.status.seq or status.session~=AUDIO.status.session then AUDIO.status_changed_at=now end
            AUDIO.status = status
        end
    end
    local status=AUDIO.status
    local actual=enabled and S.playing and READY and not AUDIO.write_error and status.ready and status.loaded and status.playing
        and status.session==AUDIO.session and status.file==media and not status.stale
        and (not status.error or status.error=="") and now-(AUDIO.status_changed_at or -10)<1.0
    SESSION.music(SESSION.mute_bgm and actual==true)
end
audio_tick(true, true)
if type(re.on_script_reset) == "function" then
    re.on_script_reset(function() audio_tick(true, true) end)
end

local MAP, TLOCAL, AXISFB, DREFW, ANCHORW, ADIR, RESTW, BIND = {}, {}, {}, {}, {}, {}, {}, {}
local J, JORDER, RESET_LIST, RESET_SKIP, HELPER_LIST, IK_LIST = {}, {}, {}, {}, {}, {}
local SKIN_HELPERS = {}
local ARM_CHAINS = {}
local BINDING = {next_check=0,generation=0,status="等待本地玩家"}
local POS_ZERO = nil          -- 位移通道运行时零点（首次写入时抓取 Cog 的局部位置）
local WORLD_ZERO = nil        -- 角色顶级 Transform 起始世界位置（首次写入时抓取）
local WORLD_YAW_ZERO = 0.0    -- 角色开局时的世界偏航角（保证向前位移严格沿角色面朝方向推进）
local MASTER_XF = nil         -- 角色顶级 Transform 缓存
local LAST_WORLD_TIME = nil
local LAST_WORLD_POS = nil    -- 上一帧世界位置（供抗频闪 EMA 滤波器平滑使用）
local CLIPS = {
    { slug = "smile_rise", label = "★你的笑容(崛起纯血版)" },
    { slug = "smile_pos",  label = "你的笑容(旧版参考)" },
    { slug = "baam",       label = "★BAAM(当前唯一视觉正确)" },
    { slug = "seetinh",    label = "See Tinh" },
    { slug = "darling",    label = "Darling" },
    { slug = "blu",        label = "blu(坏数据对照)" },
}
-- Imported dances are registered by the converter; no Lua edits per dance.
local LIBRARY = {}
local function refresh_library(refresh)
    PACKAGES.sync(refresh)
    local ok, lib = pcall(json.load_file, "MMDRise/library.json")
    LIBRARY = {}
    local seen = {}
    -- The original sample predates library.json; include it only while its
    -- motion file exists. A deleted built-in sample must not reappear.
    local opened,file=pcall(io.open,"MMDRise/dance_smile_rise.json","rb")
    if opened and file then
        file:close()
        LIBRARY[#LIBRARY+1]={slug="smile_rise",label="还是你的笑容最可爱"};seen.smile_rise=true
    end
    for _, c in ipairs(ok and type(lib)=="table" and type(lib.clips)=="table" and lib.clips or {}) do
        if type(c) == "table" and type(c.slug) == "string" and
           string.match(c.slug, "^[%w][%w_%-]*$") and #c.slug <= 64 and
           type(c.label) == "string" and not seen[c.slug] then
            LIBRARY[#LIBRARY+1] = c
            seen[c.slug] = true
        end
    end
end
refresh_library()

local FLIP_BONES = {
    "L_UpperArm", "L_Forearm", "L_Hand", "L_Thigh", "L_Shin", "L_Foot",
    "R_UpperArm", "R_Forearm", "R_Hand", "R_Thigh", "R_Shin", "R_Foot",
}
local LN = 0
local diag_cd = 0
local SELF = { ref_dev = nil, map_dev = nil, map_n = 0, rest_all_ident = nil }

local function reset_twist()
    ST.prev_w, ST.twist = {}, {}
    ST.prev_fi = nil
end
local function reset_c14()
    CF.inited = false
    CF.last_fi = nil
    CF.anchor_fi = nil
    CF.w0, CF.wtp_ref, CF.Wt_ref, CF.Rfix, CF.Wt, CF.Qt = {}, {}, {}, {}, {}, {}
    CF.prevw_raw, CF.src_step = {}, {}
end
local function clear_stats()
    ST.max_inc, ST.max_n, ST.sum_n = 0.0, 0, 0
    CF.src_n, CF.src_max, CF.src_over30 = 0, 0.0, 0
    CF.reanchors = 0
end

-- ================================================================ 数据
local function build_ref()
    TLOCAL, AXISFB, DREFW, MAP, ANCHORW, ADIR, RESTW, BIND = {}, {}, {}, {}, {}, {}, {}, {}
    if anim == nil then return end
    for k, v in pairs(anim.map or {}) do MAP[k] = v end
    local ok, a = pcall(json.load_file, "MMDRise/align.json")
    if ok and type(a) == "table" and type(a.child_base) == "table" then
        for k, cb in pairs(a.child_base) do
            if type(cb) == "table" and type(cb.x) == "number" then
                local n = math.sqrt(cb.x*cb.x + cb.y*cb.y + cb.z*cb.z)
                if n > 1e-6 then TLOCAL[k] = { cb.x/n, cb.y/n, cb.z/n } end
            end
        end
    end
    -- 缺 T_local 的骨骼：叶子用「父级的 T_local」，根(Hip) 用局部 +Y
    -- （实测核对：TLOCAL[父级] == normalize(base_pos(叶子))，5 根全部 0.00°）
    local parent = anim.parent or {}
    local missing = {}
    for _, bone in ipairs(anim.order or {}) do
        if TLOCAL[bone] == nil then
            local pb = parent[bone]
            local ax = pb and TLOCAL[pb] or nil
            AXISFB[bone] = ax or SRCAX
            missing[#missing + 1] = bone
        end
    end
    local f0 = anim.frames and anim.frames[1]
    local restw = anim.restw or {}
    local nd, nrest, nrest_ident = 0, 0, 0
    for _, bone in ipairs(anim.order or {}) do
        local rw = restw[bone]
        if type(rw) ~= "table" then rw = nil end
        local aw = nil
        if S.ref_mode == "rest" then aw = rw end
        if aw == nil and f0 and f0[bone] then aw = f0[bone].w end
        if aw ~= nil then
            ANCHORW[bone] = aw
            DREFW[bone] = qrot(aw, SRCAX)
            nd = nd + 1
            if rw ~= nil then
                nrest = nrest + 1
                local dv = qdiff(rw, IDENT)
                if dv ~= nil and dv < 1.0 then nrest_ident = nrest_ident + 1 end
            end
        end
    end
    SELF.rest_all_ident = (nrest > 0) and (nrest_ident == nrest) or nil
    logmsg(string.format("预计算: TLOCAL=%d 根, 缺失回退=%d 根(%s), 锚点=%s, 有世界朝向=%d(restw %d)",
        (function() local c = 0 for _ in pairs(TLOCAL) do c = c + 1 end return c end)(),
        #missing, table.concat(missing, ","),
        S.ref_mode == "rest" and "静止姿态" or "第1帧", nd, nrest))
    for _, bone in ipairs(anim.order or {}) do
        local rw = restw[bone]
        if type(rw) == "table" then
            RESTW[bone] = rw
            local tl = TLOCAL[bone]
            if tl then ADIR[bone] = qbetween(qrot(rw, SRCAX), tl) end
        end
    end
    local nad = 0
    for _ in pairs(ADIR) do nad = nad + 1 end
    logmsg("绝对映射对齐四元数 ADIR: " .. nad .. " 根")

    -- DLL 原版模式所需：源绑定姿态 bindMap（作为"世界增量"的锚点）
    BIND = {}
    local bindtbl = anim.bind or {}
    for _, bone in ipairs(anim.order) do
        local bq = bindtbl[bone]
        if type(bq) == "table" then BIND[bone] = qnorm(bq) end
    end
    local nb = 0
    for _ in pairs(BIND) do nb = nb + 1 end
    logmsg("DLL模式 源绑定姿态 bindMap: " .. nb .. " 根")
end

-- C14 启动自检（纯数据，不需要关节）：
--   (1) 参考帧恒等：以数据 ref 帧为参考、wtp_ref = IDENT 的合成环境下应得 Qt = identity
--   (2) 映射自检：目标世界方向 == R_b · 源方向（C14 的精确性），扫若干帧
local function c14_self_check()
    SELF.ref_dev, SELF.map_dev, SELF.map_n = nil, nil, 0
    if anim == nil or type(anim.frames) ~= "table" or #anim.frames == 0 then return end
    local frames = anim.frames
    local ridx = tonumber(anim.ref) or 1
    if ridx < 1 or ridx > #frames then ridx = 1 end
    local fref = frames[ridx]
    if fref == nil then return end
    local refmax = 0.0
    local mapmax = 0.0
    local sampled = 0
    local last = #frames
    local step = 1
    if last > 600 then step = math.floor(last / 600) end
    for _, bone in ipairs(anim.order or {}) do
        local e0 = fref[bone]
        if e0 ~= nil and e0.w ~= nil then
            local ax = TLOCAL[bone] or AXISFB[bone] or SRCAX
            -- 合成：wtp_ref = IDENT
            local dref = qrot(qnorm(e0.w), SRCAX)
            local R = qbetween(dref, ax)
            -- roll 翻转必须是【左乘】：axis_angle(ax,π)·R_b 保持 R_b·dref = ax（方向不变），
            -- 只把 roll 零点转 180°。若写成 R_b·axis_angle(ax,π) 会破坏方向映射。
            if S.rollflip[bone] then R = qmul(axis_angle(ax, math.pi), R) end
            -- (1) 参考帧：D = I → Qt 应为 identity
            local Dref = qmul(qnorm(e0.w), qinv(qnorm(e0.w)))
            local Wref = qmul(qmul(qmul(R, Dref), qinv(R)), IDENT)
            local d1 = qdiff(qmul(qinv(IDENT), Wref), IDENT)
            if d1 ~= nil and d1 > refmax then refmax = d1 end
            -- (2) 扫描：目标世界方向(Wt·ax) 应恒等于 R·(源方向)
            for k = 1, last, step do
                local e = frames[k][bone]
                if e ~= nil and e.w ~= nil then
                    local D = qmul(qnorm(e.w), qinv(qnorm(e0.w)))
                    local Wt = qmul(qmul(qmul(R, D), qinv(R)), IDENT)
                    local a1 = qrot(Wt, ax)
                    local a2 = qrot(R, qrot(qnorm(e.w), SRCAX))
                    local d2 = vang(a1, a2)
                    if d2 ~= nil and d2 > mapmax then mapmax = d2 end
                    sampled = sampled + 1
                end
            end
        end
    end
    SELF.ref_dev = refmax
    SELF.map_dev = mapmax
    SELF.map_n = sampled
    logmsg(string.format("C14 自检: 参考帧(ref=%d)与 identity 最大偏差=%.6f°, 映射(世界方向)最大误差=%.4f° (采样 %d)",
        ridx, refmax, mapmax, sampled))
    if SELF.rest_all_ident == true then
        logmsg("提示: restw 全是 identity（restWorldMap 未提供有效静止姿态）—— 旧 abs 模式会失真, C14 不受影响")
    end
end

local function clip_asset(slug,field,fallback)
    for _,c in ipairs(LIBRARY) do if c.slug==slug then return c[field] or fallback end end
    return fallback
end
local function load_fingers_now(slug)
    slug = slug or S.clip
    if anim == nil then return false end
    anim.fingers = nil
    local base_slug = string.gsub(string.gsub(slug, "_pos", ""), "_rise", "")
    local fg_candidates = {
        "MMDRise/" .. slug .. "_fingers.json",
        "MMDRise/dance_" .. slug .. "_fingers.json",
        "MMDRise/dance_" .. base_slug .. "_fingers.json",
        "MMDRise/" .. base_slug .. "_fingers.json",
    }
    -- Smile compatibility paths belong only to Smile, never another dance.
    if string.sub(slug, 1, 5) == "smile" then
        fg_candidates[#fg_candidates+1] = "MMDRise/dance_smile_fingers.json"
        fg_candidates[#fg_candidates+1] = "MMDRise/smile_pos_fingers.json"
    end

    local explicit=clip_asset(slug,'fingers')
    if explicit then table.insert(fg_candidates,1,PATHS.path(explicit) or '') end
    local loaded_fg = nil
    local loaded_name = nil
    for _, fn in ipairs(fg_candidates) do
        local okf, fg = pcall(json.load_file, fn)
        if okf and type(fg) == "table" and #fg > 0 then
            loaded_fg = fg
            loaded_name = fn
            break
        end
    end
    if loaded_fg ~= nil then
        anim.fingers = loaded_fg
        logmsg(string.format("[FINGERS-LOADED] 成功载入手指动捕文件: %s (共 %d 帧)", loaded_name, #loaded_fg))
        return true
    else
        logmsg(string.format("[FINGERS-WARN] 未能载入任何伴生手指文件 (已检索 %d 个候选路径)", #fg_candidates))
        return false
    end
end

local function load_clip(slug)
    local name=clip_asset(slug,'file','dance_'..slug..'.json')
    local path=PATHS.path(name)
    local ok, d = pcall(json.load_file, path or '')
    if not ok or type(d) ~= "table" or type(d.frames) ~= "table" then
        logmsg("载入失败: dance_" .. slug .. ".json -> " .. tostring(d))
        return false
    end
    if d.converter == "mhrs_vmd_1" then
        -- Imported clips start from their own defaults, not a previous clip's tuning.
        S.mode = "dll"
        S.pos_on, S.pos_horiz = true, true
        S.pos_yaw_offset = 0.0
        S.flip_axis, S.bendflip, S.rollflip = {}, {}, {}
        S.yaw_limb180 = false
        S.elbow_pitch = d.elbow_pitch or 0.0
        S.shoulder_pitch = d.shoulder_pitch or 0.0
        S.arm_width = d.arm_width or 0.0
        S.fix_arm = d.fix_arm == true
    end
    CAMERA.release_mmd()
    EXPRESSIONS.release()
    AUDIO.revision = AUDIO.revision + 1
    anim = d
    S.t = 0.0
    S.clip = slug
    POS_ZERO = nil            -- 位移零点重新锚定（切舞）
    WORLD_ZERO = nil
    WORLD_YAW_ZERO = 0.0
    LAST_WORLD_POS = nil
    -- ★ 镜像约定是【每个 clip 各自的属性】，不能全局写死（用户实测：
    --   smile 取消 G=180° 后手臂方向正常，但 BAAM 取消后手臂反而不正常）
    --   舞蹈 JSON 里若带 "g_x180" 则采用它；旧 clip 无此字段 ⟹ 保持面板当前值（默认 true）
    if type(d.g_x180) == "boolean" then S.g_x180 = d.g_x180 end
    -- ★ 同理：根骨零位修正也必须是【每个 clip 各自的属性】。
    --   smile 的 VMD 第 0 帧本身就是 177.3° 偏航 = 角色背对开局（合法开场姿势），
    --   抵消它会把"背面开局"变成"正面开局"（用户实测）。故 smile 必须 root_zero=false。
    if type(d.root_zero) == "boolean" then S.root_zero = d.root_zero end
    -- ★ 位移通道也按 clip 走：Unity 导出的 4 支舞源是左手系 ⟹ 需 X 镜像、单位=米(scale 1.0)；
    --   smile 来自 VMD(MMD 单位, 左=+X) ⟹ 不镜像、scale 0.08023。
    --   权威旁证：荒野 DLL 自己的 Lua 髋位移就是 Vector3f.new(-wx, wy, wz)（注释"X镜像(与旋转同一G约定)"）
    if type(d.pos_mirror) == "boolean" then S.pos_mirror = d.pos_mirror end
    if type(d.pos_z_flip) == "boolean" then S.pos_z_flip = d.pos_z_flip end
    if type(d.reflect_z) == "boolean" then S.reflect_z = d.reflect_z end
    if type(d.reflect_x) == "boolean" then S.reflect_x = d.reflect_x end
    if type(d.fix_foot) == "boolean" then S.fix_foot = d.fix_foot end
    if type(d.foot_pitch) == "number" then S.foot_pitch = d.foot_pitch end
    if type(d.shoulder_pitch) == "number" then S.shoulder_pitch = d.shoulder_pitch end
    if type(d.arm_width) == "number" then S.arm_width = d.arm_width end
    if type(d.yaw180) == "boolean" then S.yaw180 = d.yaw180; S.yaw_deg = d.yaw180 and 180.0 or 0.0 end
    if type(d.pos_scale) == "number" then S.pos_scale = d.pos_scale end
    -- ★ 崛起纯血版动画默认使用原生父子世界除法解算（零畸变），保持 arm_pure_local = false；旧版参考保持纯净局部通道
    if slug == "smile_rise" then
        S.arm_pure_local = false
    elseif slug == "smile_pos" then
        S.arm_pure_local = true
    end
    if type(d.arm_pure_local) == "boolean" then S.arm_pure_local = d.arm_pure_local end
    build_ref()
    c14_self_check()
    reset_twist()
    reset_c14()
    clear_stats()
    -- ★ 载入伴生手指动捕文件（多候选智能匹配）
    load_fingers_now(slug)
    FRAMESTORE.compact(d)
    SAMPLE={}
    collectgarbage("collect")
    logmsg(string.format("已载入 %s: frames=%d fps=%s 时长=%.1fs ref=%s",
        slug, #d.frames, tostring(d.fps), #d.frames / (d.fps or 30), tostring(d.ref)))
    return true
end

-- ================================================================ 关节
local function get_master_go()
    local pm = sdk.get_managed_singleton("snow.player.PlayerManager")
    if pm == nil then return nil end
    for _,method in ipairs({"findMasterPlayer()","findMasterPlayer","getMasterPlayer"}) do
        local ok,master=pcall(pm.call,pm,method)
        if ok and master then
            local good,index=pcall(master.call,master,"getPlayerIndex")
            if good and type(index)=="number" then
                local got,go=pcall(master.call,master,"get_GameObject")
                if got and go then return go,master,index end
            end
        end
    end
    return nil
end
-- A model name (or player00) does not identify the local hunter. Resolve through
-- PlayerManager and keep its index plus object identity, as in the supplied mods.
function BINDING.snapshot(go,owner,index,xf)
    if not go then go,owner,index=get_master_go() end
    if not go then return nil,"等待本地玩家" end
    if not xf then
        local ok,value=pcall(go.call,go,"get_Transform")
        if ok then xf=value end
    end
    if not xf then return nil,"等待主角 Transform" end
    local ok,preview=pcall(function() return owner:get_type_definition():is_a("snow.player.PlayerSaveLoad") end)
    if ok and preview then return nil,"等待可游玩的主角（当前为存档预览）" end
    local got,joints=pcall(xf.get_Joints,xf)
    if not got or not joints then return nil,"等待主角骨架" end
    local map,order={},{}
    for _,joint in pairs(joints) do
        local good,name=pcall(joint.get_Name,joint)
        if not good or not name or map[name] then return nil,"等待完整骨架" end
        map[name]=joint;order[#order+1]=name
    end
    for _,name in ipairs({"Cog","Waist_00","Spine_01","Neck_00","Head_00",
        "L_Arm_01","L_Arm_02","L_Arm_03","R_Arm_01","R_Arm_02","R_Arm_03",
        "L_Leg_00","L_Leg_01","L_Leg_02","R_Leg_00","R_Leg_01","R_Leg_02"}) do
        if not map[name] then return nil,"等待主角完整骨架: "..name end
    end
    local parent_ok,parent=pcall(map.Waist_00.call,map.Waist_00,"get_Parent")
    if not parent_ok or parent~=map.Cog then return nil,"等待主角根骨父链" end
    local parts={}
    local child_ok,child=pcall(xf.call,xf,"get_Child")
    local seen,visited={},0
    while child_ok and child and not seen[child] and visited<64 do
        seen[child]=true;visited=visited+1
        local obj_ok,obj=pcall(child.call,child,"get_GameObject")
        if obj_ok and obj then
            local name_ok,name=pcall(obj.call,obj,"get_Name")
            if name_ok and type(name)=="string" and
                (name:match("^[fm]_helm%d") or name:match("^[fm]_body%d") or name:match("^[fm]_arm%d") or
                 name:match("^[fm]_wst%d") or name:match("^[fm]_leg%d")) then
                parts[#parts+1]=name..":"..tostring(obj)
            end
        end
        child_ok,child=pcall(child.call,child,"get_Next")
    end
    table.sort(parts)
    return {go=go,owner=owner,index=index,xf=xf,joints=map,order=order,parts=table.concat(parts,"|")}
end
function BINDING.same_joints(candidate)
    if #JORDER~=#candidate.order then return false end
    for name,joint in pairs(candidate.joints) do if J[name]~=joint then return false end end
    return true
end
local function refresh(candidate,preserve_stage)
    candidate=candidate or BINDING.snapshot()
    if not candidate then return false end
    MASTER_XF=candidate.xf
    if not preserve_stage then
        POS_ZERO=nil;WORLD_ZERO=nil;WORLD_YAW_ZERO=0;LAST_WORLD_POS=nil
    end
    J,JORDER=candidate.joints,candidate.order
    local miss = {}
    for _, bone in ipairs(anim and anim.order or {}) do
        local t = MAP[bone]
        if t == nil or J[t] == nil then miss[#miss + 1] = bone end
    end
    READY = J["Cog"] ~= nil and #JORDER > 0
    local wset, anc = {}, {}
    for _, bone in ipairs(anim and anim.order or {}) do
        local t = MAP[bone]
        if t then wset[t] = true end
    end
    for name in pairs(wset) do
        local j = J[name]
        local guard = 0
        while j ~= nil and guard < 24 do
            local okp, par = pcall(j.call, j, "get_Parent")
            if not okp or par == nil then break end
            local okn, pn = pcall(par.get_Name, par)
            if not okn or pn == nil or anc[pn] then break end
            anc[pn] = true
            j = par
            guard = guard + 1
        end
    end
    RESET_LIST = {}
    RESET_SKIP = {}
    -- P2 修复：不碰约束骨/派生骨（IK、扭转派生骨、武器挂点、摄像头、表情控制器等）。
    -- 这些骨被引擎/物理驱动或动捕驱动，硬写 identity 会冻结扭转或导致手指死死握拳。
    local RISKY = { "_IK", "_W", "_T", "Face", "LookAt", "Weapon", "Grip", "PL_Cam", "Cam", "RootMotion", "Neck_00_S", "Finger" }
    local nskip = 0
    for _, nm in ipairs(JORDER) do
        if not wset[nm] and not anc[nm] then
            local skip = false
            for _, pat in ipairs(RISKY) do
                if string.find(nm, pat, 1, true) ~= nil then skip = true break end
            end
            local j = J[nm]
            if not skip and j ~= nil then
                local okc, cj = pcall(j.call, j, "get_ConstraintJoint")
                if okc and cj ~= nil then skip = true end
            end
            if skip then
                nskip = nskip + 1
                RESET_SKIP[#RESET_SKIP + 1] = nm
            else
                RESET_LIST[#RESET_LIST + 1] = nm
            end
        end
    end
    logmsg(string.format("关节就绪: %d 根, 映射缺失=%s, 映射骨骼=%d, 待清零=%d(跳过约束/派生骨 %d), Cog=%s",
        #JORDER, #miss == 0 and "无" or table.concat(miss, ","),
        (function() local c = 0 for _ in pairs(wset) do c = c + 1 end return c end)(),
        #RESET_LIST, nskip, tostring(J["Cog"] ~= nil)))
    -- Inventory only. _W/_T do NOT share one hierarchy: arm helpers are children
    -- of their main joints, while some leg helpers are siblings. Copying the
    -- main local rotation into all of them would double child-joint rotations.
    HELPER_LIST = {}
    for _, nm in ipairs(JORDER) do
        local base = nil
        local b1 = string.match(nm, "^(.-)_W$")
        local b2 = string.match(nm, "^(.-)_T$")
        if b1 ~= nil then base = b1 elseif b2 ~= nil then base = b2 end
        if base ~= nil and J[base] ~= nil then
            HELPER_LIST[#HELPER_LIST + 1] = { nm, base }
        end
    end
    logmsg("辅助骨清单(不直接复制主骨旋转) " .. #HELPER_LIST .. " 根: " ..
        (function()
            local t = {}
            for _, p in ipairs(HELPER_LIST) do t[#t + 1] = p[1] .. "<-" .. p[2] end
            return table.concat(t, " ")
        end)())

    SKIN_HELPERS = {}
    for _,side in ipairs({"L","R"}) do
        local prefix=side.."_Arm_"
        for _,spec in ipairs({{"01","02","UpperArm",true},{"02","03","Hand",false}}) do
            local base,helper,child=prefix..spec[1],prefix..spec[1].."_T",prefix..spec[2]
            local j=J[helper]
            if j and J[base] and J[child] then
                local ok,p=pcall(j.call,j,"get_Parent")
                local good,name=false,nil
                if ok and p then good,name=pcall(p.call,p,"get_Name") end
                local offset=jget3(J[child],"get_LocalPosition")
                if good and name==base and offset and
                    offset[1]^2+offset[2]^2+offset[3]^2>1e-8 then
                    SKIN_HELPERS[#SKIN_HELPERS+1]={joint=helper,source=side.."_"..spec[3],
                        axis=vnorm(offset),counter=spec[4]}
                end
            end
        end
    end
    ARM_CHAINS = {}
    for _,side in ipairs({"L","R"}) do
        local p=side.."_Arm_"
        local upper,fore,hand,skin,elbow=p.."01",p.."02",p.."03",p.."01_T",p.."01_W"
        local valid=J[upper] and J[fore] and J[hand] and J[skin] and J[elbow]
        for _,pair in ipairs({{fore,upper},{hand,fore},{skin,upper},{elbow,upper}}) do
            if valid then
                local ok,parent=pcall(J[pair[1]].call,J[pair[1]],"get_Parent")
                local good,name=false,nil
                if ok and parent then good,name=pcall(parent.call,parent,"get_Name") end
                valid=good and name==pair[2]
            end
        end
        local a,b=jget3(J[fore],"get_LocalPosition"),jget3(J[hand],"get_LocalPosition")
        if valid and a and b and a[1]^2+a[2]^2+a[3]^2>1e-8 and b[1]^2+b[2]^2+b[3]^2>1e-8 then
            a,b=vnorm(a),vnorm(b)
            if math.abs(a[1]*b[1]+a[2]*b[2]+a[3]*b[3])>0.9999 then
                ARM_CHAINS[#ARM_CHAINS+1]={upper=upper,fore=fore,skin=skin,elbow=elbow,
                    source_upper=side.."_UpperArm",source_fore=side.."_Forearm",axis=a}
            end
        end
    end
    logmsg("手臂扭转辅助骨: "..#SKIN_HELPERS.." 根（核对父链与骨轴）")

    logmsg("待清零名单(" .. #RESET_LIST .. "): " .. table.concat(RESET_LIST, " "))

    -- ★ 脚 IK 列表（vmd-smith 实测：引擎站立/行走是「脚 IK 驱动」，我们只写 FK ⟹
    --   求解器把脚拉回地面目标，髋一抬腿就被拉成"向后踢"，而手臂无地面约束所以正常）
    IK_LIST = {}
    for _, nm in ipairs(JORDER) do
        if string.find(nm, "_IK", 1, true) ~= nil then IK_LIST[#IK_LIST + 1] = nm end
    end
    logmsg("脚IK关节(" .. #IK_LIST .. "): " .. table.concat(IK_LIST, " "))
    if nskip > 0 then
        logmsg("已跳过(" .. nskip .. "): " .. table.concat(RESET_SKIP, " "))
    end
    -- ★ 猎人手指骨骼层级树诊断
    local ftree = {}
    for _, nm in ipairs(JORDER) do
        if string.find(nm, "Finger", 1, true) ~= nil then
            local j = J[nm]
            local okp, par = pcall(j.call, j, "get_Parent")
            local pn = (okp and par ~= nil) and par:call("get_Name") or "nil"
            ftree[#ftree + 1] = nm .. "->" .. tostring(pn)
        end
    end
    if #ftree > 0 then
        logmsg(string.format("[FINGER-JOINTS] 猎人手指骨骼(%d): %s", #ftree, table.concat(ftree, ", ")))
    end
    return READY
end

-- ================================================================ 姿态：C14
local function reset_others_now()
    if not S.reset_others then return end
    for _, nm in ipairs(RESET_LIST) do
        local j = J[nm]
        if j ~= nil then
            pcall(j.call, j, "set_LocalRotation", Vector4f.new(0.0, 0.0, 0.0, 1.0))
        end
    end
end

local function write_joint(bone, q)
    local jn = MAP[bone]
    local j = jn and J[jn]
    if j == nil then return false end
    local u = qnorm(q)
    return pcall(j.call, j, "set_LocalRotation", Vector4f.new(u[1], u[2], u[3], u[4]))
end

local function write_raw_joint(jn, q)
    local j = jn and J[jn]
    if j == nil then return false end
    local u = qnorm(q)
    return pcall(j.call, j, "set_LocalRotation", Vector4f.new(u[1], u[2], u[3], u[4]))
end

local function apply_pose_c14(fi)
    local f = anim.frames[fi]
    if f == nil then return 0, 0, "noframe" end

    -- 重复同一帧（暂停 / 定格）：直接重写上次算好的值，不重新锚定
    if CF.inited and CF.last_fi == fi then
        local written, missing = 0, 0
        for _, bone in ipairs(anim.order) do
            local q = CF.Qt[bone]
            if q == nil then
                missing = missing + 1
            elseif write_joint(bone, q) then
                written = written + 1
            else
                missing = missing + 1
            end
        end
        reset_others_now()
        return written, missing, "reuse"
    end

    -- 帧号不连续（回绕/拖帧/切舞）→ 重新锚定
    local anchor = (not CF.inited) or (CF.last_fi == nil) or (fi ~= CF.last_fi + 1)
    if anchor then
        CF.w0, CF.wtp_ref, CF.Wt_ref, CF.Rfix, CF.Wt, CF.Qt = {}, {}, {}, {}, {}, {}
        CF.prevw_raw, CF.src_step = {}, {}
        CF.anchor_fi = fi
        CF.reanchors = CF.reanchors + 1
    end

    local Wt_root = qnorm(jget(J["Cog"], "get_Rotation")) or IDENT
    local Wt, Qt_new = {}, {}
    local written, missing = 0, 0

    for _, bone in ipairs(anim.order) do
        local pb = anim.parent and anim.parent[bone]
        local wtp = (pb and Wt[pb]) or Wt_root
        local e = f[bone]
        if e == nil or e.w == nil then
            Wt[bone] = wtp                    -- 该帧无此骨：保持父级朝向、不写
            missing = missing + 1
        else
            local raw = qnorm(e.w)          -- 归一化：源数据 w 的模长有 ~1e-5 误差
            local ax = TLOCAL[bone] or AXISFB[bone] or SRCAX
            -- 源步长统计（用未限幅的原始值，便于判断"抖动来自数据还是公式"）
            local pw = CF.prevw_raw[bone]
            if pw ~= nil then
                local dg = qdiff(pw, raw)
                if dg ~= nil then
                    CF.src_n = CF.src_n + 1
                    if dg > CF.src_max then CF.src_max = dg end
                    if dg > 30 then CF.src_over30 = CF.src_over30 + 1 end
                end
            end
            CF.prevw_raw[bone] = { raw[1], raw[2], raw[3], raw[4] }
            local w = raw
            if anchor then
                CF.src_step[bone] = { raw[1], raw[2], raw[3], raw[4] }
            elseif S.limit_on and S.limit_deg > 0.0 then
                w = limit_step(CF.src_step[bone], raw, S.limit_deg)
                CF.src_step[bone] = { w[1], w[2], w[3], w[4] }
            else
                CF.src_step[bone] = { raw[1], raw[2], raw[3], raw[4] }
            end

            local Qt = nil
            if anchor then
                -- 锚定帧：记录参考量 + 固定绑定 R_b；本帧写 identity
                CF.w0[bone] = { raw[1], raw[2], raw[3], raw[4] }
                CF.wtp_ref[bone] = { wtp[1], wtp[2], wtp[3], wtp[4] }
                CF.Wt_ref[bone] = { wtp[1], wtp[2], wtp[3], wtp[4] }
                local R = qbetween(qrot(CF.w0[bone], SRCAX), qrot(wtp, ax))
                if S.rollflip[bone] then R = qmul(axis_angle(ax, math.pi), R) end
                CF.Rfix[bone] = R
                Qt = { 0.0, 0.0, 0.0, 1.0 }
                -- 自检：走一圈公式（D 用 raw 与 w0 相消）应回到 identity
                local Dd = qmul(raw, qinv(CF.w0[bone]))
                local Wd = qmul(qmul(qmul(R, Dd), qinv(R)), CF.Wt_ref[bone])
                local dv = qdiff(qmul(qinv(wtp), Wd), IDENT)
                if dv ~= nil and dv > CF.anchor_check then CF.anchor_check = dv end
            else
                local w0b = CF.w0[bone]
                local R = CF.Rfix[bone]
                local wr = CF.Wt_ref[bone]
                if w0b == nil or R == nil or wr == nil then
                    -- 该骨中途才出现：单独补一次锚定
                    CF.w0[bone] = { raw[1], raw[2], raw[3], raw[4] }
                    CF.wtp_ref[bone] = { wtp[1], wtp[2], wtp[3], wtp[4] }
                    CF.Wt_ref[bone] = { wtp[1], wtp[2], wtp[3], wtp[4] }
                    local R2 = qbetween(qrot(CF.w0[bone], SRCAX), qrot(wtp, ax))
                    if S.rollflip[bone] then R2 = qmul(axis_angle(ax, math.pi), R2) end
                    CF.Rfix[bone] = R2
                    Qt = { 0.0, 0.0, 0.0, 1.0 }
                else
                    local D = qmul(w, qinv(w0b))                       -- 源世界增量
                    local Wt_des = qmul(qmul(qmul(R, D), qinv(R)), wr)
                    Qt = qmul(qinv(wtp), Wt_des)
                end
            end

            Qt_new[bone] = { Qt[1], Qt[2], Qt[3], Qt[4] }
            if write_joint(bone, Qt) then written = written + 1 else missing = missing + 1 end
            Wt[bone] = qmul(wtp, Qt)
        end
    end

    CF.Wt = Wt
    CF.Qt = Qt_new
    CF.inited = true
    CF.last_fi = fi
    reset_others_now()
    return written, missing, anchor and "anchor" or "step"
end

-- ================================================================ 姿态：旧模式（M25 家族 / 绝对朝向映射）
local function apply_pose_legacy(fi)
    local f = anim.frames[fi]
    if f == nil then return 0, 0 end
    if ST.prev_fi == nil or fi < ST.prev_fi or fi > ST.prev_fi + 1 then
        reset_twist()
    end
    ST.prev_fi = fi

    local Wt_root = jget(J["Cog"], "get_Rotation") or IDENT
    local Wt = {}
    local written, missing = 0, 0
    for _, bone in ipairs(anim.order) do
        local e = f[bone]
        if e and e.w then
            local pb = anim.parent and anim.parent[bone]
            local wtp = (pb and Wt[pb]) or Wt_root
            local Qt = IDENT
            local hasT = TLOCAL[bone] ~= nil
            local tl = hasT and TLOCAL[bone] or AXISFB[bone]

            -- twist：以锚点为基准 + 逐帧增量累加（避开绝对投影的 180° 病态）
            local acc = 0.0
            local pw = ST.prev_w[bone]
            if pw == nil then
                local refw = ANCHORW[bone] or e.w
                acc = signed_angle_about(qmul(qinv(refw), e.w), qrot(e.w, SRCAX))
            else
                local inc = signed_angle_about(qmul(qinv(pw), e.w), qrot(e.w, SRCAX))
                local ad = math.abs(inc) * DEG
                ST.sum_n = ST.sum_n + 1
                if ad > ST.max_inc then ST.max_inc = ad end
                if ad > 15 then ST.max_n = ST.max_n + 1 end
                acc = (ST.twist[bone] or 0.0) + inc
            end
            ST.prev_w[bone] = { e.w[1], e.w[2], e.w[3], e.w[4] }
            ST.twist[bone] = acc

            if S.mode == "abs" then
                if hasT and RESTW[bone] then
                    local A = qbetween(qrot(RESTW[bone], SRCAX), qrot(Wt_root, tl))
                    local d_map = qrot(A, qrot(e.w, SRCAX))
                    local d_loc = qrot(qinv(wtp), d_map)
                    local sw = qbetween(tl, d_loc)
                    local roll = signed_angle_about(qmul(qinv(RESTW[bone]), e.w), qrot(e.w, SRCAX))
                    Qt = S.use_twist and qmul(sw, axis_angle(tl, roll)) or sw
                else
                    local rw = RESTW[bone] or ANCHORW[bone] or e.w
                    Qt = qmul(qinv(wtp), qmul(qinv(rw), e.w))
                end
            else
                local dref = DREFW[bone]
                if dref then
                    local dnow = qrot(e.w, SRCAX)
                    local dw = qbetween(dref, dnow)
                    local dl = qmul(qmul(qinv(wtp), dw), wtp)
                    local base = hasT and qbetween(tl, qrot(dl, tl)) or dl
                    Qt = S.use_twist and qmul(base, axis_angle(tl, acc)) or base
                end
            end
            if write_joint(bone, Qt) then written = written + 1 else missing = missing + 1 end
            Wt[bone] = qmul(wtp, Qt)
        else
            missing = missing + 1
        end
    end
    reset_others_now()
    return written, missing
end

-- ================================================================ 姿态：DLL 原版公式（全局单框架）
-- 来源：从本机 MMD Implementer.dll 还原的原作者实现
--       （_work/reports/mapping/scripts/dll_lua_full.txt:1468-1537）
--   target = G ⊗ (wrot ⊗ conj(bindMap)) ⊗ conj(G)   -- 全骨架同一个 G，与关节无关（原注释 v41）
--   dG     = conj(Wg_par) ⊗ target                  -- 局部旋转
-- 为何正确：Qt = G ⊗ (conj(D父) ⊗ D子) ⊗ conj(G) 是【共轭】，天然保角
--           ⟹ 肘/膝的关节角与源一致（C14 的逐骨 R_b 会把关节角拧反 = "人体做不到的动作"）
-- 根骨骼的 Wg_par 取 identity（模型空间），不乘 Cog 的世界旋转。
local G_X180 = { 1.0, 0.0, 0.0, 0.0 }   -- 180° 绕 X（= 手性镜像算子 conj(R_x180)）

-- ★ 绝对根修正的诊断容器（只读测量，不影响姿态）
local DIAG = {
    rootbone = nil, rootjoint = nil, cog_name = nil,
    cog_yaw = nil, cog_yaw_min = nil, cog_yaw_max = nil, cog_n = 0,
    cog_world = nil, cog_local = nil,
    rootqt_yaw = nil, write_eff = nil,
    last_cog = nil, last_qt = nil, par_chain = "",
}
local ROOTJ = nil          -- 根骨对应的 via.Joint 对象（= Waist_00）
local ROOT_PARENT_W = nil  -- 本帧根骨真实父级（Cog）的世界旋转
local LAST_ROOT_QT = nil   -- 本帧写给根骨的局部旋转

-- ★★ 写入时机（write time）候选 + 「同帧回读」判据
--   ⚠️ 重要更正：旧 write_eff 是在【下一帧开头】读的，而引擎每帧都会在 UpdateMotion
--      重写所有关节的局部旋转 ⟹ 那个数【必然】偏大，它只说明"引擎下一帧会覆盖"，
--      **不能**说明"我们的值没送达本帧的渲染"。已改名 next_frame_eff 保留作对照。
--   ✅ 真判据 = same_frame_eff：在【写入之后的同一帧内】回读根骨世界旋转，
--      与 (Cog世界 ⊗ 我们写的根Qt) 比夹角；≈0 才说明我们的值被引擎用于本帧世界矩阵。
local WTIME = {
    { tag = "lockpre",  entry = "LockScene",      hook = "pre",  label = "LockScene.pre(现状)" },
    { tag = "lockpost", entry = "LockScene",      hook = "post", label = "LockScene.post" },
    { tag = "waitpre",  entry = "WaitRendering",  hook = "pre",  label = "WaitRendering.pre" },
    { tag = "beginpre", entry = "BeginRendering", hook = "pre",  label = "BeginRendering.pre" },
    { tag = "endrend",  entry = "EndRendering",   hook = "post", label = "EndRendering.post" },
    { tag = "prguipre", entry = "PrerenderGUI",   hook = "pre",  label = "PrerenderGUI.pre" },
    { tag = "unlockpre", entry = "UnlockScene",   hook = "pre",  label = "UnlockScene.pre" },
}
local WT = { tag = "lockpre", wrote = false, writes = 0, cur = { id = 0, samples = {} } }
local ROOT_AUDIT = nil     -- "根/Cog 是否被 reset_others / ik_off 触碰" 的一次性自查结果
-- 绕 Y 的偏航角（度）：取该四元数把 +Z 转到哪，避开 2*atan 的纯Y假设
local function yaw_of(q)
    if q == nil then return nil end
    local f = qrot(q, { 0.0, 0.0, 1.0 })
    if f == nil then return nil end
    return math.atan(f[1], f[3]) * DEG
end
-- 两个四元数的夹角（度）
local function qang(a, b)
    if a == nil or b == nil then return nil end
    local d = math.abs(a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4])
    if d > 1 then d = 1 end
    return 2.0 * math.acos(d) * DEG
end
-- 沿 get_Parent() 向上把各级 get_Rotation()（REF 约定：世界）串起来，作为兜底
local function compose_parent_chain(j, maxup)
    local out, cur, guard = {}, j, 0
    while cur ~= nil and guard < (maxup or 8) do
        local okp, par = pcall(cur.call, cur, "get_Parent")
        if not okp or par == nil then break end
        local w = jget(par, "get_Rotation")
        local nm = nil
        local okn, n = pcall(par.call, par, "get_Name")
        if okn then nm = n end
        out[#out + 1] = tostring(nm)
        cur = par
        guard = guard + 1
    end
    return out
end

-- ★★ 渲染后 delta 探针：直接测「引擎实际生效的世界朝向」 vs 「我们写入的 target」
--   delta_k  = actual_world_k ⊗ conj(target_k)   （即 actual = delta ⊗ target，左乘型后置变换）
--   delta2_k = conj(target_k) ⊗ actual_world_k   （即 actual = target ⊗ delta2，右乘型）
--   若四根骨的 delta 相同 ⟹ 引擎叠加了一个【全局后置旋转】⟹ 用 conj(delta) 左乘 target 即可补偿。
local PROBE_JOINTS = { "Waist_00", "Head_00", "L_Arm_01", "L_Leg_00" }
local LATE_ENTRY = { ["WaitRendering.pre"] = true, ["BeginRendering.pre"] = true,
                     ["EndRendering.post"] = true, ["UnlockScene.pre"] = true }
local COMP = {
    enabled = false,          -- 面板开关（默认关：先看测量结果，避免引入未验证的变化）
    delta = nil, delta_angle = nil, delta_axis = nil, spread = nil, stable = false,
    last_target = {}, probe = {}, joint2src = {}, rows = {}, at = nil, n = 0,
}
local DANCEDIR = {
    render_waist = nil, src_hip = nil, diff = nil, cog_yaw = nil, move_yaw = nil,
}
local function qang_axis(q)
    if q == nil then return nil, nil end
    local vx, vy, vz, w = q[1], q[2], q[3], q[4]
    local n = math.sqrt(vx*vx + vy*vy + vz*vz)
    if n < 1e-9 then return 0.0, { 0.0, 0.0, 0.0 } end
    return 2.0 * math.atan(n, w) * DEG, { vx/n, vy/n, vz/n }
end
local function qstr4(q)
    if q == nil then return "nil" end
    return string.format("(%.4f,%.4f,%.4f,%.4f)", q[1], q[2], q[3], q[4])
end
local function probe_init()
    if anim == nil or next(COMP.joint2src) ~= nil then return end
    for _, b in ipairs(anim.order) do
        local jn = MAP[b]
        if jn ~= nil then COMP.joint2src[jn] = b end
    end
    for _, jn in ipairs(PROBE_JOINTS) do
        local b = COMP.joint2src[jn]
        if b ~= nil then COMP.probe[b] = true end
    end
end
local function measure_render_delta(entry_label)
    if LATE_ENTRY[entry_label] ~= true then return end
    probe_init()
    if anim == nil then return end
    local rows, ds = {}, {}
    for _, jn in ipairs(PROBE_JOINTS) do
        local src = COMP.joint2src[jn]
        local tgt = src and COMP.last_target[src] or nil
        local j = J[jn]
        if src ~= nil and tgt ~= nil and j ~= nil then
            local act = jget(j, "get_Rotation")
            if act ~= nil then
                local d = qmul(act, qinv(tgt))          -- actual = d ⊗ target
                local d2 = qmul(qinv(tgt), act)         -- actual = target ⊗ d2
                local ang, ax = qang_axis(d)
                rows[#rows + 1] = { joint = jn, src = src, angle = ang, axis = ax, d = d, d2 = d2,
                                    yaw_act = yaw_of(act), yaw_tgt = yaw_of(tgt) }
                ds[#ds + 1] = d
            end
        end
    end
    if #rows == 0 then return end
    local spread = nil
    if #ds >= 2 then
        local worst = 0.0
        for i = 2, #ds do
            local a = qang(ds[1], ds[i])
            if a ~= nil and a > worst then worst = a end
        end
        spread = worst
    end
    COMP.rows, COMP.at = rows, entry_label
    COMP.n = COMP.n + 1
    COMP.spread = spread
    COMP.delta = ds[1]
    COMP.delta_angle, COMP.delta_axis = qang_axis(ds[1])
    if spread ~= nil and spread < 1.0 then COMP.stable = true end

    -- ★★ 舞蹈朝向与位移诊断探针 DANCEDIR
    local act_w = J["Waist_00"] and jget(J["Waist_00"], "get_Rotation")
    local yw = yaw_of(act_w)
    local fi = (math.floor(S.t) % (anim and anim.count or 1)) + 1
    local f_cur = anim and anim.frames and anim.frames[fi]
    local f1 = anim and anim.frames and anim.frames[1]
    local src_h = f_cur and f_cur["Hip"] and f_cur["Hip"].w
    local yh = yaw_of(src_h)
    local diff = nil
    if yw ~= nil and yh ~= nil then
        diff = yw - yh
        while diff > 180.0 do diff = diff - 360.0 end
        while diff < -180.0 do diff = diff + 360.0 end
    end
    local act_c = J["Cog"] and jget(J["Cog"], "get_Rotation")
    local yc = yaw_of(act_c)
    local ym = nil
    if f_cur ~= nil and f_cur.pos ~= nil and f1 ~= nil and f1.pos ~= nil then
        local dx = f_cur.pos[1] - f1.pos[1]
        local dz = f_cur.pos[3] - f1.pos[3]
        if dx*dx + dz*dz > 1e-4 then
            ym = math.atan(dx, dz) * DEG
        end
    end
    DANCEDIR.render_waist = yw
    DANCEDIR.src_hip = yh
    DANCEDIR.diff = diff
    DANCEDIR.cog_yaw = yc
    DANCEDIR.move_yaw = ym
end

-- Clear every cache that contains joints or a coordinate anchor. READY alone
-- is insufficient: ROOTJ used to keep the pre-change preview's Waist_00 forever.
function BINDING.invalidate(reason,preserve_stage)
    local was_ready=READY
    READY=false
    J,JORDER,RESET_LIST,RESET_SKIP,HELPER_LIST,IK_LIST={},{},{},{},{},{}
    SKIN_HELPERS,ARM_CHAINS={},{}
    MASTER_XF=nil;ROOTJ=nil;ROOT_PARENT_W=nil;ROOT_AUDIT=nil
    DIAG.rootbone=nil;DIAG.rootjoint=nil;DIAG.cog_name=nil;DIAG.par_chain=nil
    DIAG.last_cog=nil;DIAG.last_qt=nil;DIAG.cog_yaw_min=nil;DIAG.cog_yaw_max=nil;DIAG.cog_n=0
    COMP.last_target={};COMP.delta=nil;COMP.rows={};COMP.stable=false
    WT.wrote=false;WT.cur={id=0,samples={}}
    reset_twist();reset_c14()
    if not preserve_stage then
        POS_ZERO=nil;WORLD_ZERO=nil;WORLD_YAW_ZERO=0;LAST_WORLD_POS=nil;LAST_WORLD_TIME=nil
        CAMERA.release_mmd()
    end
    BINDING.current=nil;BINDING.attempt=nil;BINDING.status=reason or "等待主角重新绑定"
    if was_ready then AUDIO.revision=AUDIO.revision+1;logmsg(BINDING.status) end
end
function BINDING.update(force)
    -- Unicode resources may still be awaiting their native path index. Binding
    -- an empty animation would put every main joint in RESET_LIST, which then
    -- clears the real pose even after the motion loads on the same skeleton.
    if anim==nil then return false end
    local go,owner,index=get_master_go()
    local xf
    if go then
        local ok,value=pcall(go.call,go,"get_Transform")
        if ok then xf=value end
    end
    if not go or not xf then
        if READY then BINDING.invalidate("主角暂不可用，已停止旧骨架写入") end
        BINDING.next_check=0
        return false
    end
    if READY then
        local root=J.Waist_00
        local ok,parent=false,nil
        if root then ok,parent=pcall(root.call,root,"get_Parent") end
        if not ok or parent~=J.Cog then force=true end
    end
    local now=os.clock()
    local old=BINDING.current
    local attempt=BINDING.attempt
    local same_attempt=attempt and attempt.go==go and attempt.owner==owner and attempt.index==index and attempt.xf==xf
    local same_owner=old and old.go==go and old.owner==owner and old.index==index and old.xf==xf
    if not force and same_attempt and now<BINDING.next_check then return READY end
    BINDING.attempt={go=go,owner=owner,index=index,xf=xf}
    BINDING.next_check=now+0.25
    local candidate,reason=BINDING.snapshot(go,owner,index,xf)
    if not candidate then
        if READY then BINDING.invalidate(reason) else BINDING.status=reason end
        return false
    end
    local same_joints=READY and same_owner and BINDING.same_joints(candidate)
    if same_joints and old.parts==candidate.parts then return true end
    -- Replacing this hunter's skeleton must not add the current dance's world
    -- displacement a second time. Keep its stage, but recapture the new Cog's
    -- local offset. A different hunter/Transform gets a fresh stage as well.
    BINDING.invalidate("主角或外观骨架变化，正在重新绑定",same_owner)
    if not same_joints then POS_ZERO=nil end
    if not refresh(candidate,same_owner) then return false end
    BINDING.current=candidate;BINDING.generation=BINDING.generation+1
    BINDING.status=string.format("本地主角 #%d · 骨骼 %d · 绑定 %d",index,#JORDER,BINDING.generation)
    AUDIO.revision=AUDIO.revision+1
    logmsg(BINDING.status)
    return true
end

local function apply_pose_dll_prep()
    -- 每帧一次：查根骨/其真实父级（Cog），取父级世界旋转并记录诊断
    if DIAG.rootbone == nil and anim ~= nil and J ~= nil then
        for _, b in ipairs(anim.order) do
            if (anim.parent == nil) or (anim.parent[b] == nil) then
                DIAG.rootbone = b
                DIAG.rootjoint = MAP[b]
                ROOTJ = J[MAP[b]]
                break
            end
        end
        if ROOTJ ~= nil then
            local okp, par = pcall(ROOTJ.call, ROOTJ, "get_Parent")
            if okp and par ~= nil then
                local okn, n = pcall(par.call, par, "get_Name")
                if okn then DIAG.cog_name = n end
                DIAG.par_chain = table.concat(compose_parent_chain(ROOTJ, 6), " -> ")
            end
        end
        logmsg(string.format("[ABSROOT] 根骨=%s -> 关节=%s ; 真实父级=%s ; 向上链=%s",
            tostring(DIAG.rootbone), tostring(DIAG.rootjoint),
            tostring(DIAG.cog_name), tostring(DIAG.par_chain)))
    end
    -- ★ 根骨真实父级（Cog）的【世界】旋转：每帧取一次 + 记录"是否恒定/幅度多大"
    ROOT_PARENT_W = nil
    if S.absroot and ROOTJ ~= nil then
        local okp, par = pcall(ROOTJ.call, ROOTJ, "get_Parent")
        if okp and par ~= nil then
            ROOT_PARENT_W = jget(par, "get_Rotation")          -- REF 约定：get_Rotation = 世界
            DIAG.cog_world = ROOT_PARENT_W
            DIAG.cog_local = jget(par, "get_LocalRotation")
            local y = yaw_of(ROOT_PARENT_W)
            if y ~= nil then
                DIAG.cog_yaw = y
                if DIAG.cog_yaw_min == nil or y < DIAG.cog_yaw_min then DIAG.cog_yaw_min = y end
                if DIAG.cog_yaw_max == nil or y > DIAG.cog_yaw_max then DIAG.cog_yaw_max = y end
                DIAG.cog_n = DIAG.cog_n + 1
            end
        end
    end
    -- 上一帧"我们写的根 Qt + 当时的 Cog 世界" vs 本帧开局引擎给出的根世界 → 引擎是否保留
    if DIAG.last_cog ~= nil and DIAG.last_qt ~= nil and ROOTJ ~= nil then
        local cur = jget(ROOTJ, "get_Rotation")
        if cur ~= nil then DIAG.write_eff = qang(qmul(DIAG.last_cog, DIAG.last_qt), cur) end
    end
end

local function apply_pose_dll(fi)
    local f = sampled_body(fi)
    if f == nil then return 0, 0, "noframe" end
    local G = S.g_x180 and G_X180 or IDENT
    local Gc = qinv(G)
    apply_pose_dll_prep()      -- ★ 绝对根修正：每帧取根骨真实父级（Cog）的世界旋转 + 诊断
    -- ★ 根骨骼全局零位修正（修 "你的笑容" 整个人反转 180° 的问题）
    -- DLL 公式里根骨的局部旋转 = 绝对朝向 G·(w(Hip)·conj(bind))·conj(G)。
    -- BAAM 与 smile 来自不同 MMD 模型，髋部绝对朝向相差 175.25°（实测：-1.68° vs -177.31°）
    -- → 整个角色转到背面。这里用「该舞 ref 帧的根目标朝向」当零位左乘修正：
    --   数学上只改根骨，子骨的局部旋转完全不变（conj(T'(p))⊗T'(c) 中 Q0 抵消），
    --   所以 BAAM 只会被修正 ~1.7°，安全。
    local Q0 = IDENT
    if S.root_zero then
        -- ⚠️ 必须用【第 0 帧】而不是 anim.ref：smile 的 D(Hip@0)=177.27° vs D(Hip@ref)=5.83°
        --    （vmd-smith 实测；用 ref 会让 Q0≈单位阵，修正完全失效）
        local rf = anim.frames[1]
        local hb = BIND["Hip"]
        if rf ~= nil and hb ~= nil and rf["Hip"] ~= nil and rf["Hip"].w ~= nil then
            Q0 = qinv(qmul(qmul(G, qmul(rf["Hip"].w, qinv(hb))), Gc))
        end
    end
    local Wt = {}
    local qmap = {}          -- 关节名 -> 我们写入的局部旋转（供辅助骨联动）
    local written, missing = 0, 0
    for _, bone in ipairs(anim.order) do
        local e = f[bone]
        if e and e.w then
            local bindq = BIND[bone]
            local Qt = IDENT
            if bindq then
                local YAW = IDENT
                if S.yaw_deg ~= 0 then
                    local h = (S.yaw_deg * 0.5) * 0.017453292519943295
                    YAW = { 0.0, math.sin(h), 0.0, math.cos(h) }
                end
                -- ★ 只对【肢体】施加 180° 偏航（躯干不动）：
                --   实测"基线=模型对/舞蹈反；整体转身=舞蹈对/模型反" ⟹ 肢体相对躯干差了 180°
                if S.yaw_limb180 then
                    local bn = bone or ""
                    if string.find(bn, "Shoulder", 1, true) or string.find(bn, "Arm", 1, true)
                       or string.find(bn, "Hand", 1, true) or string.find(bn, "Forearm", 1, true)
                       or string.find(bn, "Thigh", 1, true) or string.find(bn, "Shin", 1, true)
                       or string.find(bn, "Foot", 1, true) or string.find(bn, "Toe", 1, true) then
                        YAW = qmul(YAW, Y180)
                    end
                end
                local target = qmul(YAW, qmul(Q0, qmul(qmul(G, qmul(e.w, qinv(bindq))), Gc)))
                -- ★ 消除脚部垂直朝天（历史数据开关）
                if S.fix_foot and (string.find(bone, "Foot", 1, true) or string.find(bone, "Toe", 1, true)) then
                    target = qmul(target, { -0.8804, 0.0, 0.0, 0.4742 })
                end
                -- ★ 消除端肩/手臂外翻/脊柱颈部歪斜
                if S.fix_arm then
                    if bone == "L_Shoulder" then
                        target = qmul(target, { -0.0038, 0.1469, -0.0435, 0.9882 })
                    elseif bone == "R_Shoulder" then
                        target = qmul(target, { -0.0038, -0.1469, 0.0435, 0.9882 })
                    elseif bone == "spine_1" then
                        target = qmul(target, { -0.1186, 0.0, 0.0, 0.9929 })
                    elseif bone == "Neck_0" or bone == "Head" then
                        target = qmul(target, { 0.1331, 0.0, 0.0, 0.9911 })
                    end
                end
                -- ★ 人体工程微调（对纯净数据与历史数据均生效）
                if S.foot_pitch ~= 0 and (string.find(bone, "Foot", 1, true) or string.find(bone, "Toe", 1, true)) then
                    local r = S.foot_pitch * 0.5 * 0.017453292519943295
                    target = qmul(target, { math.sin(r), 0.0, 0.0, math.cos(r) })
                end
                if S.shoulder_pitch ~= 0 and string.find(bone, "Shoulder", 1, true) then
                    local sgn = string.find(bone, "L_", 1, true) and 1.0 or -1.0
                    local r = S.shoulder_pitch * sgn * 0.5 * 0.017453292519943295
                    target = qmul(target, { 0.0, 0.0, math.sin(r), math.cos(r) })
                end
                if S.arm_width ~= 0 and string.find(bone, "UpperArm", 1, true) then
                    local sgn = string.find(bone, "L_", 1, true) and 1.0 or -1.0
                    local r = S.arm_width * sgn * 0.5 * 0.017453292519943295
                    target = qmul(target, { 0.0, 0.0, math.sin(r), math.cos(r) })
                end
                if S.elbow_pitch ~= 0 and string.find(bone, "Forearm", 1, true) then
                    local r = S.elbow_pitch * 0.5 * 0.017453292519943295
                    target = qmul(target, { math.sin(r), 0.0, 0.0, math.cos(r) })
                end
                -- ★★ 全局/逐骨「前后反射 Mz」：将 MMD 的 -Z 前方镜像为崛起的 +Z 前方
                --   严格四元数数学：M·R·M ⟹ 对 Z 反射取 q=(x,y,z,w) → (-x,-y,z,w)
                --   （彻底解决 MMD 前方为 -Z 而崛起前方为 +Z 导致的手脚肢体动作在背后做的问题）
                local fa = S.flip_axis and S.flip_axis[bone]
                if S.reflect_z or fa == "z" then
                    target = { -target[1], -target[2], target[3], target[4] }   -- 前后反射 Mz (Z取反)
                elseif fa == "x" then
                    target = { target[1], -target[2], -target[3], target[4] }   -- 左右反射 Mx (X取反)
                elseif fa == "y" then
                    target = { -target[1], target[2], -target[3], target[4] }   -- 上下反射 My (Y取反)
                end
                if S.reflect_x then
                    target = { target[1], -target[2], -target[3], target[4] }   -- 全局左右镜像 Mx (翻转镜头转向左右)
                end
                -- ★★ 弯曲方向翻转（auditor 方案）：【右乘】axis_angle(源轴, π)
                --   左乘只转 roll 零点（方向不变，无效）；右乘才能把"往哪边弯"翻一面，且不改手性
                if S.bendflip and S.bendflip[bone] then
                    target = qmul(target, axis_angle(SRCAX, math.pi))
                end
                -- ★ 渲染后 delta 补偿（面板开关，默认关）：若实测 actual = delta ⊗ target，
                --   则左乘 conj(delta) 后 actual = delta ⊗ conj(delta) ⊗ target = target ✓
                if COMP.enabled and COMP.delta ~= nil then
                    target = qmul(qinv(COMP.delta), target)
                end
                local pb = anim.parent and anim.parent[bone]
                local is_root = (pb == nil)
                local wpar = pb and Wt[pb] or nil
                if wpar == nil then
                    -- ★ 绝对根修正：根骨（pb=nil）用【真实父级 Cog 的世界旋转】；
                    --   关掉 S.absroot 时退回 DLL 原版行为（IDENT = 模型空间）。
                    is_root = true
                    wpar = (S.absroot and ROOT_PARENT_W) or IDENT
                end
                -- ★ 方案A：手臂纯净局部通道（跳过父子世界除法，直接采用纯净局部旋转直通）
                local is_arm = S.arm_pure_local and (string.find(bone, "Arm", 1, true) or string.find(bone, "Hand", 1, true)) and (e.r ~= nil)
                if is_arm then
                    local lq = { e.r[1], e.r[2], e.r[3], e.r[4] }
                    if S.arm_width ~= 0 and string.find(bone, "UpperArm", 1, true) then
                        local sgn = string.find(bone, "L_", 1, true) and 1.0 or -1.0
                        local r = S.arm_width * sgn * 0.5 * 0.017453292519943295
                        lq = qmul(lq, { 0.0, 0.0, math.sin(r), math.cos(r) })
                    end
                    if S.elbow_pitch ~= 0 and string.find(bone, "Forearm", 1, true) then
                        local r = S.elbow_pitch * 0.5 * 0.017453292519943295
                        lq = qmul(lq, { math.sin(r), 0.0, 0.0, math.cos(r) })
                    end
                    Qt = lq
                    Wt[bone] = qmul(wpar, Qt)
                    COMP.last_target[bone] = Wt[bone]
                else
                    Qt = qmul(qinv(wpar), target)
                    Wt[bone] = target
                    COMP.last_target[bone] = target     -- 供渲染后 delta 探针（全骨记录，便宜）
                end
                if is_root then
                    LAST_ROOT_QT = Qt
                    DIAG.rootqt_yaw = yaw_of(Qt)
                    DIAG.last_cog, DIAG.last_qt = ROOT_PARENT_W, LAST_ROOT_QT
                end
            else
                local pb = anim.parent and anim.parent[bone]
                Wt[bone] = (pb and Wt[pb]) or IDENT
            end
            if write_joint(bone, Qt) then
                written = written + 1
                local jn = MAP[bone]
                if jn ~= nil then qmap[jn] = Qt end
            else
                missing = missing + 1
            end
        end
    end
    -- Only rebalance a complete mapped neck/head chain; never rotate a missing
    -- head's parent alone. Auxiliary deformers remain under native control.
    local neck_name,head_name=MAP["Neck_0"],MAP["Head"]
    if neck_name and head_name and anim.parent and anim.parent.Head=="Neck_0" then
        local nq,hq,changed=rebalance_neck(qmap[neck_name],qmap[head_name])
        if changed then
            write_raw_joint(neck_name,nq)
            write_raw_joint(head_name,hq)
            local parent=anim.parent.Neck_0
            if parent and Wt[parent] then
                COMP.last_target.Neck_0=qmul(Wt[parent],nq)
            end
        end
    end
    -- Rebalance complete, verified arm chains before updating their skin helpers.
    local balanced={}
    for _,chain in ipairs(ARM_CHAINS) do
        if MAP[chain.source_upper]==chain.upper and MAP[chain.source_fore]==chain.fore and
            anim.parent and anim.parent[chain.source_fore]==chain.source_upper then
            local upper,fore=rebalance_arm(qmap[chain.upper],qmap[chain.fore],chain.axis)
            if upper then
                write_raw_joint(chain.upper,upper)
                write_raw_joint(chain.fore,fore)
                qmap[chain.upper],qmap[chain.fore]=upper,fore
                write_raw_joint(chain.skin,IDENT)
                balanced[chain.skin]=true
                write_raw_joint(chain.elbow,elbow_skin_rotation(fore,chain.axis))
            end
        end
    end
    -- Native deformers used the original game pose. Keep wrist helpers current;
    -- use the previous upper-arm fallback when a complete chain is unavailable.
    for _,helper in ipairs(SKIN_HELPERS) do
        if not balanced[helper.joint] then
            local source_name=MAP[helper.source]
            local rotation=skin_twist_rotation(source_name and qmap[source_name],helper.axis,helper.counter)
            if rotation then write_raw_joint(helper.joint,rotation) end
        end
    end
    if S.reset_others then reset_others_now() end
    -- ★ 动捕手指通道：写入全部 30 根手指关节的逐帧局部旋转（挥手/张开/握拳动捕）
    local fg_written = 0
    if S.use_fingers and anim.fingers ~= nil then
        local fg = SAMPLE.fingers
        if fg ~= nil then
            for jn, q in pairs(fg) do
                local j = J[jn]
                if j ~= nil then
                    local okw = pcall(j.call, j, "set_LocalRotation", Vector4f.new(q[1], q[2], q[3], q[4]))
                    if okw then fg_written = fg_written + 1 end
                end
            end
        end
    end
    written = written + fg_written
    return written, missing, "dll"
end

local function apply_pose(fi)
    if S.mode == "dll" then
        return apply_pose_dll(fi)
    end
    if S.mode == "c14" then
        return apply_pose_c14(fi)
    end
    local w, m = apply_pose_legacy(fi)
    return w, m, "legacy"
end
-- ================================================================ 原生动作位移探针
local REC_PROBE = {
    recording = false,
    samples = {},
    cur_bank = 0,
    cur_mot = 0,
    world_pos = { 0.0, 0.0, 0.0 },
    cog_pos = { 0.0, 0.0, 0.0 },
    status = "空闲"
}

local function probe_native_motion()
    local pm = sdk.get_managed_singleton("snow.player.PlayerManager")
    if pm == nil then return end
    local okm, master = pcall(pm.call, pm, "findMasterPlayer")
    if not okm or master == nil then return end
    local okg, go = pcall(master.call, master, "get_GameObject")
    if not okg or go == nil then return end
    local okx, xf = pcall(go.call, go, "get_Transform")
    local wp = nil
    if okx and xf ~= nil then
        local okp, p = pcall(xf.call, xf, "get_Position")
        if okp and p ~= nil then wp = p end
    end
    local cp = nil
    local cog = J and J["Cog"]
    if cog ~= nil then
        local okc, p = pcall(cog.call, cog, "get_LocalPosition")
        if okc and p ~= nil then cp = p end
    end
    
    local okmc, mot_ctrl = pcall(master.get_field, master, "_PlayerMotionControl")
    local bank = 0
    local mot = 0
    if okmc and mot_ctrl ~= nil then
        local okb, b = pcall(mot_ctrl.get_field, mot_ctrl, "_ReqMotionBankID")
        if okb and b then bank = b end
        local okid, id = pcall(mot_ctrl.get_field, mot_ctrl, "_ReqMotionID")
        if okid and id then mot = id end
    end
    
    if wp ~= nil then
        REC_PROBE.world_pos = { wp.x, wp.y, wp.z }
    end
    if cp ~= nil then
        REC_PROBE.cog_pos = { cp.x, cp.y, cp.z }
    end
    REC_PROBE.cur_bank = bank
    REC_PROBE.cur_mot = mot
    
    if REC_PROBE.recording and wp ~= nil and cp ~= nil then
        table.insert(REC_PROBE.samples, {
            t = os.clock(),
            bank = bank,
            mot = mot,
            world = { wp.x, wp.y, wp.z },
            cog = { cp.x, cp.y, cp.z }
        })
    end
end

-- ================================================================ 计时
-- ⚠️ P0/P1 修复：帧率测量与 S.t 推进都必须在 re.on_frame（真正的每帧回调）里做。
-- 旧实现在 on_lock_post 里 tick_time()、在 on_lock_pre 里推进 S.t：
--   LockScene 每帧可能触发多次（LAB 实测 lock_stat.max=2）→ 帧率被同倍高估 → 速度同倍偏慢
--   （prior-art 从实机日志实测：S.t 仅 13.52 帧/s，应 30 → 0.45×，一圈 3002 帧耗时 222s）
--   且帧率跌到 30 以下时步长 >1 → math.floor(S.t) 跳帧 → 触发 reinit 风暴（实测 18.6 次/圈）
local function tick_time()
    -- Windows CRT os.clock uses elapsed wall time (the game embeds Windows Lua).
    local clock = os.clock()
    TIME.dt = math.max(0, math.min(0.25, clock - TIME.clock))
    TIME.clock = clock
    TIME.frames = TIME.frames + 1
    local now = os.time()
    if now ~= TIME.last_sec then
        local dt = now - TIME.last_sec
        if dt < 1 then dt = 1 end
        local f = TIME.frames / dt
        -- P1 修复（api-hunter 审计）：旧门限 15<f<400 在 >400fps 时会把每个样本都拒掉
        -- → TIME.fps 冻在 60 → step 被 0.95 截断 → 舞速最多偏快 ~8×。放宽到 5~2000。
        if f > 5 and f < 2000 then
            if TIME.ticks == 0 then
                TIME.fps = f            -- 首个有效样本直接置位，消除从 60 出发的 ~4 秒瞬态
            else
                TIME.fps = TIME.fps * 0.4 + f * 0.6
            end
        end
        if TIME.fps < 5 then TIME.fps = 5 elseif TIME.fps > 2000 then TIME.fps = 2000 end
        TIME.last_sec = now
        TIME.frames = 0
        TIME.ticks = TIME.ticks + 1
    end
end

local function advance_time()
    if not S.enable or not READY or anim == nil then return end
    if S.rest_hold or not S.playing then return end
    local step = TIME.dt * (anim.fps or 30) * S.speed
    if S.mode == "c14" then
        -- C14 步长上限 0.95：保证 math.floor(S.t) 每次最多前进 1，永不跳帧（否则 C14 会重锚定）
        if step > 0.95 then step = 0.95 end
    end
    if step < 0 then step = 0 end
    TIME.step = step
    S.t = S.t + step
    local count = anim.count or #anim.frames
    if count > 0 and S.t >= count then
        if S.loop then S.t = S.t % count
        else S.t = count - 1; S.playing = false end
        AUDIO.revision = AUDIO.revision + 1
    end
end

-- ================================================================ entry
-- ★ 姿态写入（原 on_lock_pre 的函数体原样搬进来，供不同时机复用）
local function pose_write(physics_only)
    if not SESSION.enabled or not S.enable or anim==nil or not BINDING.update() then return end
    local count = anim.count or #anim.frames
    if count <= 0 then return end
    local fi
    if S.rest_hold then
        fi = 1
    else
        fi = (math.floor(S.t) % count) + 1
    end
    S.written, S.missing = apply_pose(fi)
    -- Motion.post has a temporary native root offset (observed -0.6 m) that
    -- the character controller restores before late behavior. Early physics
    -- feeds must not capture this as the stage origin or write positions/IK.
    -- Keep all translation anchoring and final IK at the render correction.
    if physics_only then return end
    -- 记录本次写入（供同帧回读）
    WT.writes = WT.writes + 1
    WT.cur = { id = WT.writes, fi = fi, samples = {}, entry = WT.tag }
    WT.wrote = true

    -- ★ 接管肢体 IK：将脚部与手部 IK 目标同步到真实踝/腕关节世界坐标，消除引擎原生 TwoBoneIK 将抬腿或摆臂压回初始位置的冲突
    if S.ik_off then
        if J["R_Foot_IK"] ~= nil and J["R_Leg_02"] ~= nil then
            local p = jget3(J["R_Leg_02"], "get_Position")
            if p ~= nil then
                pcall(J["R_Foot_IK"].call, J["R_Foot_IK"], "set_Position", Vector3f.new(p[1], p[2], p[3]))
            end
            write_raw_joint("R_Foot_IK", IDENT)
        end
        if J["L_Foot_IK"] ~= nil and J["L_Leg_02"] ~= nil then
            local p = jget3(J["L_Leg_02"], "get_Position")
            if p ~= nil then
                pcall(J["L_Foot_IK"].call, J["L_Foot_IK"], "set_Position", Vector3f.new(p[1], p[2], p[3]))
            end
            write_raw_joint("L_Foot_IK", IDENT)
        end
        if J["R_Hand_IK"] ~= nil and J["R_Arm_03"] ~= nil then
            local p = jget3(J["R_Arm_03"], "get_Position")
            if p ~= nil then
                pcall(J["R_Hand_IK"].call, J["R_Hand_IK"], "set_Position", Vector3f.new(p[1], p[2], p[3]))
            end
            write_raw_joint("R_Hand_IK", IDENT)
        end
        if J["L_Hand_IK"] ~= nil and J["L_Arm_03"] ~= nil then
            local p = jget3(J["L_Arm_03"], "get_Position")
            if p ~= nil then
                pcall(J["L_Hand_IK"].call, J["L_Hand_IK"], "set_Position", Vector3f.new(p[1], p[2], p[3]))
            end
            write_raw_joint("L_Hand_IK", IDENT)
        end
    end

    -- ★ 位移通道：双轨分流驱动（原生动作数据实证方案）+ 高刷子帧插值（消除阶梯抽搐）+ 抗频闪平滑滤波
    --   轨 1（垂直起伏 dy）：写 Cog.LocalPosition.y（原生录制证明 RE 引擎质心 LocalPosition 仅负责垂直起伏，Y 极差 0.636m）
    --   轨 2（水平走位 dx, dz）：写角色顶级 GameObject.Transform:Position（原生录制证明 20.85m 真实走位完全由 Transform 驱动）
    if S.pos_on and anim ~= nil and J["Cog"] ~= nil then
        local count = anim.count or #anim.frames
        if count > 0 then
            local t_mod = S.t % count
            local i0 = math.floor(t_mod) + 1
            local i1 = (i0 % count) + 1
            local alpha = t_mod - math.floor(t_mod)
            if i0 == count then alpha = 0.0 end

            local pf0 = anim.frames[i0]
            local pf1 = anim.frames[i1]
            local p1 = anim.frames[1]

            if pf0 ~= nil and pf0.pos ~= nil and p1 ~= nil and p1.pos ~= nil then
                local p0_pos = pf0.pos
                local p1_pos = (pf1 ~= nil and pf1.pos ~= nil) and pf1.pos or p0_pos

                -- ★ 高刷子帧线性插值 (Subframe Lerp)：彻底消解 30fps 动画在 144Hz 屏幕上的阶梯跳跃停顿
                local cur_px, cur_py, cur_pz
                if S.pos_subframe_lerp then
                    cur_px = p0_pos[1] + (p1_pos[1] - p0_pos[1]) * alpha
                    cur_py = p0_pos[2] + (p1_pos[2] - p0_pos[2]) * alpha
                    cur_pz = p0_pos[3] + (p1_pos[3] - p0_pos[3]) * alpha
                else
                    cur_px = p0_pos[1]
                    cur_py = p0_pos[2]
                    cur_pz = p0_pos[3]
                end

                if POS_ZERO == nil then
                    POS_ZERO = jget3(J["Cog"], "get_LocalPosition") or { 0.0, 0.0, 0.0 }
                end
                local c = S.pos_scale
                local mx, my, mz = 1.0, 1.0, 1.0
                if S.pos_mirror then my = -1.0; mz = -1.0 end
                if S.pos_z_flip then mz = -mz end               -- MMD -Z 前进 -> 崛起 +Z 前进
                local dx = (cur_px - p1.pos[1]) * c * mx
                -- Position schema 2 stores pelvis displacement from bind, including
                -- lower-body translation. Preserve initial crouch/jump height.
                -- Legacy clips retain their first-frame vertical anchor.
                local origin_y = p1.pos[2]
                if anim.pos_y_reference == "rest" then origin_y = anim.pos_y_rest or 0.0 end
                local dy = (cur_py - origin_y) * c * my
                local dz = (cur_pz - p1.pos[3]) * c * mz
                if S.reflect_x then dx = -dx end

                -- 轨 1: 垂直起伏（驱动 Cog 重心升降，水平锁定为静止位）
                local cog_y = POS_ZERO[2] + dy
                pcall(J["Cog"].call, J["Cog"], "set_LocalPosition", Vector3f.new(POS_ZERO[1], cog_y, POS_ZERO[3]))

                -- 轨 2: 水平走位（驱动角色顶级 Transform 世界坐标）
                if S.pos_horiz then
                    if MASTER_XF == nil then
                        local go = get_master_go()
                        if go ~= nil then
                            local okx, xf = pcall(go.call, go, "get_Transform")
                            if okx and xf ~= nil then MASTER_XF = xf end
                        end
                    end

                    if MASTER_XF ~= nil then
                        if WORLD_ZERO == nil then
                            local cur_wp = jget3(MASTER_XF, "get_Position")
                            if cur_wp ~= nil then
                                WORLD_ZERO = { cur_wp[1], cur_wp[2], cur_wp[3] }
                                LAST_WORLD_POS = { cur_wp[1], cur_wp[2], cur_wp[3] }
                                local cur_q = jget(MASTER_XF, "get_Rotation")
                                if cur_q ~= nil then
                                    local fwd = qrot(cur_q, { 0.0, 0.0, 1.0 })
                                    WORLD_YAW_ZERO = math.atan(fwd[1], fwd[3])
                                else
                                    WORLD_YAW_ZERO = 0.0
                                end
                            end
                        end

                        if WORLD_ZERO ~= nil then
                            local total_yaw = (WORLD_YAW_ZERO or 0.0) + (S.yaw_deg + (S.pos_yaw_offset or 0.0)) * 0.017453292519943295
                            local sn, cs = math.sin(total_yaw), math.cos(total_yaw)
                            local world_dx = dx * cs + dz * sn
                            local world_dz = -dx * sn + dz * cs
                            local target_wx = WORLD_ZERO[1] + world_dx
                            local target_wy = WORLD_ZERO[2]
                            local target_wz = WORLD_ZERO[3] + world_dz

                            -- Idempotent within a render frame. The previous EMA advanced
                            -- again for every LockScene callback, so its lag varied by FPS
                            -- and callback count. Scrubbing/looping must snap, not smear.
                            local final_wx, final_wy, final_wz = target_wx,target_wy,target_wz
                            local elapsed = LAST_WORLD_TIME and (S.t-LAST_WORLD_TIME)/(anim.fps or 30) or nil
                            if S.pos_smooth and LAST_WORLD_POS and elapsed and S.playing then
                                if elapsed==0 then
                                    final_wx,final_wz=LAST_WORLD_POS[1],LAST_WORLD_POS[3]
                                elseif elapsed>0 and elapsed<0.25 then
                                    local k=1-math.exp(-elapsed/math.max(S.speed,0.1)/0.005)
                                    final_wx=LAST_WORLD_POS[1]+(target_wx-LAST_WORLD_POS[1])*k
                                    final_wz=LAST_WORLD_POS[3]+(target_wz-LAST_WORLD_POS[3])*k
                                end
                            end
                            LAST_WORLD_TIME=S.t
                            LAST_WORLD_POS={final_wx,final_wy,final_wz}

                            local ok_pos = pcall(MASTER_XF.call, MASTER_XF, "set_Position", Vector3f.new(final_wx, final_wy, final_wz))
                            if not ok_pos then
                                pcall(MASTER_XF.call, MASTER_XF, "set_Position", Vector4f.new(final_wx, final_wy, final_wz, 1.0))
                            end
                        end
                    end
                end
            end
        end
    end
end

-- 同帧回读：在写入之后的任一被 hook 的 entry 都会被调用
local function measure_same_frame(entry_label)
    measure_render_delta(entry_label)      -- ★ 渲染后 delta 探针（仅 late entry 生效）
    if not WT.wrote then return end
    if ROOTJ == nil or LAST_ROOT_QT == nil or ROOT_PARENT_W == nil then return end
    if #WT.cur.samples >= 6 then return end
    local cur = jget(ROOTJ, "get_Rotation")
    if cur == nil then return end
    local eff = qang(qmul(ROOT_PARENT_W, LAST_ROOT_QT), cur)
    WT.cur.samples[#WT.cur.samples + 1] = { at = entry_label, eff = eff }
end

-- 根/Cog 是否被 reset_others / ik_off 触碰（回答"写入顺序"自查）
local function audit_root_touch()
    if ROOT_AUDIT ~= nil or DIAG.rootjoint == nil then return end
    local function inlist(lst, name)
        if lst == nil or name == nil then return "?" end
        for _, v in ipairs(lst) do if v == name then return "是" end end
        return "否"
    end
    ROOT_AUDIT = string.format("根关节=%s 在RESET_LIST=%s 在RESET_SKIP=%s 在IK_LIST=%s ; Cog 在RESET_LIST=%s ; 顺序=apply_pose(先写根) -> reset_others -> ik_off -> pos",
        tostring(DIAG.rootjoint), inlist(RESET_LIST, DIAG.rootjoint), inlist(RESET_SKIP, DIAG.rootjoint),
        inlist(IK_LIST, DIAG.rootjoint), inlist(RESET_LIST, "Cog"))
    logmsg("[ABSROOT-ORDER] " .. ROOT_AUDIT)
end

local function on_lock_post()
    LN = LN + 1
    diag_cd = diag_cd + 1
    if DIAGNOSTICS and diag_cd >= 300 then
        diag_cd = 0
        local lim = S.limit_on and string.format("开(%.0f°/帧)", S.limit_deg) or "关"
        local s1 = WT.cur.samples[1]
        local sN = WT.cur.samples[#WT.cur.samples]
        logmsg(string.format("frame=%d t=%.1f/%d clip=%s mode=%s written=%d missing=%d fps_est=%.0f step=%.4f 源步长限幅=%s srcMax=%.1f°(>30°:%d/%d) reinit=%d",
            LN, S.t, anim and (anim.count or 0) or 0, S.clip, S.mode,
            S.written, S.missing, TIME.fps, TIME.step or 0, lim,
            CF.src_max, CF.src_over30, CF.src_n, CF.reanchors))
        logmsg(string.format("[WTIME] 时机=%s | same_frame_eff 首=%s@%s 末=%s@%s (样本%d) | next_frame_eff(旧,必然偏大,仅供参考)=%s",
            tostring(WT.tag),
            s1 and string.format("%.3f", s1.eff) or "?", s1 and s1.at or "-",
            sN and string.format("%.3f", sN.eff) or "?", sN and sN.at or "-",
            #WT.cur.samples, DIAG.write_eff and string.format("%.3f", DIAG.write_eff) or "?"))
        if ROOT_AUDIT ~= nil then logmsg("[WTIME-ORDER] " .. ROOT_AUDIT) end
        -- ★★ 渲染后 delta：引擎实际世界朝向 vs 我们写入的 target
        do
            local parts = {}
            for _, r in ipairs(COMP.rows) do
                parts[#parts + 1] = string.format("%s:Δ=%.2f°轴=(%.2f,%.2f,%.2f) yaw实=%.1f yaw标=%.1f",
                    r.joint, r.angle or -1, r.axis and r.axis[1] or 0, r.axis and r.axis[2] or 0,
                    r.axis and r.axis[3] or 0, r.yaw_act or 0, r.yaw_tgt or 0)
            end
            logmsg(string.format("[DELTA] @%s n=%d | delta=四级%s angle=%s° axis=(%s,%s,%s) | 四骨一致性 spread=%s° 恒定=%s | comp.enabled=%s",
                tostring(COMP.at), COMP.n, qstr4(COMP.delta),
                COMP.delta_angle and string.format("%.2f", COMP.delta_angle) or "?",
                COMP.delta_axis and string.format("%.3f", COMP.delta_axis[1]) or "?",
                COMP.delta_axis and string.format("%.3f", COMP.delta_axis[2]) or "?",
                COMP.delta_axis and string.format("%.3f", COMP.delta_axis[3]) or "?",
                COMP.spread and string.format("%.3f", COMP.spread) or "?", tostring(COMP.stable),
                tostring(COMP.enabled)))
            if #parts > 0 then logmsg("[DELTA-ROWS] " .. table.concat(parts, " | ")) end
            if COMP.rows[1] ~= nil and COMP.rows[1].d2 ~= nil then
                logmsg("[DELTA-ALT] 右乘型 delta2(首骨)=" .. qstr4(COMP.rows[1].d2) ..
                    " 角度=" .. string.format("%.2f", (qang_axis(COMP.rows[1].d2) or 0)) .. "°")
            end
        end
        logmsg(string.format("[ABSROOT] absroot=%s root_zero=%s 根=%s->%s 真实父级=%s 链=%s | Cog世界Yaw=%.2f°(min %.2f/max %.2f n=%d) Cog局部Yaw=%s | 我们写的根QtYaw=%.2f°",
            tostring(S.absroot), tostring(S.root_zero),
            tostring(DIAG.rootbone), tostring(DIAG.rootjoint),
            tostring(DIAG.cog_name), tostring(DIAG.par_chain),
            DIAG.cog_yaw or 0, DIAG.cog_yaw_min or 0, DIAG.cog_yaw_max or 0, DIAG.cog_n,
            DIAG.cog_local and string.format("%.2f", yaw_of(DIAG.cog_local) or 0) or "?",
            DIAG.rootqt_yaw or 0))
        logmsg(string.format("[DANCEDIR] Waist实际Yaw=%.1f° | Hip源Yaw=%.1f° | diff(实际-源)=%.1f° | Cog世界Yaw=%.1f° | yaw_move=%s",
            DANCEDIR.render_waist or 0.0,
            DANCEDIR.src_hip or 0.0,
            DANCEDIR.diff or 0.0,
            DANCEDIR.cog_yaw or 0.0,
            DANCEDIR.move_yaw and string.format("%.1f°", DANCEDIR.move_yaw) or "无"))
    end
end

-- The render correction alone is too late for native hair/cloth simulation:
-- both physics phases would see the underlying idle animation. Feed the same
-- sample after Motion and again after late behavior (procedural look-at can
-- change Head between the two physics phases). Keep LockScene as the final
-- render correction. Never drive outfit secondary joints or run the solver
-- ourselves. Paused poses still feed the anchors so native physics can settle.
-- Only rotations belong here. Capture Cog/stage origins and write translation
-- and IK at LockScene, after native character-controller position correction.
-- Time advances only in on_frame; both feeds sample the same S.t.
local PHYSICS_POSE = { error_logged=false }
local function physics_pose_update()
    if not SESSION.enabled or not READY or not S.enable or anim==nil or S.mode~="dll" then return end
    local ok,err=pcall(pose_write,true)
    if not ok and not PHYSICS_POSE.error_logged then
        PHYSICS_POSE.error_logged=true
        log.info("[MMD-Rise Player] 原生物理姿态供给失败: "..tostring(err))
    end
end
pcall(re.on_application_entry,"UpdateMotion",physics_pose_update)
pcall(re.on_application_entry,"LateUpdateBehavior",physics_pose_update)

-- 注册所有时机：同一函数负责"选中则写 + 之后每处回读"
local function mk_wt_handler(entry_label, tag)
    return function()
        if not SESSION.enabled or not READY or anim == nil or not S.enable then return end
        if WT.tag == tag then pose_write() end
        if DIAGNOSTICS then
            measure_same_frame(entry_label)
            audit_root_touch()
        end
    end
end
for _, w in ipairs(WTIME) do
    if DIAGNOSTICS or w.tag==WT.tag then
    local h = mk_wt_handler(w.entry .. "." .. w.hook, w.tag)
    if w.hook == "pre" then
        pcall(re.on_pre_application_entry, w.entry, h)
    else
        pcall(re.on_application_entry, w.entry, h)
    end
    end
end
-- 诊断行（LN/300 帧日志）挂在 LockScene.post 之后
if DIAGNOSTICS then pcall(re.on_application_entry, "LockScene", on_lock_post) end
-- Apply after game logic and before Transform matrices update at LockScene;
-- repeat at BeginRendering for FOV. BeginRendering alone is too late for pose.
-- All callbacks share one dance time and the fixed stage anchor.
local function camera_update()
    if not SESSION.enabled or (not S.enable and not CAMERA.free.enabled and not CAMERA.active) then return end
    CAMERA.update({clip=S.clip,enabled=S.enable and READY and anim~=nil,
        seconds=anim and S.t/(anim.fps or 30) or 0,origin=WORLD_ZERO,
        source=anim and anim.frames[1].pos or {0,0,0},scale=S.pos_scale,
        yaw=(WORLD_YAW_ZERO or 0)+(S.yaw_deg+S.pos_yaw_offset)*math.pi/180,
        reflect_x=S.reflect_x,pos_mirror=S.pos_mirror,pos_z_flip=S.pos_z_flip})
end
pcall(re.on_application_entry,"LateUpdateBehavior",camera_update)
pcall(re.on_pre_application_entry,"LockScene",camera_update)
pcall(re.on_pre_application_entry,"BeginRendering",camera_update)
pcall(re.on_pre_application_entry,"UpdateBehavior",function()
    if SESSION.enabled then CAMERA.block_player_input() end
end)
-- Set leases before SKS samples/writes its UpdateMotion phase. Both facial and
-- body tracks sample the same S.t, including fractional seeks and paused poses.
pcall(re.on_pre_application_entry,"UpdateMotion",function()
    if not SESSION.enabled or not S.enable then return end
    local ok,err=pcall(EXPRESSIONS.update,{data=anim and anim.morphs,
        enabled=S.enable and READY and anim~=nil,
        seconds=anim and S.t/(anim.fps or 30) or 0})
    if not ok then EXPRESSIONS.release();EXPRESSIONS.status="表情异常："..tostring(err) end
end)
pcall(re.on_pre_application_entry,"PrerenderGUI",function()
    if SESSION.enabled then SESSION.hud(SESSION.hide_ui and ((S.enable and READY) or CAMERA.active)==true) end
end)

-- ================================================================ UI
local function display_time(seconds)
    return string.format("%d:%04.1f",math.floor(seconds/60),seconds%60)
end
local MANAGE={confirm=nil,pending=nil,message="",serial=0,next_poll=0}
local function seek_frame(frame,count)
    if not SESSION.enabled or MANAGE.pending then return end
    if not S.enable then BINDING.update(true) end
    if not S.enable and READY then
        POS_ZERO=nil;WORLD_ZERO=nil;LAST_WORLD_POS=nil;S.enable=true
    end
    S.t=math.max(0,math.min(math.max(0,count-1),frame));S.playing=false
    AUDIO.revision=AUDIO.revision+1;audio_tick(true)
end
local function close_playback()
    CAMERA.release_mmd()
    EXPRESSIONS.release()
    SESSION.music(false)
    S.enable=false;S.playing=false;S.t=0
    POS_ZERO=nil;WORLD_ZERO=nil;LAST_WORLD_POS=nil;LAST_WORLD_TIME=nil
    AUDIO.revision=AUDIO.revision+1;audio_tick(true,true)
    EXPRESSIONS.update({data=anim and anim.morphs,enabled=false,seconds=0})
    SESSION.hud(SESSION.enabled and SESSION.hide_ui and CAMERA.active==true)
end
SESSION.on_change=function(enabled)
    HOTKEY.reset()
    if not enabled then
        close_playback()
        CAMERA.set_free(false);CAMERA.release();EXPRESSIONS.release();SESSION.release()
        BINDING.invalidate("总开关已关闭")
        anim=nil;SAMPLE={}
        CAMERA.clear_cache();EXPRESSIONS.clear_cache()
        TLOCAL,AXISFB,DREFW,MAP,ANCHORW,ADIR,RESTW,BIND={},{},{},{},{},{},{},{}
        COMP.joint2src={}
        collectgarbage("collect")
    else
        TIME.clock=os.clock();TIME.dt=0;BINDING.next_check=0;BINDING.idle_check=0
        BINDING.status="待机：播放或拖动时间轴时绑定主角"
        TIME.onframe_err_logged=false
    end
end
local function play_dance()
    if not SESSION.enabled or MANAGE.pending then return end
    BINDING.update(true)
    if not anim or not READY then logmsg("等待曲目与游戏角色就绪");return end
    if S.enable and S.playing then return end
    if not S.enable then
        POS_ZERO=nil;WORLD_ZERO=nil;LAST_WORLD_POS=nil;LAST_WORLD_TIME=nil
        if S.t >= (anim.count or #anim.frames)-1 then S.t=0 end
        S.enable=true
    end
    S.playing=true;TIME.clock=os.clock();AUDIO.revision=AUDIO.revision+1;audio_tick(true)
end
local function pause_dance()
    if not S.enable or not S.playing then return end
    S.playing=false;AUDIO.revision=AUDIO.revision+1;audio_tick(true)
end
local function request_delete(slug,label)
    if MANAGE.pending then return end
    close_playback()
    MANAGE.serial=MANAGE.serial+1
    MANAGE.pending={id=tostring(os.time()).."_"..tostring(math.floor(os.clock()*1000)).."_"..MANAGE.serial,
        slug=slug,label=label,send_after=os.clock()+0.25,deadline=os.clock()+10}
    MANAGE.confirm=nil;MANAGE.message="正在删除曲目…"
end
local function library_tick()
    local p=MANAGE.pending
    if not p then return end
    local now=os.clock()
    if not p.sent and now>=p.send_after then
        local ok,status=pcall(json.load_file,"MMDRise/library3_status.json")
        if not ok or type(status)~="table" or not status.ready or
            status.version~=3 or type(status.timestamp)~="number" or math.abs(os.time()-status.timestamp)>6 then
            MANAGE.message="曲库组件尚未连接，请用新版导入工具安装组件。";MANAGE.pending=nil;return
        end
        local wrote,value=pcall(json.dump_file,"MMDRise/library3_request.json",{id=p.id,action="delete",slug=p.slug})
        if not wrote or value==false then
            MANAGE.message="无法写入删除请求，请重试。";MANAGE.pending=nil;return
        end
        p.sent=true
    end
    if now<MANAGE.next_poll then return end
    MANAGE.next_poll=now+0.15
        local ok,status=pcall(json.load_file,"MMDRise/library3_status.json")
    if ok and type(status)=="table" and status.id==p.id then
        MANAGE.pending=nil
        if status.ok then
            close_playback();refresh_library();audio_load_library();CAMERA.reload()
            anim=nil;S.clip="";SAMPLE={}
            if LIBRARY[1] then load_clip(LIBRARY[1].slug) end
            MANAGE.message="已删除："..p.label
        else MANAGE.message="删除未完成："..tostring(status.error or "文件正在使用，请重试") end
    elseif now>p.deadline then
        MANAGE.pending=nil;MANAGE.message="等待删除结果超时，请刷新曲库核对。"
    end
end
local function refresh_assets(refresh)
    refresh_library(refresh);audio_load_library();CAMERA.reload()
    local present=false
    for _,clip in ipairs(LIBRARY) do if clip.slug==S.clip then present=true;break end end
    if not present and S.clip~="" then
        close_playback();anim=nil;SAMPLE={};S.clip=""
        if SESSION.enabled and LIBRARY[1] then load_clip(LIBRARY[1].slug) end
    end
    AUDIO.revision=AUDIO.revision+1;audio_tick(true)
end
pcall(re.on_draw_ui, function()
    local ok, err = pcall(function()
        if not imgui.tree_node("MMD 播放器###mmd_rise_player") then return end
        imgui.text_colored("版本: 1.0.3 | 作者: moon", 0xFF808080)
        imgui.separator()
        local changed,value=imgui.checkbox("MMD 总开关###mmd_master",SESSION.enabled)
        if changed then SESSION.set_enabled(value) end
        if not SESSION.enabled then
            imgui.tree_pop();return
        end
        imgui.text(HOTKEY.label().."：播放 / 暂停")
        local clips = LIBRARY
        local labels, selected = {}, 1
        for i, c in ipairs(clips) do labels[i]=c.label; if c.slug == S.clip then selected=i end end
        if #labels==0 then labels={"曲库为空，请导入舞蹈"} end
        changed, value = imgui.combo("曲目###mmd_clip",selected,labels)
        if changed and clips[value] and not MANAGE.pending then
            MANAGE.confirm=nil;MANAGE.message=""
            close_playback()
            load_clip(clips[value].slug)
            audio_tick(true)
        end
        if imgui.button("刷新曲库###mmd_refresh") and not MANAGE.pending then
            MANAGE.confirm=nil;refresh_assets()
        end
        imgui.same_line()
        if imgui.button("删除曲目###mmd_delete") and clips[selected] and not MANAGE.pending then
            MANAGE.confirm={slug=clips[selected].slug,label=clips[selected].label}
        end
        if MANAGE.confirm then
            local c=MANAGE.confirm
            imgui.text("删除《"..c.label.."》？")
            imgui.text("删除动作与独占音轨/镜头，不保留备份。\n其他曲目共用的资源会保留。")
            if imgui.button("确认删除###mmd_delete_confirm") then request_delete(c.slug,c.label) end
            imgui.same_line()
            if imgui.button("取消###mmd_delete_cancel") then MANAGE.confirm=nil end
        end
        if MANAGE.message~="" then imgui.text(MANAGE.message) end
        if not READY then imgui.text(BINDING.status) end
        local count = anim and (anim.count or #anim.frames) or 0
        local fps = anim and (anim.fps or 30) or 30
        if imgui.button("播放###mmd_play") then play_dance() end
        imgui.same_line()
        if imgui.button("暂停###mmd_pause") then pause_dance() end
        imgui.same_line()
        if imgui.button("关闭###mmd_stop") then close_playback() end
        imgui.same_line()
        if imgui.button("重头###mmd_rewind") and not MANAGE.pending then
            S.t=0; AUDIO.revision=AUDIO.revision+1; audio_tick(true)
        end
        changed,value=imgui.slider_float("进度（秒）###mmd_seek",S.t/fps,0,math.max(0,(count-1)/fps))
        if changed then seek_frame(value*fps,count) end
        imgui.text(display_time(S.t/fps).." / "..display_time(count/fps).."  "..(S.enable and (S.playing and "播放中" or "已暂停") or "已关闭"))
        changed,value=imgui.checkbox("循环###mmd_loop",S.loop)
        if changed then S.loop=value; audio_save_settings() end
        imgui.separator()
        local track = AUDIO.tracks[S.clip]
        if type(track)=="table" then
            changed,value=imgui.checkbox("音乐###mmd_music",AUDIO.enabled)
            if changed then AUDIO.enabled=value; AUDIO.revision=AUDIO.revision+1; audio_save_settings(); audio_tick(true) end
            changed,value=imgui.slider_float("音量###mmd_volume",AUDIO.volume*100,0,100)
            if changed then AUDIO.volume=value/100; audio_save_settings(); audio_tick(true) end
            local status=AUDIO.status
            if AUDIO.write_error then imgui.text("音乐通信失败："..AUDIO.write_error)
            elseif not S.enable then imgui.text(AUDIO.enabled and "音乐已绑定 · 播放时连接" or "音乐已关闭")
            elseif not status.ready or status.session~=AUDIO.session then imgui.text("音乐组件未连接；导入工具可自动安装")
            elseif status.error and status.error~="" then imgui.text("音乐："..status.error)
            elseif status.stale then imgui.text("音乐等待同步")
            else imgui.text(AUDIO.enabled and "音乐已绑定 · 随舞蹈同步" or "音乐已关闭") end
        else imgui.text("此舞蹈未绑定音乐，可在导入窗口选择配套音轨。") end
        imgui.separator()
        changed,value=imgui.checkbox("MMD 表情###mmd_expressions",EXPRESSIONS.enabled)
        if changed then EXPRESSIONS.set_enabled(value) end
        imgui.text(EXPRESSIONS.status)
        if imgui.tree_node("表情适配详情###mmd_expression_details") then
            if imgui.button("重新匹配形态键###mmd_expression_rescan") then EXPRESSIONS.rescan() end
            imgui.text("换装后自动匹配；关闭舞蹈或表情后交还 ShapeKeySystem。")
            if #EXPRESSIONS.approximate>0 then imgui.text("近似映射："..table.concat(EXPRESSIONS.approximate,"、")) end
            if #EXPRESSIONS.missing>0 then imgui.text("缺少形态键："..table.concat(EXPRESSIONS.missing,"、")) end
            imgui.tree_pop()
        end
        imgui.separator()
        changed,value=imgui.checkbox("MMD 镜头###mmd_camera",CAMERA.enabled)
        if changed then CAMERA.set_mmd(value) end
        changed,value=imgui.checkbox("自由镜头###mmd_free_camera",CAMERA.free.enabled)
        if changed then CAMERA.set_free(value) end
        if CAMERA.free.enabled then
            imgui.text(CAMERA.free.status)
            imgui.text("Ins 收起面板后：鼠标移动转向\n滚轮前后，W/S 上下，A/D 左右。")
            if imgui.tree_node("自由镜头选项###mmd_free_options") then
                local free=CAMERA.free
                changed,value=imgui.slider_float("移动速度（米/秒）###mmd_free_speed",free.speed,0.1,10)
                if changed then free.speed=value;CAMERA.save() end
                changed,value=imgui.slider_float("鼠标灵敏度###mmd_free_sensitivity",free.sensitivity,0.02,0.5)
                if changed then free.sensitivity=value;CAMERA.save() end
                changed,value=imgui.slider_float("滚轮步长（米/格）###mmd_free_wheel_step",free.wheel_step,0.05,2)
                if changed then free.wheel_step=value;CAMERA.save() end
                changed,value=imgui.slider_float("左右转向###mmd_free_yaw",free.yaw,-180,180)
                if changed then free.yaw=value end
                changed,value=imgui.slider_float("俯仰###mmd_free_pitch",free.pitch,-89,89)
                if changed then free.pitch=value end
                if free.pose then
                    changed,value=imgui.slider_float("视场###mmd_free_fov",free.pose.fov,20,120)
                    if changed then free.pose.fov=value end
                end
                imgui.tree_pop()
            end
        elseif type(CAMERA.tracks[S.clip])=="table" then
            imgui.text(CAMERA.status)
            if imgui.tree_node("镜头选项###mmd_camera_options") then
                local option=CAMERA.option(S.clip)
                local camera_track=CAMERA.tracks[S.clip]
                imgui.text(string.format("镜头范围 %.1f～%.1f 秒；结束后恢复游戏相机。",(camera_track.start or 0)/30,(camera_track["end"] or 0)/30))
                changed,value=imgui.slider_float("镜头延后（秒）###mmd_camera_offset",option.offset or camera_track.offset or 0,-10,10)
                if changed then option.offset=value;CAMERA.save() end
                changed,value=imgui.slider_float("镜头高度（米）###mmd_camera_height",option.height or 0,-2,2)
                if changed then option.height=value;CAMERA.save() end
                changed,value=imgui.slider_float("镜头距离倍率###mmd_camera_distance",option.distance or 1,0.25,3)
                if changed then option.distance=value;CAMERA.save() end
                imgui.text("默认 0 / 0 / 1；体型或舞台不同时可微调。")
                imgui.tree_pop()
            end
        else imgui.text("此舞蹈未绑定镜头，可在导入窗口选择镜头 VMD。") end
        if imgui.tree_node("播放选项###mmd_options") then
            HOTKEY.draw()
            changed,value=imgui.checkbox("MMD 音乐播放时静音游戏 BGM###mmd_mute_bgm",SESSION.mute_bgm)
            if changed then SESSION.mute_bgm=value;SESSION.save();audio_tick(true) end
            changed,value=imgui.checkbox("跳舞/镜头接管时隐藏游戏 UI###mmd_hide_ui",SESSION.hide_ui)
            if changed then SESSION.hide_ui=value;SESSION.save();if not value then SESSION.hud(false) end end
            local edited,text=imgui.input_text("定位帧###mmd_frame",tostring(math.floor(S.t)))
            local frame=tonumber(text)
            if edited and frame and frame==frame and math.abs(frame)<math.huge then
                seek_frame(math.floor(frame),count)
            end
            changed,value=imgui.slider_float("速度###mmd_speed",S.speed,0.25,2)
            if changed then S.speed=value; AUDIO.revision=AUDIO.revision+1; audio_tick(true) end
            imgui.text("改变速度时，音乐音调会随之变化。")
            if type(track)=="table" then
                local offset=AUDIO.offsets[S.clip] or track.offset or 0
                changed,value=imgui.slider_float("音乐延后（秒）###mmd_offset",offset,-5,5)
                if changed then AUDIO.offsets[S.clip]=value; AUDIO.revision=AUDIO.revision+1; audio_save_settings(); audio_tick(true) end
                imgui.text("正值让音乐晚开始；已对齐的音轨保持 0。")
            end
            imgui.tree_pop()
        end
        if imgui.tree_node("状态###mmd_status") then
            imgui.text(string.format("帧 %.1f / %d · 写入 %d · 缺失 %d",S.t,count,S.written,S.missing))
            imgui.text("播放器 1.0.3 · 音乐组件 "..tostring(AUDIO.status.version or "未连接"))
            if PACKAGES.status~='' then imgui.text(PACKAGES.status) end
            if PATHS.status~='' then imgui.text(PATHS.status) end
            if SESSION.music_error then imgui.text("游戏音乐："..SESSION.music_error) end
            if SESSION.hud_error then imgui.text("游戏 UI："..SESSION.hud_error) end
            if CAMERA.error then imgui.text("镜头："..CAMERA.error) end
            imgui.text(BINDING.status)
            imgui.text(S.msg)
            imgui.tree_pop()
        end
        imgui.tree_pop()
    end)
    if not ok then log.info("[MMD-Rise Player] UI 错误: "..tostring(err)) end
end)

-- ================================================================ 启动
local started = false
re.on_frame(function()
    if PATHS.poll(SESSION.enabled) then refresh_assets(false) end
    if not SESSION.enabled then return end
    -- N1 修复（prior-art 审计）：包 pcall。on_frame 里的错误比 on_draw_ui 更难察觉，
    -- 用户只会看到"脚本没反应"。
    local ok, err = pcall(function()
        HOTKEY.tick(function() if S.playing then pause_dance() else play_dance() end end)
        tick_time()
        CAMERA.tick(TIME.dt)
        library_tick()
        if DIAGNOSTICS then probe_native_motion() end
        if anim == nil then
            local selected=nil
            for _,c in ipairs(LIBRARY) do if c.slug==S.clip then selected=c;break end end
            selected=selected or LIBRARY[1]
            if not selected then audio_tick();return end
            if not load_clip(selected.slug) then return end
        end
        -- Normal gameplay needs no skeleton scans. Play and seek force a fresh
        -- binding before the first pose; active/paused dance retains live checks.
        if not S.enable then audio_tick();return end
        local ready=BINDING.update()
        if ready then
            advance_time()
            if not started then
                started=true;logmsg("就绪。请选择曲目并点击播放。")
            end
        end
        audio_tick()
    end)
    if not ok then
        BINDING.invalidate("主角检测异常，等待重新绑定")
        SESSION.music(false)
        if not TIME.onframe_err_logged then
            TIME.onframe_err_logged = true
            log.info("[MMD-Rise Player] on_frame 错误: " .. tostring(err))
        end
    end
end)


