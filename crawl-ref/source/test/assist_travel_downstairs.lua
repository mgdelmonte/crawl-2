-- Test assist.rc travel_to_downstairs function
-- Run with: crawl -test assist_travel_downstairs
--
-- Tests that the travel_to_downstairs function works without errors,
-- particularly the "cannot resume dead coroutine" error.
--
-- NOTE: RC files (clua) and tests (dlua) run in separate Lua VMs.
-- We trigger the function via the ':' macro and check for errors in messages.

crawl.setopt("{ function c_answer_prompt(prompt) return true end }")

-- Load assist.rc (this loads it into clua, not dlua)
crawl.read_options("C:/dev/simple/assist.rc")

-- Verify RC loaded
local messages = crawl.messages(50)
assert(messages:lower():find("starting assist"), "RC should emit 'starting assist' message")

-----------------------------------------------------------------------
-- Set up the test level
-----------------------------------------------------------------------
crawl.stderr("\n=== Testing travel_to_downstairs ===\n")

debug.goto_place("D:2")
dgn.reset_level()
dgn.fill_grd_area(1, 1, dgn.GXM - 2, dgn.GYM - 2, 'floor')

-- Place a downstairs
dgn.grid(45, 40, "stone_stairs_down_i")

-- Position player away from stairs
you.moveto(40, 40)
debug.los_changed()

crawl.stderr("Player at 40,40, stairs at 45,40")

-----------------------------------------------------------------------
-- TEST 1: Trigger travel_to_downstairs via macro
-----------------------------------------------------------------------
crawl.stderr("\n--- TEST 1: Trigger via ':' macro ---")

-- Clear messages before test
crawl.clear_messages()

-- Send the ':' key which is bound to ===travel_to_downstairs
crawl.sendkeys(":")

-- Run turns to process the macro and any resulting actions
debug.run_turns(3)

-- Check messages for coroutine errors
local msgs = crawl.messages(200)
crawl.stderr("Messages after macro: " .. msgs:gsub("\n", " | "))

local has_coroutine_error = msgs:lower():find("coroutine") or msgs:lower():find("cannot resume")
local has_lua_error = msgs:lower():find("lua error") or msgs:lower():find("attempt to call")

local test1_passed = true
if has_coroutine_error then
    crawl.stderr("FAIL: Found coroutine error in messages")
    test1_passed = false
else
    crawl.stderr("PASS: No coroutine errors in messages")
end

if has_lua_error then
    crawl.stderr("FAIL: Found Lua error in messages")
    test1_passed = false
else
    crawl.stderr("PASS: No Lua errors in messages")
end

-----------------------------------------------------------------------
-- TEST 2: Trigger when already on stairs
-----------------------------------------------------------------------
crawl.stderr("\n--- TEST 2: Trigger via ':' when on stairs ---")

-- Move player to stairs
you.moveto(45, 40)
debug.los_changed()

local feat = view.feature_at(0, 0)
crawl.stderr("Player feature: " .. (feat or "nil"))

-- Clear messages
crawl.clear_messages()

-- Send the ':' key
crawl.sendkeys(":")

-- Run turns
debug.run_turns(3)

-- Check messages
local msgs2 = crawl.messages(200)
crawl.stderr("Messages after macro (on stairs): " .. msgs2:gsub("\n", " | "))

local has_coroutine_error2 = msgs2:lower():find("coroutine") or msgs2:lower():find("cannot resume")
local has_lua_error2 = msgs2:lower():find("lua error") or msgs2:lower():find("attempt to call")

local test2_passed = true
if has_coroutine_error2 then
    crawl.stderr("FAIL: Found coroutine error in messages (on stairs)")
    test2_passed = false
else
    crawl.stderr("PASS: No coroutine errors in messages (on stairs)")
end

if has_lua_error2 then
    crawl.stderr("FAIL: Found Lua error in messages (on stairs)")
    test2_passed = false
else
    crawl.stderr("PASS: No Lua errors in messages (on stairs)")
end

-----------------------------------------------------------------------
-- Summary
-----------------------------------------------------------------------
crawl.stderr("\n=== Test Summary ===")
crawl.stderr("Test 1 (macro trigger): " .. (test1_passed and "PASS" or "FAIL"))
crawl.stderr("Test 2 (on stairs): " .. (test2_passed and "PASS" or "FAIL"))

local all_passed = test1_passed and test2_passed

if all_passed then
    crawl.stderr("\nAll tests passed!")
    crawl.stderr("travel_to_downstairs works without coroutine errors.")
else
    crawl.stderr("\nSome tests failed!")
end

assert(all_passed, "travel_to_downstairs test failed")
