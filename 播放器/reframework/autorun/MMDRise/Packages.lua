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
 if PATHS.revision and PATHS.paths[name]==nil then return false end
 local path=PATHS.path(name);if not path then return false end
 local f=io.open(path,'rb');if not f then return false end
 local length=f:seek('end');f:close();return not size or length==size
end
local function valid_file(name)
 if type(name)~='string' or name:find('[%z\\:]') or name:find('..',1,true) or name:sub(1,1)=='/' then return false end
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
 table.sort(files)
 local docs={['library.json']=read('library.json',{version=1,clips={}}),
  ['audio_library.json']=read('audio_library.json',{version=1,tracks={}}),
  ['camera_library.json']=read('camera_library.json',{version=1,tracks={}})}
 assert(type(docs['library.json'].clips)=='table','曲库格式无效')
 assert(type(docs['audio_library.json'].tracks)=='table' and type(docs['camera_library.json'].tracks)=='table','媒体曲库格式无效')
 local before={};for name in pairs(docs) do before[name]=read(name,nil) end
 local owners=read('managed_packages.json',{version=1,tracks={}})
 assert(type(owners.tracks)=='table','单曲包登记格式无效')
 local owners_before=read('managed_packages.json',nil)
 local warnings,affected={},{}
 -- Remove only entries previously owned by a descriptor that disappeared.
 -- A direct reimport with different metadata keeps its own entry.
 for slug,owner in pairs(owners.tracks) do
  if type(owner)=='table' and type(owner.descriptor)=='string' and not exists(owner.descriptor) then
   local clips=docs['library.json'].clips
   for i=#clips,1,-1 do if clips[i].slug==slug and same(clips[i],owner.clip) then table.remove(clips,i);affected['library.json']=true end end
   for _,kind in ipairs({'audio','camera'}) do
    local doc=docs[kind..'_library.json']
    if owner[kind] and same(doc.tracks[slug],owner[kind]) then doc.tracks[slug]=nil;affected[kind..'_library.json']=true end
   end
   owners.tracks[slug]=nil
  end
 end
 for _,path in ipairs(files) do
  local filename=path:match('([^/\\]+)$')
  local slug=filename
  if filename then
   local ok,err=pcall(function()
    if not exists(filename) then return end
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
     assert(valid_file(name) and type(size)=='number' and size>0,'单曲包文件清单无效：'..tostring(name))
     local optional=(type(pkg.audio)=='table' and name==pkg.audio.file) or (type(pkg.camera)=='table' and name==pkg.camera.file)
     if not optional or exists(name) then assert(exists(name,size),'单曲包文件未复制完整：'..tostring(name)) end
    end
    if pkg.audio then assert(type(pkg.audio)=='table' and valid_file(pkg.audio.file) and pkg.audio.file:match('^music/') and pkg.files[pkg.audio.file],'音轨注册信息无效') end
    if pkg.camera then assert(type(pkg.camera)=='table' and valid_file(pkg.camera.file) and not pkg.camera.file:find('/',1,true) and pkg.files[pkg.camera.file],'镜头注册信息无效') end
    local clips=docs['library.json'].clips;local index
    for i,c in ipairs(clips) do if c.slug==slug then index=i;break end end
    clips[index or #clips+1]=pkg.clip
    affected['library.json']=true
    for _,kind in ipairs({'audio','camera'}) do
     local track=pkg[kind];local doc=docs[kind..'_library.json']
     if track then
      if exists(track.file) then doc.tracks[slug]=track;affected[kind..'_library.json']=true
      elseif doc.tracks[slug] and doc.tracks[slug].file==track.file then doc.tracks[slug]=nil;affected[kind..'_library.json']=true end
     end
    end
    owners.tracks[slug]={descriptor=filename,clip=pkg.clip,audio=pkg.audio,camera=pkg.camera}
   end)
   if not ok then warnings[#warnings+1]=tostring(slug)..'：'..tostring(err) end
  end
 end
 -- Legacy merged entries have no ownership record. Missing originals must
 -- still disappear even if an old Unicode runtime alias remains on disk.
 local clips=docs['library.json'].clips
 for i=#clips,1,-1 do
  local clip=clips[i];local body=clip.file or 'dance_'..tostring(clip.slug)..'.json'
  if not valid_file(body) or not exists(body) then
   table.remove(clips,i);affected['library.json']=true
   for _,kind in ipairs({'audio','camera'}) do docs[kind..'_library.json'].tracks[clip.slug]=nil;affected[kind..'_library.json']=true end
  end
 end
 for _,kind in ipairs({'audio','camera'}) do
  local name=kind..'_library.json'
  for slug,track in pairs(docs[name].tracks) do
   if type(track)~='table' or not valid_file(track.file) or not exists(track.file) then docs[name].tracks[slug]=nil;affected[name]=true end
  end
 end
 -- If an importer/deletion just changed a manifest, leave its newer state
 -- intact and retry from fresh files on the next explicit refresh.
 for name in pairs(docs) do assert(same(read(name,nil),before[name]),'曲库刚被更新，请再次刷新') end
 for _,name in ipairs({'audio_library.json','camera_library.json','library.json'}) do
  if affected[name] and not same(before[name],docs[name]) then
   assert(json.dump_file('MMDRise/'..name,docs[name])~=false,'单曲包注册失败')
  end
 end
 if not same(owners_before,owners) then assert(json.dump_file('MMDRise/managed_packages.json',owners)~=false,'单曲包登记更新失败') end
 P.status=table.concat(warnings,'\n')
end
function P.sync(refresh)
 if refresh~=false then PATHS.request() end
 local ok,err=pcall(sync)
 if not ok then P.status=tostring(err) end
 if P.status~='' then log.info('[MMDRise Packages] '..P.status) end
end
return P
