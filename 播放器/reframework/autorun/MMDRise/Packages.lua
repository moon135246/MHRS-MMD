-- Merge independent song registrations at startup/refresh, never per frame.
local P={status=''}
local PATHS=require('MMDRise.Paths')
local function read(name,fallback)
 local path=PATHS.path(name);if not path then return fallback end
 local f=io.open(path,'rb');if not f then return fallback end;f:close()
 local value=json.load_file(path)
 assert(type(value)=='table','无法读取 '..name);return value
end
local function same(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not same(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function exists(name,size)
 local path=PATHS.path(name);if not path then return false end
 local f=io.open(path,'rb');if not f then return false end
 local length=f:seek('end');f:close();return not size or length==size
end
local function valid_file(name)
 if type(name)~='string' or not PATHS.path(name) then return false end
 if name:match('^music/[^/]+%.wav$') or name:match('^music/[^/]+%.mp3$') or name:match('^music/[^/]+%.flac$') then return true end
 return not name:find('/',1,true) and (name:match('^dance_[^/]+%.json$') or name:match('^camera_%x+%.json$') or
  name:match('_motion%.json$') or name:match('_fingers%.json$') or name:match('_report%.json$') or name:match('_camera%.json$'))
end
local function sync()
 P.status=''
 if not fs or type(fs.glob)~='function' then return end
 local files={};local seen={}
 for _,name in ipairs(PATHS.packages) do files[#files+1]=name;seen[name]=true end
 for _,name in ipairs(fs.glob([[MMDRise\\package_[A-Za-z0-9_-]+\.json]]) or {}) do
  name=name:match('([^/\\]+)$');if not seen[name] then files[#files+1]=name end
 end
 if #files==0 then return end
 table.sort(files)
 local docs={['library.json']=read('library.json',{version=1,clips={}}),
  ['audio_library.json']=read('audio_library.json',{version=1,tracks={}}),
  ['camera_library.json']=read('camera_library.json',{version=1,tracks={}})}
 assert(type(docs['library.json'].clips)=='table','曲库格式无效')
 assert(type(docs['audio_library.json'].tracks)=='table' and type(docs['camera_library.json'].tracks)=='table','媒体曲库格式无效')
 local before={};for name in pairs(docs) do before[name]=read(name,nil) end
 local warnings,affected={},{}
 for _,path in ipairs(files) do
  local filename=path:match('([^/\\]+)$')
  local slug=filename
  if filename then
   local ok,err=pcall(function()
    local pkg=read(filename,{})
    slug=type(pkg.clip)=='table' and pkg.clip.slug
    assert(type(slug)=='string' and slug:match('^[%w][%w_%-]*$') and #slug<=64,'曲目 ID 无效')
    assert(pkg.schema=='mmdrise.package/1' and type(pkg.clip)=='table' and pkg.clip.slug==slug and type(pkg.clip.label)=='string','单曲包注册信息无效')
    -- Native deletion moves the canonical motion away. A leftover descriptor
    -- cannot resurrect it; copying the complete package back can reinstall it.
    local body=pkg.clip.file or 'dance_'..slug..'.json'
    assert(valid_file(body),'动作文件路径无效')
    if not exists(body) then return end
    assert(type(pkg.files)=='table' and pkg.files[body],'单曲包缺少文件清单')
    for name,size in pairs(pkg.files) do
     assert(valid_file(name) and type(size)=='number' and size>0 and exists(name,size),'单曲包文件未复制完整：'..tostring(name))
    end
    if pkg.audio then assert(type(pkg.audio)=='table' and valid_file(pkg.audio.file) and pkg.audio.file:match('^music/') and pkg.files[pkg.audio.file],'音轨注册信息无效') end
    if pkg.camera then assert(type(pkg.camera)=='table' and valid_file(pkg.camera.file) and not pkg.camera.file:find('/',1,true) and pkg.files[pkg.camera.file],'镜头注册信息无效') end
    local clips=docs['library.json'].clips;local index
    for i,c in ipairs(clips) do if c.slug==slug then index=i;break end end
    clips[index or #clips+1]=pkg.clip
    affected['library.json']=true
    if pkg.audio then docs['audio_library.json'].tracks[slug]=pkg.audio;affected['audio_library.json']=true end
    if pkg.camera then docs['camera_library.json'].tracks[slug]=pkg.camera;affected['camera_library.json']=true end
   end)
   if not ok then warnings[#warnings+1]=tostring(slug)..'：'..tostring(err) end
  end
 end
 -- If an importer/deletion just changed a manifest, leave its newer state
 -- intact and retry from fresh files on the next explicit refresh.
 for name in pairs(docs) do assert(same(read(name,nil),before[name]),'曲库刚被更新，请再次刷新') end
 for _,name in ipairs({'audio_library.json','camera_library.json','library.json'}) do
  if affected[name] and not same(before[name],docs[name]) then
   if before[name] then assert(json.dump_file('MMDRise/'..name..'.before_packages.json',before[name])~=false,'单曲包备份失败') end
   assert(json.dump_file('MMDRise/'..name,docs[name])~=false,'单曲包注册失败')
  end
 end
 P.status=table.concat(warnings,'\n')
end
function P.sync(refresh)
 if refresh~=false then PATHS.request() end
 local ok,err=pcall(sync)
 if not ok then P.status=tostring(err) end
 if P.status~='' then log.info('[MMDRise Packages] '..P.status) end
end
return P
