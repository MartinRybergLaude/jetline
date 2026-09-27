#ifndef CJETLINESYS_H
#define CJETLINESYS_H

#include <sys/types.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <spawn.h>

/// Thin wrappers over POSIX calls Swift can't reach portably: `forkpty` lives
/// in <util.h> on Darwin and <pty.h> on Linux, and `pidfd_open` only exists as
/// a raw syscall (Swift can't call the variadic `syscall`).

/// `forkpty` with Jetline's argument order. Returns the child's pid (0 in the
/// child, -1 on failure); `*master` receives the master fd in the parent.
pid_t jl_forkpty(int *master, struct winsize *ws);

/// A pollable fd that becomes readable once `pid` exits (Linux ≥ 5.3).
/// Returns -1 where unsupported (always on Darwin, which uses kqueue).
int jl_pidfd_open(pid_t pid);

/// `ioctl(TIOCSWINSZ)` — `ioctl` is variadic, so Swift can't call it on Linux.
int jl_set_winsize(int fd, unsigned short rows, unsigned short cols, unsigned short xpixel, unsigned short ypixel);

/// Close every descriptor from `lowfd` up (to `maxfd` where there's no
/// `closefrom`). For a forked child before `execve`: without it the child
/// inherits whatever pipes the parent had open at that instant — another
/// subprocess's stdout, say, whose reader then never sees EOF.
/// Async-signal-safe.
void jl_close_from(int lowfd, int maxfd);

/// Reset every signal to its default disposition and clear the signal mask.
/// For a forked child before `execve`: ignored signals survive exec, and a
/// daemon that ignores SIGINT/SIGTERM/SIGHUP/SIGPIPE would otherwise pass
/// that on to every shell and agent it starts. Async-signal-safe.
void jl_reset_signals(void);

/// The uid of a connected unix-socket peer, or -1.
int jl_peer_uid(int fd);

/// Loopback TCP for port forwarding. `family` is 4 or 6; results are an fd
/// (close-on-exec, and SIGPIPE-free where the platform allows) or -errno.

/// Listen on 127.0.0.1:`port` or [::1]:`port` (v6-only, so the two don't
/// collide). `reuse` sets SO_REUSEADDR — only for a port nothing else is
/// listening on, since on BSD it lets a specific address shadow another
/// process's wildcard bind.
int jl_tcp_listen_loopback(int family, int port, int reuse);

/// Connect to `address` (an IPv4 or IPv6 literal) on `port`, giving up
/// after `timeout_ms`. The socket comes back blocking.
int jl_tcp_connect(const char *address, int port, int timeout_ms);

/// `accept`, close-on-exec from the start. Returns the fd or -errno.
int jl_accept(int listener);

/// Non-blocking, no Nagle, no SIGPIPE: ready for a dispatch source.
void jl_tcp_prepare(int fd);

/// `send` without SIGPIPE (MSG_NOSIGNAL on Linux).
long jl_send(int fd, const void *buffer, unsigned long length);

/// Make the next close send a RST instead of a FIN.
void jl_tcp_abort_on_close(int fd);

#if defined(__linux__)
/// glibc's `posix_spawn_file_actions_add{chdir,closefrom}_np` and
/// `POSIX_SPAWN_SETSID` are only declared under _GNU_SOURCE, which Swift's
/// Glibc module doesn't set on every distro's headers. Wrapped here, where
/// it is set.
int jl_spawn_addchdir(posix_spawn_file_actions_t *actions, const char *path);
int jl_spawn_addclosefrom(posix_spawn_file_actions_t *actions, int from);
short jl_spawn_setsid_flag(void);
#endif

#endif
