#include "include/ffbulk.h"

#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#define FF_BUF_SIZE (128 * 1024)
#define FF_BATCH_MAX 256

static inline uint32_t ff_read_u32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static inline uint64_t ff_read_u64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

int ff_scan_dir(const char *path, ff_entry_callback callback, void *context) {
    int fd = open(path, O_RDONLY, 0);
    if (fd < 0) {
        return -1;
    }

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE |
                        ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FILEID;
    alist.fileattr = ATTR_FILE_DATALENGTH;

    uint8_t *buf = (uint8_t *)malloc(FF_BUF_SIZE);
    if (buf == NULL) {
        close(fd);
        errno = ENOMEM;
        return -1;
    }

    ff_entry_t entries[FF_BATCH_MAX];
    int rc = 0;

    for (;;) {
        int retcount = getattrlistbulk(fd, &alist, buf, FF_BUF_SIZE, 0);
        if (retcount < 0) {
            rc = -1;
            break;
        }
        if (retcount == 0) {
            break;
        }

        const uint8_t *cursor = buf;
        int batch_count = 0;

        for (int i = 0; i < retcount; i++) {
            const uint8_t *entry_start = cursor;
            uint32_t entry_len = ff_read_u32(cursor);
            const uint8_t *p = cursor + sizeof(uint32_t);

            // ATTR_CMN_RETURNED_ATTRS is always returned first when requested:
            // attribute_set_t = { commonattr, volattr, dirattr, fileattr, forkattr }
            uint32_t ret_common = ff_read_u32(p + 0);
            uint32_t ret_file = ff_read_u32(p + 12);
            p += 20;

            ff_entry_t e;
            memset(&e, 0, sizeof(e));

            if (ret_common & ATTR_CMN_NAME) {
                // attrreference_t { int32_t attr_dataoffset; uint32_t attr_length; }
                // attr_dataoffset is relative to the address of the attrreference_t itself.
                int32_t data_offset = (int32_t)ff_read_u32(p + 0);
                uint32_t data_length = ff_read_u32(p + 4);
                const char *name_ptr = (const char *)(p + data_offset);
                uint32_t copy_len = data_length;
                if (copy_len > 0) {
                    copy_len -= 1; // data_length includes the NUL terminator
                }
                if (copy_len > FF_NAME_MAX - 1) {
                    copy_len = FF_NAME_MAX - 1;
                }
                memcpy(e.name, name_ptr, copy_len);
                e.name[copy_len] = '\0';
                e.name_len = (uint16_t)copy_len;
                p += sizeof(attrreference_t);
            }
            if (ret_common & ATTR_CMN_OBJTYPE) {
                uint32_t obj_type = ff_read_u32(p);
                e.is_dir = (obj_type == VDIR) ? 1 : 0;
                p += sizeof(fsobj_type_t);
            }
            // Kernel returns attributes in bitmask order: CRTIME (0x0200) before MODTIME (0x0400).
            if (ret_common & ATTR_CMN_CRTIME) {
                int64_t tv_sec = (int64_t)ff_read_u64(p);
                e.crtime_sec = tv_sec;
                p += sizeof(struct timespec);
            }
            if (ret_common & ATTR_CMN_MODTIME) {
                // struct timespec on 64-bit Darwin: { time_t tv_sec; long tv_nsec; } = 16 bytes
                int64_t tv_sec = (int64_t)ff_read_u64(p);
                e.mtime_sec = tv_sec;
                p += sizeof(struct timespec);
            }
            if (ret_common & ATTR_CMN_FILEID) {
                e.file_id = ff_read_u64(p);
                p += sizeof(uint64_t);
            }
            if (ret_file & ATTR_FILE_DATALENGTH) {
                e.size = ff_read_u64(p);
                p += sizeof(uint64_t);
            }

            entries[batch_count++] = e;
            if (batch_count == FF_BATCH_MAX) {
                callback(entries, batch_count, context);
                batch_count = 0;
            }

            cursor = entry_start + entry_len;
        }

        if (batch_count > 0) {
            callback(entries, batch_count, context);
        }
    }

    free(buf);
    close(fd);
    return rc;
}
