-- UTF-8 logical filenames, native ANSI byte paths, and portable audio aliases.
local P={paths={},packages={},status='',serial=0}
function P.reload()
 local ok,v=pcall(json.load_file,'MMDRise/paths.json')
 if ok and type(v)=='table' and v.version==1 then P.paths=v.paths or {};P.packages=v.packages or {};P.revision=v.revision end
end
function P.relative(name)
 if type(name)~='string' or name:find('[%z\\:]') or name:find('..',1,true) or name:sub(1,1)=='/' then return nil end
 local row=P.paths[name]
 if row and type(row.hex)=='string' and #row.hex%2==0 and not row.hex:find('[^%da-f]') then
  return (row.hex:gsub('..',function(b) return string.char(tonumber(b,16)) end))
 end
 if not name:find('[\128-\255]') then return name end
 return nil
end
function P.path(name) local relative=P.relative(name);return relative and 'MMDRise/'..relative end
function P.media(name) local row=P.paths[name];return row and row.media or name end
function P.read(name)
 local path=P.path(name);if not path then return nil end
 return json.load_file(path)
end
function P.request()
 P.serial=P.serial+1;P.pending=tostring(os.time())..'_paths_'..math.floor(os.clock()*1000)..'_'..P.serial
 P.deadline=os.clock()+10;P.next_poll=0
 local ok,result=pcall(json.dump_file,'MMDRise/library3_request.json',{id=P.pending,action='index'})
 if not ok or result==false then P.pending=nil;P.status='无法请求资源索引：'..tostring(result) end
end
function P.poll(watch)
 if not P.pending and not watch then return false end
 if os.clock()<(P.next_poll or 0) then return false end
 P.next_poll=os.clock()+(P.pending and .2 or 2.)
 local ok,v=pcall(json.load_file,'MMDRise/library3_status.json')
 if ok and type(v)=='table' and v.id==P.pending then
  P.pending=nil
  if v.ok then P.reload();P.status='';return true end
  P.status='中文资源索引失败：'..tostring(v.error);return false
 end
 if ok and type(v)=='table' and v.ready and v.version==3 and type(v.timestamp)=='number' and math.abs(os.time()-v.timestamp)<6 and type(v.index_revision)=='string' and v.index_revision~=P.revision then
  P.reload();return true
 end
 if P.pending and os.clock()>P.deadline then P.pending=nil;P.status='曲库组件未连接，请用 1.0.3 转换工具更新游戏组件。' end
 return false
end
P.reload()
return P
