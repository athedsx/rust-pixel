return function(root)
  local Panel=dofile(app.fs.joinPath(root, "aseprite-plugin", "panel.lua"))
  local calls, errors, stops=0, 0, 0
  local panel=setmetatable({
    timer={stop=function() stops=stops+1 end},
    add_error=function() errors=errors+1 end,
  }, Panel)
  panel.tick=function(self)
    calls=calls+1
    self:poll()
    assert(not self:run(function() error("Nested access ran") end))
  end
  panel:poll()
  assert(calls == 1 and errors == 0 and not panel.busy, "Polling must not reenter during a permission dialog")
  panel.tick=function()
    calls=calls+1
    error("Access denied")
  end
  panel:poll()
  panel:poll()
  assert(calls == 2 and errors == 1 and stops > 0 and panel.poll_failed,
    "Denied access must suspend polling without repeated prompts")
  assert(not panel.busy, "Failed access left the panel locked")
  local timer, native_calls, panel_calls, alerts= nil, 0, 0, 0
  local commands={}
  local native={enabled=true}
  local view={}
  native.process=function()
    native_calls=native_calls+1
    if native_calls < 4 then timer.ontick() end
  end
  native.export=function() error("Access denied") end
  view.show=function(self) self.dialog={}; self.poll_failed=false end
  view.poll=function() panel_calls=panel_calls+1 end
  local environment=setmetatable({
    app={
      isUIAvailable=true, apiVersion=35,
      fs={joinPath=app.fs.joinPath, isFile=function() return true end},
      alert=function() alerts=alerts+1; return 1 end,
    },
    Timer=function(options)
      timer=options
      timer.start=function(self) self.running=true end
      timer.stop=function(self) self.running=false end
      return timer
    end,
    dofile=function(path)
      if path:match("bridge%.lua$") then
        return {new=function() return native end, read_json=function() return {queue_dir="test-queue"} end}
      end
      assert(path:match("panel%.lua$"))
      return {new=function() return view end}
    end,
  }, {__index=_G})
  assert(loadfile(app.fs.joinPath(root, "aseprite-plugin", "init.lua"), "t", environment))()
  local plugin={
    path=root, version=app.version, preferences={permissions_help=1},
    newMenuGroup=function() end, newMenuSeparator=function() end,
    newCommand=function(_, command) commands[command.id]=command end,
  }
  environment.init(plugin)
  timer.ontick()
  assert(native_calls == 1 and panel_calls == 1, "Bridge and panel must share one non-reentrant timer")
  view.busy=true
  timer.ontick()
  assert(native_calls == 1, "Background bridge must wait while the panel asks for access")
  view.busy=false; view.poll_failed=true
  timer.ontick()
  assert(not timer.running and native_calls == 1, "Denied panel access must stop all background I/O")
  commands.RustPixelPanel.onclick()
  assert(timer.running and not view.poll_failed, "Explicitly reopening must resume polling")
  commands.RustPixelExport.onclick()
  assert(not timer.running and not native.enabled and alerts == 1, "Denied bridge access must stop without retrying")
end
