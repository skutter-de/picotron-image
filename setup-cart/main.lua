--[[pod_format="raw",created="2026-11-22 00:00:00",modified="2026-11-22 00:00:00",revision=0]]
-- Picotron Linux Initial Setup Wizard
-- Screens: language -> keymap -> create_user -> done

local daemon_url = "http://127.0.0.1:2425"
local screen = "language"

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
  {"us      - English (US)",  "us"},
  {"de      - Deutsch",       "de"},
  {"fr      - Francais",      "fr"},
  {"es      - Espanol",       "es"},
  {"it      - Italiano",      "it"},
  {"br-abnt2- Portugues (BR)","br-abnt2"},
  {"nl      - Nederlands",    "nl"},
  {"pl      - Polski",        "pl"},
  {"ru      - Russky",        "ru"},
  {"jp106   - Japanese",      "jp106"},
  {"uk      - English (UK)",  "uk"},
  {"dvorak  - Dvorak",        "dvorak"},
  {"colemak - Colemak",       "colemak"},
}

local lang_sel  = 1
local kmap_sel  = 1
local list_scroll = 0
local VISIBLE   = 7

local input_username = ""
local input_password = ""
local input_confirm  = ""
local input_active   = "username"
local status_msg     = ""

local C_BG   = 0
local C_FG   = 7
local C_DIM  = 5
local C_ACC  = 11
local C_BAR  = 1
local C_ERR  = 8
local C_SEL  = 2

function _init()
  window{title="Picotron Setup", width=480, height=270, pauseable=false}
  local ok, r = pcall(fetch, daemon_url.."/setup/state")
  if ok and type(r)=="table" and r.screen then
    screen = r.screen
  end
end

local function center_text(text, y, col)
  local w = #text * 5
  print(text, 240 - w//2, y, col or C_FG)
end

local function draw_header(title)
  cls(C_BG)
  rectfill(0, 0, 479, 12, C_BAR)
  print("Picotron Linux Setup", 4, 3, C_DIM)
  center_text(title, 28, C_ACC)
  line(60, 38, 419, 38, C_DIM)
end

local function draw_list(items, sel, scroll, lx, ly)
  local item_h = 14
  for i = 1, VISIBLE do
    local idx = i + scroll
    if idx > #items then break end
    local label = items[idx][1]
    local y = ly + (i-1)*item_h
    if idx == sel then
      rectfill(lx-4, y-1, lx+356, y+item_h-3, C_SEL)
      print(label, lx, y, C_ACC)
    else
      print(label, lx, y, C_FG)
    end
  end
  if #items > VISIBLE then
    local bar_h = ly + VISIBLE*14 - ly
    local thumb_h = max(6, 14*VISIBLE*VISIBLE//#items)
    local range = 14*VISIBLE - thumb_h
    local thumb_y = ly + range * scroll // (#items - VISIBLE)
    line(445, ly, 445, ly+VISIBLE*14, C_DIM)
    rectfill(443, thumb_y, 447, thumb_y+thumb_h, C_DIM)
  end
end

local function input_box(label, x, y, value, active, hidden)
  print(label, x, y, C_DIM)
  rect(x, y+11, x+280, y+24, active and C_ACC or C_DIM)
  local display = hidden and string.rep("*", #value) or value
  if active then display = display.."_" end
  print(display, x+3, y+14, C_FG)
end

local function draw_language()
  draw_header("Select Language")
  center_text("Choose the system language:", 48, C_DIM)
  draw_list(languages, lang_sel, list_scroll, 90, 62)
  print("arrow keys: navigate   enter: confirm", 90, 240, C_DIM)
end

local function draw_keymap()
  draw_header("Select Keyboard Layout")
  center_text("Choose your keyboard layout:", 48, C_DIM)
  draw_list(keymaps, kmap_sel, list_scroll, 90, 62)
  print("arrow keys: navigate   enter: apply & continue", 90, 240, C_DIM)
end

local function draw_restarting()
  cls(C_BG)
  center_text("Applying keyboard layout...", 125, C_DIM)
  center_text("Restarting session.", 140, C_DIM)
end

local function draw_create_user()
  draw_header("Create User Account")
  center_text("Create the first user for this system.", 50, C_DIM)
  input_box("Username:",         100, 54,  input_username, input_active=="username", false)
  input_box("Password:",         100, 92,  input_password, input_active=="password", true)
  input_box("Confirm password:", 100, 130, input_confirm,  input_active=="confirm",  true)
  if status_msg ~= "" then
    center_text(status_msg, 183, C_ERR)
  end
  print("tab: switch field   enter: confirm", 100, 220, C_DIM)
end

local function draw_done()
  draw_header("Setup Complete")
  center_text("Your system is ready.", 100, C_FG)
  center_text("Starting login screen...", 115, C_DIM)
end

function _draw()
  if     screen=="language"    then draw_language()
  elseif screen=="keymap"      then draw_keymap()
  elseif screen=="restarting"  then draw_restarting()
  elseif screen=="create_user" then draw_create_user()
  elseif screen=="done"        then draw_done()
  else   cls(C_BG)
  end
end

local function daemon_post(path, body)
  local ok, r = pcall(fetch, daemon_url..path,
    {method="POST",
     headers={["content-type"]="application/x-www-form-urlencoded"},
     body=body})
  if ok and type(r)=="table" then return r end
  return nil
end

local function list_nav(items, sel, scroll)
  if keyp("up") and sel > 1 then
    sel -= 1
    if sel < scroll+1 then scroll = sel-1 end
  end
  if keyp("down") and sel < #items then
    sel += 1
    if sel > scroll+VISIBLE then scroll = sel-VISIBLE end
  end
  return sel, scroll
end

function _update()
  if screen=="language" then
    lang_sel, list_scroll = list_nav(languages, lang_sel, list_scroll)
    if keyp("return") then
      daemon_post("/setup/set_locale", "locale="..languages[lang_sel][2])
      screen = "keymap"
      list_scroll = 0
      kmap_sel = 1
    end

  elseif screen=="keymap" then
    kmap_sel, list_scroll = list_nav(keymaps, kmap_sel, list_scroll)
    if keyp("return") then
      daemon_post("/setup/apply_keymap", "keymap="..keymaps[kmap_sel][2])
      screen = "restarting"
    end

  elseif screen=="create_user" then
    if keyp("tab") then
      if     input_active=="username" then input_active = "password"
      elseif input_active=="password" then input_active = "confirm"
      else                                 input_active = "username"
      end
      status_msg = ""
    end
    local ch = readtext()
    if ch and #ch > 0 then
      for c in ch:gmatch(".") do
        if input_active=="username" and #input_username < 32 then
          input_username ..= c
        elseif input_active=="password" and #input_password < 64 then
          input_password ..= c
        elseif input_active=="confirm" and #input_confirm < 64 then
          input_confirm ..= c
        end
      end
    end
    if keyp("backspace") then
      if input_active=="username" and #input_username > 0 then
        input_username = input_username:sub(1,-2)
      elseif input_active=="password" and #input_password > 0 then
        input_password = input_password:sub(1,-2)
      elseif input_active=="confirm" and #input_confirm > 0 then
        input_confirm = input_confirm:sub(1,-2)
      end
      status_msg = ""
    end
    if keyp("return") then
      if #input_username < 1 then
        status_msg = "Username cannot be empty"
      elseif #input_password < 4 then
        status_msg = "Password must be >= 4 characters"
      elseif input_password ~= input_confirm then
        status_msg = "Passwords do not match"
      else
        status_msg = "Creating user..."
        local r = daemon_post("/setup/create_user",
          "username="..input_username.."&password="..input_password)
        if r and r.ok then
          screen = "done"
          daemon_post("/setup/finish", "")
        else
          status_msg = (r and r.error) or "Could not reach setup daemon"
        end
      end
    end
  end
end
