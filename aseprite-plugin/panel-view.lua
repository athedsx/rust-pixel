local function shorten(text, limit)
  if utf8.len(text) <= limit then return text end
  return text:sub(1, utf8.offset(text, limit-2)-1) .. "..."
end

local function blend(a, b, amount)
  return Color {r=math.floor(a.red*(1-amount)+b.red*amount),
    g=math.floor(a.green*(1-amount)+b.green*amount), b=math.floor(a.blue*(1-amount)+b.blue*amount)}
end

local names={codex="Codex", openrouter="OpenRouter"}

return function(Panel, host)
  local Dialog, app, Timer=host.Dialog, host.app, host.Timer
  function Panel:copy_text()
    local message=self.selected_message and self.messages[self.selected_message]
    if message then return self.ui.plain(message.text) end
    for index=#self.messages,1,-1 do
      if self.messages[index].role == "assistant" then return self.ui.plain(self.messages[index].text) end
    end
    return ""
  end

  function Panel:paint_header(gc)
    local colors=gc.theme.color
    gc.color=colors.window_face; gc:fillRect(Rectangle(0,0,gc.width,gc.height))
    local sprite=app.sprite
    local x=6
    if sprite then
      local ok, image=pcall(function() return Image(sprite) end)
      if ok then
        local ratio=20/math.max(image.width,image.height)
        local w,h=math.max(1,math.floor(image.width*ratio)),math.max(1,math.floor(image.height*ratio))
        gc:drawImage(image, Rectangle(0,0,image.width,image.height), Rectangle(5,3,w,h))
        x=32
      end
    end
    gc.color=colors.text
    gc:fillText(shorten(sprite and app.fs.fileName(sprite.filename) or "Nova conversa", math.max(14,math.floor((gc.width-x-4)/6))),x,3)
    gc.color=colors.disabled
    local detail=self.read_only and "Previa visual / sem conexao" or names[self.provider] .. (self.configured and " conectado" or " / conectar")
    if sprite then detail=detail .. " / " .. sprite.width .. "x" .. sprite.height end
    gc:fillText(shorten(detail, math.max(14,math.floor((gc.width-x-4)/5))),x,15)
  end

  function Panel:paint_reference(gc, reference, x, y, width, height)
    if not reference then return end
    local image=reference.image or self:reference_thumbnail(reference)
    local side=math.min(height-4,48)
    gc.color=gc.theme.color.window_face; gc:fillRect(Rectangle(x,y,side+4,side+4))
    if image then
      local ratio=math.min(side/image.width,side/image.height)
      local w,h=math.max(1,math.floor(image.width*ratio)),math.max(1,math.floor(image.height*ratio))
      gc:drawImage(image,Rectangle(0,0,image.width,image.height),Rectangle(x+2+(side-w)/2,y+2+(side-h)/2,w,h))
    end
    local text_x=x+side+10
    gc.color=gc.theme.color.disabled; gc:fillText("Referencia",text_x,y+2)
    gc.color=gc.theme.color.textbox_text
    gc:fillText(shorten(reference.name,math.max(8,math.floor((width-side-12)/6))),text_x,y+15)
  end

  function Panel:chat_layout(gc)
    if self.chat_cache and self.chat_cache.width == gc.width then return self.chat_cache end
    local cache={width=gc.width, blocks={}, height=8}
    local index=1
    local line_height=math.max(12,gc:measureText("Ag").height+4)
    local measure=function(text) return gc:measureText(text).width end
    while index <= #self.messages do
      local message=self.messages[index]
      local block={index=index, role=message.role, y=cache.height, line_height=line_height}
      local text=message.text
      if message.role == "tool" then
        local actions={}
        while self.messages[index] and self.messages[index].role == "tool" do
          actions[#actions+1]=self.messages[index].text; index=index+1
        end
        block.role="steps"
        block.title=(self.expanded_steps[block.index] and "- " or "+ ") .. #actions .. " etapa(s) / " .. actions[#actions]
        block.lines=self.expanded_steps[block.index] and self.ui.rich_lines(table.concat(actions,"\n"),measure,gc.width-32) or {}
        block.height=line_height+6+#block.lines*line_height
      else
        block.lines=self.ui.rich_lines(text,measure,gc.width-30)
        block.height=22+#block.lines*line_height+(message.reference_image and 60 or 0)
        block.reference=message.reference_image
        index=index+1
      end
      cache.blocks[#cache.blocks+1]=block
      cache.height=cache.height+block.height+8
    end
    self.chat_cache=cache
    return cache
  end

  function Panel:paint_chat(gc)
    local colors=gc.theme.color
    gc.color=colors.textbox_face; gc:fillRect(Rectangle(0,0,gc.width,gc.height))
    self.chat_height=gc.height
    self.chat_hits={}
    if #self.messages == 0 then
      gc.color=colors.textbox_text; gc:fillText("O que vamos criar?",12,18)
      gc.color=colors.disabled
      local lines=self.ui.rich_lines("Descreva um sprite ou peca uma mudanca no documento aberto.",function(text) return gc:measureText(text).width end,gc.width-28)
      for index,line in ipairs(lines) do
        local x=12
        for _,run in ipairs(line.runs) do gc:fillText(run.text,x,34+(index-1)*13); x=x+run.width end
      end
      return
    end
    local layout=self:chat_layout(gc)
    self.max_scroll=math.max(0,layout.height-gc.height)
    self.scroll=self.follow_tail and self.max_scroll or math.min(self.scroll,self.max_scroll)
    for _,block in ipairs(layout.blocks) do
      local y=block.y-self.scroll
      if y+block.height >= 0 and y < gc.height then
        self.chat_hits[#self.chat_hits+1]={top=y,bottom=y+block.height,index=block.index,steps=block.role == "steps"}
        if block.role == "steps" then
          gc.color=colors.disabled
          local title=self.ui.rich_lines(block.title,function(text) return gc:measureText(text).width end,gc.width-28)[1]
          local x=12
          for _,run in ipairs(title.runs) do gc:fillText(run.text,x,y+2); x=x+run.width end
          y=y+block.line_height+4
        else
          if block.role == "user" then
            gc.color=blend(colors.textbox_face,colors.window_face,0.55)
            gc:fillRect(Rectangle(6,y,gc.width-15,block.height))
          end
          if self.selected_message == block.index then
            gc.color=colors.window_titlebar_face; gc:fillRect(Rectangle(6,y,2,block.height))
          end
          gc.color=block.role == "user" and colors.link_text or block.role == "error" and colors.selected or colors.textbox_text
          gc:fillText(block.role == "user" and "Voce" or block.role == "error" and "Aviso" or "Rust Pixel",12,y+4)
          y=y+20
        end
        for _,line in ipairs(block.lines) do
          if y+block.line_height >= 0 and y < gc.height then
            if line.code then
              gc.color=blend(colors.textbox_face,colors.window_face,0.5)
              gc:fillRect(Rectangle(9,y-2,gc.width-24,block.line_height))
            end
            local x=12
            for _,run in ipairs(line.runs) do
              gc.color=block.role == "steps" and colors.disabled or run.style == "code" and colors.link_text or colors.textbox_text
              gc:fillText(run.text,x,y)
              if run.style == "bold" then gc:fillText(run.text,x+1,y) end
              x=x+run.width
            end
          end
          y=y+block.line_height
        end
        if block.reference then self:paint_reference(gc,block.reference,12,y+4,gc.width-30,52) end
      end
    end
    if self.max_scroll > 0 then
      local thumb=math.max(12,gc.height*gc.height/layout.height)
      gc.color=colors.disabled
      gc:fillRect(Rectangle(gc.width-4,(gc.height-thumb)*self.scroll/self.max_scroll,2,thumb))
    end
  end

  function Panel:paint_composer(gc)
    local colors=gc.theme.color
    gc.color=colors.textbox_face; gc:fillRect(Rectangle(0,0,gc.width,gc.height))
    gc.color=self.composer_focused and colors.window_titlebar_face or colors.disabled
    gc:strokeRect(Rectangle(0,0,gc.width-1,gc.height-1))
    local editor=self.editor
    local line_height=math.max(12,gc:measureText("Ag").height+4)
    self.composer_line_height=line_height
    local lines=editor:layout(function(text) return gc:measureText(text).width end,gc.width-16)
    local rows=math.max(1,math.floor((gc.height-12)/line_height))
    local cursor_row,cursor_x=editor:location()
    if editor.reveal then
      if cursor_row <= editor.scroll then editor.scroll=cursor_row-1
      elseif cursor_row > editor.scroll+rows then editor.scroll=cursor_row-rows end
      editor.reveal=false
    end
    editor.scroll=math.max(0,math.min(editor.scroll,#lines-rows))
    if editor.text == "" then
      gc.color=colors.disabled; gc:fillText("Descreva o que voce quer criar...",7,7)
    end
    local first,last=editor:selection()
    for row=editor.scroll+1,math.min(#lines,editor.scroll+rows) do
      local y=7+(row-editor.scroll-1)*line_height
      for _,cell in ipairs(lines[row].cells) do
        if cell.first < last and cell.last > first then
          gc.color=blend(colors.textbox_face,colors.window_titlebar_face,0.7)
          gc:fillRect(Rectangle(7+cell.x,y-1,cell.width,line_height))
        end
        gc.color=colors.textbox_text; gc:fillText(cell.text,7+cell.x,y)
      end
    end
    if self.composer_focused and cursor_row > editor.scroll and cursor_row <= editor.scroll+rows then
      gc.color=colors.textbox_text
      gc:fillRect(Rectangle(7+cursor_x,6+(cursor_row-editor.scroll-1)*line_height,1,line_height-1))
    end
  end

  function Panel:composer_key(ev)
    local ctrl=ev.ctrlKey or ev.metaKey
    local result
    if ctrl and ev.code == "KeyV" then
      result=self.editor:insert(self:clipboard()) and true or "limit"
    elseif ctrl and (ev.code == "KeyC" or ev.code == "KeyX") then
      local selected=self.editor:selected()
      if selected ~= "" then self:clipboard(selected); if ev.code == "KeyX" then self.editor:insert("") end end
      result=true
    else result=self.editor:key(ev) end
    if result then
      ev:stopPropagation()
      if result == "send" then self:send()
      elseif result == "limit" then self.status="Limite de 16000 bytes por pedido." end
      self.preferences.draft=self.editor.text
      self.composer_focused=true
      self.dialog:repaint()
    end
  end

  function Panel:composer_point(ev, extend)
    local row=math.floor((ev.y-7)/(self.composer_line_height or 12))+1+self.editor.scroll
    self.editor:move(self.editor:point(ev.x-7,row),extend)
    self.composer_focused=true
    self.dialog:repaint()
  end

  function Panel:sync_bounds()
    if not self.dialog or not self.pinned or self.closing or self.layouting then return end
    local window=app.window
    if not window or window.width <= 0 or window.height <= 0 then return end
    local target=self.ui.sidebar_bounds(window.width,window.height,app.uiScale,self.preferences.sidebar_width,self.collapsed,self.dialog.sizeHint)
    local current=self.dialog.bounds
    if current.x ~= target.x or current.y ~= target.y or current.width ~= target.width or current.height ~= target.height then
      self.layouting=true
      self.dialog.bounds=Rectangle(target.x,target.y,target.width,target.height)
      self.layouting=false
    end
  end

  function Panel:set_collapsed(collapsed)
    self.collapsed=collapsed
    self.preferences.collapsed=collapsed
    if self.selector_dialog then self.selector_dialog:close() end
    if self.reference_dialog then self.reference_dialog:close() end
    for _,id in ipairs({"chat","composer","hint","mode","model_button","attach","reference","reference_preview","reference_remove","undo","stop","send"}) do
      self.dialog:modify {id=id,visible=not collapsed}
    end
    self.dialog:modify {id="collapse",text=collapsed and "Expandir" or "Recolher"}
    self:update_controls()
    if self.pinned then self:sync_bounds()
    else
      local bounds=self.dialog.bounds
      self.dialog.bounds=Rectangle(bounds.x,bounds.y,bounds.width,collapsed and self.dialog.sizeHint.height or math.max(320*(app.uiScale or 1),self.dialog.sizeHint.height))
    end
  end

  function Panel:show_reference_picker()
    if self.read_only or self.chat_job or self.connect_job then return end
    if self.reference_dialog then self.reference_dialog:show {wait=false}; return end
    self.composer_focused=false
    local candidate,dialog
    dialog=Dialog {title="Imagem de referencia",parent=self.dialog,onclose=function() self.reference_dialog=nil end}
    self.reference_dialog=dialog
    dialog:file {id="source",label="Imagem",title="Escolher imagem de referencia",filename="",open=true,
      filetypes={"png","jpg","jpeg","gif","bmp","aseprite","ase"},
      onchange=function()
        self:run(function()
          local ok,result=pcall(function() return self:load_reference(dialog.data.source) end)
          candidate=ok and result or nil
          dialog:modify {id="add",enabled=candidate ~= nil}
          local detail=candidate and candidate.width .. "x" .. candidate.height .. " / primeiro frame"
            or tostring(result):gsub("^.-:%d+:%s*", "")
          dialog:modify {id="details",text=shorten(detail,48)}
          dialog:repaint()
        end)
      end,
    }
    dialog:newrow()
    dialog:canvas {id="preview",width=240,height=120,onpaint=function(ev)
      local gc=ev.context
      gc.color=gc.theme.color.textbox_face; gc:fillRect(Rectangle(0,0,gc.width,gc.height))
      if candidate then
        local image=candidate.image
        local ratio=math.min((gc.width-12)/image.width,(gc.height-12)/image.height)
        local w,h=math.max(1,math.floor(image.width*ratio)),math.max(1,math.floor(image.height*ratio))
        gc:drawImage(image,Rectangle(0,0,image.width,image.height),Rectangle((gc.width-w)/2,(gc.height-h)/2,w,h))
      else gc.color=gc.theme.color.disabled; gc:fillText("Escolha uma imagem para ver a previa.",8,12) end
    end}
    dialog:newrow()
    dialog:label {id="details",text="A imagem sera enviada com seu proximo pedido."}
    dialog:newrow()
    dialog:button {id="add",text="Anexar",enabled=false,onclick=function()
      self:run(function() if candidate and self:set_reference(candidate) then dialog:close() end end)
    end}
    dialog:button {text="Cancelar",onclick=function() dialog:close() end}
    dialog:show {wait=false}
  end

  function Panel:show_selector()
    if self.read_only then return end
    self.composer_focused=false
    if self.selector_dialog then self.selector_dialog:show {wait=false}; return end
    local dialog
    dialog=Dialog {title="Modelo e conexao",parent=self.dialog,onclose=function() self.selector_dialog=nil end}
    self.selector_dialog=dialog
    dialog:combobox {id="provider",label="Provedor",options={"Codex","OpenRouter"},option=names[self.provider],
      onchange=function() self:run(function() self:select_provider() end) end}
    dialog:newrow()
    dialog:entry {id="search",label="Buscar",text="",onchange=function() self:update_models(dialog.data.search) end}
    dialog:newrow()
    dialog:combobox {id="model",label="Modelo",options=self.labels,option=self.model_caption,onchange=function()
      if not self.changing_models then
        self.model=self.model_ids[dialog.data.model] or self.model
        self.model_caption=dialog.data.model
        self.preferences[self.provider .. "_model"]=self.model
        self:update_controls()
      end
    end}
    dialog:newrow()
    dialog:button {id="connect",text="Conectar",onclick=function() self:run(function() self:connect() end) end}
    dialog:button {id="configure",text="Configurar",onclick=function() self:configure() end}
    dialog:button {text="Fechar",onclick=function() dialog:close() end}
    self:update_controls()
    dialog:show {wait=false}
  end

  function Panel:show()
    if self.dialog and not self.poll_failed then self.dialog:show {wait=false}; self:sync_bounds(); return end
    if self.dialog then self:close() end
    self.closing=false
    local dialog
    dialog=Dialog {title=self.read_only and "Rust Pixel - Previa visual" or "Rust Pixel",resizeable=true,
      onresize=function()
        self.chat_cache=nil
        if self.pinned and not self.layouting and self.dialog then
          self.preferences.sidebar_width=self.dialog.bounds.width/(app.uiScale or 1)
        end
      end,
      onclose=function()
        self.closing=true
        if self.timer then self.timer:stop() end
        if self.selector_dialog then self.selector_dialog:close() end
        if self.settings_dialog then self.settings_dialog:close() end
        if self.reference_dialog then self.reference_dialog:close() end
        if self.resize_listener then pcall(function() self.resize_events:off(self.resize_listener) end); self.resize_listener=nil end
        self.preferences.draft=self.editor.text
        self.preferences.panel_open=false
        self.dialog=nil
      end,
    }
    self.dialog=dialog
    self.preferences.panel_open=true
    dialog:canvas {id="header",width=240,height=27,vexpand=false,onpaint=function(ev) self:paint_header(ev.context) end,
      onmousedown=function() self:show_selector() end}
    dialog:newrow()
    dialog:button {id="new",text="Nova",onclick=function()
      self.thread_id=tostring(Uuid()):lower(); self.preferences.thread_id=self.thread_id
      self.messages={}; self.chat_cache=nil; self.scroll=0; self.follow_tail=true; self.expanded_steps={}; self.selected_message=nil
      self.status="Nova conversa."; self:update_controls(); dialog:repaint()
    end}
    dialog:button {id="copy",text="Copiar",onclick=function() self:run(function() local text=self:copy_text(); if text ~= "" then self:clipboard(text) end end) end}
    dialog:button {id="pin",text=self.pinned and "Lateral" or "Livre",selected=self.pinned,onclick=function()
      self.pinned=not self.pinned; self.preferences.sidebar=self.pinned
      dialog:modify {id="pin",text=self.pinned and "Lateral" or "Livre",selected=self.pinned}; self:sync_bounds()
    end}
    dialog:button {id="collapse",text="Recolher",onclick=function() self:set_collapsed(not self.collapsed) end}
    dialog:newrow()
    dialog:canvas {id="chat",width=240,height=40,vexpand=true,onpaint=function(ev) self:paint_chat(ev.context) end,
      onwheel=function(ev)
        self.scroll=math.max(0,math.min(self.max_scroll,self.scroll+ev.deltaY*24)); self.follow_tail=self.scroll >= self.max_scroll-2
        dialog:repaint()
      end,
      onmousedown=function(ev)
        self.composer_focused=false
        for _,hit in ipairs(self.chat_hits or {}) do
          if ev.y >= hit.top and ev.y <= hit.bottom then
            if hit.steps then self.expanded_steps[hit.index]=not self.expanded_steps[hit.index]; self.chat_cache=nil
            else self.selected_message=hit.index end
            break
          end
        end
        self:update_controls(); dialog:repaint()
      end,
      onkeydown=function(ev)
        if (ev.ctrlKey or ev.metaKey) and ev.code == "KeyC" then
          self:run(function() local text=self:copy_text(); if text ~= "" then self:clipboard(text) end end); ev:stopPropagation()
        end
      end,
    }
    dialog:newrow()
    dialog:canvas {id="reference_preview",width=200,height=28,visible=false,
      onpaint=function(ev)
        local gc=ev.context
        gc.color=gc.theme.color.textbox_face; gc:fillRect(Rectangle(0,0,gc.width,gc.height))
        self:paint_reference(gc,self.reference,3,1,gc.width-6,gc.height-2)
      end,
      onmousedown=function() self:show_reference_picker() end,
    }
    dialog:button {id="reference_remove",text="X",visible=false,onclick=function() self:set_reference(nil) end}
    dialog:newrow()
    dialog:canvas {id="composer",width=240,height=62,vexpand=false,focus=true,
      onpaint=function(ev) self:paint_composer(ev.context) end,
      onkeydown=function(ev) self:run(function() self:composer_key(ev) end) end,
      onmousedown=function(ev) self.composer_dragging=true; self:composer_point(ev,ev.shiftKey) end,
      onmousemove=function(ev) if self.composer_dragging then self:composer_point(ev,true) end end,
      onmouseup=function() self.composer_dragging=false end,
      onwheel=function(ev)
        self.editor.scroll=math.max(0,self.editor.scroll+ev.deltaY); self.editor.reveal=false; dialog:repaint()
      end,
    }
    dialog:newrow()
    dialog:label {id="hint",text=self.read_only and "Previa visual / envio desativado" or "Enter envia / Shift+Enter: nova linha"}
    dialog:newrow()
    dialog:button {id="mode",text=self.mode,onclick=function()
      self.mode=self.mode == "Agente" and "Perguntar" or "Agente"; self.preferences.mode=self.mode; self:update_controls()
    end}
    dialog:button {id="model_button",text=names[self.provider],onclick=function() self:show_selector() end}
    dialog:newrow()
    dialog:check {id="attach",text="Usar sprite atual",selected=true}
    dialog:button {id="reference",text="Referencia",onclick=function() self:show_reference_picker() end}
    dialog:newrow()
    dialog:button {id="undo",text="Desfazer",onclick=function() if not self.read_only and app.sprite then app.command.Undo(); dialog:repaint() end end}
    dialog:button {id="stop",text="Parar",enabled=false,onclick=function() self:run(function() self:cancel() end) end}
    dialog:button {id="send",text="Enviar",enabled=false,onclick=function() self:run(function() self:send() end) end}
    dialog:newrow()
    dialog:label {id="status",text=shorten(self.status,37)}
    self:update_controls()
    self.layouting=true
    dialog:show {wait=false,autoscrollbars=true}
    self.layouting=false
    self:set_collapsed(self.collapsed)
    local window=app.window
    if window and window.events then
      self.resize_events=window.events
      self.resize_listener=self.resize_events:on("resize",function() self:sync_bounds() end)
    end
    self.poll_failed=false
    self.loaded=false
    if not self.managed then self.timer=Timer {interval=0.2,ontick=function() self:poll() end} end
    self:run(function()
      self:write(app.fs.joinPath(self.root, "panel.json"), {updated_at=os.time(),open=true})
      self.last_heartbeat=os.time()
      self:start_worker()
      if self.timer then self.timer:start() end
    end)
  end
end
