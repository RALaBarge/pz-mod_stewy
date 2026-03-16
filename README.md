# Stewy - Automated Stew Prep for Project Zomboid Build 42

**Author:** jinx_player  
**Version:** 1.1  
**Requires:** Project Zomboid Build 42.0+

## What It Does

Tired of the RSI from making stew? Stewy automates the tedious process of dragging
ingredients into cooking pots one at a time. Right-click anywhere to open the Stewy
window, select your ingredients, hit PREP, and watch your character add them all
automatically — distributed evenly across however many pots you have.

## Installation

1. Drop the `Stewy/` folder into `~/Zomboid/mods/` (Linux) or `%UserProfile%\Zomboid\mods\` (Windows)
2. Enable the mod in the main menu: **Mods** screen
3. **⚠️ CRITICAL ⚠️** Also enable it **per-save**: **Load → More Options → Mods**

That third step is a Build 42 requirement that bites everyone. The mod loads its Lua
globally (you'll see `[Stewy] SCRIPT FILE LOADED` in `console.txt`), but it will NOT
hook into your running game unless you also activate it on your specific save file.

## How To Use

1. Have cooking pot(s) with water in your inventory (or stew-in-progress)
2. Have food ingredients in your inventory
3. Right-click on anything (world or inventory) → **"Stewy: Prep Stew Ingredients"**
4. Select ingredients from the list (click to toggle [X])
5. Hit **PREP ALL POTS**
6. **Stand still!** Your character will add ingredients one at a time. Each add is a
   timed action with an animation — don't move, open menus, or interact with anything
   until you see the "Done!" speech bubble.

## File Structure

```
Stewy/
├── 42/                              ← Version folder (matches Build 42.x.x)
│   ├── mod.info                     ← Mod metadata (MUST be inside version folder)
│   └── media/
│       └── lua/
│           └── client/              ← Client-side Lua
│               └── Stewy_Main.lua   ← All mod logic
├── common/                          ← Shared assets folder (MUST EXIST, even if empty)
└── README.md                        ← This file
```

## Known Behaviors

- **Evolved recipe matching**: PZ has separate evolved recipes for pot stew vs bucket
  stew. Stewy matches the recipe based on the container type (`Base.Pot` → pot stew
  recipe, `Base.BucketOfStew` → bucket stew recipe) so you get the correct output.
  When stew is consumed from a pot, you get your pot back.

- **Only one ingredient adds at a time**: Each ingredient is a vanilla `ISAddItemInRecipe`
  timed action — the same thing that happens when you manually drag food onto a pot.
  Stewy just automates queuing them.

- **Queue stops if you interrupt**: Moving, opening a menu, or interacting cancels the
  timed action queue. This is standard PZ behavior for all timed actions.

## Debugging

Check `~/Zomboid/console.txt` for lines starting with `[Stewy]`:

```bash
cat ~/Zomboid/console.txt | grep Stewy
```

Key lines to look for:
- `SCRIPT FILE LOADED` + `INITIALIZATION COMPLETE` → Lua loaded correctly
- `Found pot in inventory: Base.Pot` → Pot detection working
- `Pots: 2 | Inv food: 12` → Scan results
- `Queue loaded: 8 items into 2 pot(s)` → Distribution started
- `Queue complete: 8/8` → All items processed
- `Error:` → Something went wrong (report this!)

---

# Build 42 Modding Guide (Lessons Learned The Hard Way)

This section documents everything we learned getting Stewy to work on B42.
Consider it a practical companion to the PZwiki modding pages.

## 1. Folder Structure

Build 42 introduced a new mod folder structure with **version folders** and a **common folder**.

```
YourMod/
├── 42/              ← Version folder. Named to match game build.
│   ├── mod.info     ← MUST be here, not at the root.
│   └── media/
│       └── lua/
│           ├── client/   ← UI, input handling, client-only logic
│           ├── server/   ← Server-side logic (MP)
│           └── shared/   ← Code loaded on both client and server
├── common/          ← Shared heavy assets (textures, models).
│                       MUST EXIST even if empty.
└── (optional files like README, poster.png, icon.png)
```

**Critical**: Both the version folder AND the `common/` folder must exist. Without
`common/`, PZ won't recognize the mod in `Zomboid/mods/`. The `common/` folder can
be completely empty.

**Version folder naming**: Use `42` to match all Build 42.x.x. You can be more
specific (`42.13`) but this means the mod won't load on 42.12 or 42.14. Most mods
just use `42`.

Reference: https://pzwiki.net/wiki/Mod_structure

## 2. mod.info Fields

Build 42 changed some field names. Using the old names silently fails.

```ini
# CORRECT (B42)
name=My Mod
id=MyMod
author=YourName
modversion=1.0
description=What it does
versionMin=42.0.0

# WRONG (B41 names - will silently fail or be ignored)
# version=1.0        ← Use "modversion" instead
# minVersion=42.0    ← Use "versionMin" instead
# maxVersion=42.99   ← Not commonly used in B42
```

Reference: https://pzwiki.net/wiki/Mod.info

## 3. Per-Save Mod Activation

**This is the #1 gotcha in B42 modding.**

Enabling a mod in the main menu Mods screen makes it globally available. But for it
to actually run in a game, you ALSO need to enable it on the specific save:

**Load → More Options → Mods**

Without this, the mod's Lua files load (you'll see prints in console.txt) but no
events will fire in-game. Your context menu hooks, tick handlers, etc. silently
do nothing.

## 4. Event Handler Pattern

B42 uses Kahlua (modified Lua 5.1). Local function references can be garbage-collected
after the file scope ends. Use **global table functions** for event handlers:

```lua
-- CORRECT: global table keeps strong references
MyMod = MyMod or {}

MyMod.onInventoryMenu = function(player, context, items)
    context:addOption("My Option", player, MyMod.doSomething)
end
Events.OnFillInventoryObjectContextMenu.Add(MyMod.onInventoryMenu)

-- WRONG: local may be garbage-collected
local function onInventoryMenu(player, context, items)  -- may silently disconnect
    context:addOption("My Option", nil, doSomething)
end
Events.OnFillInventoryObjectContextMenu.Add(onInventoryMenu)
```

Also, you MUST `require "ISInventoryPaneContextMenu"` before registering context
menu event handlers. Without this, the event system may not be initialized.

## 5. Context Menu Event Signatures

```lua
-- Inventory right-click: playerNum is an INTEGER, not a player object
-- Use getSpecificPlayer(playerNum) to get the actual player
Events.OnFillInventoryObjectContextMenu.Add(function(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    context:addOption("My Option", playerNum, myCallback)
end)

-- World right-click: same playerNum pattern, plus test flag
Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldObjects, test)
    if test then return end  -- PZ is probing, not displaying
    context:addOption("My Option", playerNum, myCallback)
end)
```

The `addOption` target argument (2nd param) becomes the 1st argument to your callback.

## 6. Item References Go Stale

When a timed action transforms an item (e.g., adding food to a pot changes
`Base.Pot` → `Base.BucketOfStew`), the old Java object reference becomes invalid.
Pre-queued timed actions pointing at the old reference will silently fail.

**Solution**: Use a tick-based processor that re-finds items from inventory before
each operation. See `StewyMod.onTick` in Stewy_Main.lua for an implementation.

## 7. Item Type Matching

Use `item:getFullType()` for module-qualified type strings (e.g., `"Base.Pot"`).
Be careful with substring matching — `string.find(ft, "Pot")` will match
`"VFX.SlicedPotato"`. Use exact matches or more specific patterns:

```lua
-- CORRECT
if ft == "Base.Pot" or string.find(ft, "CookingPot") then

-- WRONG - matches SlicedPotato, FlowerPot, etc.
if string.find(ft, "Pot") then
```

## 8. B42 Fluid System

Water in containers is tracked via FluidContainer, not as inventory items:

```lua
if item.getFluidContainer then
    local fc = item:getFluidContainer()
    if fc then
        local amount = fc:getAmount()  -- returns float, e.g. 1.5
    end
end
```

Always wrap in pcall() — the API may change between B42 subversions.

## 9. Kahlua Lua Quirks

PZ uses Kahlua, a modified Lua 5.1 embedded in Java. Some gotchas:

- **No ternary shorthand with method calls**: `obj.method and obj:method() or nil`
  will crash. Break into separate if/then lines.
- **pcall() is essential**: Java interop can throw RuntimeExceptions. Always wrap
  risky Java calls in pcall().
- **getmetatable() works**: You can probe Java object methods with
  `for k,v in pairs(getmetatable(obj).__index) do print(k) end`
- **Method names are Java**: Use Java naming conventions (camelCase).
  `getFullType()`, `getFluidContainer()`, `isRotten()`, etc.
- **instanceof()** is a global function: `instanceof(item, "Food")`,
  `instanceof(obj, "IsoWorldInventoryObject")`, etc.

## 10. Script Overrides (Changing Vanilla Items)

To change a vanilla item's properties, create a `.txt` file in `media/scripts/` that
redefines the item inside `module Base`. This **replaces the entire item definition**,
so you must include ALL original properties — not just the one you're changing.

```
/* stewy_overrides.txt */
module Base
{
    item BucketOfStew
    {
        DisplayCategory = Food,
        ItemType = base:food,
        Weight = 3.0,
        /* ... all other vanilla properties ... */
        ReplaceOnUse = Base.Pot,    /* <-- the one change we actually want */
    }
}
```

Do NOT use `imports { Base }` with your own module name — that creates a separate item
(`YourModule.BucketOfStew`) instead of overriding the vanilla one.

For safer overrides that don't stomp on other mods, consider Item Tweaker API.

## 11. Useful Resources

- **PZwiki Modding**: https://pzwiki.net/wiki/Modding
- **Mod Structure**: https://pzwiki.net/wiki/Mod_structure
- **mod.info**: https://pzwiki.net/wiki/Mod.info
- **Lua Events**: https://pzwiki.net/wiki/Lua_event
- **ISContextMenu**: https://pzwiki.net/wiki/ISContextMenu
- **Keyboard**: https://pzwiki.net/wiki/Keyboard
- **ModOptions**: https://pzwiki.net/wiki/ModOptions
- **B42 Mod Template**: https://github.com/LabX1/ProjectZomboid-Build42-ModTemplate
- **Event Stubs**: https://github.com/demiurgeQuantified/PZEventStubs
- **Unofficial JavaDocs**: https://projectzomboid.com/modding/
# pz-mod_stewy
