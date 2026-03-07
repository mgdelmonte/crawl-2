/**
 * @file
 * @brief Multiplayer TCP client.
**/

// Winsock2 must be included before AppHdr.h to prevent windows.h macro
// conflicts (PURE, NEAR, etc.) — AppHdr.h will redefine them correctly.
#ifdef _WIN32
# define WIN32_LEAN_AND_MEAN
# define NOMINMAX
# ifndef _WIN32_WINNT
#  define _WIN32_WINNT 0x0600
# endif
# include <winsock2.h>
# include <ws2tcpip.h>
#endif

#include "AppHdr.h"

#include "mp-client.h"

#include <cerrno>
#include <cstring>
#ifdef TARGET_OS_WINDOWS
# define poll WSAPoll
# define close closesocket
  static inline bool mp_would_block()
  { int e = WSAGetLastError(); return e == WSAEWOULDBLOCK || e == WSAEINTR; }
#else
# include <sys/socket.h>
# include <sys/types.h>
# include <netinet/in.h>
# include <arpa/inet.h>
# include <netdb.h>
# include <unistd.h>
# include <fcntl.h>
# include <poll.h>
  static inline bool mp_would_block()
  { return errno == EAGAIN || errno == EWOULDBLOCK; }
#endif

#include "json.h"
#include "json-wrapper.h"
#include "message.h"
#ifdef USE_TILE_LOCAL
#include "ui.h"
#endif

MPClient mp_client;

MPClient::MPClient()
{
}

MPClient::~MPClient()
{
    disconnect();
}

bool MPClient::connect_to(const string& host, int port)
{
#ifdef TARGET_OS_WINDOWS
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif

    m_socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (m_socket_fd < 0)
    {
        mprf(MSGCH_ERROR, "MP client: failed to create socket: %s",
             strerror(errno));
        return false;
    }

    // Resolve hostname.
    struct hostent *he = gethostbyname(host.c_str());
    if (!he)
    {
        mprf(MSGCH_ERROR, "MP client: failed to resolve host '%s'",
             host.c_str());
        close(m_socket_fd);
        m_socket_fd = -1;
        return false;
    }

    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);

    if (::connect(m_socket_fd, (sockaddr*)&addr, sizeof(addr)) < 0)
    {
        mprf(MSGCH_ERROR, "MP client: failed to connect to %s:%d: %s",
             host.c_str(), port, strerror(errno));
        close(m_socket_fd);
        m_socket_fd = -1;
        return false;
    }

    // Set non-blocking after connection established.
#ifdef TARGET_OS_WINDOWS
    u_long mode = 1;
    ioctlsocket(m_socket_fd, FIONBIO, &mode);
#else
    int flags = fcntl(m_socket_fd, F_GETFL, 0);
    fcntl(m_socket_fd, F_SETFL, flags | O_NONBLOCK);
#endif

    m_connected = true;
    mprf(MSGCH_PLAIN, "MP client: connected to %s:%d", host.c_str(), port);

    return true;
}

void MPClient::disconnect()
{
    if (m_socket_fd >= 0)
    {
        close(m_socket_fd);
        m_socket_fd = -1;
    }
    m_connected = false;
}

void MPClient::send_command(const string& json_msg)
{
    if (!m_connected)
        return;

    string line = json_msg + "\n";
    ssize_t sent = 0;
    while (sent < (ssize_t)line.size())
    {
        ssize_t n = send(m_socket_fd, line.c_str() + sent,
                         line.size() - sent, 0);
        if (n < 0)
        {
            if (mp_would_block())
                continue;
            mprf(MSGCH_ERROR, "MP client: send error");
            disconnect();
            return;
        }
        sent += n;
    }
}

vector<string> MPClient::poll_messages()
{
    if (!m_connected)
        return {};

    char buf[4096];
    ssize_t n = recv(m_socket_fd, buf, sizeof(buf), 0);
    if (n > 0)
    {
        m_recv_buffer.append(buf, n);
    }
    else if (n == 0)
    {
        // Connection closed.
        mprf(MSGCH_ERROR, "MP client: server disconnected.");
        disconnect();
        return {};
    }
    else if (!mp_would_block())
    {
        mprf(MSGCH_ERROR, "MP client: recv error");
        disconnect();
        return {};
    }

    return extract_messages();
}

string MPClient::wait_for_message(const string& msg_type, int timeout_ms)
{
    if (!m_connected)
        return "";

    int elapsed = 0;
    const int poll_interval = 50; // ms

    while (elapsed < timeout_ms)
    {
        auto messages = poll_messages();
        for (size_t i = 0; i < messages.size(); i++)
        {
            // Check if this message matches the desired type.
            JsonNode *node = json_decode(messages[i].c_str());
            if (node)
            {
                JsonNode *type_node = json_find_member(node, "type");
                if (type_node && type_node->tag == JSON_STRING
                    && string(type_node->string_) == msg_type)
                {
                    json_delete(node);

                    // Preserve all other messages (before and after the
                    // match) by putting them back in the receive buffer.
                    string preserved;
                    for (size_t j = 0; j < messages.size(); j++)
                    {
                        if (j != i)
                            preserved += messages[j] + "\n";
                    }
                    m_recv_buffer = preserved + m_recv_buffer;

                    return messages[i];
                }
                json_delete(node);
            }
        }

#ifdef USE_TILE_LOCAL
        ui::pump_events(0);
#endif
        struct pollfd pfd;
        pfd.fd = m_socket_fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, poll_interval);
        elapsed += poll_interval;
    }

    return "";
}

vector<string> MPClient::extract_messages()
{
    vector<string> messages;
    size_t pos;
    while ((pos = m_recv_buffer.find('\n')) != string::npos)
    {
        string line = m_recv_buffer.substr(0, pos);
        m_recv_buffer.erase(0, pos + 1);
        if (!line.empty())
            messages.push_back(line);
    }
    return messages;
}
