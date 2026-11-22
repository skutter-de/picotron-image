--[[pod_format="raw",created="2026-11-21 00:00:00",modified="2026-11-21 00:00:00",revision=0]]
-- Socket worker for VT100 terminal
-- Headless process: _update() keeps it alive, on_event() receives writes from parent
-- env().host, env().port = TCP target; env().parent_pid = auto-set by Picotron

local sock = nil
local parent = nil
local was_connected = false

function _init()
    parent = env().parent_pid
    sock = socket("tcp://"..env().host..":"..env().port)

    on_event("term_write", function(msg)
        if sock and msg.data then sock:write(msg.data) end
    end)
    on_event("term_resize", function(msg)
        if sock and msg.cols and msg.rows then
            sock:write(string.format("\x1b[8;%d;%dt", msg.rows, msg.cols))
        end
    end)
end

function _update()
    if not sock or sock:status()=="disconnected" then
        if was_connected then
            send_message(parent, {event="term_exit"})
            exit()
            return
        end
        sock = socket("tcp://"..env().host..":"..env().port)
        return
    end
    was_connected = true
    local data = sock:read()
    if data and #data > 0 then
        send_message(parent, {event="term_data", data=data})
    end
end
