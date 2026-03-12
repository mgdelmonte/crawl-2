-- Test for sneak_path() function across three map layouts
local temp_rc = "C:/dev/crawl/crawl-ref/source/test_safest_explore_temp.rc"
crawl.read_options(temp_rc)

local messages = crawl.messages(50)
assert(messages:lower():find("starting assist"), "RC didn't load: " .. messages)

-- Helper: set up a small room with walls, return player-relative target coords
-- map_str is an array of strings; '#' = wall, ' '/'.' = floor, 'x' = target, '@' = player
local function setup_map(map_str)
    debug.goto_place("D:1")
    dgn.reset_level()
    -- Fill everything with walls first
    dgn.fill_grd_area(0, 0, dgn.GXM - 1, dgn.GYM - 1, 'rock_wall')

    local base_x, base_y = 40, 40
    local px, py, tx, ty

    for row, line in ipairs(map_str) do
        for col = 1, #line do
            local ch = line:sub(col, col)
            local mx = base_x + col - 1
            local my = base_y + row - 1
            if ch == '#' then
                dgn.grid(mx, my, "rock_wall")
            elseif ch == ' ' or ch == '.' or ch == 'x' or ch == '@' then
                dgn.grid(mx, my, "floor")
                if ch == '@' then px, py = mx, my end
                if ch == 'x' then tx, ty = mx, my end
            end
        end
    end

    assert(px and py, "No player '@' in map")
    assert(tx and ty, "No target 'x' in map")

    -- Reveal the entire map: fill everything with floor first,
    -- let the player see it all, then place the walls.
    dgn.fill_grd_area(base_x, base_y,
        base_x + #map_str[1] - 1, base_y + #map_str - 1, 'floor')
    you.moveto(px, py)
    debug.los_changed()
    crawl.redraw_view()

    -- Now place the walls (map_knowledge already recorded the floor)
    for row, line in ipairs(map_str) do
        for col = 1, #line do
            if line:sub(col, col) == '#' then
                dgn.grid(base_x + col - 1, base_y + row - 1, "rock_wall")
            end
        end
    end
    debug.los_changed()
    crawl.redraw_view()

    return tx - px, ty - py
end

-- Helper: call sneak_path from clua via setopt, parse result from messages
local function run_sneak_path(rel_tx, rel_ty)
    crawl.messages(100) -- clear
    crawl.setopt(string.format([[{
        local result = sneak_path(view.get_map(), %d, %d)
        if result then
            local parts = {}
            local pw_count = 0
            local last_x, last_y = 0, 0
            for i, step in ipairs(result) do
                parts[#parts + 1] = step.x .. ";" .. step.y
                    .. (step.passwall and ";PW" or "")
                if step.passwall then pw_count = pw_count + 1 end
                last_x, last_y = step.x, step.y
            end
            crawl.mpr("SP_RESULT: len=" .. #result
                .. " pw=" .. pw_count
                .. " end=(" .. last_x .. "," .. last_y .. ")"
                .. " path=" .. table.concat(parts, " "))
        else
            crawl.mpr("SP_RESULT: nil")
        end
    }]], rel_tx, rel_ty))

    local msg = crawl.messages(100)
    -- Extract just the LAST SP_RESULT line (messages are cumulative)
    local last_sp
    for line in msg:gmatch("SP_RESULT:[^\n]+") do last_sp = line end
    return last_sp or "SP_RESULT: nil"
end

-- Helper: parse path from an SP_RESULT line
local function parse_path(sp_line)
    local path = {}
    local path_str = sp_line:match("path=(.+)$")
    if not path_str then return path end
    for x, y, pw in path_str:gmatch("(%-?%d+);(%-?%d+)(;?%a*)") do
        path[#path + 1] = {
            x = tonumber(x), y = tonumber(y),
            passwall = (pw == ";PW") }
    end
    return path
end

-- Helper: check that path ends on target
local function assert_ends_on_target(path, rel_tx, rel_ty, label)
    assert(#path > 0, label .. ": path is empty")
    local last = path[#path]
    assert(last.x == rel_tx and last.y == rel_ty,
        label .. ": path ends at (" .. last.x .. "," .. last.y
        .. ") expected (" .. rel_tx .. "," .. rel_ty .. ")")
end

-- Helper: check that the second-to-last step is adjacent to target
local function assert_penultimate_adjacent(path, rel_tx, rel_ty, label)
    if #path < 2 then return end -- already adjacent at start
    local pen = path[#path - 1]
    local dx = math.abs(pen.x - rel_tx)
    local dy = math.abs(pen.y - rel_ty)
    assert(dx <= 1 and dy <= 1,
        label .. ": penultimate step (" .. pen.x .. "," .. pen.y
        .. ") not adjacent to target")
end

-- Helper: check that last step (the attack) is NOT passwall
local function assert_attack_not_passwall(path, label)
    assert(not path[#path].passwall,
        label .. ": final attack step must not be passwall")
end

crawl.stderr("=== sneak_path test starting ===")

-----------------------------------------------------
-- Map 1: Wall separating player and target, gap at bottom
-- Player must go around the wall via the bottom row
-----------------------------------------------------
crawl.stderr("--- Map 1: wall with bottom gap ---")
local rel_tx, rel_ty = setup_map({
    "########",
    "#.x#..@#",
    "#..#...#",
    "#..#...#",
    "#......#",
    "########" })

crawl.stderr("  target relative: (" .. rel_tx .. "," .. rel_ty .. ")")
assert(rel_tx == -4 and rel_ty == 0, "Map 1: unexpected target coords")

local sp = run_sneak_path(rel_tx, rel_ty)
crawl.stderr("  " .. sp)

assert(not sp:find("SP_RESULT: nil"), "Map 1: sneak_path returned nil")

local path1 = parse_path(sp)
crawl.stderr("  parse_path: " .. #path1 .. " steps")
assert_ends_on_target(path1, rel_tx, rel_ty, "Map 1")
assert_penultimate_adjacent(path1, rel_tx, rel_ty, "Map 1")
assert_attack_not_passwall(path1, "Map 1")

-- The path should go around the wall (via y=3 in player-relative)
-- Verify it passes through positive y values (goes south)
local went_south = false
for _, step in ipairs(path1) do
    if step.y >= 2 then went_south = true; break end
end
assert(went_south, "Map 1: path should go south around the wall")

crawl.stderr("  Map 1 PASSED: path len=" .. #path1)

-----------------------------------------------------
-- Map 2: Target in corner, wall separating
-----------------------------------------------------
crawl.stderr("--- Map 2: corner target with wall ---")
rel_tx, rel_ty = setup_map({
    "########",
    "#x.#..@#",
    "#..#...#",
    "#..#...#",
    "#......#",
    "########" })

crawl.stderr("  target relative: (" .. rel_tx .. "," .. rel_ty .. ")")
assert(rel_tx == -5 and rel_ty == 0, "Map 2: unexpected target coords")

sp = run_sneak_path(rel_tx, rel_ty)
crawl.stderr("  " .. sp)

assert(not sp:find("SP_RESULT: nil"), "Map 2: sneak_path returned nil")

local path2 = parse_path(sp)
assert_ends_on_target(path2, rel_tx, rel_ty, "Map 2")
assert_penultimate_adjacent(path2, rel_tx, rel_ty, "Map 2")
assert_attack_not_passwall(path2, "Map 2")

-- Also must go around the wall
went_south = false
for _, step in ipairs(path2) do
    if step.y >= 2 then went_south = true; break end
end
assert(went_south, "Map 2: path should go south around the wall")

crawl.stderr("  Map 2 PASSED: path len=" .. #path2)

-----------------------------------------------------
-- Map 3: L-shaped wall, player below target
-----------------------------------------------------
crawl.stderr("--- Map 3: L-shaped wall ---")
rel_tx, rel_ty = setup_map({
    "########",
    "#.x....#",
    "#.##...#",
    "#..#...#",
    "#...@..#",
    "########" })

crawl.stderr("  target relative: (" .. rel_tx .. "," .. rel_ty .. ")")
assert(rel_tx == -2 and rel_ty == -3, "Map 3: unexpected target coords")

sp = run_sneak_path(rel_tx, rel_ty)
crawl.stderr("  " .. sp)

assert(not sp:find("SP_RESULT: nil"), "Map 3: sneak_path returned nil")

local path3 = parse_path(sp)
assert_ends_on_target(path3, rel_tx, rel_ty, "Map 3")
assert_penultimate_adjacent(path3, rel_tx, rel_ty, "Map 3")
assert_attack_not_passwall(path3, "Map 3")

-- The L-wall blocks direct approach from below-right.
-- Path should go around the wall (left or right), not through it.
-- Verify path length is reasonable (not excessively long)
assert(#path3 <= 8, "Map 3: path unreasonably long (" .. #path3 .. " steps)")

crawl.stderr("  Map 3 PASSED: path len=" .. #path3)

-----------------------------------------------------
-- Map 4: Open room with unseen area above.
-- Frontier is along the top wall. Player should
-- hug the bottom wall to avoid revealing unseen cells.
-----------------------------------------------------
crawl.stderr("--- Map 4: open room, unseen above ---")

-- This map needs special setup: the area above the top wall
-- must remain unseen. We only reveal the interior floor cells.
do
    debug.goto_place("D:1")
    dgn.reset_level()
    dgn.fill_grd_area(0, 0, dgn.GXM - 1, dgn.GYM - 1, 'rock_wall')

    local map4 = {
        "#......#",
        "#......#",
        "#......#",
        "#......#",
        "#......#",
        "#......#",
        "#x.....#",
        "#.....@#",
        "########" }

    local base_x, base_y = 40, 40
    local px, py, tx, ty

    -- Place actual geometry
    for row, line in ipairs(map4) do
        for col = 1, #line do
            local ch = line:sub(col, col)
            local mx = base_x + col - 1
            local my = base_y + row - 1
            if ch == '#' then
                dgn.grid(mx, my, "rock_wall")
            elseif ch == '.' or ch == 'x' or ch == '@' then
                dgn.grid(mx, my, "floor")
                if ch == '@' then px, py = mx, my end
                if ch == 'x' then tx, ty = mx, my end
            end
        end
    end

    assert(px and py, "Map 4: no player")
    assert(tx and ty, "Map 4: no target")

    -- Reveal only the floor cells (not the area above the top wall).
    -- Place them as floor, move player there briefly, then restore.
    -- We reveal row by row: place floor, visit a cell in that row.
    -- Simpler: just fill the interior with floor, stand at player pos.
    -- The top wall at base_y is rock_wall, so cells above (base_y-1 etc)
    -- remain unseen = frontier exists on the top interior row.

    -- Temporarily make interior all floor so player can see it
    for row, line in ipairs(map4) do
        for col = 1, #line do
            local ch = line:sub(col, col)
            if ch ~= '#' then
                dgn.grid(base_x + col - 1, base_y + row - 1, "floor")
            end
        end
    end

    you.moveto(px, py)
    debug.los_changed()
    crawl.redraw_view()

    -- Restore walls
    for row, line in ipairs(map4) do
        for col = 1, #line do
            if line:sub(col, col) == '#' then
                dgn.grid(base_x + col - 1, base_y + row - 1, "rock_wall")
            end
        end
    end

    -- The top row of the map (row 1) is "#......#" — these are floor cells
    -- at base_y+0 = 40. The area above (y=39 and below) is rock_wall that
    -- the player has never seen, so the floor cells at y=40 are frontier.
    -- Actually the top row IS the wall row. Row 1 = "#......#" means
    -- walls at columns 1 and 8, floor at columns 2-7, at y = base_y + 0 = 40.
    -- Above that (y=39) is unseen rock_wall, so the floor cells at y=40
    -- are frontier cells (adjacent to unseen).

    debug.los_changed()
    crawl.redraw_view()

    rel_tx, rel_ty = tx - px, ty - py
end

crawl.stderr("  target relative: (" .. rel_tx .. "," .. rel_ty .. ")")
assert(rel_tx == -5 and rel_ty == -1, "Map 4: unexpected target coords")

sp = run_sneak_path(rel_tx, rel_ty)
crawl.stderr("  " .. sp)

assert(not sp:find("SP_RESULT: nil"), "Map 4: sneak_path returned nil")

local path4 = parse_path(sp)
assert_ends_on_target(path4, rel_tx, rel_ty, "Map 4")
assert_penultimate_adjacent(path4, rel_tx, rel_ty, "Map 4")
assert_attack_not_passwall(path4, "Map 4")

-- The path should stay along the bottom rows (high y values in
-- player-relative coords, i.e. y >= -1) to avoid the frontier at top.
-- No step (except the final attack) should go above y = -3 relative
-- (that's row 5 of the map, 3 rows above player).
local max_north = 0
for i, step in ipairs(path4) do
    if i < #path4 and step.y < max_north then
        max_north = step.y
    end
end
crawl.stderr("  most northern step y=" .. max_north)
-- Player is at row 8 (y=0 relative), target at row 7 (y=-1).
-- Hugging the bottom means path stays at y=0 or y=-1.
-- Allow y=-2 as slight tolerance but no further north.
assert(max_north >= -2,
    "Map 4: path went too far north (y=" .. max_north
    .. "), should hug bottom wall")

crawl.stderr("  Map 4 PASSED: path len=" .. #path4)

-----------------------------------------------------
-- Map 5: Diagonal corridor with wall cover
-- Optimal route goes up-left behind the diagonal wall
-- rather than straight toward the target.
-----------------------------------------------------
crawl.stderr("--- Map 5: diagonal corridor with wall cover ---")

do
    debug.goto_place("D:1")
    dgn.reset_level()
    dgn.fill_grd_area(0, 0, dgn.GXM - 1, dgn.GYM - 1, 'rock_wall')

    local map5 = {
        "....##..",
        "....x..",
        "..#....#",
        "..#..#.",
        ".#....",
        ".#..#",
        "#...#",
        "#@#",
        "..#" }

    local base_x, base_y = 40, 40
    local px, py, tx, ty

    -- Place actual geometry
    for row, line in ipairs(map5) do
        for col = 1, #line do
            local ch = line:sub(col, col)
            local mx = base_x + col - 1
            local my = base_y + row - 1
            if ch == '#' then
                dgn.grid(mx, my, "rock_wall")
            elseif ch == '.' or ch == 'x' or ch == '@' then
                dgn.grid(mx, my, "floor")
                if ch == '@' then px, py = mx, my end
                if ch == 'x' then tx, ty = mx, my end
            end
        end
    end

    assert(px and py, "Map 5: no player")
    assert(tx and ty, "Map 5: no target")

    -- Reveal all cells: temporarily make EVERYTHING floor (including walls)
    -- so the player can see through the whole map, then restore walls.
    for row, line in ipairs(map5) do
        for col = 1, #line do
            dgn.grid(base_x + col - 1, base_y + row - 1, "floor")
        end
    end

    you.moveto(px, py)
    debug.los_changed()
    crawl.redraw_view()

    -- Restore walls
    for row, line in ipairs(map5) do
        for col = 1, #line do
            if line:sub(col, col) == '#' then
                dgn.grid(base_x + col - 1, base_y + row - 1, "rock_wall")
            end
        end
    end

    debug.los_changed()
    crawl.redraw_view()

    rel_tx, rel_ty = tx - px, ty - py
end

crawl.stderr("  target relative: (" .. rel_tx .. "," .. rel_ty .. ")")
assert(rel_tx == 3 and rel_ty == -6, "Map 5: unexpected target coords ("
    .. rel_tx .. "," .. rel_ty .. ")")

sp = run_sneak_path(rel_tx, rel_ty)
crawl.stderr("  " .. sp)

assert(not sp:find("SP_RESULT: nil"), "Map 5: sneak_path returned nil")

local path5 = parse_path(sp)
assert_ends_on_target(path5, rel_tx, rel_ty, "Map 5")
assert_penultimate_adjacent(path5, rel_tx, rel_ty, "Map 5")
assert_attack_not_passwall(path5, "Map 5")

-- The optimal path goes left (negative x) to use wall cover.
-- Verify at least one step has x < 0.
local went_left = false
for _, step in ipairs(path5) do
    if step.x < 0 then went_left = true; break end
end
assert(went_left, "Map 5: path should go left behind the wall for cover")

-- The path should not be excessively long
assert(#path5 <= 12, "Map 5: path unreasonably long (" .. #path5 .. " steps)")

crawl.stderr("  Map 5 PASSED: path len=" .. #path5)

crawl.stderr("=== All sneak_path tests PASSED ===")
