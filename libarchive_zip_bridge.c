#include "libarchive_zip_bridge.h"

#include <archive.h>
#include <archive_entry.h>

#include <errno.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <windows.h>
#define swift_tar_chdir _chdir
#define swift_tar_getcwd _getcwd
#else
#include <sys/stat.h>
#include <unistd.h>
#define swift_tar_chdir chdir
#define swift_tar_getcwd getcwd
#endif

/* Identify a file by identity rather than by its path, so the walk can recognise
 * the archive it is writing however that file is spelled.
 *
 * libarchive detects this case itself on macOS and Linux and returns
 * ARCHIVE_FAILED from archive_write_header with "Can't add archive to itself",
 * which the loop below handles. On Windows it never reports it: measured at
 * a18e92e, `-c --zip -f m.zip .` from inside the tree returned 0 with empty
 * stderr and `./m.zip` among the members. So the check cannot be left to
 * libarchive, and this runs on every platform -- one behaviour to reason about,
 * and the platform that had no check is not the platform whose check is
 * untested.
 *
 * Path strings are not enough: `./m.zip` and an absolute spelling of the same
 * file must both be recognised, which is why the tar path in Swift compares
 * st_dev/st_ino and volumeSerial/fileIndex. The same two pairs are used here.
 *
 * 以檔案身分而非路徑字串辨識檔案，使走訪無論該檔如何拼寫，都認得出「正在寫出的封存」。
 *
 * macOS 與 Linux 上 libarchive 會自行偵測，archive_write_header 回傳
 * ARCHIVE_FAILED 並附上 "Can't add archive to itself"，由下方迴圈處理。Windows 上
 * 它從不回報：於 a18e92e 實測，在樹內執行 `-c --zip -f m.zip .` 回傳 0、stderr 全空，
 * 而 `./m.zip` 就在成員清單裡。故此檢查不能交給 libarchive，且在所有平台都執行——
 * 只需推理一種行為，而原本沒有檢查的平台，不會變成「檢查未受測」的那個平台。
 *
 * 路徑字串不夠：`./m.zip` 與同一檔案的絕對路徑寫法都必須被認出，這正是 Swift 端的 tar
 * 路徑比對 st_dev／st_ino 與 volumeSerial／fileIndex 的原因。此處採用同樣的兩組值。 */
#ifdef _WIN32
typedef struct { DWORD volume; DWORD index_high; DWORD index_low; int valid; } file_id;

static file_id file_identity(const char *path) {
    file_id id;
    HANDLE handle;
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t *wide;
    int wide_len;

    id.volume = 0; id.index_high = 0; id.index_low = 0; id.valid = 0;
    if (path == NULL) return id;

    /* 名稱以 UTF-8 傳遞（見下方 hdrcharset 的說明），故用 CP_UTF8 而非 ANSI 代碼頁；
     * 用 CreateFileA 會讓非 ASCII 檔名比對不到自己。
     * Names travel as UTF-8 (see the hdrcharset note below), so convert with CP_UTF8 and
     * not the ANSI codepage: CreateFileA would fail to match a non-ASCII name against
     * itself. */
    wide_len = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wide_len <= 0) return id;
    wide = (wchar_t *)malloc((size_t)wide_len * sizeof(wchar_t));
    if (wide == NULL) return id;
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, wide_len) <= 0) {
        free(wide);
        return id;
    }

    /* 存取權限 0 只查詢不讀取，且三個 SHARE 旗標齊備——這個檔案此刻正被 writer 開著寫入，
     * 少了任何一個都會拿不到 handle，而那會讓檢查靜默失效。
     * Access 0 queries without reading, and all three share flags are needed: this file is
     * open for writing right now, and without them the handle would fail and the check
     * would silently do nothing. */
    handle = CreateFileW(wide, 0,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(wide);
    if (handle == INVALID_HANDLE_VALUE) return id;
    if (GetFileInformationByHandle(handle, &info)) {
        id.volume = info.dwVolumeSerialNumber;
        id.index_high = info.nFileIndexHigh;
        id.index_low = info.nFileIndexLow;
        id.valid = 1;
    }
    CloseHandle(handle);
    return id;
}

static int same_file(file_id a, file_id b) {
    return a.valid && b.valid && a.volume == b.volume
        && a.index_high == b.index_high && a.index_low == b.index_low;
}
#else
typedef struct { dev_t device; ino_t inode; int valid; } file_id;

static file_id file_identity(const char *path) {
    file_id id;
    struct stat st;

    id.device = 0; id.inode = 0; id.valid = 0;
    if (path != NULL && stat(path, &st) == 0) {
        id.device = st.st_dev;
        id.inode = st.st_ino;
        id.valid = 1;
    }
    return id;
}

static int same_file(file_id a, file_id b) {
    return a.valid && b.valid && a.device == b.device && a.inode == b.inode;
}
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
                    file_id archive_id,
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

        /* 在 descend 與 write_header 之前先問身分：封存本身是一般檔案，不會被 descend，
         * 而在寫入之前攔下它，才能讓每個平台走同一條路徑，不必依賴 libarchive 是否回報。
         * 訊息沿用 libarchive 的原文，好讓兩個平台的 stderr 一致——測試斷言的正是這句話。
         * Ask about identity before descend and before write_header: the archive itself is a
         * regular file and is never descended into, and stopping it before the write is what
         * lets every platform take one path rather than depending on whether libarchive
         * reports it. The wording is libarchive's own, so stderr reads the same on both
         * platforms -- which is what the test asserts. */
        if (archive_id.valid) {
            file_id entry_id = file_identity(archive_entry_sourcepath(entry));
            if (same_file(entry_id, archive_id)) {
                fprintf(stderr, "swift_tar: %s: Can't add archive to itself\n",
                        archive_entry_pathname(entry));
                archive_entry_free(entry);
                entry = NULL;
                continue;
            }
        }

        if (archive_read_disk_can_descend(disk)) archive_read_disk_descend(disk);
        if (verbose) fprintf(stderr, "a %s\n", archive_entry_pathname(entry));

        status = archive_write_header(writer, entry);
        if (status == ARCHIVE_FATAL) {
            set_archive_error(error_buffer, error_capacity, "archive_write_header", writer);
            goto cleanup;
        }
        if (status == ARCHIVE_FAILED) {
            /* This entry cannot be written; the archive is still usable. libarchive
             * defines ARCHIVE_FAILED on write_header to mean exactly that, and it is
             * what "Can't add archive to itself" comes back as when -f names a file
             * inside the tree being walked. Testing `status < ARCHIVE_OK` treated it
             * as fatal, so the walk stopped at the archive file and every member
             * after it was missing from a file that had still been created. bsdtar,
             * on this same libarchive, skips the entry and carries on -- so did the
             * tar path here, which excludes the archive by file identity in Swift.
             * 此項寫不進去，但封存仍然可用。libarchive 對 write_header 的
             * ARCHIVE_FAILED 定義正是如此，而 `-f` 指向被走訪目錄內的檔案時，
             * "Can't add archive to itself" 回傳的就是它。原本以 `status <
             * ARCHIVE_OK` 判斷會當成致命錯誤，於是走訪停在封存檔本身，其後的成員
             * 全部缺席，而檔案仍被建立出來。同一套 libarchive 上的 bsdtar 是略過
             * 該項並繼續；此處的 tar 路徑亦然，它在 Swift 端以檔案身分排除封存。 */
            fprintf(stderr, "swift_tar: %s: %s\n",
                    archive_entry_pathname(entry), archive_error_string(writer));
            archive_entry_free(entry);
            entry = NULL;
            continue;
        }
        if (status < ARCHIVE_OK) {
            /* ARCHIVE_WARN: the header was written, so keep going and copy the data,
             * but do not let the reason go unsaid.
             * ARCHIVE_WARN：標頭已寫入，故繼續複製資料，但不讓原因無聲消失。 */
            fprintf(stderr, "swift_tar: %s: %s\n",
                    archive_entry_pathname(entry), archive_error_string(writer));
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

/* Adopt the environment's character set, once, before any libarchive call.
   A C program starts in the "C" locale, where nl_langinfo(CODESET) is
   "US-ASCII", and libarchive keys two separate decisions off that:

     writing  a name that is not all-ASCII gets general purpose bit 11 only if
              the locale says UTF-8. Left in "C", swift_tar wrote correct UTF-8
              bytes with the flag clear, so readers had to guess -- Python's
              zipfile turned 中文檔名.txt into Σ╕¡µûçµ¬öσÉì.txt, and reads it
              correctly once the flag is set. (Info-ZIP `unzip` 6.00, which is
              what macOS ships, mangles the name either way; it predates this
              part of the spec, so it is not evidence about the archive.)
     reading  a name whose bit 11 IS set must be converted from UTF-8 to the
              locale's charset, which cannot be done from "C" without iconv:
              "Pathname cannot be converted from UTF-8 to current locale".

   So it has to be set for both directions or neither: setting it only on the
   write side produced archives that bsdtar and Python read correctly and
   swift_tar itself could not. Nothing is converted here -- UTF-8 in a UTF-8
   locale is the identity -- this only tells libarchive what the bytes already
   are. bsdtar does the same at startup, which is why it never had the problem.

   Not on Windows: there the hdrcharset option resolves through the Win32 API
   and already does this job, and changing the process locale could disturb a
   path that works.
   在任何 libarchive 呼叫之前，先採用環境的字元集，且僅一次。C 程式啟動於 "C"
   locale，其 nl_langinfo(CODESET) 為 "US-ASCII"，而 libarchive 有兩個判斷取決於它：

     寫入  非全 ASCII 的名稱，唯有在 locale 為 UTF-8 時才會取得 general purpose
           bit 11。停留在 "C" 時，swift_tar 寫出的是正確的 UTF-8 位元組卻未設旗標，
           讀取端只能用猜的——Python 的 zipfile 把 中文檔名.txt 讀成
           Σ╕¡µûçµ¬öσÉì.txt，旗標設定後即可正確讀取。（macOS 隨附的 Info-ZIP
           `unzip` 6.00 在設定前後皆為亂碼；它早於規範的這個部分，故不能作為判斷
           封存正確與否的證據。）
     讀取  已設 bit 11 的名稱必須從 UTF-8 轉為 locale 的字元集，而自 "C" 出發在無
           iconv 時無法完成：「Pathname cannot be converted from UTF-8 to current
           locale」。

   故兩個方向必須一起設定，否則就都不要設：只在寫入端設定的結果，是產出 bsdtar 與
   Python 都讀得正確、swift_tar 自己卻讀不開的封存。此處不轉換任何東西——UTF-8 在
   UTF-8 locale 下是恆等——只是告訴 libarchive 這些位元組本來就是什麼。bsdtar 在啟動
   時做的是同一件事，這正是它從未遇到此問題的原因。

   Windows 不適用：該平台的 hdrcharset 選項經由 Win32 API 解析且已完成此職責，變更
   行程 locale 反而可能擾亂一條原本可用的路徑。 */
static void adopt_environment_charset(void)
{
#if !defined(_WIN32)
    static int done = 0;
    if (!done) {
        setlocale(LC_CTYPE, "");
        done = 1;
    }
#endif
}

int swift_tar_zip_create(const char *archive_path,
                         const char *change_dir,
                         const char *const *paths,
                         size_t path_count,
                         int force_zip64,
                         int verbose,
                         char *error_buffer,
                         size_t error_capacity) {
    adopt_environment_charset();
    struct archive *writer = NULL;
    char *original_dir = NULL;
    file_id archive_id = {0};
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
    /* Two different mechanisms mark entry names as UTF-8, and which one applies
       is decided by the platform, not by us. libarchive's ZIP writer sets
       general purpose bit 11 if EITHER the hdrcharset option resolved to UTF-8,
       OR nl_langinfo(CODESET) says the process is already running in UTF-8.

       On Windows the option is the one that works: names arrive from the disk
       reader as UTF-16, converting them to UTF-8 is well defined, and it is
       done through the Win32 API. Without it a Traditional Chinese filename
       failed the whole write with "Can't translate pathname to current locale".

       On macOS and Linux the option is not merely unavailable, it is wrong.
       Names arrive already encoded in UTF-8, so nothing needs converting, and
       hdrcharset means "convert FROM the process locale TO UTF-8". Measured
       with -DENABLE_ICONV=ON to make the option succeed: every byte of
       'src/中文檔名.txt' became U+FFFD and the write failed with "Can't
       translate pathname to UTF-8", because the process locale is "C" and the
       conversion was ASCII->UTF-8. Enabling iconv does not fix this platform;
       it activates a destructive conversion that was previously only failing to
       initialise. So the option stays best-effort, and setlocale below takes
       the other branch.
       有兩種機制可將項目名稱標示為 UTF-8，適用哪一種由平台決定，而非由我們決定。
       libarchive 的 ZIP writer 在「hdrcharset 選項解析為 UTF-8」或
       「nl_langinfo(CODESET) 顯示行程本身即以 UTF-8 執行」任一成立時設定
       general purpose bit 11。

       在 Windows 上有效的是該選項：名稱由 disk reader 以 UTF-16 傳入，轉為 UTF-8
       定義明確，且經由 Win32 API 完成。缺少它時，繁體中文檔名會使整個寫入失敗。

       在 macOS 與 Linux 上，該選項不只是不可用，而是錯的。名稱傳入時已是 UTF-8
       編碼，無須轉換；而 hdrcharset 的語意是「從行程 locale 轉為 UTF-8」。以
       -DENABLE_ICONV=ON 實測讓該選項成功後：'src/中文檔名.txt' 的每個位元組都變成
       U+FFFD，且寫入以「Can't translate pathname to UTF-8」失敗——因為行程 locale
       為 "C"，該轉換實為 ASCII→UTF-8。啟用 iconv 並未修好本平台，只是啟動了一個
       原本連初始化都失敗的破壞性轉換。故此選項維持盡力而為，改由下方的 setlocale
       走另一條分支。 */
    if (archive_write_set_options(writer, "hdrcharset=UTF-8") != ARCHIVE_OK) {
        if (verbose) {
            fprintf(stderr,
                "swift_tar: ZIP header charset stays platform default: %s\n",
                archive_error_string(writer));
        }
        archive_clear_error(writer);
    }

    status = archive_write_open_filename(writer,
        archive_path != NULL && strcmp(archive_path, "-") != 0 ? archive_path : NULL);
    if (status != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "archive_write_open_filename", writer);
        goto cleanup;
    }

    /* 身分要在 chdir 之前取得：`archive_path` 是相對於呼叫端的工作目錄，而下面馬上就會
     * 切換到 change_dir。切換之後再解析同一個字串，會指向另一個檔案或根本不存在，而那會
     * 讓檢查靜默失效——正是這類「看起來有防守其實沒有」的形狀。
     * 寫到 stdout（`-f -`）時沒有輸出檔可比，identity 保持無效，檢查自然不生效。
     * Take the identity before the chdir: `archive_path` is relative to the caller's working
     * directory and the next block moves out of it. Resolving the same string afterwards
     * would name a different file or none at all, and the check would silently do nothing --
     * exactly the looks-guarded-but-is-not shape. Writing to stdout (`-f -`) has no output
     * file to compare against, so the identity stays invalid and the check does not fire. */
    if (archive_path != NULL && strcmp(archive_path, "-") != 0) {
        archive_id = file_identity(archive_path);
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
        if (add_path(writer, paths[index], archive_id, verbose, error_buffer, error_capacity) != 0) {
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

static int copy_archive_data_to_stdout(struct archive *reader,
                                       char *error_buffer,
                                       size_t error_capacity) {
    char buffer[64 * 1024];
    la_ssize_t count;

    while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
        if (fwrite(buffer, 1, (size_t)count, stdout) != (size_t)count) {
            if (error_buffer != NULL && error_capacity > 0) {
                snprintf(error_buffer, error_capacity, "write stdout: %s", strerror(errno));
            }
            return -1;
        }
    }
    if (count < 0) {
        set_archive_error(error_buffer, error_capacity, "archive_read_data", reader);
        return -1;
    }
    return 0;
}

int swift_tar_zip_read(const char *archive_path,
                       const char *destination_dir,
                       int extract,
                       int to_stdout,
                       int verbose,
                       int restore_mtime,
                       char *error_buffer,
                       size_t error_capacity) {
    adopt_environment_charset();
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
    {
        /* On a real file, register both ZIP readers and let libarchive pick the
           seekable one, which reads the central directory and therefore sees
           every entry. On stdin there is no central directory to seek to, and
           letting it choose produced silent data loss rather than an error: a
           300 KB archive holding three files listed two entries and extracted
           exactly one, with exit 0 both times, while the same archive read from
           a path gave all three. A smaller archive failed outright instead, so
           the damage varied with the input -- the worst kind, since a script
           sees success either way. Naming the streamable reader explicitly is
           what makes stdin read local headers front to back.
           對真實檔案註冊兩種 ZIP reader，由 libarchive 挑選 seekable 的那個，它會
           讀取 central directory，因而看得到每一個項目。stdin 上沒有 central
           directory 可供 seek，而放任它自行挑選造成的是靜默資料遺失而非錯誤：一個
           含三個檔案的 300 KB 封存列出兩個項目、只解出一個檔案，兩次離開碼皆為 0，
           而同一封存以路徑讀取時三個檔案齊全。較小的封存則是直接失敗，故損害隨輸入
           而異——這是最糟的一類，因為腳本在兩種情況下看到的都是成功。明確指定
           streamable reader，才能讓 stdin 由前往後逐一讀取 local header。 */
        int from_stdin = (archive_path == NULL || strcmp(archive_path, "-") == 0);
        if (from_stdin) {
            archive_read_support_format_zip_streamable(reader);
        } else {
            archive_read_support_format_zip(reader);
        }
    }

    status = archive_read_open_filename(reader,
        archive_path != NULL && strcmp(archive_path, "-") != 0 ? archive_path : NULL,
        64 * 1024);
    if (status != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "archive_read_open_filename", reader);
        goto cleanup;
    }

    if (extract && !to_stdout) {
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
        if (!extract) {
            printf("%s\n", path != NULL ? path : "");
        } else if (verbose) {
            FILE *listing = to_stdout ? stderr : stdout;
            fprintf(listing, "x %s\n", path != NULL ? path : "");
        }

        if (extract && to_stdout) {
            if (archive_entry_filetype(entry) == AE_IFREG) {
                if (copy_archive_data_to_stdout(reader, error_buffer, error_capacity) != 0) {
                    goto cleanup;
                }
            } else {
                archive_read_data_skip(reader);
            }
        } else if (extract) {
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
    if (to_stdout && fflush(stdout) != 0) {
        if (error_buffer != NULL && error_capacity > 0) {
            snprintf(error_buffer, error_capacity, "flush stdout: %s", strerror(errno));
        }
        goto cleanup;
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
