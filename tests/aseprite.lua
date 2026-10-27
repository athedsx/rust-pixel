local root = assert(app.params["root"], "root parameter is required")
local queue_dir = assert(app.params["queue"], "queue parameter is required")
local result_path = assert(app.params["result"], "result parameter is required")
local Bridge = dofile(app.fs.joinPath(root, "aseprite-plugin", "bridge.lua"))

local function run()
  dofile(app.fs.joinPath(root, "tests", "panel-lifecycle.lua"))(root)
  dofile(app.fs.joinPath(root, "tests", "ui-model.lua"))(root)
  dofile(app.fs.joinPath(root, "tests", "panel-ui.lua"))(root, queue_dir)
  local bridge = Bridge.new(queue_dir, app.version)
  assert(type(bridge.version) == "string", "Native Version objects must be normalized before JSON serialization")
  bridge:process()
  assert(Bridge.read_json(app.fs.joinPath(queue_dir, "outbox", "status.json")).version == tostring(app.version),
    "Heartbeat must serialize native Version objects as text")
  local context = bridge:context()
  assert(#context.sprites == 0, "Expected an empty initial context")
  assert(Bridge.encode(context):match('"sprites"%s*:%s*%[%s*%]'), "Empty sprite list must encode as an array")

  local red = {r=255, g=0, b=0, a=255}
  local green = {r=0, g=255, b=0, a=255}
  local blue = {r=0, g=0, b=255, a=128}
  local info = bridge:execute(json.decode(Bridge.encode {
    type="create_sprite", sprite_name="Bridge test",
    recipe={width=8, height=8, frames=2, layers={"base", "details"}, ops={
      {op="rect", x=0, y=0, width=8, height=8, color=red},
      {op="put_pixel", x=1, y=1, color=green, frame=1},
      {op="put_pixel", x=2, y=2, color=blue, layer="details"},
    }},
  }))
  local sprite = app.sprite
  assert(info.width == 8 and info.frames == 2, "Wrong sprite dimensions")
  assert(#sprite.layers == 2 and #sprite.frames == 2, "Layers and frames were not preserved")
  assert(sprite.layers[1].name == "base" and sprite.layers[2].name == "details", "Wrong layer order")
  assert(sprite.layers[1]:cel(1).image:getPixel(1, 1) == app.pixelColor.rgba(255, 0, 0, 255), "Unexpected first frame")
  assert(sprite.layers[1]:cel(2).image:getPixel(1, 1) == app.pixelColor.rgba(0, 255, 0, 255), "Frame-specific operation failed")
  assert(sprite.layers[1]:cel(2).image:getPixel(3, 3) == app.pixelColor.rgba(255, 0, 0, 255), "JSON frame indices must share the same image buffer")
  assert(sprite.layers[2]:cel(1).image:getPixel(2, 2) == app.pixelColor.rgba(0, 0, 255, 128), "Layer-specific operation failed")
  assert(app.fs.isFile(info.path), "Native asset was not exported")
  assert(app.fs.isFile(app.fs.joinPath(queue_dir, "assets", info.id .. ".png")), "PNG was not exported")

  bridge:execute {
    type="edit_sprite", sprite_id=info.id, frame=0, layer="base", ops={
      {op="clear"},
      {op="line", x0=0, y0=0, x1=7, y1=7, color=red},
      {op="h_line", x=2, y=0, width=3, color=green},
      {op="v_line", x=0, y=2, height=3, color=green},
      {op="dither", x=5, y=0, width=2, height=2, color_a=red, color_b=green, density=0.5},
      {op="flood_fill", x=7, y=0, color=green},
      {op="set_palette", palette={name="test", colors={red, green}}},
    },
  }
  local image = sprite.layers[1]:cel(1).image
  assert(image:getPixel(2, 0) == app.pixelColor.rgba(0, 255, 0, 255), "Horizontal line failed")
  assert(image:getPixel(0, 2) == app.pixelColor.rgba(0, 255, 0, 255), "Vertical line failed")
  assert(image:getPixel(6, 0) == app.pixelColor.rgba(255, 0, 0, 255), "Dither failed")
  assert(image:getPixel(7, 0) == app.pixelColor.rgba(0, 255, 0, 255), "Flood fill failed")
  assert(#sprite.palettes[1] == 2, "Palette operation failed")
  assert(sprite.layers[1]:cel(2).image:getPixel(1, 1) == app.pixelColor.rgba(0, 255, 0, 255),
    "Editing one frame must not overwrite another frame")

  local before = image:clone()
  local ok = pcall(function()
    bridge:execute {type="edit_sprite", sprite_id=info.id, frame=99, layer="base", ops={{op="clear"}}}
  end)
  assert(not ok, "Out-of-range edit must fail")
  assert(sprite.layers[1]:cel(1).image:isEqual(before), "Failed edit changed the sprite")

  context = bridge:context()
  assert(#context.sprites == 1 and context.sprites[1].id == info.id, "Context IDs must remain stable")
  local exported = Sprite {fromFile=info.path}
  assert(#exported.layers == 2 and #exported.frames == 2, "Native snapshot lost layers or frames")
  exported:close()

  local expired_path = app.fs.joinPath(queue_dir, "inbox", "expired.cmd.json")
  local file = assert(io.open(expired_path, "wb"))
  file:write(json.encode {id="expired-test", expires_at=os.time()-10, command={type="export_context"}})
  file:close()
  bridge:process()
  local ack = Bridge.read_json(app.fs.joinPath(queue_dir, "ack", "expired-test.json"))
  assert(ack.success == false, "Expired command was executed")
  sprite:close()
  return {success=true, version=tostring(app.version)}
end

local ok, result = pcall(run)
local file = assert(io.open(result_path, "wb"))
file:write(json.encode(ok and result or {success=false, error=tostring(result)}))
file:close()
if not ok then error(result) end
