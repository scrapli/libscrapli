/* Windows compat stub: sys/socket.h
 * Minimal self-contained stub. Do NOT include winsock2.h here —
 * pulling real Windows headers through zig translate-c trips over
 * bundled clang SIMD intrinsics headers. The actual C compilation
 * (zig cc) gets real WinSock headers from the system; only
 * translate-c (header parsing for Zig bindings) sees this file.
 */
#ifndef _WINDOWS_COMPAT_SYS_SOCKET_H
#define _WINDOWS_COMPAT_SYS_SOCKET_H

typedef unsigned int socklen_t;

/* POSIX shutdown constants */
#ifndef SHUT_RD
#define SHUT_RD   0
#endif
#ifndef SHUT_WR
#define SHUT_WR   1
#endif
#ifndef SHUT_RDWR
#define SHUT_RDWR 2
#endif

#endif /* _WINDOWS_COMPAT_SYS_SOCKET_H */
