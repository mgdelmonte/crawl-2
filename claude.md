# DCSS Development Notes

## Building on Windows (MSVC)

```sh
cd crawl-ref/source/MSVC
"/c/Program Files/Microsoft Visual Studio/2022/Community/MSBuild/Current/Bin/MSBuild.exe" \
  crawl.vcxproj \
  "-p:Configuration=Debug Console" \
  -p:Platform=x64 \
  -p:WindowsTargetPlatformVersion=10.0.26100.0 \
  -p:PlatformToolset=v143 \
  -m
```

### Configuration options
- `Debug Console` / `Release Console` - console build
- `Debug Tiles` / `Release Tiles` - tiles build
- Platform: `x64` or `Win32`

### Overrides needed for VS 2022
The project targets VS 2019, so override:
- `PlatformToolset=v143` (VS 2022 toolset)
- `WindowsTargetPlatformVersion=10.0.26100.0` (or your installed SDK)

## Running Tests

Tests are in `crawl-ref/source/test/*.lua`

```sh
cd crawl-ref/source
./crawl.exe -test              # run all tests
./crawl.exe -test abyss_shift  # run specific test
./crawl.exe -test foo          # run tests matching "foo"
```

### Writing tests

Basic structure:
```lua
-- Use assert() for verification
assert(condition, "error message")

-- Load dlua files
crawl_require('dlua/somefile.lua')

-- Access game APIs: you.*, crawl.*, items.*, dgn.*
```

### Testing RC files

RC files (clua) and tests (dlua) run in separate Lua VMs. To test an RC file:

```lua
-- Load RC with Lua enabled
crawl.read_options("C:/path/to/file.rc")

-- Check messages emitted by the RC
local messages = crawl.messages(50)
assert(messages:lower():find("expected message"), "message not found")
```

Note: The `-rc` flag only does a first pass without Lua execution. Use `crawl.read_options()` in the test to trigger Lua code.

## Headless Mode

For console builds, `in_headless_mode()` indicates no terminal is attached. Code that accesses console state should check this:

```cpp
if (in_headless_mode())
    return;  // skip console operations
```

## assist.rc Maintenance

The `C:/dev/simple/assist.rc` file displays a startup message with the last-modified timestamp. When modifying assist.rc, update the timestamp in the `init()` function using the **user's actual local time** (do not make up times):

```lua
crawl.mpr("starting assist (updated YYYY-MM-DD HH:MM)")  -- use actual local time, don't guess
```

### RC File Lua Block Syntax

RC files enclose Lua code in `{` and `}` braces. The parser looks for `}` at the **start of a line** to end the Lua block. This means:

- **NEVER** have a closing brace `}` at the start of a line (column 1) except for the final `}` that ends the Lua block
- Put closing braces on the same line as the last element

```lua
-- WRONG - parser sees } as end of Lua block
my_table = {
    ["key"] = true,
}

-- CORRECT - closing brace on same line as last element
my_table = {
    ["key"] = true }
```

## Lua Persist Tables

There are two persist tables with different availability:

- **`c_persist`** - Works everywhere (online, offline, but NOT in test mode). Use this for RC files.
- **`persist`** - Only works in offline play. NOT available online or in test mode.

For RC features that need to save state (e.g., tracking explored levels), use `c_persist`.

## Reference

- Full test docs: `crawl-ref/docs/develop/testing.md`
- Example tests: `crawl-ref/source/test/mutation.lua`, `los_maps.lua`
