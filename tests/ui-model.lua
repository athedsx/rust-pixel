return function(root)
  local Ui=dofile(app.fs.joinPath(root,"aseprite-plugin","ui.lua"))
  local editor=Ui.editor("Ação")
  editor:key {code="ArrowLeft"}
  editor:key {code="Backspace"}
  assert(editor.text == "Aço" and utf8.len(editor.text), "Backspace must remove complete UTF-8 characters")
  editor:key {code="KeyA",ctrlKey=true}
  assert(editor:selected() == "Aço", "Select all must include Unicode text")
  editor:insert("primeira\r\nsegunda")
  assert(editor.text == "primeira\nsegunda", "Pasted Windows newlines must normalize")
  editor:key {code="Enter",shiftKey=true}
  editor:insert("terceira")
  assert(editor:key {code="Enter"} == "send", "Enter must send without inserting a newline")
  local before=editor.text
  editor:key {code="KeyZ",ctrlKey=true}
  editor:key {code="KeyY",ctrlKey=true}
  assert(editor.text == before, "Composer undo and redo must preserve text")
  assert(not editor:insert(string.rep("x",16001)), "Oversized clipboard content must be rejected")
  local lines=editor:layout(function(text) return utf8.len(text) end,8)
  assert(#lines >= 3 and editor:location() == #lines, "Caret must follow multiline wrapping")
  editor:move(0)
  editor:key {code="ArrowDown"}
  assert(editor.cursor >= lines[2].first, "Vertical navigation must follow wrapped lines")
  local rich=Ui.rich_lines("Feito: **16x16** com `brilho`.\n\n- uma espada",function(text) return utf8.len(text) end,20)
  local text, bold={}, false
  for _,line in ipairs(rich) do
    local width=0
    for _,run in ipairs(line.runs) do
      text[#text+1]=run.text; width=width+run.width
      if run.style == "bold" and run.text:find("16x16",1,true) then bold=true end
    end
    assert(width <= 20, "Rich text must wrap within its viewport")
  end
  assert(bold and not table.concat(text):find("**",1,true), "Markdown emphasis must render without raw delimiters")
  assert(Ui.plain("**texto** e `codigo`") == "texto e codigo", "Copy must produce readable text")
  for _,scale in ipairs({1,2,3}) do
    local bounds=Ui.sidebar_bounds(1600,900,scale,270,false,{width=100,height=100})
    assert(bounds.x+bounds.width <= 1600 and bounds.y+bounds.height <= 900, "Sidebar must stay inside the editor")
    local small=Ui.sidebar_bounds(320,240,scale,270,false,{width=100,height=100})
    assert(small.x+small.width <= 320 and small.y+small.height <= 240, "Sidebar must fit smaller windows")
    local collapsed=Ui.sidebar_bounds(1600,900,scale,270,true,{width=100,height=50})
    assert(collapsed.height < bounds.height, "Collapsed sidebar must free canvas space")
  end
end
