/* Windows compat shadow header: string.h
 *
 * This directory is searched FIRST (-I src/windows-compat), so this file
 * intercepts every #include <string.h>. Its sole job is to pre-set
 * __MINGW_FORTIFY_LEVEL=0 BEFORE deferring to the real mingw header via
 * include_next, which compiles out the BOS fortify overload bodies
 * (wcscpy/wcscat wrappers containing local extern decls of *_s functions).
 * Those bodies trip a zig translate-c limitation (unused local constants)
 * and there is no other reliable way to suppress them.
 */
#ifndef _WINDOWS_COMPAT_STRING_H
#define _WINDOWS_COMPAT_STRING_H

#ifndef __MINGW_FORTIFY_LEVEL
#define __MINGW_FORTIFY_LEVEL 0
#endif

#include_next <string.h>

#endif /* _WINDOWS_COMPAT_STRING_H */
