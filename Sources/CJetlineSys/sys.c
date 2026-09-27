#include "CJetlineSys.h"

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
