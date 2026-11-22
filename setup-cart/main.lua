--[[pod_format="raw",created="2026-11-22 00:00:00",modified="2026-11-22 00:00:00",revision=0]]
-- Picotron Linux Initial Setup Wizard
-- Native Picotron GUI style; HTTP comms via worker

local DAEMON  = "http://127.0.0.1:2425"
local WIN_W, WIN_H = 480, 270
local HDR_H   = 38   -- header height

-- Picotron native palette
local C_BG    = 6    -- light grey (window background)
local C_FG    = 1    -- dark navy (primary text)
local C_DIM   = 5    -- dark grey (secondary text)
local C_ACC   = 13   -- purple (borders, accent)
local C_BAR   = 1    -- dark navy (header bar)
local C_BAR_T = 7    -- white (header text)
local C_SEL_B = 2    -- dark blue (list selection bg)
local C_SEL_T = 7    -- white (list selection text)
local C_BTN_B = 6    -- grey (button bg)
local C_BTN_H = 7    -- lighter grey (button hover)
local C_BTN_T = 1    -- dark (button text)
local C_INPUT = 7    -- white (input bg)
local C_ERR   = 8    -- red (error text)

local screen     = "language"
local worker_pid = nil
local gui        = nil
local req_id     = 0
local callbacks  = {}

local lang_sel = 1
local kmap_sel = 1
local status_msg = ""

-- references to text editor fields (create_user screen)
local username_ed, password_ed, confirm_ed

local languages = {
  {"English (US)",   "en_US.UTF-8"},
  {"Deutsch",        "de_DE.UTF-8"},
  {"Francais",       "fr_FR.UTF-8"},
  {"Espanol",        "es_ES.UTF-8"},
  {"Italiano",       "it_IT.UTF-8"},
  {"Portugues (BR)", "pt_BR.UTF-8"},
  {"Nederlands",     "nl_NL.UTF-8"},
  {"Polski",         "pl_PL.UTF-8"},
  {"Russky",         "ru_RU.UTF-8"},
  {"Japanese",       "ja_JP.UTF-8"},
}

local keymaps = {
  {"us       - English (US)",  "us"},
  {"de       - Deutsch",       "de"},
  {"fr       - Francais",      "fr"},
  {"es       - Espanol",       "es"},
  {"it       - Italiano",      "it"},
  {"br-abnt2 - Portugues",     "br-abnt2"},
  {"nl       - Nederlands",    "nl"},
  {"pl       - Polski",        "pl"},
  {"ru       - Russky",        "ru"},
  {"jp106    - Japanese",      "jp106"},
  {"uk       - English (UK)",  "uk"},
  {"dvorak   - Dvorak",        "dvorak"},
  {"colemak  - Colemak",       "colemak"},
}

-- -- helpers -------------------------------------------------------------------

local function http_post(path, body, cb)
  req_id += 1
  callbacks[req_id] = cb
  send_message(worker_pid, {event="http_post", id=req_id, url=DAEMON..path, body=body})
end

local function http_get(path, cb)
  req_id += 1
  callbacks[req_id] = cb
  send_message(worker_pid, {event="http_get", id=req_id, url=DAEMON..path})
end

local function center_text(text, y, col)
  print(text, WIN_W//2 - #text*5//2, y, col or C_FG)
end

-- Draw a Picotron-style section header bar
local function draw_section_bar(text, y, w)
  w = w or WIN_W
  rectfill(0, y, w-1, y+13, C_BAR)
  print(text, 6, y+3, C_BAR_T)
end

-- -- scrollable list with native scrollbars ------------------------------------

local ROW_H    = 14
local VISIBLE  = 7
local SCROLL_W = 10

local function attach_list(parent, x, y, w, items, sel_ref, on_select)
  local vp_h    = VISIBLE * ROW_H
  local total_h = #items * ROW_H

  local container = parent:attach({x=x, y=y, width=w+SCROLL_W, height=vp_h, clip_to_parent=true})
  local contents  = container:attach({x=0, y=0, width=w, height=total_h})

  function contents:draw()
    -- list background
    rectfill(0, 0, self.width-1, self.height-1, C_INPUT)
    for i, item in ipairs(items) do
      local ry = (i-1)*ROW_H
      if i == sel_ref.v then
        rectfill(0, ry, self.width-1, ry+ROW_H-2, C_SEL_B)
        print(item[1], 4, ry+3, C_SEL_T)
      else
        print(item[1], 4, ry+3, C_FG)
      end
    end
    -- border around whole list
    rect(0, 0, self.width-1, total_h-1, C_ACC)
  end

  local function scroll_to_sel()
    local top    = -(sel_ref.v-1)*ROW_H
    local bottom = -(sel_ref.v)*ROW_H + vp_h
    if contents.y < top    then contents.y = top    end
    if contents.y > bottom then contents.y = bottom end
    contents.y = mid(-(total_h-vp_h), contents.y, 0)
  end

  function contents:update()
    if keyp("up")   and sel_ref.v > 1      then sel_ref.v -= 1; scroll_to_sel() end
    if keyp("down") and sel_ref.v < #items then sel_ref.v += 1; scroll_to_sel() end
    if keyp("return") then on_select(items[sel_ref.v]) end
  end

  function contents:click(msg)
    local clicked = flr((msg.my - self.y) / ROW_H) + 1
    if clicked >= 1 and clicked <= #items then sel_ref.v = clicked end
  end

  function contents:mousewheel(msg)
    self.y = mid(-(total_h-vp_h), self.y + msg.wheel_y*ROW_H, 0)
  end

  container:attach_scrollbars({bgcol=6, fgcol=5})
  return contents
end

-- -- masked password field (custom, since text_editor can't mask) --------------

local function attach_password_field(parent, x, y, w, h)
  local el = parent:attach({x=x, y=y, width=w, height=h, str=""})

  function el:draw()
    local focused = self:has_keyboard_focus()
    rrectfill(0, 0, self.width-1, self.height-1, 2, C_INPUT)
    rrect(0, 0, self.width-1, self.height-1, 2, focused and C_ACC or C_DIM)
    local display = string.rep("*", #self.str)
    if focused then display = display.."_" end
    print(display, 3, 3, C_FG)
  end

  function el:click()
    self:set_keyboard_focus(true)
    readtext(true)
  end

  function el:update()
    if self:has_keyboard_focus() then
      local ch = readtext()
      if ch and #ch > 0 then self.str = self.str..ch end
      if keyp("backspace") and #self.str > 0 then
        self.str = self.str:sub(1,-2)
      end
    end
  end

  return el
end

-- -- screens -------------------------------------------------------------------

local function label_el(parent, text, x, y)
  parent:attach({x=x, y=y, width=#text*5+4, height=10,
    draw=function(self) print(text, 0, 0, C_DIM) end})
end

local function setup_language()
  gui = create_gui()
  local root = gui:attach({x=0, y=HDR_H, width=WIN_W, height=WIN_H-HDR_H})
  -- subheader
  root:attach({x=0, y=0, width=WIN_W, height=16,
    draw=function(self)
      rectfill(0,0,self.width-1,self.height-1, C_BG)
      print("Choose the system language:", 10, 4, C_DIM)
    end})
  local sel = {v=lang_sel}
  local function do_select_lang()
    local item = languages[sel.v]
    lang_sel = sel.v
    http_post("/setup/set_locale", "locale="..item[2], function()
      screen = "keymap"; kmap_sel = 1; setup_keymap()
    end)
  end
  attach_list(root, 10, 18, WIN_W-20, languages, sel, do_select_lang)
  root:attach_button({
    x=WIN_W//2-50, y=18+VISIBLE*ROW_H+6, width=100, height=18,
    label="Continue",
    highlight=true,
    tap=function(self) do_select_lang() end,
  })
  root:attach({x=0, y=WIN_H-HDR_H-14, width=WIN_W, height=12,
    draw=function(self)
      rectfill(0,0,self.width-1,self.height-1, C_BG)
      print("up/down  enter  or click to select, then Continue", 10, 1, C_DIM)
    end})
end

local function setup_keymap()
  gui = create_gui()
  local root = gui:attach({x=0, y=HDR_H, width=WIN_W, height=WIN_H-HDR_H})
  root:attach({x=0, y=0, width=WIN_W, height=16,
    draw=function(self)
      rectfill(0,0,self.width-1,self.height-1, C_BG)
      print("Choose your keyboard layout:", 10, 4, C_DIM)
    end})
  local sel = {v=kmap_sel}
  local function do_select_keymap()
    local item = keymaps[sel.v]
    kmap_sel = sel.v
    http_post("/setup/apply_keymap", "keymap="..item[2], function()
      screen = "restarting"; gui = nil
    end)
  end
  attach_list(root, 10, 18, WIN_W-20, keymaps, sel, do_select_keymap)
  root:attach_button({
    x=WIN_W//2-50, y=18+VISIBLE*ROW_H+6, width=100, height=18,
    label="Continue",
    highlight=true,
    tap=function(self) do_select_keymap() end,
  })
  root:attach({x=0, y=WIN_H-HDR_H-14, width=WIN_W, height=12,
    draw=function(self)
      rectfill(0,0,self.width-1,self.height-1, C_BG)
      print("up/down  enter  or click to select, then Continue", 10, 1, C_DIM)
    end})
end

local function setup_create_user()
  status_msg = ""
  gui = create_gui()
  local root = gui:attach({x=0, y=HDR_H+4, width=WIN_W, height=WIN_H-HDR_H-4})

  -- label + text_editor for username
  label_el(root, "Username:", 10, 8)
  username_ed = root:attach_text_editor({
    x=10, y=20, width=460, height=16,
    max_lines=1,
    key_callback={
      tab   = function() password_ed:set_keyboard_focus(true); readtext(true) end,
      enter = function()
        password_ed:set_keyboard_focus(true); readtext(true)
      end,
    },
  })
  username_ed:set_text({""})

  -- password (masked - custom field)
  label_el(root, "Password:", 10, 44)
  password_ed = attach_password_field(root, 10, 56, 460, 16)

  label_el(root, "Confirm password:", 10, 80)
  confirm_ed = attach_password_field(root, 10, 92, 460, 16)

  -- error text
  root:attach({x=0, y=118, width=WIN_W, height=12,
    draw=function(self)
      if status_msg ~= "" then center_text(status_msg, 0, C_ERR) end
    end})

  -- hint
  root:attach({x=0, y=WIN_H-HDR_H-30, width=WIN_W, height=12,
    draw=function(self)
      print("tab: switch field   enter: confirm", 10, 0, C_DIM)
    end})

  -- Create button
  root:attach_button({
    x=WIN_W//2-50, y=WIN_H-HDR_H-50, width=100, height=18,
    label="Create Account",
    highlight=true,
    tap=function(self)
      local u = username_ed:get_text()[1] or ""
      local p = password_ed.str
      local c = confirm_ed.str
      if #u < 1 then
        status_msg = "Username cannot be empty"
      elseif #p < 4 then
        status_msg = "Password must be >= 4 characters"
      elseif p ~= c then
        status_msg = "Passwords do not match"
      else
        status_msg = "Creating user..."
        http_post("/setup/create_user", "username="..u.."&password="..p,
          function(ok, data)
            if ok and data and data.ok then
              screen = "done"; gui = nil
              http_post("/setup/finish", "", function() end)
            else
              status_msg = (data and data.error) or "Error creating user"
            end
          end)
      end
    end,
  })

  -- tab between password fields
  root:attach({x=0, y=0, width=0, height=0,
    update=function(self)
      if keyp("tab") then
        if password_ed:has_keyboard_focus() then
          password_ed:set_keyboard_focus(false)
          confirm_ed:set_keyboard_focus(true); readtext(true)
        elseif confirm_ed:has_keyboard_focus() then
          confirm_ed:set_keyboard_focus(false)
          username_ed:set_keyboard_focus(true); readtext(true)
        end
        status_msg = ""
      end
      if keyp("return") then
        if password_ed:has_keyboard_focus() or confirm_ed:has_keyboard_focus() then
          -- forward to button tap logic
          local u = username_ed:get_text()[1] or ""
          local p = password_ed.str
          local c = confirm_ed.str
          if #u < 1 then status_msg = "Username cannot be empty"
          elseif #p < 4 then status_msg = "Password must be >= 4 characters"
          elseif p ~= c then status_msg = "Passwords do not match"
          else
            status_msg = "Creating user..."
            http_post("/setup/create_user", "username="..u.."&password="..p,
              function(ok, data)
                if ok and data and data.ok then
                  screen = "done"; gui = nil
                  http_post("/setup/finish", "", function() end)
                else
                  status_msg = (data and data.error) or "Error creating user"
                end
              end)
          end
        end
      end
    end})

  -- give focus to username on start
  username_ed:set_keyboard_focus(true)
  readtext(true)
end

-- -- header draw ---------------------------------------------------------------

local TITLES = {
  language    = "Select Language",
  keymap      = "Select Keyboard Layout",
  restarting  = "Applying Keyboard Layout",
  create_user = "Create User Account",
  done        = "Setup Complete",
}

local function draw_frame()
  -- window background
  cls(C_BG)
  -- title bar
  rectfill(0, 0, WIN_W-1, HDR_H-1, C_BAR)
  local title = "Picotron Linux Setup -- " .. (TITLES[screen] or "")
  print(title, 6, HDR_H//2 - 3, C_BAR_T)
  -- separator
  line(0, HDR_H, WIN_W-1, HDR_H, C_ACC)
end

-- -- lifecycle -----------------------------------------------------------------

function _init()
  window{title="Picotron Setup", width=WIN_W, height=WIN_H, pauseable=false}

  worker_pid = create_process("/desktop/setup.p64/worker.lua")

  on_event("http_response", function(msg)
    local cb = callbacks[msg.id]
    if cb then callbacks[msg.id] = nil; cb(msg.ok, msg.data) end
  end)

  on_event("shutdown", function()
    if worker_pid then send_message(worker_pid, {event="quit"}) end
    exit()
  end)

  http_get("/setup/state", function(ok, data)
    local s = ok and data and data.screen or "language"
    screen = s
    if     s == "create_user" then setup_create_user()
    elseif s == "keymap"      then setup_keymap()
    else                           setup_language()
    end
  end)
end

function _update()
  if gui then gui:update_all() end
end

function _draw()
  draw_frame()

  if screen == "restarting" then
    center_text("Applying keyboard layout...", WIN_H//2 - 6, C_DIM)
    center_text("Session will restart.", WIN_H//2 + 8, C_DIM)
    return
  end
  if screen == "done" then
    center_text("Your system is ready.", WIN_H//2 - 6, C_FG)
    center_text("Starting login screen...", WIN_H//2 + 8, C_DIM)
    return
  end

  if gui then gui:draw_all() end
end
