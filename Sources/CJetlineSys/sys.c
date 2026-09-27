#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "CJetlineSys.h"

#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#include <unistd.h>
#include <sys/syscall.h>
#endif

pid_t jl_forkpty(int *master, struct winsize *ws) {
    return forkpty(master, NULL, NULL, ws);
}

int jl_pidfd_open(pid_t pid) {
#if defined(__linux__) && defined(SYS_pidfd_open)
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    (void)pid;
    return -1;
#endif
}

int jl_set_winsize(int fd, unsigned short rows, unsigned short cols, unsigned short xpixel, unsigned short ypixel) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = xpixel;
    ws.ws_ypixel = ypixel;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

void jl_close_from(int lowfd, int maxfd) {
#if defined(__linux__)
    (void)maxfd;
    closefrom(lowfd);
#else
    for (int fd = lowfd; fd < maxfd; fd++) {
        close(fd);
    }
#endif
}

#if defined(__linux__)
int jl_spawn_addchdir(posix_spawn_file_actions_t *actions, const char *path) {
    return posix_spawn_file_actions_addchdir_np(actions, path);
}

int jl_spawn_addclosefrom(posix_spawn_file_actions_t *actions, int from) {
    return posix_spawn_file_actions_addclosefrom_np(actions, from);
}

short jl_spawn_setsid_flag(void) {
    return POSIX_SPAWN_SETSID;
}
#endif

void jl_reset_signals(void) {
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig == SIGKILL || sig == SIGSTOP) continue;
        signal(sig, SIG_DFL);
    }
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
}

int jl_peer_uid(int fd) {
#if defined(__APPLE__)
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0) return -1;
    return (int)uid;
#else
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
    return (int)cred.uid;
#endif
}

/// A TCP socket that is close-on-exec from birth where the platform allows,
/// so a subprocess spawned at that instant can't inherit it.
static int jl_tcp_socket(int domain) {
#if defined(__linux__)
    return socket(domain, SOCK_STREAM | SOCK_CLOEXEC, 0);
#else
    return socket(domain, SOCK_STREAM, 0);
#endif
}

int jl_accept(int listener) {
#if defined(__linux__)
    int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
#else
    int fd = accept(listener, NULL, NULL);
    if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
#endif
    return fd < 0 ? -errno : fd;
}

static void jl_cloexec_nosigpipe(int fd) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#if defined(__APPLE__)
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
}

int jl_tcp_listen_loopback(int family, int port, int reuse) {
    int fd = jl_tcp_socket(family == 6 ? AF_INET6 : AF_INET);
    if (fd < 0) return -errno;
    jl_cloexec_nosigpipe(fd);
    int on = 1;
    if (reuse) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    int result;
    if (family == 6) {
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, sizeof(on));
        struct sockaddr_in6 addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin6_family = AF_INET6;
        addr.sin6_port = htons((unsigned short)port);
        addr.sin6_addr = in6addr_loopback;
        result = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    } else {
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((unsigned short)port);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        result = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    }
    if (result != 0 || listen(fd, 128) != 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    return fd;
}

int jl_tcp_connect(const char *address, int port, int timeout_ms) {
    struct sockaddr_in v4;
    struct sockaddr_in6 v6;
    memset(&v4, 0, sizeof(v4));
    memset(&v6, 0, sizeof(v6));
    struct sockaddr *addr;
    socklen_t length;
    int family;
    if (inet_pton(AF_INET, address, &v4.sin_addr) == 1) {
        v4.sin_family = AF_INET;
        v4.sin_port = htons((unsigned short)port);
        addr = (struct sockaddr *)&v4;
        length = sizeof(v4);
        family = AF_INET;
    } else if (inet_pton(AF_INET6, address, &v6.sin6_addr) == 1) {
        v6.sin6_family = AF_INET6;
        v6.sin6_port = htons((unsigned short)port);
        addr = (struct sockaddr *)&v6;
        length = sizeof(v6);
        family = AF_INET6;
    } else {
        return -EINVAL;
    }
    int fd = jl_tcp_socket(family);
    if (fd < 0) return -errno;
    jl_cloexec_nosigpipe(fd);
    // Non-blocking with a deadline: a listener whose backlog is full drops
    // the SYN, and a blocking connect would sit through the retries.
    int flags = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int result = connect(fd, addr, length);
    if (result != 0 && errno == EINPROGRESS) {
        struct pollfd pfd = { fd, POLLOUT, 0 };
        int ready;
        do { ready = poll(&pfd, 1, timeout_ms); } while (ready < 0 && errno == EINTR);
        if (ready <= 0) {
            close(fd);
            return ready == 0 ? -ETIMEDOUT : -errno;
        }
        int error = 0;
        socklen_t size = sizeof(error);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size);
        if (error != 0) {
            close(fd);
            return -error;
        }
        result = 0;
    }
    if (result != 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    fcntl(fd, F_SETFL, flags);
    return fd;
}

void jl_tcp_prepare(int fd) {
    jl_cloexec_nosigpipe(fd);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    int on = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
}

long jl_send(int fd, const void *buffer, unsigned long length) {
#if defined(__linux__)
    return (long)send(fd, buffer, length, MSG_NOSIGNAL);
#else
    return (long)send(fd, buffer, length, 0);
#endif
}

void jl_tcp_abort_on_close(int fd) {
    struct linger linger = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, sizeof(linger));
}
