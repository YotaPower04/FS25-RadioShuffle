-- ShuffleModUI
-- Adds "Radio Fade Distance" and "Radio Outside Volume" sliders to the in-game
-- General Settings page, using the bundled UIHelper library (clones existing
-- base-game settings elements). Values persist via ShuffleMod:saveConfig().

ShuffleModUI = {}
ShuffleModUI.controls    = {}
ShuffleModUI.initialized = false

function ShuffleModUI.inject()
    if ShuffleModUI.initialized then return end
    if UIHelper == nil or g_gui == nil or InGameMenu == nil then return end

    local sc = g_gui.screenControllers[InGameMenu]
    local settingsPage = sc ~= nil and sc.pageSettings or nil
    if settingsPage == nil or settingsPage.generalSettingsLayout == nil then return end

    ShuffleModUI.initialized = true
    ShuffleModUI.controls    = {}

    local props = {
        { name = "fadeDistance",   min = 1, max = 50,  step = 0.5, unit = "m" },
        { name = "outsidePercent", min = 0, max = 100, step = 5,   unit = "%" },
    }

    local ok = pcall(function()
        UIHelper.createControlsDynamically(settingsPage, "shufflemod_section_title", ShuffleModUI, props, "shufflemod_")
        UIHelper.registerFocusControls(ShuffleModUI.controls)
    end)
    if not ok then return end

    ShuffleModUI.populate()
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
        InGameMenuSettingsFrame.onFrameOpen, ShuffleModUI.populate)
end

function ShuffleModUI.populate()
    if ShuffleMod == nil then return end
    if ShuffleModUI.fadeDistance ~= nil then
        UIHelper.setControlValue(ShuffleModUI.fadeDistance, ShuffleMod.fadeDistance or 16.5)
    end
    if ShuffleModUI.outsidePercent ~= nil then
        UIHelper.setControlValue(ShuffleModUI.outsidePercent,
            math.floor((ShuffleMod.outsideFactor or 0.30) * 100 + 0.5))
    end
end

function ShuffleModUI:on_fadeDistance_changed(newState)
    local v = UIHelper.getControlValue(self.fadeDistance, newState)
    if v ~= nil then
        ShuffleMod.fadeDistance = math.max(1, v)
        if ShuffleMod.saveConfig ~= nil then ShuffleMod:saveConfig() end
    end
end

function ShuffleModUI:on_outsidePercent_changed(newState)
    local v = UIHelper.getControlValue(self.outsidePercent, newState)
    if v ~= nil then
        ShuffleMod.outsideFactor = math.max(0, math.min(v / 100, 1))
        if ShuffleMod.saveConfig ~= nil then ShuffleMod:saveConfig() end
    end
end

BaseMission.loadMapFinished = Utils.appendedFunction(BaseMission.loadMapFinished, function()
    ShuffleModUI.inject()
end)
