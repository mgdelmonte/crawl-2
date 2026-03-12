-- Test for safest_explore() function
local temp_rc = "C:/dev/crawl/crawl-ref/source/test_safest_explore_temp.rc"
crawl.read_options(temp_rc)

local messages = crawl.messages(50)
assert(messages:lower():find("starting assist"), "RC didn't load: " .. messages)

-- Set up level: open floor with walls at edges to create frontier cells
debug.goto_place("D:1")
dgn.reset_level()
-- Fill with floor, walls remain at boundaries creating frontiers
dgn.fill_grd_area(1, 1, dgn.GXM - 2, dgn.GYM - 2, 'floor')

-- Place some walls to create interesting frontier patterns
-- A wall block 10 cells away from player creates frontier at distance ~10
for x = 30, 35 do
    for y = 38, 42 do
        dgn.grid(x, y, "rock_wall")
    end
end

you.moveto(40, 40)
debug.los_changed()
crawl.redraw_view()

-- Clear messages
crawl.messages(100)

-- Call safest_explore() directly via clua setopt
crawl.setopt([[{
    local result = safest_explore()
    if result then
        crawl.mpr("SE_RESULT: x=" .. result.x .. " y=" .. result.y
            .. " dist=" .. result.best_dist
            .. " count=" .. result.count
            .. " cost=" .. result.path_cost
            .. " pathlen=" .. #result.path)
    else
        crawl.mpr("SE_RESULT: nil")
    end
}]])

messages = crawl.messages(50)
crawl.stderr("safest_explore messages: " .. messages)

if messages:find("SE_RESULT: nil") then
    crawl.stderr("safest_explore returned nil (no frontier cells)")
    crawl.stderr("TEST PASSED: function ran without error")
elseif messages:find("SE_RESULT:") then
    local x = messages:match("x=(-?%d+)")
    local y = messages:match("y=(-?%d+)")
    local dist = messages:match("dist=(%d+)")
    local count = messages:match("count=(%d+)")
    local pathlen = messages:match("pathlen=(%d+)")

    crawl.stderr("  Target: (" .. (x or "?") .. "," .. (y or "?") .. ")")
    crawl.stderr("  Dist=" .. (dist or "?") .. " Count=" .. (count or "?")
        .. " PathLen=" .. (pathlen or "?"))

    assert(tonumber(dist) > 0, "best_dist should be > 0")
    assert(tonumber(dist) <= 7, "best_dist should be <= 7")
    assert(tonumber(count) > 0, "count should be > 0")
    assert(tonumber(pathlen) > 0, "path should have steps (excludes player pos)")

    crawl.stderr("TEST PASSED: safest_explore returned valid result")
else
    crawl.stderr("Messages: " .. messages:sub(1, 500))
    assert(false, "SE_RESULT not found - function may have errored")
end

crawl.stderr("=== safest_explore test completed ===")
