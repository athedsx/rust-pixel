local Ui = {}
local Editor = {}
Editor.__index = Editor

local function previous(text, cursor)
  return cursor > 0 and utf8.offset(text, -1, cursor+1)-1 or 0
end

local function following(text, cursor)
  return cursor < #text and (utf8.offset(text, 2, cursor+1) or #text+1)-1 or #text
end

function Ui.editor(text)
  text=text or ""
  return setmetatable({text=text, cursor=#text, anchor=#text, undo={}, redo={}, scroll=0, reveal=true}, Editor)
end

function Editor:selection()
  return math.min(self.cursor, self.anchor), math.max(self.cursor, self.anchor)
end

function Editor:selected()
  local first, last=self:selection()
  return self.text:sub(first+1, last)
end

function Editor:snapshot()
  return {text=self.text, cursor=self.cursor, anchor=self.anchor}
end

function Editor:restore(state)
  self.text, self.cursor, self.anchor=state.text, state.cursor, state.anchor
  self.reveal=true
end

function Editor:insert(text)
  text=text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%z", "")
  local first, last=self:selection()
  local result=self.text:sub(1, first) .. text .. self.text:sub(last+1)
  if not utf8.len(result) or #result > 16000 then return false end
  self.undo[#self.undo+1]=self:snapshot()
  if #self.undo > 100 then table.remove(self.undo, 1) end
  self.redo={}
  self.text, self.cursor=result, first+#text
  self.anchor=self.cursor
  self.reveal=true
  return true
end

function Editor:move(cursor, extend)
  self.cursor=math.max(0, math.min(#self.text, cursor))
  if not extend then self.anchor=self.cursor end
  self.reveal=true
end

function Editor:clear()
  self:restore {text="", cursor=0, anchor=0}
  self.undo, self.redo={}, {}
end

function Editor:key(ev)
  local code, ctrl=ev.code, ev.ctrlKey or ev.metaKey
  if ctrl and code == "KeyA" then self.anchor=0; self.cursor=#self.text
  elseif ctrl and (code == "KeyZ" or code == "KeyY") then
    local redo=ev.shiftKey or code == "KeyY"
    local source, target=redo and self.redo or self.undo, redo and self.undo or self.redo
    if #source > 0 then target[#target+1]=self:snapshot(); self:restore(table.remove(source)) end
  elseif code == "Enter" or code == "NumpadEnter" then
    if ev.shiftKey and not ctrl then self:insert("\n") else return "send" end
  elseif code == "Backspace" or code == "Delete" then
    local first, last=self:selection()
    if first == last then
      if code == "Backspace" then self.anchor=previous(self.text, first)
      else self.anchor=following(self.text, last) end
    end
    self:insert("")
  elseif code == "ArrowLeft" or code == "ArrowRight" then
    local first, last=self:selection()
    local cursor=self.cursor
    local left=code == "ArrowLeft"
    if first ~= last and not ev.shiftKey then cursor=left and first or last
    else
      cursor=left and previous(self.text, cursor) or following(self.text, cursor)
      if ctrl then
        while cursor > 0 and cursor < #self.text do
          local next_cursor=left and previous(self.text, cursor) or following(self.text, cursor)
          local character=left and self.text:sub(next_cursor+1, cursor) or self.text:sub(cursor+1, next_cursor)
          if character:match("%s") then break end
          cursor=next_cursor
        end
      end
    end
    self:move(cursor, ev.shiftKey)
  elseif code == "Home" or code == "End" then
    local line=self.lines and self.lines[self:location()]
    self:move(ctrl and (code == "Home" and 0 or #self.text)
      or line and (code == "Home" and line.first or line.last)
      or (code == "Home" and 0 or #self.text), ev.shiftKey)
  elseif code == "ArrowUp" or code == "ArrowDown" then
    local row, x=self:location()
    if self.lines then self:move(self:point(x, row+(code == "ArrowUp" and -1 or 1)), ev.shiftKey) end
  elseif not ctrl and not ev.altKey and ev.key and ev.key ~= "" and not ev.key:find("%c") then
    if not self:insert(ev.key) then return "limit" end
  else return false end
  self.reveal=true
  return true
end

function Editor:layout(measure, width)
  local lines, cells, used, first={}, {}, 0, 0
  local function emit(count, last)
    local line={cells={}, first=first, last=last, width=0}
    for i=1,count do
      local cell=cells[i]
      cell.x=line.width
      line.width=line.width+cell.width
      line.cells[#line.cells+1]=cell
    end
    lines[#lines+1]=line
    local remaining={}
    for i=count+1,#cells do remaining[#remaining+1]=cells[i] end
    cells=remaining; used=0; first=last
    for _,cell in ipairs(cells) do cell.x=used; used=used+cell.width end
  end
  for position, codepoint in utf8.codes(self.text) do
    local character=utf8.char(codepoint)
    local before, after=position-1, position+#character-1
    if character == "\n" then
      emit(#cells, before); first=after
    else
      local display=character == "\t" and "    " or character
      local size=measure(display)
      if used+size > width and #cells > 0 then
        local split
        for i=#cells,1,-1 do if cells[i].text:match("^%s+$") then split=i; break end end
        emit(split or #cells, cells[split or #cells].last)
        if used+size > width and #cells > 0 then emit(#cells, before) end
      end
      cells[#cells+1]={text=display, first=before, last=after, x=used, width=size}
      used=used+size
    end
  end
  emit(#cells, #self.text)
  self.lines=lines
  return lines
end

function Editor:location()
  local row, x=1, 0
  for index,line in ipairs(self.lines or {}) do
    if self.cursor >= line.first then
      row=index; x=0
      for _,cell in ipairs(line.cells) do
        if self.cursor >= cell.last then x=cell.x+cell.width else break end
      end
    end
  end
  return row, x
end

function Editor:point(x, row)
  local line=self.lines and self.lines[math.max(1, math.min(#self.lines, row))]
  if not line then return self.cursor end
  for _,cell in ipairs(line.cells) do
    if x < cell.x+cell.width/2 then return cell.first end
  end
  return line.last
end

function Ui.plain(text)
  return text:gsub("```[^\n]*\n", ""):gsub("```", "")
    :gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)")
    :gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1"):gsub("`(.-)`", "%1")
    :gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
end

function Ui.rich_lines(text, measure, width)
  local output, in_code={}, false
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    if paragraph:match("^%s*```") then in_code=not in_code
    else
      local heading=not in_code and paragraph:match("^#+%s+")
      if heading then paragraph=paragraph:sub(#heading+1) end
      paragraph=paragraph:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1")
      local bold, code=heading ~= nil, in_code
      local runs, current, used={}, "", 0
      local function flush(style)
        if current ~= "" then runs[#runs+1]={text=current, style=style, width=measure(current)}; current="" end
      end
      local function emit()
        flush(code and "code" or bold and "bold" or "text")
        output[#output+1]={runs=runs, code=in_code, heading=heading ~= nil}
        runs={}; used=0
      end
      local index=1
      while index <= #paragraph do
        local pair=paragraph:sub(index,index+1)
        if not in_code and (pair == "**" or pair == "__") then
          flush(code and "code" or bold and "bold" or "text"); bold=not bold; index=index+2
        elseif not in_code and paragraph:sub(index,index) == "`" then
          flush(code and "code" or bold and "bold" or "text"); code=not code; index=index+1
        else
          local token=paragraph:match("^%s+", index) or paragraph:match("^[^%s*_`]+", index)
            or paragraph:sub(index, (utf8.offset(paragraph, 2, index) or #paragraph+1)-1)
          local token_width=measure(token)
          if used+token_width > width and used > 0 and not token:match("^%s+$") then emit() end
          for _,point in utf8.codes(token) do
            local character=utf8.char(point)
            local size=measure(character)
            if used+size > width and used > 0 then emit() end
            if used > 0 or not character:match("%s") or in_code then
              current=current .. character; used=used+size
            end
          end
          index=index+#token
        end
      end
      emit()
    end
  end
  return output
end

function Ui.sidebar_bounds(width, height, scale, preferred, collapsed, minimum)
  scale=math.max(1, scale or 1)
  local margin, top=6*scale, 30*scale
  local maximum=math.max(1, width-2*margin)
  local panel_width=math.min(maximum, math.max((minimum and minimum.width) or 0, (preferred or 270)*scale))
  local panel_height=collapsed and math.max(70*scale, (minimum and minimum.height) or 0) or height-top-margin
  return {x=math.max(margin, width-panel_width-margin), y=math.min(top, math.max(0,height-1)),
    width=math.floor(panel_width), height=math.max(1, math.floor(math.min(panel_height,height-top-margin)))}
end

return Ui
