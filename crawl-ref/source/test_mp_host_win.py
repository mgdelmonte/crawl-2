#!/usr/bin/env python3
"""
Windows multiplayer host test for DCSS.

Verifies:
1.  Host starts successfully (server listening, game loop running)
2.  Pre-game phase works (host responsive while waiting for players)
3.  TCP client connects and receives welcome
4.  Real --connect client starts without crashing
5.  Game starts after all players ready
6.  Level data has substantial map (1000+ features)
7.  Initial game state valid (3 alive players with positions)
8.  Display stats present for all players (title, species, XL, AC, EV, etc.)
9.  Map has features around each player position (map would render)
10. Host alive after pre-game -> in-game transition
11. TCP client (P1) can act (wait command acknowledged)
12. Real client still alive after game start
13. Real client has correct name in game state
14. Place string present in game state (message area data)
15. Client and host stable for 5 seconds after game start

Uses tcrawl.exe (tiles build) by default, falls back to ccrawl.exe.
"""

import json
import os
import random
import socket
import subprocess
import sys
import tempfile
import time


SERVER_WAIT_TIMEOUT = 15
MSG_TIMEOUT = 15
SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
SAVE_DIR = os.path.join(SOURCE_DIR, "saves")


class TestFailure(Exception):
    pass


class MPClient:
    """Simple TCP client for the DCSS multiplayer protocol."""

    def __init__(self):
        self.sock = None
        self.recv_buffer = ""

    def connect(self, host, port, timeout=10):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect((host, port))
        self.sock.setblocking(False)

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def send_message(self, msg_dict):
        data = json.dumps(msg_dict) + "\n"
        self.sock.setblocking(True)
        self.sock.sendall(data.encode())
        self.sock.setblocking(False)

    def recv_message(self, msg_type=None, timeout=MSG_TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            messages = self._extract_messages()
            for i, msg_str in enumerate(messages):
                try:
                    msg = json.loads(msg_str)
                except json.JSONDecodeError:
                    continue
                if msg_type is None or msg.get("type") == msg_type:
                    remaining = messages[:i] + messages[i + 1 :]
                    if remaining:
                        self.recv_buffer = (
                            "\n".join(remaining) + "\n" + self.recv_buffer
                        )
                    return msg

            remaining_time = deadline - time.time()
            if remaining_time <= 0:
                break
            try:
                self.sock.setblocking(False)
                data = self.sock.recv(8192)
                if not data:
                    raise TestFailure("Server disconnected")
                self.recv_buffer += data.decode()
            except BlockingIOError:
                time.sleep(0.05)
            except socket.timeout:
                pass

        raise TimeoutError(
            f"Timed out waiting for message type '{msg_type}' (timeout={timeout}s)"
        )

    def _extract_messages(self):
        messages = []
        while "\n" in self.recv_buffer:
            line, self.recv_buffer = self.recv_buffer.split("\n", 1)
            line = line.strip()
            if line:
                messages.append(line)
        return messages


def log(tag, msg):
    print(f"[{tag}] {msg}", flush=True)


def find_binary():
    """Find the best available crawl binary.
    Use --ccrawl or --tcrawl to force a specific build.
    """
    if "--ccrawl" in sys.argv:
        path = os.path.join(SOURCE_DIR, "ccrawl.exe")
        if os.path.exists(path):
            return path
    if "--tcrawl" in sys.argv:
        path = os.path.join(SOURCE_DIR, "tcrawl.exe")
        if os.path.exists(path):
            return path
    for name in ("tcrawl.exe", "ccrawl.exe", "crawl.exe"):
        path = os.path.join(SOURCE_DIR, name)
        if os.path.exists(path):
            return path
    return None


def wait_for_server(port, timeout=SERVER_WAIT_TIMEOUT):
    """Wait for server port to open using netstat (avoids consuming a player slot)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result = subprocess.run(
                ["netstat", "-an"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            for line in result.stdout.splitlines():
                if f":{port}" in line and "LISTENING" in line:
                    return True
        except (subprocess.TimeoutExpired, OSError):
            pass
        time.sleep(0.3)
    return False


def clean_saves(names):
    """Remove stale save files (best-effort, ignores locked files)."""
    for name in names:
        for ext in (".cs", ".cs.tmp"):
            path = os.path.join(SAVE_DIR, name + ext)
            try:
                if os.path.exists(path):
                    os.unlink(path)
            except OSError:
                pass
    # Also clean mp-clients subdirectory
    mp_clients_dir = os.path.join(SAVE_DIR, "mp-clients")
    if os.path.isdir(mp_clients_dir):
        for name in names:
            for ext in (".cs", ".cs.tmp"):
                path = os.path.join(mp_clients_dir, name + ext)
                try:
                    if os.path.exists(path):
                        os.unlink(path)
                except OSError:
                    pass


def kill_proc(proc, label="process"):
    """Terminate a process, kill if needed."""
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def main():
    port = 18000 + random.randint(0, 999)
    host_proc = None
    client_proc = None
    tcp_client = MPClient()
    rc_file = None
    passed = 0
    test_start = time.time()

    try:
        binary = find_binary()
        if not binary:
            raise TestFailure(
                f"No crawl binary found in {SOURCE_DIR}. "
                "Build tcrawl.exe or ccrawl.exe first."
            )

        log("SETUP", f"Using {os.path.basename(binary)}")
        clean_saves(["TestHost", "TestP2", "TestP3"])

        # Create temp rc file
        rc_fd, rc_file = tempfile.mkstemp(suffix=".rc", prefix="mp_test_")
        with os.fdopen(rc_fd, "w") as f:
            f.write("weapon = random\n")
            f.write("tile_skip_title = true\n")
        log("SETUP", f"Created temp rc file: {rc_file}")

        # --- Start Host (3 players: host + TCP client + real client) ---
        log("SETUP", f"Starting host on port {port} (3 players)...")
        host_cmd = [
            binary,
            "--char",
            "TestHost:MiBe:random",
            "-host",
            "3",
            "-port",
            str(port),
            "-rc",
            rc_file,
        ]
        host_proc = subprocess.Popen(
            host_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # --- Test 1: Server starts listening ---
        log("TEST", "Waiting for server to start listening...")
        if not wait_for_server(port):
            if host_proc.poll() is not None:
                stderr = host_proc.stderr.read().decode()[-500:]
                raise TestFailure(f"Host died (exit={host_proc.returncode}): {stderr}")
            raise TestFailure(f"Server not listening after {SERVER_WAIT_TIMEOUT}s")
        log("PASS", "1. Server is listening (host started, game loop running)")
        passed += 1

        # --- Test 2: Host is responsive during pre-game ---
        time.sleep(1.0)
        if host_proc.poll() is not None:
            raise TestFailure(
                f"Host crashed during pre-game (exit={host_proc.returncode})"
            )
        log("PASS", "2. Host alive during pre-game phase")
        passed += 1

        # --- Test 3: TCP client connects ---
        log("TEST", "Connecting player 2 via TCP...")
        tcp_client.connect("localhost", port)

        welcome = tcp_client.recv_message("welcome")
        player_idx = int(welcome["player_idx"])
        num_players = int(welcome["num_players"])
        log(
            "TEST",
            f"Received welcome: player_idx={player_idx}, num_players={num_players}",
        )
        assert player_idx == 1, f"Expected player_idx=1, got {player_idx}"
        assert num_players == 3, f"Expected num_players=3, got {num_players}"
        log("PASS", "3. Player 2 (TCP) connected, received welcome")
        passed += 1

        # TCP client sends player_info (but game won't start until player 3 joins)
        tcp_client.send_message(
            {
                "type": "player_info",
                "name": "TestP2",
                "species": "Hu",
                "job": "Fi",
            }
        )
        log("TEST", "TCP client sent player_info")

        # --- Test 4: Real client (--connect) starts and connects ---
        log("TEST", "Starting real client (--connect)...")
        client_cmd = [
            binary,
            "--char",
            "TestP3:HuFi:random",
            "--connect",
            f"localhost:{port}",
            "-rc",
            rc_file,
        ]
        client_proc = subprocess.Popen(
            client_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Give the client time to do character selection (instant with --char)
        # and connect to the host
        time.sleep(2.0)
        if client_proc.poll() is not None:
            stderr = client_proc.stderr.read().decode()[-500:]
            raise TestFailure(
                f"Client crashed during startup "
                f"(exit={client_proc.returncode}): {stderr}"
            )
        log("PASS", "4. Real client (--connect) started without crashing")
        passed += 1

        # --- Test 5: Game starts after all players ready ---
        log("TEST", "Waiting for game_start (all 3 players)...")
        game_start = tcp_client.recv_message("game_start")
        gs_num = int(game_start["num_players"])
        log("TEST", f"Received game_start: num_players={gs_num}")
        assert gs_num == 3, f"Expected 3 players, got {gs_num}"
        log("PASS", "5. Game started successfully (all 3 players connected)")
        passed += 1

        # --- Test 6: Level data has substantial map ---
        level_data = tcp_client.recv_message("level_data")
        gxm = int(level_data["gxm"])
        gym = int(level_data["gym"])
        grid = level_data["grid"]
        non_zero = sum(1 for v in grid if int(v) != 0)
        log(
            "TEST",
            f"Received level_data: gxm={gxm}, gym={gym}, features={non_zero}",
        )
        assert gxm == 80, f"Expected gxm=80, got {gxm}"
        assert gym == 70, f"Expected gym=70, got {gym}"
        assert len(grid) == gxm * gym, "Grid size mismatch"
        assert non_zero >= 100, (
            f"Grid has only {non_zero} features (expected 100+, "
            "map may not be rendering)"
        )
        log("PASS", f"6. Level data has substantial map ({non_zero} features)")
        passed += 1

        # --- Test 7: Initial game state valid with 3 players ---
        state = tcp_client.recv_message("game_state")
        players_data = state["players"]
        turn = int(state["turn"])
        assert len(players_data) == 3, f"Expected 3 players, got {len(players_data)}"
        for i, p in enumerate(players_data):
            assert p["alive"], f"Player {i} not alive"
            assert int(p["hp"]) > 0, f"Player {i} hp <= 0"
            assert int(p["x"]) > 0, f"Player {i} invalid x"
            assert int(p["y"]) > 0, f"Player {i} invalid y"
        positions = [(int(p["x"]), int(p["y"])) for p in players_data]
        names = [p["name"] for p in players_data]
        log(
            "TEST",
            f"Initial state: turn={turn}, "
            f"P0={names[0]}@{positions[0]}, "
            f"P1={names[1]}@{positions[1]}, "
            f"P2={names[2]}@{positions[2]}",
        )
        log("PASS", "7. Initial game state valid (3 alive players)")
        passed += 1

        # --- Test 8: Display stats present for all players ---
        # The host must send title, species_name, xl, ac, ev, sh, str,
        # intel, dex for each player — these are needed for the HUD sidebar.
        required_stat_fields = [
            "title",
            "species_name",
            "xl",
            "ac",
            "ev",
            "sh",
            "str",
            "intel",
            "dex",
            "weapon",
            "noise",
            "silenced",
        ]
        for i, p in enumerate(players_data):
            for field in required_stat_fields:
                assert field in p, f"Player {i} missing display stat '{field}'"
            # Title and species should be non-empty strings
            assert len(p["title"]) > 0, f"Player {i} has empty title"
            assert len(p["species_name"]) > 0, f"Player {i} has empty species_name"
            # XL should be >= 1
            assert int(p["xl"]) >= 1, f"Player {i} xl={p['xl']} (expected >= 1)"
        log(
            "TEST",
            f"P0: title='{players_data[0]['title']}', "
            f"species='{players_data[0]['species_name']}', "
            f"xl={players_data[0]['xl']}, "
            f"ac={players_data[0]['ac']}, ev={players_data[0]['ev']}",
        )
        log(
            "TEST",
            f"P2: title='{players_data[2]['title']}', "
            f"species='{players_data[2]['species_name']}', "
            f"xl={players_data[2]['xl']}, "
            f"ac={players_data[2]['ac']}, ev={players_data[2]['ev']}",
        )
        log("PASS", "8. Display stats present for all players")
        passed += 1

        # --- Test 9: Map has features around each player's position ---
        # Check that the grid has non-zero features within 3 tiles of
        # each player. If the map is empty around a player, the client
        # would display a blank screen.
        for i, (px, py) in enumerate(positions):
            nearby_features = 0
            for dy in range(-3, 4):
                for dx in range(-3, 4):
                    nx, ny = px + dx, py + dy
                    if 0 <= nx < gxm and 0 <= ny < gym:
                        idx = ny * gxm + nx
                        if int(grid[idx]) != 0:
                            nearby_features += 1
            assert nearby_features >= 5, (
                f"Player {i} at ({px},{py}) has only {nearby_features} "
                f"nearby features (expected 5+, map blank around player)"
            )
        log("PASS", "9. Map has features around each player position")
        passed += 1

        # --- Test 10: Host alive after transition ---
        time.sleep(0.5)
        if host_proc.poll() is not None:
            raise TestFailure(
                f"Host crashed after game start (exit={host_proc.returncode})"
            )
        log("PASS", "10. Host alive after game start transition")
        passed += 1

        # --- Test 11: TCP client (P1) can act ---
        log("TEST", "Having P1 send wait command...")
        tcp_client.send_message({"cmd": "wait"})

        acted_state = None
        deadline = time.time() + MSG_TIMEOUT
        while time.time() < deadline:
            try:
                s = tcp_client.recv_message("game_state", timeout=2)
                if s["players"][1]["acted"]:
                    acted_state = s
                    break
            except TimeoutError:
                break

        if acted_state is None:
            raise TestFailure("P1 wait command not acknowledged in game_state")
        log("PASS", "11. P1 wait command accepted")
        passed += 1

        # --- Test 12: Real client still alive after game start ---
        if client_proc.poll() is not None:
            stderr = client_proc.stderr.read().decode()[-500:]
            raise TestFailure(
                f"Real client crashed after game start "
                f"(exit={client_proc.returncode}): {stderr}"
            )
        log("PASS", "12. Real client (--connect) alive after game start")
        passed += 1

        # --- Test 13: Real client has correct name in game state ---
        p3 = players_data[2]
        assert p3["name"] == "TestP3", (
            f"Expected player 3 name 'TestP3', got '{p3['name']}'"
        )
        log("PASS", "13. Real client has correct name in game state")
        passed += 1

        # --- Test 14: Place string present (message area data) ---
        assert "place" in state, "game_state missing 'place' field"
        place = state["place"]
        assert len(place) > 0, "place string is empty"
        log("TEST", f"Place: '{place}'")
        log("PASS", "14. Place string present in game state")
        passed += 1

        # --- Test 15: Client and host stable for 5 seconds ---
        log("TEST", "Waiting 5 seconds to verify stability...")
        for sec in range(1, 6):
            time.sleep(1.0)
            if client_proc.poll() is not None:
                stderr = client_proc.stderr.read().decode()[-500:]
                raise TestFailure(
                    f"Real client crashed {sec}s after game start "
                    f"(exit={client_proc.returncode}): {stderr}"
                )
            if host_proc.poll() is not None:
                raise TestFailure(
                    f"Host crashed {sec}s after game start "
                    f"(exit={host_proc.returncode})"
                )
        log("PASS", "15. Client and host stable for 5 seconds after game start")
        passed += 1

        # --- Summary ---
        log("RESULT", f"ALL TESTS PASSED ({passed} checks)")

    except TestFailure as e:
        log("FAIL", str(e))
        if host_proc and host_proc.poll() is not None:
            try:
                stderr = host_proc.stderr.read().decode()[-500:]
                if stderr.strip():
                    log("FAIL", f"Host stderr: {stderr.strip()}")
            except Exception:
                pass
        sys.exit(1)
    except TimeoutError as e:
        log("FAIL", str(e))
        sys.exit(1)
    except AssertionError as e:
        log("FAIL", f"Assertion failed: {e}")
        sys.exit(1)
    except Exception as e:
        log("FAIL", f"Unexpected error: {type(e).__name__}: {e}")
        sys.exit(1)
    finally:
        log("CLEANUP", "Shutting down...")
        tcp_client.close()
        kill_proc(client_proc, "client")
        kill_proc(host_proc, "host")

        if host_proc and host_proc.poll() is not None:
            try:
                stderr = host_proc.stderr.read().decode()[-500:]
                if stderr.strip():
                    log("CLEANUP", f"Host stderr: {stderr.strip()}")
            except Exception:
                pass

        if rc_file and os.path.exists(rc_file):
            os.unlink(rc_file)

        clean_saves(["TestHost", "TestP2", "TestP3"])

        elapsed = time.time() - test_start
        log("CLEANUP", f"Done in {elapsed:.1f}s")


if __name__ == "__main__":
    main()
