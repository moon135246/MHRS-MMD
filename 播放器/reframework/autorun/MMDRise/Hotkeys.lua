-- Single-press transport shortcut. No input/SDK polling while master is off.
local R=require('MMDRise.Session')
local H={ready=false,down=false,capturing=false}
local names={[8]='Backspace',[9]='Tab',[13]='Enter',[19]='Pause',[20]='Caps Lock',
 [32]='Space',[33]='Page Up',[34]='Page Down',[35]='End',[36]='Home',
 [37]='Left',[38]='Up',[39]='Right',[40]='Down',[45]='Insert',[46]='Delete',
 [106]='Num *',[107]='Num +',[109]='Num -',[110]='Num .',[111]='Num /',
 [144]='Num Lock',[145]='Scroll Lock',[186]=';',[187]='=',[188]=',',[189]='-',
 [190]='.',[191]='/',[192]='`',[219]='[',[220]='\\',[221]=']',[222]="'"}
for n=48,57 do names[n]=string.char(n) end
for n=65,90 do names[n]=string.char(n) end
for n=96,105 do names[n]='Num '..(n-96) end
for n=112,135 do names[n]='F'..(n-111) end
local keys={};for vk in pairs(names) do keys[#keys+1]=vk end;table.sort(keys)
function H.label() return names[R.play_key] or '未设置' end
function H.reset() H.ready=false;H.down=false;H.capturing=false;H.capture_ready=false end
function H.set(vk)
 if vk~=0 and not names[vk] then return false end
 R.play_key=vk;H.reset();R.save();return true
end
function H.begin() H.reset();H.capturing=true;H.deadline=os.clock()+15 end
local function focus()
 if not H.focus then
  local td=sdk.find_type_definition('via.Application')
  H.focus=assert(td and td:get_method('get_HasFocus'),'游戏焦点接口不可用')
 end
 return H.focus:call(nil)==true
end
local function down(vk) return reframework:is_key_down(vk)==true end
function H.tick(toggle)
 if not R.enabled then H.reset();return end
 if not H.capturing and not names[R.play_key] then H.ready=false;return end
 local ok,err=pcall(function()
  if not reframework or not focus() then H.ready=false;H.capture_ready=false;return end
  if H.capturing then
   if os.clock()>H.deadline or down(27) then H.reset();return end
   local held={};for _,vk in ipairs(keys) do if down(vk) then held[#held+1]=vk end end
   if not H.capture_ready then H.capture_ready=#held==0;return end
   if #held==1 then H.set(held[1]) elseif #held>1 then H.capture_ready=false end
   return
  end
  -- Match the standalone variant manager: REF visibility does not gate keys.
  local held=down(R.play_key)
  if not H.ready then H.ready=not held;H.down=held;return end
  local pressed=held and not H.down;H.down=held
  if pressed then toggle() end
 end)
 H.error=not ok and tostring(err) or nil
 if not ok then H.ready=false;H.capture_ready=false end
end
function H.draw()
 imgui.text('播放 / 暂停快捷键：'..H.label())
 if H.capturing then
  imgui.text('松开按键后，按新的单个键（Esc 取消，15 秒超时）。')
  if imgui.button('取消设置###mmd_key_cancel') then H.reset() end
 else
  if imgui.button('修改快捷键###mmd_key_bind') then H.begin() end
  imgui.same_line()
  if imgui.button('恢复 End###mmd_key_default') then H.set(0x23) end
  imgui.same_line()
  if imgui.button('禁用快捷键###mmd_key_disable') then H.set(0) end
 end
 imgui.text('REF 面板打开时也生效；总开关关闭时不响应。')
 if H.error then imgui.text('快捷键：'..H.error) end
end
if not names[R.play_key] and R.play_key~=0 then R.play_key=0x23 end
return H
