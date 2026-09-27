#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "CJetlineSys.h"

#include <unistd.h>

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
