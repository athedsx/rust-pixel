local root = assert(app.params["root"])
local queue = assert(app.params["queue"])
local Panel = dofile(app.fs.joinPath(root, "aseprite-plugin", "panel.lua"))
local bridge = {}
local panel
local ok, message=pcall(function()
  local sprite=Sprite(16, 16, ColorMode.RGB)
  sprite.filename="RustPixelSidebarPreview.aseprite"
  local image=sprite.cels[1].image
  for y=2,10 do
    image:drawPixel(7, y, app.pixelColor.rgba(167, 220, 235, 255))
    image:drawPixel(8, y, app.pixelColor.rgba(98, 162, 189, 255))
  end
  for x=4,11 do image:drawPixel(x, 11, app.pixelColor.rgba(222, 169, 86, 255)) end
  for y=12,14 do image:drawPixel(7, y, app.pixelColor.rgba(133, 91, 70, 255)) end
  panel=Panel.new {
    bridge=bridge, queue_dir=queue, plugin_path=app.fs.joinPath(root, "aseprite-plugin"),
    config={}, preferences={provider="codex",codex_model="preview-model"}, managed=true, read_only=true,
    Bridge={read_json=function() return nil end,write_json=function() end},
  }
  panel.start_worker=function(self)
    self.ready=true; self.configured=false
    self.providers={}
    self.status="Previa visual: envio desativado."
    self.models={{id="preview-model",name="Modelo de demonstracao",default=true}}
    self:update_models()
  end
  panel.messages={{role="user",text="Crie uma espada 16x16 com brilho azul e guarda dourada."},
    {role="tool",text="Consultando o documento: concluido"},{role="tool",text="Criando sprite: concluido"},
    {role="assistant",text="Feito! Criei uma espada **16x16**, com lamina metalica, guarda dourada e cabo marrom.\n\nO sprite esta aberto no editor. Posso ajustar as cores ou criar uma animacao."}}
  panel:show()
  panel.editor:insert("Deixe o brilho mais azul.\nMantenha o tamanho e a silhueta.")
  panel:sync_bounds()
end)
if not ok then
  app.alert {title="Rust Pixel preview",text=tostring(message)}
end
