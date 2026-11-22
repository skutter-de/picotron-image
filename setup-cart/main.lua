--[[pod_format="raw",created="2026-11-22 00:00:00",modified="2026-11-22 00:00:00",revision=0]]
-- Picotron Linux Initial Setup Wizard
-- Communicates with picotron-setup-daemon on localhost:2425

local screen = "welcome"
local daemon_url = "http://127.0.0.1:2425"

local input_username = ""
local input_password = ""
local input_active = "username"
local status_msg = ""
local media_found = false
local poll_timer = 0

-- colors
local C_BG  = 0   -- black
local C_FG  = 7   -- white
local C_DIM = 5   -- dark grey
local C_ACC = 11  -- green (accent)
local C_BAR = 1   -- dark blue (header bar)
local C_ERR = 8   -- red

function _init()
  window{title="Picotron Setup", width=480, height=270, pauseable=false}
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

local function input_box(label, x, y, value, active, hidden)
  print(label, x, y, C_DIM)
  local bw, bh = 280, 13
  local bx, by = x, y + 11
  local col = active and C_ACC or C_DIM
  rect(bx, by, bx+bw, by+bh, col)
  local display = hidden and string.rep("*", #value) or value
  if active then display = display .. "_" end
  print(display, bx+3, by+3, C_FG)
end

-- WELCOME
local function draw_welcome()
  draw_header("Welcome")
  center_text("Welcome to Picotron Linux", 65, C_FG)
  center_text("This wizard will help you set up your system.", 80, C_DIM)
  center_text("You will create a user account for this system.", 105, C_DIM)
  center_text("Press ENTER to begin", 200, C_ACC)
end

-- INSERT MEDIA
local function draw_media()
  draw_header("Install Picotron")
  if media_found then
    center_text("Picotron data found!", 90, C_ACC)
    center_text("Press ENTER to continue", 200, C_ACC)
  else
    center_text("Please insert a device with Picotron data", 70, C_FG)
    center_text("The partition must have the label: PICOTRON", 84, C_DIM)
    local dots = string.rep(".", (poll_timer // 20) % 4)
    center_text("Waiting" .. dots, 190, C_DIM)
  end
end

-- CREATE USER
local function draw_create_user()
  draw_header("Create Account")
  center_text("Create the first user account for this system.", 55, C_DIM)
  input_box("Username:", 100, 80,  input_username, input_active=="username", false)
  input_box("Password:", 100, 120, input_password, input_active=="password", true)
  if status_msg ~= "" then
    center_text(status_msg, 165, C_ERR)
  end
  print("TAB: switch field   ENTER: confirm", 100, 215, C_DIM)
end

-- DONE
local function draw_done()
  draw_header("Setup Complete")
  center_text("Your system is ready.", 100, C_FG)
  center_text("Starting the login screen...", 115, C_DIM)
end

function _draw()
  if     screen == "welcome"     then draw_welcome()
  elseif screen == "media"       then draw_media()
  elseif screen == "create_user" then draw_create_user()
  elseif screen == "done"        then draw_done()
  end
end

local function daemon_get(path)
  local ok, res = pcall(fetch, daemon_url .. path)
  if ok and type(res) == "table" then return res end
  return nil
end

local function daemon_post(path, body)
  local ok, res = pcall(fetch, daemon_url .. path,
    {method="POST", headers={["content-type"]="application/x-www-form-urlencoded"}, body=body})
  if ok and type(res) == "table" then return res end
  return nil
end

function _update()
  poll_timer += 1

  if screen == "welcome" then
    if keyp("return") then screen = "create_user" end

  elseif screen == "media" then
    if poll_timer % 120 == 1 then
      local r = daemon_get("/setup/picotron_status")
      if r and r.installed then media_found = true end
    end
    if media_found and keyp("return") then screen = "create_user" end

  elseif screen == "create_user" then
    if keyp("tab") then
      input_active = input_active == "username" and "password" or "username"
      status_msg = ""
    end
    local ch = readtext()
    if ch and #ch > 0 then
      for c in ch:gmatch(".") do
        if input_active == "username" and #input_username < 32 then
          input_username ..= c
        elseif input_active == "password" and #input_password < 64 then
          input_password ..= c
        end
      end
    end
    if keyp("backspace") then
      if input_active == "username" and #input_username > 0 then
        input_username = input_username:sub(1, -2)
      elseif input_active == "password" and #input_password > 0 then
        input_password = input_password:sub(1, -2)
      end
      status_msg = ""
    end
    if keyp("return") then
      if #input_username < 1 then
        status_msg = "Username cannot be empty"
      elseif #input_password < 4 then
        status_msg = "Password must be >= 4 characters"
      else
        status_msg = "Creating user..."
        local r = daemon_post("/setup/create_user",
          "username=" .. input_username .. "&password=" .. input_password)
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
