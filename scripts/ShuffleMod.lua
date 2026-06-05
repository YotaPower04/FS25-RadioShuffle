-- ShuffleMod v2.2
-- Radio shuffle + per-vehicle radio state + outside-vehicle distance fade + volume hotkeys.

ShuffleMod = {}

-- ── Shuffle ──────────────────────────────────────────────────────────────────
ShuffleMod.enabled      = false
ShuffleMod.playlist     = {}
ShuffleMod.position     = 1
ShuffleMod.knownTotal   = 0
ShuffleMod.nextFunc     = nil
ShuffleMod.lastItem     = nil
ShuffleMod.suppress     = 0

-- Song table (filesystem scan at loadMap)
ShuffleMod.songTable    = {}
ShuffleMod.songCount    = 0
ShuffleMod.musicPath    = nil

-- ── Radio / Volume ────────────────────────────────────────────────────────────
ShuffleMod.radioGroupIdx  = nil
ShuffleMod.soundMixer     = nil
ShuffleMod.baseVolume     = nil
ShuffleMod.rangeFactor    = 1
ShuffleMod.volumeStep     = 0.10

-- ── Vehicle state ─────────────────────────────────────────────────────────────
ShuffleMod.vehicleStates  = {}     -- vehicle → { radioOn }  (volume is global)
ShuffleMod.lastVehicle    = nil
ShuffleMod.pendingStates  = {}

-- ── Distance fading ───────────────────────────────────────────────────────────
ShuffleMod.fadeDistance   = 16.5
ShuffleMod.outsideFactor  = 0.30
ShuffleMod.currentFactor  = 1
ShuffleMod.fadeUpSpeed    = 8.0
ShuffleMod.fadeDownSpeed  = 2.0
ShuffleMod.nearMode       = nil    -- true while keeping a nearby radio audible on foot
ShuffleMod.origVehicleOnly = nil   -- saved game settings, restored on unload
ShuffleMod.origRadioActive = nil
ShuffleMod.origRadioVolume = nil

-- ── Timing / input ──────────────────────────────────────────────────────────────
ShuffleMod.updateTimer    = 0
ShuffleMod.updateInterval = 50
ShuffleMod.eventId        = nil
ShuffleMod.guiWasVisible  = false

-- ── Volume HUD bar (self-managed, replaces instead of stacking) ─────────────────
ShuffleMod.hudMsgVolume   = 0
ShuffleMod.hudMsgTimer    = 0
ShuffleMod.hudMsgDuration = 2000   -- ms
ShuffleMod.barOverlay     = nil

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

-- Center-screen transient message (the one that pops up and fades)
local function notify(text)
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        pcall(function() g_currentMission:showBlinkingWarning(text, 3000) end)
    end
end

local function clamp(v) return math.max(0, math.min(v or 0, 1)) end

local function setSettingIfDiff(name, value)
    if g_gameSettings ~= nil and g_gameSettings:getValue(name) ~= value then
        g_gameSettings:setValue(name, value)
    end
end

-- Path to a file in the user's modSettings folder (created if needed)
local function modSettingsPath(filename)
    if getUserProfileAppPath == nil then return nil end
    local p = getUserProfileAppPath()
    if p == nil or p == "" then return nil end
    if createFolder ~= nil then pcall(createFolder, p .. "modSettings/") end
    return p .. "modSettings/" .. filename
end

local function getNext(sp)
    local cls = (getmetatable(sp) or {}).__index or sp
    return cls.nextItem or cls.nextChannel or cls.nextSong
end

local function shuffleList(t, from)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Volume pipeline (distance fade applied as a mixer *factor*, not absolute volume)
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:refreshAudioRefs()
    if self.radioGroupIdx == nil then
        self.radioGroupIdx = AudioGroup.getAudioGroupIndexByName("RADIO")
    end
    if self.soundMixer == nil then
        if g_soundManager ~= nil and g_soundManager.soundMixer ~= nil then
            self.soundMixer = g_soundManager.soundMixer
        elseif g_currentMission ~= nil and g_currentMission.soundMixer ~= nil then
            self.soundMixer = g_currentMission.soundMixer
        end
    end
end

-- The game's SoundMixer owns the RADIO group's absolute volume — it re-applies
-- it per game state (e.g. ducking during the pause menu, with fades). So we do
-- NOT set the group volume directly (that fights the mixer and loses on every
-- menu open/close). Instead we set the mixer *factor*, which the mixer multiplies
-- on top of its state volume: it composes with the pause duck and restores
-- automatically when the menu closes, and takes effect live.
-- The game's radioVolume setting is pinned to full (see pinRadioVolume) so our
-- factor (baseVolume × distance) is the single source of truth for loudness.
function ShuffleMod:applyRadioOutput()
    self:refreshAudioRefs()
    if self.radioGroupIdx == nil then return end
    local factor = clamp(clamp(self.baseVolume or 0.5) * clamp(self.rangeFactor))
    if self.soundMixer ~= nil and self.soundMixer.setAudioGroupVolumeFactor ~= nil then
        self.soundMixer:setAudioGroupVolumeFactor(self.radioGroupIdx, factor)
    else
        setAudioGroupVolume(self.radioGroupIdx, factor)   -- fallback if no mixer
    end
end

-- Keep the game's radio volume slider at full so it doesn't scale on top of our
-- factor (we are the volume control now).
function ShuffleMod:pinRadioVolume()
    setSettingIfDiff("radioVolume", 1.0)
end

function ShuffleMod:setVolume(vol)
    self.baseVolume = math.floor(clamp(vol) * 100 + 0.5) / 100
    self:applyRadioOutput()
    self:showVolumeMessage(self.baseVolume)
end

-- Self-managed volume HUD bar: overwrites a single state, so rapid presses
-- replace the bar in place instead of stacking notifications.
function ShuffleMod:showVolumeMessage(vol)
    self.hudMsgVolume = clamp(vol)
    self.hudMsgTimer  = self.hudMsgDuration
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-vehicle radio state
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:ensureState(vehicle)
    if vehicle == nil then return nil end
    if self.vehicleStates[vehicle] == nil then
        -- A freshly-seen vehicle inherits the current radio on/off state, so
        -- entering it never forces the radio off / restarts the song.
        self.vehicleStates[vehicle] = {
            radioOn = g_gameSettings:getValue("radioIsActive") == true
        }
    end
    return self.vehicleStates[vehicle]
end

function ShuffleMod:saveVehicle(vehicle)
    if vehicle == nil then return end
    local state = self:ensureState(vehicle)
    state.radioOn = g_gameSettings:getValue("radioIsActive") == true
end

function ShuffleMod:restoreVehicle(vehicle)
    if vehicle == nil then return end
    local state = self:ensureState(vehicle)

    -- Per-vehicle radio ON/OFF only. Volume is global (never changed on a switch).
    -- Toggling radioIsActive restarts the song, so skip it when it already matches.
    local currentActive = g_gameSettings:getValue("radioIsActive") == true
    if state.radioOn ~= currentActive then
        g_gameSettings:setValue("radioIsActive", state.radioOn)
        self.suppress = 4
    end
end

function ShuffleMod:onVehicleSwitch(oldVehicle, newVehicle)
    self:saveVehicle(oldVehicle)
    self:restoreVehicle(newVehicle)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Distance fading
-- ─────────────────────────────────────────────────────────────────────────────

-- "Near mode" flips the game's radioVehicleOnly setting. With it OFF, the game
-- keeps the radio playing after you leave the vehicle — which is the only way
-- there is any audio outside to fade. Restored on unload (see deleteMap).
function ShuffleMod:setNearMode(enabled)
    if self.nearMode == enabled then return end
    self.nearMode = enabled
    setSettingIfDiff("radioVehicleOnly", not enabled)
end

function ShuffleMod:getNearestRadioVehicle()
    if g_localPlayer == nil or g_localPlayer.rootNode == nil or not entityExists(g_localPlayer.rootNode) then
        return nil, math.huge
    end
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local nearest, nearestDist = nil, math.huge
    for vehicle, state in pairs(self.vehicleStates) do
        if state.radioOn and vehicle.rootNode ~= nil and entityExists(vehicle.rootNode) then
            local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
            local dist = MathUtil.vector3Length(px - vx, py - vy, pz - vz)
            if dist < nearestDist then nearestDist = dist; nearest = vehicle end
        end
    end
    return nearest, nearestDist
end

function ShuffleMod:updateDistanceFade(dt)
    local nearest, dist = self:getNearestRadioVehicle()

    local target = 0
    if nearest ~= nil then
        local effective = math.max(0, dist - 1.5)
        if effective < self.fadeDistance then
            target = clamp(self.outsideFactor * (1 - effective / self.fadeDistance))
        end
    end

    if target > 0 then
        -- A running radio is within earshot: keep it playing. Volume stays the
        -- global value; only the distance *factor* below scales what you hear.
        self:setNearMode(true)
        setSettingIfDiff("radioIsActive", true)
    else
        -- Out of range / nothing playing: let the game stop the radio normally
        self:setNearMode(false)
    end

    local speed = target > self.currentFactor and self.fadeUpSpeed or self.fadeDownSpeed
    local step  = speed * (dt / 1000)

    if math.abs(target - self.currentFactor) <= step then
        self.currentFactor = target
    elseif target > self.currentFactor then
        self.currentFactor = self.currentFactor + step
    else
        self.currentFactor = self.currentFactor - step
    end

    self.rangeFactor = clamp(self.currentFactor)
    self:applyRadioOutput()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Song table
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:buildSongTable()
    self.songTable = {}
    self.songCount = 0
    if self.musicPath == nil or Files == nil then return end

    local ok, files = pcall(Files.getFilesRecursive, self.musicPath)
    if not ok or files == nil then return end

    table.sort(files, function(a, b) return a.path < b.path end)

    for _, f in ipairs(files) do
        if not f.isDirectory then
            local name = (f.filename or f.path or ""):lower()
            if name:sub(-4) == ".mp3" then
                self.songCount = self.songCount + 1
                self.songTable[self.songCount] = f.path
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Shuffle
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:getTotal(sp)
    if self.songCount > 0 then return self.songCount end
    local map = sp.channelItemMapping
    if map == nil then return 0 end
    local n = map[sp.currentChannel or 0]
    return type(n) == "number" and n or 0
end

function ShuffleMod:build()
    local sp = g_soundPlayer
    if sp == nil then return end
    local total = self:getTotal(sp)
    local cur   = sp.currentItem or 1
    if total < 2 then return end

    local t = {cur}
    for i = 1, total do if i ~= cur then t[#t+1] = i end end
    shuffleList(t, 2)

    self.playlist   = t
    self.position   = 1
    self.knownTotal = total
    self.lastItem   = cur
end

function ShuffleMod:expand(newTotal)
    local new = {}
    for i = self.knownTotal + 1, newTotal do new[#new+1] = i end
    shuffleList(new)
    for _, v in ipairs(new) do
        local at = math.random(self.position + 1, #self.playlist + 1)
        table.insert(self.playlist, at, v)
    end
    self.knownTotal = newTotal
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Action callbacks
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:onToggle()
    local sp = g_soundPlayer
    if sp == nil then return end

    self.enabled = not self.enabled

    if not self.enabled then
        notify(g_i18n:getText("shuffle_off"))
        return
    end

    self.nextFunc = getNext(sp)
    if self.nextFunc == nil then
        self.enabled = false
        notify("Radio not ready")
        return
    end

    self:build()

    if #self.playlist == 0 then
        self.enabled = false
        notify("No songs found")
        return
    end

    local count = self.songCount > 0 and self.songCount or self.knownTotal
    notify(string.format("%s (%d %s)", g_i18n:getText("shuffle_on"), count, g_i18n:getText("songs_found")))
end

local function adjustVolume(vehicle, delta)
    local cur = ShuffleMod.baseVolume or g_gameSettings:getValue("radioVolume") or 0.5
    ShuffleMod:setVolume(cur + delta)   -- global volume; vehicle arg unused
end

function ShuffleMod.onVolumeUp(vehicle)   adjustVolume(vehicle,  ShuffleMod.volumeStep) end
function ShuffleMod.onVolumeDown(vehicle) adjustVolume(vehicle, -ShuffleMod.volumeStep) end

-- ─────────────────────────────────────────────────────────────────────────────
-- Action registration
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod.onRegisterShuffleAction()
    if g_inputBinding == nil then return end
    local ok, id = g_inputBinding:registerActionEvent(
        InputAction.RADIO_SHUFFLE_TOGGLE, ShuffleMod, ShuffleMod.onToggle,
        false, true, false, true)
    if ok then
        ShuffleMod.eventId = id
        g_inputBinding:setActionEventTextVisibility(id, false)
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_LOW)
        g_inputBinding:setActionEventText(id, g_i18n:getText("action_toggle_shuffle"))
    end
end

function ShuffleMod.onRegisterVehicleActions(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    if vehicle == nil or not vehicle.isClient then return end

    vehicle.spec_shuffleMod = vehicle.spec_shuffleMod or {}
    local spec = vehicle.spec_shuffleMod
    spec.actionEvents = spec.actionEvents or {}
    vehicle:clearActionEventsTable(spec.actionEvents)

    -- Stay registered while the player is seated, INCLUDING when an AI helper is
    -- driving. The base ENTER action does this via getIsActiveForInput(true, true)
    -- where the second arg (activeForAI) keeps it active during AI control.
    local entered = vehicle.getIsEntered == nil or vehicle:getIsEntered()
    local active  = vehicle.getIsActiveForInput == nil or vehicle:getIsActiveForInput(true, true)
    if not (entered and active) then return end

    local _, upId = vehicle:addActionEvent(spec.actionEvents, "RC_RADIO_VOLUME_UP",
        vehicle, ShuffleMod.onVolumeUp, false, true, false, true, nil)
    if upId then
        g_inputBinding:setActionEventTextVisibility(upId, false)
        -- HIGH priority so the LShift+number combo wins over the base game's
        -- number-key radio-channel selection (matches Radio Enhancements)
        g_inputBinding:setActionEventTextPriority(upId, GS_PRIO_HIGH)
    end

    local _, downId = vehicle:addActionEvent(spec.actionEvents, "RC_RADIO_VOLUME_DOWN",
        vehicle, ShuffleMod.onVolumeDown, false, true, false, true, nil)
    if downId then
        g_inputBinding:setActionEventTextVisibility(downId, false)
        g_inputBinding:setActionEventTextPriority(downId, GS_PRIO_HIGH)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Config (global settings: fade distance + outside volume, set via the menu)
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:getConfigPath()
    return modSettingsPath("ShuffleModConfig.xml")
end

function ShuffleMod:loadConfig()
    local path = self:getConfigPath()
    if path == nil or fileExists == nil or not fileExists(path) then return end
    local xml = loadXMLFile("ShuffleModConfig", path)
    if xml == nil or xml == 0 then return end
    local d = getXMLFloat(xml, "shuffleMod.fadeDistance")
    if d ~= nil then self.fadeDistance = math.max(1, d) end
    local f = getXMLFloat(xml, "shuffleMod.outsideFactor")
    if f ~= nil then self.outsideFactor = clamp(f) end
    delete(xml)
end

function ShuffleMod:saveConfig()
    local path = self:getConfigPath()
    if path == nil then return end
    local xml = createXMLFile("ShuffleModConfig", path, "shuffleMod")
    if xml == nil or xml == 0 then return end
    setXMLFloat(xml, "shuffleMod.fadeDistance", self.fadeDistance)
    setXMLFloat(xml, "shuffleMod.outsideFactor", self.outsideFactor)
    saveXMLFile(xml)
    delete(xml)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Savegame (per-vehicle radio state)
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:getSavePath()
    return modSettingsPath("ShuffleModVehicles.xml")
end

function ShuffleMod:loadVehicleStates()
    self.pendingStates = {}
    local path = self:getSavePath()
    if path == nil or fileExists == nil or not fileExists(path) then return end

    local xml = loadXMLFile("ShuffleModVehicles", path)
    if xml == nil or xml == 0 then return end

    local i = 0
    while true do
        local key = string.format("vehicles.vehicle(%d)", i)
        if not hasXMLProperty(xml, key) then break end
        local uid = getXMLString(xml, key .. "#uniqueId")
        if uid ~= nil and uid ~= "" then
            self.pendingStates[uid] = {
                radioOn = getXMLBool(xml, key .. "#radioOn") == true
            }
        end
        i = i + 1
    end
    delete(xml)
end

function ShuffleMod:saveVehicleStates(vehicles)
    local path = self:getSavePath()
    if path == nil then return end

    local xml = createXMLFile("ShuffleModVehicles", path, "vehicles")
    if xml == nil or xml == 0 then return end

    local idx = 0
    if vehicles ~= nil then
        for _, v in ipairs(vehicles) do
            if v ~= nil and v.getUniqueId ~= nil then
                local uid   = v:getUniqueId()
                local state = self.vehicleStates[v]
                if uid ~= nil and uid ~= "" and state ~= nil then
                    local key = string.format("vehicles.vehicle(%d)", idx)
                    setXMLString(xml, key .. "#uniqueId", uid)
                    setXMLBool(xml, key .. "#radioOn", state.radioOn == true)
                    idx = idx + 1
                end
            end
        end
    end

    saveXMLFile(xml)
    delete(xml)
end

function ShuffleMod:applyPendingStates()
    if g_currentMission == nil or g_currentMission.vehicles == nil then return end
    for _, v in ipairs(g_currentMission.vehicles) do
        if v ~= nil and v.getUniqueId ~= nil then
            local saved = self.pendingStates[v:getUniqueId()]
            if saved ~= nil then
                local state   = self:ensureState(v)
                state.radioOn = saved.radioOn
            end
        end
    end
    self.pendingStates = {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:loadMap()
    -- Music lives next to mods/ under the FS25 user profile dir — the same anchor
    -- we use for settings. Robust even when the mod is loaded from a ZIP.
    self.musicPath = nil
    if getUserProfileAppPath ~= nil then
        local p = getUserProfileAppPath()
        if p ~= nil and p ~= "" then
            self.musicPath = p .. "music/"
        end
    end

    self:buildSongTable()

    if PlayerInputComponent and PlayerInputComponent.registerGlobalPlayerActionEvents then
        PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
            PlayerInputComponent.registerGlobalPlayerActionEvents,
            ShuffleMod.onRegisterShuffleAction)
    end

    if Enterable and Enterable.onRegisterActionEvents then
        Enterable.onRegisterActionEvents = Utils.appendedFunction(
            Enterable.onRegisterActionEvents,
            ShuffleMod.onRegisterVehicleActions)
    end

    if VehicleSystem and VehicleSystem.saveToXML then
        VehicleSystem.saveToXML = Utils.appendedFunction(
            VehicleSystem.saveToXML,
            function(vs)
                ShuffleMod:saveVehicleStates(vs and vs.vehicles)
            end)
    end

    self:loadConfig()
    self:loadVehicleStates()
    -- Start at the player's current radio volume, then pin the slider to full so
    -- our factor is the single volume control (restored on unload).
    self.origRadioVolume = g_gameSettings:getValue("radioVolume") or 0.5
    self.baseVolume      = self.origRadioVolume

    -- Remember the player's radio settings so we can restore them on unload
    if g_gameSettings ~= nil then
        self.origVehicleOnly = g_gameSettings:getValue("radioVehicleOnly")
        self.origRadioActive = g_gameSettings:getValue("radioIsActive")
    end
    self:pinRadioVolume()
    self:applyRadioOutput()   -- set our factor now so there's no full-volume blip
    self.nearMode = nil
end

function ShuffleMod:update(dt)
    -- Volume bar fade timer (runs every frame, before any throttle/early-return)
    if self.hudMsgTimer > 0 then
        self.hudMsgTimer = math.max(0, self.hudMsgTimer - dt)
    end

    local sp = g_soundPlayer
    if sp == nil then return end

    self.updateTimer = self.updateTimer + dt
    if self.updateTimer < self.updateInterval then return end
    local elapsed    = self.updateTimer
    self.updateTimer = 0

    if next(self.pendingStates) ~= nil then
        self:applyPendingStates()
    end

    -- While a menu/GUI is open, do nothing: getCurrentVehicle can momentarily
    -- read nil there, which would otherwise trigger the distance fade or a
    -- spurious vehicle "switch" and move the volume. lastVehicle is left intact.
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        self.guiWasVisible = true
        return
    end
    -- A menu just closed: re-pin the slider (in case it was touched in settings)
    -- and re-assert our factor so the radio returns to the right level.
    if self.guiWasVisible then
        self.guiWasVisible = false
        self:pinRadioVolume()
        self:applyRadioOutput()
    end

    local currentVehicle = g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil
        and g_localPlayer:getCurrentVehicle() or nil

    if currentVehicle ~= self.lastVehicle then
        self:onVehicleSwitch(self.lastVehicle, currentVehicle)
        self.lastVehicle = currentVehicle
    end

    if currentVehicle ~= nil then
        -- Inside a vehicle: normal radio behavior, full volume (no distance fade)
        self:setNearMode(false)
        if self.rangeFactor ~= 1 then
            self.rangeFactor   = 1
            self.currentFactor = 1
            self:applyRadioOutput()
        end
        local state    = self:ensureState(currentVehicle)
        local radioNow = g_gameSettings:getValue("radioIsActive") == true
        if radioNow ~= state.radioOn then
            state.radioOn = radioNow
        end
    else
        self:updateDistanceFade(elapsed)
    end

    -- ── Shuffle ────────────────────────────────────────────────────────────
    if not self.enabled or #self.playlist == 0 then return end

    if self.songCount == 0 then
        local total = self:getTotal(sp)
        if total > self.knownTotal then self:expand(total) end
    end

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
        self.suppress = 3
        self.lastItem = target
        jump(sp, target, self.knownTotal, self.nextFunc or getNext(sp))
        return
    end

    self.lastItem = cur
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HUD: graphical volume bar (replaces in place; fades after a couple seconds)
-- ─────────────────────────────────────────────────────────────────────────────

function ShuffleMod:draw()
    if self.hudMsgTimer <= 0 then return end
    if self.barOverlay == nil then
        self.barOverlay = createImageOverlay("dataS/menu/base/graph_pixel.png")
    end
    if self.barOverlay == nil or self.barOverlay == 0 then return end

    local vol = clamp(self.hudMsgVolume)
    local barW, barH = 0.18, 0.011
    local barX = 0.5 - barW / 2
    local barY = 0.86

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    renderText(0.5, barY + 0.016, 0.018, string.format("Radio Volume  %d%%", math.floor(vol * 100 + 0.5)))
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)

    setOverlayColor(self.barOverlay, 0, 0, 0, 0.55)         -- track
    renderOverlay(self.barOverlay, barX, barY, barW, barH)
    setOverlayColor(self.barOverlay, 0.18, 0.78, 0.24, 1)   -- fill
    renderOverlay(self.barOverlay, barX, barY, barW * vol, barH)
end

function ShuffleMod:deleteMap()
    -- Restore the player's original radio settings and reset the mixer factor so
    -- the radio group isn't left scaled after the mod unloads.
    if g_gameSettings ~= nil then
        if self.origVehicleOnly ~= nil then setSettingIfDiff("radioVehicleOnly", self.origVehicleOnly) end
        if self.origRadioActive ~= nil then setSettingIfDiff("radioIsActive", self.origRadioActive) end
        if self.origRadioVolume ~= nil then setSettingIfDiff("radioVolume", self.origRadioVolume) end
    end
    self.rangeFactor   = 1
    self.currentFactor = 1
    self:refreshAudioRefs()
    if self.radioGroupIdx ~= nil and self.soundMixer ~= nil and self.soundMixer.setAudioGroupVolumeFactor ~= nil then
        self.soundMixer:setAudioGroupVolumeFactor(self.radioGroupIdx, 1)
    end

    if self.eventId ~= nil and g_inputBinding ~= nil then
        g_inputBinding:removeActionEvent(self.eventId)
        self.eventId = nil
    end
    self.enabled       = false
    self.playlist      = {}
    self.lastItem      = nil
    self.suppress      = 0
    self.knownTotal    = 0
    self.nextFunc      = nil
    self.vehicleStates = {}
    self.lastVehicle   = nil
    self.pendingStates = {}
    self.rangeFactor   = 1
    self.currentFactor = 1
    self.baseVolume    = nil
    self.radioGroupIdx = nil
    self.soundMixer    = nil
    self.updateTimer   = 0
    self.songTable     = {}
    self.songCount     = 0
    self.nearMode      = nil
    self.guiWasVisible = false

    self.hudMsgTimer   = 0
    if self.barOverlay ~= nil and self.barOverlay ~= 0 then
        delete(self.barOverlay)
    end
    self.barOverlay    = nil
end

addModEventListener(ShuffleMod)
