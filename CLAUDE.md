# DCSS (Dungeon Crawl Stone Soup) - Development Notes

## Repository

- Fork of https://github.com/crawl/crawl
- Upstream remote: `upstream` -> https://github.com/crawl/crawl.git
- Origin remote: `origin` -> https://github.com/mgdelmonte/crawl-2

## How to Build (macOS Tiles)

### Prerequisites

- Xcode + command line tools (`xcode-select --install`)
- Git submodules initialized (`git submodule update --init` from repo root)
- PyYAML (`pip install pyyaml`)

### Build Commands

From `crawl-ref/source/`:

```sh
# Tiles build (SDL/OpenGL graphical version)
make -j8 TILES=y

# Console build (terminal/ncurses version)
make -j8

# Debug build
make -j8 TILES=y debug

# Mac app bundle (creates .app in mac-app-zips/)
make -j8 TILES=y mac-app-tiles

# Clean build
make clean TILES=y
make -j8 TILES=y
```

### Run

```sh
cd crawl-ref/source
./crawl
```

### Verify Build

```sh
./crawl -version
```

Look for `USE_TILE`, `USE_TILE_LOCAL`, `USE_SDL` in the CFLAGS output to confirm tiles support.

### Syncing with Upstream

```sh
git fetch upstream
git merge upstream/master
git submodule update --init --recursive
git push origin master
```

## How to Build (Windows MSVC)

### Prerequisites

- Visual Studio 2022 with C++ workload (v143 toolset)
- Windows 10/11 SDK
- Git submodules initialized (`git submodule update --init` from repo root)
- Prebuilt contrib libraries in `crawl-ref/source/contrib/bin/x64/Release/`

### Build Commands

From `crawl-ref/source/MSVC/` (Git Bash). Note: MSBuild flags use `//` prefix in Git Bash to prevent path mangling.

```sh
MSBUILD="/c/Program Files/Microsoft Visual Studio/2022/Community/MSBuild/Current/Bin/MSBuild.exe"

# Tiles build (SDL/OpenGL graphical version)
"$MSBUILD" crawl.vcxproj "//p:Configuration=Release Tiles" //p:Platform=x64 \
  //p:WindowsTargetPlatformVersion=10.0 //p:PlatformToolset=v143 //nologo //v:minimal

# Console build (terminal version)
"$MSBUILD" crawl.vcxproj "//p:Configuration=Release Console" //p:Platform=x64 \
  //p:WindowsTargetPlatformVersion=10.0 //p:PlatformToolset=v143 //nologo //v:minimal
```

Both configs output to `crawl-ref/source/crawl.exe`. Copy after each build:
- Tiles build → `tcrawl.exe`
- Console build → `ccrawl.exe`

```sh
# After tiles build:
cp ../crawl.exe ../tcrawl.exe

# After console build:
cp ../crawl.exe ../ccrawl.exe
```

### Notes

- The vcxproj targets Windows SDK 8.1 and v142 toolset by default; override with the `//p:` flags shown above.
- Only `Release` configs work out of the box — `Debug` configs look for libs in `contrib/bin/x64/Debug/` which don't exist (only `Release/` is populated).
- `mp-client.cc` and `mp-server.cc` have precompiled headers disabled in the vcxproj (they use Winsock2 which conflicts with the PCH).

### Run

```sh
cd crawl-ref/source
./tcrawl.exe          # tiles
./ccrawl.exe          # console
./tcrawl.exe --host 2 # multiplayer host (2 players, tiles)
./tcrawl.exe --connect # multiplayer client
```

## Project Structure

- `crawl-ref/source/` - Main source code directory (C++)
- `crawl-ref/source/dat/` - Game data files (.des level layouts, Lua scripts, descriptions)
- `crawl-ref/source/rltiles/` - Tile graphics
- `crawl-ref/source/contrib/` - Bundled dependencies (submodules: lua, SDL2, freetype, etc.)
- `crawl-ref/docs/` - Documentation
- `crawl-ref/INSTALL.md` - Official build instructions


---
# Multiplayer Branch

## design

This branch is a multiplayer version of the current (0.34) version of DCSS.  Some key differences:

- multiplayer: supports up to 4 simultaneous player characters
    - players act on a first-come-first-served basis
    - all players must act before the turn can continue
    - one player may move into another's tile, swapping the two players (and the second player loses his action; he is forced to swap as his action)
    - when a player dies, he leaves behind a corpse, and enters spectator mode
    - awarded XP is shared among all live players
    - a common gold balance is shared among all live players
    - friendly fire is OFF by default; meaning players can shoot at and through each other without hitting themselves; but clouds and other AOE spells cast by players can still harm other players; and friendly fire ON may become an option
    - PvP is NOT an option (yet): this game is intended to be co-op only
    - for test purposes, one or more players may be driven by an AI

- client/server architecture; the client that starts the game is also the host server, and allows additional clients to connect to that game in progress.
    - when the client starts as host, it is told in advance how many players will connect
    - its player is always a real person (not an ai) and he starts the game as normal, but he can't take any game actions until all other players connect (he can, however, do non-game-actions: look at inventory, set training, etc.)
    - after all players connect and have chosen race/class/name, then the game loop starts at turn 0, and all players can now act (on a first-come-first-served basis as described above)
    - if the host player quits, the entire game is over and all other players are disconnected


# saved games
- the host machine is responsible for saving the game; other players' machines do not save the game
- the host machine can load ONLY saved games that have the same number of players as the --host value
- the saved game saves players in the same order as they were created when the players joined, so the host machine's player is ALWAYS the "first" player; when other clients connect, they are associated with saved players in first-come-first-served order (it is therefore up to the clients to correct in the same order)


## corpses
A dead player leaves behind a corpse.  
- The corpse remains visible to all players
- it occupies a tile, but any player or monster can move into its tile, automatically swapping places with it; if it is moved into lava or deep water, it disappears permanently
- it can be fired through (by ranged weapons and spells)
- "reach" attacks can reach across it
- it never takes damage

