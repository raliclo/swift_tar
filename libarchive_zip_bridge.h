#ifndef SWIFT_TAR_LIBARCHIVE_ZIP_BRIDGE_H
#define SWIFT_TAR_LIBARCHIVE_ZIP_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int swift_tar_zip_create(const char *archive_path,
                         const char *change_dir,
                         const char *const *paths,
                         size_t path_count,
                         int force_zip64,
                         int verbose,
                         char *error_buffer,
                         size_t error_capacity);

int swift_tar_zip_read(const char *archive_path,
                       const char *destination_dir,
                       int extract,
                       int verbose,
                       int restore_mtime,
                       char *error_buffer,
                       size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
