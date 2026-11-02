-- VMD morphs -> installed SKS profiles -> actual worn channels. No engine writes.
local E={enabled=true,status="等待表情数据",profile="",mapped={},missing={},approximate={}}
local OWNER="MMDRise.Expressions"
local IDS={"airi","arkit","chocolat","eku","kaguya","karin","kipfel","mafuyu",
    "manuka","maya","milltina","mmd","moko","nitco","sairou","shinano"}
local api,listener,U,Names,profiles,clip,plan,dirty=nil,nil,nil,nil,nil,nil,nil,true
local held=false
local cached_frame,cached_values,last_send=nil,nil,-10
local function clamp(v) return math.max(0.0,math.min(1.0,v)) end
local function norm(s) return U.norm(s) end
local aliases={}
local specs={}
local function spec(id,names,signals,family,approx)
    specs[id]={signals=signals,family=family,approx=approx}
    for _,name in ipairs(names) do aliases[name]=id end
end
local function both(s,v) return {[s..".L"]=v or 1,[s..".R"]=v or 1} end
spec("a",{"あ","ア","a"},{jawOpen=1},"mouth")
spec("i",{"い","イ","i"},{jawOpen=.25,["stretch.L"]=.8,["stretch.R"]=.8},"mouth",true)
spec("u",{"う","ウ","u"},both("funnel"),"mouth")
spec("e",{"え","エ","e"},{jawOpen=.5,["stretch.L"]=.5,["stretch.R"]=.5},"mouth",true)
spec("o",{"お","オ","o"},{jawOpen=.65,["funnel.L"]=1,["funnel.R"]=1},"mouth",true)
spec("blink",{"まばたき","瞬き","blink","眨眼","闭眼","目閉じ"},both("blink"),"eye")
spec("winkL",{"ウィンク","ウインク","ウィンク２","ウインク２","ウィンク左","ウィンク２左","wink","wink2"},{["blink.L"]=1},"eye")
spec("winkR",{"ウィンク右","ウインク右","ｳｨﾝｸ２右","ウィンク２右","ウインク２右","ウィンク右２","wink_r","wink2_r"},{["blink.R"]=1},"eye")
spec("joy",{"笑い","笑眼","smileeyes","にっこり"},{["cheekSquint.L"]=1,["cheekSquint.R"]=1,["blink.L"]=.7,["blink.R"]=.7},"eye",true)
spec("half",{"なごみ","半目","じと目","ジト目"},both("eyeSquint"),"eye")
spec("wide",{"びっくり","驚き","見開き","surprised"},both("eyeWide"),"eye")
spec("lowerlid",{"下瞼上げ","下まぶた上げ","下まつ毛上げ"},both("cheekSquint"),"eye")
spec("browUp",{"上","眉上","眉上げ"},both("browOuterUp"),"brow")
spec("browDown",{"下","眉下","眉下げ","真面目"},both("browDown"),"brow")
spec("browSad",{"困る","困り","困り眉"},both("browInnerUp"),"brow")
spec("browAngry",{"怒り","眉怒り"},both("browBring"),"brow")
spec("browSmile",{"にこり"},both("browInnerUp",.5),"brow",true)
spec("smile",{"口角上げ","口角上","にやり","微笑"},both("smile"),"mouth")
spec("frown",{"口角下げ","口角下","への字","∧"},both("frown"),"mouth")
spec("stretch",{"口横広げ","口横","口幅大"},both("stretch"),"mouth")
spec("narrow",{"すぼめ","口小","口幅小"},both("funnelTogether"),"mouth")
spec("press",{"ん","口閉じ","抿嘴"},both("press"),"mouth")
spec("puff",{"ぷくー","頬ぷく","鼓腮"},both("puff"),"cheek")
local native={
    a={"mouth_a1","mouth_a_1","mouth_A_1","kuchi_A","m_a","mouth_aa","mouth_あ","vrc.v_aa","あ"},
    i={"mouth_i1","mouth_i_1","mouth_I_1","kuchi_I","m_i","mouth_い","vrc.v_ih","い"},
    u={"mouth_u1","mouth_u_1","mouth_U_1","kuchi_U","m_u","mouth_ou","mouth_う","vrc.v_ou","う"},
    e={"mouth_e1","mouth_e_1","mouth_E_1","kuchi_E","m_e","mouth_え","vrc.v_e","え"},
    o={"mouth_o1","mouth_o_1","mouth_O_1","kuchi_O","m_o","mouth_お","vrc.v_oh","お"},
    joy={"eye_joy_L","eye_joy_R"},half={"eye_halfclose_L","eye_halfclose_R"},
    tongue={"tongue_pero","tongueOut","舌出し","ぺろっ"}
}
spec("tongue",{"ぺろっ","舌出し","tongueOut"},{},"mouth")

-- Only the small, documented profile expression grammar is evaluated. Gaze and
-- sculpt position/size nodes are deliberately excluded from neutral ownership.
local function eval(n,p)
    if n.s then return (p[n.s] or 0)*(n.k or 1) end
    if n.const then return n.const end
    if type(n.sub)=="table" then
        local v=eval(n.sub[1],p)
        for i=2,#n.sub do v=v-eval(n.sub[i],p) end
        return v*(n.k or 1)
    end
    for _,op in ipairs({"sum","max","min","mul"}) do
        if type(n[op])=="table" then
            local v=(op=="mul") and 1 or ((op=="min") and math.huge or 0)
            for _,child in ipairs(n[op]) do
                local x=eval(child,p)
                if op=="sum" then v=v+x elseif op=="max" then v=math.max(v,x)
                elseif op=="min" then v=math.min(v,x) else v=v*x end
            end
            return v*(n.k or 1)
        end
    end
    return 0
end
local function read_profiles()
    profiles={}
    for _,id in ipairs(IDS) do
        local ok,p=pcall(json.load_file,"ShapeKeySystem/builtin/profiles/"..id..".json")
        if ok and type(p)=="table" and type(p.channels)=="table" then profiles[#profiles+1]=p end
    end
end
local function release()
    if api and held then pcall(api.release_all,OWNER) end
    held=false
    cached_frame,cached_values,last_send=nil,nil,-10
end
function E.release() release() end
function E.clear_cache()
    release();clip=nil;plan=nil;dirty=true
    E.mapped={};E.missing={};E.approximate={};E.profile=''
    if api and listener then pcall(api.off,listener) end
    api=nil;listener=nil
end
function E.rescan() dirty=true end
function E.set_enabled(v) E.enabled=v==true;if not E.enabled then release() end end
local function connect()
    local a=rawget(_G,"ShapeKeySystemAPI")
    if api~=a then
        release()
        if api and listener then pcall(api.off,listener) end
        api=a;listener=nil;dirty=true
        if api then listener=api.on("scan",function() dirty=true end) end
    end
    if not api then E.status="未连接 ShapeKeySystem 1.5+";return false end
    if not U then
        U=require("ShapeKeySystem_Core.Util");Names=require("ShapeKeySystem_Core.Names")
        local normalized={}
        for name,id in pairs(aliases) do normalized[norm(name)]=id end
        aliases=normalized
        read_profiles()
    end
    if not api.is_ready() then release();E.status="等待支持形态键的装备";return false end
    return true
end
local function sample(keys,f)
    if f<keys[1][1] then return 0 end -- neutral before first authored key
    local lo,hi=1,#keys
    while lo<hi do local m=math.floor((lo+hi+1)/2);if keys[m][1]<=f then lo=m else hi=m-1 end end
    local a,b=keys[lo],keys[lo+1]
    if not b then return a[2] end
    return a[2]+(b[2]-a[2])*(f-a[1])/(b[1]-a[1])
end
E.sample=sample
local function rebuild(data)
    release();dirty=false;plan={tracks={},neutral={}};E.mapped={};E.missing={};E.approximate={}
    local channels=api.channels();local actual,by_norm={},{ }
    for _,c in ipairs(channels) do
        actual[#actual+1]=c.name
        local keys,n=Names.keys(c.name)
        for i=1,n do by_norm[keys[i]]=by_norm[keys[i]] or {};table.insert(by_norm[keys[i]],c.name) end
    end
    local best,selected,best_count=nil,{},0
    for _,p in ipairs(profiles) do
        local names={};for i,c in ipairs(p.channels) do names[i]=c.name end
        local index=Names.build_index(names,p.aliases,p.channels)
        local matches=Names.match_part(index,actual);local count=0
        for _,s in ipairs(matches) do if s then count=count+1 end end
        if count>best_count then best,best_count,selected=p,count,matches end
    end
    E.profile=best and best.name or "同名形态键"
    local rows={}
    if best then for i,s in ipairs(selected) do if s then rows[#rows+1]={name=actual[i],node=best.channels[s]} end end end
    local families={}
    for _,track in ipairs(data.tracks or {}) do
        local active=false
        for _,k in ipairs(track.keys or {}) do if k[2]>0 then active=true;break end end
        if active then
            local id=aliases[norm(track.name)];local definition=specs[id];local targets={};local approx=false
            local function add(names,gain)
                for _,name in ipairs(names or {}) do targets[name]=math.max(targets[name] or 0,gain) end
            end
            add(by_norm[norm(track.name)],1)
            if next(targets)==nil and native[id] then
                for _,name in ipairs(native[id]) do
                    add(by_norm[norm(name)],1)
                    -- Vowels choose one native viseme; bilateral eyes keep both.
                    if next(targets) and id~="joy" and id~="half" then break end
                end
            end
            if next(targets)==nil and definition then
                approx=definition.approx or false
                for _,row in ipairs(rows) do
                    local v=clamp(eval(row.node,definition.signals))
                    if v>0 then targets[row.name]=v;approx=approx or row.node.guessed==true end
                end
            end
            if next(targets) then
                plan.tracks[#plan.tracks+1]={keys=track.keys,targets=targets,name=track.name}
                E.mapped[#E.mapped+1]=track.name
                if approx then E.approximate[#E.approximate+1]=track.name end
                if definition then families[definition.family]=true end
                for name in pairs(targets) do plan.neutral[name]=true end
            else E.missing[#E.missing+1]=track.name end
        end
    end
    -- Neutralize only expression families authored by this clip; never position,
    -- body sculpt, gaze or unrelated accessories. Expiring leases restore SKS.
    for _,row in ipairs(rows) do
        for _,definition in pairs(specs) do
            if families[definition.family] and eval(row.node,definition.signals)>0 then plan.neutral[row.name]=true;break end
        end
    end
    for id,names in pairs(native) do
        local family=specs[id] and specs[id].family
        if families[family] then for _,name in ipairs(names) do for _,n in ipairs(by_norm[norm(name)] or {}) do plan.neutral[n]=true end end end
    end
    E.status=string.format("%s · 已匹配 %d / %d 项",E.profile,#E.mapped,#E.mapped+#E.missing)
end
function E.update(ctx)
    local data=ctx.data
    if not E.enabled or not ctx.enabled or type(data)~="table" or data.schema~="mmdrise.morphs/1" then
        release()
        E.status=not E.enabled and "表情已关闭" or (data and "表情待播放" or "此曲目没有表情，可在导入窗口选择表情 VMD。")
        return
    end
    if not connect() then return end
    if clip~=data then clip=data;dirty=true end
    if dirty or not plan then rebuild(data) end
    local frame=ctx.seconds*(data.fps or 30)
    local now=os.clock()
    -- Paused poses are identical. Reuse their exact weights and only renew the
    -- .5-second leases at .2 seconds; a scan, clip change or release clears this.
    if cached_frame==frame and cached_values and held and now-last_send<.2 then return end
    local values=cached_values
    if cached_frame~=frame or not values then
        values={}
        for name in pairs(plan.neutral) do values[name]=0.0 end
        for _,track in ipairs(plan.tracks) do
            local v=clamp(sample(track.keys,frame))
            for name,gain in pairs(track.targets) do values[name]=clamp((values[name] or 0)+v*gain) end
        end
        cached_frame,cached_values=frame,values
    end
    held=next(values)~=nil
    for name,v in pairs(values) do
        local ok,err=api.set(OWNER,name,v+0.0,{ttl=.5})
        if not ok then release();E.status="表情写入被拒绝："..tostring(err);return end
    end
    last_send=now
end
function E.shutdown()
    release()
    if api and listener then pcall(api.off,listener) end
    listener=nil
end
if type(re.on_script_reset)=="function" then re.on_script_reset(E.shutdown) end
return E
