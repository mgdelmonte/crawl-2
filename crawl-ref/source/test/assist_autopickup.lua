-- Test assist.rc autopickup configuration
-- Run with: crawl -test assist_autopickup
--
-- Tests the is_wanted() autopickup function that picks up:
--   - darts
--   - javelins
--   - unidentified staves
--
-- Also verifies item classes for autopickup symbol matching.

-----------------------------------------------------------------------
-- Define is_wanted function from assist.rc for testing
-----------------------------------------------------------------------

function is_wanted(it)
    if not it then
        return nil
    end

    local item_class = it.class(true)
    local item_subtype = it.subtype and it.subtype() or nil

    -- Pick up darts and javelins (throwables we want)
    if item_class == "missile" then
        if item_subtype == "dart" or item_subtype == "javelin" then
            return true
        end
    end

    -- Pick up unidentified staves (could be useful magical staves)
    if item_class == "staff" or item_class == "magical staff" then
        if not it.fully_identified then
            return true
        end
    end

    -- Return nil to let other autopickup rules decide
    return nil
end

-----------------------------------------------------------------------
-- Test function: create item and check is_wanted result
-----------------------------------------------------------------------
local function test_item_wanted(item_spec, expected_result, reason)
    -- Set up level
    debug.goto_place("D:1")
    dgn.reset_level()
    dgn.fill_grd_area(1, 1, dgn.GXM - 2, dgn.GYM - 2, 'floor')

    local px, py = 40, 40
    you.moveto(px, py)

    -- Create item
    dgn.create_item(px, py, item_spec)

    -- Check item properties
    local floor_items = dgn.items_at(px, py)
    if not floor_items or #floor_items == 0 then
        return nil, "item not created"
    end

    local item = floor_items[1]
    local item_name = item.name()
    local item_class = item.class(true)
    local item_subtype = item.subtype and item.subtype() or "nil"
    local result = is_wanted(item)

    return {
        name = item_name,
        class = item_class,
        subtype = item_subtype,
        result = result,
        expected = expected_result,
        reason = reason }, nil
end

-----------------------------------------------------------------------
-- Run tests
-----------------------------------------------------------------------
crawl.stderr("=== Testing is_wanted() autopickup function ===\n")

local tests = {
    -- Items is_wanted should return TRUE for
    {spec = "dart q:5", expected = true, reason = "darts should be wanted"},
    {spec = "javelin q:3", expected = true, reason = "javelins should be wanted"},
    {spec = "staff of fire", expected = true, reason = "unid staff should be wanted"},
    {spec = "staff of cold", expected = true, reason = "unid staff should be wanted"},

    -- Items is_wanted should return NIL for (let other rules decide)
    {spec = "stone q:10", expected = nil, reason = "stones handled by ae rules"},
    {spec = "large rock q:2", expected = nil, reason = "large rocks handled by ae rules"},
    {spec = "boomerang q:3", expected = nil, reason = "boomerangs not specifically wanted"},
    {spec = "dagger", expected = nil, reason = "weapons not specifically wanted"},
    {spec = "short sword", expected = nil, reason = "weapons not specifically wanted"},
    {spec = "long sword", expected = nil, reason = "weapons not specifically wanted"} }

local passed = 0
local failed = 0
local skipped = 0

for _, test in ipairs(tests) do
    local result, err = test_item_wanted(test.spec, test.expected, test.reason)
    if err then
        crawl.stderr(string.format("  SKIP: %s (%s)", test.spec, err))
        skipped = skipped + 1
    elseif result.result == result.expected then
        crawl.stderr(string.format("  PASS: %s -> is_wanted=%s (class=%s, subtype=%s) - %s",
            result.name, tostring(result.result), result.class, result.subtype, result.reason))
        passed = passed + 1
    else
        crawl.stderr(string.format("  FAIL: %s -> is_wanted=%s, expected=%s (class=%s, subtype=%s)",
            result.name, tostring(result.result), tostring(result.expected), result.class, result.subtype))
        failed = failed + 1
    end
end

-----------------------------------------------------------------------
-- Summary
-----------------------------------------------------------------------
crawl.stderr(string.format("\n=== Summary: Passed=%d, Failed=%d, Skipped=%d ===",
    passed, failed, skipped))

crawl.stderr("\nis_wanted() function behavior:")
crawl.stderr("  returns TRUE for: darts, javelins, unidentified staves")
crawl.stderr("  returns NIL for: everything else (lets other rules decide)")

assert(failed == 0, string.format("is_wanted() tests failed: %d", failed))
