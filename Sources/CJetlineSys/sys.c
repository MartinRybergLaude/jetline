#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "CJetlineSys.h"

#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>

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
