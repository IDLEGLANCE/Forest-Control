-- Forest Control · Rayfield Gen2
-- Autofarm-Kern mit Area-Filter; Oberfläche ausschließlich über Sirius Gen2.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HIT_CONFIRM_TIMEOUT = 0.13
local POST_HIT_RECOVERY_FACTOR = 0.92
local HELLCHAIN_RECOVERY_FACTOR = POST_HIT_RECOVERY_FACTOR * 0.92
local SAW_SWAP_HEAT = 0.85
local SAW_RETURN_HEAT = 0.25
local TREE_DISTANCE = 2
local TREE_RETRY_AFTER = 5
local LOG_RETRY_AFTER = 2

local environment = getgenv and getgenv() or _G
local KEY = "__BambooTweenFarm"
local teleportState = environment.__ForestControlTeleportState
environment.__ForestControlTeleportState = nil
local previous = environment[KEY]
local previousConfig = type(previous) == "table"
    and type(previous.config) == "table" and table.clone(previous.config) or nil

if type(previous) == "table" then
    if type(previous.stop) == "function" then pcall(previous.stop) end
    previous.running = false
    previous.enabled = false
    if previous.tween then pcall(function() previous.tween:Cancel() end) end
end

type ThemeStudioHandle = {
    destroy: () -> (),
    [string]: any,
}

type PlayerControllerHandle = {
    destroy: () -> (),
    [string]: any,
}

type ConfigManagerHandle = {
    destroy: () -> (),
    [string]: any,
}

local state = {
    alive = true,
    enabled = false,
    running = false,
    revision = 0,
    tween = nil,
    worker = nil,
    collectWorker = nil,
    collectEnabled = false,
    sellEnabled = false,
    sellBusy = false,
    sellWorker = nil,
    sellJob = nil,
    cancelSell = function(_reason) return false end,
    requestSell = function(_mode) return false, "Verkaufsablauf wird initialisiert" end,
    window = nil,
    controls = {} :: { [string]: any },
    themeStudio = nil :: ThemeStudioHandle?,
    playerController = nil :: PlayerControllerHandle?,
    configManager = nil :: ConfigManagerHandle?,
    combat = nil :: { [string]: any }?,
    bossController = nil :: { [string]: any }?,
    abilityController = nil :: { [string]: any }?,
    treeCoordinator = nil :: { [string]: any }?,
    runController = nil :: { [string]: any }?,
    upgradeController = nil :: { [string]: any }?,
    runBusy = false,
    upgradeBusy = false,
    bossBusy = false,
    bossWorker = nil,
    configLoading = false,
    configPending = {} :: { [string]: any },
    pendingModes = {} :: { [string]: boolean },
}
environment[KEY] = state

local config = {
    Speed = 38,
    MaxChopDistance = 2.5,
    MinTweenTime = 0.08,
    MaxTweenTime = 30,
    CollectRadius = 12,
    CollectInterval = 0.15,
    CollectLogs = true,
    CollectGems = true,
    CollectShards = true,
    CurrencyCollectRadius = 16,
    FlySpeed = 60,
    WalkSpeed = 50,
    SellThreshold = 100,
    AutoDetectBackpackCapacity = false,
    ChainsawToolSwitch = true,
    AutoBoss = false,
    AutoUpgrade = false,
    AutoBuyFarmTools = true,
    AutoRavens = false,
    AutoHoard = false,
    AutoFinishRun = false,
    AutoRepeatRun = false,
    RunDestination = type(workspace:GetAttribute("RunMap")) == "string" and workspace:GetAttribute("RunMap") or "Forest",
    RunDifficulty = type(workspace:GetAttribute("RunDifficulty")) == "string" and workspace:GetAttribute("RunDifficulty") or "NORMAL",
    RunPeaceful = workspace:GetAttribute("RunPeaceful") == true,
}
if previousConfig then
    for key, default in pairs(config) do
        if type(previousConfig[key]) == type(default) then
            config[key] = previousConfig[key]
        end
    end
end
config.MaxChopDistance = math.max(TREE_DISTANCE, config.MaxChopDistance)
state.config = config

local status
local sellStatus
local lastSellStatus
local lastStatus
local syncing = false

local function isAlive()
    return state.alive and environment[KEY] == state
        and not (state.window and state.window.unloaded)
end

local function isGuardianFightActive()
    local active = workspace:GetAttribute("GuardianActive")
    return type(active) == "string" and active ~= ""
end

local function isRunTransitionIdle()
    local controller = state.runController
    return not state.runBusy and not state.upgradeBusy and not (controller and (controller.inLobby or controller.ended or controller.departing))
end

local function isRunning()
    return isAlive() and state.enabled and not state.bossBusy and not state.sellBusy and isRunTransitionIdle() and not state.configLoading
        and not isGuardianFightActive()
end

local function isBossRunning()
    return isAlive() and config.AutoBoss and not state.sellBusy and isRunTransitionIdle() and not state.configLoading
        and not (state.abilityController and state.abilityController.isFlying())
        and not (state.playerController and state.playerController.enabled and state.playerController.enabled.Fly)
end

local function cancelMovement()
    local tween = state.tween
    state.tween = nil
    if tween then pcall(function() tween:Cancel() end) end
end

local function setStatus(text)
    if isAlive() and status and text ~= lastStatus then
        lastStatus = text
        status:Set(text)
    end
end

local function setSellStatus(text)
    if isAlive() and sellStatus and text ~= lastSellStatus then
        lastSellStatus = text
        sellStatus:Set(text)
    end
end

function state.setAutoSell(enabled)
    if not isAlive() then return end
    if state.configLoading then
        state.pendingModes.SellEnabled = enabled == true
        return
    end
    state.sellEnabled = enabled == true
    local toggle = state.controls.AutoSell
    if toggle then
        local updated, message = pcall(toggle.Set, toggle, state.sellEnabled, true)
        if not updated then warn("[ForestControl Sell UI] " .. tostring(message)) end
    end
    if not state.sellEnabled and state.sellJob and state.sellJob.mode == "auto" and state.cancelSell then
        state.cancelSell("Auto-Sell ausgeschaltet · zurückgekehrt")
    end
    if not state.sellBusy then
        setSellStatus(state.sellEnabled and "Auto-Sell bereit" or "Auto-Sell aus · manueller Verkauf bereit")
    end
end

function state.setAutoCollect(enabled)
    if not isAlive() then return end
    if state.configLoading then
        state.pendingModes.CollectEnabled = enabled == true
        return
    end
    state.collectEnabled = enabled == true
    local toggle = state.controls.AutoCollect
    if toggle then
        syncing = true
        local updated, updateError = pcall(toggle.Set, toggle, state.collectEnabled, true)
        syncing = false
        if not updated then
            warn("[ForestControl Collect UI] " .. tostring(updateError))
        end
    end
end

function state.setEnabled(enabled)
    if not isAlive() then return end
    if state.configLoading then
        state.pendingModes.FarmEnabled = enabled == true
        return
    end
    if enabled and state.playerController then state.playerController.set("Fly", false) end
    state.enabled = enabled == true
    state.running = state.enabled
    state.revision = state.revision + 1
    cancelMovement()
    if not state.enabled and state.treeCoordinator then state.treeCoordinator.clear() end
    if not state.enabled and state.abilityController then state.abilityController.cancel() end
    if not state.enabled and state.combat then
        if state.combat.stopSaw then state.combat.stopSaw() end
        if state.combat.stopNative then state.combat.stopNative() end
        if state.combat.cancelSawSwap then state.combat.cancelSawSwap() end
    end

    local toggle = state.controls.Main
    if toggle then
        syncing = true
        local updated, updateError = pcall(toggle.Set, toggle, state.enabled, true)
        syncing = false
        if not updated then
            warn("[ForestControl Farm UI] " .. tostring(updateError))
        end
    end
    setStatus(state.enabled and "Suche nächsten Baum …" or "Pausiert · bereit zum Starten")
end

function state.stop()
    if not state.alive then return end
    if state.cancelSell then state.cancelSell("Beendet") end
    state.alive = false
    state.enabled = false
    state.collectEnabled = false
    state.sellEnabled = false
    state.running = false
    state.revision = state.revision + 1
    cancelMovement()

    if state.upgradeController then state.upgradeController.destroy() end
    if state.runController then state.runController.destroy() end
    if state.treeCoordinator then state.treeCoordinator.destroy() end
    if state.abilityController then state.abilityController.destroy() end
    if state.bossController then state.bossController.destroy() end
    if state.combat and state.combat.destroy then state.combat.destroy() end

    if state.configManager then
        state.configManager.destroy()
        state.configManager = nil
    end

    if state.playerController then
        state.playerController.destroy()
        state.playerController = nil
    end

    local worker = state.worker
    state.worker = nil
    if worker and worker ~= coroutine.running() and coroutine.status(worker) ~= "dead" then
        pcall(task.cancel, worker)
    end

    local bossWorker = state.bossWorker
    state.bossWorker = nil
    if bossWorker and bossWorker ~= coroutine.running() and coroutine.status(bossWorker) ~= "dead" then
        pcall(task.cancel, bossWorker)
    end

    local collectWorker = state.collectWorker
    state.collectWorker = nil
    if collectWorker and collectWorker ~= coroutine.running() and coroutine.status(collectWorker) ~= "dead" then
        pcall(task.cancel, collectWorker)
    end

    local sellWorker = state.sellWorker
    state.sellWorker = nil
    if sellWorker and sellWorker ~= coroutine.running() and coroutine.status(sellWorker) ~= "dead" then
        pcall(task.cancel, sellWorker)
    end

    if state.themeStudio then
        state.themeStudio.destroy()
        state.themeStudio = nil
    end

    local window = state.window
    state.window = nil
    if window and not window.unloaded then
        pcall(function() window:Unload() end)
    end
    table.clear(state.controls)
    if environment[KEY] == state then environment[KEY] = nil end
end
state.terminate = state.stop

local player = Players.LocalPlayer
if not player then
    state.stop()
    return
end

-- Einmaliger Übergang: eventuell verwaiste Kopien des früheren UI entfernen.
local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui")
if not isAlive() then return end
for _, child in ipairs(playerGui:GetChildren()) do
    if child.Name == "ForestControlUI" then child:Destroy() end
end

local descriptors = {
    { Key = "SellThreshold", Name = "Automatisch verkaufen ab Holzmenge", Description = "Anzahl getragener Stämme. Bei kleinerem Rucksack gilt dessen maximale Kapazität.", Min = 1, Integer = true, Tab = "Selling" },
    { Key = "FlySpeed", Name = "Flyspeed", Description = "Fluggeschwindigkeit in Studs pro Sekunde.", Min = 1, Max = 500, Tab = "Player" },
    { Key = "WalkSpeed", Name = "Walkspeed", Description = "Laufgeschwindigkeit bei aktiviertem Walkspeed-Toggle.", Min = 0, Max = 500, Tab = "Player" },
    { Key = "Speed", Name = "Tween-Speed", Description = "Bewegung in Studs pro Sekunde.", Min = 0.1, Tab = "Movement" },
    { Key = "MinTweenTime", Name = "Minimale Tween-Zeit", Description = "Untere Dauergrenze in Sekunden.", Min = 0.01, Tab = "Movement" },
    { Key = "MaxTweenTime", Name = "Maximale Tween-Zeit", Description = "Obere Dauergrenze in Sekunden.", Min = 0.01, Tab = "Movement" },
    { Key = "MaxChopDistance", Name = "Maximale Schlagdistanz", Description = "Vor jedem Schlag geprüfter Abstand in Studs.", Min = 0.1, Tab = "Chopping" },
    { Key = "CollectRadius", Name = "Sammelradius", Description = "Radius für den ersten Stamm; auf die Spielreichweite begrenzt. Grasp erfasst Nachbarstämme automatisch.", Min = 0.1, Tab = "Collection" },
    { Key = "CurrencyCollectRadius", Name = "Gems/Shards-Sammelradius", Description = "Radius in Studs, maximal 16 wie beim normalen Anklicken; mit kleinem Abstand zur Reichweitengrenze.", Min = 0.1, Max = 16, Tab = "Collection" },
    { Key = "CollectInterval", Name = "Sammelabstand", Description = "Sekunden zwischen Anfragen; mindestens 0,12.", Min = 0.12, Tab = "Collection" },
}
local descriptorByKey = {}
for _, descriptor in ipairs(descriptors) do
    descriptorByKey[descriptor.Key] = descriptor
end

local function format(value)
    return string.format("%.6g", value)
end

local function syncField(key)
    local handle = state.controls[key]
    if not handle then return end
    syncing = true
    handle:Set(format(config[key]), true)
    syncing = false
end

local function settingsChanged()
    state.revision = state.revision + 1
    cancelMovement()
    setStatus(state.enabled and "Einstellungen übernommen · suche Baum …" or "Einstellungen übernommen · pausiert")
end

function state.applySetting(key, text)
    if not isAlive() then return false, "UI beendet" end
    local descriptor = descriptorByKey[key]
    if not descriptor then return false, "Unbekanntes Feld" end
    local value = tonumber((tostring(text):gsub(",", ".")))
    if not value or value ~= value or math.abs(value) == math.huge then
        return false, "Eine gültige Zahl eingeben"
    end
    if value < descriptor.Min then return false, "Minimum: " .. format(descriptor.Min) end
    if descriptor.Max and value > descriptor.Max then return false, "Maximum: " .. format(descriptor.Max) end
    if descriptor.Integer and value % 1 ~= 0 then return false, "Eine ganze Zahl eingeben" end
    if key == "MinTweenTime" and value > config.MaxTweenTime then
        return false, "Minimale Zeit darf maximale Zeit nicht übersteigen"
    end
    if key == "MaxTweenTime" and value < config.MinTweenTime then
        return false, "Maximale Zeit darf minimale Zeit nicht unterschreiten"
    end
    if key == "MaxChopDistance" and value < TREE_DISTANCE then
        return false, "Schlagdistanz muss mindestens Abstand sein"
    end
    config[key] = value
    syncField(key)
    if descriptor.Tab ~= "Player" and descriptor.Tab ~= "Selling" then settingsChanged() end
    return true
end

local function commit(key, value)
    if syncing or not isAlive() then return end
    if state.configLoading then
        state.configPending[key] = value
        return
    end
    local ok, message = state.applySetting(key, value)
    if not ok then
        syncField(key)
        setStatus(message)
        state.window:Notify({ title = "Eingabe prüfen", content = message })
    end
end

local function syncSellCapacityUI()
    local field = state.controls.SellThreshold
    if not field then return end
    if config.AutoDetectBackpackCapacity then
        field:Lock("Die aktuelle Rucksackkapazität bestimmt die Verkaufsschwelle")
        if field.input:IsFocused() then field.input:ReleaseFocus() end
        field.main.Visible = false
    else
        field:Unlock()
        field.main.Visible = true
    end
end

local function commitBoolean(key, value)
    if syncing or not isAlive() then return end
    if state.configLoading then
        state.configPending[key] = value
    else
        config[key] = value
        if state.runController then state.runController.changed(key) end
        if state.upgradeController then state.upgradeController.changed(key) end
        if key == "AutoDetectBackpackCapacity" then syncSellCapacityUI() end
        if key == "AutoBoss" then
            if value and state.playerController then state.playerController.set("Fly", false) end
            if not value and state.bossController then state.bossController.stop() end
        end
        if key == "ChainsawToolSwitch" then
            if state.combat then
                state.combat.stopSaw()
                if state.combat.stopNative then state.combat.stopNative() end
                state.combat.cancelSawSwap()
            end
            settingsChanged()
        end
    end
end

-- Vollständiger Theme-Editor. Er verändert ausschließlich die Oberfläche.
local function createThemeStudio(window)
    local HttpService = game:GetService("HttpService")
    local BANK_KEY = "__ForestControlThemes_v1"
    local FILE = "ForestControl/Themes.json"
    local labels = { "Default", "Cobalt", "Ember", "Amethyst", "Frost", "Rose", "macOS" }
    local bases = {
        Default = "default", Cobalt = "cobalt", Ember = "ember",
        Amethyst = "amethyst", Frost = "frost", Rose = "rose", macOS = "macos",
    }
    local categories = {
        "Vorlagen & Speichern", "Akzent & Schrift", "Fenster", "Tabs",
        "Elemente", "Schalter & Slider", "Felder & Meldungen", "Formen & Transparenz",
    }
    local fontEnums = {
        ["Gotham"] = "Gotham", ["Gotham Medium"] = "GothamMedium",
        ["Gotham Fett"] = "GothamBold", ["Arial"] = "Arial",
        ["Roboto"] = "Roboto", ["Roboto Mono"] = "RobotoMono",
        ["Source Sans"] = "SourceSans", ["Builder Sans"] = "BuilderSans",
    }
    local fonts, fontOptions = {}, { "Gen2 (Standard)" }
    for name, enumName in pairs(fontEnums) do
        local ok, font = pcall(function() return Font.fromEnum(Enum.Font[enumName]) end)
        if ok then
            fonts[name] = font
            table.insert(fontOptions, name)
        end
    end
    table.sort(fontOptions)
    local specs = {
        { "AccentColor", "Akzentfarbe", "color", "Akzent & Schrift" },
        { "AccentStroke", "Akzentkontur", "color", "Akzent & Schrift" },
        { "ContentColor", "Textfarbe", "color", "Akzent & Schrift" },
        { "TitlingColor", "Fenstertitel", "color", "Akzent & Schrift" },
        { "ElementTextHoverColor", "Text beim Darüberfahren", "color", "Akzent & Schrift" },
        { "ActionColor", "Symbole in der Titelleiste", "color", "Akzent & Schrift" },
        { "Font", "Schrift für Inhalte", "font", "Akzent & Schrift" },
        { "TitleFont", "Schrift für Überschriften", "font", "Akzent & Schrift" },
        { "WindowColor", "Fensterverlauf", "gradient", "Fenster" },
        { "ShadowColor", "Fensterschatten", "color", "Fenster" },
        { "SurfaceStroke", "Feine Oberflächenkontur", "color", "Fenster" },
        { "LiveAnimation", "Animierter Fensterverlauf", "boolean", "Fenster" },
        { "TabColor", "Aktiver Tab: Text", "color", "Tabs" },
        { "TabBackground", "Aktiver Tab: Verlauf", "gradient", "Tabs" },
        { "TabStroke", "Aktiver Tab: Konturverlauf", "gradient", "Tabs" },
        { "ElementGradient", "Karten: Verlauf", "gradient", "Elemente", nil, nil, "ElementTransparency" },
        { "ElementStroke", "Karten: Kontur", "color", "Elemente", nil, nil, "ElementStrokeTransparency" },
        { "ElementStrokeGradient", "Karten: Konturverlauf", "gradient", "Elemente" },
        { "ElementStrokeHover", "Karten: Kontur beim Darüberfahren", "color", "Elemente", nil, nil, "ElementStrokeHoverTransparency" },
        { "StatBackground", "Statistik-Karten", "color", "Elemente" },
        { "SliderBackground", "Slider: Spur", "color", "Schalter & Slider" },
        { "SliderBackgroundHover", "Slider: Spur beim Darüberfahren", "color", "Schalter & Slider" },
        { "SliderProgress", "Slider: Füllverlauf", "gradient", "Schalter & Slider" },
        { "SliderStroke", "Slider: Kontur", "color", "Schalter & Slider" },
        { "SliderHandle", "Slider: Griff", "color", "Schalter & Slider" },
        { "ToggleTrack", "Schalter: Hintergrund", "color", "Schalter & Slider", nil, nil, "ToggleTrackTransparency" },
        { "ToggleKnobOff", "Schalter: Knopf im Aus-Zustand", "color", "Schalter & Slider", nil, nil, "ToggleKnobOffTransparency" },
        { "DarkToggleOverlay", "Dunkle Schalterüberlagerung", "boolean", "Schalter & Slider" },
        { "DropdownHighlight", "Auswahlmarkierung", "color", "Schalter & Slider" },
        { "FieldBackground", "Eingabefelder: Hintergrund", "color", "Felder & Meldungen", nil, nil, "FieldTransparency" },
        { "FieldGlow", "Eingabefelder: Leuchten", "color", "Felder & Meldungen" },
        { "PlaceholderColor", "Platzhaltertext", "color", "Felder & Meldungen" },
        { "NeutralButton", "Dialog-Buttons", "color", "Felder & Meldungen" },
        { "NeutralButtonHover", "Dialog-Buttons beim Darüberfahren", "color", "Felder & Meldungen" },
        { "NeutralButtonStroke", "Dialog-Buttons: Kontur", "color", "Felder & Meldungen" },
        { "ErrorColor", "Fehlerfarbe", "color", "Felder & Meldungen" },
        { "ErrorStrokeColor", "Fehlerkontur", "color", "Felder & Meldungen" },
        { "CornerRoundness", "Fensterrundung", "radius", "Formen & Transparenz", 0, 32 },
        { "PillCornerRadius", "Tab-Rundung · 32 = rund", "radius", "Formen & Transparenz", 0, 32 },
        { "ElementCornerRadius", "Kartenrundung", "radius", "Formen & Transparenz", 0, 32 },
        { "ElementTransparency", "Karten: Transparenz", "number", "Formen & Transparenz", 0, 1 },
        { "ElementStrokeTransparency", "Kartenkontur: Transparenz", "number", "Formen & Transparenz", 0, 1 },
        { "ElementStrokeHoverTransparency", "Hover-Kontur: Transparenz", "number", "Formen & Transparenz", 0, 1 },
        { "FieldTransparency", "Eingabefelder: Transparenz", "number", "Formen & Transparenz", 0, 1 },
        { "ToggleTrackTransparency", "Schalterspur: Transparenz", "number", "Formen & Transparenz", 0, 1 },
        { "ToggleKnobOffTransparency", "Schalterknopf: Transparenz", "number", "Formen & Transparenz", 0, 1 },
        { "AccentGlow", "Akzentleuchten · 1 = aus", "number", "Formen & Transparenz", 0, 1 },
    }
    local byKey = {}
    for _, spec in ipairs(specs) do byKey[spec[1]] = spec end
    local function clone(value)
        if type(value) ~= "table" then return value end
        local copy = {}
        for key, item in pairs(value) do copy[key] = clone(item) end
        return copy
    end
    local function hex(value)
        if typeof(value) == "Color3" then return "#" .. value:ToHex():upper() end
        if type(value) ~= "string" then error("Hex-Farbe erwartet") end
        local clean = value:gsub("^#", "")
        if #clean ~= 6 or not clean:match("^%x+$") then error("Farbe als #RRGGBB eingeben") end
        return "#" .. clean:upper()
    end
    local function color(value) return Color3.fromHex(hex(value)) end
    local function normalizeValue(spec, value)
        local kind = spec[3]
        if kind == "color" then return hex(value) end
        if kind == "gradient" then
            if type(value) ~= "table" then error("Zwei Verlaufsfarben erwartet") end
            return { first = hex(value.first), last = hex(value.last) }
        end
        if kind == "number" or kind == "radius" then
            if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge
                or value < spec[5] or value > spec[6] then
                error(spec[2] .. ": Wert außerhalb des Bereichs")
            end
            return value
        end
        if kind == "boolean" then
            if type(value) ~= "boolean" then error("Ein/Aus-Wert erwartet") end
            return value
        end
        if kind == "font" then
            if value ~= "Gen2 (Standard)" and not fonts[value] then error("Unbekannte Schrift") end
            return value
        end
        error("Unbekannte Theme-Eigenschaft")
    end
    local function validateRecord(record)
        if type(record) ~= "table" or record.version ~= 1
            or type(record.base) ~= "string" or type(record.overrides) ~= "table" then
            error("Kein gültiges Forest-Control-Theme")
        end
        local found = false
        for _, base in pairs(bases) do if record.base == base then found = true end end
        if not found then error("Unbekannte Theme-Vorlage") end
        local clean = { version = 1, base = record.base, overrides = {} }
        for key, value in pairs(record.overrides) do
            if not byKey[key] then error("Unbekannte Theme-Eigenschaft: " .. tostring(key)) end
            clean.overrides[key] = normalizeValue(byKey[key], value)
        end
        return clean
    end
    local function decode(key, value)
        local kind = byKey[key][3]
        if kind == "color" then return color(value) end
        if kind == "gradient" then return ColorSequence.new(color(value.first), color(value.last)) end
        if kind == "radius" then
            return key == "PillCornerRadius" and value == 32 and UDim.new(1, 0) or UDim.new(0, value)
        end
        if kind == "font" then return fonts[value] end
        return value
    end
    local macColors = {
        WindowColor = { first = "#F4F4F7", last = "#E8E9EF" },
        ShadowColor = "#A3A8B2", SurfaceStroke = "#FFFFFF",
        ContentColor = "#1D1D1F", TitlingColor = "#1D1D1F",
        ElementTextHoverColor = "#000000", ActionColor = "#63636B",
        TabColor = "#1D1D1F",
        TabBackground = { first = "#D5E8FF", last = "#C4DEFF" },
        TabStroke = { first = "#B7D2F5", last = "#ADCBEF" },
        ElementGradient = { first = "#FFFFFF", last = "#F8F9FC" },
        ElementStroke = "#D6D8DF",
        ElementStrokeGradient = { first = "#DFE1E7", last = "#D3D5DD" },
        ElementStrokeHover = "#B2BED0", StatBackground = "#FFFFFF",
        AccentColor = "#007AFF", AccentStroke = "#54A4FF",
        SliderBackground = "#D8DBE2", SliderBackgroundHover = "#C8CFD9",
        SliderProgress = { first = "#0784FF", last = "#0068E4" },
        SliderStroke = "#C8CFD9", SliderHandle = "#FFFFFF",
        ToggleTrack = "#D7DAE0", ToggleKnobOff = "#FFFFFF",
        DropdownHighlight = "#007AFF", FieldBackground = "#FFFFFF",
        FieldGlow = "#C9DFFD", PlaceholderColor = "#63636B",
        NeutralButton = "#F1F2F5", NeutralButtonHover = "#E5E7ED",
        NeutralButtonStroke = "#C8CBD4", ErrorColor = "#FF453A", ErrorStrokeColor = "#FF6961",
        CornerRoundness = 14, ElementCornerRadius = 8, PillCornerRadius = 8,
        LiveAnimation = false, DarkToggleOverlay = false,
        ElementTransparency = 0, ElementStrokeTransparency = 0.1,
        ElementStrokeHoverTransparency = 0, FieldTransparency = 0,
        ToggleTrackTransparency = 0, ToggleKnobOffTransparency = 0, AccentGlow = 0.85,
        Font = "Gotham", TitleFont = "Gotham Medium",
    }
    local function nativePatch(values)
        local native = {}
        for key, value in pairs(values) do
            local resolved = decode(key, value)
            if resolved ~= nil then native[key] = resolved end
        end
        return native
    end
    local bank = environment[BANK_KEY]
    if type(bank) ~= "table" or bank.version ~= 1 or type(bank.saved) ~= "table" then
        bank = { version = 1, saved = {} }
        if type(readfile) == "function" then
            local ok, text = pcall(readfile, FILE)
            if ok and type(text) == "string" and #text < 512000 then
                local decodedOk, data = pcall(HttpService.JSONDecode, HttpService, text)
                if decodedOk and type(data) == "table" and data.version == 1 and type(data.saved) == "table" then
                    for name, record in pairs(data.saved) do
                        if type(name) == "string" then
                            local valid, clean = pcall(validateRecord, record)
                            if valid then bank.saved[name] = clean end
                        end
                    end
                    if data.active then
                        local valid, clean = pcall(validateRecord, data.active)
                        if valid then bank.active = clean end
                    end
                    if type(data.name) == "string" then bank.name = data.name end
                end
            end
        end
        environment[BANK_KEY] = bank
    end
    local studio = {
        alive = true, controls = {}, history = {}, category = "Vorlagen & Speichern",
        name = bank.name or "Mein macOS Theme", selected = nil, json = "", tab = nil,
        renderTask = nil, syncing = false,
    }
    local activeOk, active = pcall(validateRecord, bank.active)
    studio.record = activeOk and active or { version = 1, base = "macos", overrides = {} }
    state.themeStudio = studio

    local render, syncVisible
    local function activeLabel()
        for label, base in pairs(bases) do if studio.record.base == base then return label end end
        return "Custom"
    end
    local function countEdits()
        local count = 0
        for _ in pairs(studio.record.overrides) do count = count + 1 end
        return count
    end
    local function remember()
        bank.active = clone(studio.record)
        bank.name = studio.name
    end
    local function notify(message)
        if isAlive() and studio.alive then
            window:Notify({ title = "Theme Studio", content = message })
        end
    end
    local function pushHistory()
        table.insert(studio.history, clone(studio.record))
        if #studio.history > 30 then table.remove(studio.history, 1) end
    end
    local function applyRecord(record, rememberHistory)
        local clean = validateRecord(record)
        if rememberHistory then pushHistory() end
        window:ChangeTheme(clean.base == "macos" and "default" or clean.base)
        if clean.base == "macos" then window:ChangeTheme(nativePatch(macColors)) end
        local patch = nativePatch(clean.overrides)
        if next(patch) then window:ChangeTheme(patch) end
        studio.record = clean
        remember()
        if syncVisible then syncVisible() end
    end
    local function resolved(key)
        return window.theme[key]
    end
    local function gradientEnds(key)
        local value = resolved(key)
        if typeof(value) == "ColorSequence" then
            return hex(value.Keypoints[1].Value), hex(value.Keypoints[#value.Keypoints].Value)
        end
        if typeof(value) == "Color3" then return hex(value), hex(value) end
        return "#FFFFFF", "#FFFFFF"
    end
    local function displayValue(spec)
        local key, kind = spec[1], spec[3]
        local value = resolved(key)
        if kind == "font" then return studio.record.overrides[key] or (studio.record.base == "macos" and macColors[key]) or "Gen2 (Standard)" end
        if kind == "radius" then
            return typeof(value) == "UDim" and (value.Scale > 0 and 32 or value.Offset) or 0
        end
        return value
    end
    local function protected(callback)
        return function(...)
            if not isAlive() or not studio.alive or studio.syncing then return end
            local ok, message = pcall(callback, ...)
            if not ok then
                local cleanedMessage = (tostring(message):gsub("^.-:%d+: ", ""))
                notify(cleanedMessage)
            end
        end
    end
    function studio.setValues(values)
        assert(isAlive() and studio.alive, "Theme Studio beendet")
        local clean = {}
        local restoreBase = false
        for key, value in pairs(values) do
            assert(byKey[key], "Unbekannte Theme-Eigenschaft")
            clean[key] = normalizeValue(byKey[key], value)
            if byKey[key][3] == "font" and value == "Gen2 (Standard)" then restoreBase = true end
        end
        pushHistory()
        for key, value in pairs(clean) do
            studio.record.overrides[key] = value
            if byKey[key][3] == "font" and value == "Gen2 (Standard)" then studio.record.overrides[key] = nil end
        end
        if restoreBase then
            applyRecord(studio.record, false)
        else
            window:ChangeTheme(nativePatch(clean))
            remember()
            if syncVisible then syncVisible() end
        end
        return true
    end
    function studio.setPreset(label)
        assert(bases[label], "Unbekannte Vorlage")
        applyRecord({ version = 1, base = bases[label], overrides = {} }, true)
        return true
    end
    function studio.undo()
        local previousRecord = table.remove(studio.history)
        if not previousRecord then return false, "Noch keine Änderung zum Zurücknehmen" end
        applyRecord(previousRecord, false)
        return true
    end
    function studio.resetSection()
        local nextRecord = clone(studio.record)
        for _, spec in ipairs(specs) do
            if spec[4] == studio.category then nextRecord.overrides[spec[1]] = nil end
        end
        applyRecord(nextRecord, true)
        return true
    end
    function studio.resetPreset()
        applyRecord({ version = 1, base = studio.record.base, overrides = {} }, true)
        return true
    end
    local function cleanName(name)
        assert(type(name) == "string", "Theme-Namen eingeben")
        name = name:match("^%s*(.-)%s*$")
        assert(#name > 0 and #name <= 80, "Theme-Namen mit 1 bis 80 Zeichen eingeben")
        return name
    end
    local function saveBank()
        if type(writefile) ~= "function" then return false, "Nur in dieser Spielsitzung gespeichert" end
        if type(makefolder) == "function" then pcall(makefolder, "ForestControl") end
        local ok = pcall(writefile, FILE, HttpService:JSONEncode({
            version = 1, saved = bank.saved, active = studio.record, name = studio.name,
        }))
        return ok, ok and "Lokal unter ForestControl/Themes.json gespeichert" or "Sitzung gespeichert; Datei konnte nicht geschrieben werden"
    end
    function studio.listSaved()
        local names = {}
        for name in pairs(bank.saved) do table.insert(names, name) end
        table.sort(names)
        return names
    end
    function studio.save(name, persist)
        studio.name = cleanName(name or studio.name)
        bank.saved[studio.name] = clone(studio.record)
        studio.selected = studio.name
        remember()
        local stored, message = false, "In dieser Spielsitzung gespeichert"
        if persist ~= false then stored, message = saveBank() end
        return true, message, stored
    end
    function studio.load(name)
        local record = bank.saved[name]
        assert(record, "Zuerst ein gespeichertes Theme auswählen")
        studio.name = name
        studio.selected = name
        applyRecord(record, true)
        return true
    end
    function studio.exportJSON()
        local record = clone(studio.record)
        record.name = studio.name
        return HttpService:JSONEncode(record)
    end
    function studio.importJSON(text)
        assert(type(text) == "string" and #text > 0 and #text <= 64000, "Theme-JSON mit höchstens 64 KB einfügen")
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, text)
        assert(ok, "Ungültiges JSON")
        local record = validateRecord(decoded)
        local importedName = decoded.name and cleanName(decoded.name) or studio.name
        applyRecord(record, true)
        studio.name = importedName
        remember()
        return true
    end
    local function scheduleRender()
        if studio.renderTask then pcall(task.cancel, studio.renderTask) end
        studio.renderTask = task.defer(function()
            studio.renderTask = nil
            if isAlive() and studio.alive then
                local ok, message = pcall(render)
                if not ok then notify("Editor konnte nicht angezeigt werden: " .. tostring(message)) end
            end
        end)
    end
    function studio.selectCategory(category)
        assert(table.find(categories, category), "Unbekannter Bereich")
        studio.category = category
        scheduleRender()
    end
    function studio.destroy()
        studio.alive = false
        if studio.renderTask and studio.renderTask ~= coroutine.running() then pcall(task.cancel, studio.renderTask) end
        studio.renderTask = nil
        studio.controls = {}
        studio.tab = nil
    end

    syncVisible = function()
        if not studio.alive then return end
        studio.syncing = true
        local controls = studio.controls
        if controls.Preset then controls.Preset:Set(activeLabel(), true) end
        if controls.Name then controls.Name:Set(studio.name, true) end
        if controls.Info then controls.Info:Set(activeLabel() .. " · " .. countEdits() .. " eigene Anpassungen · Änderungen sind sofort sichtbar.") end
        for _, spec in ipairs(specs) do
            local key, kind = spec[1], spec[3]
            if kind == "gradient" then
                local first, last = gradientEnds(key)
                if controls[key .. "_first"] then controls[key .. "_first"]:Set(color(first), true) end
                if controls[key .. "_last"] then controls[key .. "_last"]:Set(color(last), true) end
            elseif controls[key] then
                controls[key]:Set(displayValue(spec), true)
            end
            if spec[7] then
                local alpha = 1 - (tonumber(resolved(spec[7])) or 0)
                if controls[key] then controls[key]:SetAlpha(alpha, true) end
                if controls[key .. "_first"] then controls[key .. "_first"]:SetAlpha(alpha, true) end
                if controls[key .. "_last"] then controls[key .. "_last"]:SetAlpha(alpha, true) end
            end
        end
        studio.syncing = false
    end
    local function addPicker(tab, spec, endpoint)
        local key = spec[1]
        local first, last = gradientEnds(key)
        local value = endpoint and (endpoint == "first" and first or last) or resolved(key)
        local alpha = spec[7] and 1 - (tonumber(resolved(spec[7])) or 0) or 1
        local suffix = endpoint and (endpoint == "first" and " · Anfang" or " · Ende") or ""
        local id = key .. (endpoint and "_" .. endpoint or "")
        studio.controls[id] = tab:CreateColorPicker({
            name = spec[2] .. suffix,
            description = spec[7] and "Farbe und Deckkraft direkt anpassen." or "RGB oder Hex wählen; Transparenz separat im Bereich Formen.",
            color = value, alpha = alpha, forgetState = true,
            callback = protected(function(picked, opacity)
                local patch = {}
                if endpoint then
                    local from, to = gradientEnds(key)
                    patch[key] = { first = endpoint == "first" and hex(picked) or from, last = endpoint == "last" and hex(picked) or to }
                else
                    patch[key] = hex(picked)
                end
                if spec[7] then patch[spec[7]] = 1 - opacity end
                studio.setValues(patch)
            end),
        })
    end
    render = function()
        if not isAlive() or not studio.alive then return end
        studio.syncing = true
        if studio.tab then studio.tab:Remove() end
        studio.controls = {}
        local tab = window:CreateTab({ name = "Themes" })
        studio.tab = tab
        studio.controls.Preset = tab:CreateDropdown({
            name = "Basis-Preset", options = labels, value = activeLabel(), forgetState = true,
            description = "Vorlage auswählen oder unten einen Bereich bearbeiten.",
            callback = protected(function(value) studio.setPreset(value) end),
        })
        studio.controls.Category = tab:CreateDropdown({
            name = "Bearbeiten", options = categories, value = studio.category, forgetState = true,
            callback = protected(function(value) studio.selectCategory(value) end),
        })
        if studio.category == "Vorlagen & Speichern" then
            studio.controls.Info = tab:CreateText({ name = "Theme Studio", text = "" })
            studio.controls.Name = tab:CreateInput({
                name = "Name deines Themes", value = studio.name, forgetState = true,
                callback = protected(function(value)
                    studio.name = cleanName(value)
                    remember()
                end),
            })
            studio.controls.Saved = tab:CreateDropdown({
                name = "Gespeicherte Themes", options = studio.listSaved(), value = studio.selected,
                placeholder = "Noch kein Theme gewählt", forgetState = true,
                callback = protected(function(value) studio.selected = value end),
            })
            local row = tab:CreateGroup()
            row:CreateButton({
                name = "Theme speichern",
                description = "Lokal im Executor-Ordner ForestControl speichern.",
                callback = protected(function()
                    local _, message = studio.save(studio.name, true)
                    scheduleRender()
                    notify(message)
                end),
            })
            row:CreateButton({
                name = "Theme laden",
                callback = protected(function()
                    studio.load(studio.selected)
                    scheduleRender()
                end),
            })
            studio.controls.JSON = tab:CreateInput({
                name = "Theme als JSON", value = studio.json, placeholder = "JSON hier einfügen", forgetState = true,
                callback = protected(function(value) studio.json = value end),
            })
            local share = tab:CreateGroup()
            share:CreateButton({
                name = "JSON kopieren",
                callback = protected(function()
                    studio.json = studio.exportJSON()
                    studio.controls.JSON:Set(studio.json, true)
                    if type(setclipboard) == "function" then
                        setclipboard(studio.json)
                        notify("Theme-JSON kopiert")
                    else notify("Theme-JSON steht im Textfeld zum Kopieren") end
                end),
            })
            share:CreateButton({
                name = "JSON importieren",
                callback = protected(function()
                    studio.importJSON(studio.json)
                    scheduleRender()
                    notify("Theme importiert")
                end),
            })
        else
            tab:CreateSection({ name = studio.category })
            for _, spec in ipairs(specs) do
                if spec[4] == studio.category then
                    local key, kind = spec[1], spec[3]
                    if kind == "color" then addPicker(tab, spec)
                    elseif kind == "gradient" then
                        addPicker(tab, spec, "first")
                        addPicker(tab, spec, "last")
                    elseif kind == "font" then
                        studio.controls[key] = tab:CreateDropdown({
                            name = spec[2], options = fontOptions, value = displayValue(spec), forgetState = true,
                            callback = protected(function(value) studio.setValues({ [key] = value }) end),
                        })
                    elseif kind == "boolean" then
                        studio.controls[key] = tab:CreateToggle({
                            name = spec[2], value = displayValue(spec), forgetState = true,
                            callback = protected(function(value) studio.setValues({ [key] = value }) end),
                        })
                    else
                        studio.controls[key] = tab:CreateSlider({
                            name = spec[2], range = { spec[5], spec[6] }, increment = kind == "radius" and 1 or 0.01,
                            suffix = kind == "radius" and " px" or "", value = displayValue(spec), forgetState = true,
                            callback = protected(function(value) studio.setValues({ [key] = value }) end),
                        })
                    end
                end
            end
        end
        local actions = tab:CreateGroup()
        actions:CreateButton({
            name = "Rückgängig",
            callback = protected(function()
                local ok, message = studio.undo()
                if not ok then notify(message) end
            end),
        })
        if studio.category ~= "Vorlagen & Speichern" then
            actions:CreateButton({ name = "Bereich zurücksetzen", callback = protected(studio.resetSection) })
        end
        actions:CreateButton({ name = "Vorlage zurücksetzen", callback = protected(studio.resetPreset) })
        studio.syncing = false
        syncVisible()
        tab:Select(true)
    end
    applyRecord(studio.record, false)
    render()
    return studio
end

-- Schusshilfen verwenden nur die native Waffensteuerung; keine zusätzlichen Schussanfragen.
local function createGunAssist(getFlags)
    local manager = {
        alive = true, binding = nil :: { [string]: any }?, patches = {} :: { [number]: any },
        nextCheck = 0, status = "", error = nil :: string?, shot = nil :: { [string]: any }?,
        lastTarget = nil :: Instance?, heights = {} :: { [Instance]: number },
        stats = { shots = 0, redirected = 0 },
    }
    local names = { "Pistol", "Rifle", "Minigun" }
    local api = getfenv() :: any
    local inspect = api.getupvalues or (debug :: any).getupvalues
    local assign = api.setupvalue or (debug :: any).setupvalue
    local list = api.getrendersteppedlist
    local function enabled(key) return manager.alive and getFlags()[key] == true end
    local function report(text)
        if manager.status == text then return end
        manager.status = text
    end
    local function current(fn, index)
        return inspect(fn)[index]
    end
    local function findFunction(fn, name)
        for index, value in pairs(inspect(fn)) do
            if type(value) == "function" and debug.info(value, "n") == name then return value, index end
        end
        return nil, nil
    end
    local function patch(object, key, group)
        if type(object) ~= "table" or type(object[key]) ~= "number" then return end
        for _, saved in ipairs(manager.patches) do
            if saved.object == object and saved.key == key then
                if object[key] ~= 0 then saved.original = object[key] end
                object[key] = 0
                return
            end
        end
        table.insert(manager.patches, { object = object, key = key, original = object[key], group = group })
        object[key] = 0
    end
    local function restore(group)
        for index = #manager.patches, 1, -1 do
            local saved = manager.patches[index]
            if group == nil or saved.group == group then
                if saved.object[saved.key] == 0 then saved.object[saved.key] = saved.original end
                table.remove(manager.patches, index)
            end
        end
    end
    local function resetRecoil(recoil)
        if type(recoil) ~= "table" then return end
        for _, collection in ipairs({ recoil.AimKick, recoil.GunKick }) do
            if type(collection) == "table" then
                for _, spring in pairs(collection) do
                    if type(spring) == "table" then spring.X, spring.V = 0, 0 end
                end
            end
        end
        if type(recoil.AimClimb) == "table" then
            recoil.AimClimb.Pitch, recoil.AimClimb.Yaw = 0, 0
            recoil.AimClimb.PitchTo, recoil.AimClimb.YawTo = 0, 0
        end
        recoil.Shake = 0
        -- AimApplied/ShakeOn räumt der native Render-Schritt selbst auf.
    end
    function manager.detach()
        local binding = manager.binding
        manager.binding, manager.shot, manager.lastTarget = nil, nil, nil
        if binding and type(inspect) == "function" and type(assign) == "function" then
            if current(binding.render, binding.shootIndex) == binding.wrapper then
                assign(binding.render, binding.shootIndex, binding.shoot)
            end
            if current(binding.shoot, binding.probeIndex) == binding.probeWrapper then
                assign(binding.shoot, binding.probeIndex, binding.probe)
            end
        end
        restore(nil)
        table.clear(manager.heights)
    end
    function manager.destroy()
        manager.alive = false
        manager.detach()
    end
    function manager.selectTarget(gun)
        local binding = manager.binding
        local camera = workspace.CurrentCamera
        local character = player.Character
        local head = character and character:FindFirstChild("Head")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local spec = binding and binding.guns[gun]
        local folder = workspace:FindFirstChild("Monsters")
        if not camera or not head or not humanoid or humanoid.Health <= 0
            or player:GetAttribute("Down") == true or not spec or not folder then return nil, nil end
        local origin = head.Position
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local filter = { camera, folder }
        for _, who in ipairs(Players:GetPlayers()) do
            if who.Character then table.insert(filter, who.Character) end
        end
        for _, name in ipairs({ "Logs", "GunShells" }) do
            local object = workspace:FindFirstChild(name)
            if object then table.insert(filter, object) end
        end
        params.FilterDescendantsInstances = filter
        local viewport = camera.ViewportSize / 2
        local selected, point, best, nearest
        for _, model in ipairs(folder:GetChildren()) do
            if not model:IsA("Model") then continue end
            local kind = model:GetAttribute("Monster")
            if kind ~= "Minion" and kind ~= "Guardian" then continue end
            local hp = model:GetAttribute("HP")
            local stateName = model:GetAttribute("State")
            if type(hp) ~= "number" or hp <= 0 or model:GetAttribute("DeadAt")
                or model:GetAttribute("Hidden") == true or model:GetAttribute("Test") == true
                or stateName == "Dead" or stateName == "Underground" then continue end
            local from = model:GetAttribute("MoveFrom")
            local at = model:GetAttribute("MoveAt")
            local velocity = model:GetAttribute("MoveVel")
            local aim
            if typeof(from) == "Vector3" then
                local height = manager.heights[model]
                if not height then height = model:GetExtentsSize().Y; manager.heights[model] = height end
                aim = from + Vector3.new(0, height / 2 + (tonumber(model:GetAttribute("Hover")) or 0), 0)
                if typeof(velocity) == "Vector3" and type(at) == "number" then
                    aim = aim + velocity * math.max(0, workspace:GetServerTimeNow() - at
                        + math.clamp(player:GetNetworkPing(), 0, 0.1))
                end
            else
                local frame = model:GetBoundingBox()
                aim = frame.Position
            end
            local delta = aim - origin
            local distance = delta.Magnitude
            if distance < 0.01 or distance > spec.Range - 0.25 then continue end
            local screen, visible = camera:WorldToViewportPoint(aim)
            if not visible or screen.Z <= 0 then continue end
            local obstruction = workspace:Raycast(origin, delta, params)
            if obstruction and obstruction.Distance < distance - 0.5 then continue end
            local score = (Vector2.new(screen.X, screen.Y) - viewport).Magnitude
            if not best or score < best or math.abs(score - best) < 0.01 and distance < nearest then
                selected, point, best, nearest = model, aim, score, distance
            end
        end
        return selected, point
    end
    local function attach()
        if type(inspect) ~= "function" or type(assign) ~= "function" or type(list) ~= "function" then return false end
        local render
        for _, entry in pairs(list()) do
            if type(entry) == "table" and entry.Name == "NightGuns" and type(entry.Function) == "function" then
                render = entry.Function
                break
            end
        end
        if not render then return false end
        local shoot, shootIndex = findFunction(render, "shoot")
        if not shoot then return false end
        local probe, probeIndex = findFunction(shoot, "monsterOnRay")
        local kick = findFunction(shoot, "kickFor")
        if not probe or not kick then return false end
        local guns, tuning, recoil
        for _, value in pairs(inspect(shoot)) do
            if type(value) == "table" and type(value.Rifle) == "table" and type(value.Rifle.Rate) == "number" then guns = value end
        end
        for _, value in pairs(inspect(kick)) do
            if type(value) == "table" then
                if type(value.Rifle) == "table" and type(value.Rifle.Recoil) == "number" then tuning = value end
                if type(value.AimKick) == "table" and type(value.GunKick) == "table" then recoil = value end
            end
        end
        if not guns or not tuning or not recoil then return false end
        local binding = {
            render = render, shoot = shoot, shootIndex = shootIndex, probe = probe, probeIndex = probeIndex,
            guns = guns, tuning = tuning, recoil = recoil,
            wrapper = nil :: any, probeWrapper = nil :: any,
        }
        manager.binding = binding
        binding.probeWrapper = function(...)
            local shot = manager.shot
            if shot and shot.target and not shot.redirected and enabled("SilentAim") then
                shot.redirected = true
                return shot.target, shot.point
            end
            return probe(...)
        end
        binding.wrapper = function(gun, ...)
            if not manager.alive then return shoot(gun, ...) end
            manager.stats.shots = manager.stats.shots + 1
            local previous = manager.shot
            local target, aim
            if enabled("SilentAim") then target, aim = manager.selectTarget(gun) end
            local shot = { target = target, point = aim, redirected = false }
            manager.shot = shot
            local results = table.pack(pcall(shoot, gun, ...))
            manager.shot = previous
            manager.lastTarget = target
            if shot.redirected then manager.stats.redirected = manager.stats.redirected + 1 end
            if not results[1] then error(results[2], 0) end
            return table.unpack(results, 2, results.n)
        end
        assign(shoot, probeIndex, binding.probeWrapper)
        assign(render, shootIndex, binding.wrapper)
        return true
    end
    local function update()
        local flags = getFlags()
        if not flags.NoRecoil and not flags.NoSpread and not flags.SilentAim then
            manager.detach()
            report("Schusshilfen ausgeschaltet")
            return
        end
        local now = os.clock()
        if manager.binding and (current(manager.binding.render, manager.binding.shootIndex) ~= manager.binding.wrapper
            or current(manager.binding.shoot, manager.binding.probeIndex) ~= manager.binding.probeWrapper) then
            manager.detach()
        end
        if not manager.binding then
            if now < manager.nextCheck then return end
            manager.nextCheck = now + 1
            if not attach() then report("Warte auf Waffensteuerung …"); return end
        end
        local binding = manager.binding
        for _, name in ipairs(names) do
            local spec = binding.guns[name]
            if flags.NoSpread and spec then patch(spec, "Spread", "spread") end
            local tune = binding.tuning[name]
            if flags.NoRecoil and tune then
                for _, key in ipairs({ "Recoil", "RecoilYaw", "Shake" }) do patch(tune, key, "recoil") end
                for _, key in ipairs({ "Back", "Up", "Pitch", "Roll", "Yaw" }) do patch(tune.Kick, key, "recoil") end
            end
        end
        if not flags.NoSpread then restore("spread") end
        if not flags.NoRecoil then restore("recoil") else resetRecoil(binding.recoil) end
        for model in pairs(manager.heights) do if not model.Parent then manager.heights[model] = nil end end
        report("Schusshilfen bereit · Pistole / AK / Minigun")
    end
    function manager.step()
        if not manager.alive then return end
        local ok, message = pcall(update)
        if not ok then
            manager.detach()
            manager.nextCheck = os.clock() + 2
            report("Schusshilfen warten auf Waffensteuerung …")
            if manager.error ~= tostring(message) then
                manager.error = tostring(message)
                warn("[ForestControl Guns] " .. manager.error)
            end
        end
    end
    return manager
end

-- Player-Funktionen besitzen nur ihre eigenen Verbindungen und Physikobjekte.
local function createPlayerTab(window)
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local tab = window:CreateTab({ name = "Player" })
    local controller = {
        alive = true,
        enabled = { Fly = false, WalkSpeed = false, Noclip = false, NoRecoil = false, NoSpread = false, SilentAim = false },
        connections = {},
        collisions = setmetatable({}, { __mode = "k" }),
        flight = nil,
        walk = nil,
        character = nil,
        focused = true,
    }
    state.playerController = controller
    local gunAssist = createGunAssist(function() return controller.enabled end)
    controller.gunAssist = gunAssist
    local toggleNames = { Fly = "PlayerFly", WalkSpeed = "PlayerWalkSpeed", Noclip = "PlayerNoclip",
        NoRecoil = "PlayerNoRecoil", NoSpread = "PlayerNoSpread", SilentAim = "PlayerSilentAim" }

    local function syncToggle(feature)
        local handle = state.controls[toggleNames[feature]]
        if handle and isAlive() then
            local updated, message = pcall(handle.Set, handle, controller.enabled[feature], true)
            if not updated then warn("[ForestControl Player UI] " .. tostring(message)) end
        end
    end

    local function stopFlight()
        local flight = controller.flight
        controller.flight = nil
        if not flight then return end
        for _, object in ipairs(flight.objects) do pcall(function() object:Destroy() end) end
        pcall(function()
            flight.root.AssemblyLinearVelocity = Vector3.zero
            flight.root.AssemblyAngularVelocity = Vector3.zero
        end)
        pcall(function()
            flight.humanoid.AutoRotate = flight.autoRotate
            flight.humanoid.PlatformStand = flight.platformStand
            if flight.humanoid.Health > 0 and not flight.platformStand then
                flight.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end)
    end

    local function restoreWalk()
        local saved = controller.walk
        controller.walk = nil
        if saved then
            pcall(function()
                -- Einen bereits extern geänderten Wert nicht mit einem alten überschreiben.
                if saved.humanoid.WalkSpeed == saved.applied then
                    saved.humanoid.WalkSpeed = saved.original
                end
            end)
        end
    end

    local function restoreCollisions()
        for part, value in pairs(controller.collisions) do
            pcall(function() part.CanCollide = value end)
            controller.collisions[part] = nil
        end
    end

    function controller.set(feature, enabled)
        if not controller.alive or not isAlive() or controller.enabled[feature] == nil then return false end
        if state.configLoading then
            state.pendingModes["Player" .. feature] = enabled == true
            return true
        end
        enabled = enabled == true
        if feature == "Fly" and enabled and state.sellBusy then
            syncToggle(feature)
            return false
        end
        if feature == "Fly" and enabled and state.enabled then state.setEnabled(false) end
        controller.enabled[feature] = enabled
        if not enabled then
            if feature == "Fly" then stopFlight()
            elseif feature == "WalkSpeed" then restoreWalk()
            elseif feature == "Noclip" then restoreCollisions() end
        end
        if feature == "NoRecoil" or feature == "NoSpread" or feature == "SilentAim" then gunAssist.step() end
        syncToggle(feature)
        return true
    end

    function controller.destroy()
        if not controller.alive then return end
        controller.alive = false
        for _, connection in ipairs(controller.connections) do connection:Disconnect() end
        table.clear(controller.connections)
        for feature in pairs(controller.enabled) do
            controller.enabled[feature] = false
            syncToggle(feature)
        end
        stopFlight()
        restoreWalk()
        restoreCollisions()
        gunAssist.destroy()
        controller.character = nil
    end

    local function startFlight(root, humanoid)
        -- Sofort registrieren, damit auch ein teilweise aufgebauter Flug aufgeräumt wird.
        local flight = {
            root = root, humanoid = humanoid, objects = {},
            autoRotate = humanoid.AutoRotate, platformStand = humanoid.PlatformStand,
        }
        controller.flight = flight
        local attachment = Instance.new("Attachment")
        table.insert(flight.objects, attachment)
        attachment.Name = "ForestControlFlightAttachment"
        attachment.Parent = root
        local velocity = Instance.new("LinearVelocity")
        table.insert(flight.objects, velocity)
        velocity.Name = "ForestControlFlightVelocity"
        velocity.Attachment0 = attachment
        velocity.RelativeTo = Enum.ActuatorRelativeTo.World
        velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        velocity.ForceLimitsEnabled = false
        velocity.VectorVelocity = Vector3.zero
        velocity.Parent = root
        flight.velocity = velocity
        local orientation = Instance.new("AlignOrientation")
        table.insert(flight.objects, orientation)
        orientation.Name = "ForestControlFlightOrientation"
        orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
        orientation.Attachment0 = attachment
        orientation.MaxTorque = math.huge
        orientation.Responsiveness = 40
        orientation.CFrame = root.CFrame.Rotation
        orientation.Parent = root
        flight.orientation = orientation
        humanoid.AutoRotate = false
        humanoid.PlatformStand = true
        humanoid:ChangeState(Enum.HumanoidStateType.Physics)
        return flight
    end

    local function step()
        if state.configLoading then return end
        gunAssist.step()
        local character = player.Character
        if character ~= controller.character then
            stopFlight()
            restoreWalk()
            restoreCollisions()
            controller.character = character
        end
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
            stopFlight()
            restoreWalk()
            restoreCollisions()
            return
        end
        if controller.enabled.WalkSpeed then
            local saved = controller.walk
            if saved and saved.humanoid ~= humanoid then
                restoreWalk()
                saved = nil
            end
            if not saved then
                saved = { humanoid = humanoid, original = humanoid.WalkSpeed, applied = humanoid.WalkSpeed }
                controller.walk = saved
            elseif humanoid.WalkSpeed ~= saved.applied then
                -- Änderungen durch Spiel-Upgrades als neuen Rückkehrwert behalten.
                saved.original = humanoid.WalkSpeed
            end
            saved.applied = config.WalkSpeed
            if humanoid.WalkSpeed ~= saved.applied then humanoid.WalkSpeed = saved.applied end
        end
        if controller.enabled.Noclip then
            for _, part in ipairs(character:GetDescendants()) do
                if part:IsA("BasePart") then
                    if controller.collisions[part] == nil then controller.collisions[part] = part.CanCollide end
                    if part.CanCollide then part.CanCollide = false end
                end
            end
        end
        if controller.enabled.Fly then
            local flight = controller.flight
            if flight and (flight.root ~= root or flight.humanoid ~= humanoid) then
                stopFlight()
                flight = nil
            end
            if not flight then flight = startFlight(root, humanoid) end
            local camera = workspace.CurrentCamera
            local direction = Vector3.zero
            if camera then
                local frame = camera.CFrame
                local horizontal = Vector3.new(frame.LookVector.X, 0, frame.LookVector.Z)
                if horizontal.Magnitude > 0.001 then
                    flight.orientation.CFrame = CFrame.lookAt(Vector3.zero, horizontal)
                end
                local recording = window._recordingKeybind ~= nil
                if controller.focused and not recording and not UserInputService:GetFocusedTextBox() then
                    local function down(key) return UserInputService:IsKeyDown(key) and 1 or 0 end
                    direction = frame.LookVector * (down(Enum.KeyCode.W) - down(Enum.KeyCode.S))
                        + frame.RightVector * (down(Enum.KeyCode.D) - down(Enum.KeyCode.A))
                        + Vector3.yAxis * (down(Enum.KeyCode.Space) - down(Enum.KeyCode.LeftControl))
                end
            end
            if direction.Magnitude > 1 then direction = direction.Unit end
            flight.velocity.VectorVelocity = direction * config.FlySpeed
            humanoid.AutoRotate = false
            humanoid.PlatformStand = true
        end
    end
    controller.step = step

    tab:CreateText({
        name = "Player-Funktionen & Keybinds",
        text = "Ohne geladene Config starten Funktionen ausgeschaltet und Keybinds unbelegt. Taste anklicken und belegen; Backspace löscht die Belegung. Noclip aus = Clip.",
    })
    local features = {
        { key = "Fly", name = "Fly", keybind = true, speed = "FlySpeed", hint = "WASD folgt der Kamera · Leertaste hoch · linke Strg runter. Pausiert den Autofarm." },
        { key = "WalkSpeed", name = "Walkspeed", keybind = true, speed = "WalkSpeed", hint = "Eigenen Laufwert einschalten; beim Ausschalten gilt wieder der Spielwert." },
        { key = "Noclip", name = "Noclip / Clip", keybind = true, hint = "Ein: durch Hindernisse bewegen. Aus: ursprüngliche Kollision der Charakterteile wiederherstellen." },
        { key = "NoRecoil", name = "No Recoil", hint = "Entfernt den lokalen Waffenrückstoß bei Pistole, AK und Minigun." },
        { key = "NoSpread", name = "No Spread", hint = "Entfernt die lokale Geschossstreuung bei Pistole, AK und Minigun." },
        { key = "SilentAim", name = "Silent Aim", hint = "Lenkt manuelle Schüsse auf sichtbare kleine Monster und Bosse nächst am Fadenkreuz. Beachtet Reichweite und Hindernisse; bewegt die Kamera nicht." },
    }
    for _, feature in ipairs(features) do
        local key = feature.key
        tab:CreateSection({ name = feature.name })
        state.controls[toggleNames[key]] = tab:CreateToggle({
            name = feature.name, description = feature.hint, value = false, flag = "PlayerToggle_" .. key,
            callback = function(value) controller.set(key, value) end,
        })
        if feature.speed then
            local field = feature.speed
            local descriptor = descriptorByKey[field]
            state.controls[field] = tab:CreateInput({
                name = descriptor.Name, description = descriptor.Description,
                numeric = true, value = format(config[field]), flag = "Setting_" .. field,
                callback = function(value) commit(field, value) end,
            })
        end
        if feature.keybind then
            state.controls[key .. "Keybind"] = tab:CreateKeybind({
                name = feature.name .. " · Keybind", value = Enum.KeyCode.Unknown,
                flag = "PlayerKeybind_" .. key, hold = false,
                callback = function()
                    if controller.alive and isAlive() and not state.configLoading and not UserInputService:GetFocusedTextBox() then
                        controller.set(key, not controller.enabled[key])
                    end
                end,
            })
        end
    end
    table.insert(controller.connections, UserInputService.WindowFocusReleased:Connect(function()
        controller.focused = false
        if controller.flight then controller.flight.velocity.VectorVelocity = Vector3.zero end
    end))
    table.insert(controller.connections, UserInputService.WindowFocused:Connect(function() controller.focused = true end))
    table.insert(controller.connections, RunService.PreSimulation:Connect(function()
        if not controller.alive then return end
        if not isAlive() then
            controller.destroy()
            return
        end
        local stepped, message = xpcall(step, function(reason) return debug.traceback(tostring(reason), 2) end)
        if not stepped then
            warn("[ForestControl Player] " .. tostring(message))
            controller.destroy()
        end
    end))
    return tab
end

-- Run-Münzen: vorhandene Farmwerkzeuge, Chipper und Grasp bis zu ihren echten MAX-Stufen.
local function createUpgradeAutomation()
    local controller = {
        alive = true, worker = nil :: thread?, rpc = nil :: thread?, tween = nil :: Tween?,
        pending = nil :: { [string]: any }?, epoch = 0, nextAction = 0, status = "", summary = "",
        retries = {} :: { [string]: number }, data = nil :: { [string]: any }?,
        stats = { upgraded = 0, bought = 0 },
    }
    state.upgradeController = controller
    local function running() return controller.alive and isAlive() end
    local function report(message, summary)
        if controller.status ~= message then
            controller.status = message
            local control = state.controls.UpgradeStatus
            if control and running() then control:Set(message) end
        end
        if summary and controller.summary ~= summary then
            controller.summary = summary
            local control = state.controls.UpgradeTargets
            if control and running() then control:Set(summary) end
        end
    end
    local function resolve()
        if controller.data then return controller.data end
        local shared = ReplicatedStorage:FindFirstChild("Shared")
        local configs = shared and shared:FindFirstChild("Configs")
        local utilities = shared and shared:FindFirstChild("Utilities")
        local services = shared and shared:FindFirstChild("Services")
        local settings = configs and configs:FindFirstChild("Chopping")
        local mathModule = utilities and utilities:FindFirstChild("UpgradeMath")
        local world = configs and configs:FindFirstChild("ChapterWorld")
        local place = utilities and utilities:FindFirstChild("PlaceMode")
        local remotes = services and services:FindFirstChild("ChopRemotes")
        local buy = remotes and remotes:FindFirstChild("BuyTool")
        local upgrade = remotes and remotes:FindFirstChild("BuyUpgrade")
        if not settings or not mathModule or not world or not place or not buy or not upgrade
            or not buy:IsA("RemoteFunction") or not upgrade:IsA("RemoteEvent") then return nil end
        controller.data = { settings = require(settings), math = require(mathModule), world = require(world),
            place = require(place), buy = buy, upgrade = upgrade }
        return controller.data
    end
    local function money()
        local stats = player:FindFirstChild("leaderstats")
        local value = stats and stats:FindFirstChild("Cash")
        local amount = value and value.Value
        return type(amount) == "number" and amount == amount and amount >= 0 and amount < math.huge and amount or nil
    end
    local function present(tool)
        return player:GetAttribute("Owns" .. tool) == true or player:GetAttribute("OwnsForever_" .. tool) == true
            or player:GetAttribute("Tool") == tool
            or (tonumber(player:GetAttribute("TrialUntil_" .. tool)) or 0) > workspace:GetServerTimeNow()
    end
    -- Reine Planung anhand replizierter Besitz-/Levelwerte; keine optimistischen lokalen Käufe.
    function controller.plan(data)
        local actions, lines = {}, {}
        local special = false
        local class = player:GetAttribute("Class")
        local tools = data.settings.Tools
        for name, spec in pairs(tools) do
            if type(name) == "string" and type(spec) == "table" and type(spec.Class) == "string"
                and spec.Class ~= "" and (spec.Class == class or present(name)) then special = true end
        end
        if config.AutoBuyFarmTools and not special then
            for index, name in ipairs({ "Axe", "Chainsaw" }) do
                local spec = tools[name]
                if spec and type(spec.Price) == "number" and spec.Price > 0 and not present(name)
                    and (not spec.RequiresItem or data.math.HasItem(player, spec.RequiresItem)) then
                    table.insert(actions, { kind = "buy", id = name, key = "buy:" .. name,
                        name = spec.DisplayName or name, price = spec.Price, priority = index })
                end
            end
        end
        local levels, maximum = 0, 0
        for _, section in ipairs(data.settings.Upgrades.Sections) do
            if section.ComingSoon then continue end
            local tool = section.Tool
            local spec = tool and tools[tool]
            local weapon = tool == "Axe" or tool == "Chainsaw" or type(spec) == "table" and type(spec.Class) == "string" and spec.Class ~= ""
            if section.Requires and player:GetAttribute("Owns" .. section.Requires) ~= true then continue end
            if weapon and player:GetAttribute("Owns" .. tool) ~= true then continue end
            local parts = {}
            for _, item in ipairs(section.Items or {}) do
                if not weapon and item.Effect ~= "ChipSpeed" and item.Effect ~= "Grasp" then continue end
                if item.ComingSoon or type(item.Prices) ~= "table" or #item.Prices == 0
                    or item.Currency and item.Currency ~= "Coins" and item.Currency ~= "Cash"
                    or item.RequiresItem and not data.math.HasItem(player, item.RequiresItem) then continue end
                local level = data.math.Level(player, item.Id)
                local max = #item.Prices
                levels, maximum = levels + level, maximum + max
                table.insert(parts, (item.Name or item.Id) .. " " .. level .. "/" .. max)
                local price = item.Prices[level + 1]
                if type(price) == "number" and price > 0 and price < math.huge then
                    table.insert(actions, { kind = "upgrade", id = item.Id, key = "upgrade:" .. item.Id .. ":" .. level,
                        name = (section.DisplayName or section.Id) .. " · " .. (item.Name or item.Id),
                        price = price, from = level, maximum = max, priority = 3 })
                end
            end
            if #parts > 0 then table.insert(lines, (section.DisplayName or section.Id) .. ": " .. table.concat(parts, " · ")) end
        end
        table.sort(actions, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            if a.price ~= b.price then return a.price < b.price end
            return a.id < b.id
        end)
        local policy = special and "Klassenwaffe erkannt · keine Axt-/Kettensägenkäufe"
            or not config.AutoBuyFarmTools and "Werkzeugkäufe ausgeschaltet"
            or present("Chainsaw") and "Kettensäge vorhanden · Axt als Backup prüfen"
            or "Fehlende Axt und Kettensäge mit Run-Münzen kaufen"
        return actions, policy .. "\n" .. table.concat(lines, "\n"), levels, maximum
    end
    local function ready(data)
        if not running() or not config.AutoUpgrade or state.configLoading or state.sellBusy or state.runBusy
            or state.bossBusy or isGuardianFightActive() or data.place.IsLobby()
            or player:GetAttribute("Loaded") ~= true or player:GetAttribute("InCutscene") == true
            or player:GetAttribute("Down") == true then return false end
        local run = state.runController
        if run and (run.inLobby or run.ended or run.departing) then return false end
        if state.abilityController and state.abilityController.isFlying() then return false end
        if state.playerController and state.playerController.enabled.Fly then return false end
        local map = workspace:FindFirstChild("Map")
        local character = player.Character
        local human = character and character:FindFirstChildOfClass("Humanoid")
        return map ~= nil and map:FindFirstChild("Trees") ~= nil and human ~= nil and human.Health > 0 and not human.Sit
    end
    function controller.cancel()
        controller.epoch = controller.epoch + 1
        if controller.tween then controller.tween:Cancel(); controller.tween = nil end
        if controller.rpc then pcall(task.cancel, controller.rpc); controller.rpc = nil end
        controller.pending = nil
        state.upgradeBusy = false
    end
    function controller.destroy()
        controller.alive = false
        controller.cancel()
        if controller.worker and controller.worker ~= coroutine.running() then pcall(task.cancel, controller.worker) end
        controller.worker = nil
    end
    function controller.changed(key)
        if key == "AutoUpgrade" and not config.AutoUpgrade then controller.cancel(); report("Ausgeschaltet") end
        if key == "AutoBuyFarmTools" and not config.AutoBuyFarmTools and state.upgradeBusy then controller.cancel() end
    end
    local function actionCurrent(data, action)
        for _, candidate in ipairs((controller.plan(data))) do
            if candidate.key == action.key and candidate.price == action.price then return true end
        end
        return false
    end
    local function stationAllowed(anchor, data)
        local unlocked = workspace:GetAttribute("AreasUnlocked")
        if type(unlocked) ~= "number" or unlocked < 1 then return false end
        local node = anchor
        while node and node ~= workspace do
            local index = node:GetAttribute("AreaIndex")
            if index ~= nil then return type(index) == "number" and index >= 1 and index % 1 == 0 and index <= unlocked end
            local area = node:GetAttribute("Area")
            if type(area) == "string" then
                local mapped = data.world.UnlockIndexOf(area)
                return type(mapped) == "number" and mapped >= 1 and mapped <= unlocked
            end
            node = node.Parent
        end
        local map = workspace:FindFirstChild("Map")
        local cabin = map and map:FindFirstChild("LogCabin")
        return cabin ~= nil and anchor:IsDescendantOf(cabin)
    end
    local function findStation(tool, data, position)
        local nearest, best = nil, math.huge
        for _, anchor in ipairs(workspace:GetDescendants()) do
            if anchor:IsA("BasePart") and anchor.Name == "PromptAnchor" and anchor:GetAttribute("ShopItem") == tool
                and stationAllowed(anchor, data) then
                local prompt = anchor:FindFirstChildWhichIsA("ProximityPrompt", true)
                local range = prompt and prompt.MaxActivationDistance or 10
                local distance = (anchor.Position - position).Magnitude
                if distance < best then nearest, best = { anchor = anchor, range = range }, distance end
            end
        end
        return nearest
    end
    local function fail(action, message)
        controller.retries[action.key] = os.clock() + 8
        report(message)
    end
    local function validTrip(data, job)
        return ready(data) and controller.epoch == job.epoch and state.upgradeBusy
            and player.Character == job.character and job.root:IsDescendantOf(job.character)
    end
    local function move(data, job, position, arrived)
        if not validTrip(data, job) then return false end
        local function reached() return arrived and arrived() or not arrived and (job.root.Position - position).Magnitude <= 1 end
        if reached() then return true end
        local duration = math.max(0.05, (job.root.Position - position).Magnitude / math.max(1, config.Speed))
        local tween = TweenService:Create(job.root, TweenInfo.new(duration, Enum.EasingStyle.Linear),
            { CFrame = CFrame.new(position) * job.root.CFrame.Rotation })
        controller.tween = tween
        tween:Play()
        local deadline = os.clock() + duration + 1
        while validTrip(data, job) and os.clock() < deadline and not reached() do task.wait(0.04) end
        tween:Cancel()
        if controller.tween == tween then controller.tween = nil end
        return validTrip(data, job) and reached()
    end
    local function purchase(data, action)
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local station = findStation(action.id, data, root.Position)
        if not station then
            fail(action, action.name .. " · warte auf einen freigeschalteten Verkaufsstand")
            return
        end
        local job = { character = character, root = root, origin = root.Position, epoch = controller.epoch }
        state.upgradeBusy = true
        state.revision = state.revision + 1
        cancelMovement()
        if state.treeCoordinator then state.treeCoordinator.clear() end
        if state.combat then
            if state.combat.stopSaw then state.combat.stopSaw() end
            if state.combat.stopNative then state.combat.stopNative() end
        end
        report("Kaufe " .. action.name .. " · " .. action.price .. " Münzen · zum Stand")
        local offset = Vector3.new(root.Position.X - station.anchor.Position.X, 0, root.Position.Z - station.anchor.Position.Z)
        offset = offset.Magnitude > 0.01 and offset.Unit or Vector3.new(1, 0, 0)
        local destination = station.anchor.Position + offset * math.min(3, station.range / 3)
        local arrivalDistance = math.max(1, math.min(7, station.range - 2))
        if move(data, job, destination, function() return (root.Position - station.anchor.Position).Magnitude <= arrivalDistance end) then
            task.wait(0.2)
            if validTrip(data, job) and actionCurrent(data, action) and stationAllowed(station.anchor, data)
                and (root.Position - station.anchor.Position).Magnitude <= station.range - 0.5
                and (money() or 0) >= action.price then
                local result = { done = false, ok = false, response = nil :: any }
                controller.rpc = task.spawn(function()
                    local ok, response = pcall(data.buy.InvokeServer, data.buy, action.id)
                    result.ok, result.response, result.done = ok, response, true
                end)
                local deadline = os.clock() + 8
                repeat task.wait(0.05) until not validTrip(data, job) or result.done or os.clock() >= deadline
                if controller.rpc then pcall(task.cancel, controller.rpc); controller.rpc = nil end
                if validTrip(data, job) then
                    local untilAt = os.clock() + 1.5
                    while validTrip(data, job) and player:GetAttribute("Owns" .. action.id) ~= true
                        and result.ok and type(result.response) == "table" and result.response.Ok and os.clock() < untilAt do task.wait(0.05) end
                    if player:GetAttribute("Owns" .. action.id) == true then
                        controller.stats.bought = controller.stats.bought + 1
                        report(action.name .. " gekauft · Besitz vom Server bestätigt")
                    else
                        local reason = type(result.response) == "table" and result.response.Why or "Keine Bestätigung"
                        fail(action, action.name .. " nicht bestätigt · " .. tostring(reason))
                    end
                end
            end
        end
        if validTrip(data, job) then move(data, job, job.origin) end
        if controller.epoch == job.epoch then controller.cancel() end
    end
    function controller.step()
        if not config.AutoUpgrade then report("Ausgeschaltet"); return end
        local data = resolve()
        if not data then report("Warte auf Kauf- und Upgrade-Daten"); return end
        local actions, summary, levels, maximum = controller.plan(data)
        if not ready(data) then report(data.place.IsLobby() and "Lobby · Upgrades beginnen erst im Run" or "Warte auf einen aktiven Run / freie Interaktion", summary); return end
        local cash = money()
        if cash == nil then report("Warte auf Run-Münzen", summary); return end
        local pending = controller.pending
        if pending then
            local level = data.math.Level(player, pending.id)
            if level > pending.from then
                controller.stats.upgraded = controller.stats.upgraded + 1
                controller.pending = nil
                controller.nextAction = os.clock() + 0.12
                report(pending.name .. " · Stufe " .. level .. "/" .. pending.maximum .. " bestätigt", summary)
            elseif player:GetAttribute("UpgradeRefusedAt") ~= pending.refused or os.clock() >= pending.deadline then
                controller.pending = nil
                fail(pending, pending.name .. " nicht bestätigt · " .. tostring(player:GetAttribute("UpgradeRefusedWhy") or "neuer Versuch folgt"))
            end
            return
        end
        if os.clock() < controller.nextAction then return end
        local selected, nextPrice
        for _, action in ipairs(actions) do
            nextPrice = not nextPrice and action.price or math.min(nextPrice, action.price)
            if (controller.retries[action.key] or 0) <= os.clock() and cash >= action.price then selected = action; break end
        end
        if not selected then
            report(#actions == 0 and ("Alle erkannten Ziele auf MAX · " .. levels .. "/" .. maximum)
                or "Warte auf Münzen / Kaufmöglichkeit · " .. math.floor(cash) .. " vorhanden · nächster Preis ab " .. tostring(nextPrice), summary)
            return
        end
        report(selected.name .. " · " .. selected.price .. " Münzen", summary)
        if selected.kind == "buy" then purchase(data, selected); return end
        -- Genau eine Stufe anfordern und erst nach der replizierten Leveländerung fortfahren.
        selected.refused = player:GetAttribute("UpgradeRefusedAt")
        selected.deadline = os.clock() + 2.5
        controller.pending = selected
        data.upgrade:FireServer(selected.id)
    end
    function controller.createTab(window)
        local tab = window:CreateTab({ name = "Upgrades" })
        state.controls.AutoUpgrade = tab:CreateToggle({
            name = "Automatisch bis MAX upgraden", value = config.AutoUpgrade, flag = "Setting_AutoUpgrade",
            description = "Unabhängig vom Autofarm: verbessert vorhandene Axt, Kettensäge und Klassenwaffen sowie Chipper-Speed und Grasp mit Run-Münzen bis MAX. Wartet nach jeder Stufe auf die Serverbestätigung.",
            callback = function(value) commitBoolean("AutoUpgrade", value) end,
        })
        state.controls.AutoBuyFarmTools = tab:CreateToggle({
            name = "Axt und Kettensäge automatisch kaufen", value = config.AutoBuyFarmTools, flag = "Setting_AutoBuyFarmTools",
            description = "Nur bei aktiver Upgrade-Automatik. Erkennt vorhandene und permanente Werkzeuge. Bei eigenen Klassenwaffen entfallen beide Käufe; sonst bleibt die Axt als Backup für den bestehenden 85-%-Hitzewechsel.",
            callback = function(value) commitBoolean("AutoBuyFarmTools", value) end,
        })
        state.controls.UpgradeStatus = tab:CreateText({ name = "Upgrade-Status", text = "Ausgeschaltet" })
        state.controls.UpgradeTargets = tab:CreateText({ name = "Erkannte Ziele", text = "Werkzeuge, Preise und MAX-Stufen werden bei aktivierter Automatik aus dem Spiel gelesen." })
        return tab
    end
    function controller.start()
        controller.worker = task.spawn(function()
            while running() do
                local ok, message = xpcall(controller.step, function(reason) return debug.traceback(tostring(reason), 2) end)
                if not ok and running() then
                    controller.cancel()
                    report("Upgrade-Automatik wartet · Details in der Konsole")
                    warn("[ForestControl Upgrades] " .. tostring(message))
                    task.wait(3)
                end
                task.wait(0.15)
            end
        end)
    end
    return controller
end

-- Weltwechsel, bestätigte Event-Interaktionen und wiederholbare Solo-Runs.
local function createRunAutomation()
    local HttpService = game:GetService("HttpService")
    local api = getfenv() :: any
    local queue = api.queue_on_teleport or api.queueonteleport
        or (type(api.syn) == "table" and api.syn.queue_on_teleport)
    local controller = {
        alive = true, connections = {} :: { [string]: any }, sources = {} :: { [string]: Instance },
        worker = nil :: thread?, rpc = nil :: thread?, tween = nil :: Tween?, job = nil :: string?, epoch = 0,
        queued = false, everQueued = false, queueAvailable = type(queue) == "function", status = "", retry = {} :: { [Instance]: number },
        teleportToken = HttpService:GenerateGUID(false),
        inLobby = false, ended = false, departing = false, returning = false, returnAt = 0, returnAttempts = 0,
        openPad = nil :: string?, launchingUntil = 0, nextLaunch = 0, catalog = nil :: any,
    }
    state.runController = controller
    local function running() return controller.alive and isAlive() end
    local function report(message)
        if controller.status == message then return end
        controller.status = message
    end
    local function moduleAt(parent, name)
        local object = parent and parent:FindFirstChild(name)
        if not object or not object:IsA("ModuleScript") then return nil end
        local success, result = pcall(require, object)
        return success and type(result) == "table" and result or nil
    end
    local function rules()
        local shared = ReplicatedStorage:FindFirstChild("Shared")
        local configs = shared and shared:FindFirstChild("Configs")
        local utilities = shared and shared:FindFirstChild("Utilities")
        local lobby = ReplicatedStorage:FindFirstChild("Lobby")
        local chapter = moduleAt(configs, "ChapterWorld")
        local chopping = moduleAt(configs, "Chopping")
        local placeMode = moduleAt(utilities, "PlaceMode")
        local catalog = moduleAt(lobby, "LobbyConfig")
        if catalog then controller.catalog = catalog end
        if not chapter or not chopping then return nil end
        local isLobby = placeMode and placeMode.IsLobby and placeMode.IsLobby()
            or chopping.Places and game.PlaceId == chopping.Places.Lobby
        local current = not isLobby and chapter.Current() or nil
        return { lobby = isLobby == true, chapter = current, chopping = chopping, catalog = catalog }
    end
    function controller.catalogOptions()
        local lobby = ReplicatedStorage:FindFirstChild("Lobby")
        local catalog = controller.catalog or moduleAt(lobby, "LobbyConfig")
        controller.catalog = catalog
        local worlds, difficulties, worldKeys = {}, {}, {}
        if catalog then
            for _, entry in ipairs(catalog.Maps or {}) do
                if entry.Hidden ~= true and (not entry.Ends or entry.Ends > os.time()) then
                    local label = entry.Name .. " (" .. entry.Key .. ")"
                    table.insert(worlds, label)
                    worldKeys[label] = entry.Key
                end
            end
            for _, entry in ipairs(catalog.Difficulties or {}) do table.insert(difficulties, entry.Name) end
        end
        return worlds, difficulties, worldKeys
    end
    function controller.validateSetting(key, value)
        if type(value) ~= "string" then return false end
        local _, difficulties, worlds = controller.catalogOptions()
        if key == "RunDestination" then
            for _, worldKey in pairs(worlds) do if value == worldKey then return true end end
        elseif key == "RunDifficulty" then
            return table.find(difficulties, value) ~= nil
        end
        return false
    end
    function controller.displaySetting(key, value)
        if key == "RunDestination" then
            local _, _, worldKeys = controller.catalogOptions()
            for label, worldKey in pairs(worldKeys) do if worldKey == value then return label end end
        end
        return value
    end
    function controller.cancel()
        controller.epoch = controller.epoch + 1
        if controller.rpc then pcall(task.cancel, controller.rpc); controller.rpc = nil end
        if controller.tween then controller.tween:Cancel(); controller.tween = nil end
        state.runBusy = false
        controller.job = nil
    end
    local function writeTeleportRecord(record)
        if type(api.writefile) ~= "function" then return end
        pcall(function()
            if type(api.makefolder) == "function" and (type(api.isfolder) ~= "function" or not api.isfolder("ForestControl")) then api.makefolder("ForestControl") end
            api.writefile("ForestControl/TeleportResume.json", HttpService:JSONEncode(record))
        end)
    end
    function controller.changed(key)
        if controller.job == key and config[key] ~= true then controller.cancel() end
        if key == "AutoRepeatRun" and config.AutoRepeatRun ~= true then
            controller.departing, controller.returning = false, false
            controller.returnAttempts = 0
        end
    end
    function controller.destroy()
        if controller.everQueued then
            writeTeleportRecord({ version = 1, gameId = game.GameId, expires = os.time() + 900,
                token = controller.teleportToken, cancelled = true })
        end
        controller.alive = false
        controller.cancel()
        for _, connection in pairs(controller.connections) do connection:Disconnect() end
        table.clear(controller.connections)
        if controller.worker and controller.worker ~= coroutine.running() then pcall(task.cancel, controller.worker) end
        controller.worker = nil
    end
    local function capture()
        local modes = { farm = state.enabled, collect = state.collectEnabled, sell = state.sellEnabled,
            player = state.playerController and table.clone(state.playerController.enabled) or {} }
        local binds = {}
        for _, key in ipairs({ "Fly", "WalkSpeed", "Noclip" }) do
            local handle = state.controls[key .. "Keybind"]
            if handle then binds[key] = handle.value.Name end
        end
        return { version = 1, gameId = game.GameId, expires = os.time() + 900, token = controller.teleportToken,
            settings = table.clone(config), modes = modes, binds = binds,
            theme = state.themeStudio and state.themeStudio.exportJSON() or nil }
    end
    function controller.prepareTeleport()
        if not running() then return false end
        if not controller.queueAvailable then report("Weltwechsel: Executor unterstützt keinen Teleport-Neustart"); return false end
        local record = capture()
        writeTeleportRecord(record)
        if controller.queued then return true end
        local payload = HttpService:JSONEncode(record)
        local loader = string.format([=[
if not game:IsLoaded() then game.Loaded:Wait() end
local env = getgenv and getgenv() or _G
if env.__ForestControlTeleportBoot == game.JobId then return end
local data = game:GetService("HttpService"):JSONDecode(%q)
if type(readfile) == "function" then
    local ok, recent = pcall(function()
        local text = readfile("ForestControl/TeleportResume.json")
        assert(#text < 131072)
        return game:GetService("HttpService"):JSONDecode(text)
    end)
    if ok and type(recent) == "table" and recent.version == 1 and recent.gameId == data.gameId
        and type(recent.expires) == "number" and recent.expires >= os.time() then data = recent end
end
if data.cancelled then return end
if game.GameId ~= data.gameId or os.time() > data.expires then return end
env.__ForestControlTeleportBoot = game.JobId
env.__ForestControlTeleportState = data
for attempt = 1, 3 do
    local ok, message = pcall(function()
        local source = game:HttpGet("https://raw.githubusercontent.com/IDLEGLANCE/Forest-Control/main/Forest-Control-Gen2.luau")
        local fn, reason = loadstring(source)
        assert(fn, reason)
        env.__ForestControlTeleportState = data
        fn()
        assert(env.__BambooTweenFarm and env.__BambooTweenFarm.alive, "Forest Control nicht bereit")
    end)
    if ok then return end
    if attempt == 3 then warn("[ForestControl Teleport] " .. tostring(message)) else task.wait(2) end
end
        ]=], payload)
        local accepted, message = pcall(queue, loader)
        controller.queued = accepted
        controller.everQueued = controller.everQueued or accepted
        if not accepted then report("Teleport-Neustart fehlgeschlagen: " .. tostring(message)) end
        return accepted
    end
    controller.connections.Teleport = player.OnTeleport:Connect(function(phase)
        if phase == Enum.TeleportState.Started or phase == Enum.TeleportState.InProgress then
            controller.prepareTeleport()
            if controller.departing or controller.ended then controller.returning = true end
        elseif phase == Enum.TeleportState.Failed then
            controller.queued = false
            controller.launchingUntil, controller.returning = 0, false
            controller.nextLaunch = os.clock() + 8
            report("Teleport fehlgeschlagen · erneuter Versuch folgt")
        end
    end)
    local function connect(name, source, callback)
        if controller.sources[name] == source then return end
        if controller.connections[name] then controller.connections[name]:Disconnect() end
        controller.sources[name] = source
        controller.connections[name] = source.OnClientEvent:Connect(callback)
    end
    local function bindRemotes()
        local shared = ReplicatedStorage:FindFirstChild("Shared")
        local services = shared and shared:FindFirstChild("Services")
        local chop = services and services:FindFirstChild("ChopRemotes")
        local ended = chop and chop:FindFirstChild("RunEnded")
        if ended and ended:IsA("RemoteEvent") then
            connect("RunEnded", ended, function(data)
                if type(data) ~= "table" or data.Staying then return end
                controller.ended = true
                if data.Returning then controller.returning = true end
                if state.upgradeController then state.upgradeController.cancel() end
                controller.cancel()
            end)
        end
        local lobby = ReplicatedStorage:FindFirstChild("Lobby")
        local remotes = lobby and lobby:FindFirstChild("Remotes")
        local open = remotes and remotes:FindFirstChild("OpenCreate")
        if open and open:IsA("RemoteEvent") then
            connect("OpenCreate", open, function(padName)
                controller.openPad = type(padName) == "string" and padName or nil
            end)
        end
        return chop, remotes
    end
    local function aliveCharacter()
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local human = character and character:FindFirstChildOfClass("Humanoid")
        if not root or not human or human.Health <= 0 or player:GetAttribute("Down") == true then return nil end
        return character, root
    end
    local function canAct()
        return running() and not state.configLoading and not state.sellBusy and not state.bossBusy and not state.upgradeBusy
            and not isGuardianFightActive() and not controller.ended and not controller.departing
            and not (state.abilityController and state.abilityController.isFlying())
            and not (state.playerController and state.playerController.enabled.Fly)
            and player:GetAttribute("InCutscene") ~= true
    end
    local function beginJob(kind)
        local character, root = aliveCharacter()
        if not character or not canAct() then return nil end
        controller.cancel()
        controller.job, state.runBusy = kind, true
        state.revision = state.revision + 1
        cancelMovement()
        if state.treeCoordinator then state.treeCoordinator.clear() end
        if state.combat then
            if state.combat.stopSaw then state.combat.stopSaw() end
            if state.combat.stopNative then state.combat.stopNative() end
        end
        return { kind = kind, epoch = controller.epoch, character = character, root = root }
    end
    local function jobValid(job)
        return canAct() and controller.epoch == job.epoch and controller.job == job.kind
            and player.Character == job.character and job.root:IsDescendantOf(job.character)
            and job.character:FindFirstChildOfClass("Humanoid") ~= nil
            and job.character:FindFirstChildOfClass("Humanoid").Health > 0 and config[job.kind] == true
    end
    local function finishJob(job)
        if controller.epoch == job.epoch then controller.cancel() end
    end
    local function move(job, position, radius)
        if not jobValid(job) then return false end
        local delta = position - job.root.Position
        if delta.Magnitude <= radius then return true end
        local duration = math.max(0.05, delta.Magnitude / math.max(config.Speed, 1))
        local tween = TweenService:Create(job.root, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = CFrame.new(position) * job.root.CFrame.Rotation })
        controller.tween = tween
        tween:Play()
        local deadline = os.clock() + duration + 1
        while jobValid(job) and os.clock() < deadline and (job.root.Position - position).Magnitude > radius do task.wait(0.04) end
        tween:Cancel()
        if controller.tween == tween then controller.tween = nil end
        return jobValid(job) and (job.root.Position - position).Magnitude <= radius
    end
    local function promptPosition(prompt)
        local parent = prompt and prompt.Parent
        if parent and parent:IsA("Attachment") then return parent.WorldPosition end
        if parent and parent:IsA("BasePart") then return parent.Position end
        if parent and parent:IsA("Model") then return parent:GetPivot().Position end
        return nil
    end
    local function usePrompt(job, prompt, acknowledged)
        local position = promptPosition(prompt)
        if not position or not prompt.Enabled or not jobValid(job) then return false end
        local offset = Vector3.new(job.root.Position.X - position.X, 0, job.root.Position.Z - position.Z)
        offset = offset.Magnitude > 0.01 and offset.Unit or Vector3.new(1, 0, 0)
        local radius = math.min(3, math.max(0.5, prompt.MaxActivationDistance / 3))
        local destination = position + offset * radius
        if not move(job, destination, 1) then return false end
        local settleUntil = os.clock() + 0.2
        repeat task.wait(0.04) until not jobValid(job) or os.clock() >= settleUntil
        if not jobValid(job) or not prompt:IsDescendantOf(workspace) or not prompt.Enabled
            or (job.root.Position - position).Magnitude > prompt.MaxActivationDistance - 0.5 then return false end
        if type(api.fireproximityprompt) == "function" then
            api.fireproximityprompt(prompt)
        else
            prompt:InputHoldBegin()
            local untilAt = os.clock() + prompt.HoldDuration + 0.05
            repeat task.wait(0.04) until not jobValid(job) or os.clock() >= untilAt
            prompt:InputHoldEnd()
        end
        local deadline = os.clock() + 1.6
        repeat
            if acknowledged() then return true end
            task.wait(0.05)
        until not jobValid(job) or os.clock() >= deadline
        return acknowledged()
    end
    local function foundRavens()
        local result = {}
        local encoded = player:GetAttribute("RavensFound")
        if type(encoded) ~= "string" then return result end
        local ok, values = pcall(HttpService.JSONDecode, HttpService, encoded)
        if ok and type(values) == "table" then for _, id in pairs(values) do result[id] = true end end
        return result
    end
    local function areaAllowed(object, current)
        if not current or type(current.Areas) ~= "table" then return false end
        local unlocked = workspace:GetAttribute("AreasUnlocked")
        if type(unlocked) ~= "number" then return false end
        local area = object:GetAttribute("Area")
        for index, entry in ipairs(current.Areas) do if entry.Key == area then return index <= unlocked end end
        return false
    end
    local function collectRaven(wild, current)
        local ravens = wild:FindFirstChild("Ravens")
        local _, root = aliveCharacter()
        if not ravens or not root then return false end
        local found, best, nearest = foundRavens(), math.huge, nil
        local count = 0
        for _ in pairs(found) do count = count + 1 end
        for _, raven in ipairs(ravens:GetChildren()) do
            if raven:IsA("Model") and not found[raven:GetAttribute("RavenId") or raven.Name]
                and areaAllowed(raven, current) and (controller.retry[raven] or 0) <= os.clock() then
                local prompt = raven:FindFirstChildWhichIsA("ProximityPrompt", true)
                local position = prompt and promptPosition(prompt)
                local distance = position and (position - root.Position).Magnitude or math.huge
                if prompt and prompt.Enabled and distance < best then nearest, best = raven, distance end
            end
        end
        if not nearest then
            if count >= (tonumber(ravens:GetAttribute("Total")) or 12) then report("Raben · alle " .. count .. " vom Server bestätigt") end
            return false
        end
        local job = beginJob("AutoRavens")
        if not job then return false end
        local raven = nearest
        report("Raben · " .. count .. "/" .. tostring(ravens:GetAttribute("Total") or 12) .. " · " .. raven.Name)
        local id = raven:GetAttribute("RavenId") or raven.Name
        local success = usePrompt(job, raven:FindFirstChildWhichIsA("ProximityPrompt", true), function() return foundRavens()[id] == true end)
        controller.retry[raven] = os.clock() + (success and 0 or 8)
        finishJob(job)
        return true
    end
    local function solveHoard(wild, current)
        local hoard = wild:FindFirstChild("Hoard")
        if not hoard or hoard:GetAttribute("Open") == true then return false end
        local area = current and current.Areas and current.Areas[6]
        local total = area and workspace:GetAttribute("BiomeTotal_" .. area.Key)
        local left = area and workspace:GetAttribute("AreaLeft_" .. area.Key)
        if not area or (tonumber(workspace:GetAttribute("AreasUnlocked")) or 0) < 6
            or type(total) ~= "number" or total <= 0 or type(left) ~= "number" or left > total * 0.1 then
            report("Kiste wartet · Area 6 muss mindestens 90 % geräumt sein")
            return false
        end
        if (controller.retry[hoard] or 0) > os.clock() then return false end
        local target = hoard:GetAttribute("Target")
        if type(target) ~= "string" then return false end
        local symbols = string.split(target, ",")
        if #symbols ~= 3 then return false end
        local pillars = {}
        for index = 1, 3 do
            local pillar = hoard:FindFirstChild("Pillar" .. index)
            local prompt = pillar and pillar:FindFirstChildWhichIsA("ProximityPrompt", true)
            if not pillar or not prompt or not tonumber(symbols[index])
                or type(pillar:GetAttribute("Rune")) ~= "number" then return false end
            if pillar:GetAttribute("Rune") ~= tonumber(symbols[index]) and not prompt.Enabled then return false end
            table.insert(pillars, { object = pillar, prompt = prompt, target = tonumber(symbols[index]) })
        end
        local job = beginJob("AutoHoard")
        if not job then return false end
        local success = true
        for index, entry in ipairs(pillars) do
            local turns = 0
            while jobValid(job) and hoard:GetAttribute("Open") ~= true and entry.object:GetAttribute("Rune") ~= entry.target and turns < 8 do
                report("Kiste · Säule " .. index .. " auf Symbol " .. entry.target .. " drehen")
                local previous = entry.object:GetAttribute("Rune")
                if not usePrompt(job, entry.prompt, function() return entry.object:GetAttribute("Rune") ~= previous or hoard:GetAttribute("Open") == true end) then success = false; break end
                turns = turns + 1
                task.wait(0.15)
            end
            if not jobValid(job) or not success or turns == 8 then success = false; break end
        end
        if success and jobValid(job) then
            local deadline = os.clock() + 2
            repeat task.wait(0.05) until not jobValid(job) or hoard:GetAttribute("Open") == true or os.clock() >= deadline
        end
        report(hoard:GetAttribute("Open") == true and "Kiste geöffnet · vom Server bestätigt" or "Kiste noch nicht bestätigt · neuer Versuch nach weiterem Abbau")
        controller.retry[hoard] = os.clock() + 8
        finishJob(job)
        return true
    end
    local function finishRun(current, chopping)
        if current and current.EventBoss then return false end
        local areaList = current and current.Areas or chopping.Forest and chopping.Forest.Areas and chopping.Forest.Areas.Order
        if type(areaList) ~= "table" or #areaList == 0 then return false end
        if (tonumber(workspace:GetAttribute("AreasUnlocked")) or 0) < #areaList then return false end
        for _, area in ipairs(areaList) do
            local key = type(area) == "table" and area.Key or area
            if type(key) ~= "string" then return false end
            local left = workspace:GetAttribute("AreaLeft_" .. key)
            if type(left) ~= "number" or left > 0 then return false end
        end
        local map = workspace:FindFirstChild("Map")
        local reward = map and map:FindFirstChild("Reward")
        local businessman = reward and reward:FindFirstChild("Businessman")
        local prompt = businessman and businessman:FindFirstChildWhichIsA("ProximityPrompt", true)
        if not prompt or not prompt.Enabled or (controller.retry[prompt] or 0) > os.clock() then return false end
        local job = beginJob("AutoFinishRun")
        if not job then return false end
        report("Run abschließen · Businessman ansprechen")
        local previous = workspace:GetAttribute("CashOutAt")
        usePrompt(job, prompt, function() return controller.ended or workspace:GetAttribute("CashOutAt") ~= previous end)
        controller.retry[prompt] = os.clock() + 8
        finishJob(job)
        return true
    end
    local function returnToLobby(chop, places, eventComplete)
        if not controller.queueAvailable then
            report("Auto-Run benötigt Executor-Unterstützung für Teleport-Neustarts"); return
        end
        if controller.returning then report("Run beendet · Rückkehr zur Lobby läuft"); return end
        if controller.returnAttempts >= 3 then report("Lobby-Teleport nicht bestätigt · Wiederholung aus- und einschalten für neuen Versuch"); return end
        if os.clock() < controller.returnAt then return end
        local remote = chop and chop:FindFirstChild("ReturnToLobby")
        if not eventComplete and (not remote or not remote:IsA("RemoteEvent")) then return end
        if eventComplete and (not places or type(places.Lobby) ~= "number") then return end
        if eventComplete and not controller.departing then
            local job = beginJob("AutoRepeatRun")
            if job then finishJob(job) end
            state.revision = state.revision + 1
            cancelMovement()
        end
        controller.cancel()
        controller.departing = eventComplete == true
        report(eventComplete and "12 Raben und Kiste bestätigt · zurück zur Lobby für nächsten Run" or "Run beendet · zurück zur Lobby und neuen Run starten")
        controller.returnAt, controller.returnAttempts = os.clock() + 5, controller.returnAttempts + 1
        if eventComplete then
            -- Normale Client-Teleport-API: Event-Rewards sind bereits bestätigt; kein vorgetäuschter Run-Abschluss.
            local accepted, reason = pcall(function() game:GetService("TeleportService"):Teleport(places.Lobby, player) end)
            if not accepted then report("Lobby-Teleport fehlgeschlagen: " .. tostring(reason)) end
        else
            remote:FireServer()
        end
    end
    local function eventRewardsComplete(wild)
        local ravens, hoard = wild:FindFirstChild("Ravens"), wild:FindFirstChild("Hoard")
        if not ravens or not hoard or hoard:GetAttribute("Open") ~= true then return false end
        local found, count = foundRavens(), 0
        for _, raven in ipairs(ravens:GetChildren()) do
            if raven:IsA("Model") then
                if not found[raven:GetAttribute("RavenId") or raven.Name] then return false end
                count = count + 1
            end
        end
        return count >= (tonumber(ravens:GetAttribute("Total")) or 12)
    end
    local function freePad(pad)
        if not pad:IsA("Model") then return false end
        local status = pad:GetAttribute("Status")
        if status ~= nil and status ~= "Idle" then return false end
        if pad:GetAttribute("Host") ~= nil or (tonumber(pad:GetAttribute("Members")) or 0) > 0 then return false end
        for _, peer in ipairs(Players:GetPlayers()) do
            if peer ~= player then
                local root = peer.Character and peer.Character:FindFirstChild("HumanoidRootPart")
                if root then
                    local delta = root.Position - pad:GetPivot().Position
                    if Vector2.new(delta.X, delta.Z).Magnitude <= 6.5 and delta.Y > -2 and delta.Y < 9 then return false end
                end
            end
        end
        return true
    end
    local function launchRun(data, remotes)
        if os.clock() < controller.nextLaunch or os.clock() < controller.launchingUntil then return end
        if not controller.queueAvailable then
            report("Auto-Run benötigt Executor-Unterstützung für Teleport-Neustarts"); return
        end
        if player:GetAttribute("Loaded") ~= true or not data.catalog then report("Lobby · warte auf Spielerdaten"); return end
        local selected, difficulty
        for _, entry in ipairs(data.catalog.Maps or {}) do if entry.Key == config.RunDestination then selected = entry; break end end
        for _, entry in ipairs(data.catalog.Difficulties or {}) do if entry.Name == config.RunDifficulty then difficulty = entry; break end end
        local wins = tonumber(player:GetAttribute("Wins")) or 0
        if not selected or selected.Hidden == true or selected.Ends and selected.Ends <= os.time() then report("Gewählte Welt ist nicht mehr verfügbar"); return end
        if not difficulty or wins < (selected.Wins or 0) or wins < (difficulty.Wins or 0) then report("Welt oder Schwierigkeit noch nicht freigeschaltet"); return end
        local lobby = workspace:FindFirstChild("Lobby")
        local pads = lobby and lobby:FindFirstChild("LobbyPads")
        local _, root = aliveCharacter()
        if not pads or not root or not remotes then report("Lobby · warte auf Startpads"); return end
        local party = player:GetAttribute("PartyPad")
        local pad = type(party) == "string" and pads:FindFirstChild(party) or nil
        if pad then
            if tonumber(pad:GetAttribute("Host")) ~= player.UserId then report("Andere Party aktiv · automatischer Start wartet"); return end
            local status = pad:GetAttribute("Status")
            if status ~= nil and status ~= "Idle" and controller.openPad ~= pad.Name then report("Eigene Party · warte auf Start"); return end
        else
            local distance = math.huge
            for _, candidate in ipairs(pads:GetChildren()) do
                if freePad(candidate) then
                    local candidateDistance = (candidate:GetPivot().Position - root.Position).Magnitude
                    if candidateDistance < distance then pad, distance = candidate, candidateDistance end
                end
            end
        end
        if not pad then report("Lobby · warte auf ein freies Startpad"); return end
        local job = beginJob("AutoRepeatRun")
        if not job then return end
        report("Lobby · Solo-Run starten: " .. selected.Name .. " · " .. difficulty.Name)
        if controller.openPad ~= pad.Name then
            if not move(job, pad:GetPivot().Position + Vector3.new(0, 3, 0), 1) then finishJob(job); return end
            local deadline = os.clock() + 5
            repeat task.wait(0.05) until not jobValid(job) or controller.openPad == pad.Name or os.clock() >= deadline
        end
        local create = remotes:FindFirstChild("CreateParty")
        local host = tonumber(pad:GetAttribute("Host"))
        if not jobValid(job) or controller.openPad ~= pad.Name or host and host ~= player.UserId
            or not create or not create:IsA("RemoteFunction") then
            controller.nextLaunch = os.clock() + 8
            finishJob(job)
            return
        end
        controller.nextLaunch = os.clock() + 15
        -- Ein Aufruf pro bestätigtem Pad; keine wiederholten Requests während des Starts.
        local result = { done = false, success = false, response = nil :: any }
        local rpc = task.spawn(function()
            local success, response = pcall(create.InvokeServer, create, pad.Name, difficulty.Name, 1, selected.Key, config.RunPeaceful and selected.Peaceful ~= false)
            result.success, result.response, result.done = success, response, true
        end)
        controller.rpc = rpc
        local deadline = os.clock() + 12
        repeat task.wait(0.05) until result.done or not jobValid(job) or os.clock() >= deadline
        if not result.done then pcall(task.cancel, rpc) end
        if controller.rpc == rpc then controller.rpc = nil end
        if not jobValid(job) then finishJob(job); return end
        local success, response = result.success, result.response
        if success and type(response) == "table" and response.Ok then
            controller.launchingUntil = os.clock() + 30
            report("Solo-Run erstellt · warte auf Teleport")
        else
            report("Run-Start abgelehnt · " .. tostring(type(response) == "table" and (response.Message or response.Error) or response))
            if not result.done then controller.launchingUntil = os.clock() + 30; report("Run-Start noch nicht bestätigt · warte auf Server oder Teleport") end
        end
        finishJob(job)
    end
    function controller.step()
        local chop, lobbyRemotes = bindRemotes()
        if state.configLoading then return end
        local data = rules()
        if not data then report("Warte auf Welt- und Run-Daten"); return end
        controller.inLobby = data.lobby
        if data.lobby then
            controller.ended = false
            if config.AutoRepeatRun then launchRun(data, lobbyRemotes) else report("Lobby · automatischer Run-Start ausgeschaltet") end
            return
        end
        if playerGui:FindFirstChild("RunEnd") then controller.ended = true end
        if controller.ended then
            if config.AutoRepeatRun then returnToLobby(chop, data.chopping.Places, false) else report("Run beendet · automatische Wiederholung ausgeschaltet") end
            return
        end
        local wild = workspace:FindFirstChild("FrostWilds")
        if config.AutoRepeatRun and wild and data.chapter and data.chapter.Key == "WarGod"
            and (controller.departing or eventRewardsComplete(wild)) then
            if state.upgradeController then state.upgradeController.cancel() end
            returnToLobby(chop, data.chopping.Places, true)
            return
        end
        if not canAct() then return end
        if wild and data.chapter and data.chapter.Key == "WarGod" then
            if config.AutoRavens and collectRaven(wild, data.chapter) then return end
            if config.AutoHoard and solveHoard(wild, data.chapter) then return end
        end
        if config.AutoFinishRun and finishRun(data.chapter, data.chopping) then return end
        if not config.AutoRavens and not config.AutoHoard and not config.AutoFinishRun then report("Bereit · Run- und Event-Automatik ausgeschaltet") end
        for object in pairs(controller.retry) do if not object:IsDescendantOf(workspace) then controller.retry[object] = nil end end
    end
    function controller.restore(payload)
        if type(payload) ~= "table" or payload.version ~= 1 or payload.gameId ~= game.GameId
            or type(payload.expires) ~= "number" or payload.expires < os.time() then return false end
        state.configLoading = true
        for key, value in pairs(payload.settings or {}) do
            if type(value) == type(config[key]) and (type(value) ~= "string" or controller.validateSetting(key, value)) then config[key] = value end
        end
        config.MaxChopDistance = math.max(TREE_DISTANCE, config.MaxChopDistance)
        for key, value in pairs(config) do
            local control = state.controls[key]
            if control then
                local display = value
                if key == "RunDestination" then
                    local _, _, worldKeys = controller.catalogOptions()
                    for label, worldKey in pairs(worldKeys) do if worldKey == value then display = label end end
                end
                control:Set(type(display) == "number" and format(display) or display, true)
            end
        end
        syncSellCapacityUI()
        for key, name in pairs(payload.binds or {}) do
            local control = state.controls[key .. "Keybind"]
            local found, code = pcall(function() return Enum.KeyCode[name] end)
            if control and found and code then control:Set(code, true) end
        end
        if type(payload.theme) == "string" and state.themeStudio then pcall(state.themeStudio.importJSON, payload.theme) end
        state.configLoading = false
        local modes = payload.modes or {}
        for key, value in pairs(modes.player or {}) do state.playerController.set(key, value == true) end
        state.setEnabled(modes.farm == true)
        state.setAutoCollect(modes.collect == true)
        state.setAutoSell(modes.sell == true)
        return true
    end
    function controller.createTab(window)
        local tab = window:CreateTab({ name = "Runs & Event" })
        tab:CreateSection({ name = "Frozen Wilds · Shards" })
        for _, feature in ipairs({
            { key = "AutoRavens", name = "Raben automatisch einsammeln", hint = "Besucht noch fehlende Raben in freigeschalteten Areas und wartet auf die bestätigte RavensFound-Liste. Unabhängig vom Autofarm." },
            { key = "AutoHoard", name = "Säulenrätsel automatisch lösen", hint = "Ab 90 % geräumter Area 6: Zielsymbole lesen, die drei Säulen drehen und auf die bestätigte Kistenöffnung warten." },
        }) do
            local key = feature.key
            state.controls[key] = tab:CreateToggle({ name = feature.name, description = feature.hint,
                value = config[key], flag = "Setting_" .. key,
                callback = function(value) commitBoolean(key, value) end })
        end
        tab:CreateSection({ name = "Run-Abschluss & Wiederholung" })
        state.controls.AutoFinishRun = tab:CreateToggle({
            name = "Run automatisch abschließen", value = config.AutoFinishRun, flag = "Setting_AutoFinishRun",
            description = "Spricht nach vollständig geräumten Chapter-Areas und beendetem Bosskampf den Businessman an. Event-Bosse behalten ihren eigenen Abschluss.",
            callback = function(value) commitBoolean("AutoFinishRun", value) end,
        })
        local worlds, difficulties, worldKeys = controller.catalogOptions()
        local function choice(key, value)
            if syncing or not running() or type(value) ~= "string" then return end
            if key == "RunDestination" then value = worldKeys[value] end
            if not controller.validateSetting(key, value) then return end
            if state.configLoading then state.configPending[key] = value else config[key] = value; controller.cancel() end
        end
        state.controls.RunDestination = tab:CreateDropdown({
            name = "Welt für neue Runs", options = worlds,
            value = { controller.displaySetting("RunDestination", config.RunDestination) },
            flag = "Setting_RunDestination", description = "Erstellt einen neuen Solo-Run in der ausgewählten verfügbaren Welt. Freischaltungen und Event-Endzeiten werden geprüft.",
            callback = function(value) choice("RunDestination", value) end,
        })
        state.controls.RunDifficulty = tab:CreateDropdown({
            name = "Schwierigkeit", options = difficulties, value = { config.RunDifficulty },
            flag = "Setting_RunDifficulty", callback = function(value) choice("RunDifficulty", value) end,
        })
        state.controls.RunPeaceful = tab:CreateToggle({
            name = "Neue Runs friedlich starten", value = config.RunPeaceful, flag = "Setting_RunPeaceful",
            description = "Wird nur gesetzt, wenn die gewählte Welt den Friedlich-Modus unterstützt.",
            callback = function(value) commitBoolean("RunPeaceful", value) end,
        })
        state.controls.AutoRepeatRun = tab:CreateToggle({
            name = "Runs automatisch wiederholen", value = config.AutoRepeatRun, flag = "Setting_AutoRepeatRun",
            description = "Chapter: nach RunEnded zur Lobby. Frozen Wilds: sobald alle 12 Raben und die Kiste bestätigt sind. Danach neuen Solo-Run starten; aktuelle Farm-/Sammel-/Boss-Schalter werden übernommen.",
            callback = function(value) commitBoolean("AutoRepeatRun", value) end,
        })
        return tab
    end
    function controller.start()
        bindRemotes()
        controller.worker = task.spawn(function()
            while running() do
                local ok, message = xpcall(controller.step, function(reason) return debug.traceback(tostring(reason), 2) end)
                if not ok and running() then
                    controller.cancel()
                    report("Run-Automatik wartet · Details in der Konsole")
                    warn("[ForestControl Runs] " .. tostring(message))
                    task.wait(3)
                end
                task.wait(0.25)
            end
        end)
    end
    bindRemotes()
    return controller
end

local function createConfigManager(window)
    local HttpService = game:GetService("HttpService")
    local META_FILE = "ForestControl/ConfigLoader.json"
    local tab = window.rfSettings
    assert(tab and type(tab.CreateDropdown) == "function", "Native Sirius-Einstellungen nicht verfügbar")
    local nativeSave, nativeLoad, nativeDelete = window.Save, window.Load, window.DeleteConfig
    local manager = {
        alive = true, syncing = false, busy = false, name = "Meine Config", selected = nil,
        meta = { version = 1, autoEnabled = false, autoName = "", lastName = "Meine Config", themes = {} :: { [string]: string } },
        controls = {} :: { [string]: any },
        offLabel = "Aus",
    }
    state.configManager = manager
    if type(readfile) == "function" then
        local read, text = pcall(readfile, META_FILE)
        if read and type(text) == "string" and #text < 1024000 then
            local decoded, data = pcall(HttpService.JSONDecode, HttpService, text)
            if decoded and type(data) == "table" and data.version == 1 then
                manager.meta.autoEnabled = data.autoEnabled == true
                manager.meta.autoName = type(data.autoName) == "string" and data.autoName or ""
                if type(data.themes) == "table" then
                    for name, theme in pairs(data.themes) do
                        if type(name) == "string" and type(theme) == "string" and #theme <= 64000 then
                            manager.meta.themes[name] = theme
                        end
                    end
                end
                if type(data.lastName) == "string" and #data.lastName > 0 and #data.lastName <= 64 then manager.name = data.lastName end
            end
        end
    end
    local function report(message)
        if manager.alive and isAlive() and message:sub(1, 7) == "Fehler:" then
            window:Notify({ title = "Config", content = message })
        end
    end
    local function cleanName(value)
        assert(type(value) == "string", "Config-Namen eingeben")
        local name = value:match("^%s*(.-)%s*$")
        assert(#name > 0 and #name <= 64 and name ~= "." and name ~= "..", "Config-Name: 1 bis 64 Zeichen")
        assert(not name:find('[<>:"/\\|?*%c]') and name:sub(-1) ~= ".", "Config-Name enthält ungültige Dateizeichen")
        return name
    end
    local function persistMeta()
        assert(type(writefile) == "function" and type(makefolder) == "function", "Executor unterstützt kein lokales Speichern")
        pcall(makefolder, "ForestControl")
        writefile(META_FILE, HttpService:JSONEncode(manager.meta))
    end
    local function action(callback)
        if not manager.alive or not isAlive() then return false, "UI beendet" end
        if manager.busy then return false, "Eine Config-Aktion läuft bereits" end
        manager.busy = true
        local succeeded, message = pcall(callback)
        manager.busy = false
        local text = succeeded and tostring(message) or (tostring(message):gsub("^.-:%d+: ", ""))
        report(succeeded and text or "Fehler: " .. text)
        return succeeded, text
    end
    function manager.refresh()
        local names = window:ListConfigs()
        if type(names) ~= "table" then names = {} end
        table.sort(names)
        if not table.find(names, manager.selected) then manager.selected = names[1] end
        manager.offLabel = "Aus"
        while table.find(names, manager.offLabel) do manager.offLabel = manager.offLabel .. " (deaktiviert)" end
        if manager.meta.autoEnabled and not table.find(names, manager.meta.autoName) then
            manager.meta.autoEnabled = false
            manager.meta.autoName = ""
            persistMeta()
        end
        local options = { manager.offLabel }
        for _, name in ipairs(names) do table.insert(options, name) end
        manager.syncing = true
        local refreshed, message = pcall(function()
            if manager.controls.AutoName then
                manager.controls.AutoName:Refresh(options)
                manager.controls.AutoName:Set(manager.meta.autoEnabled and manager.meta.autoName or manager.offLabel, true)
            end
        end)
        manager.syncing = false
        assert(refreshed, message)
        return names
    end
    local function modes()
        local controller = state.playerController
        return {
            FarmEnabled = state.enabled, CollectEnabled = state.collectEnabled, SellEnabled = state.sellEnabled,
            PlayerFly = controller and controller.enabled.Fly == true or false,
            PlayerWalkSpeed = controller and controller.enabled.WalkSpeed == true or false,
            PlayerNoclip = controller and controller.enabled.Noclip == true or false,
            PlayerNoRecoil = controller and controller.enabled.NoRecoil == true or false,
            PlayerNoSpread = controller and controller.enabled.NoSpread == true or false,
            PlayerSilentAim = controller and controller.enabled.SilentAim == true or false,
        }
    end
    local function snapshot()
        local binds = {}
        for _, key in ipairs({ "Fly", "WalkSpeed", "Noclip" }) do binds[key] = state.controls[key .. "Keybind"].value end
        return {
            settings = table.clone(config), modes = modes(), binds = binds,
            theme = state.themeStudio and state.themeStudio.exportJSON() or nil,
        }
    end
    local function syncSettings()
        for key, value in pairs(config) do
            local handle = state.controls[key]
            local display = state.runController and state.runController.displaySetting(key, value) or value
            if handle then handle:Set(type(display) == "number" and format(display) or display, true) end
        end
        syncSellCapacityUI()
    end
    local function applyModes(values)
        local controller = state.playerController
        if controller then
            controller.set("WalkSpeed", values.PlayerWalkSpeed == true)
            controller.set("Noclip", values.PlayerNoclip == true)
            controller.set("NoRecoil", values.PlayerNoRecoil == true)
            controller.set("NoSpread", values.PlayerNoSpread == true)
            controller.set("SilentAim", values.PlayerSilentAim == true)
        end
        state.setEnabled(values.FarmEnabled == true)
        if controller then controller.set("Fly", values.PlayerFly == true and not values.FarmEnabled) end
        state.setAutoCollect(values.CollectEnabled == true)
        state.setAutoSell(values.SellEnabled == true)
    end
    local function pause()
        if state.upgradeController then state.upgradeController.cancel() end
        if state.runController then state.runController.cancel() end
        state.cancelSell("Configwechsel · zurückgekehrt")
        state.setEnabled(false)
        state.setAutoCollect(false)
        state.setAutoSell(false)
        local controller = state.playerController
        if controller then
            for _, key in ipairs({ "Fly", "WalkSpeed", "Noclip", "NoRecoil", "NoSpread", "SilentAim" }) do controller.set(key, false) end
        end
    end
    local function validateSettings(values)
        local candidate = table.clone(config)
        for key, raw in pairs(values) do
            if type(candidate[key]) == "boolean" then
                assert(type(raw) == "boolean", "Ungültiger Schalter: " .. key)
                candidate[key] = raw
            elseif type(candidate[key]) == "string" then
                assert(state.runController and state.runController.validateSetting(key, raw), "Ungültige Run-Auswahl: " .. key)
                candidate[key] = raw
            else
                local descriptor = descriptorByKey[key]
                assert(descriptor, "Unbekannte Einstellung: " .. tostring(key))
                local value = tonumber((tostring(raw):gsub(",", ".")))
                assert(value and value == value and math.abs(value) < math.huge, "Ungültige Zahl: " .. key)
                assert(value >= descriptor.Min and (not descriptor.Max or value <= descriptor.Max), "Wert außerhalb des Bereichs: " .. key)
                assert(not descriptor.Integer or value % 1 == 0, "Ganze Zahl nötig: " .. key)
                candidate[key] = value
            end
        end
        assert(candidate.MinTweenTime <= candidate.MaxTweenTime, "Minimale Tween-Zeit übersteigt die maximale")
        candidate.MaxChopDistance = math.max(TREE_DISTANCE, candidate.MaxChopDistance)
        return candidate
    end
    function manager.save(name)
        return action(function()
            assert(not state.sellBusy, "Den laufenden Verkauf kurz abwarten")
            local target = cleanName(name or window.configuration.fileName or "Default")
            if name ~= nil then name = target end
            syncSettings()
            local values = snapshot()
            assert(nativeSave(window, name), "Config konnte nicht lokal gespeichert werden")
            if values.theme then manager.meta.themes[target] = values.theme end
            manager.name = target
            manager.selected = target
            manager.meta.lastName = target
            persistMeta()
            manager.refresh()
            return "Config gespeichert: " .. target
        end)
    end
    function manager.load(name)
        return action(function()
            local target = cleanName(name or window.configuration.fileName or "Default")
            if name ~= nil then name = target end
            assert(table.find(manager.refresh(), target), "Config nicht gefunden: " .. target)
            local before = snapshot()
            pause()
            state.configPending = {}
            state.pendingModes = {}
            state.configLoading = true
            local loaded, result = pcall(function()
                assert(nativeLoad(window, name), "Config konnte nicht gelesen werden")
                task.wait()
                assert(manager.alive and isAlive(), "UI während des Ladens beendet")
                local candidate = validateSettings(state.configPending)
                assert(not (state.pendingModes.FarmEnabled and state.pendingModes.PlayerFly), "Config aktiviert gleichzeitig Fly und Autofarm")
                local theme = manager.meta.themes[target]
                if theme and state.themeStudio then state.themeStudio.importJSON(theme) end
                return candidate
            end)
            state.configLoading = false
            if not manager.alive or not isAlive() then error("UI während des Ladens beendet") end
            if not loaded then
                for key, value in pairs(before.settings) do config[key] = value end
                syncSettings()
                for key, value in pairs(before.binds) do state.controls[key .. "Keybind"]:Set(value, true) end
                if before.theme and state.themeStudio then pcall(state.themeStudio.importJSON, before.theme) end
                applyModes(before.modes)
                error(result)
            end
            for key, value in pairs(result) do config[key] = value end
            syncSettings()
            applyModes(state.pendingModes)
            manager.name = target
            manager.selected = target
            if manager.controls.NativeSelection then manager.controls.NativeSelection:Set(target) end
            manager.refresh()
            return "Config geladen: " .. target
        end)
    end
    function manager.setAuto(enabled, name)
        return action(function()
            local selected = name ~= nil and cleanName(name) or manager.meta.autoName
            if enabled then assert(table.find(manager.refresh(), selected), "Zuerst eine vorhandene Auto-Config auswählen") end
            local previousEnabled, previousName = manager.meta.autoEnabled, manager.meta.autoName
            manager.meta.autoEnabled = enabled == true
            manager.meta.autoName = selected
            local written, message = pcall(persistMeta)
            if not written then
                manager.meta.autoEnabled, manager.meta.autoName = previousEnabled, previousName
                manager.refresh()
                error(message)
            end
            manager.refresh()
            return enabled and ("Beim Start automatisch laden: " .. selected) or "Auto-Config-Loader ausgeschaltet"
        end)
    end
    function manager.start()
        manager.refresh()
        if manager.meta.autoEnabled then
            return manager.load(manager.meta.autoName)
        end
        report("Bereit · Configs werden lokal gespeichert")
        return true
    end
    function manager.destroy()
        manager.alive = false
    end
    function manager.delete(name)
        return action(function()
            name = cleanName(name)
            assert(nativeDelete(window, name), "Config konnte nicht gelöscht werden")
            manager.meta.themes[name] = nil
            if manager.meta.autoName == name then
                manager.meta.autoEnabled = false
                manager.meta.autoName = ""
            end
            persistMeta()
            manager.refresh()
            return "Config gelöscht: " .. name
        end)
    end
    for _, element in ipairs(tab.elements) do
        if element.name == "Saved Configurations" then manager.controls.NativeSelection = element end
    end
    manager.refresh()
    manager.controls.AutoName = tab:CreateDropdown({
        name = "Auto-Load", options = { manager.offLabel }, value = { manager.offLabel },
        description = "Aus oder eine Config auswählen, die beim nächsten Scriptstart geladen wird.",
        forgetState = true,
        callback = function(value)
            if manager.syncing or not manager.alive or type(value) ~= "string" then return end
            local enabled = value ~= manager.offLabel
            manager.setAuto(enabled, enabled and value or nil)
        end,
    })
    manager.refresh()
    -- Die nativen Save/Load/Delete-Buttons verwenden diese Instanzmethoden.
    -- Validierung und Theme-Wiederherstellung bleiben damit auch dort atomar.
    window.Save = function(_, name) return manager.save(name) end
    window.Load = function(_, name) return manager.load(name) end
    window.DeleteConfig = function(_, name) return manager.delete(name) end
    return manager
end

local ok, err = pcall(function()
    local librarySource = game:HttpGet("https://sirius.menu/gen2")
    if not isAlive() then return end
    local loader, loadError = loadstring(librarySource)
    assert(loader, loadError)
    -- Nur diese Gen2-Instanz im normalen PlayerGui anlegen.
    -- Hintergrund-Tasks benötigen dadurch keinen Zugriff auf geschütztes CoreGui.
    local libraryEnvironment = setmetatable({
        gethui = function()
            return playerGui
        end,
    }, { __index = getfenv(loader) })
    setfenv(loader, libraryEnvironment)
    local Rayfield = loader()
    if not isAlive() then return end

    local window = Rayfield:CreateWindow({
        name = "Forest Control",
        subtitle = "Rayfield Gen2",
        showName = "Forest",
        sidebarLayout = true,
        theme = "cobalt",
        configuration = {
            autoSave = false, autoLoad = false,
            fileName = "Default", customFolder = "ForestControl",
        },
    })
    if not isAlive() then
        window:Unload()
        return
    end
    state.window = window
    local runController = createRunAutomation()
    local upgradeController = createUpgradeAutomation()

    local farm = window:CreateTab({ name = "Farm" })
    local movement = window:CreateTab({ name = "Bewegung" })
    local chopping = window:CreateTab({ name = "Abbau" })
    local collection = window:CreateTab({ name = "Sammeln" })
    local selling = window:CreateTab({ name = "Verkaufen" })
    runController.createTab(window)
    upgradeController.createTab(window)
    createPlayerTab(window)
    local tabs = { Movement = movement, Chopping = chopping, Collection = collection, Selling = selling }

    state.controls.AutoSell = selling:CreateToggle({
        name = "Auto-Sell", value = false, flag = "SellEnabled",
        description = "Ab der Holzmenge oder bei vollem Rucksack per schnellem Tween zum nächsten freigeschalteten Verkaufspunkt und zurück.",
        callback = function(value)
            if not syncing and isAlive() then state.setAutoSell(value) end
        end,
    })
    state.controls.AutoDetectBackpackCapacity = selling:CreateToggle({
        name = "Auto Detect Backpack Capacity", value = config.AutoDetectBackpackCapacity,
        flag = "Setting_AutoDetectBackpackCapacity",
        description = "Verkauft automatisch bei vollem Rucksack und berücksichtigt dessen aktuelle Kapazität. Ein unendlicher Rucksack wird nie voll.",
        callback = function(value) commitBoolean("AutoDetectBackpackCapacity", value) end,
    })
    state.controls.SellThreshold = selling:CreateInput({
        name = descriptorByKey.SellThreshold.Name, description = descriptorByKey.SellThreshold.Description,
        numeric = true, value = format(config.SellThreshold), flag = "Setting_SellThreshold",
        callback = function(value) commit("SellThreshold", value) end,
    })
    syncSellCapacityUI()
    state.controls.ManualSell = selling:CreateButton({
        name = "Jetzt Holz verkaufen",
        description = "Per schnellem Tween zum Pad, einmal Holz abgeben, dort 1 Sekunde bleiben und zurück; unabhängig vom Auto-Sell-Toggle.",
        callback = function()
            if not isAlive() then return end
            local accepted, message = state.requestSell("manual")
            if not accepted then setSellStatus(message) end
        end,
    })
    selling:CreateButton({
        name = "Verkauf abbrechen & zurück",
        callback = function()
            if state.cancelSell then state.cancelSell("Abgebrochen · zurückgekehrt") end
        end,
    })
    sellStatus = selling:CreateText({ name = "Verkaufsstatus", text = "Auto-Sell aus · manueller Verkauf bereit" })

    syncing = true
    state.controls.Main = farm:CreateToggle({
        name = "Autofarm",
        description = "Startet oder pausiert den Autofarm für alle Baumarten mit automatischer Werkzeug- und Klassenerkennung und Restfeuerschaden. Auto-Collect bleibt unabhängig.",
        value = false,
        flag = "FarmEnabled",
        callback = function(value)
            if not syncing and isAlive() then state.setEnabled(value) end
        end,
    })
    state.controls.ChainsawToolSwitch = farm:CreateToggle({
        name = "Kettensäge ↔ bestes Werkzeug",
        description = string.format("An: Kettensäge und Ersatzwerkzeug wechseln bei 85 %% Hitze; zurück bei %.0f %%. Aus: bestes Ersatzwerkzeug ohne Kettensäge.", SAW_RETURN_HEAT * 100),
        value = config.ChainsawToolSwitch,
        flag = "Setting_ChainsawToolSwitch",
        callback = function(value) commitBoolean("ChainsawToolSwitch", value) end,
    })
    state.controls.AutoBoss = farm:CreateToggle({
        name = "Auto-Bossfight", value = config.AutoBoss, flag = "Setting_AutoBoss",
        description = "Unabhängig vom Autofarm: Guardian mit der besten vorhandenen Waffe bekämpfen, seine Rückseite verfolgen und frontalen Angriffen ausweichen.",
        callback = function(value) commitBoolean("AutoBoss", value) end,
    })
    status = farm:CreateText({ name = "Status", text = "Pausiert · bereit zum Starten" })
    farm:CreateButton({
        name = "Terminate",
        description = "Autofarm und Auto-Collect vollständig beenden und dieses Fenster entfernen.",
        callback = state.stop,
    })

    state.controls.AutoCollect = collection:CreateToggle({
        name = "Auto-Collect",
        description = "Holz, eigene Gems und Shards einsammeln, unabhängig vom Autofarm. Grasp und Tragkapazität gelten für Holz.",
        value = false,
        flag = "CollectEnabled",
        callback = function(value)
            if not syncing and isAlive() then state.setAutoCollect(value) end
        end,
    })
    for _, item in ipairs({
        { key = "CollectLogs", name = "Holz einsammeln" },
        { key = "CollectGems", name = "Gems einsammeln" },
        { key = "CollectShards", name = "Shards einsammeln" },
    }) do
        local key = item.key
        state.controls[key] = collection:CreateToggle({
            name = item.name, value = config[key], flag = "Setting_" .. key,
            description = "Wird nur ausgeführt, solange Auto-Collect eingeschaltet ist.",
            callback = function(value)
                commitBoolean(key, value)
            end,
        })
    end

    state.controls.CombatStats = chopping:CreateText({ name = "Werkzeug · Live-Werte", text = "Werkzeugdaten werden gelesen …" })

    for _, descriptor in ipairs(descriptors) do
        if descriptor.Tab == "Player" or descriptor.Tab == "Selling" then continue end
        local key = descriptor.Key
        state.controls[key] = tabs[descriptor.Tab]:CreateInput({
            name = descriptor.Name,
            description = descriptor.Description,
            numeric = true,
            value = format(config[key]),
            placeholder = "Zahl eingeben",
            flag = "Setting_" .. key,
            callback = function(value) commit(key, value) end,
        })
    end
    syncing = false
    state.setEnabled(false)
    state.setAutoCollect(false)
    state.setAutoSell(false)
    createThemeStudio(window)
    createConfigManager(window)
end)

if not ok then
    state.stop()
    warn("[ForestControl Gen2] UI konnte nicht geladen werden: " .. tostring(err))
    return
end
if not isAlive() then return end

local trees
local Swing
local Chop
local skippedUntil = setmetatable({}, { __mode = "k" })
local treeRecovery = setmetatable({}, { __mode = "k" })

local combat = {
    confirmTimeout = HIT_CONFIRM_TIMEOUT,
    recoveryFactor = POST_HIT_RECOVERY_FACTOR,
    hellChainRecoveryFactor = HELLCHAIN_RECOVERY_FACTOR,
    nextStart = type(previous) == "table" and type(previous.combat) == "table"
        and tonumber(previous.combat.nextStart) or 0,
    tracks = setmetatable({}, { __mode = "k" }),
    fireModels = {} :: { [string]: any },
    fireWorker = nil,
    sent = 0, confirmed = 0, fireReleased = 0,
    fireFinished = 0, fireRevisited = 0,
    native = nil, module = nil, math = nil, settings = nil,
    axe = nil,
    axeStats = { sent = 0, confirmed = 0, lastDamage = 0, lastHP = 0 },
    fistsStats = { sent = 0, confirmed = 0, lastDamage = 0, lastHP = 0 },
    sawStats = { sent = 0, confirmed = 0, lastDamage = 0, lastHP = 0 },
    toolStats = {} :: { [string]: any },
    nativeModules = {} :: { [string]: any },
    slashAdapters = {} :: { [string]: any },
    nativeBridge = nil :: { [string]: any }?,
    sawThrottle = false,
    sawRefreshAt = 0,
    sawSwap = nil :: { [string]: any }?,
    sawSwapRetryAt = 0,
    sawSwapRejected = {} :: { [string]: number },
    lastAttempt = nil :: { [string]: any }?,
    lastDisplay = nil,
}
state.combat = combat

local function positive(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function confirmedRecovery(startedAt, profile)
    local now = os.clock()
    local before = math.max(0, combat.nextStart - now)
    local minimum = startedAt + (profile.minInterval or 0)
    local factor = profile.tool == "HellChain" and HELLCHAIN_RECOVERY_FACTOR or POST_HIT_RECOVERY_FACTOR
    combat.nextStart = math.max(now, minimum, now + before * factor)
    return before, math.max(0, combat.nextStart - now)
end

local function treeHP(tree)
    local hp = tree:GetAttribute("HP")
    return type(hp) == "number" and hp == hp and hp < math.huge and math.max(0, hp) or nil
end

-- Nur lesender Zugriff auf den bereits initialisierten Spielclient.
-- Dessen Blow übernimmt Trefferstelle, Slash-Slot und gemeinsame Treffersequenz.
local function resolveCombatData()
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local utilities = shared and shared:FindFirstChild("Utilities")
    local configs = shared and shared:FindFirstChild("Configs")
    if not combat.math and utilities and configs then
        local mathModule = utilities:FindFirstChild("UpgradeMath")
        local configModule = configs:FindFirstChild("Chopping")
        if not mathModule or not configModule then return false end
        combat.math = require(mathModule)
        combat.settings = require(configModule)
    end
    return combat.math ~= nil and combat.settings ~= nil
end

local function resolveCombat()
    if not resolveCombatData() then return false end
    local scripts = player:FindFirstChild("PlayerScripts")
    local client = scripts and scripts:FindFirstChild("Client")
    local extra = client and client:FindFirstChild("Extra")
    local chopping = extra and extra:FindFirstChild("Chopping")
    local module = chopping and chopping:FindFirstChild("HellChain")
    if not module then return false end
    if combat.module ~= module or not combat.native then
        local inspect = (getfenv() :: any).getupvalues or (debug :: any).getupvalues
        if type(inspect) ~= "function" then return false end
        local api = require(module)
        if type(api.Step) ~= "function" then return false end
        local native
        local basicTiming
        for _, value in pairs(inspect(api.Step)) do
            if type(value) == "table" then
                if type(value.Basics) == "table" and type(value.Blow) == "function" then
                    native = value
                elseif type(value.Poses) == "table" and positive(value.Speed) then
                    basicTiming = value
                end
            end
        end
        if not native then return false end
        local probe
        for _, value in pairs(inspect(native.Blow)) do
            if type(value) == "function" and debug.info(value, "n") == "probe" then
                probe = value
            end
        end
        if not probe then return false end
        local visualsModule = chopping:FindFirstChild("TreeVisuals")
        local visuals = visualsModule and require(visualsModule)
        if not visuals or type(visuals.FromInstance) ~= "function" or type(visuals.CanChop) ~= "function" then return false end
        combat.native = { controller = native, probe = probe, basicTiming = basicTiming, visuals = visuals }
        combat.module = module
    end
    return true
end

local function resolveAxe()
    if not resolveCombatData() then return false end
    local scripts = player:FindFirstChild("PlayerScripts")
    local client = scripts and scripts:FindFirstChild("Client")
    local extra = client and client:FindFirstChild("Extra")
    local chopping = extra and extra:FindFirstChild("Chopping")
    local main = chopping and chopping:FindFirstChild("Main")
    if not main then return false end
    if combat.axe and combat.axe.main == main then return true end
    local inspect = (getfenv() :: any).getupvalues or (debug :: any).getupvalues
    local list = (getfenv() :: any).getrendersteppedlist
    local setValue = (getfenv() :: any).setupvalue or (debug :: any).setupvalue
    if type(inspect) ~= "function" or type(list) ~= "function" or type(setValue) ~= "function" then return false end
    local function child(fn, name)
        if type(fn) ~= "function" then return nil end
        for _, value in pairs(inspect(fn)) do
            if type(value) == "function" and debug.info(value, "n") == name then return value end
        end
        return nil
    end
    local bound, renderPriority, undo
    for _, entry in pairs(list()) do
        if type(entry) == "table" and entry.Name == "ChopRender" and type(entry.Function) == "function" then
            bound = entry.Function
            renderPriority = entry.Priority or 201
        elseif type(entry) == "table" and entry.Name == "ChopCameraUndo" then
            undo = entry.Function
        end
    end
    local render = child(bound, "render")
    local step = child(render, "stepSwing")
    local want = child(step, "wantSwing")
    local heldIndex, clickIndex
    if want then
        local booleans, numbers = {}, {}
        for index, value in pairs(inspect(want)) do
            if type(value) == "boolean" then table.insert(booleans, index)
            elseif type(value) == "number" then table.insert(numbers, index) end
        end
        if #booleans == 1 and #numbers == 1 then heldIndex, clickIndex = booleans[1], numbers[1] end
    end
    local impact = child(step, "resolveImpact")
    local probe = child(impact, "probe")
    if not impact or not probe then return false end
    local swing
    for _, value in pairs(inspect(impact)) do
        if type(value) == "table" and type(value.State) == "string" and type(value.Side) == "number" then
            swing = value
            break
        end
    end
    local visualsModule = chopping:FindFirstChild("TreeVisuals")
    local visuals = visualsModule and require(visualsModule)
    if not swing or not visuals or type(visuals.FromInstance) ~= "function" then return false end
    local thirdPersonModule = chopping:FindFirstChild("ThirdPersonAnims")
    local bodyModule = chopping:FindFirstChild("BodyAnims")
    local stepSaw = child(render, "stepSaw")
    local sawCut = child(stepSaw, "sawCut")
    local sawState
    if sawCut then
        for _, value in pairs(inspect(sawCut)) do
            if type(value) == "table" and type(value.Cuts) == "number"
                and type(value.Cutting) == "boolean" then sawState = value end
        end
    end
    local effects
    for _, value in pairs(inspect(impact)) do
        if type(value) == "table" and type(value.Runtime) == "table"
            and type(value.Runtime.Heat) == "function" then effects = value.Runtime end
    end
    combat.axe = {
        effects = effects,
        main = main, probe = probe, swing = swing, visuals = visuals,
        bound = bound, priority = renderPriority, undo = undo,
        input = want, heldIndex = heldIndex, clickIndex = clickIndex,
        inspect = inspect, setValue = setValue,
        finish = function()
            for index, value in pairs(inspect(impact)) do
                if type(value) == "function" and getfenv(value).script == visualsModule then
                    setValue(impact, index, nil)
                    pcall(value)
                end
            end
        end,
        body = bodyModule and require(bodyModule), sawState = sawState,
        sawCut = sawCut,
        impact = function(aim)
            local before = inspect(impact)
            local hitStop, connected = impact(aim)
            -- Den nativen LocalHit-Abschluss einmal konsumieren, da hier kein
            -- manueller First-Person-Schlagzustand bis HitStop durchlaufen wird.
            for index, value in pairs(inspect(impact)) do
                if type(value) == "function" and value ~= before[index]
                    and getfenv(value).script == visualsModule then
                    setValue(impact, index, nil)
                    value()
                end
            end
            return hitStop, connected
        end,
        globals = getfenv(impact)._G,
        thirdPerson = thirdPersonModule and require(thirdPersonModule),
        ready = function(toolName)
            for _, value in pairs(inspect(impact)) do
                if value == combat.settings.Tools[toolName or "Axe"] then return true end
            end
            return false
        end,
    }
    return true
end

local function axeProfile(tree, preview)
    if not preview and player:GetAttribute("Tool") ~= "Axe" then return nil end
    if not resolveAxe() then return nil end
    local api = combat.math
    local tool = combat.settings.Tools.Axe
    local timing = combat.settings.Axe
    local scale = (tool.Swing or 1) * api.SwingScale(player, "Axe")
    local side = preview and 1 or combat.axe.swing.Side
    if side ~= 1 and side ~= -1 then return nil end
    local rawDamage = api.Damage(player, "Axe", tree and tree:GetAttribute("TreeType"), side)
    local frostDamage = tonumber(player:GetAttribute("FrostDamage")) or 1
    if not positive(scale) or not positive(rawDamage) or not positive(frostDamage)
        or not positive(timing.Windup) or not positive(timing.Strike) or not positive(timing.Recover) then return nil end
    local reach = math.min(tool.Reach, timing.Range, tool.ServerReach or tool.Reach, timing.ServerRange or timing.Range)
    return {
        tool = "Axe", damage = rawDamage * frostDamage, rawDamage = rawDamage, frostDamage = frostDamage,
        speedLevel = api.Level(player, "AxeSpeed"), sharpLevel = api.Level(player, "AxeSharp"),
        hold = api.Level(player, "AxeHold") > 0, scale = scale, side = side,
        minInterval = (tool.Interval or timing.MinInterval or 0) * scale,
        windup = (timing.Windup + timing.Strike) * scale,
        cycle = math.max((timing.Windup + timing.Strike + timing.Recover * timing.ChainAt) * scale
            + timing.HitStop, (tool.Interval or timing.MinInterval or 0) * scale),
        settle = math.clamp(0.08 * scale, 0.05, 0.08), reach = reach,
    }
end
combat.axeProfile = axeProfile

-- Fäuste nutzen FistTime direkt; Tools.Fists.Swing skaliert diese Animation nicht.
local function fistsProfile(tree, preview)
    if not preview and player:GetAttribute("Tool") ~= "Fists" then return nil end
    if not resolveAxe() then return nil end
    local native = combat.axe
    local timing = native.body and native.body.FistTime
    if type(timing) ~= "table" then return nil end
    local api, tool = combat.math, combat.settings.Tools.Fists
    local scale = api.SwingScale(player, "Fists")
    local side = preview and 1 or native.swing.Side
    if side ~= 1 and side ~= -1 then return nil end
    local damage = api.Damage(player, "Fists", tree and tree:GetAttribute("TreeType"), side)
    if not positive(scale) or not positive(damage) or not positive(timing.Windup)
        or not positive(timing.Strike) or not positive(timing.Recover) then return nil end
    return {
        tool = "Fists", label = "Fäuste", damage = damage, scale = scale, side = side,
        minInterval = tool.Interval or 0,
        windup = (timing.Windup + timing.Strike) * scale,
        recover = timing.Recover * timing.ChainAt * scale,
        cycle = math.max((timing.Windup + timing.Strike + timing.Recover * timing.ChainAt) * scale
            + combat.settings.Axe.HitStop, tool.Interval or 0),
        settle = math.clamp(0.08 * scale, 0.05, 0.08),
        reach = math.min(tool.Reach, tool.ServerReach or tool.Reach),
        hold = api.Holds(player, "Fists"),
    }
end
combat.fistsProfile = fistsProfile


-- Die serverseitige Hitze bleibt auch bei ausgerüstetem Ersatzwerkzeug lesbar.
local function sawHeatState()
    if not resolveCombatData() then return nil end
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local utilities = shared and shared:FindFirstChild("Utilities")
    local heatModule = utilities and utilities:FindFirstChild("SawHeat")
    if not heatModule then return nil end
    combat.sawHeat = combat.sawHeat or require(heatModule)
    local heatSpec = combat.math.Heat(player, "Chainsaw")
    if not heatSpec then return nil end
    local snapshot = combat.sawHeat.Read(player, {})
    local now = workspace:GetServerTimeNow()
    local heat, locked, remaining = combat.sawHeat.At(snapshot, heatSpec, now)
    local fullAt = combat.sawHeat.FullAt(snapshot)
    if not locked and fullAt <= now then
        locked = true
        remaining = math.max(0, combat.sawHeat.LockTime(heatSpec) - (now - fullAt))
    end
    return { heat = heat, locked = locked, coolRemaining = remaining, fullAt = fullAt, heatSpec = heatSpec }
end
combat.sawHeatState = sawHeatState

local function sawProfile(tree)
    if player:GetAttribute("Tool") ~= "Chainsaw" or not resolveAxe() then return nil end
    local native = combat.axe
    if not native.sawCut or not native.sawState then return nil end
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local utilities = shared and shared:FindFirstChild("Utilities")
    local heatModule = utilities and utilities:FindFirstChild("SawHeat")
    local services = shared and shared:FindFirstChild("Services")
    local remotes = services and services:FindFirstChild("ChopRemotes")
    local throttle = remotes and remotes:FindFirstChild("Throttle")
    if not heatModule or not throttle or not throttle:IsA("RemoteEvent") then return nil end
    combat.throttleRemote = throttle
    local tool, api = combat.settings.Tools.Chainsaw, combat.math
    local heatState = sawHeatState()
    local damage = api.Damage(player, "Chainsaw", tree and tree:GetAttribute("TreeType"), 1)
    if not positive(damage) or not positive(tool.Interval) or not heatState then return nil end
    return {
        tool = "Chainsaw", label = "Kettensäge", damage = damage, side = 1,
        -- Genau der native Sägetakt. Speed steckt bereits in UpgradeMath.Damage.
        cycle = tool.Interval * 1.02,
        engage = tonumber(tool.Engage) or 0.15, windup = 0, settle = 0.05,
        reach = math.min(tool.Reach, tool.ServerReach or tool.Reach),
        heat = heatState.heat, locked = heatState.locked, coolRemaining = heatState.coolRemaining,
        fullAt = heatState.fullAt, heatSpec = heatState.heatSpec,
        speedLevel = api.Level(player, "ChainsawSpeed"),
        coolingLevel = api.Level(player, "ChainsawCooling"),
        recoveryLevel = api.Level(player, "ChainsawRecovery"),
    }
end
combat.sawProfile = sawProfile

function combat.stopSaw()
    if not combat.sawThrottle then return end
    combat.sawThrottle = false
    combat.sawRefreshAt = 0
    if combat.throttleRemote then pcall(combat.throttleRemote.FireServer, combat.throttleRemote, false) end
end

local function startSaw()
    if not combat.throttleRemote then return false end
    local now = os.clock()
    if not combat.sawThrottle or now >= combat.sawRefreshAt then
        combat.throttleRemote:FireServer(true)
        combat.sawThrottle = true
        combat.sawRefreshAt = now + 0.5
    end
    return true
end

local function combatProfile(tree, preview)
    if not preview and player:GetAttribute("Tool") ~= "HellChain" then return nil end
    if not resolveCombat() then return nil end
    local mathApi = combat.math
    local tool = combat.settings.Tools.HellChain
    local native = combat.native.controller
    local clip = native.ClipBasic
    local isClip = clip ~= nil
    if not clip then
        local count = #native.Basics
        if count == 0 then return nil end
        clip = native.Basics[(native.BasicCombo or 0) % count + 1]
    end
    local spec = clip.Spec or {}
    local speed = isClip and spec.Speed or (combat.native.basicTiming and combat.native.basicTiming.Speed)
    local length = isClip and spec.ChainAt or clip.Length
    local upgrade = mathApi.Find("ChainPower")
    local level = mathApi.Level(player, "ChainPower")
    local scale = upgrade and upgrade.SwingStep and upgrade.SwingStep ^ level or 1
    local damage = mathApi.Damage(player, "HellChain", tree and tree:GetAttribute("TreeType"), spec.Side or 1)
    if not positive(speed) or not positive(length) or not positive(clip.Strike)
        or not positive(scale) or not positive(damage) then return nil end
    -- Kleine Zeitkürzung zusätzlich zur echten SwingStep-Skalierung:
    -- 2 % ohne Upgrade, bis 3 % bei vollständig ausgebauter ChainPower.
    local maxLevel = upgrade and type(upgrade.Prices) == "table" and #upgrade.Prices or 1
    local progress = math.clamp(level / math.max(1, maxLevel), 0, 1)
    local timingFactor = 0.98 - 0.01 * progress
    local nativeCycle = length / speed * scale
    local nativeWindup = clip.Strike / speed * scale
    local smoulder = tool.Smoulder or {}
    return {
        tool = "HellChain",
        damage = damage, level = level,
        minInterval = tonumber(tool.Interval) or 0,
        cycle = math.max(nativeCycle * timingFactor, tonumber(tool.Interval) or 0),
        windup = nativeWindup * timingFactor,
        settle = math.clamp(0.08 * scale, 0.05, 0.08),
        timingFactor = timingFactor, nativeCycle = nativeCycle, nativeWindup = nativeWindup,
        reach = math.min(tool.Reach, tool.ServerReach or tool.Reach),
        side = spec.Side or 1,
        fireDuration = tonumber(smoulder.Duration) or 0,
        fireTick = tonumber(smoulder.Tick) or 0,
        fireShare = tonumber(smoulder.Share) or 0,
        lashRange = (tool.Lash and tool.Lash.Range or 0) + mathApi.Add(player, "LashRange", "HellChain"),
    }
end


-- Werkzeugfamilien stammen aus der Spielkonfiguration, nicht aus Klassennamen.
local function nativeModuleFor(name)
    if combat.nativeModules[name] then return combat.nativeModules[name] end
    local main = combat.axe and combat.axe.main
    local module = main and main.Parent and main.Parent:FindFirstChild(name)
    if not module or not module:IsA("ModuleScript") then return nil end
    local ok, api = pcall(require, module)
    if ok and type(api) == "table" then combat.nativeModules[name] = api
return api end
    return nil
end

-- Direkter Trefferanschluss eines Angriffsmoduls, ohne dessen Menü-/Animationsschleife.
local function slashAdapter(name, module)
    if combat.slashAdapters[name] then return combat.slashAdapters[name] end
    if not module or type(module.Step) ~= "function" then return nil end
    local inspect = combat.axe.inspect
    local visited = {}
    local controller, clips
    local function visit(fn, depth)
        if visited[fn] or depth > 3 then return end
        visited[fn] = true
        for _, value in pairs(inspect(fn)) do
            if type(value) == "function" then
                visit(value, depth + 1)
            elseif type(value) == "table" then
                if type(value.Blow) == "function"
                    and (value.Tool == combat.settings.Tools[name] or value.Basics or value.Kit) then
                    controller = value
                end
                local first = value[1]
                if type(first) == "table" and positive(first.ChainAt)
                    and positive(first.Strike) and type(first.Side) == "number" then clips = value end
            end
        end
    end
    visit(module.Step, 0)
    if not controller or not clips then return nil end
    local result = { controller = controller, clips = clips }
    combat.slashAdapters[name] = result
    return result
end

local function genericProfile(tree, name)
    name = name or player:GetAttribute("Tool")
    if not resolveAxe() then return nil end
    local spec = combat.settings.Tools[name]
    if type(spec) ~= "table" or type(spec.Act) ~= "string" then return nil end
    local api = combat.math
    local timing = combat.settings[name] or {}
    local scale = api.SwingScale(player, name)
    if not positive(scale) then return nil end
    local module = spec.NoSwing and nativeModuleFor(name) or nil
    local stats = combat.toolStats[name]
    local comboIndex, side = 1, 1
    local clips = spec.NoSwing and spec.Slashes and slashAdapter(name, module) or nil
    if clips then
        comboIndex = ((stats and stats.comboIndex or 0) % #clips.clips) + 1
        side = clips.clips[comboIndex].Side
    elseif spec.Slashes then
        local count = timing.Combo and timing.Combo.Length or 3
        local reset = timing.Combo and timing.Combo.Reset or 1.2
        local previous = stats and stats.comboIndex or 0
        if not stats or os.clock() - (stats.lastSwingAt or 0) > reset then previous = 0 end
        comboIndex = previous % count + 1
        if comboIndex < count then side = comboIndex % 2 == 1 and 1 or -1
        elseif timing.M3Style == "Cleave" and spec.Cleave then side = 3
        elseif timing.M3Style == "Sweep" and spec.DoubleSweep then side = 4
        else side = 2 end
    end
    local damage = api.Damage(player, name, tree and tree:GetAttribute("TreeType"), side)
    local hp = tree and (tonumber(tree:GetAttribute("MaxHP")) or treeHP(tree))
    if spec.HitsToFell and positive(hp) then damage = hp / spec.HitsToFell end
    local axeLike = spec.AxeLike or spec.Cuts and not spec.Continuous
    if axeLike then damage = damage * (tonumber(player:GetAttribute("FrostDamage")) or 1) end
    local reach = math.min(spec.Reach or 0, spec.ServerReach or spec.Reach or 0)
    local family, windup, cycle = "Schlag", nil, nil
    local minimumDistance, activeThrow, recover, hitStopMultiplier
    if positive(damage) and not spec.NoSwing and not spec.Continuous then
        local anim
        if axeLike then
            anim = combat.settings.Axe
            scale = scale * (spec.Swing or 1)
        else
            local action = side == 4 and "DoubleSweep" or side == 3 and "Cleave" or side == 2 and "XSlash" or "Slash"
            anim = spec.Slashes and combat.axe.body.TimeFor(name, action) or combat.axe.body.FistTime
        end
        if not anim or not positive(anim.Windup) or not positive(anim.Strike) or not positive(anim.Recover) then return nil end
        local heavy = axeLike and spec.Heavy or {}
        windup = (anim.Windup * (heavy.Windup or 1) + anim.Strike * (heavy.Strike or 1)) * scale
        recover = anim.Recover * (heavy.Recover or 1) * (anim.ChainAt or 1) * scale
        hitStopMultiplier = heavy.HitStop or 1
        cycle = windup + recover + (combat.settings.Axe.HitStopFinal or 0) * hitStopMultiplier
        family = axeLike and "Axtsteuerung" or spec.Slashes and "Kombo-Steuerung" or "Schlagsteuerung"
    elseif positive(damage) and clips then
        local clip = clips.clips[comboIndex]
        local length = (spec.Swing or 1) * scale
        local speed = math.clamp(clip.ChainAt / math.max(0.05, length), 0.6, 3)
        windup = clip.Strike / speed
        cycle = math.max(length, clip.ChainAt / speed)
        recover = 0
        family = "Direkter Modul-Treffer"
    elseif positive(damage) then
        -- Unbekannte Modulformate behalten ihre eigene Zeitsteuerung.
        cycle = math.max(spec.Interval or 0, (spec.Swing or 1) * scale)
        windup = cycle
        family = spec.Continuous and "Dauerangriff" or "Angriffsmodul"
    elseif module and type(module.TryThrow) == "function" and positive(timing.ThrowRange or 0) then
        activeThrow = true
        reach = timing.ThrowRange
        minimumDistance = math.min(reach - 1, (timing.Radius or timing.MinRange or 4) + 2)
        cycle = (timing.Cooldown or 1) * api.Scale(player, "Cooldown", name)
        windup = (timing.Release or 0.25) + (timing.Fuse or 0)
        damage = hp or 1
        family = "Wurfmodul"
    elseif module and type(module.Step) == "function" and positive(timing.Range or 0)
        and positive(timing.BurnBase or 0) then
        reach = math.min(timing.Range, timing.ServerRange or timing.Range)
        windup = timing.CatchTime or 0.15
        cycle = windup + timing.BurnBase + (timing.BurnPerHP or 0) * (hp or 1)
        damage = hp or 1
        family = "Brennmodul"
    else
        return nil -- Sammelgeräte ohne Baumangriff sind keine Farmwaffen.
    end
    if not positive(damage) or not positive(reach) or not positive(cycle) then return nil end
    cycle = math.max(cycle, spec.Interval or 0)
    local heatSpec = spec.Heat and api.Heat(player, name)
    local heat, heatLocked = 0, false
    if heatSpec and combat.axe.effects then
        local ok, value, locked = pcall(combat.axe.effects.Heat, combat.axe.effects)
        if ok then heat, heatLocked = value, locked == true end
    end
    local coolingGrace = heatSpec and heatSpec.LockHold + 1 / heatSpec.LockCoolPerSecond + heatSpec.CoolDelay or 0
    return {
        tool = name, label = spec.DisplayName or name, class = spec.Class,
        family = family, damage = damage, reach = reach, windup = windup,
        cycle = cycle, settle = 0.08, scale = scale,
        minInterval = (spec.Interval or 0) * scale, minimumDistance = minimumDistance,
        activeThrow = activeThrow, module = module,
        silent = true, side = side, comboIndex = comboIndex, slash = clips,
        direct = not spec.NoSwing and not spec.Continuous or clips ~= nil,
        axeLike = axeLike, recover = recover, hitStopMultiplier = hitStopMultiplier or 1,
        heat = heat, heatLocked = heatLocked, hasRuntime = heatSpec and combat.axe.effects ~= nil,
        timeout = math.max(5, cycle * 3 + windup + coolingGrace + 3),
    }
end
combat.genericProfile = genericProfile

combat.profile = function(tree)
    local tool = player:GetAttribute("Tool")
    if tool == "Axe" then return axeProfile(tree) end
    if tool == "Fists" then return fistsProfile(tree) end
    if tool == "Chainsaw" then return sawProfile(tree) end
    local profile = combatProfile(tree)
    if profile then return profile end
    return genericProfile(tree)
end

-- Während des allgemeinen Angriffs erhält ausschließlich der normale
-- Chop-Renderer das Ziel. Kamera und ursprünglicher Renderer werden restauriert.
local function nativeCameraFrame(native, camera, frame, focus, callback, undoPrevious)
    local originalFrame, originalFocus = camera.CFrame, camera.Focus
    if undoPrevious and native.undo then
        for _, value in pairs(native.inspect(native.undo)) do
            if typeof(value) == "CFrame" then
                originalFrame = originalFrame * value:Inverse()
                break
            end
        end
    end
    camera.CFrame, camera.Focus = frame, focus
    local ok, message = pcall(callback)
    local kick = CFrame.identity
    if native.undo then
        for _, value in pairs(native.inspect(native.undo)) do
            if typeof(value) == "CFrame" then
                kick = value
                break
            end
        end
    end
    camera.CFrame, camera.Focus = originalFrame * kick, originalFocus
    return ok, message
end

function combat.stopNative()
    local bridge = combat.nativeBridge
    if not bridge then return end
    combat.nativeBridge = nil
    local native = bridge.native
    native.setValue(native.input, native.heldIndex, false)
    native.setValue(native.input, native.clickIndex, -math.huge)
    native.swing.State, native.swing.T, native.swing.Stop = "Idle", 0, 0
    native.finish()
    local run = game:GetService("RunService")
    -- Nur die eigene Registrierung ersetzen
    -- Zwischenzeitliche fremde Änderungen erhalten.
    local list = (getfenv() :: any).getrendersteppedlist
    for _, entry in pairs(list()) do
        if entry.Name == "ChopRender" and entry.Function == bridge.wrapper then
            run:UnbindFromRenderStep("ChopRender")
            local camera = workspace.CurrentCamera
            if camera then
                nativeCameraFrame(native, camera, camera.CFrame,
                    camera.CFrame * CFrame.new(0, 0, -10), function() native.bound(0) end, true)
            end
            run:BindToRenderStep("ChopRender", native.priority, native.bound)
            break
        end
    end
end

local function startNative(profile, aimFor, valid)
    combat.stopNative()
    local native = combat.axe
    if not native or not native.input or not native.heldIndex or not native.clickIndex or not native.undo then
        return nil, "Native Eingabesteuerung nicht verfügbar"
    end
    if native.swing.State ~= "Idle" then return nil, "Warte auf laufende Werkzeuganimation" end
    local bridge = { native = native, tool = profile.tool, lastThrow = -math.huge } :: { [string]: any }
    bridge.wrapper = function(dt)
        if combat.nativeBridge ~= bridge or bridge.error or not valid() then
            native.setValue(native.input, native.heldIndex, false)
            native.setValue(native.input, native.clickIndex, -math.huge)
            return
        end
        local camera = workspace.CurrentCamera
        local aim = camera and aimFor()
        if not aim then
            native.setValue(native.input, native.heldIndex, false)
            native.setValue(native.input, native.clickIndex, -math.huge)
            return
        end
        local active = os.clock() >= combat.nextStart
        native.setValue(native.input, native.heldIndex, active)
        native.setValue(native.input, native.clickIndex, active and os.clock() or -math.huge)
        local oldState = native.swing.State
        local ok, message = nativeCameraFrame(native, camera, aim, aim * CFrame.new(0, 0, -0.5), function()
            if active and profile.activeThrow and os.clock() - bridge.lastThrow >= 0.5 then
                bridge.lastThrow = os.clock()
                profile.module.TryThrow(aim)
            end
            native.bound(dt)
        end)
        if oldState == "Idle" and native.swing.State ~= "Idle" then bridge.lastSwingAt = os.clock() end
        if not ok then bridge.error = tostring(message) end
    end
    local run = game:GetService("RunService")
    combat.nativeBridge = bridge
    run:UnbindFromRenderStep("ChopRender")
    local ok, message = pcall(run.BindToRenderStep, run, "ChopRender", native.priority, bridge.wrapper)
    if not ok then
        combat.nativeBridge = nil
        run:BindToRenderStep("ChopRender", native.priority, native.bound)
        return nil, tostring(message)
    end
    return bridge
end

local function ownsFarmTool(toolName)
    -- Angebote und eine freischaltbare Klasse allein sind kein Werkzeugbesitz.
    return toolName == "Fists" or player:GetAttribute("Owns" .. toolName) == true
        or toolName == player:GetAttribute("Tool")
        or (tonumber(player:GetAttribute("TrialUntil_" .. toolName)) or 0) > workspace:GetServerTimeNow()
end

local function chooseSawFallback(tree)
    local best, bestScore
    local names = {}
    for name, spec in pairs(combat.settings.Tools) do
        if type(name) == "string" and type(spec) == "table" and spec.Act and name ~= "Chainsaw" then table.insert(names, name) end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        if not ownsFarmTool(name) or (combat.sawSwapRejected[name] or 0) > os.clock() then continue end
        local profile
        if name == "Axe" then profile = axeProfile(tree, true)
        elseif name == "HellChain" then profile = combatProfile(tree, true)
        elseif name == "Fists" then profile = fistsProfile(tree, true)
        else profile = genericProfile(tree, name) end
        if profile and positive(profile.damage) and positive(profile.cycle) then
            -- Nur bestätigte Grundschadensformeln vergleichen; unbekannte
            -- Feuer-Ticks fließen nicht als geschätzter Bonus in die Rangliste ein.
            local score = profile.damage / profile.cycle
            if not bestScore or score > bestScore then
                best, bestScore = name, score
            end
        end
    end
    return best, bestScore
end
combat.chooseSawFallback = chooseSawFallback

function combat.cancelSawSwap()
    combat.sawSwap = nil
    combat.sawSwapRetryAt = 0
end

local function requestFarmTool(toolName, ownerRunning)
    local running = ownerRunning or isRunning
    if not running() or not ownsFarmTool(toolName) then return false end
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local services = shared and shared:FindFirstChild("Services")
    local remotes = services and services:FindFirstChild("ChopRemotes")
    local equip = remotes and remotes:FindFirstChild("EquipTool")
    if not equip or not equip:IsA("RemoteEvent") then return false end
    local revision = state.revision
    local character = player.Character
    local before = player:GetAttribute("Tool")
    combat.stopSaw()
    equip:FireServer(toolName)
    local deadline = os.clock() + 2.5
    repeat
        if not running() or not ownerRunning and state.revision ~= revision or player.Character ~= character then return false end
        local current = player:GetAttribute("Tool")
        if current == toolName then return true end
        if current ~= before then return false end
        task.wait()
    until os.clock() >= deadline
    return false
end


local function useBestFallback(tree, rememberSaw, heat)
    combat.stopSaw()
    local fallback, score = chooseSawFallback(tree)
    if not fallback then
        setStatus("Warte auf ein verfügbares Ersatzwerkzeug …")
        task.wait(0.1)
        return true
    end
    local current = player:GetAttribute("Tool")
    if current == fallback then
        if rememberSaw then combat.sawSwap = { fallback = fallback, score = score, at = os.clock() } end
        return false
    end
    if os.clock() < combat.sawSwapRetryAt then
        setStatus("Warte auf nächsten Werkzeugwechsel …")
        task.wait(0.1)
        return true
    end
    combat.sawSwapRetryAt = os.clock() + 3
    setStatus("Wechsle zum besten Ersatzwerkzeug · "
        .. (combat.settings.Tools[fallback].DisplayName or fallback))
    if requestFarmTool(fallback) then
        if rememberSaw then combat.sawSwap = { fallback = fallback, score = score, at = os.clock() } end
        combat.lastToolSwap = { from = current, to = fallback, heat = heat and heat.heat,
            score = score, at = os.clock(), mode = rememberSaw and "cooling" or "best-only" }
    else
        combat.sawSwapRejected[fallback] = os.clock() + 10
    end
    return true
end

local function updateSawToolChoice(tree)
    if not isRunning() then return false end
    if not config.ChainsawToolSwitch or not ownsFarmTool("Chainsaw") then
        combat.sawSwap = nil
        return useBestFallback(tree, false)
    end
    local current = player:GetAttribute("Tool")
    local swap = combat.sawSwap
    if swap and current ~= swap.fallback then
        combat.sawSwap = nil
        swap = nil
    end
    local heat = sawHeatState()
    if not heat then
        setStatus("Warte auf Kettensägen-Hitzedaten …")
        task.wait(0.1)
        return true
    end
    if swap then
        if not heat.locked and heat.heat <= SAW_RETURN_HEAT
            and os.clock() >= combat.sawSwapRetryAt
            and os.clock() >= (combat.sawSwapRejected.Chainsaw or 0) then
            combat.sawSwapRetryAt = os.clock() + 3
            setStatus("Kettensäge abgekühlt · wechsle zurück …")
            if requestFarmTool("Chainsaw") then
                combat.lastToolSwap = { from = current, to = "Chainsaw", heat = heat.heat, at = os.clock() }
                combat.sawSwap = nil
            else
                combat.sawSwapRejected.Chainsaw = os.clock() + 10
            end
            return true
        end
        return false
    end
    if (combat.sawSwapRejected.Chainsaw or 0) > os.clock() then
        return useBestFallback(tree, true, heat)
    end
    if heat.heat >= SAW_SWAP_HEAT or heat.locked then
        return useBestFallback(tree, true, heat)
    end
    if current == "Chainsaw" then return false end
    if os.clock() < combat.sawSwapRetryAt then
        task.wait(0.1)
        return true
    end
    combat.sawSwapRetryAt = os.clock() + 3
    setStatus("Kettensägen-Wechselmodus · rüste Kettensäge aus …")
    if requestFarmTool("Chainsaw") then
        combat.lastToolSwap = { from = current, to = "Chainsaw", heat = heat.heat, at = os.clock() }
    else
        combat.sawSwapRejected.Chainsaw = os.clock() + 10
    end
    return true
end
combat.updateSawToolChoice = updateSawToolChoice

local function refreshCombatDisplay()
    local handle = state.controls.CombatStats
    if not handle or not isAlive() then return end
    local profile = combat.profile()
    local text
    if profile and profile.tool == "Axe" then
        text = string.format("Axt · Schaden %.3f (Basis %.3f · Frost ×%.2f)\nSharpness %d · Speed %d · Hold %s\nSchlagabstand %.3f s · Treffer nach %.3f s · Reichweite %.1f\nRestpause nach bestätigtem Treffer −8 %%\nLetzter bestätigter HP-Abzug %.3f · Rest-HP %.3f",
            profile.damage, profile.rawDamage, profile.frostDamage, profile.sharpLevel, profile.speedLevel,
            profile.hold and "freigeschaltet" or "nicht gekauft", profile.cycle, profile.windup, profile.reach,
            combat.axeStats.lastDamage, combat.axeStats.lastHP)
    elseif profile and profile.tool == "Fists" then
        text = string.format("Fäuste · Schaden %.3f · Reichweite %.1f\nSchlagabstand %.3f s · Treffer nach %.3f s\nLetzter bestätigter HP-Abzug %.3f · Rest-HP %.3f",
            profile.damage, profile.reach, profile.cycle, profile.windup,
            combat.fistsStats.lastDamage, combat.fistsStats.lastHP)
    elseif profile and profile.tool == "Chainsaw" then
        text = string.format("Kettensäge · Schaden pro Sägetakt %.3f · Reichweite %.1f\nSägetakt %.3f s · Ansetzen %.3f s\nSpeed %d · Cooling %d · Recovery %d\nHitze %.0f %% · %s\nLetzter bestätigter HP-Abzug %.3f · Rest-HP %.3f",
            profile.damage, profile.reach, profile.cycle, profile.engage,
            profile.speedLevel, profile.coolingLevel, profile.recoveryLevel, profile.heat * 100,
            profile.locked and string.format("Abkühlen · %.1f s", profile.coolRemaining) or "bereit",
            combat.sawStats.lastDamage, combat.sawStats.lastHP)
    elseif profile and profile.tool ~= "HellChain" then
        local stats = combat.toolStats[profile.tool]
        text = string.format("%s · %s\nSchaden %.3f · Reichweite %.1f · Klasse %s\n%s\nLetzter bestätigter HP-Abzug %.3f",
            profile.label, profile.family, profile.damage, profile.reach, profile.class or "Standard",
            profile.direct and "Direkte Treffer ohne lokale Schlaganimation" or "Native Modulsteuerung", stats and stats.lastDamage or 0)
    elseif profile then
        text = string.format("ChainPower %d · Schaden %.3f · Schlag %.3f s · Treffer nach %.3f s\nZeitkürzung %.1f %% · Ankunftspause %.3f s\nRestpause nach bestätigtem Treffer −%.2f %%\nSchlagreichweite %.1f · Lash %.1f (Spezialfähigkeit)\nFeuer %.1f s / Tick %.2f s · Restschaden aus gespeicherten HP-Ticks",
            profile.level, profile.damage, profile.cycle, profile.windup,
            (1 - profile.timingFactor) * 100, profile.settle,
            (1 - HELLCHAIN_RECOVERY_FACTOR) * 100,
            profile.reach, profile.lashRange, profile.fireDuration, profile.fireTick)
    elseif player:GetAttribute("Tool") == "Axe" or player:GetAttribute("Tool") == "Fists"
        or player:GetAttribute("Tool") == "Chainsaw" then
        text = "Warte auf initialisierte Werkzeug- und Animationsdaten …"
    elseif player:GetAttribute("Tool") == "HellChain" then
        text = "Warte auf initialisierte HellChain- und Animationsdaten …"
    else
        text = "Werkzeugautomatik inaktiv · manuelle Abbauwerte gelten"
    end
    if combat.sawSwap then
        local heat = sawHeatState()
        if heat then text = text .. string.format("\nSäge kühlt im Hintergrund · %.0f %% · Rückwechsel bei %.0f %%", heat.heat * 100, SAW_RETURN_HEAT * 100) end
    end
    if state.abilityController and ownsFarmTool("Leviathan") then
        local ability = state.abilityController
        local left = ability.cooldownLeft()
        text = text .. string.format("\nWar-God-Wurf · %s · letzte Serverziele %d",
            ability.isFlying() and "Axt unterwegs" or left > 0 and string.format("%.1f s Cooldown", left) or "bereit",
            ability.lastFlight and ability.lastFlight.count or 0)
    end
    if text ~= combat.lastDisplay then
        handle:Set(text)
        combat.lastDisplay = text
    end
end

-- Messwerte nur zwischen identischen Baum-/Schadensprofilen wiederverwenden.
-- Smoulder.Share wird nicht als unbekannte Serverformel interpretiert.
local function fireModelKey(tree, profile)
    return table.concat({
        tostring(tree:GetAttribute("TreeType") or tree.Name),
        tostring(tree:GetAttribute("AreaIndex")), tostring(tree:GetAttribute("Mutation")),
        string.format("%.9g", tonumber(tree:GetAttribute("MaxHP")) or treeHP(tree) or 0),
        tostring(profile.level), string.format("%.9g", profile.damage),
        string.format("%.9g", profile.fireDuration), string.format("%.9g", profile.fireTick),
        tostring(profile.side), tostring(profile.fireShare),
    }, "|")
end

local function discardFire(tree, track)
    if track.connection then
        track.connection:Disconnect()
        track.connection = nil
    end
    if combat.tracks[tree] == track then combat.tracks[tree] = nil end
end

function combat.destroy()
    combat.stopNative()
    combat.stopSaw()
    combat.cancelSawSwap()
    local worker = combat.fireWorker
    combat.fireWorker = nil
    if worker and worker ~= coroutine.running() and coroutine.status(worker) ~= "dead" then
        pcall(task.cancel, worker)
    end
    for tree, track in pairs(combat.tracks) do discardFire(tree, track) end
end

local function observeFire(tree, track)
    if combat.tracks[tree] ~= track then return end
    local now = os.clock()
    local hp = treeHP(tree)
    if not hp then return end
    if hp > track.lastHP + 0.001 then
        discardFire(tree, track)
        skippedUntil[tree] = nil
        return
    end
    if hp < track.lastHP - 0.00001 then
        local delta = track.lastHP - hp
        if not track.confirmed then
            track.confirmed = true
            track.confirmedAt = now
            track.expires = track.expires or now + track.duration
            track.tickAt = track.tickAt or now
            combat.confirmed = combat.confirmed + 1
        elseif track.tick > 0 then
            local elapsed = now - track.changeAt
            if elapsed >= track.tick * 0.6 and elapsed <= track.tick * 1.5 then
                -- Ein tödlicher Tick ist nur eine Untergrenze, bleibt aber sicher nutzbar.
                if hp > 0 then
                    track.tickDamage = track.measuredFullTick and math.min(track.tickDamage, delta) or delta
                    track.measuredFullTick = true
                end
                track.tickAt = now
                local model = combat.fireModels[track.modelKey]
                if model then
                    if hp > 0 then
                        model.tickDamage = model.fullSample and math.min(model.tickDamage, delta) or delta
                        model.fullSample = true
                    elseif not model.fullSample then
                        model.tickDamage = math.max(model.tickDamage or 0, delta)
                    end
                    model.samples = (model.samples or 0) + 1
                end
            end
        end
        track.lastHP = hp
        track.changeAt = now
    end
end

local function remainingFire(track, now)
    if not track.confirmed or not track.tickDamage or not track.tickAt or track.tick <= 0 then return 0 end
    -- Nur zukünftige Ticks vor Brandende zählen; den Ablauf-Grenzfall ausschließen.
    local first = math.max(1, math.floor((now - track.tickAt) / track.tick) + 1)
    local last = math.floor((track.expires - track.tickAt - 0.00001) / track.tick)
    local count = math.max(0, last - first + 1)
    return count * track.tickDamage * 0.95
end
combat.remainingFire = remainingFire

local function releaseToFire(tree)
    local track = combat.tracks[tree]
    local hp = treeHP(tree)
    if not track or not hp or hp <= 0 or track.top ~= tree:FindFirstChild("Top", true) then return false end
    observeFire(tree, track)
    if combat.tracks[tree] ~= track then return false end
    local remaining = remainingFire(track, os.clock())
    if remaining + 0.00001 < hp then return false end
    if track.pending then return true end
    track.pending = true
    track.releasedAt = os.clock()
    track.remainingAtRelease = remaining
    track.hpAtRelease = hp
    skippedUntil[tree] = track.expires + HIT_CONFIRM_TIMEOUT
    combat.fireReleased = combat.fireReleased + 1
    local trace = combat.lastAttempt
    if trace and trace.treeId == tree:GetAttribute("TreeId") then
        trace.stage = "fire-release"
        trace.fireRemaining = remaining
        trace.hpAfter = hp
    end
    setStatus("Brennt voraussichtlich zu Ende · " .. tree.Name)
    return true
end

local function calibrateFire(tree, track)
    if not track.confirmed or track.tickDamage
        or track.tick <= 0 or track.duration <= 0 then return end
    local model = combat.fireModels[track.modelKey]
    if not model or model.lastProbe and os.clock() - model.lastProbe < 10 then return end
    model.lastProbe = os.clock()
    local deadline = math.min(track.expires,
        track.confirmedAt + track.tick + math.clamp(HIT_CONFIRM_TIMEOUT, 0.1, 0.3))
    setStatus("Feuertick einmalig messen · " .. tree.Name)
    while isRunning() and combat.tracks[tree] == track and not track.tickDamage
        and track.top == tree:FindFirstChild("Top", true) and (treeHP(tree) or 0) > 0
        and os.clock() < deadline do
        observeFire(tree, track)
        task.wait()
    end
end

local function sweepFire()
    local now = os.clock()
    for tree, track in pairs(combat.tracks) do
        if tree.Parent then observeFire(tree, track) end
        if combat.tracks[tree] ~= track then continue end
        if not tree.Parent or tree:GetAttribute("Felled") or tree:GetAttribute("Doomed")
            or treeHP(tree) == 0 or track.top ~= tree:FindFirstChild("Top", true) then
            if track.pending then combat.fireFinished = combat.fireFinished + 1 end
            discardFire(tree, track)
            skippedUntil[tree] = nil
            treeRecovery[tree] = nil
        elseif now >= (track.expires or track.sentAt + track.duration) + HIT_CONFIRM_TIMEOUT then
            -- Prognosen sind vorläufig: überlebende Bäume sofort erneut zulassen.
            if track.pending then
                skippedUntil[tree] = nil
                combat.fireRevisited = combat.fireRevisited + 1
                local model = combat.fireModels[track.modelKey]
                if model then
                    model.tickDamage = nil
                    model.lastProbe = nil
                end
            end
            discardFire(tree, track)
        end
    end
end

combat.fireWorker = task.spawn(function()
    while isAlive() do
        sweepFire()
        task.wait(0.1)
    end
    combat.destroy()
end)

local function isAreaUnlocked(tree)
    local areaIndex = tree:GetAttribute("AreaIndex")
    local unlocked = workspace:GetAttribute("AreasUnlocked")

    -- Unbekannte oder noch nicht replizierte Gebiete nicht ansteuern.
    return type(areaIndex) == "number"
        and type(unlocked) == "number"
        and areaIndex >= 1
        and areaIndex % 1 == 0
        and unlocked >= 1
        and unlocked % 1 == 0
        and areaIndex <= unlocked
end

local function isAvailable(tree)
    return trees and tree:IsDescendantOf(trees)
        and isAreaUnlocked(tree)
        and (tree:IsA("Model") or tree:IsA("BasePart"))
        and not tree:GetAttribute("Felled")
        and not tree:GetAttribute("Doomed")
        and treeHP(tree) ~= 0
        and tree:FindFirstChild("Top", true) ~= nil
end

local function treePosition(tree)
    local base = tree:FindFirstChild("TrunkBase", true)
    if base and base:IsA("BasePart") then
        local half = base.Size / 2
        local frame = base.CFrame
        local verticalHalf = math.abs(frame.RightVector.Y) * half.X
            + math.abs(frame.UpVector.Y) * half.Y + math.abs(frame.LookVector.Y) * half.Z
        return Vector3.new(base.Position.X, base.Position.Y - verticalHalf + 3, base.Position.Z)
    end
    if tree:IsA("Model") then
        local cf, size = tree:GetBoundingBox()
        return Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2 + 3, cf.Position.Z)
    elseif tree:IsA("BasePart") then
        return tree.Position
    end
    return nil
end

-- Gemeinsame Bäume meiden: replizierte Treffer/Aktionen und sichtbare Anläufe anderer Spieler.
local function createTreeCoordinator()
    local flights: { [Instance]: any } = {}
    setmetatable(flights, { __mode = "k" })
    local coordinator = {
        alive = true,
        peers = {} :: { [number]: any }, previous = {} :: { [number]: any },
        flights = flights,
        current = nil :: Instance?, currentTop = nil :: Instance?, claimedAt = 0, claimClock = 0, nextRefresh = 0,
        connection = nil :: RBXScriptConnection?,
    }
    state.treeCoordinator = coordinator
    local function flat(vector) return Vector3.new(vector.X, 0, vector.Z) end
    local function actor(who)
        local character = who.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not root or not humanoid or humanoid.Health <= 0 or humanoid.Sit
            or who:GetAttribute("Down") == true then return nil end
        return root
    end
    local function actionWindow(who)
        local tool = who:GetAttribute("Tool")
        local spec = combat.settings and combat.settings.Tools and combat.settings.Tools[tool]
        local windup = spec and spec.Heavy and tonumber(spec.Heavy.Windup) or 1
        return math.clamp((spec and tonumber(spec.Swing) or 1) * windup + 1, 1.25, 5)
    end
    local function acting(who, since)
        if who:GetAttribute("GunOut") or who:GetAttribute("AxeOut") then return false end
        if who:GetAttribute("Revving") == true then
            if not since then return true end
            local visuals = combat.axe and combat.axe.visuals or combat.native and combat.native.visuals
            local hit = visuals and type(visuals.SawingBy) == "function" and visuals.SawingBy(who.UserId)
            if hit and hit.Tree == coordinator.current and (tonumber(hit.HitAt) or 0) >= coordinator.claimClock then return true end
        end
        local at = who:GetAttribute("ActAt")
        local kind = who:GetAttribute("ActKind")
        local age = type(at) == "number" and workspace:GetServerTimeNow() - at or math.huge
        return type(kind) == "string" and (kind == "Chop" or kind == "Punch" or kind == "Slash"
            or kind == "Heavy" or kind == "Saw" or kind == "Flame") and age >= -0.2 and age <= actionWindow(who)
            and (not since or at >= since)
    end
    function coordinator.setTarget(tree)
        local top = tree and tree:FindFirstChild("Top", true)
        if coordinator.current ~= tree or coordinator.currentTop ~= top then
            coordinator.current, coordinator.currentTop = tree, top
            coordinator.claimedAt = workspace:GetServerTimeNow()
            coordinator.claimClock = os.clock()
        end
    end
    function coordinator.clear()
        coordinator.setTarget(nil)
        coordinator.nextRefresh = 0
    end
    function coordinator.destroy()
        coordinator.alive = false
        if coordinator.connection then coordinator.connection:Disconnect(); coordinator.connection = nil end
        table.clear(coordinator.peers)
        table.clear(coordinator.previous)
        for tree in pairs(coordinator.flights) do coordinator.flights[tree] = nil end
        coordinator.current = nil
    end
    local function refresh()
        local now = os.clock()
        if now < coordinator.nextRefresh then return end
        coordinator.nextRefresh = now + 0.1
        local peers, previous = {}, {}
        local visuals = combat.axe and combat.axe.visuals or combat.native and combat.native.visuals
        for _, who in ipairs(Players:GetPlayers()) do
            if who == player then continue end
            local root = actor(who)
            if not root then continue end
            local position = root.Position
            local prior = coordinator.previous[who.UserId]
            local motion = prior and prior.root == root and now > prior.at and flat(position - prior.position) / (now - prior.at)
                or flat(root.AssemblyLinearVelocity)
            previous[who.UserId] = { position = position, at = now, root = root }
            local facing = flat(root.CFrame.LookVector)
            facing = facing.Magnitude > 0.001 and facing.Unit or Vector3.new(0, 0, -1)
            local tool = who:GetAttribute("Tool")
            local spec = combat.settings and combat.settings.Tools and combat.settings.Tools[tool]
            local range = spec and (spec.ServerReach or spec.Reach)
            if tool == "Flamethrower" and combat.settings and combat.settings.Flamethrower then
                range = combat.settings.Flamethrower.ServerRange or combat.settings.Flamethrower.Range or range
            end
            local reach = math.clamp(tonumber(range) or 8, 3, 18) + 1
            local peer = { player = who, root = root, position = position, active = acting(who), target = nil,
                approaching = false }
            if trees and not who:GetAttribute("GunOut") and not who:GetAttribute("AxeOut") then
                if visuals and type(visuals.SawingBy) == "function" then
                    local hit = visuals.SawingBy(who.UserId)
                    local tree = hit and hit.Tree
                    local at = tree and isAvailable(tree) and treePosition(tree)
                    if at and math.abs(at.Y - position.Y) <= 7 and flat(at - position).Magnitude <= reach + 3 then
                        peer.target, peer.active = tree, true
                    end
                end
                if not peer.target and (peer.active or motion.Magnitude > 1) then
                    local best = math.huge
                    for _, tree in ipairs(trees:GetChildren()) do
                        if not isAvailable(tree) then continue end
                        local at = treePosition(tree)
                        if not at or math.abs(at.Y - position.Y) > 7 then continue end
                        local offset = flat(at - position)
                        local distance = offset.Magnitude
                        if distance <= 0.1 or distance > reach then continue end
                        local alignment = facing:Dot(offset.Unit)
                        if alignment < 0.7 then continue end
                        local score = distance * (1 + (1 - alignment) * 2)
                        if score < best then
                            best = score
                            peer.target = tree
                            peer.approaching = motion:Dot(offset.Unit) > 1
                        end
                    end
                end
            end
            table.insert(peers, peer)
        end
        coordinator.peers, coordinator.previous = peers, previous
    end
    function coordinator.isOccupied(tree)
        if not coordinator.alive then return false end
        refresh()
        local flight = coordinator.flights[tree]
        if flight then
            if os.clock() < flight.expires and flight.player.Parent == Players and actor(flight.player) then return true end
            coordinator.flights[tree] = nil
        end
        local root, at
        for _, peer in ipairs(coordinator.peers) do
            if peer.target ~= tree then continue end
            if peer.active then
                local mine = coordinator.current == tree and acting(player, coordinator.claimedAt)
                -- Bei gleichzeitig gestarteten Schlägen gewinnt dieselbe UserId auf beiden Clients.
                if not mine or peer.player.UserId < player.UserId then return true end
            elseif peer.approaching then
                root = root or actor(player)
                at = at or treePosition(tree)
                if not root or not at then continue end
                local theirDistance = flat(peer.position - at).Magnitude
                local myDistance = flat(root.Position - at).Magnitude
                if theirDistance + 1 < myDistance
                    or math.abs(theirDistance - myDistance) <= 1 and peer.player.UserId < player.UserId then return true end
            end
        end
        return false
    end
    function coordinator.throwSafe(plan, spec, origin)
        refresh()
        local foreign = {}
        for _, peer in ipairs(coordinator.peers) do
            if peer.target and (peer.active or peer.approaching) and coordinator.isOccupied(peer.target) then
                foreign[peer.target] = true
            end
        end
        for tree, flight in pairs(coordinator.flights) do
            if os.clock() < flight.expires and flight.player.Parent == Players then foreign[tree] = true end
        end
        local range = tonumber(spec.Range) or 100
        local chainRange = tonumber(spec.ChainRange) or 170
        local hop = (tonumber(spec.HopRange) or 34) + 2
        local cone = math.cos(math.rad(math.max(tonumber(spec.Cone) or 32, tonumber(spec.RightCone) or 10)))
        for tree in pairs(foreign) do
            if not isAvailable(tree) then continue end
            local at = treePosition(tree)
            local offset = at and flat(at - origin)
            if not offset or offset.Magnitude > chainRange then continue end
            if offset.Magnitude <= range and (offset.Magnitude < 0.1 or offset.Unit:Dot(plan.direction) >= cone) then
                return false
            end
            for _, selected in ipairs(plan.trees) do
                local position = treePosition(selected)
                if position and flat(position - at).Magnitude <= hop then return false end
            end
        end
        return true
    end
    function coordinator.positionClear(position)
        if not coordinator.alive then return true end
        refresh()
        for _, peer in ipairs(coordinator.peers) do
            if math.abs(position.Y - peer.position.Y) < 5
                and flat(position - peer.position).Magnitude < 3.25 then return false end
        end
        return true
    end
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local services = shared and shared:FindFirstChild("Services")
    local remotes = services and services:FindFirstChild("ChopRemotes")
    local flight = remotes and remotes:FindFirstChild("AxeFlight")
    if flight then
        coordinator.connection = flight.OnClientEvent:Connect(function(who, _points, times, targets)
            if not isAlive() or who == player or typeof(who) ~= "Instance" or not who:IsA("Player")
                or type(times) ~= "table" or type(targets) ~= "table" then return end
            local backAt = times[#times]
            if not positive(backAt) then return end
            local expires = os.clock() + math.clamp(backAt - workspace:GetServerTimeNow() + 0.8, 0.1, 8)
            for _, tree in pairs(targets) do
                if typeof(tree) == "Instance" and isAvailable(tree) then
                    coordinator.flights[tree] = { player = who, expires = expires }
                end
            end
        end)
    end
    return coordinator
end
local treeCoordinator = createTreeCoordinator()

local function nativeTreeState(tree)
    local adapter = player:GetAttribute("Tool") ~= "HellChain" and combat.axe or combat.native
    local visuals = adapter and adapter.visuals
    local base = tree:FindFirstChild("TrunkBase", true)
    return visuals and base and visuals.FromInstance(base) or nil
end

local function hitPosition(tree, fallback)
    local data = nativeTreeState(tree)
    local adapter = player:GetAttribute("Tool") ~= "HellChain" and combat.axe or combat.native
    local visuals = adapter and adapter.visuals
    if data and typeof(data.Root) == "CFrame" and visuals and type(visuals.CutYFor) == "function" then
        local cutY = visuals.CutYFor(data, fallback)
        if type(cutY) == "number" and cutY == cutY and math.abs(cutY) < math.huge then
            return data.Root:PointToWorldSpace(Vector3.new(0, cutY, 0))
        end
    end
    return fallback
end

local function retryTree(tree, recovery, reason)
    recovery.failures = recovery.failures + 1
    recovery.reason = reason
    skippedUntil[tree] = os.clock() + TREE_RETRY_AFTER
    setStatus(reason .. " · neuer Anlauf in " .. TREE_RETRY_AFTER .. " s")
end

local function resolveWorld()
    local map = workspace:FindFirstChild("Map")
    trees = map and map:FindFirstChild("Trees")
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local services = shared and shared:FindFirstChild("Services")
    local remotes = services and services:FindFirstChild("ChopRemotes")
    Swing = remotes and remotes:FindFirstChild("Swing")
    Chop = remotes and remotes:FindFirstChild("Chop")
    return trees and Swing and Swing:IsA("RemoteEvent") and Chop and Chop:IsA("RemoteEvent")
end

local function nearestTree(root)
    sweepFire()
    local nearest
    local bestSquared = math.huge
    local now = os.clock()
    local nextRetry = math.huge
    for _, tree in ipairs(trees:GetChildren()) do
        if isAvailable(tree) and not treeCoordinator.isOccupied(tree) then
            local position = treePosition(tree)
            if position then
                local offset = root.Position - position
                local squared = offset:Dot(offset)
                local readyAt = skippedUntil[tree] or 0
                if readyAt <= now and squared < bestSquared then
                    nearest = tree
                    bestSquared = squared
                elseif readyAt > now then
                    nextRetry = math.min(nextRetry, readyAt)
                end
            end
        end
    end
    treeCoordinator.setTarget(nearest)
    return nearest, nextRetry
end

local function validTarget(tree, character, root, humanoid, revision)
    return isRunning()
        and state.revision == revision
        and player.Character == character
        and root:IsDescendantOf(character)
        and humanoid.Health > 0
        and isAvailable(tree)
        and not treeCoordinator.isOccupied(tree)
end

local function approachTree(tree, character, root, humanoid, revision, profile)
    if not validTarget(tree, character, root, humanoid, revision) then return nil end
    local position = treePosition(tree)
    if not position then return nil end
    local direction = Vector3.new(root.Position.X - position.X, 0, root.Position.Z - position.Z)
    direction = direction.Magnitude > 0.01 and direction.Unit or Vector3.new(1, 0, 0)
    local recovery = profile and treeRecovery[tree]
    if recovery then
        recovery.angle = recovery.angle or math.atan2(direction.Z, direction.X)
        local angle = recovery.angle + (recovery.failures % 4) * math.pi / 2
        direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
    end
    local maxDistance = profile and math.min(config.MaxChopDistance, profile.reach - 0.25) or config.MaxChopDistance
    if profile and profile.minimumDistance then maxDistance = profile.reach - 0.25 end
    local clearance = TREE_DISTANCE + (recovery and math.min(1, recovery.failures * 0.35) or 0)
    if profile and profile.minimumDistance then clearance = math.max(clearance, profile.minimumDistance) end
    local destination = position + direction * math.min(clearance, maxDistance)
    if not treeCoordinator.positionClear(destination) then
        local radius = math.min(clearance, maxDistance)
        local best, bestDistance
        for i = 0, 7 do
            local angle = i * math.pi / 4
            local candidate = position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            local distance = (candidate - root.Position).Magnitude
            if treeCoordinator.positionClear(candidate) and (not bestDistance or distance < bestDistance) then
                best, bestDistance = candidate, distance
            end
        end
        if not best then return nil end
        destination = best
    end
    local lookAt = Vector3.new(position.X, destination.Y, position.Z)
    local duration = math.clamp(
        (root.Position - destination).Magnitude / config.Speed,
        config.MinTweenTime,
        config.MaxTweenTime
    )
    local tween = TweenService:Create(
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        { CFrame = CFrame.lookAt(destination, lookAt) }
    )
    state.tween = tween
    tween:Play()
    setStatus("Unterwegs · " .. tree.Name)

    while tween.PlaybackState == Enum.PlaybackState.Playing do
        if not validTarget(tree, character, root, humanoid, revision)
            or not treeCoordinator.positionClear(destination) then
            tween:Cancel()
            break
        end
        if profile and player:GetAttribute("Tool") ~= (profile.tool or "HellChain") then
            tween:Cancel()
            break
        end
        task.wait()
    end
    if state.tween == tween then state.tween = nil end

    if tween.PlaybackState ~= Enum.PlaybackState.Completed
        or not validTarget(tree, character, root, humanoid, revision) then
        return nil
    end
    local positionNow = treePosition(tree)
    if positionNow and (root.Position - positionNow).Magnitude <= maxDistance then
        return positionNow
    end
    return nil
end

local function automaticTree(tree, character, root, humanoid, revision, initialProfile)
    local profile = initialProfile
    local initialHP = treeHP(tree)
    if not initialHP then
        skippedUntil[tree] = os.clock() + 1
        setStatus("Warte auf Baum-HP · " .. tree.Name)
        task.wait(0.1)
        return
    end
    local recovery = treeRecovery[tree]
    if not recovery then
        recovery = { failures = 0 }
        treeRecovery[tree] = recovery
    end
    local trace = { treeId = tree:GetAttribute("TreeId"), stage = "approach", hpBefore = initialHP } :: { [string]: any }
    combat.lastAttempt = trace
    local budget = math.clamp(math.ceil(initialHP / profile.damage) + 3, 3, 100)
    local function contextValid()
        return isRunning() and state.revision == revision
            and player.Character == character and root:IsDescendantOf(character)
            and humanoid.Health > 0
            and player:GetAttribute("Tool") == "HellChain"
    end
    local function valid()
        return contextValid() and isAvailable(tree) and not treeCoordinator.isOccupied(tree)
    end
    local function waitForNative()
        local deadline = os.clock() + 2.5
        while contextValid() and tree:IsDescendantOf(trees) and treeHP(tree) ~= 0
            and not tree:GetAttribute("Felled") do
            local track = combat.tracks[tree]
            if track then observeFire(tree, track) end
            local data = nativeTreeState(tree)
            if data and combat.native.visuals.CanChop(data) then return true end
            if os.clock() >= deadline then return false end
            trace.stage = "reconcile"
            setStatus("Warte auf Server / lokale Fällvorschau · " .. tree.Name)
            task.wait(0.05)
        end
        return false
    end
    local position = approachTree(tree, character, root, humanoid, revision, profile)
    if not valid() then return end
    if not position then
        retryTree(tree, recovery, "Anlauf nicht in Schlagreichweite")
        return
    end
    trace.arrivedAt = os.clock()
    trace.stage = "settle"
    -- Swing erst nach abgeschlossener Anreise und einer kurzen Replikationspause.
    -- Bei einem fehlgeschlagenen Anlauf zusätzlich etwas Zeit zum Einrasten geben.
    task.wait(recovery.failures > 0 and math.min(0.35, 0.1 + recovery.failures * 0.1) or profile.settle)

    for _ = 1, budget do
        if not valid() or releaseToFire(tree) then return end
        if not waitForNative() then
            if valid() then retryTree(tree, recovery, "Baumdarstellung noch nicht bereit") end
            return
        end
        if not valid() then return end
        profile = combatProfile(tree)
        if not profile then return end
        while valid() and os.clock() < combat.nextStart do
            local track = combat.tracks[tree]
            if track then observeFire(tree, track) end
            if releaseToFire(tree) then return end
            task.wait()
        end
        if not valid() then return end
        -- Ein während der Wartezeit gekauftes Upgrade vor diesem Swing übernehmen.
        profile = combatProfile(tree)
        if not profile then return end
        position = treePosition(tree)
        local range = math.min(config.MaxChopDistance, profile.reach - 0.25)
        if not position or (root.Position - position).Magnitude > range then
            retryTree(tree, recovery, "Position vor dem Schlag verlassen")
            return
        end
        local startedAt = os.clock()
        combat.nextStart = startedAt + profile.cycle
        trace.swingAt = startedAt
        trace.distanceAtSwing = (root.Position - position).Magnitude
        trace.stage = "windup"
        Swing:FireServer(1)
        repeat
            task.wait()
            local track = combat.tracks[tree]
            if track then observeFire(tree, track) end
            if releaseToFire(tree) then return end
        until not valid() or os.clock() >= startedAt + profile.windup
        if not valid() then return end

        position = treePosition(tree)
        if not position or (root.Position - position).Magnitude > range then
            retryTree(tree, recovery, "Position während des Schlags verlassen")
            return
        end
        local aimAt = hitPosition(tree, position)
        if (aimAt - root.Position).Magnitude < 0.01 then
            retryTree(tree, recovery, "Kein gültiger Zielpunkt am Stamm")
            return
        end
        local aim = CFrame.lookAt(root.Position, aimAt)
        local kind, _, target = combat.native.probe(aim)
        if kind ~= "Tree" or not target or target.Tree ~= tree or not isAreaUnlocked(target.Tree) then
            retryTree(tree, recovery, "Stamm verdeckt · anderer Anlaufwinkel")
            return
        end
        local hpBefore = treeHP(tree)
        if not hpBefore or hpBefore <= 0 then return end
        local now = os.clock()
        local modelKey = fireModelKey(tree, profile)
        local model = combat.fireModels[modelKey]
        if not model then
            model = {}
            combat.fireModels[modelKey] = model
        end
        local oldTrack = combat.tracks[tree]
        local activeBurn = oldTrack and oldTrack.confirmed and oldTrack.expires and oldTrack.expires > now
        local tickDamage = model.tickDamage
        if activeBurn and oldTrack.modelKey ~= modelKey then
            tickDamage = tickDamage and oldTrack.tickDamage and math.min(tickDamage, oldTrack.tickDamage) or nil
        end
        local track = {
            top = tree:FindFirstChild("Top", true), lastHP = hpBefore,
            changeAt = now, sentAt = now, duration = profile.fireDuration,
            -- Ohne bestätigte Verlängerung die ältere Brandfrist beibehalten.
            expires = activeBurn and oldTrack.expires or nil,
            tickAt = activeBurn and oldTrack.tickAt or nil,
            tickDamage = tickDamage, modelKey = modelKey,
            tick = profile.fireTick, confirmed = false,
        }
        if oldTrack then discardFire(tree, oldTrack) end
        combat.tracks[tree] = track
        track.connection = tree:GetAttributeChangedSignal("HP"):Connect(function()
            if isAlive() then observeFire(tree, track) end
        end)
        trace.stage = "await-server"
        trace.sentAt = now
        setStatus(string.format("HellChain · %s · %.2f HP · Serverbestätigung", tree.Name, hpBefore))
        local accepted = combat.native.controller.Blow(aim, aim.RightVector, profile.side)
        if not accepted then
            discardFire(tree, track)
            if valid() then retryTree(tree, recovery, "Lokaler Treffer nicht bereit") end
            return
        end
        combat.sent = combat.sent + 1
        local deadline = now + HIT_CONFIRM_TIMEOUT
        repeat
            observeFire(tree, track)
            if not track.confirmed and tree:GetAttribute("Felled") then
                track.confirmed = true
                combat.confirmed = combat.confirmed + 1
            end
            if track.confirmed or not contextValid() then break end
            task.wait()
        until os.clock() >= deadline
        trace.hpAfter = treeHP(tree)
        trace.confirmed = track.confirmed
        if track.confirmed then
            trace.recoveryBefore, trace.recoveryAfter = confirmedRecovery(startedAt, profile)
            recovery.failures = 0
            skippedUntil[tree] = nil
            trace.stage = "confirmed"
            if valid() then
                calibrateFire(tree, track)
                if not valid() then return end
                if releaseToFire(tree) then return end
                trace.fireRemaining = remainingFire(track, os.clock())
                trace.hpAfter = treeHP(tree)
            end
        elseif contextValid() and isAvailable(tree) then
            -- Die lokale Vorschau wird vom Spiel nach ca. 2 s zurückgesetzt.
            -- Der nächste Besuch wartet darauf; kein weiterer Swing gegen diese Vorschau.
            trace.stage = "unconfirmed"
            retryTree(tree, recovery, "Treffer nicht vom Server bestätigt")
            return
        end
        if not valid() then
            if treeHP(tree) == 0 or tree:GetAttribute("Felled") then treeRecovery[tree] = nil end
            return
        end
    end
    if valid() then retryTree(tree, recovery, "Baum benötigt einen weiteren Anlauf") end
end

local function automaticAxeTree(tree, character, root, humanoid, revision, initialProfile)
    local profile = initialProfile
    local toolName = profile.tool
    local label = profile.label or (toolName == "Fists" and "Fäuste" or "Axt")
    local stats: { [string]: any }
    if toolName == "Fists" then stats = combat.fistsStats
    elseif toolName == "Axe" then stats = combat.axeStats
    else
        stats = combat.toolStats[toolName]
        if not stats then
            stats = { sent = 0, confirmed = 0, lastDamage = 0, lastHP = 0 }
            combat.toolStats[toolName] = stats
        end
    end
    local function getProfile(target)
        if toolName == "Fists" then return fistsProfile(target) end
        if toolName == "Axe" then return axeProfile(target) end
        return genericProfile(target, toolName)
    end
    local hp = treeHP(tree)
    if not hp or hp <= 0 then return end
    local recovery = treeRecovery[tree]
    if not recovery then
        recovery = { failures = 0 }
        treeRecovery[tree] = recovery
    end
    local trace = { tool = toolName, treeId = tree:GetAttribute("TreeId"), stage = "approach", hpBefore = hp } :: { [string]: any }
    stats.lastAttempt = trace
    local function contextValid()
        return isRunning() and state.revision == revision and player.Character == character
            and root:IsDescendantOf(character) and humanoid.Health > 0
            and player:GetAttribute("Tool") == toolName
    end
    local function valid() return contextValid() and isAvailable(tree) and not treeCoordinator.isOccupied(tree) end
    local position = approachTree(tree, character, root, humanoid, revision, profile)
    if not valid() then return end
    if not position then
        retryTree(tree, recovery, label .. " nicht in Schlagreichweite")
        return
    end
    trace.arrivedAt = os.clock()
    trace.stage = "settle"
    task.wait(recovery.failures > 0 and math.min(0.35, 0.1 + recovery.failures * 0.1) or profile.settle)
    local budget = math.clamp(math.ceil(hp / profile.damage) * 3 + 6, 6, 200)
    for _ = 1, budget do
        if not valid() then return end
        while valid() and os.clock() < combat.nextStart do task.wait() end
        if not valid() then return end
        local readyBy = os.clock() + 2.5
        while valid() do
            local native = combat.axe
            local data = nativeTreeState(tree)
            if native.ready(toolName) and native.swing.State == "Idle" and data
                and native.visuals.CanChop(data) then break end
            if os.clock() >= readyBy then
                retryTree(tree, recovery, label .. " · warte auf lokale Fällvorschau")
                return
            end
            task.wait()
        end
        if not valid() then return end
        profile = getProfile(tree)
        if not profile then return end
        while valid() and profile.heatLocked do
            setStatus(label .. " kühlt ab · " .. string.format("%.0f %%", profile.heat * 100))
            task.wait(0.1)
            profile = getProfile(tree)
            if not profile then return end
        end
        if not valid() then return end
        local native = combat.axe
        if profile.silent then native.swing.Side = profile.side end
        local range = math.min(config.MaxChopDistance, profile.reach - 0.25)
        position = treePosition(tree)
        if not position or (root.Position - position).Magnitude > range then
            retryTree(tree, recovery, label .. " · Position außerhalb der Reichweite")
            return
        end
        local aimAt = hitPosition(tree, position)
        if (aimAt - root.Position).Magnitude < 0.01 then
            retryTree(tree, recovery, label .. " · kein gültiger Schnittpunkt")
            return
        end
        local aim = CFrame.lookAt(root.Position, aimAt)
        local kind, _, target = native.probe(aim)
        if kind ~= "Tree" or not target or target.Tree ~= tree or not isAreaUnlocked(target.Tree) then
            retryTree(tree, recovery, label .. " · Stamm verdeckt · anderer Anlaufwinkel")
            return
        end
        local startedAt = os.clock()
        combat.nextStart = startedAt + profile.cycle
        trace.swingAt = startedAt
        trace.stage = "windup"
        trace.expectedHits = math.ceil((treeHP(tree) or 0) / profile.damage)
        trace.expectedDamage = profile.damage
        trace.distanceAtSwing = (root.Position - position).Magnitude
        Swing:FireServer(profile.side)
        if profile.hasRuntime and native.effects and type(native.effects.Swing) == "function" then
            native.effects:Swing(profile.side)
        end
        if not profile.silent and native.thirdPerson and type(native.thirdPerson.PlayLocal) == "function" then
            pcall(native.thirdPerson.PlayLocal, toolName == "Fists" and "Punch" or "Chop", profile.side)
        end
        repeat task.wait() until not valid() or os.clock() >= startedAt + profile.windup
        if not valid() then return end
        if not native.ready(toolName) or native.swing.State ~= "Idle" or native.swing.Side ~= profile.side then return end
        position = treePosition(tree)
        if not position or (root.Position - position).Magnitude > range then
            retryTree(tree, recovery, label .. " · Schlagposition verlassen")
            return
        end
        aimAt = hitPosition(tree, position)
        if (aimAt - root.Position).Magnitude < 0.01 then return end
        aim = CFrame.lookAt(root.Position, aimAt)
        kind, _, target = native.probe(aim)
        if kind ~= "Tree" or not target or target.Tree ~= tree or not isAreaUnlocked(target.Tree) then
            retryTree(tree, recovery, label .. " · Schnittpunkt nicht mehr frei")
            return
        end
        local hpBefore = treeHP(tree)
        if not hpBefore or hpBefore <= 0 then return end
        trace.hpBefore = hpBefore
        trace.sentAt = os.clock()
        trace.stage = "await-server"
        -- Derselbe Frost-Cleave-Aufruf wie beim normalen nativen Axt-Einschlag.
        local frost = native.globals and native.globals.FrostCleave
        if (toolName == "Axe" or profile.axeLike) and type(frost) == "table" and type(frost.Blow) == "function" then frost.Blow(toolName) end
        local hitStop, connected
        if profile.slash then
            connected = profile.slash.controller.Blow(aim, -aim.RightVector * profile.side, profile.side)
            hitStop = 0
        else
            hitStop, connected = native.impact(aim)
            if type(hitStop) == "number" then hitStop = hitStop * (profile.hitStopMultiplier or 1) end
        end
        if not connected then
            if valid() then retryTree(tree, recovery, label .. " · Treffer lokal nicht bereit") end
            return
        end
        stats.sent = stats.sent + 1
        if type(hitStop) == "number" and hitStop >= 0 then
            local timing = combat.settings.Axe
            combat.nextStart = math.max(combat.nextStart,
                startedAt + profile.windup + hitStop + (profile.recover or timing.Recover * timing.ChainAt * profile.scale))
        end
        setStatus(string.format("%s · %s · %.2f HP · voraussichtlich %d Treffer", label, tree.Name, hpBefore, trace.expectedHits))
        local deadline = trace.sentAt + HIT_CONFIRM_TIMEOUT
        repeat
            local after = treeHP(tree)
            if after and after < hpBefore - 0.00001 or tree:GetAttribute("Felled") then break end
            task.wait()
        until not contextValid() or os.clock() >= deadline
        local after = treeHP(tree)
        trace.hpAfter = after
        trace.confirmed = after ~= nil and after < hpBefore - 0.00001 or tree:GetAttribute("Felled") == true
        if trace.confirmed then
            if profile.silent then
                trace.recoveryBefore = math.max(0, combat.nextStart - os.clock())
                trace.recoveryAfter = trace.recoveryBefore
            else
                trace.recoveryBefore, trace.recoveryAfter = confirmedRecovery(startedAt, profile)
            end
            if profile.silent then
                stats.comboIndex = profile.comboIndex
                stats.lastSwingAt = startedAt
            end
            stats.confirmed = stats.confirmed + 1
            stats.lastDamage = math.max(0, hpBefore - (after or 0))
            stats.lastHP = after or 0
            trace.actualDamage = stats.lastDamage
            trace.remainingHits = trace.actualDamage > 0 and math.ceil((after or 0) / trace.actualDamage) or nil
            trace.stage = "confirmed"
            if toolName == "Fists" and native.ready(toolName) and native.swing.State == "Idle"
                and native.swing.Side == profile.side then native.swing.Side = -profile.side end
            recovery.failures = 0
            skippedUntil[tree] = nil
        elseif valid() then
            trace.stage = "unconfirmed"
            retryTree(tree, recovery, label .. " · Treffer nicht vom Server bestätigt")
            return
        end
        if not valid() then
            if after == 0 or tree:GetAttribute("Felled") then treeRecovery[tree] = nil end
            return
        end
    end
    if valid() then retryTree(tree, recovery, label .. " · Baum benötigt weiteren Anlauf") end
end

-- Die Säge verwendet den nativen sawCut: Schnittfläche, lokale Vorschau und
-- gemeinsame Treffersequenz bleiben dadurch mit dem Spielclient synchron.
local function automaticSawTree(tree, character, root, humanoid, revision, initialProfile)
    local profile = initialProfile
    local hp = treeHP(tree)
    if not hp or hp <= 0 then return end
    local recovery = treeRecovery[tree]
    if not recovery then
        recovery = { failures = 0 }
        treeRecovery[tree] = recovery
    end
    local stats = combat.sawStats
    local trace = { tool = "Chainsaw", treeId = tree:GetAttribute("TreeId"), stage = "approach", hpBefore = hp } :: { [string]: any }
    stats.lastAttempt = trace
    local function contextValid()
        return isRunning() and state.revision == revision and player.Character == character
            and root:IsDescendantOf(character) and humanoid.Health > 0
            and player:GetAttribute("Tool") == "Chainsaw"
    end
    local function valid() return contextValid() and isAvailable(tree) and not treeCoordinator.isOccupied(tree) end
    local position = approachTree(tree, character, root, humanoid, revision, profile)
    if not valid() then return end
    if not position then
        retryTree(tree, recovery, "Kettensäge nicht in Reichweite")
        return
    end
    trace.arrivedAt = os.clock()
    task.wait(profile.settle)
    local ok, message = xpcall(function()
        local engageAt = nil
        local cooling = false
        local nextCut = math.max(os.clock(), combat.nextStart)
        local readyBy = os.clock() + 2.5
        local budget = math.clamp(math.ceil(hp / profile.damage) * 3 + 6, 6, 200)
        local cuts = 0
        while valid() and cuts < budget do
            profile = sawProfile(tree)
            if not profile then return end
            if profile.heat >= SAW_SWAP_HEAT or profile.locked then
                trace.stage = "heat-tool-switch"
                updateSawToolChoice(tree)
                return
            end
            local native = combat.axe
            if not native.ready("Chainsaw") or native.swing.State ~= "Idle"
                or native.sawState.Sent then
                combat.stopSaw()
                engageAt = nil
                if os.clock() >= readyBy then
                    retryTree(tree, recovery, "Kettensäge wartet auf Werkzeugwechsel / manuellen Angriff")
                    return
                end
                task.wait()
                continue
            end
            readyBy = os.clock() + 2.5
            local serverNow = workspace:GetServerTimeNow()
            local slack = math.max(0.05, player:GetNetworkPing() - 0.25 + 0.05)
            if profile.locked or profile.fullAt - serverNow <= slack then cooling = true end
            if cooling then
                combat.stopSaw()
                engageAt = nil
                trace.stage = "cooling"
                trace.heat = profile.heat
                if not profile.locked and profile.heat <= 0.65 then
                    cooling = false
                else
                    setStatus(string.format("Kettensäge kühlt ab · %.0f %% Hitze", profile.heat * 100))
                    task.wait(0.1)
                    continue
                end
            end
            position = treePosition(tree)
            local range = math.min(config.MaxChopDistance, profile.reach - 0.25)
            if not position or (root.Position - position).Magnitude > range then
                retryTree(tree, recovery, "Kettensägenposition außerhalb der Reichweite")
                return
            end
            local data = nativeTreeState(tree)
            if not data or not native.visuals.CanChop(data) then
                combat.stopSaw()
                engageAt = nil
                local untilReady = os.clock() + 2.5
                repeat
                    task.wait()
                    data = nativeTreeState(tree)
                until not valid() or data and native.visuals.CanChop(data) or os.clock() >= untilReady
                if not valid() then return end
                if not data or not native.visuals.CanChop(data) then
                    retryTree(tree, recovery, "Kettensäge wartet auf lokale Fällvorschau")
                    return
                end
            end
            local aimAt = hitPosition(tree, position)
            if (aimAt - root.Position).Magnitude < 0.01 then return end
            local aim = CFrame.lookAt(root.Position, aimAt)
            local kind, hit, target = native.probe(aim)
            if kind ~= "Tree" or not hit or not target or target.Tree ~= tree
                or not isAreaUnlocked(target.Tree) then
                retryTree(tree, recovery, "Sägeschnitt verdeckt · anderer Anlaufwinkel")
                return
            end
            startSaw()
            if player:GetAttribute("Revving") ~= true then
                trace.stage = "await-throttle"
                engageAt = engageAt or os.clock()
                if os.clock() - engageAt > 2.5 then
                    retryTree(tree, recovery, "Säge vom Server noch nicht bereit")
                    return
                end
                task.wait()
                continue
            end
            if not engageAt or trace.stage == "await-throttle" then
                engageAt = os.clock()
                trace.stage = "engage"
            end
            if os.clock() < math.max(nextCut, engageAt + profile.engage) then
                task.wait()
                continue
            end
            local hpBefore = treeHP(tree)
            if not hpBefore or hpBefore <= 0 then return end
            -- Nur die vom nativen Schnitt benötigten Werte für diesen Aufruf setzen.
            local runtime = native.sawState
            local oldHit, oldShake = runtime.HitPos, runtime.ShakeMul
            runtime.HitPos = hit.Position
            runtime.ShakeMul = 1
            trace.sentAt = os.clock()
            trace.stage = "await-server"
            trace.hpBefore = hpBefore
            trace.expectedDamage = profile.damage
            trace.distanceAtCut = (root.Position - position).Magnitude
            trace.heatAtCut = profile.heat
            local cutOk, cutError = pcall(native.sawCut, target, aim)
            runtime.HitPos = oldHit
            runtime.ShakeMul = oldShake
            if not cutOk then error(cutError, 0) end
            stats.sent = stats.sent + 1
            cuts = cuts + 1
            nextCut = trace.sentAt + profile.cycle
            combat.nextStart = nextCut
            setStatus(string.format("Kettensäge · %s · %.2f HP · %.0f %% Hitze", tree.Name, hpBefore, profile.heat * 100))
            local deadline = trace.sentAt + HIT_CONFIRM_TIMEOUT
            repeat
                local after = treeHP(tree)
                if after and after < hpBefore - 0.00001 or tree:GetAttribute("Felled") then break end
                task.wait()
            until not contextValid() or os.clock() >= deadline
            local after = treeHP(tree)
            trace.hpAfter = after
            trace.confirmed = after ~= nil and after < hpBefore - 0.00001 or tree:GetAttribute("Felled") == true
            if trace.confirmed then
                stats.confirmed = stats.confirmed + 1
                stats.lastDamage = math.max(0, hpBefore - (after or 0))
                stats.lastHP = after or 0
                trace.actualDamage = stats.lastDamage
                trace.stage = "confirmed"
                recovery.failures = 0
                skippedUntil[tree] = nil
            elseif valid() then
                retryTree(tree, recovery, "Sägeschnitt nicht vom Server bestätigt")
                return
            end
        end
        if valid() then retryTree(tree, recovery, "Sägebaum benötigt einen weiteren Anlauf") end
    end, function(reason) return debug.traceback(tostring(reason), 2) end)
    combat.stopSaw()
    if not isAvailable(tree) then treeRecovery[tree] = nil end
    if not ok then error(message, 0) end
end

local function automaticNativeTree(tree, character, root, humanoid, revision, profile)
    local recovery = treeRecovery[tree]
    if not recovery then recovery = { failures = 0 }
treeRecovery[tree] = recovery end
    local stats = combat.toolStats[profile.tool]
    if not stats then stats = { confirmed = 0, lastDamage = 0 }
combat.toolStats[profile.tool] = stats end
    local function contextValid()
        return isRunning() and state.revision == revision and player.Character == character
            and root:IsDescendantOf(character) and humanoid.Health > 0
            and player:GetAttribute("Tool") == profile.tool
    end
    local function valid() return contextValid() and isAvailable(tree) and not treeCoordinator.isOccupied(tree) end
    local trace = { tool = profile.tool, treeId = tree:GetAttribute("TreeId"), stage = "approach" } :: { [string]: any }
    stats.lastAttempt = trace
    local position = approachTree(tree, character, root, humanoid, revision, profile)
    if not valid() then return end
    if not position then retryTree(tree, recovery, profile.label .. " nicht in Reichweite")
return end
    trace.arrivedAt = os.clock()
    task.wait(profile.settle)
    if not valid() then return end
    local function aimFor()
        local at = treePosition(tree)
        if not at then return nil end
        local maxDistance = profile.minimumDistance and profile.reach - 0.25
            or math.min(config.MaxChopDistance, profile.reach - 0.25)
        if (root.Position - at).Magnitude > maxDistance then return nil end
        local head = character:FindFirstChild("Head")
        local eye = head and head.Position or root.Position + Vector3.new(0, 1.5, 0)
        local hit = hitPosition(tree, at)
        return (hit - eye).Magnitude > 0.01 and CFrame.lookAt(eye, hit) or nil
    end
    trace.stage = "native-attack"
    local bridge, message = startNative(profile, aimFor, valid)
    if not bridge then retryTree(tree, recovery, message)
return end
    local ok, failure = xpcall(function()
        local hpBefore = treeHP(tree)
        local deadline = os.clock() + profile.timeout
        while contextValid() do
            if bridge.error then error(bridge.error, 0) end
            local after = treeHP(tree)
            if hpBefore and after and after < hpBefore - 0.00001 then
                stats.confirmed = stats.confirmed + 1
                stats.lastDamage = hpBefore - after
                trace.confirmed = true
                trace.hpBefore, trace.hpAfter, trace.actualDamage = hpBefore, after, stats.lastDamage
                trace.stage = "confirmed"
                combat.nextStart = math.max(combat.nextStart, (bridge.lastSwingAt or os.clock()) + profile.cycle)
                hpBefore = after
                recovery.failures = 0
                skippedUntil[tree] = nil
                deadline = os.clock() + profile.timeout
            end
            if not isAvailable(tree) or treeCoordinator.isOccupied(tree) then return end
            if not aimFor() then retryTree(tree, recovery, profile.label .. " hat die Schlagposition verloren")
return end
            if os.clock() >= deadline then
                retryTree(tree, recovery, profile.label .. " wartet auf bestätigten Schaden")
                return
            end
            setStatus(profile.label .. " · " .. tree.Name .. " · native Werkzeugsteuerung")
            task.wait()
        end
    end, function(reason) return debug.traceback(tostring(reason), 2) end)
    combat.stopNative()
    if not isAvailable(tree) then treeRecovery[tree] = nil end
    if not ok then error(failure, 0) end
end

-- Area-Guardian: eigene Kampfwerte statt der Baum-Schadenswerte.
local function createBossController()
    local controller = {
        job = nil :: { [string]: any }?,
        stats = { sent = 0, confirmed = 0, defeated = 0, advanced = 0 },
        rules = nil :: { [string]: any }?,
        warnings = {} :: { [number]: any },
        warningConnection = nil :: RBXScriptConnection?,
    }
    state.bossController = controller
    local function rules()
        if controller.rules then return controller.rules end
        if not resolveCombatData() then return nil end
        local shared = ReplicatedStorage:FindFirstChild("Shared")
        local configs = shared and shared:FindFirstChild("Configs")
        local module = configs and configs:FindFirstChild("NightMonsters")
        local services = shared and shared:FindFirstChild("Services")
        local remotes = services and services:FindFirstChild("ChopRemotes")
        if not module or not remotes then return nil end
        controller.rules = {
            settings = require(module), swing = remotes:FindFirstChild("Swing"), equip = remotes:FindFirstChild("EquipTool"),
            gun = remotes:FindFirstChild("GunFire"),
        }
        local fx = remotes:FindFirstChild("MonsterFx")
        if fx then
            controller.warningConnection = fx.OnClientEvent:Connect(function(kind, payload)
                if not isAlive() or kind ~= "Warn" or type(payload) ~= "table"
                    or payload.Kind == "Bomb" or payload.Kind == "Summon" or payload.Shape ~= "Circle" or payload.Id == nil
                    or typeof(payload.At) ~= "Vector3" or not positive(payload.Radius) then return end
                local signatureName = payload.Kind == "Petals" and "PetalCloud" or payload.Kind == "Frost" and "FrostRing" or payload.Kind
                local signature = controller.rules.settings.Signatures[signatureName]
                local lasts = signature and tonumber(signature.Lasts) or 0
                table.insert(controller.warnings, {
                    id = payload.Id, kind = payload.Kind, at = payload.At, radius = payload.Radius,
                    expires = os.clock() + math.max(0.15, tonumber(payload.Time) or 1) + math.max(0, lasts) + 0.25,
                })
                if #controller.warnings > 64 then table.remove(controller.warnings, 1) end
            end)
        end
        return controller.rules
    end
    local function livingBoss(area)
        local folder = workspace:FindFirstChild("Monsters")
        if not folder then return nil end
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") and model:GetAttribute("Monster") == "Guardian"
                and model:GetAttribute("Biome") == area and not model:GetAttribute("Event")
                and model:GetAttribute("Test") ~= true and not model:GetAttribute("DeadAt")
                and model:GetAttribute("State") ~= "Dead" then
                local hp = model:GetAttribute("HP")
                if positive(hp) then return model end
            end
        end
        return nil
    end
    controller.find = livingBoss
    local function bestWeapon(data, rejected)
        local best, score
        for name, spec in pairs(data.settings.Guns or {}) do
            if data.gun and type(spec) == "table" and positive(spec.Damage) and positive(spec.Rate)
                and player:GetAttribute("OwnsGun_" .. name) == true
                and (rejected["gun:" .. name] or 0) <= os.clock() then
                local value = spec.Damage * spec.Rate * (1 + combat.math.Perk(player, "GunDamage"))
                if not score or value > score then
                    best, score = { kind = "gun", name = name, reach = spec.Range,
                        interval = 1 / spec.Rate + 0.01, damage = spec.Damage, spec = spec }, value
                end
            end
        end
        for name, base in pairs(data.settings.Melee.Damage or {}) do
            local spec = combat.settings.Tools[name]
            if positive(base) and spec and positive(spec.Damage) and ownsFarmTool(name)
                and (rejected["melee:" .. name] or 0) <= os.clock() then
                local profile
                if name == "Axe" then profile = axeProfile(nil, true)
                elseif name == "Fists" then profile = fistsProfile(nil, true)
                elseif name == "HellChain" then profile = combatProfile(nil, true)
                else profile = genericProfile(nil, name) end
                if profile then
                    local multiplier = combat.math.Damage(player, name, nil, 1) / spec.Damage
                    if spec.AxeLike or name == "Axe" then multiplier = multiplier * (tonumber(player:GetAttribute("FrostDamage")) or 1) end
                    local value = base * multiplier / profile.cycle
                    if not score or value > score then
                        best, score = { kind = "melee", name = name, reach = profile.reach,
                            interval = profile.cycle, windup = profile.windup, damage = base * multiplier }, value
                    end
                end
            end
        end
        if best then best.score = score end
        return best
    end
    controller.bestWeapon = function()
        local data = rules()
        return data and bestWeapon(data, {}) or nil
    end
    local function cancelTween(job)
        local tween = job and job.tween
        if tween then
            pcall(tween.Cancel, tween)
            job.tween = nil
        end
    end
    local function releaseHover(job)
        if not job then return end
        if job.hoverForce then job.hoverForce:Destroy(); job.hoverForce = nil end
        if job.hoverAttachment then job.hoverAttachment:Destroy(); job.hoverAttachment = nil end
    end
    local function hover(job, root)
        if job.hoverRoot ~= root then releaseHover(job) end
        if not job.hoverForce then
            local attachment = Instance.new("Attachment")
            attachment.Name = "ForestControlBossHover"
            attachment.Parent = root
            local force = Instance.new("VectorForce")
            force.Name = "ForestControlBossHoverForce"
            force.Attachment0 = attachment
            force.RelativeTo = Enum.ActuatorRelativeTo.World
            force.ApplyAtCenterOfMass = true
            force.Parent = root
            job.hoverRoot, job.hoverAttachment, job.hoverForce = root, attachment, force
        end
        job.hoverForce.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
        local velocity = root.AssemblyLinearVelocity
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
    end
    function controller.stop()
        local job = controller.job
        controller.job = nil
        state.bossBusy = false
        if not job then return end
        cancelTween(job)
        releaseHover(job)
        local data = controller.rules
        if data and data.gun and job.changedGun then
            local out = player:GetAttribute("GunOut")
            if out == job.equippedGun or out == job.originalGun or out == nil then data.gun:FireServer("Equip", job.originalGun) end
        end
        if data and data.equip and job.equippedTool and job.equippedTool ~= job.originalTool then
            local tool = player:GetAttribute("Tool")
            if tool == job.equippedTool or tool == job.originalTool then data.equip:FireServer(job.originalTool) end
        end
        local unlocked = workspace:GetAttribute("AreasUnlocked")
        if type(unlocked) == "number" and unlocked > job.unlocked then
            controller.stats.advanced = controller.stats.advanced + 1
            if not job.defeated then controller.stats.defeated = controller.stats.defeated + 1 end
            controller.lastResult = { area = job.area, advanced = true, at = os.clock() }
        end
    end
    function controller.destroy()
        controller.stop()
        if controller.warningConnection then
            controller.warningConnection:Disconnect()
            controller.warningConnection = nil
        end
        table.clear(controller.warnings)
    end
    local function configure(job, data)
        local weapon = bestWeapon(data, job.rejected)
        if not weapon then return false end
        job.weapon = weapon
        job.nextAttack = os.clock() + 0.15
        if weapon.kind == "gun" then
            if not data.gun then return false end
            job.changedGun = player:GetAttribute("GunOut") ~= job.originalGun or weapon.name ~= job.originalGun
            job.equippedGun = weapon.name
            if player:GetAttribute("GunOut") ~= weapon.name then data.gun:FireServer("Equip", weapon.name) end
            local untilTime = os.clock() + 1.5
            repeat task.wait() until not isBossRunning() or not config.AutoBoss or controller.job ~= job
                or player:GetAttribute("GunOut") == weapon.name or os.clock() >= untilTime
            if player:GetAttribute("GunOut") ~= weapon.name then
                job.rejected["gun:" .. weapon.name] = os.clock() + 10
                job.weapon = nil
                return false
            end
            job.nextAttack = os.clock() + (weapon.spec.SpinUp or 0) + 0.15
        else
            if data.gun and player:GetAttribute("GunOut") then
                job.changedGun = true
                job.equippedGun = nil
                data.gun:FireServer("Equip", nil)
                task.wait(0.1)
            end
            job.equippedTool = weapon.name
            if player:GetAttribute("Tool") ~= weapon.name and not requestFarmTool(weapon.name, isBossRunning) then
                job.rejected["melee:" .. weapon.name] = os.clock() + 10
                job.weapon = nil
                return false
            end
        end
        return true
    end

    local function pose(model, frame)
        local pivot = model:GetPivot()
        local velocity = model:GetAttribute("MoveVel")
        if typeof(velocity) ~= "Vector3" or velocity.Magnitude ~= velocity.Magnitude then velocity = Vector3.zero end
        local from, at = model:GetAttribute("MoveFrom"), model:GetAttribute("MoveAt")
        local center = frame.Position
        if typeof(from) == "Vector3" and type(at) == "number" then
            center = from + velocity * math.max(0, workspace:GetServerTimeNow() - at) + (frame.Position - pivot.Position)
        end
        local face = model:GetAttribute("Face")
        local forward
        if type(face) == "number" and face == face then
            forward = CFrame.Angles(0, face, 0).LookVector
        elseif typeof(face) == "Vector3" then
            forward = face
        else
            forward = pivot.LookVector
        end
        forward = Vector3.new(forward.X, 0, forward.Z)
        forward = forward.Magnitude > 0.001 and forward.Unit or Vector3.new(0, 0, -1)
        local lead = math.clamp(player:GetNetworkPing() + 0.04, 0.05, 0.15)
        local predicted = center + Vector3.new(velocity.X, 0, velocity.Z) * lead
        return center, predicted, forward, velocity
    end
    local function rearGoal(rootPosition, center, predicted, forward, ring, radius)
        local lead = (predicted - center):Dot(forward)
        local maxLead = ring * 0.4
        if lead > maxLead then predicted = predicted - forward * (lead - maxLead) end
        local back = -forward
        local desired = predicted + back * ring
        local offset = Vector3.new(rootPosition.X - center.X, 0, rootPosition.Z - center.Z)
        local goal = desired
        -- Bei großen Drehungen seitlich um den Körper, statt quer durch ihn.
        if offset.Magnitude > 0.1 then
            local from = math.atan2(offset.Z, offset.X)
            local target = math.atan2(back.Z, back.X)
            local turn = (target - from + math.pi) % (2 * math.pi) - math.pi
            if math.abs(turn) > math.pi / 3 then
                local angle = from + math.clamp(turn, -math.pi / 2, math.pi / 2)
                local orbit = math.max(ring, radius + 6, offset.Magnitude)
                goal = predicted + Vector3.new(math.cos(angle), 0, math.sin(angle)) * orbit
            end
        end
        local ahead = (goal - center):Dot(forward)
        local lateral = (goal - center) - forward * ahead
        local minimumRear = math.max(0.5, ring * 0.3, lateral.Magnitude * 0.25)
        if ahead > -minimumRear then goal = goal - forward * (ahead + minimumRear) end
        local behind = offset.Magnitude > 0.1 and offset.Unit:Dot(forward) < -0.15
        return goal, behind, desired
    end
    local function circlesFor(model, center, data)
        local circles = {}
        local id = model:GetAttribute("MonsterId")
        for i = #controller.warnings, 1, -1 do
            local warning = controller.warnings[i]
            if os.clock() >= warning.expires then
                table.remove(controller.warnings, i)
            elseif id ~= nil and warning.id == id then
                table.insert(circles, warning)
            end
        end
        -- Falls erst während des Windups eingeschaltet: nur eindeutig bosszentrierte Angriffe schätzen.
        local anim = model:GetAttribute("Anim")
        local signature = data.settings.Signatures[anim]
        local at = model:GetAttribute("AnimAt")
        local speed = math.abs(tonumber(model:GetAttribute("AnimSpeed")) or 1)
        local age = type(at) == "number" and (workspace:GetServerTimeNow() - at) * speed or math.huge
        if #circles == 0 and (anim == "Stomp" or anim == "FrostRing") and signature
            and positive(signature.Radius) and age >= 0 and age < (signature.Windup or 1.25) + 0.25 then
            table.insert(circles, { at = center, radius = signature.Radius })
        end
        return circles
    end
    local function horizontal(vector)
        return Vector3.new(vector.X, 0, vector.Z)
    end
    local function outsideCircles(position, circles)
        for _, circle in ipairs(circles) do
            if horizontal(position - circle.at).Magnitude < circle.radius + 2 then return false end
        end
        return true
    end
    local function clearCircleGoal(goal, center, forward, circles)
        if outsideCircles(goal, circles) then return goal, false end
        local offset = horizontal(goal - center)
        local direction = offset.Magnitude > 0.01 and offset.Unit or -forward
        local distance = offset.Magnitude
        -- Entlang der sicheren Rückseite hinter den letzten überlappenden Warnkreis.
        for _ = 1, #circles + 1 do
            local changed = false
            for _, circle in ipairs(circles) do
                local relative = horizontal(circle.at - center)
                local projection = relative:Dot(direction)
                local perpendicular = math.max(0, relative:Dot(relative) - projection * projection)
                local radius = circle.radius + 2
                if perpendicular < radius * radius then
                    local half = math.sqrt(radius * radius - perpendicular)
                    if distance > projection - half and distance < projection + half then
                        distance = projection + half + 0.25
                        changed = true
                    end
                end
            end
            if not changed then break end
        end
        return center + direction * distance, true
    end
    local function clearCirclePath(start, goal, center, forward, circles)
        local function pathClear(target)
            local segment = horizontal(target - start)
            local lengthSquared = segment:Dot(segment)
            for _, circle in ipairs(circles) do
                local from = horizontal(start - circle.at)
                local radius = circle.radius + 1.9
                local fraction = lengthSquared > 0.001 and math.clamp(-from:Dot(segment) / lengthSquared, 0, 1) or 0
                local closest = from + segment * fraction
                -- Aus einem schon überdeckten Kreis sofort nach außen; außerhalb keine Abkürzung hindurch.
                local limit = math.min(radius * radius, from:Dot(from))
                if closest:Dot(closest) < limit - 0.01 then return false, circle end
            end
            return true
        end
        local clear, obstacle = pathClear(goal)
        if clear then return goal, false end
        local best, score
        local rearLimit = math.min(-0.1, horizontal(start - center):Dot(forward) + 0.5)
        for i = 0, 31 do
            local angle = i * math.pi / 16
            local candidate = obstacle.at + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (obstacle.radius + 2) * 1.6
            if horizontal(candidate - center):Dot(forward) <= rearLimit
                and outsideCircles(candidate, circles) and pathClear(candidate) then
                local cost = horizontal(candidate - start).Magnitude + horizontal(candidate - goal).Magnitude
                if not score or cost < score then best, score = candidate, cost end
            end
        end
        if best then return best, true end
        -- Bei überlappenden Flächen zunächst direkt vom blockierenden Kreis weg.
        local away = horizontal(start - obstacle.at)
        if away.Magnitude < 0.01 then away = -forward end
        return obstacle.at + away.Unit * (obstacle.radius + 2.5), true
    end
    controller.clearCirclePath = clearCirclePath
    controller.circlesFor = circlesFor
    controller.outsideCircles = outsideCircles
    controller.clearCircleGoal = clearCircleGoal
    controller.pose = pose
    controller.rearGoal = rearGoal
    local function move(job, root, destination, target, urgent, velocity)
        if os.clock() < (job.nextMove or 0) then return end
        job.nextMove = os.clock() + 0.03
        local delta = destination - root.Position
        local facing = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
        if delta.Magnitude < 0.3 and (facing.Magnitude < 0.01 or root.CFrame.LookVector:Dot(facing.Unit) > 0.98) then return end
        cancelTween(job)
        local speed = math.max(config.Speed, urgent and 150 or 100, velocity.Magnitude * 2 + 60)
        local duration = math.clamp(delta.Magnitude / speed, 0.04, urgent and 0.12 or 0.18)
        local look = Vector3.new(target.X, destination.Y, target.Z)
        if (look - destination).Magnitude < 0.01 then return end
        local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear),
            { CFrame = CFrame.lookAt(destination, look) })
        job.tween = tween
        tween:Play()
    end
    function controller.step(character, root, humanoid)
        if not config.AutoBoss or not isBossRunning() then controller.stop()
        return false end
        local data = rules()
        if not data then return false end
        local active = workspace:GetAttribute("GuardianActive")
        local area = workspace:GetAttribute("AreaCurrent")
        if type(active) ~= "string" or active ~= area then
            controller.stop()
            local left = type(area) == "string" and workspace:GetAttribute("AreaLeft_" .. area)
            if left == 0 and data.settings.Guardians[area] and not workspace:GetAttribute("Calmed_" .. area) then
                state.bossBusy = true
                setStatus("Area gerodet · warte auf Guardian …")
                task.wait(0.1)
                return true
            end
            return false
        end
        local model = livingBoss(active)
        local job = controller.job
        if job and (job.area ~= active or job.character ~= character) then controller.stop()
        job = nil end
        if not job then
            combat.stopSaw()
            combat.stopNative()
            cancelMovement()
            job = {
                area = active, character = character, unlocked = tonumber(workspace:GetAttribute("AreasUnlocked")) or 1,
                originalGun = player:GetAttribute("GunOut"), originalTool = player:GetAttribute("Tool"), detectedAt = os.clock(),
                nextAttack = 0, rejected = {}, lastHP = model and model:GetAttribute("HP"),
                lastDamageAt = os.clock(),
            }
            controller.job = job
        end
        state.bossBusy = true
        if not model then
            local previousHP = job.model and job.model:GetAttribute("HP")
            if (previousHP == 0 or job.model and job.model:GetAttribute("DeadAt")) and not job.defeated then
                job.defeated = true
                controller.stats.defeated = controller.stats.defeated + 1
            end
            cancelTween(job)
            releaseHover(job)
            setStatus("Guardian beendet · warte auf nächste Area …")
            task.wait(0.1)
            return true
        end
        job.model = model
        local hp = model:GetAttribute("HP")
        if job.lastHP and hp < job.lastHP then
            controller.stats.confirmed = controller.stats.confirmed + 1
            job.lastDamageAt = os.clock()
        end
        job.lastHP = hp
        if player:GetAttribute("Down") == true or (tonumber(player:GetAttribute("NightHP")) or 1) <= 0
            or player:GetAttribute("GuardianIntro") == true or player:GetAttribute("InCutscene") == true then
            cancelTween(job)
            releaseHover(job)
            setStatus("Guardian · warte auf Intro / spielbereiten Charakter …")
            task.wait(0.1)
            return true
        end
        if os.clock() - job.detectedAt < (data.settings.Guardian.Emerge or 3) then
            setStatus("Guardian erscheint …")
            task.wait(0.1)
            return true
        end
        if not job.weapon and not configure(job, data) then
            releaseHover(job)
            setStatus("Guardian · warte auf verfügbare Waffe …")
            task.wait(0.1)
            return true
        end
        if not isBossRunning() or controller.job ~= job or player.Character ~= character or humanoid.Health <= 0 then return true end
        if workspace:GetAttribute("GuardianActive") ~= active or workspace:GetAttribute("AreaCurrent") ~= active
            or not positive(model:GetAttribute("HP")) or model:GetAttribute("DeadAt") then
            cancelTween(job)
            releaseHover(job)
            task.wait(0.05)
            return true
        end
        local weapon = job.weapon
        local frame, size = model:GetBoundingBox()
        local center, predicted, forward, velocity = pose(model, frame)
        local radius = math.max(size.X, size.Z) / 2
        local circles = circlesFor(model, center, data)
        local gap = weapon.kind == "gun" and math.min(35, weapon.reach * 0.35) or math.max(1, weapon.reach - 2)
        local ring = weapon.kind == "gun" and radius + gap or gap
        local destination, behind, rearTarget = rearGoal(root.Position, center, predicted, forward, ring, radius)
        local dodging
        destination, dodging = clearCircleGoal(destination, center, forward, circles)
        local routed
        destination, routed = clearCirclePath(root.Position, destination, center, forward, circles)
        dodging = dodging or routed
        local bossHead = model:FindFirstChild("Head", true)
        local aim = bossHead and bossHead:IsA("BasePart") and predicted + (bossHead.Position - frame.Position)
            or predicted + Vector3.new(0, size.Y * 0.35, 0)
        destination = Vector3.new(destination.X, aim.Y, destination.Z)
        job.behind, job.dodging = behind, dodging
        job.rearTarget, job.forward, job.headHeight = rearTarget, forward, aim.Y
        hover(job, root)
        move(job, root, destination, predicted, dodging or not behind, velocity)
        setStatus(string.format("Boss · %s · %.1f HP · %s%s",
            model:GetAttribute("DisplayName") or active, hp, weapon.name, behind and " · hinter dem Boss" or " · zur Rückseite"))
        local distance = (Vector3.new(root.Position.X, center.Y, root.Position.Z) - center).Magnitude
        if weapon.kind == "gun" then distance = math.max(0, distance - radius) end
        local ready = os.clock() - job.detectedAt >= (data.settings.Guardian.Emerge or 3)
        local safeRadial = outsideCircles(root.Position, circles)
        if ready and behind and safeRadial and not model:GetAttribute("Hidden") and distance <= weapon.reach - 0.25 and os.clock() >= job.nextAttack then
            local head = character:FindFirstChild("Head")
            local origin = head and head.Position or root.Position
            local delta = aim - origin
            if delta.Magnitude > 0.01 then
                if weapon.kind == "gun" and player:GetAttribute("GunOut") == weapon.name then
                    data.gun:FireServer("Fire", weapon.name, origin, delta.Unit)
                elseif weapon.kind == "melee" and player:GetAttribute("Tool") == weapon.name then
                    data.swing:FireServer(1)
                else
                    job.weapon = nil
                    task.wait(0.05)
                    return true
                end
                controller.stats.sent = controller.stats.sent + 1
                job.nextAttack = os.clock() + weapon.interval
            end
        end
        task.wait(0.02)
        return true
    end
    rules()
    return controller
end
local bossController = createBossController()

-- War-God-Fähigkeit: Richtungsplanung lokal, Flugbahn und Treffer ausschließlich vom Server.
local function createAbilityController()
    local controller = {
        alive = true, request = nil :: { [string]: any }?,
        connection = nil :: RBXScriptConnection?, data = nil :: { [string]: any }?,
        lastPlan = nil :: { [string]: any }?, lastFlight = nil :: { [string]: any }?,
        flightUntil = 0, lastReturnAt = 0, acceptedAt = 0, nextTryAt = 0,
        stats = { sent = 0, accepted = 0, flights = 0, targets = 0, rejected = 0 },
    }
    state.abilityController = controller

    local function flat(vector)
        return Vector3.new(vector.X, 0, vector.Z)
    end
    local function better(a, b)
        if not b then return true end
        if #a.path ~= #b.path then return #a.path > #b.path end
        if math.abs(a.hp - b.hp) > 0.001 then return a.hp > b.hp end
        return a.length < b.length
    end
    local function plan(candidates, origin, spec, limit, continuePlanning)
        local yieldedAt = os.clock()
        local function checkpoint()
            if not continuePlanning then return true end
            if os.clock() - yieldedAt >= 0.005 then task.wait(); yieldedAt = os.clock() end
            return continuePlanning()
        end
        if #candidates == 0 then return nil end
        local range = math.max(1, (tonumber(spec.Range) or 100) - 0.5)
        local chainRange = math.max(range, (tonumber(spec.ChainRange) or range) - 0.5)
        local hopRange = math.max(1, (tonumber(spec.HopRange) or 34) - 0.5)
        local cone = math.cos(math.rad(tonumber(spec.ChainCone) or 60))
        local nodes = {}
        for _, candidate in ipairs(candidates) do
            local offset = flat(candidate.position - origin)
            if offset.Magnitude > 0.1 and offset.Magnitude <= chainRange then
                table.insert(nodes, { tree = candidate.tree, position = candidate.position,
                    hp = math.max(0, candidate.hp or 1), offset = offset, distance = offset.Magnitude, neighbors = {} })
            end
        end
        for i, node in ipairs(nodes) do
            if not checkpoint() then return nil end
            for j, other in ipairs(nodes) do
                if i ~= j then
                    local offset = flat(other.position - node.position)
                    if offset.Magnitude > 0.1 and offset.Magnitude <= hopRange then
                        table.insert(node.neighbors, { index = j, distance = offset.Magnitude, direction = offset.Unit })
                    end
                end
            end
            table.sort(node.neighbors, function(a, b)
                return a.distance == b.distance and a.index < b.index or a.distance < b.distance
            end)
        end
        local best
        -- Jeder erreichbare Startwinkel wird geprüft; begrenzte Strahlensuche für die Folgesprünge.
        for first, node in ipairs(nodes) do
            if not checkpoint() then return nil end
            if node.distance > range then continue end
            local beam = { { path = { first }, used = { [first] = true }, direction = node.offset.Unit,
                hp = node.hp, length = node.distance, first = first } }
            for _ = 2, limit do
                local nextBeam = {}
                for _, route in ipairs(beam) do
                    local current = nodes[route.path[#route.path]]
                    local branches = 0
                    for _, neighbor in ipairs(current.neighbors) do
                        if not route.used[neighbor.index] and route.direction:Dot(neighbor.direction) >= cone then
                            local path, used = table.clone(route.path), table.clone(route.used)
                            table.insert(path, neighbor.index)
                            used[neighbor.index] = true
                            table.insert(nextBeam, { path = path, used = used, direction = neighbor.direction,
                                hp = route.hp + nodes[neighbor.index].hp, length = route.length + neighbor.distance,
                                first = first })
                            branches = branches + 1
                            if branches >= 6 then break end
                        end
                    end
                    if better(route, best) then best = route end
                end
                if #nextBeam == 0 then break end
                table.sort(nextBeam, better)
                beam = {}
                for i = 1, math.min(4, #nextBeam) do beam[i] = nextBeam[i] end
            end
            for _, route in ipairs(beam) do if better(route, best) then best = route end end
        end
        if not best then return nil end
        local selected = {}
        for _, index in ipairs(best.path) do table.insert(selected, nodes[index].tree) end
        return { direction = nodes[best.first].offset.Unit, trees = selected,
            count = #selected, hp = best.hp, length = best.length, candidates = #nodes }
    end
    controller.plan = plan

    local function cancelRequest()
        local request = controller.request
        controller.request = nil
        local thread = request and request.thread
        if thread and thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then pcall(task.cancel, thread) end
    end
    function controller.cancel()
        cancelRequest()
    end
    function controller.destroy()
        controller.alive = false
        cancelRequest()
        if controller.connection then controller.connection:Disconnect(); controller.connection = nil end
    end
    local function resolve()
        if controller.data then return controller.data end
        if not resolveCombatData() then return nil end
        local shared = ReplicatedStorage:FindFirstChild("Shared")
        local services = shared and shared:FindFirstChild("Services")
        local remotes = services and services:FindFirstChild("ChopRemotes")
        local throw = remotes and remotes:FindFirstChild("ThrowAxe")
        local flight = remotes and remotes:FindFirstChild("AxeFlight")
        local scripts = player:FindFirstChild("PlayerScripts")
        local client = scripts and scripts:FindFirstChild("Client")
        local extra = client and client:FindFirstChild("Extra")
        local chopping = extra and extra:FindFirstChild("Chopping")
        local module = chopping and chopping:FindFirstChild("Leviathan")
        local spec = combat.settings.Leviathan
        if not throw or not throw:IsA("RemoteFunction") or not flight or not flight:IsA("RemoteEvent")
            or not module or type(spec) ~= "table" then return nil end
        controller.data = { throw = throw, native = require(module), spec = spec }
        controller.connection = flight.OnClientEvent:Connect(function(who, points, times, targets, tool)
            if not controller.alive or not isAlive() or who ~= player
                or tool ~= nil and tool ~= "Leviathan"
                or player:GetAttribute("Tool") ~= "Leviathan"
                or type(points) ~= "table" or type(times) ~= "table" or #points ~= #times or #times < 2 then return end
            local backAt = times[#times]
            if not positive(backAt) then return end
            controller.lastReturnAt = math.max(controller.lastReturnAt, backAt)
            controller.flightUntil = math.max(controller.flightUntil, backAt + 0.15)
            local unique, actual = {}, {}
            if type(targets) == "table" then
                for _, tree in pairs(targets) do
                    if typeof(tree) == "Instance" and not unique[tree] then
                        unique[tree] = true
                        table.insert(actual, tree)
                        -- Bereits vom Server ausgewählte Bäume während der Replikation nicht erneut schlagen.
                        if isAreaUnlocked(tree) then
                            skippedUntil[tree] = math.max(skippedUntil[tree] or 0,
                                os.clock() + math.max(0, backAt - workspace:GetServerTimeNow()) + 0.8)
                        end
                    end
                end
            end
            controller.stats.flights = controller.stats.flights + 1
            controller.stats.targets = controller.stats.targets + #actual
            controller.lastFlight = { trees = actual, count = #actual, backAt = backAt,
                points = points, planned = controller.lastPlan and controller.lastPlan.count or 0 }
        end)
        return controller.data
    end
    function controller.isFlying()
        local now = workspace:GetServerTimeNow()
        local request = controller.request
        if request and now - request.started >= 8 then
            cancelRequest()
            controller.nextTryAt = now + 2
            controller.stats.rejected = controller.stats.rejected + 1
        end
        local backAt = tonumber(player:GetAttribute("AxeBackAt"))
        local waitingForFlight = controller.acceptedAt > controller.lastReturnAt
            and (not backAt or backAt < controller.acceptedAt) and now < controller.acceptedAt + 8
        return controller.request ~= nil or waitingForFlight or now < controller.flightUntil
            or player:GetAttribute("AxeOut") == true and (not backAt or now < backAt + 2)
    end
    function controller.cooldownLeft()
        local data = resolve()
        if not data then return math.huge end
        local now = workspace:GetServerTimeNow()
        local backAt = tonumber(player:GetAttribute("AxeBackAt")) or 0
        controller.lastReturnAt = math.max(controller.lastReturnAt, backAt)
        local duration = (tonumber(data.spec.Cooldown) or 12) * combat.math.Scale(player, "Cooldown", "Leviathan")
        local left = controller.lastReturnAt > 0 and controller.lastReturnAt + duration - now or 0
        if type(data.native.CooldownLeft) == "function" then
            local nativeLeft = data.native.CooldownLeft()
            if type(nativeLeft) == "number" and nativeLeft == nativeLeft then left = math.max(left, nativeLeft) end
        end
        return math.max(0, left)
    end
    function controller.step(character, root, humanoid)
        if not controller.alive or not isRunning() then return false end
        local data = resolve()
        if not data or not ownsFarmTool("Leviathan") then return false end
        if controller.isFlying() then
            setStatus("War-God-Wurf · warte auf Rückkehr der Axt …")
            task.wait(0.04)
            return true
        end
        local now = workspace:GetServerTimeNow()
        if now < controller.nextTryAt or controller.cooldownLeft() > 0 then return false end
        if player:GetAttribute("Down") or player:GetAttribute("GuardianIntro") or player:GetAttribute("InCutscene")
            or humanoid.Sit or humanoid.Health <= 0 then return false end
        if os.clock() < combat.nextStart then
            setStatus("War-God-Wurf bereit · vorherigen Schlag abschließen …")
            task.wait(0.03)
            return true
        end
        local revision = state.revision
        local function valid()
            return controller.alive and isRunning() and state.revision == revision and player.Character == character
                and root:IsDescendantOf(character) and humanoid.Health > 0
        end
        local function choose()
            local origin = root.Position
            local candidates = {}
            local range = math.max(tonumber(data.spec.Range) or 100, tonumber(data.spec.ChainRange) or 170)
            for _, tree in ipairs(trees:GetChildren()) do
                if isAvailable(tree) and not treeCoordinator.isOccupied(tree) and (skippedUntil[tree] or 0) <= os.clock() then
                    local position = treePosition(tree)
                    if position and flat(position - root.Position).Magnitude <= range then
                        table.insert(candidates, { tree = tree, position = position, hp = treeHP(tree) })
                    end
                end
            end
            local limit = math.clamp(math.floor((tonumber(data.spec.Hops) or 3)
                + combat.math.Add(player, "Hops", "Leviathan")), 1, 64)
            return plan(candidates, origin, data.spec, limit, function()
                return valid() and (root.Position - origin).Magnitude <= 1
            end)
        end
        local selected = choose()
        if not selected then controller.nextTryAt = now + 0.3; return false end
        if player:GetAttribute("Tool") ~= "Leviathan" then
            if not requestFarmTool("Leviathan") or not valid() then return true end
            selected = choose()
        end
        if not selected or not valid() or player:GetAttribute("Tool") ~= "Leviathan"
            or controller.isFlying() or controller.cooldownLeft() > 0 then return false end
        for _, tree in ipairs(selected.trees) do
            if not isAvailable(tree) or treeCoordinator.isOccupied(tree) then return false end
        end
        if not treeCoordinator.throwSafe(selected, data.spec, root.Position) then
            controller.nextTryAt = now + 0.5
            return false
        end
        cancelMovement()
        combat.stopSaw()
        combat.stopNative()
        controller.lastPlan = selected
        local request = { started = workspace:GetServerTimeNow(), character = character }
        controller.request = request
        controller.stats.sent = controller.stats.sent + 1
        setStatus("War-God-Wurf · optimierter Winkel · bis zu " .. selected.count .. " Ziele")
        request.thread = task.spawn(function()
            if not valid() or controller.request ~= request then
                if controller.request == request then controller.request = nil end
                return
            end
            local ok, approved = pcall(data.throw.InvokeServer, data.throw, selected.direction)
            if not controller.alive or not isAlive() or controller.request ~= request then return end
            controller.request = nil
            if ok and approved == true then
                controller.stats.accepted = controller.stats.accepted + 1
                controller.acceptedAt = request.started
                local backAt = tonumber(player:GetAttribute("AxeBackAt"))
                if backAt and backAt >= request.started then
                    controller.lastReturnAt = math.max(controller.lastReturnAt, backAt)
                    controller.flightUntil = math.max(controller.flightUntil, backAt + 0.15)
                end
            else
                controller.stats.rejected = controller.stats.rejected + 1
                controller.nextTryAt = workspace:GetServerTimeNow() + 2
            end
        end)
        task.wait(0.02)
        return true
    end
    resolve()
    return controller
end
local abilityController = createAbilityController()

local function farmStep()
    local revision = state.revision
    refreshCombatDisplay()
    if not resolveWorld() then
        setStatus("Warte auf Map und Chop-Remotes …")
        task.wait(0.25)
        return
    end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then
        setStatus("Warte auf Charakter …")
        task.wait(0.1)
        return
    end
    if abilityController.step(character, root, humanoid) then return end
    local tree, nextRetry = nearestTree(root)
    if updateSawToolChoice(tree) then return end
    if not tree then
        if nextRetry < math.huge then
            setStatus("Warte auf nächsten Anlauf · " .. string.format("%.1f", math.max(0, nextRetry - os.clock())) .. " s")
        else
            setStatus("Kein freier Baum verfügbar · warte auf Mitspieler / neue Bäume")
        end
        task.wait(0.1)
        return
    end
    if player:GetAttribute("Tool") == "Axe" or player:GetAttribute("Tool") == "Fists" then
        local profile = player:GetAttribute("Tool") == "Fists" and fistsProfile(tree) or axeProfile(tree)
        if not profile then
            setStatus("Warte auf Werkzeug- und Animationsdaten …")
            task.wait(0.25)
            return
        end
        automaticAxeTree(tree, character, root, humanoid, revision, profile)
        return
    end
    if player:GetAttribute("Tool") == "HellChain" then
        local profile = combatProfile(tree)
        if not profile then
            setStatus("Warte auf HellChain-Trefferablauf …")
            task.wait(0.25)
            return
        end
        automaticTree(tree, character, root, humanoid, revision, profile)
        return
    end
    if player:GetAttribute("Tool") == "Chainsaw" then
        local profile = sawProfile(tree)
        if not profile then
            setStatus("Warte auf Kettensägen- und Hitzedaten …")
            task.wait(0.25)
            return
        end
        automaticSawTree(tree, character, root, humanoid, revision, profile)
        return
    end
    local profile = genericProfile(tree)
    if not profile then
        setStatus("Kein Baumangriffsprofil für " .. tostring(player:GetAttribute("Tool")))
        task.wait(0.25)
        return
    end
    if profile.direct then
        automaticAxeTree(tree, character, root, humanoid, revision, profile)
    else
        automaticNativeTree(tree, character, root, humanoid, revision, profile)
    end
end

-- Verkaufstransaktion: schnelle Tweens mit eigenem Hin-/Rückweg und Bewegungssperre.
local sellRules
local nextAutoSellAt = 0
local SELL_TWEEN_SPEED = 300
local CollectionService = game:GetService("CollectionService")

local function resolveSellRules()
    if sellRules then return sellRules end
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local configs = shared and shared:FindFirstChild("Configs")
    local utilities = shared and shared:FindFirstChild("Utilities")
    local services = shared and shared:FindFirstChild("Services")
    local remotes = services and services:FindFirstChild("ChopRemotes")
    local deposit = remotes and remotes:FindFirstChild("DepositLogs")
    local chopping = configs and configs:FindFirstChild("Chopping")
    local chapter = configs and configs:FindFirstChild("ChapterWorld")
    local upgrade = utilities and utilities:FindFirstChild("UpgradeMath")
    if not deposit or not deposit:IsA("RemoteEvent")
        or not chopping or not chapter or not upgrade then return nil end
    sellRules = {
        settings = require(chopping).Selling,
        chapter = require(chapter), math = require(upgrade),
        deposit = deposit,
    }
    return sellRules
end

local function stationUnlockIndex(spot, rules)
    local node = spot
    while node and node ~= workspace do
        local index = node:GetAttribute("AreaIndex")
        if index ~= nil then
            return type(index) == "number" and index >= 1 and index % 1 == 0 and index or nil
        end
        local area = node:GetAttribute("Area")
        if type(area) == "string" and area ~= "" then
            local mapped = rules.chapter.UnlockIndexOf(area)
            return type(mapped) == "number" and mapped >= 1 and mapped % 1 == 0 and mapped or nil
        end
        node = node.Parent
    end
    local map = workspace:FindFirstChild("Map")
    -- Der Hauptverkaufspunkt ist der frei zugängliche Ausgangspunkt der Map.
    if map and spot == map:FindFirstChild("SellSpot") then return 1 end
    return nil
end

local function stationAllowed(spot, rules)
    if not spot:IsDescendantOf(workspace) then return false end
    local unlocked = workspace:GetAttribute("AreasUnlocked")
    local index = stationUnlockIndex(spot, rules)
    return type(unlocked) == "number" and unlocked >= 1 and unlocked % 1 == 0
        and index ~= nil and index <= unlocked
end

local function nearestSellStation(position, rules)
    local stations = {}
    local seen = {}
    local function add(spot)
        if not spot or seen[spot] then return end
        seen[spot] = true
        local pad = spot:FindFirstChild("DepositPad")
        if pad and pad:IsA("BasePart") and stationAllowed(spot, rules) then
            local offset = position - pad.Position
            table.insert(stations, {
                spot = spot, pad = pad, squared = offset:Dot(offset),
                index = stationUnlockIndex(spot, rules),
                label = spot.Parent and (spot.Parent:GetAttribute("Area") or spot.Name) or spot.Name,
            })
        end
    end
    local map = workspace:FindFirstChild("Map")
    add(map and map:FindFirstChild("SellSpot"))
    for _, tag in ipairs({ "SellSpot", "SellOutpost" }) do
        for _, spot in ipairs(CollectionService:GetTagged(tag)) do add(spot) end
    end
    table.sort(stations, function(a,b) return a.squared < b.squared end)
    return stations[1]
end

local function sellThreshold(rules)
    local capacity = rules.math.CarryMax(player)
    if config.AutoDetectBackpackCapacity then
        if capacity == math.huge then
            return nil, "Auto-Sell · unendlicher Rucksack wird nie voll"
        end
        if not positive(capacity) or capacity < 1 then
            return nil, "Auto-Sell wartet auf eine gültige Rucksackkapazität"
        end
        return math.floor(capacity)
    end
    local threshold = math.max(1, math.floor(config.SellThreshold))
    if positive(capacity) then threshold = math.min(threshold, math.max(1, math.floor(capacity))) end
    return threshold
end
state.sellApi = { rules = resolveSellRules, nearest = nearestSellStation, threshold = sellThreshold, allowed = stationAllowed }

local function sellCharacterValid(job)
    return player.Character == job.character and job.root:IsDescendantOf(job.character)
        and job.humanoid.Health > 0
end

local function moveSaleCharacter(job, destination)
    if state.sellJob ~= job or not sellCharacterValid(job) then return false end
    job.root.AssemblyLinearVelocity = Vector3.zero
    job.root.AssemblyAngularVelocity = Vector3.zero
    local duration = math.max(0.15, (job.root.Position - destination).Magnitude / SELL_TWEEN_SPEED)
    local tween = TweenService:Create(job.root, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(destination) * job.root.CFrame.Rotation,
    })
    job.tween = tween
    tween:Play()
    while tween.PlaybackState == Enum.PlaybackState.Playing do
        if state.sellJob ~= job or not sellCharacterValid(job) then
            tween:Cancel()
            break
        end
        task.wait()
    end
    if job.tween == tween then job.tween = nil end
    if not sellCharacterValid(job) then return false end
    job.root.AssemblyLinearVelocity = Vector3.zero
    job.root.AssemblyAngularVelocity = Vector3.zero
    return tween.PlaybackState == Enum.PlaybackState.Completed
        and (job.root.Position - destination).Magnitude <= 2
end

local function returnFromSale(job)
    if job.returned then return true end
    if not sellCharacterValid(job) then return false end
    local moved, result = pcall(moveSaleCharacter, job, job.origin)
    job.returned = moved and result == true
    return job.returned
end

local function finishSale(job, message)
    if job.done or state.sellJob ~= job then return end
    job.finishThread = coroutine.running()
    local returned = returnFromSale(job)
    if job.done or state.sellJob ~= job then return end
    job.finishThread = nil
    job.done = true
    state.sellJob = nil
    state.sellBusy = false
    nextAutoSellAt = os.clock() + math.max(0.5, job.rules.settings.DepositInterval or 0.5)
    if isAlive() then
        local controller = state.playerController
        if job.restoreFly and not state.enabled and controller and controller.alive then controller.set("Fly", true) end
        setSellStatus(message .. (returned and " · zurückgekehrt" or " · Rückkehr bei geändertem Charakter nicht möglich"))
        setStatus(state.enabled and "Verkauf beendet · suche nächsten Baum …" or "Pausiert · Verkauf beendet")
    end
end

function state.cancelSell(reason)
    local job = state.sellJob
    if not job or job.done then return false end
    job.cancelled = true
    if job.tween then
        pcall(function() job.tween:Cancel() end)
        job.tween = nil
    end
    for _, thread in ipairs({ job.thread, job.finishThread }) do
        if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
            pcall(task.cancel, thread)
        end
    end
    finishSale(job, reason or "Verkauf abgebrochen")
    return true
end

local function sellJobValid(job)
    return isAlive() and state.sellJob == job and not job.cancelled and sellCharacterValid(job)
end

local function completeSale(job)
    while state.abilityController and state.abilityController.isFlying() do
        if not sellJobValid(job) then error("Verkauf unterbrochen") end
        setSellStatus("Warte auf Rückkehr der geworfenen Axt …")
        task.wait(0.04)
    end
    local rules = job.rules
    local station = job.station
    if not sellJobValid(job) or not stationAllowed(station.spot, rules) then error("Verkaufspunkt nicht mehr freigeschaltet") end
    local pad = station.pad
    local half = pad.Size / 2
    local frame = pad.CFrame
    local vertical = math.abs(frame.RightVector.Y) * half.X
        + math.abs(frame.UpVector.Y) * half.Y + math.abs(frame.LookVector.Y) * half.Z
    local destination = pad.Position + Vector3.new(0, vertical + job.humanoid.HipHeight + job.root.Size.Y / 2 + 0.5, 0)
    setSellStatus("Tween zum Verkaufspunkt · " .. tostring(station.label))
    assert(moveSaleCharacter(job, destination), "Charakter nicht verfügbar")
    local returnAt = os.clock() + 1
    -- Nur kurz für die Positionsreplikation aufs Pad; keine Verkaufsbestätigung abwarten.
    task.wait(0.1)
    if not sellJobValid(job) then error("Verkauf unterbrochen") end
    assert(stationAllowed(station.spot, rules) and pad:IsDescendantOf(station.spot), "Verkaufspunkt nicht mehr verfügbar")
    assert((job.root.Position - pad.Position).Magnitude <= (rules.settings.ServerDepositReach or 24) - 0.5,
        "Verkaufspunkt nach Tween nicht erreichbar")
    rules.deposit:FireServer(false)
    -- Insgesamt mindestens eine Sekunde auf dem Pad bleiben, dann per Tween zurück.
    task.wait(math.max(0, returnAt - os.clock()))
    if not sellJobValid(job) then error("Verkauf unterbrochen") end
    return "Holzabgabe ausgelöst"
end

function state.requestSell(mode)
    if not isAlive() then return false, "Script beendet" end
    if not isRunTransitionIdle() then return false, "Eine Run-/Event-Interaktion läuft oder der Run ist nicht aktiv" end
    if state.sellBusy then return false, "Ein Verkauf läuft bereits" end
    local count = player:GetAttribute("CarriedLogs")
    if type(count) ~= "number" or count < 1 then return false, "Kein Holz im Inventar" end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 or humanoid.Sit then return false, "Warte auf einen stehenden, lebenden Charakter" end
    local rules = resolveSellRules()
    if not rules then return false, "Verkaufsregeln noch nicht verfügbar" end
    local station = nearestSellStation(root.Position, rules)
    if not station then return false, "Kein freigeschalteter Verkaufspunkt gefunden" end
    local controller = state.playerController
    local job = {
        mode = mode == "auto" and "auto" or "manual", character = character,
        root = root, humanoid = humanoid, origin = root.Position,
        station = station, rules = rules, cancelled = false, done = false, returned = false,
        restoreFly = controller and controller.enabled.Fly == true or false,
    }
    state.sellJob = job
    state.sellBusy = true
    state.revision = state.revision + 1
    cancelMovement()
    if controller and controller.enabled.Fly then controller.set("Fly", false) end
    setStatus("Verkauf läuft · Autofarm pausiert")
    job.thread = task.defer(function()
        local sold, result = xpcall(function() return completeSale(job) end, function(message)
            return debug.traceback(tostring(message), 2)
        end)
        if not sold and not job.cancelled then warn("[ForestControl Sell] " .. tostring(result)) end
        if state.sellJob == job then
            finishSale(job, sold and result or "Verkauf fehlgeschlagen · Details in der Konsole")
        end
    end)
    return true, "Verkauf gestartet"
end

-- Auto-Collect: Holz mit Grasp sowie eigene Gem-/Shard-Drops.
local collectRetryAt = setmetatable({}, { __mode = "k" })
local currencyRetryAt = setmetatable({}, { __mode = "k" })
local gemLogVisuals
local gemRevealTimeout = 7
local carryMath
local carryMathModule
local logSettings
local logSettingsModule

local function collectionAllowed()
    return isAlive() and state.collectEnabled and not state.sellBusy and isRunTransitionIdle() and not state.configLoading
end

local function isLogAreaAllowed(log)
    -- "Zone" ist ein Wertmultiplikator (z.B. 1.5), kein Gebietsindex.
    -- Nur ein tatsächlich vorhandener AreaIndex darf zum Sperren führen.
    if log:GetAttribute("AreaIndex") ~= nil then
        return isAreaUnlocked(log)
    end
    return true
end

local function planLogBatch(candidates, rootPosition, firstRange, serverRange, graspRange, limit)
    if limit < 1 then return {} end
    local first
    local firstSquared = firstRange * firstRange
    for _, candidate in ipairs(candidates) do
        local delta = rootPosition - candidate.position
        local squared = delta:Dot(delta)
        if squared <= firstSquared then
            firstSquared = squared
            first = candidate
        end
    end
    if not first then return {} end

    local batch = { first }
    if limit == 1 then return batch end
    local neighbors = {}
    for _, candidate in ipairs(candidates) do
        if candidate ~= first then
            local fromFirst = candidate.position - first.position
            local fromPlayer = candidate.position - rootPosition
            local squared = fromFirst:Dot(fromFirst)
            if squared <= graspRange * graspRange
                and fromPlayer:Dot(fromPlayer) <= serverRange * serverRange then
                table.insert(neighbors, { candidate = candidate, squared = squared })
            end
        end
    end
    table.sort(neighbors, function(a,b) return a.squared < b.squared end)
    for index = 1, math.min(limit - 1, #neighbors) do
        table.insert(batch, neighbors[index].candidate)
    end
    return batch
end

local function collectLogsStep(character, root, humanoid, shared, remotes)
    local logs = workspace:FindFirstChild("Logs")
    local pickup = remotes and remotes:FindFirstChild("PickUpLog")
    if not logs or not pickup or not pickup:IsA("RemoteEvent") then
        return "Holz: warte auf Logs/PickUpLog"
    end

    local utilities = shared and shared:FindFirstChild("Utilities")
    local mathModule = utilities and utilities:FindFirstChild("UpgradeMath")
    if mathModule ~= carryMathModule then
        carryMath = nil
        carryMathModule = mathModule
    end
    if not carryMath and mathModule then
        local ok, api = pcall(require, mathModule)
        if ok and type(api) == "table" and type(api.CarryMax) == "function" then
            carryMath = api
        end
    end

    local configs = shared and shared:FindFirstChild("Configs")
    local settingsModule = configs and configs:FindFirstChild("Chopping")
    if settingsModule ~= logSettingsModule then
        logSettings = nil
        logSettingsModule = settingsModule
    end
    if not logSettings and settingsModule then
        local ok, settings = pcall(require, settingsModule)
        if ok and type(settings) == "table" and type(settings.Logs) == "table" then
            logSettings = settings.Logs
        end
    end
    if not collectionAllowed() or player.Character ~= character then return end
    if not carryMath or not logSettings then
        return "Holz: warte auf Sammelregeln"
    end

    local capacity = carryMath.CarryMax(player)
    local carried = player:GetAttribute("CarriedLogs")
    if type(capacity) ~= "number" or type(carried) ~= "number" then
        return "Holz: warte auf Rucksackdaten"
    end
    if carried >= capacity then
        return "Holz: Rucksack voll"
    end

    -- Dieselbe Upgrade-Berechnung wie beim manuellen Einsammeln.
    local grab = type(carryMath.Grab) == "function" and carryMath.Grab(player) or 1
    if type(grab) ~= "number" or grab ~= grab or grab == math.huge then grab = 1 end
    grab = math.max(1, math.floor(grab))
    local limit = math.floor(math.min(grab, capacity - carried))
    local serverRange = math.max(0, (tonumber(logSettings.ServerPickupRange) or 15) - 0.25)
    local firstRange = math.min(config.CollectRadius, serverRange)
    local graspRange = math.max(0, tonumber(logSettings.GraspRadius) or 8)
    local now = os.clock()
    local candidates = {}
    for _, log in ipairs(logs:GetChildren()) do
        if log:IsA("Model") and log:HasTag("Log")
            and isLogAreaAllowed(log)
            and (collectRetryAt[log] or 0) <= now then
            local position = log:GetPivot().Position
            local offset = root.Position - position
            if offset:Dot(offset) <= serverRange * serverRange then
                table.insert(candidates, { log = log, position = position })
            end
        end
    end
    local batch = planLogBatch(candidates, root.Position, firstRange, serverRange, graspRange, limit)
    if #batch == 0 then
        return "Holz: keines in Reichweite · Grasp " .. grab
    end

    local anchor = batch[1].position
    local sent = 0
    for index, candidate in ipairs(batch) do
        if not collectionAllowed() or not config.CollectLogs
            or player.Character ~= character
            or not root:IsDescendantOf(character)
            or humanoid.Health <= 0 then
            break
        end
        local log = candidate.log
        if log:IsDescendantOf(logs) and isLogAreaAllowed(log)
            and (collectRetryAt[log] or 0) <= os.clock() then
            local position = log:GetPivot().Position
            local distance = (root.Position - position).Magnitude
            local inRange = index == 1 and distance <= firstRange
                or (index > 1 and distance <= serverRange
                    and (position - anchor).Magnitude <= graspRange)
            if index == 1 and not inRange then break end
            if inRange then
                collectRetryAt[log] = os.clock() + LOG_RETRY_AFTER
                pickup:FireServer(log)
                sent = sent + 1
            end
        elseif index == 1 then
            break
        end
    end
    if sent > 0 then
        return "Holz: " .. sent .. " pro Griff · Grasp " .. grab
    end
    return "Holz: warte auf erreichbaren Stamm"
end

local function currencyKind(drop)
    if drop:GetAttribute("Currency") == "Candy" then return nil end
    if drop.Name == "Shard" or drop:GetAttribute("Currency") == "Shards" then return "Shards" end
    if drop.Name == "Gem" then return "Gems" end
    return nil
end

local function currencyEnabled(kind)
    return kind == "Gems" and config.CollectGems or kind == "Shards" and config.CollectShards
end

local function currencyReady(drop)
    local fellAt = drop:GetAttribute("FellAt")
    if fellAt == nil then return true end
    if not positive(fellAt) then return false end
    if gemLogVisuals and type(gemLogVisuals.BrokenAt) == "function" then
        local brokenAt = gemLogVisuals.BrokenAt(fellAt)
        if type(brokenAt) == "number" and os.clock() - brokenAt >= 0.35 then return true end
    end
    -- Dieselbe Rückfallregel wie im GemDrops-Client, falls der Baum nicht sichtbar war.
    return workspace:GetServerTimeNow() - fellAt > gemRevealTimeout
end

local function collectCurrencyStep(character, root, humanoid, shared, remotes)
    if not config.CollectGems and not config.CollectShards then return nil end
    local folder = workspace:FindFirstChild("GemDrops")
    local remote = remotes and remotes:FindFirstChild("CollectGem")
    if not folder or not remote or not remote:IsA("RemoteEvent") then
        return "Gems/Shards: warte auf GemDrops/CollectGem"
    end
    if not gemLogVisuals then
        local scripts = player:FindFirstChild("PlayerScripts")
        local client = scripts and scripts:FindFirstChild("Client")
        local extra = client and client:FindFirstChild("Extra")
        local chopping = extra and extra:FindFirstChild("Chopping")
        local module = chopping and chopping:FindFirstChild("LogVisuals")
        if module then
            local loaded, api = pcall(require, module)
            if loaded then gemLogVisuals = api end
        end
        local configs = shared and shared:FindFirstChild("Configs")
        local settingsModule = configs and configs:FindFirstChild("Chopping")
        if settingsModule then
            local loaded, settings = pcall(require, settingsModule)
            if loaded and type(settings) == "table" and type(settings.Logs) == "table" then
                gemRevealTimeout = tonumber(settings.Logs.RevealTimeout) or 7
            end
        end
    end
    if not collectionAllowed() or player.Character ~= character then return nil end
    local range = math.min(config.CurrencyCollectRadius, 15.75)
    local now = os.clock()
    local candidates = {}
    for _, drop in ipairs(folder:GetDescendants()) do
        if drop:IsA("BasePart") and drop:HasTag("GemDrop")
            and drop:GetAttribute("Owner") == player.UserId
            and not drop:GetAttribute("CollectedBy")
            and isLogAreaAllowed(drop) and (currencyRetryAt[drop] or 0) <= now then
            local kind = currencyKind(drop)
            local offset = root.Position - drop.Position
            local squared = offset:Dot(offset)
            if currencyEnabled(kind) and squared <= range * range and currencyReady(drop) then
                table.insert(candidates, { drop = drop, squared = squared })
            end
        end
    end
    table.sort(candidates, function(a,b) return a.squared < b.squared end)
    local gems, shards = 0, 0
    for index = 1, math.min(#candidates, 4) do
        if not collectionAllowed() or player.Character ~= character
            or not root:IsDescendantOf(character) or humanoid.Health <= 0 then break end
        local drop = candidates[index].drop
        local kind = currencyKind(drop)
        if drop:IsDescendantOf(folder) and drop:HasTag("GemDrop") and currencyEnabled(kind)
            and drop:GetAttribute("Owner") == player.UserId
            and not drop:GetAttribute("CollectedBy") and isLogAreaAllowed(drop)
            and currencyReady(drop) and (currencyRetryAt[drop] or 0) <= os.clock()
            and (root.Position - drop.Position).Magnitude <= range then
            currencyRetryAt[drop] = os.clock() + LOG_RETRY_AFTER
            remote:FireServer(drop, "Click")
            if kind == "Shards" then shards = shards + 1 else gems = gems + 1 end
        end
    end
    if gems + shards == 0 then return "Gems/Shards: keine eigenen erreichbaren Drops" end
    return "Gems: " .. gems .. " · Shards: " .. shards
end

local function collectStep()
    if not collectionAllowed() then return end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then
        return
    end
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local services = shared and shared:FindFirstChild("Services")
    local remotes = services and services:FindFirstChild("ChopRemotes")
    collectCurrencyStep(character, root, humanoid, shared, remotes)
    -- Ein voller Holzrucksack blockiert keine Währungs-Drops.
    if config.CollectLogs and collectionAllowed() and player.Character == character then
        collectLogsStep(character, root, humanoid, shared, remotes)
    end
end

state.collectWorker = task.spawn(function()
    while isAlive() do
        if collectionAllowed() then
            local ok, err = xpcall(collectStep, function(message)
                return debug.traceback(tostring(message), 2)
            end)
            if not ok and isAlive() then
                warn("[ForestControl Collect] " .. tostring(err))
                pcall(state.setAutoCollect, false)
            end
            task.wait(math.max(config.CollectInterval, 0.12))
        else
            task.wait(0.1)
        end
    end
end)

state.sellWorker = task.spawn(function()
    while isAlive() do
        if state.sellEnabled and not state.sellBusy and not state.bossBusy and isRunTransitionIdle() and not state.configLoading
            and not (state.abilityController and state.abilityController.isFlying()) and os.clock() >= nextAutoSellAt then
            local checked, message = xpcall(function()
                local rules = resolveSellRules()
                local count = player:GetAttribute("CarriedLogs")
                if not rules or type(count) ~= "number" then
                    setSellStatus("Auto-Sell wartet auf Rucksack- und Verkaufsdaten")
                    return
                end
                local threshold, capacityStatus = sellThreshold(rules)
                if not threshold then
                    setSellStatus(capacityStatus)
                elseif count >= threshold then
                    local accepted, reason = state.requestSell("auto")
                    if not accepted then
                        nextAutoSellAt = os.clock() + 3
                        setSellStatus(reason)
                    end
                else
                    setSellStatus("Auto-Sell bereit · " .. count .. " / " .. threshold .. " Holz")
                end
            end, function(reason) return debug.traceback(tostring(reason), 2) end)
            if not checked and isAlive() then
                warn("[ForestControl Auto-Sell] " .. tostring(message))
                state.setAutoSell(false)
            end
        end
        task.wait(0.25)
    end
end)


-- Unabhängiger Boss-Worker; Boss-Bewegung besitzt einen eigenen Tween.
state.bossWorker = task.spawn(function()
    while isAlive() do
        if isBossRunning() then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if root and humanoid and humanoid.Health > 0 then
                local ok, message = xpcall(function()
                    bossController.step(character, root, humanoid)
                end, function(reason) return debug.traceback(tostring(reason), 2) end)
                if not ok and isAlive() then
                    warn("[ForestControl Auto-Boss] " .. tostring(message))
                    config.AutoBoss = false
                    if state.controls.AutoBoss then state.controls.AutoBoss:Set(false, true) end
                    bossController.stop()
                    setStatus("Auto-Bossfight pausiert · Details in der Konsole")
                end
            else
                bossController.stop()
            end
            task.wait(0.02)
        else
            bossController.stop()
            task.wait(0.1)
        end
    end
    bossController.stop()
end)

state.worker = task.spawn(function()
    local nextDisplay = 0
    while isAlive() do
        if not isRunning() then
            if state.enabled and isGuardianFightActive() and not state.bossBusy
                and not state.sellBusy and not state.configLoading then
                setStatus("Bosskampf · Baumfarm pausiert · manuelle Waffenwahl")
            end
            if os.clock() >= nextDisplay then
                nextDisplay = os.clock() + 1
                local displayed, displayError = pcall(refreshCombatDisplay)
                if not displayed then
                    warn("[ForestControl HellChain] " .. tostring(displayError))
                    nextDisplay = os.clock() + 10
                end
            end
            task.wait(0.1)
        else
            local ok, err = xpcall(farmStep, function(message)
                return debug.traceback(tostring(message), 2)
            end)
            if not ok and isAlive() then
                warn("[ForestControl] " .. tostring(err))
                pcall(state.setEnabled, false)
                pcall(setStatus, "Fehler · Details in der Konsole")
            end
        end
    end
    state.stop()
end)

if state.configManager then state.configManager.start() end
if state.runController then
    state.runController.restore(teleportState)
    state.runController.start()
end
if state.upgradeController then state.upgradeController.start() end
print("[ForestControl Gen2] Bereit · alte Instanz vollständig beendet · native Configs mit Auto-Load verfügbar.")
