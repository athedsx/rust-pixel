local bridge, timer, panel

function init(plugin)
  if not app.isUIAvailable then return end
  if not json or app.apiVersion < 35 then
    app.alert {title="Rust Pixel", text="Aseprite 1.3.15 ou superior e necessario."}
    return
  end
  if plugin.preferences.permissions_help ~= 1 then
    local answer=app.alert {
      title="Rust Pixel - primeiro acesso",
      text={
        "A extensao precisa ler e gravar seus arquivos locais",
        "e iniciar o assistente instalado no computador.",
        "Nos avisos Security, marque Don't show this specific",
        "alert again for this script antes de permitir.",
        "Nao e necessario marcar Give full trust.",
      },
      buttons={"Continuar", "Mais tarde"},
    }
    if answer ~= 1 then return end
    plugin.preferences.permissions_help=1
  end
  local Bridge = dofile(app.fs.joinPath(plugin.path, "bridge.lua"))
  local Panel = dofile(app.fs.joinPath(plugin.path, "panel.lua"))
  local config_path = app.fs.joinPath(plugin.path, "bridge.json")
  local config = app.fs.isFile(config_path) and Bridge.read_json(config_path) or {}
  local queue_dir = os.getenv("RUST_PIXEL_QUEUE_DIR") or config.queue_dir
  if not queue_dir then
    local data = os.getenv("APPDATA") or os.getenv("XDG_DATA_HOME")
      or app.fs.joinPath(os.getenv("HOME"), ".local", "share")
    queue_dir = app.fs.joinPath(data, ".rust-pixel", "queue")
  end
  local function ensure_bridge()
    if not bridge then bridge=Bridge.new(queue_dir, plugin.version) end
    return bridge
  end
  local working=false
  local function guarded(action)
    if working or (panel and panel.busy) then return end
    working=true
    local ok, message=pcall(action)
    if not ok then
      timer:stop()
      if bridge then bridge.enabled=false end
      app.alert {
        title="Rust Pixel",
        text={tostring(message), "Acesso interrompido. Reabra o painel quando quiser tentar novamente."},
      }
    end
    if panel and panel.poll_failed then timer:stop() end
    working=false
  end
  local function open_panel()
    ensure_bridge()
    if not bridge.enabled then bridge.enabled=true; plugin.preferences.enabled=true; timer:start() end
    if not panel then
      panel=Panel.new {
        bridge=bridge, queue_dir=queue_dir, config=config,
        plugin_path=plugin.path, preferences=plugin.preferences, managed=true,
      }
    end
    panel:show()
    if not panel.poll_failed then timer:start() end
  end

  plugin:newMenuGroup {id="rust_pixel", title="Rust Pixel", group="file_scripts"}
  plugin:newCommand {id="RustPixelPanel", title="Abrir painel", group="rust_pixel", onclick=function() guarded(open_panel) end}
  plugin:newMenuSeparator {group="rust_pixel"}
  plugin:newCommand {
    id="RustPixelEnable", title="Ativar bridge", group="rust_pixel",
    onchecked=function() return bridge and bridge.enabled end,
    onclick=function() guarded(function()
      ensure_bridge()
      bridge.enabled=not bridge.enabled
      plugin.preferences.enabled=bridge.enabled
      bridge:heartbeat()
      if bridge.enabled then timer:start() else timer:stop() end
    end) end,
  }
  plugin:newCommand {
    id="RustPixelExport", title="Exportar sprite atual", group="rust_pixel",
    onenabled=function() return bridge ~= nil and app.sprite ~= nil end,
    onclick=function() guarded(function()
      bridge:export(app.sprite)
    end) end,
  }
  plugin:newCommand {
    id="RustPixelStatus", title="Estado da conexao", group="rust_pixel",
    onclick=function()
      app.alert {title="Rust Pixel", text={bridge and bridge.enabled and "Bridge ativo" or "Bridge desativado", queue_dir}}
    end,
  }

  local initial_panel=plugin.preferences.panel_open ~= false
  timer=Timer {
    interval=0.25,
    ontick=function()
      if panel and panel.poll_failed then timer:stop(); return end
      guarded(function()
        ensure_bridge():process()
        if initial_panel then initial_panel=false; open_panel() end
        if panel and panel.dialog then panel:poll() end
      end)
    end,
  }
  if plugin.preferences.enabled ~= false then timer:start() end
end

function exit(plugin)
  local was_open=panel and panel.dialog ~= nil
  if panel then panel:close() end
  plugin.preferences.panel_open=was_open or false
  if timer then timer:stop() end
  if bridge then bridge.enabled=false end
end
