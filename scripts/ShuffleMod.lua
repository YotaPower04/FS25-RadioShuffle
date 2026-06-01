ShuffleMod = {}
ShuffleMod.enabled       = false
ShuffleMod.playlist      = {}
ShuffleMod.position      = 1
ShuffleMod.knownTotal    = 0
ShuffleMod.eventId       = nil
ShuffleMod.lastItem      = nil
ShuffleMod.suppress      = 0
ShuffleMod.preloading    = false
ShuffleMod.preloadOrig   = 0
ShuffleMod.preloadSteps  = 0
ShuffleMod.preloadTimer  = 0
ShuffleMod.nextFunc      = nil

local function notify(text)
    if g_currentMission == nil then return end
    pcall(function()
        if g_currentMission.hud and g_currentMission.hud.sideNotification then
            g_currentMission.hud.sideNotification:addNotification(text, {0.18, 0.78, 0.24, 1}, 3000)
        end
    end)
end

local function getTotal(sp)
    local map = sp.channelItemMapping
    if map == nil then return 0 end
    local n = map[sp.currentChannel or 0]
    return type(n) == "number" and n or 0
end

local function getNext(sp)
    local cls = (getmetatable(sp) or {}).__index or sp
    return cls.nextItem or cls.nextChannel or cls.nextSong
end

local function shuffle(t, from)
    from = from or 1
    for i = #t, from + 1, -1 do
        local j = math.random(from, i)
        t[i], t[j] = t[j], t[i]
    end
end

local function jump(sp, target, total, fn)
    if fn == nil then return end
    sp.currentItem = target - 1
    if sp.currentItem < 1 then sp.currentItem = total end
    fn(sp)
end

function ShuffleMod:build()
    local sp    = g_soundPlayer
    local total = getTotal(sp)
    local cur   = sp.currentItem or 1
    if total < 2 then return end
    local t = {cur}
    for i = 1, total do if i ~= cur then t[#t+1] = i end end
    shuffle(t, 2)
    self.playlist   = t
    self.position   = 1
    self.knownTotal = total
    self.lastItem   = cur
end

function ShuffleMod:expand(newTotal)
    local new = {}
    for i = self.knownTotal + 1, newTotal do new[#new+1] = i end
    shuffle(new)
    for _, v in ipairs(new) do
        local at = math.random(self.position + 1, #self.playlist + 1)
        table.insert(self.playlist, at, v)
    end
    self.knownTotal = newTotal
end

function ShuffleMod:onToggle()
    local sp = g_soundPlayer
    if sp == nil then return end
    self.enabled = not self.enabled
    if not self.enabled then notify(g_i18n:getText("shuffle_off")); return end

    local fn = getNext(sp)
    if fn == nil or getTotal(sp) < 2 then
        self.enabled = false
        notify("Skip a few songs first")
        return
    end

    self.nextFunc     = fn
    self.preloading   = true
    self.preloadOrig  = sp.currentItem or 1
    self.preloadSteps = 0
    self.preloadTimer = 0
    notify("Scanning for all songs...")
end

function ShuffleMod.onRegisterActions()
    if g_inputBinding == nil then return end
    local ok, id = g_inputBinding:registerActionEvent(
        InputAction.RADIO_SHUFFLE_TOGGLE, ShuffleMod, ShuffleMod.onToggle,
        false, true, false, true)
    if ok then
        ShuffleMod.eventId = id
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_LOW)
        g_inputBinding:setActionEventText(id, g_i18n:getText("action_toggle_shuffle"))
    end
end

function ShuffleMod:loadMap()
    if PlayerInputComponent and PlayerInputComponent.registerGlobalPlayerActionEvents then
        PlayerInputComponent.registerGlobalPlayerActionEvents =
            Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents, ShuffleMod.onRegisterActions)
    end
end

function ShuffleMod:update(dt)
    local sp = g_soundPlayer
    if sp == nil then return end

    if self.preloading then
        self.preloadTimer = self.preloadTimer + dt
        if self.preloadTimer >= 0.05 then
            self.preloadTimer = 0
            self.preloadSteps = self.preloadSteps + 1
            if self.preloadSteps >= 600 then
                jump(sp, self.preloadOrig, getTotal(sp), self.nextFunc)
                self.preloading = false
                self:build()
                notify(#self.playlist > 0
                    and string.format("Loaded %d songs - Shuffle ON", self.knownTotal)
                    or  "Failed to load playlist")
                if #self.playlist == 0 then self.enabled = false end
                return
            end
            self.nextFunc(sp)
        end
        return
    end

    if not self.enabled or #self.playlist == 0 then return end

    local total = getTotal(sp)
    if total > self.knownTotal then self:expand(total) end

    if self.suppress > 0 then
        self.suppress = self.suppress - 1
        self.lastItem = sp.currentItem
        return
    end

    local cur = sp.currentItem
    if cur == nil then return end

    if self.lastItem ~= nil and cur ~= self.lastItem then
        self.position = (self.position % #self.playlist) + 1
        local target  = self.playlist[self.position]
        self.suppress = 20
        self.lastItem = target
        jump(sp, target, self.knownTotal, self.nextFunc or getNext(sp))
        return
    end

    self.lastItem = cur
end

function ShuffleMod:deleteMap()
    if self.eventId ~= nil and g_inputBinding ~= nil then
        g_inputBinding:removeActionEvent(self.eventId)
        self.eventId = nil
    end
    self.enabled     = false
    self.playlist    = {}
    self.lastItem    = nil
    self.suppress    = 0
    self.knownTotal  = 0
    self.preloading  = false
    self.nextFunc    = nil
end

addModEventListener(ShuffleMod)
