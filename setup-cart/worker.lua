--[[pod_format="raw",created="2026-11-22 00:00:00",modified="2026-11-22 00:00:00",revision=0]]
-- HTTP worker for setup wizard
-- Handles all fetch() calls so the main process stays responsive

local parent = nil
local req_id = 0

function _init()
  parent = env().parent_pid

  on_event("http_get", function(msg)
    local ok, r = pcall(fetch, msg.url)
    send_message(parent, {
      event = "http_response",
      id    = msg.id,
      ok    = ok and type(r)=="table",
      data  = ok and r or nil,
    })
  end)

  on_event("http_post", function(msg)
    local ok, r = pcall(fetch, msg.url, {
      method  = "POST",
      headers = {["content-type"] = "application/x-www-form-urlencoded"},
      body    = msg.body,
    })
    send_message(parent, {
      event = "http_response",
      id    = msg.id,
      ok    = ok and type(r)=="table",
      data  = ok and r or nil,
    })
  end)

  on_event("quit", function()
    exit()
  end)
end

function _update() end
