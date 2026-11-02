-- Exact binary64 storage removes hundreds of thousands of GC-traced tables.
-- A bounded cache restores the same public frame shape for the pose solver.
local F={}
local function layout(v)
 if type(v)=='number' then return true end
 if type(v)~='table' then error('non-numeric frame') end
 local keys={};for k in pairs(v) do keys[#keys+1]=k end
 table.sort(keys,function(a,b) if type(a)==type(b) then return a<b end;return type(a)<type(b) end)
 local node={keys=keys,children={}}
 for i,k in ipairs(keys) do node.children[i]=layout(v[k]) end
 return node
end
local function flatten(node,v,out)
 if node==true then assert(type(v)=='number');out[#out+1]=v;return end
 assert(type(v)=='table');local count=0;for _ in pairs(v) do count=count+1 end;assert(count==#node.keys)
 for i,k in ipairs(node.keys) do flatten(node.children[i],v[k],out) end
end
local function restore(node,values,pos)
 if node==true then return values[pos],pos+1 end
 local out={};for i,k in ipairs(node.keys) do out[k],pos=restore(node.children[i],values,pos) end
 return out,pos
end
function F.pack(frames)
 if type(frames)~='table' or #frames==0 or not string.pack then return frames end
 local ok,result=pcall(function()
  local schema=layout(frames[1]);local first={};flatten(schema,frames[1],first)
  local format='<'..string.rep('d',#first);local packed={}
  for i=1,#frames do local values={};flatten(schema,frames[i],values);packed[i]=string.pack(format,table.unpack(values)) end
  local cache,order={},{}
  return setmetatable({}, {__len=function() return #packed end,__index=function(_,i)
   if type(i)~='number' or not packed[i] then return nil end
   if cache[i] then return cache[i] end
   local values={string.unpack(format,packed[i])};local frame=restore(schema,values,1)
   if #order>=8 then cache[table.remove(order,1)]=nil end
   order[#order+1]=i;cache[i]=frame;return frame
  end})
 end)
 -- Unusual legacy schemas remain intact rather than dropping any fields.
 return ok and result or frames
end
function F.compact(anim)
 anim.frames=F.pack(anim.frames)
 if anim.fingers then anim.fingers=F.pack(anim.fingers) end
end
return F
