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
                         int follow_symlinks,
                         int (*is_excluded)(const char *path, int is_directory),
                         char *error_buffer,
                         size_t error_capacity);

int swift_tar_zip_read(const char *archive_path,
                       const char *destination_dir,
                       int extract,
                       int to_stdout,
                       int verbose,
                       int restore_mtime,
                       int (*is_excluded)(const char *path, int is_directory),
                       char *error_buffer,
                       size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
