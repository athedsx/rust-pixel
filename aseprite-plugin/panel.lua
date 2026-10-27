local Panel = {}
Panel.__index = Panel
local providers={Codex="codex", OpenRouter="openrouter"}
local provider_names={codex="Codex", openrouter="OpenRouter"}

local function uuid() return tostring(Uuid()):lower() end
local function shorten(text, length)
  if utf8.len(text) <= length then return text end
  return text:sub(1, utf8.offset(text, length-2)-1) .. "..."
end

function Panel.new(options)
  local self = setmetatable(options, Panel)
  self.ui=dofile(app.fs.joinPath(self.plugin_path, "ui.lua"))
  dofile(app.fs.joinPath(self.plugin_path, "panel-view.lua"))(Panel, {Dialog=Dialog, app=app, Timer=Timer})
  self.root = app.fs.joinPath(self.queue_dir, "assistant")
  for _,directory in ipairs({"requests", "responses", "conversations", "references"}) do
    app.fs.makeAllDirectories(app.fs.joinPath(self.root, directory))
  end
  self.thread_id = self.preferences.thread_id or uuid()
  self.preferences.thread_id = self.thread_id
  self.provider = self.preferences.provider or "openrouter"
  if not provider_names[self.provider] then self.provider="openrouter" end
  self.model = self.preferences[self.provider .. "_model"]
    or (self.provider == "openrouter" and (self.preferences.model or "openrouter/auto") or "")
  self.providers={}
  self.models, self.messages, self.pending = {}, {}, {}
  self.labels, self.model_ids = {}, {}
  self.scroll, self.max_scroll, self.ready, self.configured = 0, 0, false, false
  self.status = "Iniciando..."
  self.Bridge = self.Bridge or getmetatable(self.bridge) or dofile(app.fs.joinPath(self.plugin_path, "bridge.lua"))
  self.editor=self.ui.editor(self.preferences.draft or "")
  self.mode=self.preferences.mode or "Agente"
  self.pinned=self.preferences.sidebar ~= false
  self.collapsed=self.preferences.collapsed == true
  self.follow_tail=true
  self.expanded_steps={}
  self.reference_images={}
  self.reference=self.preferences.reference_image
  if self.reference and not self:reference_thumbnail(self.reference) then
    self.reference=nil; self.preferences.reference_image=nil
  end
  local cached = self:read(app.fs.joinPath(self.root, self.provider == "codex" and "models-codex.json" or "models.json"))
  if cached then self.models=cached.models end
  self:update_models()
  return self
end

function Panel:read(path)
  if not app.fs.isFile(path) then return nil end
  local ok, value = pcall(self.Bridge.read_json, path)
  return ok and value or nil
end

function Panel:write(path, value) self.Bridge.write_json(path, value) end

function Panel:load_reference(path)
  assert(type(path) == "string" and app.fs.isFile(path), "Selecione uma imagem existente.")
  local file=assert(io.open(path,"rb"), "Nao foi possivel ler a imagem.")
  local size=file:seek("end"); file:close()
  assert(size and size <= 20*1024*1024, "A imagem deve ter no maximo 20 MB.")
  local image=assert(Image {fromFile=path}, "Formato de imagem nao suportado.")
  assert(image.width*image.height <= 16*1024*1024, "A imagem deve ter no maximo 16 megapixels.")
  local width,height=image.width,image.height
  local ratio=math.min(1,1024/math.max(width,height))
  if ratio < 1 then image:resize {width=math.max(1,math.floor(width*ratio)),height=math.max(1,math.floor(height*ratio)),method=image.colorMode == ColorMode.RGB and "bilinear" or nil} end
  if image.colorMode ~= ColorMode.RGB then
    local palette=image.colorMode == ColorMode.INDEXED and Palette {fromFile=path}
    local converted,colors=Image(image.width,image.height,ColorMode.RGB),{}
    for pixel in image:pixels() do
      local value=pixel()
      if not colors[value] then
        if palette then
          local color=palette:getColor(value)
          colors[value]=app.pixelColor.rgba(color.red,color.green,color.blue,color.alpha)
        else
          local gray=app.pixelColor.grayaV(value)
          colors[value]=app.pixelColor.rgba(gray,gray,gray,app.pixelColor.grayaA(value))
        end
      end
      converted:drawPixel(pixel.x,pixel.y,colors[value])
    end
    image=converted
  end
  return {name=app.fs.fileName(path),image=image,width=width,height=height}
end

function Panel:set_reference(value)
  if self.read_only or self.chat_job or self.connect_job then return false end
  if not value then
    self.reference=nil; self.preferences.reference_image=nil
    self.status="Referencia removida."
    self:update_controls()
    return true
  end
  local ok,reference=pcall(function()
    local candidate=type(value) == "string" and self:load_reference(value) or value
    local reference={id=uuid(),name=candidate.name}
    local path=app.fs.joinPath(self.root,"references",reference.id .. ".png")
    candidate.image:saveAs(path)
    assert(app.fs.isFile(path), "Nao foi possivel salvar a referencia.")
    return reference
  end)
  if not ok then self:add_error(tostring(reference)); return false end
  self.reference=reference; self.preferences.reference_image=reference
  self:reference_thumbnail(reference)
  self.status="Referencia anexada ao proximo pedido."
  self:update_controls()
  return true
end

function Panel:reference_thumbnail(reference)
  if not reference or type(reference.id) ~= "string" or #reference.id ~= 36
    or not reference.id:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then return nil end
  local cached=self.reference_images[reference.id]
  if cached ~= nil then return cached or nil end
  local ok,image=pcall(function()
    local path=app.fs.joinPath(self.root,"references",reference.id .. ".png")
    if not app.fs.isFile(path) then return nil end
    local loaded=Image {fromFile=path}
    if not loaded then return nil end
    local ratio=math.min(1,96/math.max(loaded.width,loaded.height))
    if ratio < 1 then loaded:resize {width=math.max(1,math.floor(loaded.width*ratio)),height=math.max(1,math.floor(loaded.height*ratio)),method="bilinear"} end
    return loaded
  end)
  self.reference_images[reference.id]=ok and image or false
  return ok and image or nil
end

function Panel:model_accepts_images()
  for _,model in ipairs(self.models) do
    if model.id == self.model then return model.vision ~= false end
  end
  return true
end

function Panel:run(action)
  if self.busy then return false end
  self.busy=true
  local ok, message=pcall(action)
  if not ok then
    self.poll_failed=true
    if self.timer then self.timer:stop() end
    self:add_error(tostring(message))
  end
  self.busy=false
  return ok
end

function Panel:poll()
  if self.poll_failed or self.busy then return end
  if not self:run(function() self:tick() end) then
    self.poll_failed=true
    if self.timer then self.timer:stop() end
  end
end

function Panel:request(action, values)
  local id = uuid()
  values = values or {}
  values.id, values.action = id, action
  values.provider=values.provider or self.provider
  self:write(app.fs.joinPath(self.root, "requests", id .. ".request.json"), values)
  self.pending[id] = {action=action, started=os.time(), provider=values.provider, thread_id=values.thread_id}
  return id
end

function Panel:start_worker()
  local status = self:read(app.fs.joinPath(self.root, "status.json"))
  if status and status.ready and os.time()-status.updated_at < 5 then return end
  local executable = self.config.agent_path
  if not executable or not app.fs.isFile(executable) then
    self.status = "Atualize a instalacao do Rust Pixel para abrir o painel."
    return
  end
  assert(not executable:find('[\r\n"%%!&|<>^]') and not self.queue_dir:find('[\r\n"%%!&|<>^]'), "Unsupported character in the installation path")
  os.execute('start "" /b "' .. executable .. '" --queue-dir "' .. self.queue_dir .. '"')
  self.worker_started = os.time()
end

function Panel:update_models(filter)
  filter = (filter or ""):lower()
  local labels, ids, selected = {}, {}, nil
  local function add(id, name)
    local label = shorten(name, 35)
    if ids[label] and ids[label] ~= id then label=shorten(name, 27) .. " " .. id:sub(-6) end
    labels[#labels+1], ids[label] = label, id
    if id == self.model then selected=label end
  end
  if self.provider == "openrouter" and (filter == "" or ("openrouter/auto auto router"):find(filter, 1, true)) then add("openrouter/auto", "Auto Router") end
  for _,model in ipairs(self.models) do
    if model.id ~= "openrouter/auto"
      and (filter == "" or (model.name .. " " .. model.id):lower():find(filter, 1, true)) then
      add(model.id, model.name)
    end
  end
  if #labels == 0 then labels={self.provider == "codex" and #self.models == 0 and "Conecte o Codex para carregar" or "Nenhum modelo encontrado"} end
  self.labels, self.model_ids = labels, ids
  self.model_caption=selected or labels[1]
  if self.selector_dialog then
    self.changing_models = true
    self.selector_dialog:modify {id="model", options=labels, option=self.model_caption}
    self.changing_models = false
  end
  if self.dialog then self:update_controls() end
end

function Panel:send()
  if self.read_only or self.chat_job or self.connect_job or not self.ready or not self.configured then return end
  local data = self.dialog.data
  local prompt = self.editor.text
  if prompt:match("^%s*$") then return end
  if self.reference and not self:model_accepts_images() then
    self:add_error("Este modelo nao aceita imagens. Escolha um modelo com visao ou remova a referencia.")
    return
  end
  self.preferences[self.provider .. "_model"] = self.model
  local asset
  if data.attach and app.sprite then
    local ok, info = pcall(function() return self.bridge:export(app.sprite) end)
    if not ok then self:add_error(tostring(info)); return end
    asset=info.id
  end
  self.chat_job = self:request("chat", {
    thread_id=self.thread_id, prompt=prompt, model=self.model,
    mode=self.mode == "Perguntar" and "ask" or "agent", attach_asset=asset, reference_image=self.reference,
  })
  self.preferences.active_job = self.chat_job
  self.messages[#self.messages+1] = {role="user", text=prompt, reference_image=self.reference}
  self.follow_tail, self.status = true, "Enviando..."
  self.chat_cache=nil
  self.editor:clear(); self.preferences.draft=""
  self.reference=nil; self.preferences.reference_image=nil
  self:update_controls()
end

function Panel:add_error(text)
  self.messages[#self.messages+1] = {role="error", text=text}
  self.follow_tail=true
  self.chat_cache=nil
  self.status="Confira o aviso na conversa."
  if self.dialog then self.dialog:repaint() end
end

function Panel:cancel()
  local job=self.chat_job or self.connect_job
  if not job then return end
  self:write(app.fs.joinPath(self.root, "requests", job .. ".cancel"), {cancel=true})
  self.status="Interrompendo..."
end

function Panel:select_provider()
  self.provider=providers[self.selector_dialog.data.provider] or "openrouter"
  self.preferences.provider=self.provider
  self.model=self.preferences[self.provider .. "_model"] or (self.provider == "openrouter" and "openrouter/auto" or "")
  self.models={}
  self.thread_id=uuid(); self.preferences.thread_id=self.thread_id
  self.messages={}; self.scroll=0; self.chat_cache=nil; self.expanded_steps={}; self.follow_tail=true
  self.configured=self.providers[self.provider] and self.providers[self.provider].configured == true or false
  self.status="Carregando " .. provider_names[self.provider] .. "..."
  self:update_models(self.selector_dialog.data.search)
  self:request("models")
  self:update_controls()
end

function Panel:connect()
  if self.provider == "openrouter" then self:configure(); return end
  if self.connect_job then return end
  self.connect_job=self:request("connect")
  self.status="Conectando ao Codex..."
  self:update_controls()
end

function Panel:update_controls()
  if not self.dialog then return end
  local idle=not self.chat_job and not self.connect_job
  self.dialog:modify {id="send", enabled=not self.read_only and self.ready and self.configured and idle}
  self.dialog:modify {id="model_button", enabled=not self.read_only and self.ready and idle, text=self.read_only and "Previa visual" or shorten(self.configured and (self.model_caption or provider_names[self.provider]) or "Conectar " .. provider_names[self.provider], 20)}
  self.dialog:modify {id="mode", enabled=not self.read_only and idle, text=self.mode}
  self.dialog:modify {id="attach", enabled=not self.read_only}
  self.dialog:modify {id="undo", enabled=not self.read_only}
  self.dialog:modify {id="reference", enabled=not self.read_only and idle}
  self.dialog:modify {id="reference_preview", visible=self.reference ~= nil and not self.collapsed}
  self.dialog:modify {id="reference_remove", visible=self.reference ~= nil and not self.collapsed, enabled=not self.read_only and idle}
  self.dialog:modify {id="stop", enabled=not idle}
  self.dialog:modify {id="new", enabled=idle}
  self.dialog:modify {id="copy", enabled=self:copy_text() ~= ""}
  self.dialog:modify {id="status", text=shorten(self.status, 37)}
  if self.selector_dialog then
    self.selector_dialog:modify {id="configure", enabled=self.ready and idle}
    self.selector_dialog:modify {id="provider", enabled=self.ready and idle}
    self.selector_dialog:modify {id="model", enabled=self.ready and idle}
    self.selector_dialog:modify {id="connect", enabled=self.ready and idle and not (self.provider == "codex" and self.configured),
      text=self.provider == "codex" and self.configured and "Conectado" or "Conectar"}
  end
end

function Panel:clipboard(text)
  if text == nil then return app.clipboard.text or "" end
  app.clipboard.text=text
end

function Panel:configure()
  if self.provider == "codex" then self:configure_codex(); return end
  if self.settings_dialog then self.settings_dialog:show {wait=false}; return end
  local secret = ""
  local dialog
  local function save()
    if not self.ready then return end
    self:run(function()
      self:request("configure", {api_key=secret ~= "" and secret or nil, model=self.model})
      secret=""
      dialog:close()
      self.status="Verificando conexao..."
      self:update_controls()
    end)
  end
  dialog=Dialog {
    title="OpenRouter", parent=self.dialog,
    onclose=function() secret=""; self.settings_dialog=nil end,
  }
  self.settings_dialog=dialog
  dialog:label {text="Uma conexao, varios modelos."}
  dialog:newrow()
  dialog:label {text=self.configured and "Chave salva. Cole outra para substituir." or "Cole sua chave do OpenRouter para conectar."}
  dialog:newrow()
  dialog:canvas {
    id="key", width=300, height=22,
    onpaint=function(ev)
      local gc=ev.context
      gc.color=gc.theme.color.textbox_face
      gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
      gc.color=secret == "" and gc.theme.color.disabled or gc.theme.color.textbox_text
      gc:fillText(secret == "" and "Clique aqui e use Ctrl+V" or string.rep("*", math.min(45, #secret)), 7, 7)
      gc.color=gc.theme.color.window_titlebar_face
      gc:strokeRect(Rectangle(0, 0, gc.width-1, gc.height-1))
    end,
    onkeydown=function(ev)
      if ev.ctrlKey and ev.code == "KeyV" then secret=(app.clipboard.text or ""):gsub("%s", "")
      elseif ev.ctrlKey and ev.code == "KeyA" then secret=""
      elseif ev.code == "Backspace" then secret=secret:sub(1,-2)
      elseif ev.code == "Delete" then secret=""
      elseif ev.code == "Enter" then save(); return
      elseif not ev.ctrlKey and not ev.altKey and ev.key and ev.key:match("^[%g ]+$") then secret=secret .. ev.key end
      if #secret > 2560 then secret=secret:sub(1,2560) end
      dialog:repaint()
    end,
  }
  dialog:newrow()
  dialog:label {text="Chave protegida pelo cofre do Windows."}
  dialog:newrow()
  dialog:label {text="Chaves: openrouter.ai/keys"}
  dialog:newrow()
  dialog:button {text="Conectar", onclick=save}
  dialog:button {text="Fechar", onclick=function() dialog:close() end}
  dialog:show {wait=false}
end

function Panel:configure_codex()
  if self.settings_dialog then self.settings_dialog:show {wait=false}; return end
  local info=self.providers.codex or {}
  local dialog
  local function save(connect)
    self:run(function()
      local executable=(dialog.data.executable or ""):match("^%s*(.-)%s*$")
      local id=self:request("configure", {codex_path=executable ~= "" and executable or nil, model=self.model})
      self.pending[id].connect_after=connect
      dialog:close()
      self.status="Verificando o Codex..."; self:update_controls()
    end)
  end
  dialog=Dialog {title="Conexao Codex", parent=self.dialog, onclose=function() self.settings_dialog=nil end}
  self.settings_dialog=dialog
  dialog:label {text=info.configured and "Conta do cliente Codex conectada." or "Conecte usando sua conta no cliente oficial Codex."}
  dialog:newrow()
  dialog:label {text="O login e feito no navegador, sem copiar tokens."}
  dialog:newrow()
  dialog:entry {id="executable", label="Executavel", text=info.path or ""}
  dialog:newrow()
  dialog:label {text="Se necessario, indique o caminho completo de codex.exe."}
  dialog:newrow()
  dialog:label {text="Para trocar de conta, use o cliente Codex."}
  dialog:newrow()
  dialog:button {text="Conectar", onclick=function() save(true) end}
  dialog:button {text="Salvar", onclick=function() save(false) end}
  dialog:button {text="Fechar", onclick=function() dialog:close() end}
  dialog:show {wait=false}
end

function Panel:tick()
  self:sync_bounds()
  if self.last_heartbeat ~= os.time() then
    self:write(app.fs.joinPath(self.root, "panel.json"), {updated_at=os.time(), open=true})
    self.last_heartbeat=os.time()
  end
  local status = self:read(app.fs.joinPath(self.root, "status.json"))
  self.ready=status and status.ready and os.time()-status.updated_at < 5 or false
  if self.ready then self.worker_seen=true; self.worker_started=nil end
  self.providers=status and status.providers or self.providers
  self.configured=self.providers[self.provider] and self.providers[self.provider].configured == true
    or (self.provider == "openrouter" and status and status.configured == true) or false
  if self.ready and not self.loaded then
    self.loaded=true
    if self.preferences.active_job then
      self.chat_job=self.preferences.active_job
      self.pending[self.chat_job]={action="chat", started=os.time(), provider=self.provider, thread_id=self.thread_id}
    else self:request("load", {thread_id=self.thread_id}) end
    self:request("models")
    self.status=self.configured and "Pronto para criar." or "Conecte o " .. provider_names[self.provider] .. " para comecar."
  end
  for id,pending in pairs(self.pending) do
    local response = self:read(app.fs.joinPath(self.root, "responses", id .. ".json"))
    if response then
      if (pending.action == "chat" or (pending.action == "load" and not self.chat_job)) and pending.thread_id == self.thread_id then
        local messages={}
        local changed=#self.messages ~= #(response.messages or {})
        for index,message in ipairs(response.messages or {}) do
          if message.reference_image then self:reference_thumbnail(message.reference_image) end
          messages[#messages+1]={role=message.role, text=message.text, reference_image=message.reference_image}
          local previous=self.messages[index]
          if not previous or previous.role ~= message.role or previous.text ~= message.text
            or (previous.reference_image and previous.reference_image.id) ~= (message.reference_image and message.reference_image.id) then changed=true end
        end
        if changed then self.messages=messages; self.chat_cache=nil end
        if pending.action == "chat" then self.status=response.status end
      end
      if pending.action == "connect" and pending.provider == self.provider then self.status=response.status end
      if response.done then
        if not response.ok then self:add_error(response.error or "Nao foi possivel concluir o pedido.")
        elseif pending.action == "models" and pending.provider == self.provider then
          self.models=response.data.models
          if self.provider == "codex" and self.model == "" then
            for _,model in ipairs(self.models) do
              if model.default then self.model=model.id; break end
            end
          end
          self:update_models(self.selector_dialog and self.selector_dialog.data.search)
        elseif (pending.action == "configure" or pending.action == "connect") and pending.provider == self.provider then
          self.providers=response.data.providers or self.providers
          self.configured=self.providers[self.provider] and self.providers[self.provider].configured == true or response.data.configured == true
          self.status=self.configured and provider_names[self.provider] .. " conectado." or "Conecte para comecar."
          if pending.action == "configure" and pending.connect_after then self:connect()
          elseif pending.action == "connect" then self:request("models") end
        end
        if pending.action == "chat" then self.chat_job=nil; self.preferences.active_job=nil end
        if pending.action == "connect" then self.connect_job=nil end
        self.pending[id]=nil
      end
    elseif os.time()-pending.started > 20 and not self.ready then
      self.pending[id]=nil
      if pending.action == "chat" then self.chat_job=nil; self.preferences.active_job=nil end
      if pending.action == "connect" then self.connect_job=nil end
      self:add_error("O assistente nao iniciou. Reabra o painel e confira as permissoes da extensao.")
    end
  end
  if not self.ready and self.worker_started and os.time()-self.worker_started > 15 then
    self.status=self.worker_seen and "Conexao interrompida. Reabra o painel." or "Assistente indisponivel. Reabra o painel."
  elseif not self.ready and self.worker_seen then
    self.status="Conexao interrompida. Reabra o painel."
  end
  self:update_controls()
  self.dialog:repaint()
end

function Panel:close() if self.dialog then self.dialog:close() end end
return Panel
