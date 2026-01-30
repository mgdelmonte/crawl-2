-- Test that debug.run_turns() executes the game loop and calls ready()
-- Run with: crawl -test run_turns

-- Define a ready() function via RC that counts calls
local rc_content = [[
{
ready_call_count = (ready_call_count or 0)

function ready()
    ready_call_count = ready_call_count + 1
    crawl.mpr("READY_CALLED:" .. ready_call_count)
end
}
]]

-- Write and load the RC (use source directory for temp file)
local rc_path = "test_run_turns_temp.rc"
assert(file.writefile(rc_path, rc_content), "failed to write test RC")
crawl.read_options(rc_path)

-- Set up a simple level
debug.goto_place("D:1")
dgn.reset_level()
dgn.fill_grd_area(1, 1, dgn.GXM - 2, dgn.GYM - 2, 'floor')

-- Position player
you.moveto(40, 40)
debug.los_changed()

-- Clear message buffer
crawl.messages(100)

-- Run 5 game turns
debug.run_turns(5)

-- Check that ready() was called 5 times
local messages = crawl.messages(100)
assert(messages:find("READY_CALLED:1"), "ready() should be called on turn 1")
assert(messages:find("READY_CALLED:2"), "ready() should be called on turn 2")
assert(messages:find("READY_CALLED:3"), "ready() should be called on turn 3")
assert(messages:find("READY_CALLED:4"), "ready() should be called on turn 4")
assert(messages:find("READY_CALLED:5"), "ready() should be called on turn 5")

crawl.stderr("run_turns test passed - ready() called 5 times")
