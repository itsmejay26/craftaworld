--[[
    ROTATION FARM v3.0
    Harvest -> Break -> Plant -> Grow -> Next Batch -> Repeat

    Harvest Row 1  : center-right (farmStartX->X99) fire rowY
                   + below-left   (X99->X0)          fire rowY-2
                     fall at X=0 to row 2
    Harvest Middle : below-right  (X1->X100)         fire rowY-2
                     fall at X=100 to next row
    Harvest Last   : collect-left (X99->X1)          no firing
                     fall-right   (X1->X100)         drop to break floor
    Break          : place breakBlocks tile-by-tile, fist back; repeat until inventory empty
    Plant          : bottom-up per batch; miss = go fix it, return to saved X, resume
    Batches        : advance DOWNWARD each cycle; wrap to farmStartY when exhausted
]]

-- ============ SINGLETON ============
if _G.RotFarmV3 then
    _G.RotFarmV3.dead = true
    for _, c in pairs(_G.RotFarmV3.connections or {}) do pcall(function() c:Disconnect() end) end
end
local inst = {dead=false, connections={}}
_G.RotFarmV3 = inst

-- ============ SERVICES ============
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local RunSvc      = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local VIM         = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local player      = Players.LocalPlayer
local gui      = player:WaitForChild("PlayerGui")
local Remotes  = RS:WaitForChild("Remotes")
local placeR   = Remotes:WaitForChild("PlayerPlaceItem")
local fstR     = Remotes:WaitForChild("PlayerFist")
local invUI    = gui:WaitForChild("InventoryUI", 30)
if not invUI then return end
local invScroll = invUI
    :WaitForChild("Handle",10):WaitForChild("Frame",10)
    :WaitForChild("Bottom",10):WaitForChild("InventoryFrame",10)
    :WaitForChild("InventoryScroll",10)
if not invScroll then return end

-- ============ CONSTANTS ============
local TILE_SIZE      = 4.5
local BREAK_FLOOR_Y  = 7
local TRAVERSE_LEFT  = 0
local TRAVERSE_RIGHT = 100
local JUMP_RIGHT     = 99
local JUMP_LEFT      = 1
local JUMP_HOLD      = 0.65
local MOVE_REFRESH   = 10
local PLANT_DELAY    = 0.75

-- ============ CONFIG ============
local CFG = {
    farmStartX=nil, farmStartY=nil, breakX=70,
    plantItem=nil,  breakItem=nil,
    rowsPerCycle=3, breakBlocks=26, growTime=5700, skipGrow=false,
    batchStart=1,  -- which batch number to start from (1 = farmStartY)
}

-- ============ RUNTIME STATE ============
local isRunning=false; local currentBatchY=nil; local cycleCount=0; local statusLabel=nil
local function SetStatus(t,c) if statusLabel then statusLabel.Text=t; statusLabel.TextColor3=c or Color3.fromRGB(200,255,210) end end

-- ============ SAFE MODE STATE ============
local safeAutoStop  = false
local safeAutoLeave = false
local isMinimized   = false
local SAVE_FILE     = "RotFarm_Whitelist.json"
local whitelist     = {"54321_jaymes"}  -- default entry

local function SaveWhitelist()
    pcall(function()
        if writefile then writefile(SAVE_FILE, HttpService:JSONEncode(whitelist)) end
    end)
end
local function LoadWhitelist()
    local ok, data = pcall(function()
        if isfile and isfile(SAVE_FILE) then
            return HttpService:JSONDecode(readfile(SAVE_FILE))
        end
    end)
    if ok and type(data)=="table" then whitelist=data end
end
local function IsWhitelisted(name)
    for _,n in ipairs(whitelist) do
        if n:lower()==name:lower() then return true end
    end
    return false
end
LoadWhitelist()
-- ensure default is always present
local function EnsureDefault()
    if not IsWhitelisted("54321_jaymes") then
        table.insert(whitelist,1,"54321_jaymes"); SaveWhitelist()
    end
end
EnsureDefault()

-- ============ POSITION ============
local hrpRef=nil
local function RefHRP() local c=player.Character; hrpRef=c and c:FindFirstChild("HumanoidRootPart") end
RefHRP()
table.insert(inst.connections, player.CharacterAdded:Connect(function(c) task.wait(); hrpRef=c:FindFirstChild("HumanoidRootPart") end))
local function GetTileIndex()
    local pos=hrpRef and hrpRef.Parent and hrpRef.Position; if not pos then return nil,nil end
    return math.floor(pos.X/TILE_SIZE+0.5), math.floor(pos.Y/TILE_SIZE+0.5)
end

-- ============ MOVEMENT ============
local function pressKey(k)   VIM:SendKeyEvent(true,  k, false, game) end
local function releaseKey(k) VIM:SendKeyEvent(false, k, false, game) end
local function startMoveRight() releaseKey(Enum.KeyCode.D); task.wait(0.01); pressKey(Enum.KeyCode.D) end
local function startMoveLeft()  releaseKey(Enum.KeyCode.A); task.wait(0.01); pressKey(Enum.KeyCode.A) end
local function stopAll()
    pcall(function() releaseKey(Enum.KeyCode.A) end)
    pcall(function() releaseKey(Enum.KeyCode.D) end)
    pcall(function() releaseKey(Enum.KeyCode.Space) end)
end
local function walkToX(targetX, guardFn)
    local ix=GetTileIndex(); if not ix or not guardFn() then return false end
    local goRight=ix<targetX; local key=goRight and Enum.KeyCode.D or Enum.KeyCode.A
    local lr=tick(); pressKey(key)
    while guardFn() and not inst.dead do
        ix=GetTileIndex(); if not ix then task.wait(0.01); continue end
        if goRight  and ix>=targetX then break end
        if not goRight and ix<=targetX then break end
        if tick()-lr>=MOVE_REFRESH then releaseKey(key); task.wait(0.01); pressKey(key); lr=tick() end
        task.wait(0.01)
    end
    releaseKey(key); return guardFn()
end

-- ============ ROW HELPERS ============
local function isActiveRow(y,refY) return y>BREAK_FLOOR_Y and (refY-y)%2==0 end
local function getRows(topY,count,refY)
    local rows={}; local y=topY
    while #rows<count and y>BREAK_FLOOR_Y do
        if isActiveRow(y,refY) then table.insert(rows,y) end; y=y-1
    end; return rows
end

-- ============ CLIMB TO Y ============
local function climbToY(targetY, guardFn)
    local ix,iy=GetTileIndex(); if not ix or not iy then return nil,nil end
    if iy>=targetY then return ix, ix>=50 end
    local useRight=(TRAVERSE_RIGHT-ix)<=(ix-TRAVERSE_LEFT)
    SetStatus("CLIMB Y="..targetY, Color3.fromRGB(255,200,100)); stopAll(); task.wait(0.05)
    if useRight then walkToX(TRAVERSE_RIGHT,guardFn); if not guardFn() then return nil,nil end; walkToX(JUMP_RIGHT,guardFn)
    else walkToX(TRAVERSE_LEFT,guardFn); if not guardFn() then return nil,nil end; walkToX(JUMP_LEFT,guardFn) end
    stopAll(); task.wait(0.15); if not guardFn() then return nil,nil end
    local ja,maxJ,lastY,stuck=0,60,iy,0
    while guardFn() and not inst.dead and ja<maxJ do
        ix,iy=GetTileIndex(); if not iy then task.wait(0.08); ja+=1; continue end
        if iy>=targetY then task.wait(0.15); return useRight and JUMP_RIGHT or JUMP_LEFT, useRight end
        if iy==lastY then stuck+=1; if stuck>5 then return ix,useRight end
        else stuck=0; lastY=iy end
        pressKey(Enum.KeyCode.Space); task.wait(JUMP_HOLD); releaseKey(Enum.KeyCode.Space); task.wait(0.2); ja+=1
    end
    ix,iy=GetTileIndex(); return ix,useRight
end

-- ============ HANDLE BOUNDARY ============
local function handleBoundary(isRight, guardFn, refY)
    local _,ySaved=GetTileIndex()
    if isRight then releaseKey(Enum.KeyCode.D); task.wait(0.01); pressKey(Enum.KeyCode.A)
    else releaseKey(Enum.KeyCode.A); task.wait(0.01); pressKey(Enum.KeyCode.D) end
    local ft=tick()
    while guardFn() and not inst.dead do
        local _,yN=GetTileIndex()
        if yN and ySaved and yN~=ySaved then
            local t=yN; if refY and (refY-t)%2~=0 then t=t-1 end; stopAll()
            if t<=BREAK_FLOOR_Y then return "last",ySaved end; return "fell",t
        end
        if tick()-ft>=0.45 then stopAll(); return "last",ySaved end
        task.wait(0.01)
    end
    stopAll(); return "stopped",ySaved
end

-- ============ SLOT HELPERS ============
local scMap,scNext={},10
local function GetCode(k) if not k or k=="" then return nil end; if scMap[k] then return scMap[k] end; scMap[k]=tostring(scNext); scNext+=1; return scMap[k] end
local function SafeImg(o) if not o then return nil end; local ok,img=pcall(function() return o.Image end); return (ok and type(img)=="string" and img~="") and img or nil end
local function SafeCol(o) if not o then return nil end; local ok,c=pcall(function() return o.ImageColor3 end); return (ok and typeof(c)=="Color3") and c or nil end
local function CK(c) return math.round(c.R*255)..","..math.round(c.G*255)..","..math.round(c.B*255) end
local function GetSlotKey(slot)
    local d=slot:FindFirstChild("ItemDisplay"); if not d then return nil end
    local l2=d:FindFirstChild("layer2"); if l2 then local img=SafeImg(l2); if img then local n=img:match("%d+"); local lc,dc=SafeCol(l2),SafeCol(d); return n.."|"..(lc and CK(lc) or "0,0,0").."|"..(dc and CK(dc) or "0,0,0") end end
    local img=SafeImg(d); return img and img:match("%d+") or nil
end
local function ParseAmt(t) return tonumber(tostring(t):match("%d+")) or 0 end
local function FindSlotByCode(code)
    if not code then return nil end
    for _,slot in pairs(invScroll:GetChildren()) do
        local n=tonumber(slot.Name); if not n then continue end
        local k=GetSlotKey(slot); local c=k and GetCode(k)
        local d=slot:FindFirstChild("ItemDisplay"); local a=d and ParseAmt((d:FindFirstChild("AmountText") or {}).Text or "") or 0
        if c==code and a>0 then return n end
    end
end
local function GetTotalByCode(code)
    if not code then return 0 end; local tot=0
    for _,slot in pairs(invScroll:GetChildren()) do
        if tonumber(slot.Name) then
            local k=GetSlotKey(slot); local c=k and GetCode(k)
            if c==code then local d=slot:FindFirstChild("ItemDisplay"); if d then tot+=ParseAmt((d:FindFirstChild("AmountText") or {}).Text or "") end end
        end
    end; return tot
end

-- ============ WORLD TILE TRACKING ============
local worldTileSet={}
local function wTE(pX,pY) return worldTileSet[pX..","..pY]==true end
local function sWT(pX,pY,e) local k=pX..","..pY; if e then worldTileSet[k]=true else worldTileSet[k]=nil end end
local groupLayout={
    {{8,5},{8,5},{8,5},{8,5},{8,5},{8,5},{8,5},{8,5},{8,5},{8,5},{8,5},{8,5},{5,5}},
    {{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{5,8}},
    {{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{5,8}},
    {{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{5,8}},
    {{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{5,8}},
    {{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{5,8}},
    {{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{5,8}},
    {{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{8,8},{5,8}},
}
local gpPos={}; local x0,y0,gStep=15.75,267.75,36
for r=1,8 do gpPos[r]={}; local yp=y0-gStep*(r-1); for c=1,13 do gpPos[r][c]=Vector3.new(x0+gStep*(c-1),yp,-13.5) end end
local function fndG(p) local md=math.huge; local br,bc=1,1; for r=1,8 do for c=1,13 do local d=(Vector3.new(p.X,p.Y,0)-Vector3.new(gpPos[r][c].X,gpPos[r][c].Y,0)).Magnitude; if d<md then md=d; br,bc=r,c end end end; return br,bc end
local function pTI(u,gR,gC) local gW=groupLayout[gR][gC][1]; local gH=groupLayout[gR][gC][2]; return math.clamp(math.floor(u.X.Offset/45+0.5),0,gW-1), math.clamp(math.floor((u.Y.Offset+(gH-1)*45)/45+0.5),0,gH-1) end
local function wTP(gR,gC,lC,lR) local gp=gpPos[gR][gC]; local gW=groupLayout[gR][gC][1]; local gH=groupLayout[gR][gC][2]; local pX=math.floor((gp.X+(lC-(gW-1)/2)*TILE_SIZE)/TILE_SIZE+0.5); local pY=math.floor((gp.Y+((gH-1)/2-lR)*TILE_SIZE)/TILE_SIZE+0.5); if gW==5 then pX=pX-2 end; if gH==5 then pY=pY-2 end; return pX,pY end
local tCn,sCn,mCn={},{},{}
local function oIA(il,pt) if not il:IsA("ImageLabel") then return end; local gR,gC=fndG(pt.Position); local lC,lR=pTI(il.Position,gR,gC); local pX,pY=wTP(gR,gC,lC,lR); sWT(pX,pY,true) end
local function oIR(il,pt) if not il:IsA("ImageLabel") then return end; local gR,gC=fndG(pt.Position); local lC,lR=pTI(il.Position,gR,gC); local pX,pY=wTP(gR,gC,lC,lR); sWT(pX,pY,false) end
local function wSG(sg2,pt) if sCn[sg2] then return end; sCn[sg2]={}; table.insert(sCn[sg2],sg2.ChildAdded:Connect(function(c) task.defer(function() oIA(c,pt) end) end)); table.insert(sCn[sg2],sg2.ChildRemoved:Connect(function(c) task.defer(function() oIR(c,pt) end) end)) end
local function uSG(sg2) if sCn[sg2] then for _,c in ipairs(sCn[sg2]) do c:Disconnect() end; sCn[sg2]=nil end end
local function wTP2(pt)
    if not pt:IsA("BasePart") or tCn[pt] then return end; tCn[pt]={}
    local eg=pt:FindFirstChildOfClass("SurfaceGui"); if eg then wSG(eg,pt) end
    table.insert(tCn[pt],pt.ChildAdded:Connect(function(c) if c:IsA("SurfaceGui") then wSG(c,pt); task.defer(function() for _,il in ipairs(c:GetChildren()) do oIA(il,pt) end end) end end))
    table.insert(tCn[pt],pt.ChildRemoved:Connect(function(c) if c:IsA("SurfaceGui") then uSG(c) end end))
end
local function uTP(pt) if tCn[pt] then for _,c in ipairs(tCn[pt]) do c:Disconnect() end; tCn[pt]=nil end; local s=pt:FindFirstChildOfClass("SurfaceGui"); if s then uSG(s) end end
local function fullScan()
    local tf=workspace:FindFirstChild("Tiles"); if not tf then return end; worldTileSet={}
    for _,pt in ipairs(tf:GetChildren()) do if pt:IsA("BasePart") then local gR,gC=fndG(pt.Position); local sg2=pt:FindFirstChildOfClass("SurfaceGui"); if sg2 then for _,il in ipairs(sg2:GetChildren()) do if il:IsA("ImageLabel") then local lC,lR=pTI(il.Position,gR,gC); local pX,pY=wTP(gR,gC,lC,lR); sWT(pX,pY,true) end end end end end
end
local worldWatching=false
local function startWatching()
    local tf=workspace:FindFirstChild("Tiles"); if not tf then return end
    for _,p in ipairs(tf:GetChildren()) do wTP2(p) end
    table.insert(mCn,tf.ChildAdded:Connect(function(p) wTP2(p) end))
    table.insert(mCn,tf.ChildRemoved:Connect(function(p) uTP(p); if p:IsA("BasePart") then local s=p:FindFirstChildOfClass("SurfaceGui"); if s then for _,il in ipairs(s:GetChildren()) do if il:IsA("ImageLabel") then oIR(il,p) end end end end end))
end
local function stopWatching() for _,c in ipairs(mCn) do c:Disconnect() end; mCn={}; for p in pairs(tCn) do uTP(p) end; for s in pairs(sCn) do uSG(s) end end
local function ensureWatching() if not worldWatching then fullScan(); startWatching(); worldWatching=true end end

-- ============================================================
--  HARVEST  (fixed sweep pattern)
--
--  Row 1 (first):
--    Pass 1 RIGHT  farmStartX -> X99   fire at rowY   (center)
--    Pass 2 LEFT   X99 -> X0           fire at rowY-2 (below)
--    handleBoundary(false) at X=0 -> fall to row 2
--
--  Middle rows (ri 2..N-1):
--    RIGHT   X1 -> X100    fire at rowY-2 (below)
--    handleBoundary(true) at X=100 -> fall to next row
--
--  Last row (ri N):
--    Collect LEFT  X99 -> X1  (no firing, just pick up drops)
--    Fall RIGHT    X1 -> X100 -> drop to break floor
--
--  Single row: Pass1+Pass2 then fall right to break floor.
-- ============================================================
local function RunHarvest(rows, guardFn, refY)
    ensureWatching()

    -- ── Miss tracking (same logic as RunPlant) ────────────────────────
    -- After firing fstR at a tile, we wait HARVEST_MISS_DELAY seconds.
    -- If the tile (wTE) is STILL there after that delay, it's a miss:
    -- we stop, walk to it, fire several more times, walk back, resume.
    local HARVEST_MISS_DELAY = 0.65
    local hPending = {}
    local hIgnored = {}
    local function hIsIgn(x,y) return hIgnored[x..","..y]==true end
    local function hIgn(x,y)   hIgnored[x..","..y]=true end
    local function hClearPending() hPending={} end

    -- Queue a fire event and track the tile for miss detection.
    local function hFire(ix, targetY)
        if ix>=1 and ix<99 and wTE(ix,targetY) and not hIsIgn(ix,targetY) then
            fstR:FireServer(Vector2.new(ix,targetY))
            -- Don't duplicate-track the same tile
            for _,p in ipairs(hPending) do
                if p.x==ix and p.y==targetY then return end
            end
            table.insert(hPending, {x=ix, y=targetY, timestamp=tick()})
        end
    end

    -- Returns the first expired pending tile that is still present (miss), or nil.
    local function getMiss()
        local now=tick()
        for i=#hPending,1,-1 do
            local p=hPending[i]
            if now-p.timestamp >= HARVEST_MISS_DELAY then
                table.remove(hPending,i)
                if not wTE(p.x,p.y) then
                    hIgn(p.x,p.y)           -- already broken, good
                elseif not hIsIgn(p.x,p.y) then
                    return p.x, p.y         -- still present = miss
                end
            end
        end
        return nil,nil
    end

    -- Walk to missX, fire multiple times, mark ignored, walk back to resumeX.
    -- resumeRowY is used to climb back if we fell during the detour.
    local function fixHarvestMiss(missX, missY, resumeX, resumeRowY, gFn)
        stopAll(); SetStatus("H-MISS X="..missX, Color3.fromRGB(255,130,50))
        local _,cy = GetTileIndex()
        if cy and cy < resumeRowY then
            climbToY(resumeRowY, gFn); if not gFn() then return false end
            resumeX = GetTileIndex()
        end
        walkToX(missX, gFn); if not gFn() then return false end
        for _=1,4 do
            if wTE(missX,missY) then fstR:FireServer(Vector2.new(missX,missY)) end
            task.wait(0.05)
        end
        hIgn(missX,missY)
        if not gFn() then return false end
        if resumeX then walkToX(resumeX, gFn); if not gFn() then return false end end
        return true
    end
    -- ─────────────────────────────────────────────────────────────────

    -- Position at top row
    local _,iy = GetTileIndex()
    if iy and iy < rows[1] then climbToY(rows[1],guardFn); if not guardFn() then return false end end
    walkToX(CFG.farmStartX or 1, guardFn); if not guardFn() then return false end

    for ri, rowY in ipairs(rows) do
        if not guardFn() then return false end
        local isFirst = (ri == 1)
        local isLast  = (ri == #rows)
        local belowY  = rowY - 2
        local lr

        -- Y sanity check
        local _,curY = GetTileIndex()
        if curY and curY < rowY then climbToY(rowY,guardFn); if not guardFn() then return false end end

        -- ══════════════════════════════════════════════════════
        --  FIRST ROW: Pass1 center RIGHT + Pass2 below LEFT
        -- ══════════════════════════════════════════════════════
        if isFirst then

            -- Pass 1: RIGHT farmStartX -> X99, fire at rowY
            hClearPending()
            SetStatus("HARVEST "..ri.."/"..#rows.." CTR ->", Color3.fromRGB(255,200,80))
            lr = tick(); startMoveRight()
            while guardFn() do
                local ix,iy2 = GetTileIndex(); if not ix then task.wait(0.01); continue end
                if iy2 and iy2 < rowY then
                    stopAll(); climbToY(rowY,guardFn); if not guardFn() then return false end
                    walkToX(JUMP_LEFT,guardFn); if not guardFn() then return false end
                    lr=tick(); startMoveRight(); continue
                end
                if ix >= JUMP_RIGHT then stopAll(); break end
                local mX,mY = getMiss()
                if mX then
                    local rx=GetTileIndex()
                    if not fixHarvestMiss(mX,mY,rx,rowY,guardFn) then return false end
                    lr=tick(); startMoveRight(); continue
                end
                if tick()-lr >= MOVE_REFRESH then startMoveRight(); lr=tick() end
                hFire(ix, rowY)
                task.wait(0.01)
            end
            stopAll(); if not guardFn() then return false end

            -- Pass 2: LEFT X99 -> X0, fire at belowY
            hClearPending()
            SetStatus("HARVEST "..ri.."/"..#rows.." BLW <-", Color3.fromRGB(220,160,60))
            lr=tick(); startMoveLeft(); local fellEarlyP2=false
            while guardFn() do
                local ix,iy2 = GetTileIndex(); if not ix then task.wait(0.01); continue end
                if iy2 and iy2 < rowY then
                    if ix <= 3 then break end
                    fellEarlyP2=true; stopAll(); break
                end
                if ix <= TRAVERSE_LEFT then stopAll(); break end
                local mX,mY = getMiss()
                if mX then
                    local rx=GetTileIndex()
                    if not fixHarvestMiss(mX,mY,rx,rowY,guardFn) then return false end
                    lr=tick(); startMoveLeft(); continue
                end
                if tick()-lr >= MOVE_REFRESH then startMoveLeft(); lr=tick() end
                if belowY>BREAK_FLOOR_Y then hFire(ix, belowY) end
                task.wait(0.01)
            end
            stopAll(); if not guardFn() then return false end

            -- Recover unexpected mid-sweep fall in pass 2
            if fellEarlyP2 then
                climbToY(rowY,guardFn); if not guardFn() then return false end
                walkToX(JUMP_RIGHT,guardFn); if not guardFn() then return false end
                SetStatus("H-REDO BLW <-", Color3.fromRGB(220,130,50))
                lr=tick(); startMoveLeft()
                while guardFn() do
                    local ix,iy2 = GetTileIndex(); if not ix then task.wait(0.01); continue end
                    if iy2 and iy2 < rowY then stopAll(); break end
                    if ix <= TRAVERSE_LEFT then stopAll(); break end
                    local mX,mY = getMiss()
                    if mX then
                        local rx=GetTileIndex()
                        if not fixHarvestMiss(mX,mY,rx,rowY,guardFn) then return false end
                        lr=tick(); startMoveLeft(); continue
                    end
                    if tick()-lr >= MOVE_REFRESH then startMoveLeft(); lr=tick() end
                    if belowY>BREAK_FLOOR_Y then hFire(ix, belowY) end
                    task.wait(0.01)
                end
                stopAll(); if not guardFn() then return false end
            end

            if not isLast then
                SetStatus("FALL -> ROW "..(ri+1), Color3.fromRGB(150,150,255))
                local res,_ = handleBoundary(false,guardFn,refY)
                if res=="stopped" then return false end
                task.wait(0.1)
                walkToX(JUMP_LEFT,guardFn); if not guardFn() then return false end
            else
                SetStatus("-> BREAK FLOOR", Color3.fromRGB(255,100,80))
                lr=tick(); startMoveRight()
                while guardFn() do
                    local _,iy2=GetTileIndex()
                    if iy2 and iy2<=BREAK_FLOOR_Y then stopAll(); task.wait(0.15); break end
                    if tick()-lr>=MOVE_REFRESH then startMoveRight(); lr=tick() end
                    task.wait(0.01)
                end
                stopAll(); if not guardFn() then return false end
            end

        -- ══════════════════════════════════════════════════════
        --  LAST ROW (y=9): collect drops LEFT X99->X1.
        --  If the player lands on the wrong row at ANY point,
        --  climb back to rowY, walk to fallX, resume left.
        --  Only after reaching X1 do we walk right to break floor.
        -- ══════════════════════════════════════════════════════
        elseif isLast then

            walkToX(JUMP_RIGHT,guardFn); if not guardFn() then return false end

            SetStatus("COLLECT "..ri.."/"..#rows.." <- Y="..rowY, Color3.fromRGB(80,220,255))
            lr=tick(); startMoveLeft()
            while guardFn() do
                local ix,iy2 = GetTileIndex(); if not ix then task.wait(0.01); continue end

                -- Wrong row: climb back, resume from fallX
                if iy2 and iy2 ~= rowY then
                    stopAll()
                    local fallX = math.max(ix, JUMP_LEFT)
                    climbToY(rowY, guardFn); if not guardFn() then return false end
                    walkToX(fallX, guardFn); if not guardFn() then return false end
                    lr=tick(); startMoveLeft(); continue
                end

                if ix <= JUMP_LEFT then stopAll(); break end
                if tick()-lr >= MOVE_REFRESH then startMoveLeft(); lr=tick() end
                task.wait(0.01)
            end
            stopAll(); if not guardFn() then return false end

            SetStatus("-> BREAK FLOOR", Color3.fromRGB(255,100,80))
            walkToX(JUMP_LEFT,guardFn); if not guardFn() then return false end
            lr=tick(); startMoveRight()
            while guardFn() do
                local _,iy2 = GetTileIndex()
                if iy2 and iy2 <= BREAK_FLOOR_Y then stopAll(); task.wait(0.15); break end
                if tick()-lr >= MOVE_REFRESH then startMoveRight(); lr=tick() end
                task.wait(0.01)
            end
            stopAll(); if not guardFn() then return false end

        -- ══════════════════════════════════════════════════════
        --  MIDDLE ROW: RIGHT sweep below, fall RIGHT to next row
        -- ══════════════════════════════════════════════════════
        else

            hClearPending()
            walkToX(JUMP_LEFT,guardFn); if not guardFn() then return false end

            SetStatus("HARVEST "..ri.."/"..#rows.." BLW ->", Color3.fromRGB(220,160,60))
            lr=tick(); startMoveRight()
            while guardFn() do
                local ix,iy2 = GetTileIndex(); if not ix then task.wait(0.01); continue end
                if iy2 and iy2 < rowY then
                    if ix >= TRAVERSE_RIGHT-2 then stopAll(); break end
                    stopAll(); climbToY(rowY,guardFn); if not guardFn() then return false end
                    walkToX(JUMP_LEFT,guardFn); if not guardFn() then return false end
                    lr=tick(); startMoveRight(); continue
                end
                if ix >= TRAVERSE_RIGHT then stopAll(); break end
                local mX,mY = getMiss()
                if mX then
                    local rx=GetTileIndex()
                    if not fixHarvestMiss(mX,mY,rx,rowY,guardFn) then return false end
                    lr=tick(); startMoveRight(); continue
                end
                if tick()-lr >= MOVE_REFRESH then startMoveRight(); lr=tick() end
                if belowY>BREAK_FLOOR_Y then hFire(ix, belowY) end
                task.wait(0.01)
            end
            stopAll(); if not guardFn() then return false end

            local res,_ = handleBoundary(true,guardFn,refY)
            if res=="stopped" then return false end
            task.wait(0.1)
        end
    end
    return true
end

-- ============================================================
--  BREAK  (multi-pass: place exactly CFG.breakBlocks tile-by-tile,
--          fist back, repeat until inventory is empty.
--          All waits are minimal for maximum speed.)
-- ============================================================
local function RunBreak(guardFn)
    if not CFG.breakX then SetStatus("BREAK: No X set!", Color3.fromRGB(255,80,80)); return false end
    SetStatus("BREAK -> X="..CFG.breakX, Color3.fromRGB(220,150,50))
    walkToX(CFG.breakX,guardFn); if not guardFn() then return false end
    local breakStartX = GetTileIndex() or CFG.breakX
    local passNum = 0

    -- Fast inventory poll: sample a few times with tiny gaps to let server sync.
    local function pollTotal(timeout)
        local deadline = tick() + (timeout or 0.2)
        local prev = -1
        while tick() < deadline do
            local t = GetTotalByCode(CFG.breakItem)
            if t == prev and t >= 0 then return t end
            prev = t; task.wait(0.05)
        end
        return GetTotalByCode(CFG.breakItem)
    end

    while guardFn() do
        local total = pollTotal(0.1)
        if total <= 0 then
            SetStatus("BREAK: inventory empty -> plant", Color3.fromRGB(150,255,180))
            break
        end

        passNum += 1
        -- Always try to place the full breakBlocks count; cap at what we have.
        local toPlace = math.min(CFG.breakBlocks, total)

        walkToX(breakStartX,guardFn); if not guardFn() then return false end
        local _,iy0 = GetTileIndex(); iy0 = iy0 or BREAK_FLOOR_Y

        -- ── PLACE: move right continuously, one block per unique tile ─
        --  Reference-style movement (startMoveRight once, key refresh),
        --  but guarded by lastPlacedX so only ONE block is fired per
        --  tile — guaranteeing exactly toPlace (default 26) total blocks.
        SetStatus("BREAK P"..passNum..": PLACE "..toPlace.." ->", Color3.fromRGB(85,215,110))
        local placed     = 0
        local placeEndX  = breakStartX
        local lastPlacedX = -999   -- tracks last tile a block was placed on

        local lr = tick(); startMoveRight()
        while guardFn() do
            local ix, iy = GetTileIndex()
            if not ix then task.wait(0.01); continue end
            iy = iy or iy0

            -- Done or hit boundary
            if placed >= toPlace or ix >= TRAVERSE_RIGHT then break end

            -- Keep movement key alive (reference pattern)
            if tick() - lr >= MOVE_REFRESH then startMoveRight(); lr = tick() end

            -- Only place once per tile (ix - 1 offset, same as reference)
            if ix ~= lastPlacedX then
                local slotN = FindSlotByCode(CFG.breakItem)
                if slotN then
                    placeR:FireServer(Vector2.new(ix - 1, iy), slotN)
                    placed += 1
                    placeEndX  = ix
                    lastPlacedX = ix
                else
                    break  -- inventory empty mid-pass
                end
            end

            task.wait(0.01)
        end
        releaseKey(Enum.KeyCode.D); stopAll()
        task.wait(0.05); if not guardFn() then return false end

        if placed == 0 then
            SetStatus("BREAK P"..passNum..": no blocks placed, retry...", Color3.fromRGB(220,180,80))
            task.wait(0.15)
            passNum -= 1
            continue
        end

        -- ── FIST: walk left from placeEndX back to breakStartX ───────
        SetStatus("BREAK P"..passNum..": FIST <- "..placed, Color3.fromRGB(220,150,50))
        walkToX(placeEndX, guardFn); if not guardFn() then return false end
        local lr = tick(); startMoveLeft()
        while guardFn() do
            local ix, iy = GetTileIndex(); if not ix then task.wait(0.01); continue end
            if ix <= breakStartX then break end
            if tick() - lr >= MOVE_REFRESH then startMoveLeft(); lr = tick() end
            fstR:FireServer(Vector2.new(ix - 1, iy or iy0)); task.wait(0.02)
        end
        releaseKey(Enum.KeyCode.A); stopAll()

        -- Quick settle then check remaining
        task.wait(0.1)
        local remaining = pollTotal(0.2)
        if remaining <= 0 then
            SetStatus("BREAK: inventory empty -> plant", Color3.fromRGB(150,255,180))
            break
        end
        SetStatus("BREAK: "..remaining.." left, pass "..(passNum+1), Color3.fromRGB(220,180,80))
    end
    return guardFn()
end

-- ============================================================
--  PLANT: bottom-up per batch, direction from nearest edge.
--
--  Key rules:
--    • sweepRight is NEVER changed after the initial climb.
--      Fall recovery climbs back up and resumes from fallX in the
--      same direction — it never resets to X=99/X=1.
--    • Miss recovery: go fix missX, then walk back to resumeX
--      (the position we held before the detour) and continue.
--      If the player falls while returning, the fall recovery
--      walks back to resumeX as well, keeping direction intact.
-- ============================================================
local function RunPlant(rows, guardFn, refY)
    ensureWatching()
    local pending, ignored = {}, {}
    local function isIgn(x,y) return ignored[x..","..y] end
    local function ign(x,y)   ignored[x..","..y]=true end

    for pi=#rows,1,-1 do
        local rowY=rows[pi]; if not guardFn() then return false end
        SetStatus("PLANT "..(#rows-pi+1).."/"..#rows.." Y="..rowY, Color3.fromRGB(85,215,110))

        -- Climb to the row and decide initial direction once.
        local _,fromRight = climbToY(rowY,guardFn); if not guardFn() then return false end
        local _,curY = GetTileIndex()
        if curY and curY < rowY then
            climbToY(rowY,guardFn); if not guardFn() then return false end
            local ax=GetTileIndex(); fromRight = ax and ax>=50 or false
        end

        -- sweepRight is set here and NEVER overwritten during this row.
        local sweepRight = not fromRight
        SetStatus("PLANT "..(#rows-pi+1).."/"..#rows..(sweepRight and " ->" or " <-"), Color3.fromRGB(85,215,110))

        -- resumeAfterFall: when non-nil, after climbing back up the
        -- fall-recovery walks to this X before resuming the sweep.
        local resumeAfterFall = nil

        local lr=tick()
        if sweepRight then startMoveRight() else startMoveLeft() end

        while guardFn() do
            local ix,iy2 = GetTileIndex(); if not ix then task.wait(0.01); continue end

            -- ── Fell to wrong row ──────────────────────────────────────
            -- Climb back, walk to fallX (or resumeAfterFall if set),
            -- then continue in the SAME sweepRight direction.
            -- We deliberately do NOT change sweepRight here.
            if iy2 and iy2 < rowY then
                stopAll()
                local fallX = resumeAfterFall or ix   -- where to resume after climb
                climbToY(rowY, guardFn); if not guardFn() then return false end
                -- Walk to the position we had before falling, not the edge.
                walkToX(fallX, guardFn); if not guardFn() then return false end
                resumeAfterFall = nil   -- consumed
                lr = tick()
                if sweepRight then startMoveRight() else startMoveLeft() end
                continue
            end

            -- ── Sweep boundary ─────────────────────────────────────────
            if sweepRight     and ix >= TRAVERSE_RIGHT then stopAll(); break end
            if not sweepRight and ix <= TRAVERSE_LEFT  then stopAll(); break end

            -- ── Miss check ─────────────────────────────────────────────
            local now=tick(); local missX,missY=nil,nil
            for i=#pending,1,-1 do local p=pending[i]
                if now-p.timestamp >= PLANT_DELAY then
                    if wTE(p.x,p.y) then
                        ign(p.x,p.y); table.remove(pending,i)
                    elseif not isIgn(p.x,p.y) then
                        missX,missY=p.x,p.y; table.remove(pending,i); break
                    else
                        table.remove(pending,i)
                    end
                end
            end

            if missX then
                stopAll(); SetStatus("P-MISS X="..missX, Color3.fromRGB(255,180,80))

                -- Remember where we are NOW — this is where we must
                -- return after fixing the miss so the sweep continues
                -- forward from the correct position.
                local resumeX, recY = GetTileIndex()

                -- If we somehow fell before the miss was detected,
                -- climb back up first.
                if recY and missY and recY < missY then
                    climbToY(missY, guardFn); if not guardFn() then return false end
                    resumeX = GetTileIndex()
                end

                -- Set the fall-recovery target so that if we fall
                -- while walking to/from missX, we come back to resumeX
                -- and NOT to the sweep start edge.
                resumeAfterFall = resumeX

                -- Go plant the missed tile.
                walkToX(missX, guardFn); if not guardFn() then return false end
                for _=1,5 do
                    local s=FindSlotByCode(CFG.plantItem)
                    if s then placeR:FireServer(Vector2.new(missX,missY),s) end
                    task.wait(0.02)
                end
                ign(missX,missY)
                if not guardFn() then return false end

                -- Walk back to resumeX (our pre-detour position) and
                -- continue sweeping in the same direction.
                -- If we fall during this walk, resumeAfterFall ensures
                -- the fall handler brings us back here, not to the edge.
                if resumeX then
                    walkToX(resumeX, guardFn); if not guardFn() then return false end
                end
                resumeAfterFall = nil   -- cleared once we've arrived
                lr=tick()
                if sweepRight then startMoveRight() else startMoveLeft() end
                continue
            end

            -- ── Keep movement key refreshed ────────────────────────────
            if tick()-lr >= MOVE_REFRESH then
                if sweepRight then startMoveRight() else startMoveLeft() end; lr=tick()
            end

            -- ── Plant on empty active tiles ────────────────────────────
            if iy2 and ix>0 and ix<100 and iy2>BREAK_FLOOR_Y and (refY-iy2)%2==0
               and not isIgn(ix,iy2) and not wTE(ix,iy2) then
                local slotN=FindSlotByCode(CFG.plantItem)
                if slotN then
                    placeR:FireServer(Vector2.new(ix,iy2), slotN)
                    table.insert(pending, {x=ix, y=iy2, timestamp=tick()})
                end
            end
            task.wait(0.01)
        end
        stopAll(); if not guardFn() then return false end
    end
    return true
end

-- ============================================================
--  GROW WAIT
-- ============================================================
local function RunGrowWait(guardFn)
    if CFG.skipGrow then SetStatus("SKIP WAIT -> NEXT", Color3.fromRGB(180,255,200)); task.wait(1); return true end
    local ws=tick()
    while guardFn() and tick()-ws<CFG.growTime do
        local rem=math.ceil(CFG.growTime-(tick()-ws)); local m=math.floor(rem/60); local s=rem%60
        SetStatus("GROW: "..m.."m "..s.."s  #"..cycleCount, Color3.fromRGB(180,220,255)); task.wait(1)
    end; return guardFn()
end

-- ============================================================
--  BATCH ADVANCEMENT  (go DOWN each cycle, wrap to farmStartY)
--
--  Example: farmStartY=21, rowsPerCycle=3, step=6
--    Batch 1: Y=21  rows={21,19,17}
--    Batch 2: Y=15  rows={15,13,11}
--    Batch 3: Y=9   rows={9}          <- last valid (Y=7 is break floor)
--    Batch 4: nextY=3  no valid rows  -> wrap to Y=21
-- ============================================================
local function advanceBatch()
    local step    = CFG.rowsPerCycle * 2
    local nextY   = currentBatchY - step          -- go DOWN
    local nextRows= getRows(nextY, CFG.rowsPerCycle, CFG.farmStartY)
    if #nextRows > 0 then
        currentBatchY = nextY
        SetStatus("NEXT BATCH Y="..currentBatchY, Color3.fromRGB(150,255,180))
    else
        currentBatchY = CFG.farmStartY            -- wrap back to top
        SetStatus("WRAP -> START Y="..currentBatchY, Color3.fromRGB(180,255,200))
    end
end

-- ============================================================
--  MAIN CYCLE
--  Harvest (collect+break-floor fall embedded) -> Break -> Plant -> Grow -> Advance
-- ============================================================
local function RunCycle()
    cycleCount=0
    if not CFG.farmStartX or not CFG.farmStartY then SetStatus("SET FARM START!", Color3.fromRGB(255,80,80)); isRunning=false; return end
    if not CFG.breakX    then SetStatus("SET BREAK POS!",   Color3.fromRGB(255,80,80)); isRunning=false; return end
    if not CFG.plantItem then SetStatus("APPLY PLANT ITEM!",Color3.fromRGB(255,80,80)); isRunning=false; return end
    if not CFG.breakItem then SetStatus("APPLY BREAK ITEM!",Color3.fromRGB(255,80,80)); isRunning=false; return end

    local refY=CFG.farmStartY
    local guard=function() return isRunning and not inst.dead end

    -- Apply one-time batchStart offset: skip (batchStart-1) batches downward.
    -- After each full cycle the loop always wraps back to farmStartY (batch 1).
    currentBatchY = CFG.farmStartY
    if CFG.batchStart > 1 then
        local step = CFG.rowsPerCycle * 2
        for _=1, CFG.batchStart-1 do
            local nextY   = currentBatchY - step
            local nextRows= getRows(nextY, CFG.rowsPerCycle, refY)
            if #nextRows > 0 then currentBatchY = nextY
            else break end
        end
        SetStatus("BATCH START "..CFG.batchStart.."  Y="..currentBatchY, Color3.fromRGB(180,255,200))
    end

    ensureWatching()
    while guard() do
        cycleCount+=1
        local rows=getRows(currentBatchY,CFG.rowsPerCycle,refY)
        if #rows==0 then
            currentBatchY=CFG.farmStartY; rows=getRows(currentBatchY,CFG.rowsPerCycle,refY)
            if #rows==0 then SetStatus("NO VALID ROWS!", Color3.fromRGB(255,80,80)); break end
        end
        SetStatus("CYCLE #"..cycleCount.."  Y="..currentBatchY, Color3.fromRGB(180,255,200))
        -- 1. Harvest (last row handles collect + fall to break floor)
        RunHarvest(rows,guard,refY); if not guard() then break end
        -- 2. Break
        RunBreak(guard);             if not guard() then break end
        -- 3. Plant
        RunPlant(rows,guard,refY);   if not guard() then break end
        -- 4. Grow wait
        RunGrowWait(guard);          if not guard() then break end
        -- 5. Advance to next batch (downward); wraps to farmStartY when exhausted
        advanceBatch()
    end
    isRunning=false; stopAll(); SetStatus("STOPPED", Color3.fromRGB(255,100,100))
end

-- ============================================================
--  GUI
-- ============================================================
local lastSelSlot=nil
local oldG=gui:FindFirstChild("RotFarmGui"); if oldG then oldG:Destroy() end
local sg=Instance.new("ScreenGui",gui); sg.Name="RotFarmGui"; sg.ResetOnSpawn=false; sg.IgnoreGuiInset=true

local WIN_W=250
local WIN_H_FULL=260
local WIN_H_MIN=28   -- collapsed = just title bar

local main=Instance.new("Frame",sg)
main.Size=UDim2.new(0,WIN_W,0,WIN_H_FULL)
main.Position=UDim2.new(0.5,-WIN_W/2,0.05,0)
main.BackgroundColor3=Color3.fromRGB(18,24,20); main.BorderSizePixel=0; main.ClipsDescendants=true
Instance.new("UICorner",main).CornerRadius=UDim.new(0,10)
local ms=Instance.new("UIStroke",main); ms.Color=Color3.fromRGB(55,140,70); ms.Thickness=1.5

-- Drag (only on title bar so content area doesn't fight it)
local dragging,dragSt,dragPos=false,nil,nil
local function attachDrag(bar)
    bar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
            dragging=true; dragSt=i.Position; dragPos=main.Position end end)
end
table.insert(inst.connections,UIS.InputChanged:Connect(function(i)
    if not dragging then return end
    if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then
        local d=i.Position-dragSt
        main.Position=UDim2.new(dragPos.X.Scale,dragPos.X.Offset+d.X,dragPos.Y.Scale,dragPos.Y.Offset+d.Y) end end))
table.insert(inst.connections,UIS.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end end))

-- Title bar
local titleBar=Instance.new("Frame",main)
titleBar.Size=UDim2.new(1,0,0,28); titleBar.BackgroundColor3=Color3.fromRGB(28,42,32); titleBar.BorderSizePixel=0
Instance.new("UICorner",titleBar).CornerRadius=UDim.new(0,10)
local tbf=Instance.new("Frame",titleBar); tbf.Size=UDim2.new(1,0,0,12); tbf.Position=UDim2.new(0,0,1,-12); tbf.BackgroundColor3=Color3.fromRGB(28,42,32); tbf.BorderSizePixel=0
attachDrag(titleBar)

local ttxt=Instance.new("TextLabel",titleBar); ttxt.Size=UDim2.new(1,-70,1,0); ttxt.Position=UDim2.new(0,10,0,0)
ttxt.BackgroundTransparency=1; ttxt.Text="RotFarm v3.0"; ttxt.TextColor3=Color3.fromRGB(180,255,195)
ttxt.TextSize=12; ttxt.Font=Enum.Font.GothamBold; ttxt.TextXAlignment=Enum.TextXAlignment.Left

-- Minimize button
local minBtn=Instance.new("TextButton",titleBar)
minBtn.Size=UDim2.new(0,20,0,20); minBtn.Position=UDim2.new(1,-47,0.5,-10)
minBtn.BackgroundColor3=Color3.fromRGB(50,90,60); minBtn.BorderSizePixel=0
minBtn.Text="−"; minBtn.TextColor3=Color3.fromRGB(180,255,195); minBtn.TextSize=16; minBtn.Font=Enum.Font.GothamBold
Instance.new("UICorner",minBtn).CornerRadius=UDim.new(0,4)

-- Close button
local xBtn=Instance.new("TextButton",titleBar)
xBtn.Size=UDim2.new(0,20,0,20); xBtn.Position=UDim2.new(1,-23,0.5,-10)
xBtn.BackgroundColor3=Color3.fromRGB(160,50,50); xBtn.BorderSizePixel=0
xBtn.Text="x"; xBtn.TextColor3=Color3.new(1,1,1); xBtn.TextSize=11; xBtn.Font=Enum.Font.GothamBold
Instance.new("UICorner",xBtn).CornerRadius=UDim.new(0,4)

-- Minimize logic
minBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        main.Size=UDim2.new(0,WIN_W,0,WIN_H_MIN)
        minBtn.Text="+"
    else
        main.Size=UDim2.new(0,WIN_W,0,WIN_H_FULL)
        minBtn.Text="−"
    end
end)

-- Scrollable content
local ct=Instance.new("ScrollingFrame",main); ct.Size=UDim2.new(1,0,1,-28); ct.Position=UDim2.new(0,0,0,28)
ct.BackgroundTransparency=1; ct.BorderSizePixel=0; ct.ScrollBarThickness=4; ct.ScrollBarImageColor3=Color3.fromRGB(80,150,95)
ct.ScrollingDirection=Enum.ScrollingDirection.Y; ct.CanvasSize=UDim2.new(0,0,0,0)
local cpad=Instance.new("UIPadding",ct); cpad.PaddingLeft=UDim.new(0,10); cpad.PaddingRight=UDim.new(0,10); cpad.PaddingTop=UDim.new(0,8); cpad.PaddingBottom=UDim.new(0,12)

-- GUI helpers
local function Lbl(txt,y,h,col,ts,font) local l=Instance.new("TextLabel",ct); l.Size=UDim2.new(1,0,0,h); l.Position=UDim2.new(0,0,0,y); l.BackgroundTransparency=1; l.Text=txt; l.TextColor3=col; l.TextSize=ts; l.Font=font or Enum.Font.Gotham; l.TextXAlignment=Enum.TextXAlignment.Left; return l end
local function Cap(txt,y) return Lbl(txt,y,12,Color3.fromRGB(100,160,115),9,Enum.Font.GothamBold) end
local function Inf(txt,y) return Lbl(txt,y,11,Color3.fromRGB(120,170,140),9) end
local function Div(y) local f=Instance.new("Frame",ct); f.Size=UDim2.new(1,0,0,1); f.Position=UDim2.new(0,0,0,y); f.BackgroundColor3=Color3.fromRGB(45,75,55); f.BorderSizePixel=0; return f end
local function Btn(txt,y,h,xs,w,col,fn) local b=Instance.new("TextButton",ct); b.Size=UDim2.new(w,0,0,h); b.Position=UDim2.new(xs,0,0,y); b.BackgroundColor3=col; b.BorderSizePixel=0; b.Text=txt; b.TextColor3=Color3.new(1,1,1); b.TextSize=10; b.Font=Enum.Font.GothamBold; Instance.new("UICorner",b).CornerRadius=UDim.new(0,5); if fn then b.MouseButton1Click:Connect(fn) end; return b end
local function Stepper(y,default,minV,maxV,stepV,onChange)
    local f=Instance.new("Frame",ct); f.Size=UDim2.new(1,0,0,24); f.Position=UDim2.new(0,0,0,y); f.BackgroundColor3=Color3.fromRGB(26,36,30); f.BorderSizePixel=0; Instance.new("UICorner",f).CornerRadius=UDim.new(0,5)
    local val=default
    local minus=Instance.new("TextButton",f); minus.Size=UDim2.new(0,28,1,0); minus.BackgroundColor3=Color3.fromRGB(140,60,60); minus.BorderSizePixel=0; minus.Text="-"; minus.TextColor3=Color3.new(1,1,1); minus.TextSize=16; minus.Font=Enum.Font.GothamBold; Instance.new("UICorner",minus).CornerRadius=UDim.new(0,4)
    local lbl=Instance.new("TextLabel",f); lbl.Size=UDim2.new(1,-56,1,0); lbl.Position=UDim2.new(0,28,0,0); lbl.BackgroundTransparency=1; lbl.Text=tostring(val); lbl.TextColor3=Color3.fromRGB(180,255,200); lbl.TextSize=12; lbl.Font=Enum.Font.GothamBold
    local plus=Instance.new("TextButton",f); plus.Size=UDim2.new(0,28,1,0); plus.Position=UDim2.new(1,-28,0,0); plus.BackgroundColor3=Color3.fromRGB(45,130,65); plus.BorderSizePixel=0; plus.Text="+"; plus.TextColor3=Color3.new(1,1,1); plus.TextSize=16; plus.Font=Enum.Font.GothamBold; Instance.new("UICorner",plus).CornerRadius=UDim.new(0,4)
    minus.MouseButton1Click:Connect(function() if val>minV then val=val-stepV; lbl.Text=tostring(val); if onChange then onChange(val) end end end)
    plus.MouseButton1Click:Connect(function()  if val<maxV then val=val+stepV; lbl.Text=tostring(val); if onChange then onChange(val) end end end)
    return f,lbl end
local function Checkbox(txt,y,state,onChange)
    local f=Instance.new("Frame",ct); f.Size=UDim2.new(1,0,0,24); f.Position=UDim2.new(0,0,0,y); f.BackgroundColor3=Color3.fromRGB(26,36,30); f.BorderSizePixel=0; Instance.new("UICorner",f).CornerRadius=UDim.new(0,5)
    local chk=Instance.new("TextButton",f); chk.Size=UDim2.new(0,18,0,18); chk.Position=UDim2.new(0,5,0.5,-9); chk.BackgroundColor3=state and Color3.fromRGB(42,150,70) or Color3.fromRGB(55,65,58); chk.BorderSizePixel=0; chk.Text=state and "v" or ""; chk.TextColor3=Color3.new(1,1,1); chk.TextSize=13; chk.Font=Enum.Font.GothamBold; Instance.new("UICorner",chk).CornerRadius=UDim.new(0,4)
    local lbl=Instance.new("TextLabel",f); lbl.Size=UDim2.new(1,-30,1,0); lbl.Position=UDim2.new(0,28,0,0); lbl.BackgroundTransparency=1; lbl.Text=txt; lbl.TextColor3=Color3.fromRGB(200,230,210); lbl.TextSize=10; lbl.Font=Enum.Font.Gotham; lbl.TextXAlignment=Enum.TextXAlignment.Left
    chk.MouseButton1Click:Connect(function() state=not state; chk.BackgroundColor3=state and Color3.fromRGB(42,150,70) or Color3.fromRGB(55,65,58); chk.Text=state and "v" or ""; if onChange then onChange(state) end end) end

-- ── Layout ──────────────────────────────────────────────────────
local y=0
statusLabel=Instance.new("TextLabel",ct); statusLabel.Size=UDim2.new(1,0,0,22); statusLabel.Position=UDim2.new(0,0,0,y)
statusLabel.BackgroundTransparency=1; statusLabel.Text="[ IDLE ]"; statusLabel.TextColor3=Color3.fromRGB(150,255,180)
statusLabel.TextSize=10; statusLabel.Font=Enum.Font.GothamBold; statusLabel.TextXAlignment=Enum.TextXAlignment.Left; statusLabel.TextWrapped=true; y+=24

local posLbl=Inf("Pos: --",y); y+=14
Div(y); y+=8

Cap("FARM START POSITION",y); y+=13
local farmLbl=Inf("Farm: NOT SET",y); y+=12
Btn("SET FARM START",y,20,0,1,Color3.fromRGB(45,100,60),function()
    local ix,iy=GetTileIndex()
    if ix and iy then
        if iy<=BREAK_FLOOR_Y then SetStatus("Too low! Y > "..BREAK_FLOOR_Y.." required", Color3.fromRGB(255,80,80)); return end
        CFG.farmStartX,CFG.farmStartY=ix,iy; currentBatchY=iy
        farmLbl.Text="Farm: X="..ix.."  Y="..iy
        local r=getRows(iy,CFG.rowsPerCycle,iy); local s="Rows:"; for _,v in ipairs(r) do s=s.." "..v end
        SetStatus(s,Color3.fromRGB(100,255,150))
    else SetStatus("No position!",Color3.fromRGB(255,80,80)) end end); y+=24

Cap("BREAK POSITION",y); y+=13
local breakLbl=Inf("Break: X=70 (default)",y); y+=12
Btn("SET BREAK POS",y,20,0,1,Color3.fromRGB(130,80,40),function()
    local ix=GetTileIndex(); if ix then CFG.breakX=ix; breakLbl.Text="Break: X="..ix; SetStatus("Break X="..ix,Color3.fromRGB(220,180,80)) end end); y+=24
Div(y); y+=8

Cap("ROWS PER CYCLE  (default 3)",y); y+=13
Stepper(y,3,1,8,1,function(v)
    CFG.rowsPerCycle=v
    if CFG.farmStartY then local r=getRows(CFG.farmStartY,v,CFG.farmStartY); local s="Rows:"; for _,rv in ipairs(r) do s=s.." "..rv end; SetStatus(s,Color3.fromRGB(100,255,150)) end end); y+=28
Div(y); y+=8

Cap("BATCH START  (default 1 = top row)",y); y+=13
local batchStartLbl=Inf("Start at batch 1  (Y=".. (CFG.farmStartY or "?") ..")",y); y+=12
Stepper(y,1,1,20,1,function(v)
    CFG.batchStart=v
    if CFG.farmStartY then
        -- Calculate the Y of the selected batch for preview
        local step=CFG.rowsPerCycle*2
        local previewY=CFG.farmStartY
        for _=1,v-1 do
            local nextY=previewY-step
            local nr=getRows(nextY,CFG.rowsPerCycle,CFG.farmStartY)
            if #nr>0 then previewY=nextY else break end
        end
        batchStartLbl.Text="Start at batch "..v.."  (Y="..previewY..")"
    else
        batchStartLbl.Text="Start at batch "..v
    end
end); y+=28

Cap("HIGHLIGHTED ITEM IN INVENTORY",y); y+=13
local hlLbl=Inf("Selected: --",y); y+=12
Btn("APPLY PLANT",y,20,0,0.49,Color3.fromRGB(45,110,70),function()
    if not lastSelSlot then SetStatus("Highlight an item first!",Color3.fromRGB(255,80,80)); return end
    local k=GetSlotKey(lastSelSlot); if not k then return end; CFG.plantItem=GetCode(k); SetStatus("Plant: "..CFG.plantItem,Color3.fromRGB(85,210,115)) end)
Btn("APPLY BREAK",y,20,0.51,0.49,Color3.fromRGB(160,100,30),function()
    if not lastSelSlot then SetStatus("Highlight an item first!",Color3.fromRGB(255,80,80)); return end
    local k=GetSlotKey(lastSelSlot); if not k then return end; CFG.breakItem=GetCode(k); SetStatus("Break: "..CFG.breakItem,Color3.fromRGB(220,180,80)) end); y+=24

local plantItemLbl=Inf("Plant: NOT SET",y); y+=12
local breakItemLbl=Inf("Break: NOT SET",y); y+=14
Div(y); y+=8

Cap("BREAK BLOCKS  (default 26)",y); y+=13
Stepper(y,26,1,200,1,function(v) CFG.breakBlocks=v end); y+=28
Div(y); y+=8

Cap("GROWTH WAIT TIME",y); y+=13
local growVals={30,60,95,120,180}; local growIdx=3
local growBtn=Btn("GROW TIME: 95 min",y,20,0,1,Color3.fromRGB(55,75,105),nil)
growBtn.MouseButton1Click:Connect(function() growIdx=(growIdx%#growVals)+1; CFG.growTime=growVals[growIdx]*60; growBtn.Text="GROW TIME: "..growVals[growIdx].." min" end); y+=24

Checkbox("Ignore Growth Time (skip wait)",y,false,function(v) CFG.skipGrow=v end); y+=28
Div(y); y+=10

Btn("START",y,26,0,0.48,Color3.fromRGB(40,150,65),function() if isRunning then return end; isRunning=true; task.spawn(RunCycle) end)
Btn("STOP", y,26,0.52,0.48,Color3.fromRGB(170,50,50),function() isRunning=false; stopAll(); SetStatus("STOPPED",Color3.fromRGB(255,100,100)) end); y+=36

-- ── SAFE MODE ───────────────────────────────────────────────────
Div(y); y+=8
Cap("SAFE MODE",y); y+=14

Checkbox("Auto Stop  (stranger joins → stop farm)",y,false,function(v) safeAutoStop=v end); y+=28
Checkbox("Auto Leave  (stranger joins → leave game)",y,false,function(v) safeAutoLeave=v end); y+=28
Div(y); y+=8

-- ── WHITELIST ───────────────────────────────────────────────────
Cap("WHITELIST",y); y+=13

-- Live count label
local wlCountLbl=Inf("Users: "..#whitelist,y); y+=12

-- Names display (scrollable sub-frame)
local WL_LIST_H=60
local wlFrame=Instance.new("ScrollingFrame",ct)
wlFrame.Size=UDim2.new(1,0,0,WL_LIST_H); wlFrame.Position=UDim2.new(0,0,0,y)
wlFrame.BackgroundColor3=Color3.fromRGB(20,30,24); wlFrame.BorderSizePixel=0
wlFrame.ScrollBarThickness=3; wlFrame.ScrollBarImageColor3=Color3.fromRGB(60,120,75)
wlFrame.CanvasSize=UDim2.new(0,0,0,0); wlFrame.ScrollingDirection=Enum.ScrollingDirection.Y
Instance.new("UICorner",wlFrame).CornerRadius=UDim.new(0,5)
local wlPad=Instance.new("UIPadding",wlFrame); wlPad.PaddingLeft=UDim.new(0,6); wlPad.PaddingTop=UDim.new(0,4); wlPad.PaddingBottom=UDim.new(0,4)
y+=WL_LIST_H+6

-- Function to rebuild the whitelist display
local function RefreshWLDisplay()
    for _,c in pairs(wlFrame:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    for i,name in ipairs(whitelist) do
        local lbl=Instance.new("TextLabel",wlFrame)
        lbl.Size=UDim2.new(1,0,0,14); lbl.Position=UDim2.new(0,0,0,(i-1)*15)
        lbl.BackgroundTransparency=1; lbl.Text=(i==1 and "★ " or "  ")..name
        lbl.TextColor3=(i==1) and Color3.fromRGB(255,220,80) or Color3.fromRGB(160,220,180)
        lbl.TextSize=10; lbl.Font=Enum.Font.Gotham; lbl.TextXAlignment=Enum.TextXAlignment.Left
    end
    wlFrame.CanvasSize=UDim2.new(0,0,0,#whitelist*15+8)
    wlCountLbl.Text="Users: "..#whitelist
end
RefreshWLDisplay()

-- Add box + button
local addRow=Instance.new("Frame",ct); addRow.Size=UDim2.new(1,0,0,24); addRow.Position=UDim2.new(0,0,0,y)
addRow.BackgroundTransparency=1; addRow.BorderSizePixel=0; y+=28

local addBox=Instance.new("TextBox",addRow); addBox.Size=UDim2.new(0.68,0,1,0); addBox.Position=UDim2.new(0,0,0,0)
addBox.BackgroundColor3=Color3.fromRGB(26,36,30); addBox.BorderSizePixel=0
addBox.PlaceholderText="username..."; addBox.Text=""
addBox.PlaceholderColor3=Color3.fromRGB(80,110,90); addBox.TextColor3=Color3.fromRGB(200,240,210)
addBox.TextSize=10; addBox.Font=Enum.Font.Gotham; addBox.ClearTextOnFocus=false
Instance.new("UICorner",addBox).CornerRadius=UDim.new(0,4)
Instance.new("UIPadding",addBox).PaddingLeft=UDim.new(0,6)

local addBtn2=Instance.new("TextButton",addRow); addBtn2.Size=UDim2.new(0.15,0,1,0); addBtn2.Position=UDim2.new(0.70,0,0,0)
addBtn2.BackgroundColor3=Color3.fromRGB(40,130,60); addBtn2.BorderSizePixel=0
addBtn2.Text="ADD"; addBtn2.TextColor3=Color3.new(1,1,1); addBtn2.TextSize=9; addBtn2.Font=Enum.Font.GothamBold
Instance.new("UICorner",addBtn2).CornerRadius=UDim.new(0,4)

local remBtn=Instance.new("TextButton",addRow); remBtn.Size=UDim2.new(0.13,0,1,0); remBtn.Position=UDim2.new(0.87,0,0,0)
remBtn.BackgroundColor3=Color3.fromRGB(140,50,50); remBtn.BorderSizePixel=0
remBtn.Text="DEL"; remBtn.TextColor3=Color3.new(1,1,1); remBtn.TextSize=9; remBtn.Font=Enum.Font.GothamBold
Instance.new("UICorner",remBtn).CornerRadius=UDim.new(0,4)

addBtn2.MouseButton1Click:Connect(function()
    local name=addBox.Text:match("^%s*(.-)%s*$")
    if name=="" then return end
    if IsWhitelisted(name) then addBox.Text=""; return end
    table.insert(whitelist, name); SaveWhitelist(); RefreshWLDisplay(); addBox.Text=""
    SetStatus("WL: added "..name, Color3.fromRGB(100,255,150))
end)

remBtn.MouseButton1Click:Connect(function()
    local name=addBox.Text:match("^%s*(.-)%s*$")
    if name=="" then
        -- remove last non-default entry
        if #whitelist>1 then
            local removed=table.remove(whitelist)
            SaveWhitelist(); RefreshWLDisplay()
            SetStatus("WL: removed "..removed, Color3.fromRGB(255,160,80))
        end
        return
    end
    -- remove by name, protect default
    if name:lower()=="54321_jaymes" then SetStatus("WL: cannot remove default", Color3.fromRGB(255,160,80)); return end
    for i,n in ipairs(whitelist) do
        if n:lower()==name:lower() then table.remove(whitelist,i); SaveWhitelist(); RefreshWLDisplay()
            SetStatus("WL: removed "..n, Color3.fromRGB(255,160,80)); addBox.Text=""; return end
    end
    SetStatus("WL: not found", Color3.fromRGB(255,80,80))
end)

Div(y); y+=8

ct.CanvasSize=UDim2.new(0,0,0,y+12)

-- ── Live updaters ────────────────────────────────────────────────
table.insert(inst.connections,RunSvc.Heartbeat:Connect(function()
    if inst.dead then return end; local ix,iy=GetTileIndex()
    posLbl.Text=(ix and iy) and ("Pos: X="..ix.."  Y="..iy) or "Pos: --" end))

task.spawn(function()
    local lSel=nil
    while not inst.dead do
        local found=false
        for _,slot in pairs(invScroll:GetChildren()) do
            if tonumber(slot.Name) then local hl=slot:FindFirstChild("SelectionHighlight")
                if hl and hl.Visible then found=true; lastSelSlot=slot
                    if lSel~=slot then lSel=slot; local k=GetSlotKey(slot); hlLbl.Text="Sel: "..(k and GetCode(k) or "?") end; break end end end
        if not found then lSel=nil; lastSelSlot=nil; hlLbl.Text="Selected: --" end
        task.wait(0.15) end end)

task.spawn(function()
    while not inst.dead do
        if CFG.plantItem then plantItemLbl.Text="Plant: "..CFG.plantItem.."  x"..GetTotalByCode(CFG.plantItem) end
        if CFG.breakItem then breakItemLbl.Text="Break: "..CFG.breakItem.."  x"..GetTotalByCode(CFG.breakItem) end
        task.wait(0.5) end end)

-- ── Safe Mode: player join monitor ──────────────────────────────
table.insert(inst.connections, Players.PlayerAdded:Connect(function(plr)
    if plr==player then return end
    if IsWhitelisted(plr.Name) then return end
    if safeAutoStop then
        isRunning=false; stopAll()
        SetStatus("SAFE STOP: "..plr.Name.." joined", Color3.fromRGB(255,200,60))
    end
    if safeAutoLeave then
        SetStatus("LEAVING: "..plr.Name.." joined", Color3.fromRGB(255,100,80))
        task.wait(0.2)
        -- Try Kick first, then TeleportService as fallback
        local kicked = false
        pcall(function() player:Kick("RotFarm Safe Mode: "..plr.Name.." joined"); kicked=true end)
        if not kicked then
            pcall(function()
                game:GetService("TeleportService"):Teleport(game.PlaceId, player)
            end)
        end
    end
end))

xBtn.MouseButton1Click:Connect(function()
    isRunning=false; inst.dead=true; stopAll(); stopWatching()
    for _,c in pairs(inst.connections) do pcall(function() c:Disconnect() end) end
    _G.RotFarmV3=nil; sg:Destroy() end)

table.insert(inst.connections,player.CharacterRemoving:Connect(function() stopAll() end))
print("[RotFarm v3.0] Ready.")
