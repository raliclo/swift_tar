#include "libarchive_zip_bridge.h"

#include <archive.h>
#include <archive_entry.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#define swift_tar_chdir _chdir
#define swift_tar_getcwd _getcwd
#else
#include <unistd.h>
#define swift_tar_chdir chdir
#define swift_tar_getcwd getcwd
#endif

static void set_error(char *buffer, size_t capacity, const char *message) {
    if (buffer == NULL || capacity == 0) return;
    snprintf(buffer, capacity, "%s", message != NULL ? message : "unknown libarchive error");
}

static void set_archive_error(char *buffer, size_t capacity,
                              const char *operation, struct archive *archive) {
    const char *detail = archive != NULL ? archive_error_string(archive) : NULL;
    if (buffer == NULL || capacity == 0) return;
    snprintf(buffer, capacity, "%s: %s", operation,
             detail != NULL ? detail : "unknown libarchive error");
}

static int copy_file_to_archive(struct archive *writer,
                                struct archive_entry *entry,
                                char *error_buffer,
                                size_t error_capacity) {
    char buffer[64 * 1024];
    FILE *input;
    size_t count;

    if (archive_entry_filetype(entry) != AE_IFREG || archive_entry_size(entry) == 0) {
        return 0;
    }

#ifdef _WIN32
    {
        const wchar_t *wide_path = archive_entry_sourcepath_w(entry);
        input = wide_path != NULL ? _wfopen(wide_path, L"rb") :
                                    fopen(archive_entry_sourcepath(entry), "rb");
    }
#else
    input = fopen(archive_entry_sourcepath(entry), "rb");
#endif
    if (input == NULL) {
        const char *path = archive_entry_sourcepath(entry);
        if (error_buffer != NULL && error_capacity > 0) {
            snprintf(error_buffer, error_capacity, "cannot open '%s': %s",
                     path != NULL ? path : "<unknown>", strerror(errno));
        }
        return -1;
    }

    while ((count = fread(buffer, 1, sizeof(buffer), input)) > 0) {
        la_ssize_t written = archive_write_data(writer, buffer, count);
        if (written < 0 || (size_t)written != count) {
            set_archive_error(error_buffer, error_capacity, "archive_write_data", writer);
            fclose(input);
            return -1;
        }
    }
    if (ferror(input)) {
        set_error(error_buffer, error_capacity, "failed while reading an input file");
        fclose(input);
        return -1;
    }
    fclose(input);
    return 0;
}

static int add_path(struct archive *writer,
                    const char *path,
                    int verbose,
                    char *error_buffer,
                    size_t error_capacity) {
    struct archive *disk = archive_read_disk_new();
    struct archive_entry *entry = NULL;
    int result = -1;
    int status;

    if (disk == NULL) {
        set_error(error_buffer, error_capacity, "archive_read_disk_new failed");
        return -1;
    }
    archive_read_disk_set_symlink_physical(disk);
    archive_read_disk_set_standard_lookup(disk);

    status = archive_read_disk_open(disk, path);
    if (status != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "archive_read_disk_open", disk);
        goto cleanup;
    }

    for (;;) {
        entry = archive_entry_new();
        if (entry == NULL) {
            set_error(error_buffer, error_capacity, "archive_entry_new failed");
            goto cleanup;
        }

        status = archive_read_next_header2(disk, entry);
        if (status == ARCHIVE_EOF) {
            archive_entry_free(entry);
            entry = NULL;
            result = 0;
            break;
        }
        if (status < ARCHIVE_OK) {
            set_archive_error(error_buffer, error_capacity, "archive_read_next_header", disk);
            goto cleanup;
        }

        if (archive_read_disk_can_descend(disk)) archive_read_disk_descend(disk);
        if (verbose) fprintf(stderr, "a %s\n", archive_entry_pathname(entry));

        status = archive_write_header(writer, entry);
        if (status < ARCHIVE_OK) {
            set_archive_error(error_buffer, error_capacity, "archive_write_header", writer);
            goto cleanup;
        }
        if (copy_file_to_archive(writer, entry, error_buffer, error_capacity) != 0) {
            goto cleanup;
        }

        archive_entry_free(entry);
        entry = NULL;
    }

cleanup:
    if (entry != NULL) archive_entry_free(entry);
    archive_read_free(disk);
    return result;
}

int swift_tar_zip_create(const char *archive_path,
                         const char *change_dir,
                         const char *const *paths,
                         size_t path_count,
                         int force_zip64,
                         int verbose,
                         char *error_buffer,
                         size_t error_capacity) {
    struct archive *writer = NULL;
    char *original_dir = NULL;
    int result = -1;
    int status;
    size_t index;

    if (paths == NULL || path_count == 0) {
        set_error(error_buffer, error_capacity, "no files to archive / 未指定要打包的檔案");
        return -1;
    }

    writer = archive_write_new();
    if (writer == NULL) {
        set_error(error_buffer, error_capacity, "archive_write_new failed");
        return -1;
    }
    if (archive_write_set_format_zip(writer) != ARCHIVE_OK ||
        archive_write_zip_set_compression_deflate(writer) != ARCHIVE_OK ||
        archive_write_set_format_option(writer, "zip", "compression-level", "6") != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "configure ZIP writer", writer);
        goto cleanup;
    }
    if (force_zip64 &&
        archive_write_set_format_option(writer, "zip", "zip64", "1") != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "enable ZIP64", writer);
        goto cleanup;
    }
    /* Store entry names as UTF-8 and set the ZIP "language encoding" flag
       (general purpose bit 11) that says so. Without this libarchive tries to
       translate each pathname into the process's current locale charset, and a
       name it cannot represent there fails the whole write with
       "Can't translate pathname to current locale" -- measured on Windows with
       a Traditional Chinese filename that tar, gzip and bsdtar's own ZIP writer
       all handled without complaint. bsdtar succeeds because it calls
       setlocale() at startup; this backend is a library and must not, so it
       names the charset explicitly instead, which is also the more portable of
       the two answers: the archive no longer depends on the locale that
       happened to be active when it was written.
       將項目名稱以 UTF-8 儲存，並設定 ZIP 的語言編碼旗標（general purpose bit
       11）加以標示。若不這麼做，libarchive 會嘗試把每個路徑名轉換為行程當前
       locale 的字元集，遇到無法表示的名稱便會讓整個寫入失敗，錯誤訊息為
       "Can't translate pathname to current locale"——已在 Windows 上以繁體中文
       檔名實測，而同一檔名在 tar、gzip 以及 bsdtar 自己的 ZIP 寫入器中皆無異狀。
       bsdtar 之所以成功，是因為它在啟動時呼叫 setlocale()；本後端是函式庫，不應
       如此，故改為明確指定字元集。這也是兩者中較可攜的答案：封存不再取決於寫入
       當下恰好生效的 locale。 */
    if (archive_write_set_options(writer, "hdrcharset=UTF-8") != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "set ZIP header charset", writer);
        goto cleanup;
    }

    status = archive_write_open_filename(writer,
        archive_path != NULL && strcmp(archive_path, "-") != 0 ? archive_path : NULL);
    if (status != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "archive_write_open_filename", writer);
        goto cleanup;
    }

    if (change_dir != NULL && change_dir[0] != '\0') {
        original_dir = swift_tar_getcwd(NULL, 0);
        if (original_dir == NULL || swift_tar_chdir(change_dir) != 0) {
            if (error_buffer != NULL && error_capacity > 0) {
                snprintf(error_buffer, error_capacity, "cannot chdir to '%s': %s",
                         change_dir, strerror(errno));
            }
            goto cleanup;
        }
    }

    for (index = 0; index < path_count; ++index) {
        if (add_path(writer, paths[index], verbose, error_buffer, error_capacity) != 0) {
            goto cleanup;
        }
    }
    result = 0;

cleanup:
    if (original_dir != NULL) {
        if (swift_tar_chdir(original_dir) != 0 && result == 0) {
            set_error(error_buffer, error_capacity, "failed to restore working directory");
            result = -1;
        }
        free(original_dir);
    }
    if (writer != NULL) {
        status = archive_write_free(writer);
        if (status != ARCHIVE_OK && result == 0) {
            set_error(error_buffer, error_capacity, "failed to finalize ZIP archive");
            result = -1;
        }
    }
    return result;
}

static int copy_archive_data(struct archive *reader, struct archive *disk,
                             char *error_buffer, size_t error_capacity) {
    const void *buffer;
    size_t size;
    la_int64_t offset;
    int status;

    for (;;) {
        status = archive_read_data_block(reader, &buffer, &size, &offset);
        if (status == ARCHIVE_EOF) return 0;
        if (status != ARCHIVE_OK) {
            set_archive_error(error_buffer, error_capacity, "archive_read_data_block", reader);
            return -1;
        }
        status = archive_write_data_block(disk, buffer, size, offset);
        if (status != ARCHIVE_OK) {
            set_archive_error(error_buffer, error_capacity, "archive_write_data_block", disk);
            return -1;
        }
    }
}

int swift_tar_zip_read(const char *archive_path,
                       const char *destination_dir,
                       int extract,
                       int verbose,
                       int restore_mtime,
                       char *error_buffer,
                       size_t error_capacity) {
    struct archive *reader = NULL;
    struct archive *disk = NULL;
    struct archive_entry *entry;
    char *original_dir = NULL;
    int result = -1;
    int status;
    int extract_flags = ARCHIVE_EXTRACT_PERM |
                        ARCHIVE_EXTRACT_SECURE_SYMLINKS |
                        ARCHIVE_EXTRACT_SECURE_NODOTDOT |
                        ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS;

    if (restore_mtime) extract_flags |= ARCHIVE_EXTRACT_TIME;

    reader = archive_read_new();
    if (reader == NULL) {
        set_error(error_buffer, error_capacity, "archive_read_new failed");
        goto cleanup;
    }
    archive_read_support_filter_all(reader);
    archive_read_support_format_zip(reader);

    status = archive_read_open_filename(reader,
        archive_path != NULL && strcmp(archive_path, "-") != 0 ? archive_path : NULL,
        64 * 1024);
    if (status != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "archive_read_open_filename", reader);
        goto cleanup;
    }

    if (extract) {
        disk = archive_write_disk_new();
        if (disk == NULL) {
            set_error(error_buffer, error_capacity, "archive_write_disk_new failed");
            goto cleanup;
        }
        archive_write_disk_set_options(disk, extract_flags);
        archive_write_disk_set_standard_lookup(disk);

        if (destination_dir != NULL && destination_dir[0] != '\0') {
            original_dir = swift_tar_getcwd(NULL, 0);
            if (original_dir == NULL || swift_tar_chdir(destination_dir) != 0) {
                if (error_buffer != NULL && error_capacity > 0) {
                    snprintf(error_buffer, error_capacity, "cannot chdir to '%s': %s",
                             destination_dir, strerror(errno));
                }
                goto cleanup;
            }
        }
    }

    while ((status = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        const char *path;
        if (status < ARCHIVE_OK) {
            set_archive_error(error_buffer, error_capacity, "archive_read_next_header", reader);
            goto cleanup;
        }
        path = archive_entry_pathname(entry);
        if (!extract || verbose) printf("%s%s\n", extract ? "x " : "", path != NULL ? path : "");

        if (extract) {
            status = archive_write_header(disk, entry);
            if (status < ARCHIVE_OK) {
                set_archive_error(error_buffer, error_capacity, "archive_write_header", disk);
                goto cleanup;
            }
            if (copy_archive_data(reader, disk, error_buffer, error_capacity) != 0) {
                goto cleanup;
            }
            status = archive_write_finish_entry(disk);
            if (status < ARCHIVE_OK) {
                set_archive_error(error_buffer, error_capacity, "archive_write_finish_entry", disk);
                goto cleanup;
            }
        } else {
            archive_read_data_skip(reader);
        }
    }
    result = 0;

cleanup:
    if (original_dir != NULL) {
        if (swift_tar_chdir(original_dir) != 0 && result == 0) {
            set_error(error_buffer, error_capacity, "failed to restore working directory");
            result = -1;
        }
        free(original_dir);
    }
    if (disk != NULL) archive_write_free(disk);
    if (reader != NULL) archive_read_free(reader);
    return result;
}
