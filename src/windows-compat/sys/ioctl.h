/* Windows compat stub: sys/ioctl.h
 * MinGW doesn't provide this header. The ioctl functionality used by
 * libscrapli (terminal size setting) is not applicable on Windows.
 * We provide empty macros so includes don't fail.
 */
#ifndef _WINDOWS_COMPAT_SYS_IOCTL_H
#define _WINDOWS_COMPAT_SYS_IOCTL_H

/* TIOCGWINSZ and friends don't exist on Windows; the Windows console API
 * (GetConsoleScreenBufferInfo) replaces them. libscrapli's terminal-size
 * code paths are guarded by platform checks and won't reach here. */

#endif /* _WINDOWS_COMPAT_SYS_IOCTL_H */
