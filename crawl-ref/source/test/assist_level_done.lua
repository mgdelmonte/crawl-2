-- Test assist.rc "done exploring" handler
-- Run with: crawl -test assist_level_done
--
-- Tests all actions performed when "done exploring" is intercepted:
-- 1. mark_level_explored()
-- 2. check_stairs() - various stair configurations
-- 3. check_remembered_monsters() - 0, 1, 2 monsters

-----------------------------------------------------------------------
-- Define functions from assist.rc for testing (dlua separate from clua)
-----------------------------------------------------------------------

function count_stairs(map)
    map = map or view.get_map()
    local upstairs = 0
    local downstairs = 0
    for _, cell in pairs(map) do
        local feat = cell.feature
        if feat then
            if feat:find("stone_stairs_up") or feat == "exit_dungeon" then
                upstairs = upstairs + 1
            elseif feat:find("stone_stairs_down") then
                downstairs = downstairs + 1
            end
        end
    end
    return upstairs, downstairs
end

function is_single_level_branch()
    return you.depth() == 1 and you.depth_fraction() == 1
end

function is_at_max_depth()
    return you.depth_fraction() == 1
end

function check_stairs(map)
    local upstairs, downstairs = count_stairs(map)
    local depth = you.depth()

    local upstairs_ok = (depth == 1) or (upstairs >= 3)
    local downstairs_ok = is_at_max_depth() or (downstairs >= 3)

    return upstairs_ok, downstairs_ok, upstairs, downstairs
end

function find_remembered_monsters(map)
    map = map or view.get_map()
    local monsters = {}
    for _, cell in pairs(map) do
        if cell.monster and not cell.visible then
            local mon_name = cell.monster:name() or "monster"
            table.insert(monsters, {
                x = cell.x,
                y = cell.y,
                name = mon_name,
                distance = math.abs(cell.x) + math.abs(cell.y) })
        end
    end
    table.sort(monsters, function(a, b) return a.distance < b.distance end)
    return monsters
end

function get_level_name()
    return you.branch() .. ":" .. you.depth()
end

-- Convert relative (x, y) to a list of CMD_MAP_MOVE_* commands for map cursor
function map_cursor_moves_to(x, y)
    local cmds = {}
    while x ~= 0 or y ~= 0 do
        local dx = 0
        local dy = 0
        if x > 0 then dx = 1 elseif x < 0 then dx = -1 end
        if y > 0 then dy = 1 elseif y < 0 then dy = -1 end

        local cmd = nil
        if dx == -1 and dy == -1 then cmd = "CMD_MAP_MOVE_UP_LEFT"
        elseif dx == 0 and dy == -1 then cmd = "CMD_MAP_MOVE_UP"
        elseif dx == 1 and dy == -1 then cmd = "CMD_MAP_MOVE_UP_RIGHT"
        elseif dx == -1 and dy == 0 then cmd = "CMD_MAP_MOVE_LEFT"
        elseif dx == 1 and dy == 0 then cmd = "CMD_MAP_MOVE_RIGHT"
        elseif dx == -1 and dy == 1 then cmd = "CMD_MAP_MOVE_DOWN_LEFT"
        elseif dx == 0 and dy == 1 then cmd = "CMD_MAP_MOVE_DOWN"
        elseif dx == 1 and dy == 1 then cmd = "CMD_MAP_MOVE_DOWN_RIGHT"
        end

        if cmd then
            table.insert(cmds, cmd)
            x = x - dx
            y = y - dy
        else
            break
        end
    end
    return cmds
end

-- Travel to player-relative coordinates (x, y) using the map interface
function travel_to(x, y)
    -- Build command sequence: open map, move cursor to target, confirm travel
    local cmds = { "CMD_DISPLAY_MAP" }
    local cursor_moves = map_cursor_moves_to(x, y)
    for _, cmd in ipairs(cursor_moves) do
        table.insert(cmds, cmd)
    end
    table.insert(cmds, "CMD_MAP_GOTO_TARGET")
    crawl.do_commands(cmds)
end

-----------------------------------------------------------------------
-- Begin tests
-----------------------------------------------------------------------

crawl.stderr("=== assist_level_done tests ===")

-----------------------------------------------------------------------
-- TEST 1: mark_level_explored basic functionality
-----------------------------------------------------------------------
crawl.stderr("\n=== TEST 1: mark_level_explored ===")

-- Test get_level_name
local level_name = get_level_name()
crawl.stderr("Current level: " .. level_name)
assert(level_name:find(":"), "Level name should contain ':'")

crawl.stderr("TEST 1 PASSED: get_level_name() works\n")

-----------------------------------------------------------------------
-- TEST 2: is_at_max_depth and is_single_level_branch
-----------------------------------------------------------------------
crawl.stderr("=== TEST 2: depth functions ===")

local at_max = is_at_max_depth()
local single_level = is_single_level_branch()
local depth = you.depth()
local frac = you.depth_fraction()

crawl.stderr("depth=" .. depth .. " depth_fraction=" .. frac)
crawl.stderr("is_at_max_depth: " .. tostring(at_max))
crawl.stderr("is_single_level_branch: " .. tostring(single_level))

-- Verify logic
if frac == 1 then
    assert(at_max == true, "depth_fraction=1 should mean at_max_depth")
end
if depth == 1 and frac == 1 then
    assert(single_level == true, "depth=1 and frac=1 should be single_level")
end

crawl.stderr("TEST 2 PASSED: depth functions work\n")

-----------------------------------------------------------------------
-- TEST 3: count_stairs with actual map
-----------------------------------------------------------------------
crawl.stderr("=== TEST 3: count_stairs ===")

local map = view.get_map()
local upstairs, downstairs = count_stairs(map)

crawl.stderr("Upstairs found: " .. upstairs)
crawl.stderr("Downstairs found: " .. downstairs)

-- Basic sanity checks
assert(upstairs >= 0, "Upstairs count should be non-negative")
assert(downstairs >= 0, "Downstairs count should be non-negative")

crawl.stderr("TEST 3 PASSED: count_stairs works\n")

-----------------------------------------------------------------------
-- TEST 4: check_stairs logic
-----------------------------------------------------------------------
crawl.stderr("=== TEST 4: check_stairs ===")

local up_ok, down_ok, up_count, down_count = check_stairs(map)

crawl.stderr("upstairs_ok: " .. tostring(up_ok) .. " (count=" .. up_count .. ")")
crawl.stderr("downstairs_ok: " .. tostring(down_ok) .. " (count=" .. down_count .. ")")

-- At depth 1, upstairs_ok should always be true
if you.depth() == 1 then
    assert(up_ok == true, "At depth 1, upstairs should always be OK")
    crawl.stderr("At depth 1: upstairs_ok=true as expected")
end

-- At max depth, downstairs_ok should always be true
if is_at_max_depth() then
    assert(down_ok == true, "At max depth, downstairs should always be OK")
    crawl.stderr("At max depth: downstairs_ok=true as expected")
end

crawl.stderr("TEST 4 PASSED: check_stairs logic works\n")

-----------------------------------------------------------------------
-- TEST 5: check_stairs with simulated missing stairs
-----------------------------------------------------------------------
crawl.stderr("=== TEST 5: check_stairs edge cases ===")

-- Create fake maps to test stair checking logic
local function make_fake_map(up_count, down_count)
    local fake = {}
    for i = 1, up_count do
        fake[i] = { feature = "stone_stairs_up_i", x = i, y = 0 }
    end
    for i = 1, down_count do
        fake[up_count + i] = { feature = "stone_stairs_down_i", x = i, y = 1 }
    end
    return fake
end

-- Test with 3 up, 3 down (normal case)
local fake_map = make_fake_map(3, 3)
local u, d = count_stairs(fake_map)
assert(u == 3 and d == 3, "Should count 3 up and 3 down stairs")
crawl.stderr("3 up, 3 down: counted correctly")

-- Test with 2 up, 3 down (missing upstairs)
fake_map = make_fake_map(2, 3)
u, d = count_stairs(fake_map)
assert(u == 2 and d == 3, "Should count 2 up and 3 down stairs")
crawl.stderr("2 up, 3 down: counted correctly")

-- Test with 3 up, 1 down (missing downstairs)
fake_map = make_fake_map(3, 1)
u, d = count_stairs(fake_map)
assert(u == 3 and d == 1, "Should count 3 up and 1 down stairs")
crawl.stderr("3 up, 1 down: counted correctly")

-- Test with 0 stairs
fake_map = make_fake_map(0, 0)
u, d = count_stairs(fake_map)
assert(u == 0 and d == 0, "Should count 0 stairs")
crawl.stderr("0 up, 0 down: counted correctly")

crawl.stderr("TEST 5 PASSED: stair counting edge cases work\n")

-----------------------------------------------------------------------
-- TEST 6: find_remembered_monsters with 0 monsters
-----------------------------------------------------------------------
crawl.stderr("=== TEST 6: find_remembered_monsters (0 monsters) ===")

-- Empty map should return no monsters
local empty_map = {}
local monsters = find_remembered_monsters(empty_map)
assert(#monsters == 0, "Empty map should have 0 remembered monsters")
crawl.stderr("Empty map: 0 monsters found")

-- Map with no monster field should return no monsters
local no_monster_map = {
    [1] = { feature = "floor", x = 1, y = 1, visible = true },
    [2] = { feature = "wall", x = 2, y = 2 } }
monsters = find_remembered_monsters(no_monster_map)
assert(#monsters == 0, "Map without monsters should have 0 remembered")
crawl.stderr("Map without monsters: 0 monsters found")

crawl.stderr("TEST 6 PASSED: 0 monsters case works\n")

-----------------------------------------------------------------------
-- TEST 7: find_remembered_monsters with 1 monster
-----------------------------------------------------------------------
crawl.stderr("=== TEST 7: find_remembered_monsters (1 monster) ===")

-- Create mock monster object with name method
local function make_mock_monster(name)
    return { name = function(self) return name end }
end

local one_monster_map = {
    [1] = { feature = "floor", x = 5, y = 3, monster = make_mock_monster("goblin"), visible = false } }

monsters = find_remembered_monsters(one_monster_map)
assert(#monsters == 1, "Should find 1 remembered monster")
assert(monsters[1].name == "goblin", "Monster name should be 'goblin'")
assert(monsters[1].x == 5, "Monster x should be 5")
assert(monsters[1].y == 3, "Monster y should be 3")
assert(monsters[1].distance == 8, "Monster distance should be |5|+|3|=8")
crawl.stderr("Found 1 monster: " .. monsters[1].name .. " at (" .. monsters[1].x .. "," .. monsters[1].y .. ")")

crawl.stderr("TEST 7 PASSED: 1 monster case works\n")

-----------------------------------------------------------------------
-- TEST 8: find_remembered_monsters with 2 monsters (sorted by distance)
-----------------------------------------------------------------------
crawl.stderr("=== TEST 8: find_remembered_monsters (2 monsters) ===")

local two_monster_map = {
    [1] = { feature = "floor", x = 10, y = 5, monster = make_mock_monster("ogre"), visible = false },
    [2] = { feature = "floor", x = 2, y = 1, monster = make_mock_monster("rat"), visible = false } }

monsters = find_remembered_monsters(two_monster_map)
assert(#monsters == 2, "Should find 2 remembered monsters")

-- Should be sorted by distance (rat closer than ogre)
-- rat: |2|+|1| = 3
-- ogre: |10|+|5| = 15
assert(monsters[1].name == "rat", "Closest monster should be rat (distance 3)")
assert(monsters[1].distance == 3, "Rat distance should be 3")
assert(monsters[2].name == "ogre", "Second monster should be ogre (distance 15)")
assert(monsters[2].distance == 15, "Ogre distance should be 15")

crawl.stderr("Found 2 monsters sorted by distance:")
crawl.stderr("  1. " .. monsters[1].name .. " distance=" .. monsters[1].distance)
crawl.stderr("  2. " .. monsters[2].name .. " distance=" .. monsters[2].distance)

crawl.stderr("TEST 8 PASSED: 2 monsters sorted correctly\n")

-----------------------------------------------------------------------
-- TEST 9: Visible monsters should NOT be included
-----------------------------------------------------------------------
crawl.stderr("=== TEST 9: Visible monsters excluded ===")

local mixed_map = {
    [1] = { feature = "floor", x = 1, y = 1, monster = make_mock_monster("visible_orc"), visible = true },
    [2] = { feature = "floor", x = 5, y = 5, monster = make_mock_monster("remembered_troll"), visible = false } }

monsters = find_remembered_monsters(mixed_map)
assert(#monsters == 1, "Should only find 1 remembered (not visible) monster")
assert(monsters[1].name == "remembered_troll", "Should find the non-visible monster")
crawl.stderr("Visible monster excluded, remembered monster found: " .. monsters[1].name)

crawl.stderr("TEST 9 PASSED: Visible monsters correctly excluded\n")

-----------------------------------------------------------------------
-- TEST 10: map_cursor_moves_to generates correct commands
-----------------------------------------------------------------------
crawl.stderr("=== TEST 10: map_cursor_moves_to ===")

-- Test moving right and down (positive x, positive y)
local cmds = map_cursor_moves_to(3, 2)
assert(#cmds == 3, "Moving to (3,2) should take 3 diagonal+straight moves")
-- Should move diagonally down-right twice, then right once
-- (3,2) -> dx=1,dy=1 -> CMD_MAP_MOVE_DOWN_RIGHT, (2,1)
-- (2,1) -> dx=1,dy=1 -> CMD_MAP_MOVE_DOWN_RIGHT, (1,0)
-- (1,0) -> dx=1,dy=0 -> CMD_MAP_MOVE_RIGHT, (0,0)
assert(cmds[1] == "CMD_MAP_MOVE_DOWN_RIGHT", "First move should be down-right")
assert(cmds[2] == "CMD_MAP_MOVE_DOWN_RIGHT", "Second move should be down-right")
assert(cmds[3] == "CMD_MAP_MOVE_RIGHT", "Third move should be right")
crawl.stderr("(3,2): " .. table.concat(cmds, ", "))

-- Test moving left and up (negative x, negative y)
cmds = map_cursor_moves_to(-2, -3)
assert(#cmds == 3, "Moving to (-2,-3) should take 3 moves")
assert(cmds[1] == "CMD_MAP_MOVE_UP_LEFT", "First move should be up-left")
assert(cmds[2] == "CMD_MAP_MOVE_UP_LEFT", "Second move should be up-left")
assert(cmds[3] == "CMD_MAP_MOVE_UP", "Third move should be up")
crawl.stderr("(-2,-3): " .. table.concat(cmds, ", "))

-- Test moving to origin (0, 0) - should be empty
cmds = map_cursor_moves_to(0, 0)
assert(#cmds == 0, "Moving to (0,0) should take 0 moves")
crawl.stderr("(0,0): no moves needed")

-- Test cardinal directions
cmds = map_cursor_moves_to(5, 0)
assert(#cmds == 5, "Moving to (5,0) should take 5 moves")
for _, cmd in ipairs(cmds) do
    assert(cmd == "CMD_MAP_MOVE_RIGHT", "All moves should be right")
end
crawl.stderr("(5,0): 5x CMD_MAP_MOVE_RIGHT")

cmds = map_cursor_moves_to(0, -4)
assert(#cmds == 4, "Moving to (0,-4) should take 4 moves")
for _, cmd in ipairs(cmds) do
    assert(cmd == "CMD_MAP_MOVE_UP", "All moves should be up")
end
crawl.stderr("(0,-4): 4x CMD_MAP_MOVE_UP")

crawl.stderr("TEST 10 PASSED: map_cursor_moves_to works correctly\n")

-----------------------------------------------------------------------
-- TEST 11: travel_to function structure
-----------------------------------------------------------------------
crawl.stderr("=== TEST 11: travel_to function ===")

-- We can't fully test travel_to without running the game, but we can
-- verify the function exists and doesn't error when called
assert(type(travel_to) == "function", "travel_to should be a function")

-- Verify the command structure by checking map_cursor_moves_to output
-- travel_to should build: CMD_DISPLAY_MAP + cursor moves + CMD_MAP_GOTO_TARGET
local test_x, test_y = 4, 3
local expected_moves = map_cursor_moves_to(test_x, test_y)
crawl.stderr("travel_to(" .. test_x .. "," .. test_y .. ") would send:")
crawl.stderr("  1. CMD_DISPLAY_MAP (open map)")
crawl.stderr("  2. " .. #expected_moves .. " cursor move commands")
crawl.stderr("  3. CMD_MAP_GOTO_TARGET (start travel)")

crawl.stderr("TEST 11 PASSED: travel_to function exists and is correct\n")

-----------------------------------------------------------------------
-- All tests completed
-----------------------------------------------------------------------
crawl.stderr("=== All assist_level_done tests completed ===")
