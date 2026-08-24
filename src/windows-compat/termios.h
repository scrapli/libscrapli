/* Windows compat stub: termios.h
 * MinGW doesn't provide this. libscrapli uses termios for raw terminal
 * mode on the bin transport (pty), which is not applicable on Windows.
 */
#ifndef _WINDOWS_COMPAT_TERMIOS_H
#define _WINDOWS_COMPAT_TERMIOS_H

struct termios {
    unsigned int c_iflag;
    unsigned int c_oflag;
    unsigned int c_cflag;
    unsigned int c_lflag;
    char c_cc[20];
    unsigned int c_ispeed;
    unsigned int c_ospeed;
};

#define TCSANOW   0
#define TCSADRAIN 1
#define TCSAFLUSH 2

#endif /* _WINDOWS_COMPAT_TERMIOS_H */
