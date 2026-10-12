/*
 * data.c - exported data of Ycode's libsystem_pthread.
 *
 * Clean-room Ycode code, from host-library-init.md sections 5.1 and 7.1.
 * __unix_conforming and the shared-cache TSD key bounds keep their
 * generated read-only definitions (common/data-symbols.txt). The two
 * defined here are the ones this library writes or that need a non-zero
 * layout:
 *   __is_threaded           int, 0 until a second thread exists
 *   pthread_layout_offsets  { version 1, TSD offset 224, TSD-pointer
 *                             offset 0, entry size 8 } as four u16
 */
#include "yc_pthread.h"

YC_EXPORT int YC_FN(__is_threaded) = 0;

YC_EXPORT const yc_u16 YC_FN(pthread_layout_offsets)[4] = { 1, YC_PTHREAD_TSD_OFFSET, 0, 8 };
