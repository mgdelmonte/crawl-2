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
    - its player is always a real person (not an ai) and he starts the game as normal, but he can't take any actions until all other players connect
    - after all players connect and have chosen race/class/name, then the game loop starts at turn 0, and all players can now act (on a first-come-first-served basis as described above)

## corpses
A dead player leaves behind a corpse.  
- The corpse remains visible to all players
- it occupies a tile, but any player or monster can move into its tile, automatically swapping places with it; if it is moved into lava or deep water, it disappears permanently
- it can be fired through (by ranged weapons and spells)
- "reach" attacks can reach across it
- it never takes damage

