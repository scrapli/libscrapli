/* Windows compat stub: sys/uio.h
 * MinGW doesn't provide this header. libssh2.h includes it for
 * struct iovec and readv/writev declarations. On Windows, libssh2
 * doesn't actually use scatter/gather I/O — the include is only there
 * for POSIX compliance. We provide a minimal iovec definition.
 */
#ifndef _WINDOWS_COMPAT_SYS_UIO_H
#define _WINDOWS_COMPAT_SYS_UIO_H

#include <stddef.h>

struct iovec {
    void   *iov_base;   /* Base address */
    size_t  iov_len;    /* Length */
};

/* readv/writev are not used by libscrapli on Windows; stub them out. */
static inline int readv(int fd, const struct iovec *iov, int iovcnt) {
    (void)fd; (void)iov; (void)iovcnt;
    return -1;
}
static inline int writev(int fd, const struct iovec *iov, int iovcnt) {
    (void)fd; (void)iov; (void)iovcnt;
    return -1;
}

#endif /* _WINDOWS_COMPAT_SYS_UIO_H */
