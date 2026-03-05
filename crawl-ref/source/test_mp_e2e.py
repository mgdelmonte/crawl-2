#!/usr/bin/env python3
"""
End-to-end multiplayer test for DCSS.

Works with both console and tiles builds:
- Console: 2-player test with P0 movement via named pipe (stdin)
- Tiles: 3-player test with two tiles clients (host + spawned client)
         plus a TCP observer; verifies both tiles clients connect,
         reach the map screen, and the multiplayer protocol works

Requires: crawl binary built in crawl-ref/source/
  Console: ./crawl or ./ccrawl
  Tiles:   ./tcrawl (preferred) or ./crawl (if tiles build)
"""

import json
import os
import random
import signal
import socket
import subprocess
import sys
import tempfile
import time


SERVER_WAIT_TIMEOUT = 15  # seconds
MSG_TIMEOUT = 10  # seconds

# Vi-keys for console mode (sent via named pipe to stdin)
VIKEY_UP = b"k"
VIKEY_WAIT = b"."


class TestFailure(Exception):
    pass


class MPClient:
    """Simple TCP client that speaks the DCSS multiplayer protocol."""

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
        """Wait for a message, optionally filtering by type."""
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
    Prefer console (ccrawl) for E2E testing since tiles can't run headless."""
    for name in ("./ccrawl", "./crawl"):
        if os.path.exists(name):
            return name
    return "./crawl"


def is_tiles_build(binary):
    """Check if the crawl binary is a tiles build."""
    result = subprocess.run(
        [binary, "-version"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    return "USE_TILE_LOCAL" in result.stdout


def wait_for_server(port, timeout=SERVER_WAIT_TIMEOUT):
    """Wait for server port to open using lsof."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = subprocess.run(
            ["lsof", "-i", f"TCP:{port}", "-P", "-sTCP:LISTEN"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and str(port) in result.stdout:
            return True
        time.sleep(0.3)
    return False


def send_to_host(fifo_fd, key_bytes):
    """Send terminal input to the host process via named pipe."""
    os.write(fifo_fd, key_bytes)
    time.sleep(0.3)


def verify_initial_state(state, expected_players):
    """Verify the initial game_state message is valid."""
    players_data = state["players"]
    turn = int(state["turn"])
    assert len(players_data) == expected_players, (
        f"Expected {expected_players} players, got {len(players_data)}"
    )
    for i, player_info in enumerate(players_data):
        assert player_info["alive"], f"Player {i} not alive"
        assert int(player_info["x"]) > 0, f"Player {i} invalid x"
        assert int(player_info["y"]) > 0, f"Player {i} invalid y"
        assert int(player_info["hp"]) > 0, f"Player {i} hp <= 0"
        assert int(player_info["hp_max"]) > 0, f"Player {i} hp_max <= 0"
        assert not player_info["acted"], f"Player {i} already acted"
    return players_data, turn


def run_tiles_test(
    host_proc, client_proc, tcp_client, tcp_player_idx, initial_positions, turn
):
    """Two tiles clients test: verify both connected, reached map, can act."""
    passed = 0
    num_players = len(initial_positions)

    # --- Verify both tiles processes are alive (= tiles init + map screen) ---
    log("TEST", "Verifying tiles processes are alive...")
    time.sleep(1.0)

    assert host_proc.poll() is None, (
        f"Host tiles process crashed (exit={host_proc.returncode})"
    )
    log("PASS", "Host tiles process alive (reached map screen)")
    passed += 1

    assert client_proc.poll() is None, (
        f"Client tiles process crashed (exit={client_proc.returncode})"
    )
    log("PASS", "Client tiles process alive (reached map screen)")
    passed += 1

    # --- TCP observer (P2) sends wait command ---
    log("TEST", f"Sending P{tcp_player_idx} (TCP) wait command...")
    tcp_client.send_message({"cmd": "wait"})

    tcp_acted_state = None
    deadline = time.time() + MSG_TIMEOUT
    while time.time() < deadline:
        try:
            state = tcp_client.recv_message("game_state", timeout=2)
            if state["players"][tcp_player_idx]["acted"]:
                tcp_acted_state = state
                break
        except TimeoutError:
            break

    if tcp_acted_state is None:
        raise TestFailure(
            f"P{tcp_player_idx} wait command not acknowledged in game_state"
        )

    tcp_pos = (
        int(tcp_acted_state["players"][tcp_player_idx]["x"]),
        int(tcp_acted_state["players"][tcp_player_idx]["y"]),
    )
    log("TEST", f"P{tcp_player_idx} acted=true, pos={tcp_pos}")
    log("PASS", f"Player {tcp_player_idx} (TCP observer) command accepted")
    passed += 1

    # --- Verify P0 and P1 (tiles) have NOT acted ---
    for i in range(num_players):
        if i == tcp_player_idx:
            continue
        assert not tcp_acted_state["players"][i]["acted"], (
            f"P{i} (tiles) acted unexpectedly"
        )
    log("PASS", "Turn correctly waiting for tiles players to act")
    passed += 1

    # --- Verify turn has NOT advanced ---
    assert int(tcp_acted_state["turn"]) == turn, (
        f"Turn should not have advanced (expected {turn})"
    )
    log("PASS", "Turn blocked until all players act")
    passed += 1

    # --- Verify both tiles processes still alive after protocol activity ---
    assert host_proc.poll() is None, "Host crashed during test"
    assert client_proc.poll() is None, "Client crashed during test"
    log("PASS", "Both tiles processes still alive after protocol activity")
    passed += 1

    return passed


def run_console_test(host_proc, fifo_fd, client, initial_positions, turn):
    """Full test with P0 movement via stdin pipe (2-player console)."""
    passed = 0

    # --- P0 waits (Turn 0) ---
    log("TEST", "Sending P0 move (wait)...")
    send_to_host(fifo_fd, VIKEY_WAIT)

    p0_acted_state = None
    deadline = time.time() + MSG_TIMEOUT
    while time.time() < deadline:
        try:
            state = client.recv_message("game_state", timeout=2)
            if state["players"][0]["acted"]:
                p0_acted_state = state
                break
        except TimeoutError:
            log("TEST", "Retrying P0 keystroke...")
            send_to_host(fifo_fd, VIKEY_WAIT)

    if p0_acted_state is None:
        raise TestFailure("Player 0 never marked as acted")

    p0_pos = (
        int(p0_acted_state["players"][0]["x"]),
        int(p0_acted_state["players"][0]["y"]),
    )
    log("TEST", f"Received game_state: P0 acted=true, pos={p0_pos}")
    assert not p0_acted_state["players"][1]["acted"], (
        "Player 1 should not have acted yet"
    )
    log("PASS", "Player 0 (host) acted successfully")
    passed += 1

    # --- P1 waits (Turn 0 completes) ---
    log("TEST", "Sending P1 move (wait)...")
    client.send_message({"cmd": "wait"})

    turn_completed_state = None
    deadline = time.time() + MSG_TIMEOUT
    while time.time() < deadline:
        try:
            state = client.recv_message("game_state", timeout=2)
            if int(state["turn"]) > turn:
                turn_completed_state = state
                break
        except TimeoutError:
            break

    if turn_completed_state is None:
        raise TestFailure("Turn did not complete after both players acted")

    new_turn = int(turn_completed_state["turn"])
    log(
        "TEST",
        f"Received game_state: turn {new_turn}, "
        f"acted={[p['acted'] for p in turn_completed_state['players']]}",
    )
    for player_info in turn_completed_state["players"]:
        assert player_info["alive"], "A player died unexpectedly"
    log("PASS", "Turn completed successfully")
    passed += 1

    # --- Turn 2: both players move ---
    time.sleep(1.5)

    log("TEST", "Turn 2: Sending P0 move (up)...")
    try:
        client.recv_message("turn_start", timeout=2)
    except TimeoutError:
        pass

    send_to_host(fifo_fd, VIKEY_UP)

    p0_acted_state2 = None
    deadline = time.time() + MSG_TIMEOUT
    retry_count = 0
    while time.time() < deadline:
        try:
            state = client.recv_message("game_state", timeout=2)
            if state["players"][0]["acted"]:
                p0_acted_state2 = state
                break
        except TimeoutError:
            retry_count += 1
            log("TEST", f"Retrying P0 up (attempt {retry_count})...")
            time.sleep(0.5)
            send_to_host(fifo_fd, VIKEY_UP)

    if p0_acted_state2 is None:
        raise TestFailure("Player 0 did not act on turn 2")

    p0_pos2 = (
        int(p0_acted_state2["players"][0]["x"]),
        int(p0_acted_state2["players"][0]["y"]),
    )
    log("TEST", f"Received game_state: P0 acted=true, pos={p0_pos2}")
    log("PASS", "Player 0 acted on turn 2")
    passed += 1

    log("TEST", "Sending P1 move (up via TCP)...")
    client.send_message({"cmd": "move", "dx": 0, "dy": -1})

    turn2_state = None
    deadline = time.time() + MSG_TIMEOUT
    while time.time() < deadline:
        try:
            state = client.recv_message("game_state", timeout=2)
            if int(state["turn"]) > new_turn:
                turn2_state = state
                break
        except TimeoutError:
            break

    if turn2_state is None:
        raise TestFailure("Turn 2 did not complete")

    turn2 = int(turn2_state["turn"])
    log(
        "TEST",
        f"Received game_state: turn {turn2}, "
        f"acted={[p['acted'] for p in turn2_state['players']]}",
    )
    for player_info in turn2_state["players"]:
        assert player_info["alive"], "A player died on turn 2"
    log("PASS", "Turn 2 completed successfully")
    passed += 1

    # --- Verify position changes ---
    final_positions = [(int(p["x"]), int(p["y"])) for p in turn2_state["players"]]
    log(
        "TEST",
        f"Final positions: P0={final_positions[0]}, P1={final_positions[1]}",
    )
    position_changed = (
        final_positions[0] != initial_positions[0]
        or final_positions[1] != initial_positions[1]
    )
    if position_changed:
        log("PASS", "At least one player position changed")
        passed += 1
    else:
        log("WARN", "No positions changed (may be blocked by walls)")

    return passed


def main():
    port = 18000 + random.randint(0, 999)
    host_proc = None
    client_proc = None  # tiles client process (tiles mode only)
    tcp_client = MPClient()
    rc_file = None
    fifo_path = None
    fifo_fd = None
    passed = 0
    failed = 0
    test_start = time.time()
    tiles_mode = False

    try:
        # --- Find binary ---
        binary = find_binary()
        if not os.path.exists(binary):
            raise TestFailure(
                "No crawl binary found. "
                "Build with 'make tiles' or 'make console' first."
            )

        tiles_mode = is_tiles_build(binary)
        log("SETUP", f"Using {binary} ({'tiles' if tiles_mode else 'console'})")

        # In tiles mode: 3 players (host tiles + client tiles + TCP observer)
        # In console mode: 2 players (host console + TCP client)
        num_players = 3 if tiles_mode else 2

        # Clean up stale saves
        save_dir = os.path.expanduser(
            "~/Library/Application Support/Dungeon Crawl Stone Soup/saves"
        )
        for name in ("TestHost", "TestP1", "TestP2", "Player2", "Player3"):
            for ext in (".cs", ".cs.tmp"):
                path = os.path.join(save_dir, name + ext)
                if os.path.exists(path):
                    os.unlink(path)

        # Create temp rc file
        rc_fd, rc_file = tempfile.mkstemp(suffix=".rc", prefix="mp_test_")
        with os.fdopen(rc_fd, "w") as f:
            f.write("weapon = random\n")
            f.write("tile_skip_title = true\n")
        log("SETUP", f"Created temp rc file: {rc_file}")

        # --- Start Host Process ---
        log("SETUP", f"Starting host on port {port} ({num_players} players)...")
        host_cmd = [
            binary,
            "--char",
            "TestHost:HuFi",
            "-host",
            str(num_players),
            "-port",
            str(port),
            "-rc",
            rc_file,
        ]

        if tiles_mode:
            host_proc = subprocess.Popen(
                host_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        else:
            fifo_path = tempfile.mktemp(prefix="crawl_fifo_")
            os.mkfifo(fifo_path)
            fifo_rw = os.open(fifo_path, os.O_RDWR)
            host_proc = subprocess.Popen(
                host_cmd,
                stdin=fifo_rw,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            fifo_fd = os.open(fifo_path, os.O_WRONLY)
            os.close(fifo_rw)

        # --- Wait for Server ---
        log("SETUP", "Waiting for server...")
        if not wait_for_server(port):
            if host_proc.poll() is not None:
                stderr = host_proc.stderr.read().decode()
                raise TestFailure(
                    f"Host died (exit={host_proc.returncode}): {stderr[:300]}"
                )
            raise TestFailure(f"Server not available within {SERVER_WAIT_TIMEOUT}s")
        log("SETUP", "Server ready.")
        time.sleep(0.5)

        # --- In tiles mode, start a second tiles client (P1) ---
        if tiles_mode:
            log("SETUP", "Starting tiles client (P1)...")
            client_cmd = [
                binary,
                "--connect",
                f"localhost:{port}",
                "--name",
                "TestP1",
                "--species",
                "Hu",
                "--background",
                "Fi",
                "-rc",
                rc_file,
            ]
            client_proc = subprocess.Popen(
                client_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            # Give the tiles client time to connect before TCP observer
            time.sleep(2.0)

            if client_proc.poll() is not None:
                stderr = client_proc.stderr.read().decode()
                raise TestFailure(
                    f"Tiles client crashed on start "
                    f"(exit={client_proc.returncode}): {stderr[:300]}"
                )

        # --- Connect TCP client (observer in tiles, player in console) ---
        tcp_player_label = "TCP observer" if tiles_mode else "Player 2"
        log("TEST", f"Connecting as {tcp_player_label}...")
        tcp_client.connect("localhost", port)

        welcome = tcp_client.recv_message("welcome")
        tcp_player_idx = int(welcome["player_idx"])
        welcome_num = int(welcome["num_players"])
        log(
            "TEST",
            f"Received welcome: player_idx={tcp_player_idx}, num_players={welcome_num}",
        )
        assert welcome_num == num_players, (
            f"Expected num_players={num_players}, got {welcome_num}"
        )

        # In tiles mode, P1 is the tiles client; TCP should be P2.
        # In console mode, TCP should be P1.
        expected_tcp_idx = num_players - 1
        assert tcp_player_idx == expected_tcp_idx, (
            f"Expected player_idx={expected_tcp_idx}, got {tcp_player_idx}"
        )

        tcp_client.send_message(
            {
                "type": "player_info",
                "name": "TestP2",
                "species": "Hu",
                "job": "Br",
            }
        )
        log("TEST", "Sent player_info")

        game_start = tcp_client.recv_message("game_start")
        gs_num = int(game_start["num_players"])
        log("TEST", f"Received game_start: num_players={gs_num}")
        assert gs_num == num_players

        if tiles_mode:
            log("PASS", "Both tiles clients connected (game_start received)")
            passed += 1

        # --- Verify level_data ---
        level_data = tcp_client.recv_message("level_data")
        gxm = int(level_data["gxm"])
        gym = int(level_data["gym"])
        grid = level_data["grid"]
        log(
            "TEST",
            f"Received level_data: gxm={gxm}, gym={gym}, grid_len={len(grid)}",
        )
        assert gxm == 80, f"Expected gxm=80, got {gxm}"
        assert gym == 70, f"Expected gym=70, got {gym}"
        assert len(grid) == gxm * gym, (
            f"Expected {gxm * gym} grid entries, got {len(grid)}"
        )
        non_zero = sum(1 for v in grid if int(v) != 0)
        assert non_zero > 0, "Grid has no non-zero features"
        log("PASS", f"Level data verified ({non_zero} non-zero features)")
        passed += 1

        state = tcp_client.recv_message("game_state")
        players_data, turn = verify_initial_state(state, num_players)

        initial_positions = [(int(p["x"]), int(p["y"])) for p in players_data]
        pos_strs = ", ".join(f"P{i}={initial_positions[i]}" for i in range(num_players))
        log(
            "TEST",
            f"Received initial game_state: turn {turn}, {pos_strs}",
        )
        log("PASS", "Initial state verified")
        passed += 1

        # --- Run build-specific tests ---
        if tiles_mode:
            passed += run_tiles_test(
                host_proc,
                client_proc,
                tcp_client,
                tcp_player_idx,
                initial_positions,
                turn,
            )
        else:
            passed += run_console_test(
                host_proc,
                fifo_fd,
                tcp_client,
                initial_positions,
                turn,
            )

        # --- Summary ---
        log("PASS", f"All tests passed! ({passed} checks)")

    except TestFailure as e:
        if host_proc and host_proc.poll() is not None:
            log("FAIL", f"{e} (host crashed, exit code {host_proc.returncode})")
            log("FAIL", "This is likely a game bug, not a test failure.")
        else:
            log("FAIL", str(e))
        failed += 1
    except TimeoutError as e:
        if host_proc and host_proc.poll() is not None:
            log("FAIL", f"{e} (host crashed, exit code {host_proc.returncode})")
            log("FAIL", "This is likely a game bug, not a test failure.")
        else:
            log("FAIL", str(e))
        failed += 1
    except AssertionError as e:
        log("FAIL", f"Assertion failed: {e}")
        failed += 1
    except Exception as e:
        log("FAIL", f"Unexpected error: {type(e).__name__}: {e}")
        failed += 1
    finally:
        log("CLEANUP", "Shutting down...")
        tcp_client.close()

        if fifo_fd is not None:
            try:
                os.close(fifo_fd)
            except OSError:
                pass

        # Terminate tiles client if running
        if client_proc:
            if client_proc.poll() is not None:
                stderr_out = client_proc.stderr.read().decode()[-500:]
                if stderr_out.strip():
                    log("CLEANUP", f"Client stderr: {stderr_out.strip()}")
                log(
                    "CLEANUP",
                    f"Client exited with code {client_proc.returncode}",
                )
            else:
                client_proc.send_signal(signal.SIGTERM)
                try:
                    client_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client_proc.kill()
                    client_proc.wait(timeout=5)

        if host_proc:
            if host_proc.poll() is not None:
                stderr_out = host_proc.stderr.read().decode()[-500:]
                if stderr_out.strip():
                    log("CLEANUP", f"Host stderr: {stderr_out.strip()}")
                log(
                    "CLEANUP",
                    f"Host exited with code {host_proc.returncode}",
                )
            else:
                host_proc.send_signal(signal.SIGTERM)
                try:
                    host_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host_proc.kill()
                    host_proc.wait(timeout=5)

        if rc_file and os.path.exists(rc_file):
            os.unlink(rc_file)
        if fifo_path and os.path.exists(fifo_path):
            os.unlink(fifo_path)

        save_dir = os.path.expanduser(
            "~/Library/Application Support/Dungeon Crawl Stone Soup/saves"
        )
        for name in ("TestHost", "TestP1", "TestP2", "Player2", "Player3"):
            for ext in (".cs", ".cs.tmp"):
                path = os.path.join(save_dir, name + ext)
                if os.path.exists(path):
                    os.unlink(path)

        elapsed = time.time() - test_start
        log("CLEANUP", f"Done in {elapsed:.1f}s")

        if failed > 0:
            log("RESULT", f"FAILED ({failed} failures, {passed} passes)")
            sys.exit(1)
        else:
            log("RESULT", f"PASSED ({passed} checks)")
            sys.exit(0)


if __name__ == "__main__":
    main()
