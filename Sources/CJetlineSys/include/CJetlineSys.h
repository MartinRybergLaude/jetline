#ifndef CJETLINESYS_H
#define CJETLINESYS_H

#include <sys/types.h>
#include <sys/ioctl.h>
#include <termios.h>

/// Thin wrappers over POSIX calls Swift can't reach portably: `forkpty` lives
/// in <util.h> on Darwin and <pty.h> on Linux, and `pidfd_open` only exists as
/// a raw syscall (Swift can't call the variadic `syscall`).

/// `forkpty` with Jetline's argument order. Returns the child's pid (0 in the
/// child, -1 on failure); `*master` receives the master fd in the parent.
pid_t jl_forkpty(int *master, struct winsize *ws);

/// A pollable fd that becomes readable once `pid` exits (Linux ≥ 5.3).
/// Returns -1 where unsupported (always on Darwin, which uses kqueue).
int jl_pidfd_open(pid_t pid);

#endif
