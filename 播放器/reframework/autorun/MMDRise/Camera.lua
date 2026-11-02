local PATHS=require('MMDRise.Paths')
-- VMD cameras: raw MMD stage coordinates, six destination-key Bezier curves.
-- The player supplies its fixed stage origin and authoritative dance clock.
local C={enabled=true,tracks={},cache={},options={},status="未绑定镜头",
    free={enabled=false,speed=1.5,sensitivity=0.12,wheel_step=0.25,yaw=0,pitch=0,status="自由镜头已关闭"}}
local PI=math.pi
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function v3(v) return {v.x,v.y,v.z} end
local function q4(v) return {v.x,v.y,v.z,v.w} end
local function qmul(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
        a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
        a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
local function axis(i,r)
    local q={0,0,0,math.cos(r/2)};q[i]=math.sin(r/2);return q
end
local function rotate(q,v)
    local a=qmul(q,{v[1],v[2],v[3],0})
    local r=qmul(a,{-q[1],-q[2],-q[3],q[4]});return {r[1],r[2],r[3]}
end
local function cross(a,b) return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]} end
local function norm(v)
    local n=math.sqrt(v[1]^2+v[2]^2+v[3]^2)
    return {v[1]/n,v[2]/n,v[3]/n}
end
local function look_rotation(forward,up)
    -- via.Camera looks along local -Z (confirmed against get_LookAtPosition).
    local z={-forward[1],-forward[2],-forward[3]}
    local x=norm(cross(up,z));local y=cross(z,x)
    local a,b,c=x[1],y[1],z[1]
    local d,e,f=x[2],y[2],z[2]
    local g,h,i=x[3],y[3],z[3]
    local t=a+e+i
    if t>0 then
        local s=math.sqrt(1+t)*2;return {(h-f)/s,(c-g)/s,(d-b)/s,s/4}
    elseif a>e and a>i then
        local s=math.sqrt(1+a-e-i)*2;return {s/4,(b+d)/s,(c+g)/s,(h-f)/s}
    elseif e>i then
        local s=math.sqrt(1+e-a-i)*2;return {(b+d)/s,s/4,(f+h)/s,(c-g)/s}
    else
        local s=math.sqrt(1+i-a-e)*2;return {(c+g)/s,(f+h)/s,s/4,(d-b)/s}
    end
end
local function bezier(t,bytes,index)
    if t<=0 then return 0 elseif t>=1 then return 1 end
    local k=index*4
    local x1,x2,y1,y2=bytes[k+1]/127,bytes[k+2]/127,bytes[k+3]/127,bytes[k+4]/127
    local function curve(s,a,b) return 3*(1-s)^2*s*a+3*(1-s)*s*s*b+s*s*s end
    local lo,hi=0,1
    for _=1,22 do
        local mid=(lo+hi)/2
        if curve(mid,x1,x2)<t then lo=mid else hi=mid end
    end
    return curve((lo+hi)/2,y1,y2)
end
local function sample(data,frame)
    local keys=data.keys
    local lo,hi=1,#keys
    while lo<hi do
        local mid=math.floor((lo+hi+1)/2)
        if keys[mid].frame<=frame then lo=mid else hi=mid-1 end
    end
    local a,b=keys[lo],keys[math.min(lo+1,#keys)]
    if frame<a.frame or a==b then return a end
    local gap=b.frame-a.frame
    -- A one-frame key interval represents a cut, including fractional sampling.
    if gap<=1 then return a end
    local t=clamp((frame-a.frame)/gap,0,1)
    local r={position={},rotation={}}
    for j=1,3 do
        local w=bezier(t,b.interpolation,j-1)
        r.position[j]=a.position[j]+(b.position[j]-a.position[j])*w
    end
    local rw=bezier(t,b.interpolation,3)
    for j=1,3 do r.rotation[j]=a.rotation[j]+(b.rotation[j]-a.rotation[j])*rw end
    r.distance=a.distance+(b.distance-a.distance)*bezier(t,b.interpolation,4)
    r.fov=a.fov+(b.fov-a.fov)*bezier(t,b.interpolation,5)
    return r
end
local sample_cache={}
function C.sample(data,frame)
    if sample_cache.data==data and sample_cache.frame==frame then return sample_cache.value end
    local value=sample(data,frame)
    sample_cache={data=data,frame=frame,value=value}
    return value
end
function C.pose(key,ctx,option)
    option=option or {}
    -- Equivalent to mmd_tools camera's Blender YXZ after swapping MMD Y/Z:
    -- raw MMD orbit = Ry(-ry) Rx(-rx) Rz(-rz), distance along local +Z.
    local r=key.rotation
    local q=qmul(qmul(axis(2,-r[2]),axis(1,-r[1])),axis(3,-r[3]))
    local orbit=rotate(q,{0,0,key.distance*(option.distance or 1)})
    local p={key.position[1]+orbit[1],key.position[2]+orbit[2],key.position[3]+orbit[3]}
    local forward,up=rotate(q,{0,0,1}),rotate(q,{0,1,0})
    local sx,sy,sz=ctx.reflect_x and -1 or 1,ctx.pos_mirror and -1 or 1,1
    if ctx.pos_mirror then sz=-sz end
    if ctx.pos_z_flip then sz=-sz end
    local sn,cs=math.sin(ctx.yaw),math.cos(ctx.yaw)
    local function direction(v)
        local x,y,z=v[1]*sx,v[2]*sy,v[3]*sz
        return {x*cs+z*sn,y,-x*sn+z*cs}
    end
    local relative=direction({(p[1]-ctx.source[1])*ctx.scale,p[2]*ctx.scale,(p[3]-ctx.source[3])*ctx.scale})
    local world={ctx.origin[1]+relative[1],ctx.origin[2]+relative[2]+(option.height or 0),ctx.origin[3]+relative[3]}
    return world,look_rotation(direction(forward),direction(up)),key.fov
end
local function release_input()
    local held=C.free.input
    C.free.input=nil
    if held then pcall(held.player.call,held.player,"setInput",held.enabled) end
end
local function reset_mouse()
    C.free.input_ready=false;C.free.input_frame=nil
end
function C.release()
    local saved=C.saved
    C.saved=nil;C.active=false;C.last_pose=nil;C.free.pose=nil
    release_input()
    reset_mouse()
    if saved then
        pcall(function()
            saved.camera:call("set_VerticalEnable",saved.vertical)
            saved.camera:call("set_FOV",saved.fov)
            saved.transform:call("set_Position",Vector3f.new(table.unpack(saved.position)))
            saved.transform:call("set_Rotation",Vector4f.new(table.unpack(saved.rotation)))
        end)
    end
end
-- Dance transport, rebinding and library refresh must not close an independent camera.
function C.clear_cache()
    C.release();C.cache={};sample_cache={};C.mouse_api=nil
end
function C.release_mmd()
    if not C.free.enabled then C.release() end
end
function C.set_mmd(enabled)
    reset_mouse()
    C.enabled=enabled
    if enabled then C.free.enabled=false;C.free.pose=nil;release_input() end
    if not enabled and not C.free.enabled then C.release() end
    C.save()
end
function C.set_free(enabled)
    if enabled==C.free.enabled then return end
    reset_mouse()
    C.free.enabled=enabled
    if enabled then
        C.enabled=false;C.free.yaw=0;C.free.pitch=0
        -- When switching from VMD, start exactly at its current rendered pose.
        local p=C.last_pose
        C.free.pose=p and {p={table.unpack(p.p)},base={table.unpack(p.q)},q={table.unpack(p.q)},fov=p.fov} or nil
        C.free.status="自由镜头等待相机"
    else C.release();C.free.status="自由镜头已关闭" end
    C.save()
end
function C.block_player_input()
    if not C.free.enabled then release_input();return end
    local ok,err=pcall(function()
        local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
        local player=pm and pm:call("findMasterPlayer()")
        if not player then C.release();return end
        local held=C.free.input
        if held and held.player~=player then release_input();held=nil end
        if not held then
            held={player=player,enabled=player:call("isInput")}
            C.free.input=held
        end
        player:call("setInput",false)
    end)
    if not ok then
        C.free.enabled=false;C.release()
        C.free.status="自由镜头关闭：人物输入接管失败"
        log.info("[MMDRise Camera] input: "..tostring(err))
    end
end
local function key_down(vk) return reframework and reframework:is_key_down(vk) or false end
local function mouse_sample()
    -- Rise SDK, verified in-process. Never derive relative motion from cursor coordinates.
    if not C.mouse_api then
        local mouse=sdk.find_type_definition("via.hid.Mouse")
        local app=sdk.find_type_definition("via.Application")
        C.mouse_api={device=assert(mouse and mouse:get_method("get_Device")),
            focus=assert(app and app:get_method("get_HasFocus")),
            frame=assert(app and app:get_method("get_FrameCount"))}
    end
    local api=C.mouse_api
    local frame=api.frame:call(nil)
    local focused=api.focus:call(nil)
    assert(finite(frame) and type(focused)=="boolean","鼠标帧状态无效")
    local device=assert(api.device:call(nil),"鼠标设备不可用")
    local delta=device:call("get_DeltaPosition")
    local wheel=device:call("get_WheelDelta")
    assert(delta and finite(delta.x) and finite(delta.y) and finite(wheel),"鼠标增量无效")
    return frame,focused,delta.x,delta.y,wheel
end
-- Integrate once per on_frame, never in the three camera write callbacks.
function C.tick(dt)
    local f=C.free
    if not f.enabled or not f.pose or not f.input then reset_mouse();return end
    local ok,frame,focused,dx,dy,wheel=pcall(mouse_sample)
    if not ok then
        f.enabled=false;C.release();f.status="自由镜头关闭：鼠标读取失败"
        C.error=tostring(frame);log.info("[MMDRise Camera] mouse: "..C.error);return
    end
    if frame==f.input_frame then return end
    f.input_frame=frame
    local open=reframework and reframework:is_drawing_ui()
    local usable=focused and not open and finite(dt) and dt>=0 and dt<=0.2
    local consume=usable and f.input_ready
    f.input_ready=usable
    dt=finite(dt) and clamp(dt,0,0.1) or 0
    local p=f.pose
    local x,y=0,0
    if consume then
        x=(key_down(0x44) and 1 or 0)-(key_down(0x41) and 1 or 0)
        y=(key_down(0x57) and 1 or 0)-(key_down(0x53) and 1 or 0)
        -- Native deltas are counts / wheel notches per frame, not rates: no dt factor.
        f.yaw=f.yaw+dx*f.sensitivity
        f.yaw=(f.yaw+180)%360-180
        f.pitch=clamp(f.pitch-dy*f.sensitivity,-89,89)
    end
    p.q=qmul(qmul(axis(2,-f.yaw*PI/180),p.base),axis(1,f.pitch*PI/180))
    local right,forward=rotate(p.q,{1,0,0}),rotate(p.q,{0,0,-1})
    local move={right[1]*x,right[2]*x+y,right[3]*x}
    local length=math.sqrt(move[1]^2+move[2]^2+move[3]^2)
    if length>0 then
        for i=1,3 do p.p[i]=p.p[i]+move[i]/length*f.speed*dt end
    end
    if consume and wheel~=0 then
        for i=1,3 do p.p[i]=p.p[i]+forward[i]*wheel*f.wheel_step end
    end
end
local function capture(cam,mode,ctx)
    local xf=cam:call("get_GameObject"):call("get_Transform")
    return {camera=cam,transform=xf,fov=cam:call("get_FOV"),vertical=cam:call("get_VerticalEnable"),
        position=v3(xf:call("get_Position")),rotation=q4(xf:call("get_Rotation")),
        mode=mode,clip=ctx and ctx.clip,stage=ctx and ctx.origin}
end
local function free_update()
    local f=C.free
    local ok,err=pcall(function()
        local cam=sdk.get_primary_camera()
        if not cam then C.release();f.status="自由镜头等待游玩场景";return end
        -- The UI can switch modes after UpdateBehavior; keep its VMD seed until
        -- next frame acquires player input, instead of recapturing the game view.
        if not f.input then f.status="自由镜头等待游玩场景";return end
        if C.saved and C.saved.camera~=cam then C.release();return end
        if not C.saved then C.saved=capture(cam,"free") end
        C.saved.mode="free"
        if not f.pose then
            local xf=C.saved.transform
            local fov=cam:call("get_FOV")
            if cam:call("get_VerticalEnable") then
                fov=2*math.atan(math.tan(fov*PI/360)*cam:call("get_AspectRatio"))*180/PI
            end
            f.pose={p=v3(xf:call("get_Position")),base=q4(xf:call("get_Rotation")),
                q=q4(xf:call("get_Rotation")),fov=fov}
            f.yaw=0;f.pitch=0
        end
        local p=f.pose
        cam:call("set_VerticalEnable",false);cam:call("set_FOV",p.fov)
        C.saved.transform:call("set_Position",Vector3f.new(table.unpack(p.p)))
        C.saved.transform:call("set_Rotation",Vector4f.new(table.unpack(p.q)))
        C.active=true;C.last_pose=p;f.status="自由镜头已开启";C.error=nil
    end)
    if not ok then
        f.enabled=false;C.release();f.status="自由镜头写入失败"
        C.error=tostring(err);log.info("[MMDRise Camera] free: "..C.error)
    end
end
function C.reload()
    sample_cache={}
    C.release_mmd();C.cache={};C.error=nil
    local ok,data=pcall(json.load_file,"MMDRise/camera_library.json")
    C.tracks=ok and type(data)=="table" and type(data.tracks)=="table" and data.tracks or {}
end
function C.save()
    pcall(json.dump_file,"MMDRise/camera_user.json",{enabled=C.enabled,options=C.options,free_speed=C.free.speed,
        free_sensitivity=C.free.sensitivity,free_wheel_step=C.free.wheel_step})
end
function C.option(slug)
    if not C.options[slug] then C.options[slug]={} end
    return C.options[slug]
end
function C.load(slug)
    if C.cache[slug]~=nil then return C.cache[slug] end
    local track=C.tracks[slug]
    if type(track)~="table" or type(track.file)~="string" or not PATHS.path(track.file) then return nil end
    local ok,data=pcall(json.load_file,PATHS.path(track.file))
    if not ok or type(data)~="table" or data.version~=1 or type(data.keys)~="table" or #data.keys==0 then
        C.cache[slug]=false;C.error="镜头文件无法读取，请重新导入";return nil
    end
    local previous=-1
    for _,k in ipairs(data.keys) do
        if not finite(k.frame) or k.frame<=previous or not finite(k.distance) or not finite(k.fov) or k.fov<1 or k.fov>179 or
            k.perspective~=true or type(k.position)~="table" or type(k.rotation)~="table" or type(k.interpolation)~="table" then
            C.cache[slug]=false;C.error="镜头数据无效";return nil
        end
        for i=1,3 do
            if not finite(k.position[i]) or not finite(k.rotation[i]) then C.cache[slug]=false;C.error="镜头坐标无效";return nil end
        end
        for i=1,24 do
            if not finite(k.interpolation[i]) or k.interpolation[i]<0 or k.interpolation[i]>127 then C.cache[slug]=false;C.error="镜头插值无效";return nil end
        end
        previous=k.frame
    end
    data.start=data.keys[1].frame;data["end"]=data.keys[#data.keys].frame
    C.cache[slug]=data;C.error=nil;return data
end
function C.update(ctx)
    if C.free.enabled then free_update();return end
    local track=C.tracks[ctx.clip]
    if not track then C.release();C.status="此舞蹈未绑定镜头";return end
    if not C.enabled then C.release();C.status="镜头已关闭";return end
    if not ctx.enabled or not ctx.origin then C.release();C.status="镜头等待播放";return end
    local data=C.load(ctx.clip)
    if not data then C.release();C.status=C.error or "镜头载入失败";return end
    local option=C.option(ctx.clip)
    local frame=(ctx.seconds-(option.offset or track.offset or 0))*30
    if frame<data.start or frame>data["end"] then C.release();C.status="镜头范围外 · 游戏相机";return end
    local cam=sdk.get_primary_camera()
    if not cam then C.release();return end
    if C.saved and (C.saved.camera~=cam or (C.saved.mode~="free" and (C.saved.clip~=ctx.clip or C.saved.stage~=ctx.origin))) then C.release() end
    local ok,err=pcall(function()
        if not C.saved then
            C.saved=capture(cam,"mmd",ctx)
        end
        C.saved.mode="mmd";C.saved.clip=ctx.clip;C.saved.stage=ctx.origin
        local p,q,fov=C.pose(C.sample(data,frame),ctx,option)
        local aspect=cam:call("get_AspectRatio")
        local horizontal=2*math.atan(math.tan(fov*PI/360)*aspect)*180/PI
        cam:call("set_VerticalEnable",false)
        cam:call("set_FOV",horizontal)
        C.saved.transform:call("set_Position",Vector3f.new(table.unpack(p)))
        C.saved.transform:call("set_Rotation",Vector4f.new(table.unpack(q)))
        C.active=true;C.error=nil;C.status="镜头同步中";C.frame=frame;C.last_pose={p=p,q=q,fov=horizontal}
    end)
    if not ok then
        C.release();C.status="镜头写入失败"
        if C.error~=tostring(err) then C.error=tostring(err);log.info("[MMDRise Camera] "..C.error) end
    end
end
C.reload()
do
    local ok,data=pcall(json.load_file,"MMDRise/camera_user.json")
    if ok and type(data)=="table" then
        if type(data.enabled)=="boolean" then C.enabled=data.enabled end
        if finite(data.free_speed) then C.free.speed=clamp(data.free_speed,0.1,10) end
        if finite(data.free_sensitivity) then C.free.sensitivity=clamp(data.free_sensitivity,0.02,0.5) end
        if finite(data.free_wheel_step) then C.free.wheel_step=clamp(data.free_wheel_step,0.05,2) end
        if type(data.options)=="table" then
            for slug,o in pairs(data.options) do
                if type(o)=="table" then
                    C.options[slug]={offset=finite(o.offset) and clamp(o.offset,-30,30) or nil,
                        height=finite(o.height) and clamp(o.height,-2,2) or 0,
                        distance=finite(o.distance) and clamp(o.distance,0.25,3) or 1}
                end
            end
        end
    end
end
if type(re.on_script_reset)=="function" then re.on_script_reset(C.release) end
return C
