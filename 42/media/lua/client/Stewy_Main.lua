-- ============================================================================
-- STEWY - Automated Stew Prep for Project Zomboid Build 42
-- Author: jinx_player
-- Version: 3.0
-- License: Free to use, modify, and redistribute.
--
-- WHAT THIS MOD DOES:
--   Right-click context menu -> "Stewy: Prep Stew Ingredients" opens a
--   window showing all ENGINE-VALIDATED stew ingredients in your inventory.
--   Select items, press PREP, and Stewy queues them into your pot(s) using
--   vanilla ISAddItemInRecipe timed actions.
--
-- HOW TO INSTALL:
--   1. Drop "Stewy/" into ~/Zomboid/mods/
--   2. Enable in main menu Mods screen
--   3. >>> CRITICAL: Also enable PER-SAVE via Load > More Options > Mods <<<
--
-- KEY ARCHITECTURE DECISIONS:
--   - Uses recipe:getItemRecipe(item) to ask the ENGINE what's valid for stew
--     (no more guessing about meat types, seasonings, etc.)
--   - Groups items by pot: all pot1 items queued first, then pot2 items
--   - Queues everything at once to ISTimedActionQueue (which processes
--     them sequentially with proper animations)
--   - The pot's Java object reference survives transformation (Base.Pot ->
--     PotOfStew happens in-place on the same object), so all items queued
--     to the same pot reference work correctly
--
-- WHAT BREAKS ON PZ UPDATES:
--   - Java method signatures change (always pcall)
--   - New pot/container types appear (need to add to pot detection)
--   - Evolved recipe entries change (new container recipes)
--   - UI constructor signatures change (ISLabel, ISButton)
--   THE GOLDEN RULE: pcall everything, print liberally, grep console.txt
-- ============================================================================

require "ISInventoryPaneContextMenu"
require "TimedActions/ISAddItemInRecipe"

StewyMod = StewyMod or {}

print("[Stewy] >>> SCRIPT FILE LOADED <<<")

-- ============================================================================
-- EVOLVED RECIPE LOOKUP
-- Each container has its own recipe. We MUST exact-match on getBaseItem()
-- because string.find("PotForged", "Pot") matches the wrong recipe.
-- ============================================================================
StewyMod.evolvedRecipes = {}

function Stewy_FindStewRecipe(potItem)
    local potType = ""
    if potItem then potType = potItem:getFullType() or "" end
    if StewyMod.evolvedRecipes[potType] then
        return StewyMod.evolvedRecipes[potType]
    end

    local allStewRecipes = {}
    local recipes = getScriptManager():getAllEvolvedRecipes()
    if recipes then
        for i = 0, recipes:size() - 1 do
            local r = recipes:get(i)
            if r then
                local rName = r:getName() or ""
                if string.find(rName, "Stew") or string.find(rName, "stew") then
                    local baseItem = ""
                    if r.getBaseItem then baseItem = r:getBaseItem() or "" end
                    local resultItem = ""
                    if r.getResultItem then resultItem = r:getResultItem() or "" end
                    print("[Stewy] Found stew recipe: " .. rName .. " | base=" .. baseItem .. " | result=" .. resultItem)
                    table.insert(allStewRecipes, {recipe = r, name = rName, base = baseItem, result = resultItem})
                end
            end
        end
    end

    local bestRecipe = nil

    -- 1. Exact match for fresh pots
    for _, entry in ipairs(allStewRecipes) do
        if entry.base == potType then
            bestRecipe = entry.recipe
            print("[Stewy] Exact match: " .. entry.name .. " (base=" .. entry.base .. ")")
            break
        end
    end

    -- 2. PotOfStew/PotOfSoup -> Base.Pot recipe
    if not bestRecipe and string.find(potType, "PotOfS") then
        for _, entry in ipairs(allStewRecipes) do
            if entry.base == "Base.Pot" then
                bestRecipe = entry.recipe
                print("[Stewy] Stew-in-progress -> Pot recipe: " .. entry.name)
                break
            end
        end
    end

    -- 3. BucketOfStew -> Base.Bucket recipe
    if not bestRecipe and string.find(potType, "BucketOf") then
        for _, entry in ipairs(allStewRecipes) do
            if entry.base == "Base.Bucket" or entry.base == "Base.BucketEmpty" then
                bestRecipe = entry.recipe
                print("[Stewy] Bucket stew -> Bucket recipe: " .. entry.name)
                break
            end
        end
    end

    -- 4. PotForgedStew -> Base.PotForged recipe
    if not bestRecipe and string.find(potType, "PotForged") then
        for _, entry in ipairs(allStewRecipes) do
            if entry.base == "Base.PotForged" then
                bestRecipe = entry.recipe
                print("[Stewy] Forged stew -> PotForged recipe: " .. entry.name)
                break
            end
        end
    end

    -- 5. Fallback
    if not bestRecipe and #allStewRecipes > 0 then
        bestRecipe = allStewRecipes[1].recipe
        print("[Stewy] WARNING: No match for '" .. potType .. "', using: " .. allStewRecipes[1].name)
    end

    if bestRecipe then
        StewyMod.evolvedRecipes[potType] = bestRecipe
    else
        print("[Stewy] WARNING: No stew recipe found!")
    end
    return bestRecipe
end

-- ============================================================================
-- POT FINDING
-- ============================================================================
function Stewy_FindCurrentPots(player)
    local pots = {}
    local inv = player:getInventory()
    if not inv then return pots end
    local items = inv:getItems()
    if not items then return pots end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it then
            local ft = it:getFullType() or ""
            local isPotType = (ft == "Base.Pot" or ft == "Base.CookingPot"
                or ft == "Base.PotForged"
                or string.find(ft, "CookingPot")
                or string.find(ft, "PotOf")
                or string.find(ft, "PotForged")
                or string.find(ft, "BucketOf"))
            if isPotType then
                local valid = false
                if string.find(ft, "PotOf") or string.find(ft, "BucketOf") or string.find(ft, "PotForgedStew") then
                    valid = true
                elseif it.getFluidContainer then
                    local fc = it:getFluidContainer()
                    if fc then
                        local ok, result = pcall(function() return (fc:getAmount() or 0) > 0 end)
                        if ok and result then valid = true end
                    end
                end
                if valid then table.insert(pots, it) end
            end
        end
    end
    return pots
end

-- ============================================================================
-- ENGINE-BASED INGREDIENT VALIDATION
--
-- recipe:getItemRecipe(item) returns non-nil if the engine considers the
-- item valid for this evolved recipe. This handles EVERYTHING: meat, veggies,
-- seasonings (pepper, salt, sugar), prepared foods (hot dogs, ham slices,
-- TV dinners), etc. No more guessing with keyword lists.
-- ============================================================================
function Stewy_GetValidIngredients(player, potItem)
    local recipe = Stewy_FindStewRecipe(potItem)
    if not recipe then
        print("[Stewy] No recipe, can't validate ingredients")
        return {}
    end

    local list = {}
    local inv = player:getInventory()
    if not inv then return list end
    local items = inv:getItems()
    if not items then return list end

    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it then
            local ft = it:getFullType() or ""
            -- Skip pots/stews themselves
            local isPot = (ft == "Base.Pot" or ft == "Base.CookingPot"
                or ft == "Base.PotForged"
                or string.find(ft, "CookingPot") or string.find(ft, "BucketOf")
                or string.find(ft, "PotOf") or string.find(ft, "PotForged"))
            if not isPot then
                -- Ask the ENGINE if this item is valid for the stew recipe
                local ok, itemRecipe = pcall(function()
                    return recipe:getItemRecipe(it)
                end)
                if ok and itemRecipe then
                    table.insert(list, it)
                end
            end
        end
    end

    print("[Stewy] Engine validated " .. #list .. " ingredients")
    return list
end

-- ============================================================================
-- DISPLAY HELPER
-- ============================================================================
function Stewy_GetFoodSuffix(item)
    if not item then return "" end
    if item.getUsedDelta then
        local used = item:getUsedDelta() or 0
        if used >= 0.95 then return " [NEARLY EMPTY]"
        elseif used > 0.3 then return " [" .. math.floor((1.0 - used) * 100) .. "% left]"
        end
    end
    return ""
end

-- ============================================================================
-- UI PANEL
-- ============================================================================
ISStewPrepWindow = ISPanel:derive("ISStewPrepWindow")

function ISStewPrepWindow:new(x, y, w, h, player)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.width = w
    o.height = h
    o.backgroundColor = {r = 0.1, g = 0.1, b = 0.1, a = 0.85}
    o.borderColor = {r = 0.4, g = 0.4, b = 0.4, a = 1}
    o.moveWithMouse = true
    o.availablePots = {}
    o.availableFood = {}
    return o
end

function ISStewPrepWindow:initialise()
    ISPanel.initialise(self)
    local m = 10
    local y = m

    self.titleLabel = ISLabel:new(m, y, 25, "Stewy - Stew Prep Manager", 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)
    y = y + 30

    self.statusLabel = ISLabel:new(m, y, 20, "Scanning...", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self:addChild(self.statusLabel)
    y = y + 25

    self.potCountLabel = ISLabel:new(m, y, 20, "Found 0 Pots", 0.7, 1.0, 0.7, 1, UIFont.Small, true)
    self.potCountLabel:initialise()
    self:addChild(self.potCountLabel)
    y = y + 25

    local foodHeader = ISLabel:new(m, y, 20, "Valid Stew Ingredients:", 1, 1, 1, 1, UIFont.Small, true)
    foodHeader:initialise()
    self:addChild(foodHeader)
    y = y + 25

    local listHeight = self.height - y - 90
    self.foodListPanel = ISScrollingListBox:new(m, y, self.width - (m * 2), listHeight)
    self.foodListPanel:initialise()
    self.foodListPanel:instantiate()
    self.foodListPanel.itemheight = 24
    self.foodListPanel.selected = 0
    self.foodListPanel.joypadParent = self
    self.foodListPanel.font = UIFont.Small
    self.foodListPanel.doDrawItem = self.drawFoodItem
    self.foodListPanel.drawBorder = true
    self:addChild(self.foodListPanel)
    y = y + listHeight + 5

    self.execBtn = ISButton:new(m, y, self.width - (m * 2), 30, "PREP STEW", self, ISStewPrepWindow.onExecute)
    self.execBtn:initialise()
    self.execBtn:instantiate()
    self.execBtn.borderColor = {r = 0.4, g = 0.7, b = 0.4, a = 1}
    self:addChild(self.execBtn)
    y = y + 35

    self.errorLabel = ISLabel:new(m, y, 20, "", 1, 0.3, 0.3, 1, UIFont.Small, true)
    self.errorLabel:initialise()
    self:addChild(self.errorLabel)

    self.closeBtn = ISButton:new(self.width - 25, 2, 20, 20, "X", self, ISStewPrepWindow.onClose)
    self.closeBtn:initialise()
    self.closeBtn:instantiate()
    self:addChild(self.closeBtn)

    self:performScan()
end

function ISStewPrepWindow:performScan()
    self.availablePots = Stewy_FindCurrentPots(self.player)

    self.availableFood = {}
    if #self.availablePots > 0 then
        self.availableFood = Stewy_GetValidIngredients(self.player, self.availablePots[1])
    end

    print("[Stewy] Pots: " .. #self.availablePots .. " | Valid food: " .. #self.availableFood)

    self.potCountLabel:setName("Found " .. #self.availablePots .. " Pot(s) Ready")
    self.statusLabel:setName("Found " .. #self.availableFood .. " valid ingredient(s)")

    self.foodListPanel:clear()
    for i, item in ipairs(self.availableFood) do
        local displayName = item:getName() or "Unknown"
        local suffix = Stewy_GetFoodSuffix(item)
        if suffix ~= "" then displayName = displayName .. suffix end
        self.foodListPanel:addItem(displayName, {index = i, item = item, selected = false})
    end
end

function ISStewPrepWindow:drawFoodItem(y, item, alt)
    local itemData = item.item
    if not itemData then return y + self.itemheight end
    if itemData.selected then
        self:drawRect(0, y, self:getWidth(), self.itemheight, 0.3, 0.2, 0.6, 0.2)
        self:drawText("[X] " .. item.text, 10, y + 2, 0.3, 1.0, 0.3, 1.0, self.font)
    else
        self:drawText("[ ] " .. item.text, 10, y + 2, 0.9, 0.9, 0.9, 1.0, self.font)
    end
    return y + self.itemheight
end

function ISStewPrepWindow:prerender() ISPanel.prerender(self) end

function ISStewPrepWindow:onClose()
    self:setVisible(false)
    self:removeFromUIManager()
end

-- ============================================================================
-- EXECUTE: Build queue and start one-at-a-time timer processing
--
-- WHY NOT BATCH? ISAddItemInRecipe:isValid() checks that the recipe base
-- matches the pot's current type. After the first add, Base.Pot transforms
-- to PotOfStew, so remaining items with the Base.Pot recipe fail validation.
--
-- WHY NOT BUSY DETECTION? We tried isPerformingAction() and checking
-- ISTimedActionQueue.queues — neither reliably detects when an
-- ISAddItemInRecipe action is running. The player never appeared "busy."
--
-- SOLUTION: Fixed timer. Queue ONE item, wait DELAY_TICKS for the animation
-- to complete, then re-find pots (fresh references) + re-find recipe
-- (pot type may have changed) + queue the next item.
-- ============================================================================
StewyMod.queue = {}
StewyMod.queuePotAssign = {}
StewyMod.queuePlayer = nil
StewyMod.queueActive = false
StewyMod.queueTotal = 0
StewyMod.queueSent = 0
StewyMod.tickCounter = 0
StewyMod.lastActionTick = 0
-- 4 seconds at ~60 ticks/sec. Must be longer than the ISAddItemInRecipe
-- animation or items will be skipped. Too short = stale references.
-- Too long = just slower. Err on the side of too long.
StewyMod.DELAY_TICKS = 240

function StewyMod.onTick()
    StewyMod.tickCounter = StewyMod.tickCounter + 1
    if not StewyMod.queueActive then return end

    local player = StewyMod.queuePlayer
    if not player then StewyMod.queueActive = false; return end

    -- Wait for delay between actions
    if (StewyMod.tickCounter - StewyMod.lastActionTick) < StewyMod.DELAY_TICKS then
        return
    end

    -- Queue empty = done
    if #StewyMod.queue == 0 then
        StewyMod.queueActive = false
        player:Say("Done! Added " .. StewyMod.queueSent .. " of " .. StewyMod.queueTotal .. " items.")
        print("[Stewy] Finished: " .. StewyMod.queueSent .. "/" .. StewyMod.queueTotal)
        return
    end

    -- Pop next item and its pot assignment
    local ingredient = table.remove(StewyMod.queue, 1)
    local potIdx = table.remove(StewyMod.queuePotAssign, 1)

    -- Re-find pots FRESH every time (references go stale after transforms)
    local pots = Stewy_FindCurrentPots(player)
    if #pots == 0 then
        StewyMod.queueActive = false
        player:Say("No pots available!")
        print("[Stewy] No pots found, stopping")
        return
    end

    -- Map requested pot index to current pots
    local actualIdx = ((potIdx - 1) % #pots) + 1
    local potItem = pots[actualIdx]

    -- Verify ingredient still exists in inventory
    if not ingredient:getContainer() then
        print("[Stewy] Ingredient gone: " .. tostring(ingredient:getName()))
        return  -- skip, will try next on next tick cycle
    end

    -- Clear recipe cache for this pot type (it may have transformed)
    -- so we get a fresh recipe match
    local potType = potItem:getFullType() or ""
    StewyMod.evolvedRecipes[potType] = nil

    -- Find recipe for the pot's CURRENT type
    local recipe = Stewy_FindStewRecipe(potItem)
    if not recipe then
        print("[Stewy] No recipe for " .. potType .. ", skipping")
        return
    end

    -- Queue ONE timed action
    local ok, err = pcall(function()
        ISTimedActionQueue.add(ISAddItemInRecipe:new(player, recipe, potItem, ingredient))
    end)

    if ok then
        StewyMod.queueSent = StewyMod.queueSent + 1
        StewyMod.lastActionTick = StewyMod.tickCounter
        print("[Stewy] Added (" .. StewyMod.queueSent .. "/" .. StewyMod.queueTotal .. "): "
            .. tostring(ingredient:getName()) .. " -> pot " .. actualIdx .. " (" .. potType .. ")")
    else
        print("[Stewy] ERROR: " .. tostring(err))
    end
end

Events.OnTick.Add(StewyMod.onTick)

function ISStewPrepWindow:onExecute()
    self.errorLabel:setName("")

    local selectedItems = {}
    for _, entry in ipairs(self.foodListPanel.items) do
        local itemData = entry.item
        if itemData and itemData.selected and itemData.item then
            table.insert(selectedItems, itemData.item)
        end
    end

    if #selectedItems == 0 then
        self.errorLabel:setName("Select at least one ingredient!")
        return
    end

    local numPots = #self.availablePots
    if numPots == 0 then
        self.errorLabel:setName("No pots found!")
        return
    end

    -- Round-robin assign items to pots
    StewyMod.queue = {}
    StewyMod.queuePotAssign = {}
    local potIdx = 1
    for _, item in ipairs(selectedItems) do
        table.insert(StewyMod.queue, item)
        table.insert(StewyMod.queuePotAssign, potIdx)
        potIdx = (potIdx % numPots) + 1
    end

    StewyMod.queuePlayer = self.player
    StewyMod.queueTotal = #StewyMod.queue
    StewyMod.queueSent = 0
    StewyMod.lastActionTick = 0  -- process first item immediately
    StewyMod.queueActive = true

    -- Log the plan
    for i = 1, numPots do
        local count = 0
        for _, p in ipairs(StewyMod.queuePotAssign) do
            if p == i then count = count + 1 end
        end
        print("[Stewy] Pot " .. i .. ": " .. count .. " items planned")
    end

    self.player:Say("Prepping " .. #selectedItems .. " items into " .. numPots .. " pot(s)...")
    self:onClose()
end

-- ============================================================================
-- WINDOW OPEN/CLOSE
-- ============================================================================
StewyMod.stewyWindow = nil

StewyMod.openWindow = function(playerNum)
    if type(playerNum) ~= "number" then playerNum = 0 end
    local player = getSpecificPlayer(playerNum)
    if not player then
        print("[Stewy] No player for playerNum=" .. tostring(playerNum))
        return
    end

    if StewyMod.stewyWindow and StewyMod.stewyWindow:getIsVisible() then
        StewyMod.stewyWindow:onClose()
        StewyMod.stewyWindow = nil
        return
    end

    local w, h = 420, 520
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()

    StewyMod.stewyWindow = ISStewPrepWindow:new((screenW - w) / 2, (screenH - h) / 2, w, h, player)
    StewyMod.stewyWindow:initialise()
    StewyMod.stewyWindow:addToUIManager()

    local origMouseUp = ISScrollingListBox.onMouseUp
    StewyMod.stewyWindow.foodListPanel.onMouseUp = function(self2, x2, y2)
        if origMouseUp then origMouseUp(self2, x2, y2) end
        local row = self2:rowAt(x2, y2)
        if row and row > 0 and row <= #self2.items then
            local itemData = self2.items[row].item
            if itemData then itemData.selected = not itemData.selected end
        end
    end

    print("[Stewy] Window opened.")
end

-- ============================================================================
-- CONTEXT MENU HOOKS
-- ============================================================================
StewyMod.onInventoryMenu = function(player, context, items)
    context:addOption("Stewy: Prep Stew Ingredients", player, StewyMod.openWindow)
end
Events.OnFillInventoryObjectContextMenu.Add(StewyMod.onInventoryMenu)

StewyMod.onWorldMenu = function(playerNum, context, worldObjects, test)
    if test then return end
    context:addOption("Stewy: Prep Stew Ingredients", playerNum, StewyMod.openWindow)
end
Events.OnFillWorldObjectContextMenu.Add(StewyMod.onWorldMenu)

print("[Stewy] >>> INITIALIZATION COMPLETE <<<")
