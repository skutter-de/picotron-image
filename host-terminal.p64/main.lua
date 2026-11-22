--[[pod_format="raw",created="2026-11-21 00:00:00",modified="2026-11-21 00:00:00",revision=0]]
-- VT100 Terminal Emulator for Picotron
-- Socket I/O handled by worker.lua (child process)

local HOST = "localhost"
local PORT = 2323
local COLS = 80
local ROWS = 22
local CHAR_W = 5
local CHAR_H = 11
local WIN_W = COLS * CHAR_W   -- 400
local WIN_H = ROWS * CHAR_H   -- 242
local SCROLL_BACK = 1000

local ansi_col = {
    [0]=0,[1]=8,[2]=3,[3]=10,[4]=2,[5]=14,[6]=6,[7]=7,
    [8]=5,[9]=9,[10]=11,[11]=12,[12]=4,[13]=15,[14]=13,[15]=7,
}

-- Picotron-Palette RGB (PICO-8-kompatibel, Indizes 0-15)
local PTRON_PAL = {
    {0,0,0},{29,43,83},{126,37,83},{0,135,81},{171,82,54},{95,87,79},
    {194,195,199},{255,241,232},{255,0,77},{255,163,0},{255,236,39},
    {0,228,54},{41,173,255},{131,118,156},{255,119,168},{255,204,170}
}
local function rgb_to_ptron(r,g,b)
    local avg=(r+g+b)//3
    if math.abs(r-avg)<=20 and math.abs(g-avg)<=20 and math.abs(b-avg)<=20 then
        if avg<25 then return 0 elseif avg<75 then return 5
        elseif avg<170 then return 6 else return 7 end
    end
    -- Orange/Braun: hohes R, kaum Blau, G >= B (Braun/Orange hat mehr Grün als Blau)
    if r>180 and b<r*0.35 and b<80 and g>=b then
        if g>80 then return 9 else return 4 end
    end
    -- Rötlich-Pink: R dominant, G klein, B signifikant (kein Braun)
    if r>g*1.5 and b>60 and g<70 and r>120 then
        local d2=(r-126)^2*2+(g-37)^2*4+(b-83)^2
        local d8=(r-255)^2*2+(g-0)^2*4+(b-77)^2
        return d2<d8 and 2 or 8
    end
    local best,bestd=7,1e9
    for i,c in ipairs(PTRON_PAL) do
        local d=(r-c[1])^2*2+(g-c[2])^2*4+(b-c[3])^2
        if d<bestd then bestd=d;best=i-1 end
    end
    return best
end
local CUBE={0,95,135,175,215,255}
local function ansi256(n)
    if n<16 then return ansi_col[n] or 7 end
    if n>=232 then local v=8+(n-232)*10;return rgb_to_ptron(v,v,v) end
    local idx=n-16
    return rgb_to_ptron(CUBE[idx//36+1],CUBE[(idx//6)%6+1],CUBE[idx%6+1])
end

local cells
local scrollback = {}
local cx, cy = 1, 1
local scx, scy = 1, 1
local fg, bg = 7, 0
local bold = false
local dim = false
local scroll_top, scroll_bot = 1, ROWS
local esc_state = 0
local esc_buf = ""
local worker_pid = nil
local show_cursor = true
local ipc_timer = 0
local dirty = true
local last_contents_y = 0
local last_cursor_blink = -1
local auto_scroll = true
local bracketed_paste = false
local mouse_mode = 0     -- 0=aus, 1000=click, 1002=drag, 1003=any
local mouse_sgr  = false -- false=X10-Encoding, true=SGR (<b;x;yM)
local last_mcol  = 0
local last_mrow  = 0
local utf8_buf = ""
local utf8_need = 0
local prev_min_row = 1        -- oberste Zeile des vorherigen Render-Bereichs
local cur_min_row  = ROWS+1  -- oberste Zeile im aktuellen term_data
local last_was_erase_line = false  -- Ink-eraseLines-Muster: \x1b[2K direkt vor \x1b[A
local last_visual_offset = 0 -- letzter visual_offset (Zeilen oberhalb Dialog verstecken)
local dialog_scy = 0        -- cy beim \x1b7 (Cursor-Save), Basis für Inline-Redirect
local inline_sel_cy = 0     -- Zeile der Inline-Selection (gefunden nach erstem BSU-Block)
local in_bsu = false        -- sind wir in einem BSU-Block?
local dialog_initial_done = false -- wurde der erste BSU-Block nach \x1b7 schon verarbeitet?
local saved_dialog_rows = nil     -- gespeicherte Header-Zeilen (Trennstrich etc.) aus Initial-Render

-- Auswahl-State
local sel_anchor = nil   -- {row=abs_row, col=col}
local sel_cur    = nil
local sel_active = false
local was_mb     = 0


local gui, container, contents

local function mk_cell(ch) return {ch=ch or " ", fg=fg, bg=bg} end

local function init_cells()
    cells = {}
    for y=1,ROWS do
        cells[y] = {}
        for x=1,COLS do cells[y][x] = mk_cell(" ") end
    end
end

local function scroll_up(t, b)
    if t == 1 then
        scrollback[#scrollback+1] = cells[t]
        if #scrollback > SCROLL_BACK then
            table.remove(scrollback, 1)
            -- Auswahl-Anker anpassen wenn Scrollback getrimmt wird
            if sel_anchor then sel_anchor.row = sel_anchor.row - 1 end
            if sel_cur    then sel_cur.row    = sel_cur.row    - 1 end
        end
        auto_scroll = true  -- neue Zeile im Scrollback → snap to bottom (xterm.js)
        prev_min_row = 1    -- Scrollback-Modus: eraseLines-Klemmung deaktivieren
    end
    for y=t,b-1 do cells[y]=cells[y+1] end
    cells[b]={}
    for x=1,COLS do cells[b][x]=mk_cell(" ") end
end

local function scroll_down(t, b)
    for y=b,t+1,-1 do cells[y]=cells[y-1] end
    cells[t]={}
    for x=1,COLS do cells[t][x]=mk_cell(" ") end
end

local function erase_cells(x1,x2,y)
    if dialog_initial_done and dialog_scy>0 and inline_sel_cy>0 then
        if y==dialog_scy then y=inline_sel_cy
        elseif y==dialog_scy+1 then y=inline_sel_cy+1 end
    end
    for x=x1,x2 do cells[y][x]=mk_cell(" ") end
end

local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end

local function parse_sgr(params)
    if #params==0 then params={0} end
    local i=1
    while i<=#params do
        local p=params[i]
        if p==0 then fg,bg,bold,dim=7,0,false,false
        elseif p==1 then bold=true
        elseif p==2 then dim=true
        elseif p==22 then bold=false;dim=false
        elseif p>=30 and p<=37 then fg=ansi_col[p-30] or 7
        elseif p==39 then fg=7
        elseif p>=40 and p<=47 then bg=ansi_col[p-40] or 0
        elseif p==49 then bg=0
        elseif p>=90 and p<=97 then fg=ansi_col[p-90+8] or 7
        elseif p>=100 and p<=107 then bg=ansi_col[p-100+8] or 0
        elseif p==38 then
            if params[i+1]==5 then fg=ansi256(params[i+2] or 0);i=i+2
            elseif params[i+1]==2 then fg=rgb_to_ptron(params[i+2] or 0,params[i+3] or 0,params[i+4] or 0);i=i+4 end
        elseif p==48 then
            if params[i+1]==5 then bg=ansi256(params[i+2] or 0);i=i+2
            elseif params[i+1]==2 then bg=rgb_to_ptron(params[i+2] or 0,params[i+3] or 0,params[i+4] or 0);i=i+4 end
        end
        i=i+1
    end
end

local function parse_csi(cmd, buf)
    local priv = buf:sub(1,1)=="?" and buf:sub(2) or buf
    local params={}
    for s in (priv..";"):gmatch("([^;]*);") do
        params[#params+1]=tonumber(s) or 0
    end
    local p1=params[1] or 0
    local p2=params[2] or 0

    -- eraseLines-Erkennung: speichere ob vorheriger CSI-Befehl \x1b[2K war
    local prev_erase = last_was_erase_line
    last_was_erase_line = false  -- Standard: zurücksetzen

    if cmd=="A" then
        -- Bei Ink-eraseLines-Muster (\x1b[2K direkt davor): Cursor auf prev_min_row klemmen
        -- damit eraseLines den Bereich oberhalb des Dialogs (Shell-Prompt) nicht löscht
        if prev_erase and prev_min_row > 1 then
            cy = math.max(cy - math.max(1,p1), prev_min_row)
        else
            cy = clamp(cy - math.max(1,p1), 1, ROWS)
        end
    elseif cmd=="B" then cy=clamp(cy+math.max(1,p1),1,ROWS)
    elseif cmd=="C" then cx=clamp(cx+math.max(1,p1),1,COLS)
    elseif cmd=="D" then cx=clamp(cx-math.max(1,p1),1,COLS)
    elseif cmd=="E" then cy=clamp(cy+math.max(1,p1),1,ROWS); cx=1
    elseif cmd=="F" then cy=clamp(cy-math.max(1,p1),1,ROWS); cx=1
    elseif cmd=="G" then cx=clamp(math.max(1,p1),1,COLS)
    elseif cmd=="H" or cmd=="f" then
        cy=clamp(math.max(1,p1),1,ROWS)
        cx=clamp(math.max(1,p2),1,COLS)
    elseif cmd=="J" then
        if p1==0 then
            erase_cells(cx,COLS,cy)
            for y=cy+1,ROWS do erase_cells(1,COLS,y) end
        elseif p1==1 then
            for y=1,cy-1 do erase_cells(1,COLS,y) end
            erase_cells(1,cx,cy)
        elseif p1==2 or p1==3 then
            for y=1,ROWS do erase_cells(1,COLS,y) end
            prev_min_row = 1  -- vollständige Löschung: Klemmung zurücksetzen
        end
    elseif cmd=="K" then
        if p1==0 then erase_cells(cx,COLS,cy)
        elseif p1==1 then erase_cells(1,cx,cy)
        elseif p1==2 then erase_cells(1,COLS,cy) end
        last_was_erase_line = (p1==2)  -- \x1b[2K → nächster cursor-up wird geklemmt
    elseif cmd=="L" then
        local n=math.max(1,p1)
        for _=1,n do scroll_down(cy,scroll_bot) end
    elseif cmd=="M" then
        local n=math.max(1,p1)
        for _=1,n do scroll_up(cy,scroll_bot) end
    elseif cmd=="@" then
        local n=math.max(1,p1)
        for x=COLS,cx+n,-1 do cells[cy][x]=cells[cy][x-n] end
        for x=cx,math.min(cx+n-1,COLS) do cells[cy][x]=mk_cell(" ") end
    elseif cmd=="P" then
        local n=math.max(1,p1)
        for x=cx,COLS-n do cells[cy][x]=cells[cy][x+n] end
        for x=COLS-n+1,COLS do cells[cy][x]=mk_cell(" ") end
    elseif cmd=="S" then for _=1,math.max(1,p1) do scroll_up(scroll_top,scroll_bot) end
    elseif cmd=="T" then for _=1,math.max(1,p1) do scroll_down(scroll_top,scroll_bot) end
    elseif cmd=="d" then cy=clamp(math.max(1,p1),1,ROWS)
    elseif cmd=="m" then parse_sgr(params)
    elseif cmd=="r" then
        scroll_top=clamp(p1==0 and 1 or p1,1,ROWS)
        scroll_bot=clamp(p2==0 and ROWS or p2,1,ROWS)
        cx,cy=1,1  -- VT100: scroll-region-Änderung setzt Cursor auf Home
    elseif cmd=="s" then scx,scy=cx,cy
    elseif cmd=="u" then cx,cy=scx,scy
    elseif cmd=="h" then
        if priv=="25" then show_cursor=true
        elseif priv=="2004" then bracketed_paste=true
        elseif priv=="1000" then mouse_mode=1000
        elseif priv=="1002" then mouse_mode=1002
        elseif priv=="1003" then mouse_mode=1003
        elseif priv=="1006" then mouse_sgr=true
        elseif priv=="2026" then
            in_bsu=true
            -- Beim BSU-Start: Trennstrich-Zeilen aus dem Initial-Render wiederherstellen
            -- (verhindert dass Keypress-Header-Writes diese Zeilen dauerhaft überschreiben)
            if dialog_initial_done and dialog_scy>0 and saved_dialog_rows then
                cells[dialog_scy] = saved_dialog_rows[1]
                if saved_dialog_rows[2] and dialog_scy+1 <= ROWS then
                    cells[dialog_scy+1] = saved_dialog_rows[2]
                end
                dirty=true
            end
        elseif priv=="1049" then
            for y=1,ROWS do erase_cells(1,COLS,y) end
            cx,cy=1,1; scrollback={}; dirty=true
            dialog_scy=0; inline_sel_cy=0; dialog_initial_done=false
        end
    elseif cmd=="l" then
        if priv=="25" then show_cursor=false
        elseif priv=="2004" then bracketed_paste=false
        elseif priv=="1000" or priv=="1002" or priv=="1003" then mouse_mode=0
        elseif priv=="1006" then mouse_sgr=false
        elseif priv=="2026" then
            in_bsu=false
            -- Ersten BSU-Block nach \x1b7: Inline-Selection-Zeile ermitteln
            if dialog_scy > 0 and not dialog_initial_done then
                dialog_initial_done = true
                -- Trennstrich-Zeilen (dialog_scy..dialog_scy+1) für Wiederherstellung speichern
                local r1 = {}
                for x=1,COLS do r1[x] = cells[dialog_scy][x] end
                local r2 = {}
                for x=1,COLS do r2[x] = cells[dialog_scy+1] and cells[dialog_scy+1][x] or mk_cell(" ") end
                saved_dialog_rows = {r1, r2}
                -- Suche nach erster Zeile unterhalb dialog_scy mit ❯-Block in cols 1-4
                for y = dialog_scy+1, ROWS do
                    for x=1,4 do
                        local c = cells[y][x]
                        if c and c.block == 0x276F then
                            inline_sel_cy = y
                            break
                        end
                    end
                    if inline_sel_cy > 0 then break end
                end
            end
        elseif priv=="1049" then
            for y=1,ROWS do erase_cells(1,COLS,y) end
            cx,cy=1,1; dirty=true
            dialog_scy=0; inline_sel_cy=0; dialog_initial_done=false; saved_dialog_rows=nil
        end
    end
end

local function header_redirect(row)
    -- Header-Zeilen (dialog_scy..dialog_scy+1) → Inline-Selection-Position umleiten
    if dialog_initial_done and dialog_scy>0 and inline_sel_cy>0 then
        if row==dialog_scy then return inline_sel_cy
        elseif row==dialog_scy+1 then return inline_sel_cy+1 end
    end
    return row
end

local function write_ch(ch)
    if cx>COLS then
        cx=1; cy=cy+1
        if cy>scroll_bot then scroll_up(scroll_top,scroll_bot); cy=scroll_bot end
    end
    local efg = bold and math.min(fg+8,15) or fg
    if dim then efg = efg>=8 and efg-8 or (efg>0 and 5 or 0) end
    local wy = header_redirect(cy)
    cells[wy][cx]={ch=ch, fg=efg, bg=bg}
    if wy<cur_min_row then cur_min_row=wy end
    cx=cx+1
end

local function write_block(cp)
    if cx>COLS then
        cx=1; cy=cy+1
        if cy>scroll_bot then scroll_up(scroll_top,scroll_bot); cy=scroll_bot end
    end
    local efg = bold and math.min(fg+8,15) or fg
    if dim then efg = efg>=8 and efg-8 or (efg>0 and 5 or 0) end
    local wy = header_redirect(cy)
    cells[wy][cx]={ch=" ", fg=efg, bg=bg, block=cp}
    if wy<cur_min_row then cur_min_row=wy end
    cx=cx+1
end

local UNICODE_SUB={
    [0x00B7]=".",[0x2022]="*",[0x22C5]=".",
    [0x25CF]="*",[0x2299]="@",  -- ● ⊙ (Fallback, nicht mehr für ○◉)
    [0x2217]="*",[0x2731]="*",
    [0x203A]=">",[0x2039]="<",[0x00BB]=">",[0x00AB]="<",
    [0x2190]="<",[0x2192]=">",[0x2191]="^",[0x2193]="v",
    [0x25B6]=">",[0x25C0]="<",
    [0x2500]="-",[0x2501]="-",[0x2502]="|",[0x2503]="|",
    [0x250C]="+",[0x2510]="+",[0x2514]="+",[0x2518]="+",
    [0x251C]="+",[0x2524]="+",[0x252C]="+",[0x2534]="+",[0x253C]="+",
    [0x2550]="=",[0x2551]="|",
    [0x2554]="+",[0x2557]="+",[0x255A]="+",[0x255D]="+",
    [0x2560]="+",[0x2563]="+",[0x2566]="+",[0x2569]="+",[0x256C]="+",
    [0x2026]="~",[0x2014]="-",[0x2013]="-",
    [0x2018]="'",[0x2019]="'",[0x201C]='"',[0x201D]='"',
    [0x00A0]=" ",
    -- Häufige TUI-Zeichen (Claude Code, Ink usw.)
    -- 0x276F ❯ und 0x276E ❮ werden als echte Glyphen in draw_block gezeichnet
    [0x2714]="v",[0x2718]="x",   -- ✔ ✘ Häkchen / Kreuz
    [0x2139]="i",                 -- ℹ Info
    [0x25A0]="*",[0x25A1]="o",   -- ■ □ Gefülltes/leeres Quadrat
    [0x25B2]="^",[0x25BC]="v",   -- ▲ ▼ Pfeile
    [0x2713]="v",                 -- ✓ Häkchen
    [0x2212]="-",                 -- − Minus-Zeichen (Textual Buttons)
    [0x00D7]="x",                 -- × Multiplikation
    -- Lateinische Umlaute und Sonderzeichen
    [0x00E4]="a",[0x00F6]="o",[0x00FC]="u",   -- ä ö ü
    [0x00C4]="A",[0x00D6]="O",[0x00DC]="U",   -- Ä Ö Ü
    [0x00DF]="s",                               -- ß
    [0x00E9]="e",[0x00E8]="e",[0x00EA]="e",   -- é è ê
    [0x00E0]="a",[0x00E2]="a",[0x00E1]="a",   -- à â á
    [0x00F9]="u",[0x00FB]="u",[0x00FA]="u",   -- ù û ú
    [0x00EE]="i",[0x00EF]="i",[0x00ED]="i",   -- î ï í
    [0x00F1]="n",                               -- ñ
    [0x00E7]="c",                               -- ç
}
local BLOCK_SET={
    [0x2580]=1,[0x2581]=1,[0x2582]=1,[0x2583]=1,[0x2584]=1,[0x2585]=1,[0x2586]=1,[0x2587]=1,
    [0x2588]=1,[0x258C]=1,[0x2590]=1,[0x2591]=1,[0x2592]=1,[0x2593]=1,
    [0x2594]=1,[0x2595]=1,[0x2596]=1,[0x2597]=1,[0x2598]=1,[0x2599]=1,
    [0x259A]=1,[0x259B]=1,[0x259C]=1,[0x259D]=1,[0x259E]=1,[0x259F]=1,
    [0x276F]=1,[0x276E]=1,  -- ❯ ❮ Selektor-Zeichen
    [0x25CB]=1,[0x25CF]=1,  -- ○ ● Kreis (leer/gefüllt)
    [0x25C9]=1,[0x25CE]=1,  -- ◉ ◎ Bullseye-Varianten
    [0x2B58]=1,             -- ⭘ Heavy Circle (Textual Header-Button)
    [0x258F]=1,             -- ▏ Left One Eighth Block (Scrollbar)
    [0x256D]=1,[0x256E]=1,[0x256F]=1,[0x2570]=1,  -- ╭ ╮ ╯ ╰ Rounded corners
}
local function write_unicode(cp)
    if BLOCK_SET[cp] then write_block(cp); return end
    local s=UNICODE_SUB[cp]
    if s then for i=1,#s do write_ch(s:sub(i,i)) end
    else write_ch(" ") end
end

local function feed(ch)
    local b=string.byte(ch)
    if utf8_need>0 then
        if b>=0x80 and b<0xC0 then
            utf8_buf=utf8_buf..ch; utf8_need=utf8_need-1
            if utf8_need==0 then
                local s=utf8_buf; local b1=string.byte(s,1); local cp
                if #s==2 then cp=((b1&0x1F)<<6)|(string.byte(s,2)&0x3F)
                elseif #s==3 then cp=((b1&0x0F)<<12)|((string.byte(s,2)&0x3F)<<6)|(string.byte(s,3)&0x3F)
                elseif #s==4 then cp=((b1&0x07)<<18)|((string.byte(s,2)&0x3F)<<12)|((string.byte(s,3)&0x3F)<<6)|(string.byte(s,4)&0x3F)
                end
                if cp then write_unicode(cp) end
            end
            return
        else utf8_need=0 end
    end
    if b>=0xF0 then utf8_buf=ch;utf8_need=3;return
    elseif b>=0xE0 then utf8_buf=ch;utf8_need=2;return
    elseif b>=0xC0 then utf8_buf=ch;utf8_need=1;return
    elseif b>=0x80 then return end
    if esc_state==0 then
        if b==27 then esc_state=1
        elseif b==13 then cx=1
        elseif b==10 then
            cy=cy+1
            if cy>scroll_bot then scroll_up(scroll_top,scroll_bot); cy=scroll_bot end
        elseif b==8 then cx=math.max(1,cx-1)
        elseif b==9 then cx=math.min(COLS,cx+(8-(cx-1)%8))
        elseif b==12 then
            for y=1,ROWS do erase_cells(1,COLS,y) end
            cx,cy=1,1; dirty=true
        elseif b==7 then
        elseif b==1 or b==2 then
        elseif b>=32 then write_ch(ch)
        end
    elseif esc_state==1 then
        if ch=="[" then esc_state=2; esc_buf=""
        elseif ch=="]" then esc_state=3; esc_buf=""
        elseif ch=="7" then
            scx,scy=cx,cy
            if cy > 1 then
                for y=1,cy-1 do erase_cells(1,COLS,y) end
                dialog_scy = cy
                inline_sel_cy = 0
                dialog_initial_done = false
            end
            esc_state=0
        elseif ch=="8" then
            cx = scx
            -- \x1b8: wenn Inline-Selection bekannt → Cursor dahin statt zu dialog_scy
            if inline_sel_cy > 0 then
                cy = inline_sel_cy + (scy - dialog_scy)
            else
                cy = scy
            end
            esc_state=0
        elseif ch=="M" then
            if cy<=scroll_top then scroll_down(scroll_top,scroll_bot)
            else cy=cy-1 end
            esc_state=0
        elseif ch=="(" or ch==")" then esc_state=4
        else esc_state=0 end
    elseif esc_state==2 then
        if b>=0x40 and b<=0x7e then
            parse_csi(ch, esc_buf); esc_state=0
        else esc_buf=esc_buf..ch end
    elseif esc_state==3 then
        if b==7 then esc_state=0
        elseif b==27 then esc_state=5 end
    elseif esc_state==4 then
        esc_state=0
    elseif esc_state==5 then
        esc_state=0
    end
end

local function process(data)
    for i=1,#data do feed(data:sub(i,i)) end
end

local COL_CHAR = "0123456789abcdef"
local function col_esc(c)
    return "\12"..COL_CHAR:sub((c or 0)%16+1,(c or 0)%16+1)
end

local function sel_range()
    if not sel_active or not sel_anchor or not sel_cur then return nil end
    local r1,c1 = sel_anchor.row, sel_anchor.col
    local r2,c2 = sel_cur.row,    sel_cur.col
    if r1>r2 or (r1==r2 and c1>c2) then r1,c1,r2,c2=r2,c2,r1,c1 end
    return r1,c1,r2,c2
end

local function in_sel(abs_row, x)
    local r1,c1,r2,c2 = sel_range()
    if not r1 then return false end
    if abs_row<r1 or abs_row>r2 then return false end
    if abs_row==r1 and x<c1 then return false end
    if abs_row==r2 and x>c2 then return false end
    return true
end

local function get_selection()
    local r1,c1,r2,c2 = sel_range()
    if not r1 then return "" end
    local sb = #scrollback
    local lines = {}
    for row=r1,r2 do
        local data = row<=sb and scrollback[row] or cells[row-sb]
        if data then
            local xs = row==r1 and c1 or 1
            local xe = row==r2 and c2 or COLS
            local chars = {}
            for x=xs,xe do chars[#chars+1] = data[x] and data[x].ch or " " end
            local line = table.concat(chars)
            if row<r2 then line=line:gsub("%s+$","") end
            lines[#lines+1] = line
        end
    end
    return table.concat(lines, "\n")
end

local function draw_block(c, px, py)
    local cp,fg,bg=c.block,c.fg,c.bg
    local hw,hh=CHAR_W//2,CHAR_H//2
    if cp>=0x2585 and cp<=0x2588 then rectfill(px,py,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x2580 then rectfill(px,py,px+CHAR_W-1,py+hh-1,fg)
    elseif cp==0x2584 then rectfill(px,py+hh,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x2583 then rectfill(px,py+CHAR_H-3,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x2582 then rectfill(px,py+CHAR_H-2,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x2581 then rectfill(px,py+CHAR_H-1,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x258C then rectfill(px,py,px+hw-1,py+CHAR_H-1,fg)
    elseif cp==0x2590 then rectfill(px+hw,py,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x2596 then rectfill(px,py+hh,px+hw-1,py+CHAR_H-1,fg)
    elseif cp==0x2597 then rectfill(px+hw,py+hh,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x2598 then rectfill(px,py,px+hw-1,py+hh-1,fg)
    elseif cp==0x259D then rectfill(px+hw,py,px+CHAR_W-1,py+hh-1,fg)
    elseif cp==0x2599 then rectfill(px,py,px+hw-1,py+hh-1,fg);rectfill(px,py+hh,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x259B then rectfill(px,py,px+CHAR_W-1,py+hh-1,fg);rectfill(px,py+hh,px+hw-1,py+CHAR_H-1,fg)
    elseif cp==0x259C then rectfill(px,py,px+CHAR_W-1,py+hh-1,fg);rectfill(px+hw,py+hh,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x259F then rectfill(px+hw,py,px+CHAR_W-1,py+hh-1,fg);rectfill(px,py+hh,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x259A then rectfill(px,py,px+hw-1,py+hh-1,fg);rectfill(px+hw,py+hh,px+CHAR_W-1,py+CHAR_H-1,fg)
    elseif cp==0x259E then rectfill(px+hw,py,px+CHAR_W-1,py+hh-1,fg);rectfill(px,py+hh,px+hw-1,py+CHAR_H-1,fg)
    elseif cp==0x2591 then for dy=0,CHAR_H-1,4 do pset(px+1,py+dy,fg);pset(px+3,py+dy+2,fg) end
    elseif cp==0x2592 then for dy=0,CHAR_H-1 do for dx=(dy%2),CHAR_W-1,2 do pset(px+dx,py+dy,fg) end end
    elseif cp==0x2593 then rectfill(px,py,px+CHAR_W-1,py+CHAR_H-1,fg);for dy=0,CHAR_H-1 do for dx=(dy%2),CHAR_W-1,2 do pset(px+dx,py+dy,bg) end end
    elseif cp==0x276F then  -- ❯  5px hoch, 1px Abstand oben
        pset(px,   py+1, fg)
        pset(px+1, py+2, fg)
        pset(px+2, py+3, fg)
        pset(px+1, py+4, fg)
        pset(px,   py+5, fg)
    elseif cp==0x276E then  -- ❮  Spiegel von ❯
        pset(px+2, py+1, fg)
        pset(px+1, py+2, fg)
        pset(px,   py+3, fg)
        pset(px+1, py+4, fg)
        pset(px+2, py+5, fg)
    elseif cp==0x25CB then  -- ○ Leerer Kreis
        local cx=px+2; local cy=py+5
        circ(cx,cy,3,fg)
    elseif cp==0x25CF then  -- ● Gefüllter Kreis
        local cx=px+2; local cy=py+5
        circfill(cx,cy,3,fg)
    elseif cp==0x25C9 or cp==0x25CE then  -- ◉ ◎ Bullseye
        local cx=px+2; local cy=py+5
        circfill(cx,cy,1,fg); circ(cx,cy,3,fg)
    elseif cp==0x2B58 then  -- ⭘ Heavy Circle (Textual Header-Button)
        local cx=px+2; local cy=py+5
        circ(cx,cy,3,fg); circ(cx,cy,2,fg)  -- doppelter Ring = "heavy"
    elseif cp==0x258F then  -- ▏ Left One Eighth Block
        rectfill(px,py,px,py+CHAR_H-1,fg)
    elseif cp==0x256D then  -- ╭ top-left: Mittellinie nach rechts + nach unten
        for dx=hw,CHAR_W-1 do pset(px+dx,py+hh,fg) end
        for dy=hh,CHAR_H-1 do pset(px+hw,py+dy,fg) end
    elseif cp==0x256E then  -- ╮ top-right: Mittellinie nach links + nach unten
        for dx=0,hw do pset(px+dx,py+hh,fg) end
        for dy=hh,CHAR_H-1 do pset(px+hw,py+dy,fg) end
    elseif cp==0x256F then  -- ╯ bottom-right: Mittellinie nach links + nach oben
        for dx=0,hw do pset(px+dx,py+hh,fg) end
        for dy=0,hh do pset(px+hw,py+dy,fg) end
    elseif cp==0x2570 then  -- ╰ bottom-left: Mittellinie nach rechts + nach oben
        for dx=hw,CHAR_W-1 do pset(px+dx,py+hh,fg) end
        for dy=0,hh do pset(px+hw,py+dy,fg) end
    end
end

local function draw_row(row, py, abs_row)
    for x=1,COLS do
        local c=row[x]
        local px=(x-1)*CHAR_W
        if in_sel(abs_row, x) then
            rectfill(px,py,px+CHAR_W-1,py+CHAR_H-1, 7)
        elseif c.bg~=0 then
            rectfill(px,py,px+CHAR_W-1,py+CHAR_H-1,c.bg)
        end
    end
    for x=1,COLS do
        if row[x].block and not in_sel(abs_row,x) then draw_block(row[x],(x-1)*CHAR_W,py) end
    end
    local parts={}
    local cur_fg=-1
    local has_text=false
    for x=1,COLS do
        local c=row[x]
        local efg = in_sel(abs_row, x) and 0 or c.fg
        if c.ch~=" " then
            if efg~=cur_fg then
                parts[#parts+1]=col_esc(efg)
                cur_fg=efg
            end
            parts[#parts+1]=c.ch
            has_text=true
        else
            parts[#parts+1]=" "
        end
    end
    if has_text then print(table.concat(parts), 0, py) end
end

local function mouse_encode(btn, col, row, press)
    if mouse_sgr then
        return string.format("\x1b[<%d;%d;%d%s", btn, col, row, press and "M" or "m")
    elseif col<224 and row<224 then
        return "\x1b[M"..string.char(btn+32)..string.char(col+32)..string.char(row+32)
    end
    return ""
end

local function send_to_host(data)
    if worker_pid then
        send_message(worker_pid, {event="term_write", data=data})
        dirty = true
        -- kein auto_scroll: TUI-Apps (Claude Code etc.) steuern den Viewport selbst
    end
end

local KEY_MAP = {
    up="\x1b[A", down="\x1b[B", right="\x1b[C", left="\x1b[D",
    home="\x1b[H", ["end"]="\x1b[F",
    pageup="\x1b[5~", pagedown="\x1b[6~",
    delete="\x1b[3~", insert="\x1b[2~",
    f2="\x1bOQ", f3="\x1bOR", f4="\x1bOS",
    f5="\x1b[15~", f6="\x1b[17~", f7="\x1b[18~", f8="\x1b[19~",
}

local function update_scroll()
    local total_h = (#scrollback + ROWS) * CHAR_H
    if total_h < WIN_H then total_h = WIN_H end
    contents.height = total_h
    return total_h
end

-- Cursor-Follow: Viewport so positionieren dass der Cursor am unteren Rand sichtbar ist.
-- Entspricht dem Verhalten echter Terminals (xterm, kitty, Alacritty): der Screen
-- ist der sichtbare Bereich, neuer Output erscheint am unteren Rand.
local function follow_cursor()
    local sb = #scrollback
    local total_h = math.max((sb + ROWS) * CHAR_H, WIN_H)
    contents.height = total_h
    -- Cursor-Unterrand in Content-Koordinaten
    local cursor_bottom = (sb + cy) * CHAR_H
    -- Viewport so setzen dass Cursor am unteren Rand liegt
    local new_y = WIN_H - cursor_bottom
    -- Clamp: nicht über den Content-Anfang hinaus scrollen
    new_y = math.min(0, new_y)
    -- Clamp: nicht über das Content-Ende hinaus scrollen
    new_y = math.max(-(total_h - WIN_H), new_y)
    contents.y = new_y
end

local function do_resize(new_w, new_h)
    local new_cols = math.max(10, new_w // CHAR_W)
    local new_rows = math.max(2, new_h // CHAR_H)
    if new_cols == COLS and new_rows == ROWS then return end
    -- Zeilen expandieren/anpassen
    local max_y = math.max(ROWS, new_rows)
    for y = 1, max_y do
        if not cells[y] then
            cells[y] = {}
            for x = 1, new_cols do cells[y][x] = {ch=" ", fg=7, bg=0} end
        else
            for x = COLS+1, new_cols do cells[y][x] = {ch=" ", fg=7, bg=0} end
        end
    end
    COLS = new_cols
    ROWS = new_rows
    WIN_W = new_w
    WIN_H = new_h
    scroll_top = 1
    scroll_bot = ROWS
    cx = math.min(cx, COLS)
    cy = math.min(cy, ROWS)
    -- GUI anpassen
    container.width = WIN_W
    container.height = WIN_H
    contents.width = WIN_W
    -- Neue Größe an Bridge melden (Bridge interceptet \x1b[8;r;ct und ruft TIOCSWINSZ)
    if worker_pid then
        send_message(worker_pid, {event="term_resize", cols=COLS, rows=ROWS})
    end
    dirty = true
    auto_scroll = true
end

function _init()
    window{width=WIN_W, height=WIN_H, title="Host Terminal", pauseable=false}
    init_cells()
    store("/ram/term_active_pid.pod", tostring(pid()))

    on_event("resize", function(msg)
        if msg.width and msg.height then do_resize(msg.width, msg.height) end
    end)
    on_event("term_data", function(msg)
        cur_min_row = ROWS + 1
        last_was_erase_line = false
        process(msg.data)
        if cur_min_row <= ROWS then prev_min_row = cur_min_row end
        dirty = true
    end)
    on_event("term_exit", function()
        exit()
    end)

    worker_pid = create_process("/desktop/host_terminal.p64/worker.lua", {
        host = HOST,
        port = PORT,
    })

    gui = create_gui()
    container = gui:attach{x=0, y=0, width=WIN_W, height=WIN_H}
    contents  = container:attach{x=0, y=0, width=WIN_W, height=WIN_H}

    function contents:draw(msg)
        local sb = #scrollback
        for i,row in ipairs(scrollback) do
            draw_row(row, (i-1)*CHAR_H, i)
        end
        for y=1,ROWS do
            draw_row(cells[y], (sb+y-1)*CHAR_H, sb+y)
        end
        if show_cursor and (time()*2%2)<1 then
            local px=(cx-1)*CHAR_W
            local py=(sb+cy-1)*CHAR_H
            local cc=cells[cy] and cells[cy][cx]
            rectfill(px,py,px+CHAR_W-1,py+8,7)
            if cc and cc.ch~=" " then print(cc.ch,px,py,0) end
        end
    end

    container:attach_scrollbars{autohide=true, fgcol=7, bgcol=5}
end

function _update()
    gui:update_all()

    ipc_timer = ipc_timer + 1
    if ipc_timer >= 30 then
        ipc_timer = 0
        local ipc_path = "/ram/term_inject_"..pid()..".pod"
        local inj = fetch(ipc_path)
        if inj and type(inj)=="string" then
            send_to_host(inj)
            rm(ipc_path)
            dirty=true; auto_scroll=true
        end
    end

    -- Maushandling
    local mx,my,mb = mouse()
    local shift = key("shift")
    local abs_row   = math.max(1, math.floor((my-contents.y)/CHAR_H)+1)
    local cell_col  = math.max(1, math.min(math.floor(mx/CHAR_W)+1, COLS))
    local scr_row   = abs_row - #scrollback  -- screen-relativ für App-Protokoll

    if mouse_mode>0 and not shift then
        -- App-Modus: Mouse-Events an Shell weiterleiten
        if scr_row>=1 and scr_row<=ROWS then
            -- Button-Zustandswechsel
            local function fwd_btn(bit, btn)
                local held = mb&bit==bit
                local was  = was_mb&bit==bit
                if held and not was then
                    send_to_host(mouse_encode(btn, cell_col, scr_row, true))
                elseif not held and was then
                    send_to_host(mouse_encode(btn, cell_col, scr_row, false))
                end
            end
            fwd_btn(1, 0)  -- links
            fwd_btn(2, 2)  -- rechts
            -- Drag-Events (1002: nur mit Taste, 1003: immer)
            if (mouse_mode>=1002 and mb>0) or mouse_mode>=1003 then
                if cell_col~=last_mcol or scr_row~=last_mrow then
                    local btn = (mb&1==1) and 0 or (mb&2==2) and 2 or 3
                    send_to_host(mouse_encode(btn+32, cell_col, scr_row, true))
                end
            end
        end
        last_mcol, last_mrow = cell_col, scr_row
    else
        -- Terminal-Selektion (kein App-Modus, oder Shift-Override)
        if mb&1==1 then
            if was_mb&1==0 then
                -- Klick: Anker setzen, Selektion noch nicht aktivieren
                sel_anchor = {row=abs_row, col=cell_col}
                sel_cur    = {row=abs_row, col=cell_col}
                sel_active = false
                dirty = true
            elseif sel_anchor and (abs_row~=sel_anchor.row or cell_col~=sel_anchor.col) then
                -- Drag: erst jetzt aktivieren
                sel_active = true
                sel_cur = {row=abs_row, col=cell_col}
                dirty = true
            end
        elseif was_mb&1==1 then
            -- Loslassen ohne Drag: Selektion aufheben
            if not sel_active then
                sel_anchor = nil
                sel_cur    = nil
                dirty = true
            end
        end
    end
    was_mb = mb

    while peektext() do
        local c = readtext()
        if c then
            local b = string.byte(c)
            if b and b >= 32 and b ~= 127 then
                sel_active = false; dirty = true
                send_to_host(c)
            end
        end
    end
    for k,seq in pairs(KEY_MAP) do
        if keyp(k) then sel_active=false; send_to_host(seq) end
    end
    if keyp("backspace") then sel_active=false; send_to_host("\x7f") end
    if keyp("enter")     then sel_active=false; send_to_host("\r") end
    if keyp("tab")       then sel_active=false; send_to_host("\t") end
    if keyp("escape")    then sel_active=false; send_to_host("\x1b") end
    if keyp("f1")        then sel_active=false; send_to_host("\x1b") end
    if key("ctrl") then
        if key("shift") then
            if keyp("c") then
                local text = get_selection()
                if #text>0 then set_clipboard(text) end
            elseif keyp("v") then
                local text = get_clipboard()
                if text and #text>0 then
                    if bracketed_paste then
                        send_to_host("\x1b[200~"..text.."\x1b[201~")
                    else
                        send_to_host(text)
                    end
                end
            end
        else
            for _,k in ipairs({"a","b","c","d","e","k","l","r","u","w","z"}) do
                if keyp(k) then sel_active=false; send_to_host(string.char(string.byte(k)-96)) end
            end
            if keyp("[") then sel_active=false; send_to_host("\x1b") end
        end
    end

    if auto_scroll then
        local sb = #scrollback
        local total_h = math.max((sb + ROWS) * CHAR_H, WIN_H)
        contents.height = total_h
        contents.y = -(total_h - WIN_H)
        last_visual_offset = 0
        auto_scroll = false
        dirty = true
    end

    if contents.y ~= last_contents_y then
        last_contents_y = contents.y
        dirty = true
    end

    if show_cursor then
        local blink = (time()*2%2)<1 and 1 or 0
        if blink ~= last_cursor_blink then
            last_cursor_blink = blink
            dirty = true
        end
    end
end

function _draw()
    if not dirty then return end
    dirty = false
    cls(0)
    gui:draw_all()
end
