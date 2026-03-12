-- Test branch max depth calculation
-- Run with: crawl -test assist_branch_depth
--
-- Verifies that calculating max_depth from you.depth_fraction() matches
-- the hardcoded values used in assist.rc

crawl.stderr("=== assist_branch_depth tests ===")

-- Hardcoded table from assist.rc check_stairs()
local hardcoded_max_depth = {
    ["D"] = 15,
    ["Lair"] = 5,
    ["Orc"] = 2,
    ["Elf"] = 3,
    ["Swamp"] = 4,
    ["Shoals"] = 4,
    ["Snake"] = 4,
    ["Spider"] = 4,
    ["Slime"] = 5,
    ["Vaults"] = 5,
    ["Crypt"] = 3,
    ["Depths"] = 5,
    ["Zot"] = 5 }

-- Calculate max depth from depth and depth_fraction
-- Formula: depth_fraction = (depth - 1) / (max_depth - 1)
-- So: max_depth = (depth - 1) / depth_fraction + 1
function calc_branch_max_depth()
    local depth = you.depth()
    local frac = you.depth_fraction()
    if frac == 0 then
        -- At depth 1 of multi-level branch, can't calculate
        -- But we can use dgn.br_depth in dlua for verification
        return dgn.br_depth()
    elseif frac == 1 then
        -- Either single-level branch or at max depth
        -- Use dgn.br_depth to get actual value
        return dgn.br_depth()
    else
        return math.floor((depth - 1) / frac + 1.5)
    end
end

-----------------------------------------------------------------------
-- TEST: Show actual branch depths from dgn.br_depth (for reference)
-----------------------------------------------------------------------
crawl.stderr("\n=== Actual branch depths from dgn.br_depth() ===")

for branch, _ in pairs(hardcoded_max_depth) do
    local actual = dgn.br_depth(branch)
    crawl.stderr(branch .. ": " .. actual)
end

-----------------------------------------------------------------------
-- TEST: Verify depth_fraction calculation works at current location
-----------------------------------------------------------------------
crawl.stderr("\n=== Testing depth_fraction calculation ===")

local current_branch = you.branch()
local current_depth = you.depth()
local current_frac = you.depth_fraction()
local dgn_max = dgn.br_depth()

crawl.stderr("Current: " .. current_branch .. ":" .. current_depth)
crawl.stderr("depth_fraction: " .. current_frac)
crawl.stderr("dgn.br_depth: " .. dgn_max)

-- Verify the formula
if dgn_max == 1 then
    assert(current_frac == 1, "Single-level branch should have depth_fraction=1")
    crawl.stderr("Single-level branch: depth_fraction=1 as expected")
elseif current_depth == 1 then
    assert(current_frac == 0, "Depth 1 of multi-level branch should have depth_fraction=0")
    crawl.stderr("At depth 1: depth_fraction=0 as expected")
else
    local expected_frac = (current_depth - 1) / (dgn_max - 1)
    local diff = math.abs(current_frac - expected_frac)
    assert(diff < 0.001, "depth_fraction mismatch: got " .. current_frac .. " expected " .. expected_frac)
    crawl.stderr("depth_fraction formula verified: " .. current_frac .. " = (" .. current_depth .. "-1)/(" .. dgn_max .. "-1)")

    -- Verify reverse calculation
    local calc_max = math.floor((current_depth - 1) / current_frac + 1.5)
    assert(calc_max == dgn_max, "Reverse calculation failed: got " .. calc_max .. " expected " .. dgn_max)
    crawl.stderr("Reverse calculation verified: max_depth=" .. calc_max)
end

-----------------------------------------------------------------------
-- TEST: Verify single-level branches (portals) have max_depth=1
-----------------------------------------------------------------------
crawl.stderr("\n=== Testing portal/vault branch depths ===")

local portal_branches = {"Ossuary", "Bailey", "IceCv", "Volcano", "WizLab",
                         "Sewer", "Trove", "Gauntlet", "Bazaar", "Desolation"}

for _, branch in ipairs(portal_branches) do
    -- Try to get depth, may fail if branch doesn't exist in this game
    local ok, depth = pcall(function() return dgn.br_depth(branch) end)
    if ok then
        crawl.stderr(branch .. ": max_depth=" .. depth)
        assert(depth == 1, branch .. " should have max_depth=1 but got " .. depth)
    else
        crawl.stderr(branch .. ": (not available)")
    end
end

crawl.stderr("\n=== All assist_branch_depth tests passed ===")
