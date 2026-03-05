/**
 * @file
 * @brief Multiplayer TCP client.
**/

#pragma once

#include <string>
#include <vector>

class MPClient
{
public:
    MPClient();
    ~MPClient();

    // Connect to a host. Returns true on success.
    bool connect_to(const std::string& host, int port);

    // Disconnect from the host.
    void disconnect();

    // Send a command to the host as JSON.
    void send_command(const std::string& json_msg);

    // Poll for incoming messages from the host (non-blocking).
    // Returns a vector of complete JSON message strings.
    std::vector<std::string> poll_messages();

    // Block until a message of the given type is received.
    // Returns the full JSON string, or empty string on error.
    std::string wait_for_message(const std::string& msg_type,
                                 int timeout_ms = 30000);

    bool is_connected() const { return m_connected; }
    int player_idx() const { return m_player_idx; }
    void set_player_idx(int idx) { m_player_idx = idx; }

private:
    int m_socket_fd = -1;
    bool m_connected = false;
    int m_player_idx = -1;
    std::string m_recv_buffer;

    // Extract complete newline-delimited messages from buffer.
    std::vector<std::string> extract_messages();
};

extern MPClient mp_client;
