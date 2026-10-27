local root = assert(app.params["root"])
local queue_dir = assert(app.params["queue"])
local Bridge = dofile(app.fs.joinPath(root, "aseprite-plugin", "bridge.lua"))
local bridge = Bridge.new(queue_dir)
local execute=bridge.execute
local trace={}
bridge.execute=function(self, command)
  local result=execute(self, command)
  if command.type == "create_sprite" or command.type == "edit_sprite" then
    local pixels={}
    for i=1,#app.sprite.frames do
      local cel=app.sprite.layers[1]:cel(i)
      pixels[#pixels+1]={frame=i, image=cel and tostring(cel.image),
        pixel=cel and cel.image:getPixel(1,1), edit=cel and cel.image:getPixel(3,3)}
    end
    trace[#trace+1]={command=command, pixels=pixels}
    Bridge.write_json(app.fs.joinPath(queue_dir, "trace.json"), trace)
  end
  return result
end
local deadline, next_poll = os.time()+45, 0
while os.time() < deadline do
  if app.fs.isFile(app.fs.joinPath(queue_dir, "stop")) then break end
  if os.clock() >= next_poll then
    bridge:process()
    next_poll = os.clock()+0.05
  end
end

local ok, message = pcall(function()
  assert(app.fs.isFile(app.fs.joinPath(queue_dir, "stop")), "MCP test host timed out")
  local sprite = app.sprite
  assert(sprite and #sprite.frames == 2 and #sprite.layers == 2, "MCP recipe lost frames or layers")
  assert(sprite.layers[1]:cel(1).image:getPixel(3, 3) == app.pixelColor.rgba(0, 255, 0, 255), "MCP edit did not reach Aseprite")
  assert(sprite.layers[1]:cel(2).image:getPixel(1, 1) == app.pixelColor.rgba(0, 255, 0, 255), "MCP frame operation failed")
  assert(sprite.layers[1]:cel(2).image:getPixel(3, 3) == app.pixelColor.rgba(255, 0, 0, 255), "MCP frame background was overwritten")
  assert(sprite.layers[2]:cel(1).image:getPixel(2, 2) == app.pixelColor.rgba(0, 0, 255, 128), "MCP layer operation failed")
end)
bridge.enabled=false
bridge:heartbeat()
local result = assert(io.open(app.fs.joinPath(queue_dir, "host-result.json"), "wb"))
result:write(Bridge.encode({success=ok, error=not ok and tostring(message) or nil}))
result:close()
if not ok then error(message) end
