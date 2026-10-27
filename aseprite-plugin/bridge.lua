local Bridge = {}
Bridge.__index = Bridge

local function array(values)
  return #values > 0 and values or json.decode("[]")
end

-- Aseprite's encoder converts nested JsonObj values to null.
local function encode(value)
  if value == nil then return "null" end
  if type(value) ~= "table" then
    if type(value) == "userdata" then
      return assert(json.encode(value), "Unsupported JSON value: " .. tostring(value))
    end
    return json.encode({value}):sub(2, -2)
  end
  local parts = {}
  if #value > 0 then
    for i=1,#value do parts[#parts+1] = encode(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key,item in pairs(value) do
    parts[#parts+1] = encode(tostring(key)) .. ":" .. encode(item)
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

local function read_json(path)
  local file, message = io.open(path, "rb")
  assert(file, message)
  local contents = file:read("*a")
  file:close()
  return json.decode(contents)
end

local function write_json(path, value)
  local contents = encode(value)
  local pending = path .. ".tmp"
  local file, message = io.open(pending, "wb")
  assert(file, message)
  assert(file:write(contents))
  file:close()
  local renamed = os.rename(pending, path)
  if not renamed then
    os.remove(path)
    assert(os.rename(pending, path))
  end
end

local function rgba(color)
  return Color { r=color.r, g=color.g, b=color.b, a=color.a or 255 }
end

local function pixel_value(sprite, color)
  if sprite.colorMode == ColorMode.RGB then
    return app.pixelColor.rgba(color.r, color.g, color.b, color.a or 255)
  elseif sprite.colorMode == ColorMode.GRAY then
    local gray = math.floor(color.r * 0.299 + color.g * 0.587 + color.b * 0.114 + 0.5)
    return app.pixelColor.graya(gray, color.a or 255)
  end
  if (color.a or 255) == 0 then return sprite.transparentColor end
  local palette = sprite.palettes[1]
  local best, distance = 0, math.huge
  for i=0,#palette-1 do
    local current = palette:getColor(i)
    local d = (current.red-color.r)^2 + (current.green-color.g)^2 + (current.blue-color.b)^2
    if i ~= sprite.transparentColor and d < distance then
      best, distance = i, d
    end
  end
  return best
end

local function set_palette(sprite, data)
  local palette = Palette(#data.colors)
  for i,color in ipairs(data.colors) do palette:setColor(i-1, rgba(color)) end
  sprite:setPalette(palette)
end

local function image_layers(layers, result)
  result = result or {}
  for _,layer in ipairs(layers) do
    if layer.isGroup then image_layers(layer.layers, result)
    elseif layer.isImage and not layer.isTilemap then result[#result+1] = layer end
  end
  return result
end

local function find_layer(sprite, name)
  for _,layer in ipairs(image_layers(sprite.layers)) do
    if layer.name == name then return layer end
  end
  error("Layer not found: " .. tostring(name))
end

local function put(image, x, y, color)
  if x >= 0 and y >= 0 and x < image.width and y < image.height then
    image:drawPixel(x, y, color)
  end
end

local function draw_line(image, x0, y0, x1, y1, color)
  local dx, dy = math.abs(x1-x0), -math.abs(y1-y0)
  local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    put(image, x0, y0, color)
    if x0 == x1 and y0 == y1 then break end
    local e2 = err*2
    if e2 >= dy then err=err+dy; x0=x0+sx end
    if e2 <= dx then err=err+dx; y0=y0+sy end
  end
end

local function flood_fill(image, x, y, color)
  if x < 0 or y < 0 or x >= image.width or y >= image.height then return end
  local original = image:getPixel(x, y)
  if original == color then return end
  local pending = { {x, y} }
  image:drawPixel(x, y, color)
  while #pending > 0 do
    local point = table.remove(pending)
    for _,next_point in ipairs({
      {point[1]-1, point[2]}, {point[1]+1, point[2]},
      {point[1], point[2]-1}, {point[1], point[2]+1},
    }) do
      local xx, yy = next_point[1], next_point[2]
      if xx >= 0 and yy >= 0 and xx < image.width and yy < image.height
        and image:getPixel(xx, yy) == original then
        image:drawPixel(xx, yy, color)
        pending[#pending+1] = next_point
      end
    end
  end
end

local function draw(image, sprite, op)
  local color = op.color and pixel_value(sprite, op.color)
  if op.op == "put_pixel" then
    put(image, op.x, op.y, color)
  elseif op.op == "line" then
    draw_line(image, op.x0, op.y0, op.x1, op.y1, color)
  elseif op.op == "rect" or op.op == "h_line" or op.op == "v_line" or op.op == "dither" then
    local width = op.op == "v_line" and 1 or op.width
    local height = op.op == "h_line" and 1 or op.height
    local a = op.color_a and pixel_value(sprite, op.color_a)
    local b = op.color_b and pixel_value(sprite, op.color_b)
    local bayer = { {0, 0.5}, {0.75, 0.25} }
    for y=op.y,math.min(op.y+height, image.height)-1 do
      for x=op.x,math.min(op.x+width, image.width)-1 do
        local value = color
        if op.op == "dither" then
          value = bayer[y%2+1][x%2+1] < op.density and a or b
        end
        put(image, x, y, value)
      end
    end
  elseif op.op == "flood_fill" then
    flood_fill(image, op.x, op.y, color)
  elseif op.op == "clear" then
    image:clear(sprite.colorMode == ColorMode.INDEXED and sprite.transparentColor or 0)
  else
    error("Unsupported operation: " .. tostring(op.op))
  end
end

local function apply_ops(sprite, ops, default_frame, default_layer, all_frames)
  local buffers = {}
  for _,op in ipairs(ops) do
    if op.op == "set_palette" then
      set_palette(sprite, op.palette)
    else
      local layer = op.layer and find_layer(sprite, op.layer) or default_layer
      assert(layer, "No image layer available")
      assert(layer.isEditable, "Layer is locked: " .. layer.name)
      local first, last
      if op.frame ~= nil then first=op.frame; last=first
      elseif all_frames then first=0; last=#sprite.frames-1
      else first=default_frame; last=first end
      assert(first >= 0 and last < #sprite.frames, "Frame index is outside the sprite")
      for index=first,last do
        local frame_index = assert(math.tointeger(index), "Frame index must be an integer")
        local key = tostring(layer.id) .. ":" .. frame_index
        local buffer = buffers[key]
        if not buffer then
          local image = Image(sprite.spec)
          local cel = layer:cel(frame_index+1)
          if cel then image:drawImage(cel.image, cel.position) end
          buffer = { image=image, layer=layer, frame=frame_index+1, cel=cel }
          buffers[key] = buffer
        end
        draw(buffer.image, sprite, op)
      end
    end
  end
  for _,buffer in pairs(buffers) do
    if buffer.cel then
      buffer.cel.image = buffer.image
      buffer.cel.position = Point(0, 0)
    else
      sprite:newCel(buffer.layer, buffer.frame, buffer.image, Point(0, 0))
    end
  end
end

function Bridge.new(queue_dir, version)
  local self = setmetatable({ queue_dir=queue_dir, ids={}, enabled=true, version=tostring(version or "0.5.0") }, Bridge)
  for _,name in ipairs({"inbox", "outbox", "ack", "assets"}) do
    assert(app.fs.makeAllDirectories(app.fs.joinPath(queue_dir, name)), "Cannot create bridge directory")
  end
  return self
end

function Bridge:id(sprite)
  if not self.ids[sprite.id] then
    self.ids[sprite.id] = tostring(Uuid()):gsub("[^%w-]", ""):lower()
  end
  return self.ids[sprite.id]
end

function Bridge:sprite_info(sprite)
  local layers = {}
  for _,layer in ipairs(image_layers(sprite.layers)) do
    layers[#layers+1] = {name=layer.name, visible=layer.isVisible, opacity=layer.opacity}
  end
  return {
    id=self:id(sprite), name=app.fs.fileName(sprite.filename),
    width=sprite.width, height=sprite.height, frames=#sprite.frames,
    layers=array(layers),
  }
end

function Bridge:context()
  local sprites, palettes, active = {}, {}, nil
  for index,sprite in ipairs(app.sprites) do
    sprites[#sprites+1] = self:sprite_info(sprite)
    if app.sprite == sprite then active=index-1 end
    local palette, colors = sprite.palettes[1], {}
    for i=0,#palette-1 do
      local color = palette:getColor(i)
      colors[#colors+1] = {r=color.red, g=color.green, b=color.blue, a=color.alpha}
    end
    palettes[#palettes+1] = {name=app.fs.fileName(sprite.filename), colors=array(colors)}
  end
  return {sprites=array(sprites), active_sprite=active, palettes=array(palettes)}
end

function Bridge:export(sprite)
  local id = self:id(sprite)
  local base = app.fs.joinPath(self.queue_dir, "assets", id)
  sprite:saveCopyAs(base .. ".aseprite")
  local preview = Image(sprite.width, sprite.height, ColorMode.RGB)
  preview:drawSprite(sprite, 1)
  preview:saveAs(base .. ".png")
  local tags = {}
  for _,tag in ipairs(sprite.tags) do tags[#tags+1] = tag.name end
  local info = self:sprite_info(sprite)
  info.asset_type = "sprite"
  info.path = base .. ".aseprite"
  info.tags = array(tags)
  write_json(base .. ".json", info)
  return info
end

function Bridge:execute(command)
  if command.type == "export_context" then
    return self:context()
  elseif command.type == "import_sprite" then
    local sprite = app.open(command.source_path)
    assert(sprite, "Cannot open PNG")
    sprite.filename = command.sprite_name .. ".aseprite"
    return self:export(sprite)
  elseif command.type == "create_sprite" then
    local recipe = command.recipe
    local sprite = Sprite(recipe.width, recipe.height, ColorMode.RGB)
    sprite.filename = command.sprite_name .. ".aseprite"
    local ok, message = pcall(function()
      app.transaction("Rust Pixel: Create sprite", function()
        sprite.layers[1].name = recipe.layers[1]
        for i=2,#recipe.layers do
          local layer = sprite:newLayer()
          layer.name = recipe.layers[i]
        end
        for i=2,recipe.frames do sprite:newEmptyFrame(i) end
        if recipe.palette then set_palette(sprite, recipe.palette) end
        apply_ops(sprite, recipe.ops, 0, sprite.layers[1], true)
      end)
    end)
    if not ok then sprite:close(); error(message) end
    app.sprite = sprite
    return self:export(sprite)
  elseif command.type == "edit_sprite" then
    local sprite
    for _,candidate in ipairs(app.sprites) do
      if self:id(candidate) == command.sprite_id then sprite=candidate; break end
    end
    assert(sprite, "Sprite is not open. Refresh aseprite_context.")
    local frame = command.frame
    if frame == nil then frame=(app.sprite == sprite and app.frame.frameNumber-1 or 0) end
    local layer = command.layer and find_layer(sprite, command.layer)
      or (app.sprite == sprite and app.layer and app.layer.isImage and not app.layer.isTilemap and app.layer)
      or image_layers(sprite.layers)[1]
    app.transaction("Rust Pixel: Edit sprite", function()
      apply_ops(sprite, command.ops, frame, layer, false)
    end)
    app.refresh()
    return self:export(sprite)
  end
  error("Unknown bridge command: " .. tostring(command.type))
end

function Bridge:heartbeat()
  if self.last_heartbeat == os.time() and self.last_enabled == self.enabled then return end
  write_json(app.fs.joinPath(self.queue_dir, "outbox", "status.json"), {
    updated_at=os.time(), enabled=self.enabled, version=self.version,
  })
  self.last_heartbeat, self.last_enabled = os.time(), self.enabled
end

function Bridge:process()
  self:heartbeat()
  if not self.enabled then return end
  local inbox = app.fs.joinPath(self.queue_dir, "inbox")
  local files = app.fs.listFiles(inbox)
  table.sort(files)
  for _,name in ipairs(files) do
    if name:match("%.cmd%.json$") then
      local path = app.fs.joinPath(inbox, name)
      local decoded, wrapper = pcall(read_json, path)
      if decoded and type(wrapper.id) == "string" and wrapper.id:match("^[%w-]+$") then
        local ack_path = app.fs.joinPath(self.queue_dir, "ack", wrapper.id .. ".json")
        if not app.fs.isFile(ack_path) then
          local ok, result = pcall(function()
            assert(wrapper.expires_at and wrapper.expires_at >= os.time(), "Command expired")
            return self:execute(wrapper.command)
          end)
          write_json(ack_path, {
            command_id=wrapper.id, success=ok,
            message=ok and "Completed" or tostring(result), data=ok and result or nil,
          })
        end
      end
      os.remove(path)
    end
  end
end

Bridge.read_json = read_json
Bridge.encode = encode
Bridge.write_json = write_json
return Bridge
