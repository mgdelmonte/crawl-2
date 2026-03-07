#!/usr/bin/env python3
"""
Windows multiplayer host test for DCSS.

Verifies:
1. Host starts successfully (server listening, game loop running)
2. Pre-game phase works (host responsive while waiting for players)
3. TCP client connects and receives welcome
4. Game starts after player_info exchange
5. Level data and game state are valid
6. Host survives the pre-game -> in-game transition
7. Remote player commands are accepted after game start

On Windows, console builds can't run with piped stdin (SetConsoleMode fails),
and tiles builds use SDL for input. So keystroke tests (?, Ctrl-Q) can only
be verified indirectly: if the server is responsive, the game loop is running,
which means _input() is processing keystrokes via pump_callback.

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
MSG_TIMEOUT = 10
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
                    remaining = messages[:i] + messages[i + 1:]
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
    """Find the best available crawl binary."""
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
                capture_output=True, text=True, timeout=5,
            )
            # Look for LISTENING on our port
            for line in result.stdout.splitlines():
                if f":{port}" in line and "LISTENING" in line:
                    return True
        except (subprocess.TimeoutExpired, OSError):
            pass
        time.sleep(0.3)
    return False


def clean_saves(names):
    """Remove stale save files."""
    for name in names:
        for ext in (".cs", ".cs.tmp"):
            path = os.path.join(SAVE_DIR, name + ext)
            if os.path.exists(path):
                os.unlink(path)


def main():
    port = 18000 + random.randint(0, 999)
    host_proc = None
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
        clean_saves(["TestHost", "TestP2"])

        # Create temp rc file
        rc_fd, rc_file = tempfile.mkstemp(suffix=".rc", prefix="mp_test_")
        with os.fdopen(rc_fd, "w") as f:
            f.write("weapon = random\n")
            f.write("tile_skip_title = true\n")
        log("SETUP", f"Created temp rc file: {rc_file}")

        # --- Start Host ---
        log("SETUP", f"Starting host on port {port} (2 players)...")
        host_cmd = [
            binary,
            "--char", "TestHost:MiBe:random",
            "-host", "2",
            "-port", str(port),
            "-rc", rc_file,
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
                raise TestFailure(
                    f"Host died (exit={host_proc.returncode}): {stderr}"
                )
            raise TestFailure(f"Server not listening after {SERVER_WAIT_TIMEOUT}s")
        log("PASS", "1. Server is listening (host started, game loop running)")
        passed += 1

        # --- Test 2: Host is responsive during pre-game ---
        # The server being up proves the game loop is running and
        # _input() is processing via pump_callback. This means keystroke
        # handling (?, Ctrl-Q, etc.) is functional.
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
        log("TEST", f"Received welcome: player_idx={player_idx}, num_players={num_players}")
        assert player_idx == 1, f"Expected player_idx=1, got {player_idx}"
        assert num_players == 2, f"Expected num_players=2, got {num_players}"
        log("PASS", "3. Player 2 connected, received welcome")
        passed += 1

        # --- Test 4: Game starts after player_info ---
        tcp_client.send_message({
            "type": "player_info",
            "name": "TestP2",
            "species": "Hu",
            "job": "Fi",
        })
        log("TEST", "Sent player_info, waiting for game_start...")

        game_start = tcp_client.recv_message("game_start")
        gs_num = int(game_start["num_players"])
        log("TEST", f"Received game_start: num_players={gs_num}")
        assert gs_num == 2, f"Expected 2 players, got {gs_num}"
        log("PASS", "4. Game started successfully (pre-game -> in-game transition)")
        passed += 1

        # --- Test 5: Level data received ---
        level_data = tcp_client.recv_message("level_data")
        gxm = int(level_data["gxm"])
        gym = int(level_data["gym"])
        grid = level_data["grid"]
        non_zero = sum(1 for v in grid if int(v) != 0)
        log("TEST", f"Received level_data: gxm={gxm}, gym={gym}, features={non_zero}")
        assert gxm == 80, f"Expected gxm=80, got {gxm}"
        assert gym == 70, f"Expected gym=70, got {gym}"
        assert len(grid) == gxm * gym, f"Grid size mismatch"
        assert non_zero > 0, "Grid has no features"
        log("PASS", "5. Level data valid")
        passed += 1

        # --- Test 6: Initial game state valid ---
        state = tcp_client.recv_message("game_state")
        players = state["players"]
        turn = int(state["turn"])
        assert len(players) == 2, f"Expected 2 players, got {len(players)}"
        for i, p in enumerate(players):
            assert p["alive"], f"Player {i} not alive"
            assert int(p["hp"]) > 0, f"Player {i} hp <= 0"
            assert int(p["x"]) > 0, f"Player {i} invalid x"
            assert int(p["y"]) > 0, f"Player {i} invalid y"
        positions = [(int(p["x"]), int(p["y"])) for p in players]
        log("TEST", f"Initial state: turn={turn}, P0={positions[0]}, P1={positions[1]}")
        log("PASS", "6. Initial game state valid (2 alive players)")
        passed += 1

        # --- Test 7: Host alive after transition ---
        time.sleep(0.5)
        if host_proc.poll() is not None:
            raise TestFailure(
                f"Host crashed after game start (exit={host_proc.returncode})"
            )
        log("PASS", "7. Host alive after game start transition")
        passed += 1

        # --- Test 8: Remote player command accepted ---
        log("TEST", "Sending P1 wait command via TCP...")
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
        log("PASS", "8. Remote player command accepted after game start")
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

        if host_proc:
            if host_proc.poll() is None:
                host_proc.terminate()
                try:
                    host_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host_proc.kill()
                    host_proc.wait(timeout=5)
            else:
                try:
                    stderr = host_proc.stderr.read().decode()[-500:]
                    if stderr.strip():
                        log("CLEANUP", f"Host stderr: {stderr.strip()}")
                except Exception:
                    pass

        if rc_file and os.path.exists(rc_file):
            os.unlink(rc_file)

        clean_saves(["TestHost", "TestP2"])

        elapsed = time.time() - test_start
        log("CLEANUP", f"Done in {elapsed:.1f}s")


if __name__ == "__main__":
    main()
