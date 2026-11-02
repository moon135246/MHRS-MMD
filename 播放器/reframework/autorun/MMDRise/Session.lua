-- Temporary presentation ownership. Never change the game's saved options.
local R={enabled=true,hide_ui=true,mute_bgm=true,play_key=0x23,hud_hidden=false,bgm_muted=false}
local music
local function music_api()
    if not music then
        local td=assert(sdk.find_type_definition("via.wwise.WwiseManager"),"WwiseManager unavailable")
        music={get=assert(td:get_method("get_MuteMusic")),set=assert(td:get_method("set_MuteMusic"))}
    end
    return music
end
function R.music(active)
    if not active and not R.music_saved then return end
    local ok,err=pcall(function()
        local a=music_api()
        if active then
            local before=a.get:call(nil)
            assert(type(before)=="boolean","MuteMusic is not boolean")
            if not R.music_saved then R.music_saved={value=before} end
            if not before then a.set:call(nil,true) end
            R.bgm_muted=true
        else
            a.set:call(nil,R.music_saved.value)
            R.music_saved=nil;R.bgm_muted=false
        end
    end)
    R.music_error=not ok and tostring(err) or nil
end
local function restore_hud()
    local saved=R.hud_saved
    if not saved then return end
    saved.object:call("setInvisibleAllGUI",saved.value)
    R.hud_saved=nil;R.hud_hidden=false
end
function R.hud(active)
    if not active and not R.hud_saved then return end
    local ok,err=pcall(function()
        if not active then restore_hud();return end
        local gm=sdk.get_managed_singleton("snow.gui.GuiManager")
        if not gm then restore_hud();return end
        if R.hud_saved and R.hud_saved.object~=gm then restore_hud() end
        -- Menu input still works while HUD is hidden; reveal it before drawing.
        if gm:call("IsStartMenuAndSubmenuOpen") or gm:call("isOpenPauseWindow") then
            restore_hud();return
        end
        local before=gm:call("isInvisibleAllGUI")
        assert(type(before)=="boolean","InvisibleAllGUI is not boolean")
        if not R.hud_saved then R.hud_saved={object=gm,value=before} end
        if not before then gm:call("setInvisibleAllGUI",true) end
        R.hud_hidden=true
    end)
    R.hud_error=not ok and tostring(err) or nil
end
function R.release()
    R.music(false);R.hud(false)
end
function R.save()
    pcall(json.dump_file,"MMDRise/player_user.json",{enabled=R.enabled,hide_ui=R.hide_ui,mute_bgm=R.mute_bgm,play_key=R.play_key})
end
function R.set_enabled(enabled)
    enabled=enabled==true
    if R.enabled==enabled then return end
    R.enabled=enabled
    if R.on_change then R.on_change(enabled) end
    if not enabled then R.release() end
    R.save()
end
do
    local ok,file=pcall(io.open,"MMDRise/player_user.json","rb")
    if ok and file then
        file:close()
        local good,data=pcall(json.load_file,"MMDRise/player_user.json")
        if good and type(data)=="table" then
            for _,k in ipairs({"enabled","hide_ui","mute_bgm"}) do if type(data[k])=="boolean" then R[k]=data[k] end end
            if type(data.play_key)=="number" and data.play_key%1==0 and data.play_key>=0 and data.play_key<=254 then R.play_key=data.play_key end
        end
    end
end
if type(re.on_script_reset)=="function" then re.on_script_reset(R.release) end
return R
