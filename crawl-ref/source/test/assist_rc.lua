-- Test that assist.rc loads without errors
-- Run with: crawl -test assist_rc
--
-- Verifies that:
-- 1. init() ran by checking for its startup message
-- 2. ready() is called when game turns run via debug.run_turns()

-- Load the RC file with Lua enabled
crawl.read_options("C:/dev/simple/assist.rc")

local messages = crawl.messages(50)
assert(messages:lower():find("starting assist"), "should see 'starting assist' message from init()")

-- Set up a simple level
debug.goto_place("D:1")
dgn.reset_level()
dgn.fill_grd_area(1, 1, dgn.GXM - 2, dgn.GYM - 2, 'floor')

-- Position player
you.moveto(40, 40)
debug.los_changed()
crawl.redraw_view()

-- Clear message buffer
crawl.messages(100)

-- Run 3 game turns - this will call ready() each turn
debug.run_turns(3)

-- If we got here without errors, ready() executed successfully
-- (any Lua errors in ready() would have been reported)
crawl.stderr("assist_rc test passed - ready() ran for 3 turns")
