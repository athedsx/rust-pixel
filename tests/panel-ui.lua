return function(root, queue)
  local Bridge=dofile(app.fs.joinPath(root, "aseprite-plugin", "bridge.lua"))
  local panel_queue=app.fs.joinPath(queue, "panel-ui")
  local bridge=Bridge.new(panel_queue, app.version)
  local environment=setmetatable({Dialog=function(options)
    local dialog={data={}, controls={}, options=options, bounds=Rectangle(0,0,540,700),sizeHint={width=520,height=260}}
    for _,kind in ipairs({"canvas", "entry", "file", "combobox", "button", "label", "check"}) do
      dialog[kind]=function(self, control)
        if control.id then
          self.controls[control.id]=control
          if kind == "entry" then self.data[control.id]=control.text end
          if kind == "file" then self.data[control.id]=control.filename end
          if kind == "check" then self.data[control.id]=control.selected end
          if kind == "combobox" then
            assert(#control.options > 0 and control.option, "Combobox must have an initial option")
            self.data[control.id]=control.option
          end
        end
      end
    end
    dialog.newrow=function() end
    dialog.modify=function(self, values)
      local control=assert(self.controls[values.id], "Unknown control: " .. values.id)
      for key,value in pairs(values) do control[key]=value end
      if values.option then self.data[values.id]=values.option end
      if values.id == "prompt" and values.text then self.data.prompt=values.text end
    end
    dialog.show=function(_, values) assert(values.wait == false, "Panel must not block the editor") end
    dialog.repaint=function() end
    dialog.close=function() options.onclose() end
    return dialog
  end}, {__index=_G})
  local Panel=assert(loadfile(app.fs.joinPath(root, "aseprite-plugin", "panel.lua"), "t", environment))()
  local panel=Panel.new {bridge=bridge, queue_dir=panel_queue, plugin_path=app.fs.joinPath(root, "aseprite-plugin"),
    preferences={}, config={}, managed=true}
  panel.start_worker=function() end
  panel:show()
  assert(not panel.poll_failed and panel.dialog, "Panel must open without a sprite")
  local dialog=panel.dialog
  Bridge.write_json(app.fs.joinPath(panel.root, "status.json"), {
    updated_at=os.time(), ready=true, configured=false,
    providers={openrouter={available=true, configured=false}, codex={available=true, configured=true, path="codex.exe"}},
  })
  panel:poll()
  panel:show_selector()
  local selector=panel.selector_dialog
  assert(panel.ready and selector.controls.provider.enabled, "Provider selector must be available when worker is ready")
  local original_thread=panel.thread_id
  selector.data.provider="Codex"
  selector.controls.provider.onchange()
  assert(panel.provider == "codex" and panel.thread_id ~= original_thread, "Provider change must start a separate conversation")
  local catalog_id
  for id,pending in pairs(panel.pending) do
    if pending.action == "models" and pending.provider == "codex" then catalog_id=id end
  end
  assert(catalog_id, "Codex model request was not queued")
  local request=Bridge.read_json(app.fs.joinPath(panel.root, "requests", catalog_id .. ".request.json"))
  assert(request.provider == "codex", "Selected provider was not sent to worker")
  Bridge.write_json(app.fs.joinPath(panel.root, "responses", catalog_id .. ".json"), {
    done=true, ok=true, data={provider="codex", models={{id="test-codex", name="Test Codex", default=true}}},
  })
  panel:poll()
  assert(panel.model == "test-codex" and selector.data.model == "Test Codex", "Native provider model catalog was not selected")
  assert(dialog.controls.send.enabled and selector.controls.connect.text == "Conectado", "Connected provider controls were not updated")
  local color=Color {r=100,g=110,b=120}
  local painted={}
  local gc={width=240,height=100,theme={color={window_face=color,textbox_face=color,window_titlebar_face=color,
    text=color,textbox_text=color,disabled=color,link_text=color,selected=color}},
    fillRect=function() end,strokeRect=function() end,drawImage=function() end,
    measureText=function(_,text) return {width=utf8.len(text)*6,height=8} end,
    fillText=function(_,text) painted[#painted+1]=text end}
  local reference_path=app.fs.joinPath(panel_queue,"referencia original.png")
  local reference_pixels=Image(8,6,ColorMode.RGB)
  reference_pixels:clear(app.pixelColor.rgba(22,88,155,255))
  reference_pixels:saveAs(reference_path)
  panel:show_reference_picker()
  local picker=panel.reference_dialog
  picker.data.source=reference_path
  picker.controls.source.onchange()
  assert(picker.controls.add.enabled, "A valid image must enable Attach")
  picker.controls.preview.onpaint {context=gc}
  picker.data.source=app.fs.joinPath(panel_queue,"missing.png")
  picker.controls.source.onchange()
  assert(not picker.controls.add.enabled and not panel.poll_failed, "An invalid selection must not attach or stop the panel")
  picker.data.source=reference_path
  picker.controls.source.onchange()
  picker.controls.add.onclick()
  local attachment=assert(panel.reference, "Reference picker must attach the selected image")
  assert(not panel.reference_dialog and dialog.controls.reference_preview.visible, "Attached reference must show a thumbnail in the composer")
  local snapshot=Image {fromFile=app.fs.joinPath(panel.root,"references",attachment.id .. ".png")}
  assert(snapshot:isEqual(reference_pixels), "Attachment must preserve the image pixels")
  assert(panel:reference_thumbnail(attachment), "Local reference must have a thumbnail")
  dialog.controls.reference_remove.onclick()
  assert(not panel.reference and not panel.preferences.reference_image and not dialog.controls.reference_preview.visible,
    "Remove must detach the reference without deleting the source file")
  assert((Image {fromFile=reference_path}):isEqual(reference_pixels), "Removing a reference must not modify the original")
  for _,extension in ipairs({"jpg","bmp","gif"}) do
    local path=app.fs.joinPath(panel_queue,"referencia." .. extension)
    reference_pixels:saveAs(path)
    local loaded=panel:load_reference(path)
    assert(loaded.image.width == 8 and loaded.image.height == 6, "Supported image formats must load without opening a document")
  end
  local indexed=Sprite(2,2,ColorMode.INDEXED)
  indexed.palettes[1]:setColor(1,Color {r=22,g=88,b=155,a=255})
  indexed.cels[1].image:clear(1)
  indexed.cels[1].image:drawPixel(1,1,0)
  local indexed_path=app.fs.joinPath(panel_queue,"referencia-indexada.png")
  indexed:saveCopyAs(indexed_path); indexed:close()
  local converted=panel:load_reference(indexed_path).image
  assert(converted.colorMode == ColorMode.RGB and converted:getPixel(0,0) == app.pixelColor.rgba(22,88,155,255),
    "Indexed references must retain their palette when flattened")
  assert(app.pixelColor.rgbaA(converted:getPixel(1,1)) == 0, "Indexed references must retain transparency")
  local gray_path=app.fs.joinPath(panel_queue,"referencia-cinza.png")
  local gray=Image(2,2,ColorMode.GRAY)
  gray:clear(app.pixelColor.graya(100,32)); gray:saveAs(gray_path)
  local gray_rgb=panel:load_reference(gray_path).image
  assert(gray_rgb:getPixel(0,0) == app.pixelColor.rgba(100,100,100,32), "Grayscale references must preserve color and alpha")
  local wide_path=app.fs.joinPath(panel_queue,"referencia-larga.png")
  Image(2048,16):saveAs(wide_path)
  local wide=panel:load_reference(wide_path)
  assert(wide.image.width == 1024 and wide.image.height == 8, "Large reference previews must preserve aspect ratio")
  assert(not panel:set_reference(app.fs.joinPath(panel_queue,"missing.png")) and not panel.poll_failed,
    "Invalid attachments must not stop panel polling")
  panel.messages={{role="user",text="Crie uma espada"},{role="tool",text="Criando sprite: concluido"},
    {role="tool",text="Conferindo a previa: concluido"},{role="assistant",text="Feito! Uma espada **16x16** com `brilho`."}}
  panel.chat_cache=nil
  panel:paint_header(gc); panel:paint_chat(gc); panel:paint_composer(gc)
  assert(#panel.chat_cache.blocks == 3, "Consecutive tool messages must collapse into one activity row")
  assert(not table.concat(painted):find("**",1,true), "Rendered conversation must hide Markdown delimiters")
  panel.follow_tail=false; panel.scroll=0
  panel.messages[#panel.messages+1]={role="assistant",text="Mais detalhes sobre o sprite."}; panel.chat_cache=nil
  panel:paint_chat(gc)
  assert(panel.scroll == 0, "Incoming text must not move a reader who scrolled up")
  panel.worker_started=os.time()-100
  panel:poll()
  assert(panel.worker_started == nil and not panel.status:find("nao foi possivel iniciar"), "Healthy worker must clear its startup timeout")
  panel.editor:insert("Uma espada")
  local key={code="Enter",shiftKey=true,stopPropagation=function() end}
  panel:composer_key(key)
  panel.editor:insert("com brilho azul")
  assert(panel.editor.text == "Uma espada\ncom brilho azul", "Composer must preserve line breaks")
  assert(panel:set_reference(reference_path))
  local selected_reference=panel.reference
  local reopened=Panel.new {bridge=bridge,queue_dir=panel_queue,plugin_path=app.fs.joinPath(root,"aseprite-plugin"),
    preferences=panel.preferences,config={},managed=true}
  assert(reopened.reference.id == selected_reference.id and reopened:reference_thumbnail(reopened.reference),
    "An unsent reference must survive reopening the panel")
  panel.models[1].vision=false
  panel:send()
  assert(not panel.chat_job and panel.reference and panel.editor.text ~= "", "Text-only models must not silently discard a reference")
  panel.models[1].vision=true
  local current_sprite=Sprite(3,3,ColorMode.RGB)
  current_sprite.cels[1].image:clear(app.pixelColor.rgba(10,20,30,255))
  panel:send()
  local submitted=Bridge.read_json(app.fs.joinPath(panel.root,"requests",panel.chat_job .. ".request.json"))
  assert(submitted.prompt == "Uma espada\ncom brilho azul" and panel.editor.text == "", "Send must submit and clear the multiline draft")
  assert(submitted.reference_image.id == selected_reference.id and submitted.attach_asset,
    "A request must support a reference image and the current sprite together")
  assert(panel.messages[#panel.messages].reference_image.id == selected_reference.id and not panel.reference,
    "Sent references must remain in message history but clear from the next draft")
  panel:paint_chat(gc)
  current_sprite:close()
  panel:set_collapsed(true)
  assert(not dialog.controls.chat.visible and not dialog.controls.composer.visible, "Collapse must hide the chat and composer")
  panel:set_collapsed(false)
  assert(dialog.controls.chat.visible and dialog.controls.composer.visible, "Expand must restore the chat and composer")
  panel.chat_job=nil
  panel.bridge={}
  panel.read_only=true
  panel:update_controls()
  assert(not dialog.controls.send.enabled and not dialog.controls.model_button.enabled and not dialog.controls.undo.enabled,
    "Visual preview must disable drawing and connection controls")
  panel.editor:insert("Este pedido nao deve ser enviado")
  panel:send()
  panel:composer_key {code="Enter",stopPropagation=function() end}
  assert(not panel.chat_job and panel.editor.text == "Este pedido nao deve ser enviado",
    "Visual preview must ignore both Send and Enter without calling the drawing bridge")
  selector:close()
  panel:show_selector()
  assert(not panel.selector_dialog, "Visual preview must not open provider connections")
  panel:show_reference_picker()
  assert(not panel.reference_dialog, "Visual preview must not attach local files")
  panel:close()
  assert(not panel.dialog and not panel.preferences.panel_open, "Panel close must not require another file write")
end
