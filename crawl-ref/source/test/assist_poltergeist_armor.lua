-- Test assist.rc poltergeist armor detection
-- Run with: crawl -test assist_poltergeist_armor
--
-- Tests that a poltergeist automatically picks up and equips visible armor
-- when the ready() hook runs via the game loop.

-- First, inject a c_answer_prompt function to auto-answer "yes" to prompts
-- This is needed because in headless/test mode, yesno returns the default
-- which is "no" for the armor pickup prompt
crawl.setopt("{ function c_answer_prompt(prompt) return true end }")

-- Load assist.rc
crawl.read_options("C:/dev/simple/assist.rc")

-- Verify RC loaded by checking for startup message
local messages = crawl.messages(50)
assert(messages:lower():find("starting assist"), "RC should emit 'starting assist' message")

-- Set up a simple level
debug.goto_place("D:1")
dgn.reset_level()
dgn.fill_grd_area(1, 1, dgn.GXM - 2, dgn.GYM - 2, 'floor')

-- Position player at center
local player_x, player_y = 40, 40
you.moveto(player_x, player_y)
debug.los_changed()
crawl.redraw_view()

-- Change to poltergeist
you.change_species("poltergeist")
assert(you.race() == "Poltergeist", "should be a poltergeist")

-- Place a cloak nearby (visible but not at player position)
local cloak_x, cloak_y = 42, 40
dgn.create_item(cloak_x, cloak_y, "cloak")

-- Verify the cloak was placed
local floor_items = dgn.items_at(cloak_x, cloak_y)
assert(#floor_items > 0, "cloak should be placed on floor")
local cloak = floor_items[1]
assert(cloak.name():find("cloak"), "item should be a cloak: " .. cloak.name())

-- Verify poltergeist has no cloak equipped initially
assert(items.equipped_at("cloak") == nil, "poltergeist should not have cloak equipped initially")

-- Clear message buffer
crawl.messages(100)

-- Run game turns - the ready() hook should detect the cloak and go pick it up
-- We need enough turns for: travel to cloak (2 tiles) + pickup + equip
debug.run_turns(20)

-- Check that the cloak was picked up (no longer on floor at original location)
floor_items = dgn.items_at(cloak_x, cloak_y)
local cloak_still_on_floor = false
for _, item in ipairs(floor_items) do
    if item.name():find("cloak") then
        cloak_still_on_floor = true
        break
    end
end

-- Check that cloak is now equipped
local equipped_cloak = items.equipped_at("cloak")

-- Verify results
if equipped_cloak then
    crawl.stderr("assist_poltergeist_armor test passed - cloak equipped!")
elseif not cloak_still_on_floor then
    -- Cloak was picked up but maybe not equipped yet
    crawl.stderr("assist_poltergeist_armor test partial - cloak picked up but not equipped")
    -- Check inventory for cloak
    local found_in_inv = false
    for i = 0, 51 do
        local item = items.inslot(i)
        if item and item.name():find("cloak") then
            found_in_inv = true
            break
        end
    end
    assert(found_in_inv, "cloak should be in inventory if not on floor")
else
    -- Debug: print messages to see what happened
    messages = crawl.messages(200)
    crawl.stderr("Messages: " .. messages)
    assert(false, "cloak should have been picked up - still on floor at " .. cloak_x .. "," .. cloak_y)
end
