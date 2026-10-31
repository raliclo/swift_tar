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
#include <share.h>
#include <windows.h>
#define swift_tar_chdir _chdir
#define swift_tar_getcwd _getcwd
#else
#include <sys/stat.h>
#include <unistd.h>
#ifdef SWIFT_TAR_ZIP_PARALLEL
#include <fcntl.h>
#include <pthread.h>
#include <zlib.h>
#endif
#define swift_tar_chdir chdir
#define swift_tar_getcwd getcwd
#endif

/* The text for an errno value, written into `buffer`. On Windows strerror is declared
 * deprecated (C4996, shown by clang-cl's default warning level and hidden by cl's /W1), so
 * that platform uses strerror_s; elsewhere strerror is copied, keeping its wording unchanged.
 * Copying also means the result never points at the static buffer strerror may share.
 * errno 值的說明文字，寫入 `buffer`。Windows 上 strerror 被宣告為 deprecated（C4996，clang-cl
 * 的預設警告等級會顯示，cl 的 /W1 則隱藏），故該平台改用 strerror_s；其他平台複製 strerror 的
 * 結果，措辭不變。複製也使結果不會指向 strerror 可能共用的靜態緩衝區。 */
static const char *error_text(int error_number, char *buffer, size_t capacity) {
#ifdef _WIN32
    if (strerror_s(buffer, capacity, error_number) != 0) {
        snprintf(buffer, capacity, "error %d", error_number);
    }
#else
    snprintf(buffer, capacity, "%s", strerror(error_number));
#endif
    return buffer;
}

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

/* libarchive's message for its last error, never NULL. archive_error_string returns NULL when no
 * message was set, and a status below ARCHIVE_OK does not promise one; printf's %s with NULL is
 * undefined behaviour -- glibc prints "(null)", other C runtimes may crash. Every message in this
 * file goes through here (2026-10-30 review; test_bridge_errors.zsh keeps it that way).
 * libarchive 對最後一個錯誤的訊息，絕不為 NULL。沒有設定訊息時 archive_error_string 回傳 NULL，
 * 而低於 ARCHIVE_OK 的狀態並不保證有訊息；printf 的 %s 收到 NULL 是未定義行為——glibc 印出
 * "(null)"，其他 C 執行環境可能崩潰。本檔所有訊息都經過這裡（2026-10-30 審查；
 * test_bridge_errors.zsh 確保維持如此）。 */
static const char *archive_reason(struct archive *archive) {
    const char *detail = archive != NULL ? archive_error_string(archive) : NULL;
    return detail != NULL ? detail : "unknown libarchive error";
}

static void set_archive_error(char *buffer, size_t capacity,
                              const char *operation, struct archive *archive) {
    if (buffer == NULL || capacity == 0) return;
    snprintf(buffer, capacity, "%s: %s", operation, archive_reason(archive));
}

/* Report an entry left out because it could not be read, and count it. The wording is the
 * tar path's, so both say the same thing about the same tree; the count becomes exit 1 once
 * the archive is complete (swift_tar_zip_create). Until 2026-10-22 an unreadable directory
 * or file ended the whole run here and left an empty or partial ZIP, where bsdtar -- on this
 * same libarchive -- reports it, carries on, and exits 1.
 * 回報一個因讀不到而略過的項目，並計數。措辭與 tar 路徑相同，使兩者對同一棵樹說同一件事；
 * 計數在封存完整之後轉成結束碼 1（swift_tar_zip_create）。2026-10-22 之前，讀不到的目錄或檔案
 * 會在這裡結束整次執行，留下空的或不完整的 ZIP；而用同一套 libarchive 的 bsdtar 會回報、繼續，
 * 最後以 1 結束。 */
static void note_unreadable(long *unreadable, const char *name, const char *what,
                            const char *what_zh, int error_number) {
    char text[256];
    const char *reason = error_number != 0 ? error_text(error_number, text, sizeof(text))
                                           : "unknown error";
    fprintf(stderr, "swift_tar: %s: %s: %s / %s：%s\n",
            name != NULL ? name : "<unknown>", what, reason, what_zh, reason);
    ++*unreadable;
}

/* Open a regular file's data for reading, or NULL with errno set.
 * 開啟一般檔案的資料以供讀取；失敗時回傳 NULL 並設好 errno。 */
static FILE *open_entry_source(struct archive_entry *entry) {
#ifdef _WIN32
    /* _wfsopen/_fsopen with _SH_DENYNO rather than the deprecated _wfopen/fopen (C4996). Not
     * _wfopen_s/fopen_s: those open with _SH_SECURE, which for a read-only open denies other
     * writers, so a file another process is still writing (a log, say) would stop being
     * archivable. _SH_DENYNO is the sharing _wfopen/fopen always had, and errno is set as before.
     * 以 _wfsopen／_fsopen 加 _SH_DENYNO 取代 deprecated 的 _wfopen／fopen（C4996）。不用
     * _wfopen_s／fopen_s：它們以 _SH_SECURE 開啟，唯讀開啟時會拒絕其他寫入者，於是另一個行程
     * 仍在寫入的檔案（例如日誌）就無法再被封存。_SH_DENYNO 正是 _wfopen／fopen 一直以來的共用
     * 模式，errno 也照舊設定。 */
    const wchar_t *wide_path = archive_entry_sourcepath_w(entry);
    return wide_path != NULL ? _wfsopen(wide_path, L"rb", _SH_DENYNO) :
                               _fsopen(archive_entry_sourcepath(entry), "rb", _SH_DENYNO);
#else
    return fopen(archive_entry_sourcepath(entry), "rb");
#endif
}

/* Messages name an entry through entry_sort_name: UTF-8 first, so a non-ANSI name on Windows
 * is not printed as "(null)" (2026-10-31 review, low). Defined below.
 * 訊息經由 entry_sort_name 取項目名稱：先取 UTF-8，Windows 上非 ANSI 名稱才不會印成 "(null)"
 *（2026-10-31 審查低風險項）。定義在下方。 */
static const char *entry_sort_name(struct archive_entry *entry);

/* Copy `input`, already opened by write_entry, into the entry just written, and close it.
 * 把 write_entry 已開啟的 `input` 複製進剛寫出的項目，並關閉它。 */
static int copy_file_to_archive(struct archive *writer,
                                struct archive_entry *entry,
                                FILE *input,
                                long *unreadable,
                                char *error_buffer,
                                size_t error_capacity) {
    char buffer[64 * 1024];
    size_t count;
    la_int64_t remaining;

    if (input == NULL) return 0;
    /* No more than the size the entry was listed with. A file that grew after that used to
     * be read to its new end here: libarchive takes only the listed size, the count came
     * back short, and the whole run ended with an error -- while the threaded path stored
     * the same file without complaint. Both now store the listed size.
     * 不超過項目列出時的大小。列出之後才變大的檔案，這裡原本會讀到新的結尾：libarchive 只收
     * 列出的大小，回傳的數量少了，整次執行以錯誤結束——而執行緒路徑對同一個檔案卻照存不誤。
     * 現在兩邊存的都是列出時的大小。 */
    remaining = archive_entry_size(entry);

    while (remaining > 0 &&
           (count = fread(buffer, 1, remaining < (la_int64_t)sizeof(buffer) ?
                                     (size_t)remaining : sizeof(buffer), input)) > 0) {
        la_ssize_t written = archive_write_data(writer, buffer, count);

        remaining -= (la_int64_t)count;
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
    /* The file shrank after it was listed. The header already states the listed size, so
     * pad with zeros to it, as the tar path does, and count it toward the exit status. Until
     * 2026-10-31 the entry was silently left short (review, low).
     * 列出之後檔案縮小了。標頭已記下列出時的大小，所以與 tar 路徑相同，以零補足並計入結束碼。
     * 2026-10-31 之前該項目被默默存短（審查低風險項）。 */
    if (remaining > 0) {
        la_int64_t shrank = remaining;

        memset(buffer, 0, sizeof(buffer));
        while (remaining > 0) {
            size_t n = remaining < (la_int64_t)sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
            la_ssize_t written = archive_write_data(writer, buffer, n);

            if (written < 0 || (size_t)written != n) {
                set_archive_error(error_buffer, error_capacity, "archive_write_data", writer);
                return -1;
            }
            remaining -= (la_int64_t)n;
        }
        fprintf(stderr, "swift_tar: %s: file shrank by %lld bytes; padded with zeros / 檔案縮小了 %lld 位元組；以零補齊\n",
                entry_sort_name(entry), (long long)shrank, (long long)shrank);
        ++*unreadable;
    }
    return 0;
}

/* The name an entry is ordered by. / 項目排序所依據的名稱。 */
static const char *entry_sort_name(struct archive_entry *entry) {
    const char *name = archive_entry_pathname_utf8(entry);
    if (name == NULL) name = archive_entry_pathname(entry);
    return name != NULL ? name : "";
}

/* What the sorted walk remembers about one name in a directory while that directory is being
 * listed: the paths needed to come back to it, and nothing else. A whole archive_entry is
 * about 1.6 KB (measured 2026-10-13), so a regular file or a directory is read again from
 * its path when its turn comes; only the other kinds (symlinks, devices) keep the entry the
 * listing produced, because reading those again is not the same operation under -h.
 * Windows keeps wide paths: the narrow form cannot hold every name there.
 * 排序的走訪在列出某個目錄時，對其中一個名稱所記住的東西：回頭找它所需的路徑，僅此而已。
 * 一個完整的 archive_entry 約 1.6 KB（2026-10-13 實測），所以一般檔案與目錄在輪到時才依路徑
 * 重新讀取；只有其他種類（symlink、裝置）保留列出時得到的項目，因為在 -h 之下重新讀它們並不是
 * 同一個操作。Windows 保留寬字元路徑：窄字元形式裝不下那裡的每一個名稱。 */
typedef struct {
    char *sort_name;
    int is_directory;
    struct archive_entry *entry;
#ifdef _WIN32
    wchar_t *pathname;
    wchar_t *sourcepath;
#else
    char *pathname;
#endif
} sorted_child;

static void free_child(sorted_child *child) {
    free(child->sort_name);
    free(child->pathname);
#ifdef _WIN32
    free(child->sourcepath);
#endif
    if (child->entry != NULL) archive_entry_free(child->entry);
}

static char *copy_string(const char *text) {
    size_t size = strlen(text) + 1;
    char *copy = (char *)malloc(size);
    if (copy != NULL) memcpy(copy, text, size);
    return copy;
}

#ifdef _WIN32
static wchar_t *copy_wide_string(const wchar_t *text) {
    size_t size = (wcslen(text) + 1) * sizeof(wchar_t);
    wchar_t *copy = (wchar_t *)malloc(size);
    if (copy != NULL) memcpy(copy, text, size);
    return copy;
}
#endif

/* Order members the way the tar path does: each directory's names sorted, and a directory
 * before what is inside it. Comparing whole paths as strings is not that order -- `d.x/f`
 * would land before `d/f` because '.' sorts below '/' -- so the end of a path component
 * ('/' or the end of the string) is made to sort below every other byte.
 * 依 tar 路徑的方式排列成員：每個目錄內的名稱排序，且目錄先於其內容。把整條路徑當字串比較
 * 並不是這個順序——因為 '.' 排在 '/' 之前，`d.x/f` 會跑到 `d/f` 前面——所以讓路徑元件的結尾
 * （'/' 或字串結尾）排在其他所有位元組之前。 */
static int compare_children(const void *left, const void *right) {
    const unsigned char *a = (const unsigned char *)((const sorted_child *)left)->sort_name;
    const unsigned char *b = (const unsigned char *)((const sorted_child *)right)->sort_name;
    int rank_a, rank_b;

    while (*a != '\0' && *a == *b) { ++a; ++b; }
    rank_a = *a == '\0' ? 0 : (*a == '/' ? 1 : 2);
    rank_b = *b == '\0' ? 0 : (*b == '/' ? 1 : 2);
    if (rank_a != rank_b) return rank_a < rank_b ? -1 : 1;
    return (int)*a - (int)*b;
}

/* Write one entry's header. Returns 1 when its data is to follow, 0 when the entry could
 * not be written and was reported (the run goes on, with no data for it), and -1 when the
 * run must end.
 * 寫出一個項目的標頭。回傳 1 表示接著要寫它的資料；0 表示這個項目寫不進去且已回報（執行繼續，
 * 不寫它的資料）；-1 表示整次執行必須結束。 */
static int write_entry_header(struct archive *writer,
                              struct archive_entry *entry,
                              int verbose,
                              char *error_buffer,
                              size_t error_capacity) {
    int status;

    if (verbose) fprintf(stderr, "a %s\n", entry_sort_name(entry));

    /* mtime only. The ZIP writer puts whatever times the entry carries into the UT
     * extra field, and archive_read_disk fills in atime and ctime -- both of which
     * reading the file changes -- so the same tree, archived twice, gave two different
     * ZIPs (2026-10-09: they differed from byte 59, inside the first entry's UT field).
     * The tar path never stored either. Dropping them makes ZIP output reproducible.
     * 只留 mtime。ZIP 寫出端會把項目帶有的時間都寫進 UT 擴充欄位，而 archive_read_disk
     * 會填入 atime 與 ctime——讀取檔案本身就會改變這兩者——所以同一棵樹封存兩次會得到兩個
     * 不同的 ZIP（2026-10-09：從第 59 個位元組起不同，就在第一個項目的 UT 欄位裡）。tar 路徑
     * 從來不存這兩者。拿掉之後 ZIP 輸出可以重現。 */
    archive_entry_unset_atime(entry);
    archive_entry_unset_ctime(entry);
    archive_entry_unset_birthtime(entry);

    status = archive_write_header(writer, entry);
    if (status == ARCHIVE_FATAL) {
        set_archive_error(error_buffer, error_capacity, "archive_write_header", writer);
        return -1;
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
                entry_sort_name(entry), archive_reason(writer));
        return 0;
    }
    if (status < ARCHIVE_OK) {
        /* ARCHIVE_WARN: the header was written, so keep going and copy the data,
         * but do not let the reason go unsaid.
         * ARCHIVE_WARN：標頭已寫入，故繼續複製資料，但不讓原因無聲消失。 */
        fprintf(stderr, "swift_tar: %s: %s\n",
                entry_sort_name(entry), archive_reason(writer));
    }
    return 1;
}

/* Write one entry and, for a regular file, its data, read and compressed here. Returns 0
 * when the walk should go on and -1 when the run must end.
 * 寫出一個項目；若為一般檔案，連同其資料，在這裡讀取並壓縮。回傳 0 表示走訪應繼續，-1 表示
 * 整次執行必須結束。 */
static int write_entry(struct archive *writer,
                       struct archive_entry *entry,
                       int verbose,
                       long *unreadable,
                       char *error_buffer,
                       size_t error_capacity) {
    FILE *input = NULL;
    int status;

    /* Opened before the header, so a file that cannot be opened is left out whole rather
     * than leaving a header with no data after it.
     * 在標頭之前開啟，使開不了的檔案整個略過，而不是留下一個後面沒有資料的標頭。 */
    if (archive_entry_filetype(entry) == AE_IFREG && archive_entry_size(entry) > 0) {
        input = open_entry_source(entry);
        if (input == NULL) {
            note_unreadable(unreadable, entry_sort_name(entry),
                            "cannot open, left out", "無法開啟，未收入", errno);
            return 0;
        }
    }
    status = write_entry_header(writer, entry, verbose, error_buffer, error_capacity);
    if (status <= 0) {
        if (input != NULL) fclose(input);
        return status;
    }
    return copy_file_to_archive(writer, entry, input, unreadable, error_buffer, error_capacity);
}

/* ---- compressing members on several threads -------------------------------------------
 *
 * A ZIP is one stream and its members are written in order, but each member is its own
 * deflate stream, so the compressing can be done ahead of the writing. The walk hands
 * every entry to the pipeline; a regular file's data is read and deflated by a worker
 * thread into memory, and the calling thread writes the members in the order they were
 * handed over, waiting only when the next one is not finished yet.
 *
 * The bytes do not change with the number of threads. A worker makes the same deflate
 * stream libarchive's ZIP writer would have made (same zlib, same settings), and
 * archive_write_zip_data_deflated (patch/libarchive/0003) writes it in place of
 * archive_write_data.
 *
 * What is held is bounded: at most ZIP_WINDOW_JOBS members, and at most ZIP_WINDOW_BYTES
 * of file data handed over and not yet written. A file larger than ZIP_LARGE_FILE is not
 * handed to a worker; it is compressed by the calling thread when its turn comes, as
 * without threads, so that its compressed form never has to be held.
 *
 * Only where the build says the patched libarchive is linked (SWIFT_TAR_ZIP_PARALLEL) and
 * not on Windows; elsewhere, and with one thread, every entry is written as it arrives.
 *
 * ---- 以多個執行緒壓縮成員 ----
 *
 * ZIP 是單一串流，成員依序寫出，但每個成員各是一條自己的 deflate 串流，所以壓縮可以走在寫出
 * 之前。走訪把每個項目交給管線；一般檔案的資料由工作執行緒讀取並 deflate 到記憶體，呼叫端的
 * 執行緒則依交付的順序寫出成員，只有在下一個還沒完成時才等待。
 *
 * 位元組不隨執行緒數改變。工作執行緒做出的 deflate 串流，與 libarchive 的 ZIP 寫出端本來會
 * 做出的相同（同一份 zlib、同樣的設定），再由 archive_write_zip_data_deflated
 * （patch/libarchive/0003）取代 archive_write_data 寫入。
 *
 * 留在記憶體的東西有上限：最多 ZIP_WINDOW_JOBS 個成員，以及最多 ZIP_WINDOW_BYTES 已交付而尚未
 * 寫出的檔案資料。大於 ZIP_LARGE_FILE 的檔案不交給工作執行緒；輪到它時由呼叫端的執行緒壓縮，
 * 與沒有執行緒時相同，這樣就不必把它壓縮後的樣子留在記憶體。
 *
 * 只在建置表明連結的是打過 patch 的 libarchive（SWIFT_TAR_ZIP_PARALLEL）且不是 Windows 時啟用；
 * 其他情況，以及只有一個執行緒時，每個項目到了就寫。 */
#define ZIP_DEFLATE_LEVEL 6
#define ZIP_DEFLATE_LEVEL_TEXT "6"

#if defined(SWIFT_TAR_ZIP_PARALLEL) && !defined(_WIN32)
#define ZIP_WINDOW_JOBS 256
#define ZIP_WINDOW_BYTES ((la_int64_t)256 * 1024 * 1024)
#define ZIP_LARGE_FILE ((la_int64_t)64 * 1024 * 1024)

/* Declared here as well as in the patched archive.h: a build that reverts the patch
 * after building the library compiles this file against the unpatched header.
 * 除了打過 patch 的 archive.h 之外，這裡也宣告一次：建完函式庫就還原 patch 的建置，是對著
 * 未 patch 的 header 編譯本檔的。 */
int archive_write_zip_data_deflated(struct archive *, const void *, size_t,
                                    unsigned long, la_int64_t);

typedef struct {
    struct archive_entry *entry;
    la_int64_t cost;          /* bytes counted against the window; 0 = not for a worker */
    int done;
    int failed;
    int unreadable;           /* failed because the file could not be opened: left out, not fatal */
    int error_number;         /* errno of that open */
    unsigned char *data;      /* the finished deflate stream */
    size_t length;
    unsigned long crc;
    la_int64_t bytes;         /* uncompressed bytes actually read */
    char error[512];
} zip_job;
#endif

typedef struct {
    struct archive *writer;
    int verbose;
    char *error_buffer;
    size_t error_capacity;
    long unreadable;          /* entries left out because they could not be read */
#if defined(SWIFT_TAR_ZIP_PARALLEL) && !defined(_WIN32)
    int thread_count;         /* 0 = write every entry as it arrives */
    int started;
    pthread_t *threads;
    pthread_mutex_t lock;
    pthread_cond_t work_ready;
    pthread_cond_t job_done;
    zip_job *jobs;            /* a ring; a job's place is its number modulo the size */
    size_t first;             /* number of the oldest job not yet written */
    size_t end;               /* number the next job will get */
    size_t claim;             /* number of the next job a worker will look at */
    la_int64_t in_flight;
    int base_dir;             /* what relative paths are relative to */
    int stopping;
#endif
} zip_pipeline;

#if defined(SWIFT_TAR_ZIP_PARALLEL) && !defined(_WIN32)
/* Read one file and deflate it into memory. Runs on a worker thread; touches nothing but
 * its job. The file is opened relative to base_dir, not to the working directory, which
 * libarchive's walk may be changing on the calling thread at this very moment.
 * 讀取一個檔案並 deflate 到記憶體。在工作執行緒上執行；只碰自己的 job。檔案是相對於 base_dir
 * 開啟，而不是相對於工作目錄——呼叫端執行緒上的 libarchive 走訪可能正在改變工作目錄。 */
static void compress_job(zip_job *job, int base_dir, unsigned char *input, size_t input_size) {
    const char *path = archive_entry_sourcepath(job->entry);
    z_stream stream;
    size_t capacity = 64 * 1024;
    int fd;
    int flush = Z_NO_FLUSH;
    /* What is read stops at the size the entry was listed with, which is what the window
     * counted. Read to the end of the file instead, a file growing during the run was held
     * here at whatever size it reached, and was stored where -n 1 ended with an error.
     * 讀取止於項目列出時的大小，也就是視窗所計入的量。若改讀到檔案結尾，執行期間持續變大的
     * 檔案長到多大，這裡就留多大，而且存得進去，-n 1 卻以錯誤結束。 */
    la_int64_t remaining = job->cost;

    fd = openat(base_dir, path != NULL ? path : "", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        /* Not fatal: the writer reports it and leaves the file out (pipeline_write_first).
         * 不是致命錯誤：由寫出端回報並略過這個檔案（pipeline_write_first）。 */
        job->error_number = errno;
        job->unreadable = 1;
        job->failed = 1;
        return;
    }
    memset(&stream, 0, sizeof(stream));
    job->data = (unsigned char *)malloc(capacity);
    if (job->data == NULL ||
        deflateInit2(&stream, ZIP_DEFLATE_LEVEL, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        snprintf(job->error, sizeof(job->error), "out of memory while compressing '%s'", path);
        job->failed = 1;
        close(fd);
        return;
    }
    job->crc = crc32(0L, Z_NULL, 0);
    stream.next_out = job->data;
    stream.avail_out = (uInt)capacity;

    for (;;) {
        int status;

        if (stream.avail_in == 0 && flush == Z_NO_FLUSH) {
            ssize_t count = remaining == 0 ? 0 :
                read(fd, input, remaining < (la_int64_t)input_size ? (size_t)remaining : input_size);
            if (count < 0) {
                if (errno == EINTR) continue;
                snprintf(job->error, sizeof(job->error), "failed while reading an input file");
                job->failed = 1;
                break;
            }
            if (count == 0) {
                flush = Z_FINISH;
            } else {
                job->crc = crc32(job->crc, input, (uInt)count);
                job->bytes += count;
                remaining -= count;
                stream.next_in = input;
                stream.avail_in = (uInt)count;
            }
        }
        status = deflate(&stream, flush);
        if (status == Z_STREAM_END) break;
        if (status != Z_OK && status != Z_BUF_ERROR) {
            snprintf(job->error, sizeof(job->error), "deflate failed on '%s'", path);
            job->failed = 1;
            break;
        }
        if (stream.avail_out == 0) {
            size_t used = capacity;
            unsigned char *grown = (unsigned char *)realloc(job->data, capacity * 2);
            if (grown == NULL) {
                snprintf(job->error, sizeof(job->error),
                         "out of memory while compressing '%s'", path);
                job->failed = 1;
                break;
            }
            job->data = grown;
            capacity *= 2;
            stream.next_out = job->data + used;
            stream.avail_out = (uInt)(capacity - used);
        }
    }
    job->length = capacity - stream.avail_out;
    deflateEnd(&stream);
    close(fd);
}

static void *pipeline_worker(void *context) {
    zip_pipeline *pipeline = (zip_pipeline *)context;
    size_t input_size = 256 * 1024;
    unsigned char *input = (unsigned char *)malloc(input_size);

    pthread_mutex_lock(&pipeline->lock);
    for (;;) {
        zip_job *job;

        /* Find the next job that has data. Jobs without any are finished the moment they
         * are handed over and nobody wakes a worker for them, so the writer may already
         * have written them and reused their places in the ring: never look at a number
         * below `first`. (Until this was added, a file that followed more than a ring's
         * worth of empty members was compressed once for each time its place came round.)
         * 找出下一個帶有資料的 job。不帶資料的 job 一交付就算完成，也不會為它喚醒任何工作
         * 執行緒，所以寫出端可能早已把它們寫完、並重用了它們在環裡的位置：絕不去看編號小於
         * `first` 的 job。（加上這一段之前，跟在超過一整圈空成員之後的檔案，它的位置每轉到
         * 一次就被壓縮一次。） */
        while (!pipeline->stopping) {
            if (pipeline->claim < pipeline->first) pipeline->claim = pipeline->first;
            while (pipeline->claim < pipeline->end &&
                   pipeline->jobs[pipeline->claim % ZIP_WINDOW_JOBS].cost == 0) {
                pipeline->claim++;
            }
            if (pipeline->claim < pipeline->end) break;
            pthread_cond_wait(&pipeline->work_ready, &pipeline->lock);
        }
        if (pipeline->stopping) break;
        job = &pipeline->jobs[pipeline->claim++ % ZIP_WINDOW_JOBS];
        pthread_mutex_unlock(&pipeline->lock);

        if (input == NULL) {
            snprintf(job->error, sizeof(job->error), "out of memory while compressing");
            job->failed = 1;
        } else {
            compress_job(job, pipeline->base_dir, input, input_size);
        }

        pthread_mutex_lock(&pipeline->lock);
        job->done = 1;
        pthread_cond_broadcast(&pipeline->job_done);
    }
    pthread_mutex_unlock(&pipeline->lock);
    free(input);
    return NULL;
}

/* Write the oldest job, waiting for its worker if need be, and let go of it.
 * 寫出最舊的 job，必要時等它的工作執行緒完成，然後放掉它。 */
static int pipeline_write_first(zip_pipeline *pipeline) {
    zip_job *job = &pipeline->jobs[pipeline->first % ZIP_WINDOW_JOBS];
    int result = 0;

    pthread_mutex_lock(&pipeline->lock);
    while (!job->done) pthread_cond_wait(&pipeline->job_done, &pipeline->lock);
    pthread_mutex_unlock(&pipeline->lock);

    if (job->cost == 0) {
        result = write_entry(pipeline->writer, job->entry, pipeline->verbose,
                             &pipeline->unreadable,
                             pipeline->error_buffer, pipeline->error_capacity);
    } else if (job->unreadable) {
        /* Nothing was written for it yet, so leaving it out leaves no trace in the archive.
         * 它還沒有任何東西寫出，所以略過它不會在封存裡留下痕跡。 */
        note_unreadable(&pipeline->unreadable, entry_sort_name(job->entry),
                        "cannot open, left out", "無法開啟，未收入", job->error_number);
    } else if (job->failed) {
        set_error(pipeline->error_buffer, pipeline->error_capacity, job->error);
        result = -1;
    } else {
        int status;
        la_int64_t listed = archive_entry_size(job->entry);

        /* The size the header states is the number of bytes the worker read, so a file
         * that changed size after it was listed is still stored as what was read.
         * 標頭所記的大小是工作執行緒實際讀到的位元組數，所以列出之後大小變了的檔案，存下的仍是
         * 實際讀到的內容。 */
        archive_entry_set_size(job->entry, job->bytes);
        /* A file that shrank is stored short and said so, counted toward the exit status;
         * until 2026-10-31 nothing was said (review, low).
         * 縮小的檔案存成較短的內容並說出來，計入結束碼；2026-10-31 之前一聲不響（審查低風險項）。 */
        if (job->bytes < listed) {
            fprintf(stderr, "swift_tar: %s: file shrank by %lld bytes while being read; stored what was read / 讀取中檔案縮小了 %lld 位元組；存下實際讀到的內容\n",
                    entry_sort_name(job->entry), (long long)(listed - job->bytes),
                    (long long)(listed - job->bytes));
            ++pipeline->unreadable;
        }
        status = write_entry_header(pipeline->writer, job->entry, pipeline->verbose,
                                    pipeline->error_buffer, pipeline->error_capacity);
        if (status < 0) {
            result = -1;
        } else if (status > 0 && job->bytes > 0 &&
                   archive_write_zip_data_deflated(pipeline->writer, job->data, job->length,
                                                   job->crc, job->bytes) != ARCHIVE_OK) {
            set_archive_error(pipeline->error_buffer, pipeline->error_capacity,
                              "archive_write_zip_data_deflated", pipeline->writer);
            result = -1;
        }
    }

    free(job->data);
    archive_entry_free(job->entry);
    pthread_mutex_lock(&pipeline->lock);
    pipeline->in_flight -= job->cost;
    pipeline->first++;
    pthread_mutex_unlock(&pipeline->lock);
    return result;
}
#endif

/* Start the pipeline. `threads` is how many may compress at once; 1 or less, or a build
 * without the threaded path, writes every entry as it arrives. Call after any chdir: the
 * directory current now is the one relative paths are opened against.
 * 啟動管線。`threads` 是可同時壓縮的數量；1 以下，或建置不含執行緒路徑時，每個項目到了就寫。
 * 要在 chdir 之後呼叫：此刻的工作目錄，就是之後開啟相對路徑時所依據的目錄。 */
static int pipeline_open(zip_pipeline *pipeline, struct archive *writer, int verbose,
                         int threads, char *error_buffer, size_t error_capacity) {
    memset(pipeline, 0, sizeof(*pipeline));
    pipeline->writer = writer;
    pipeline->verbose = verbose;
    pipeline->error_buffer = error_buffer;
    pipeline->error_capacity = error_capacity;
#if defined(SWIFT_TAR_ZIP_PARALLEL) && !defined(_WIN32)
    pipeline->base_dir = -1;
    if (threads <= 1) return 0;
    pipeline->base_dir = open(".", O_RDONLY | O_CLOEXEC);
    pipeline->jobs = (zip_job *)calloc(ZIP_WINDOW_JOBS, sizeof(zip_job));
    pipeline->threads = (pthread_t *)calloc((size_t)threads, sizeof(pthread_t));
    if (pipeline->base_dir < 0 || pipeline->jobs == NULL || pipeline->threads == NULL) {
        set_error(error_buffer, error_capacity, "cannot start the compression threads");
        return -1;
    }
    pthread_mutex_init(&pipeline->lock, NULL);
    pthread_cond_init(&pipeline->work_ready, NULL);
    pthread_cond_init(&pipeline->job_done, NULL);
    pipeline->thread_count = threads;
    while (pipeline->started < threads) {
        if (pthread_create(&pipeline->threads[pipeline->started], NULL,
                           pipeline_worker, pipeline) != 0) {
            set_error(error_buffer, error_capacity, "cannot start the compression threads");
            return -1;
        }
        pipeline->started++;
    }
#else
    (void)threads;
#endif
    return 0;
}

/* Hand one entry over; the pipeline owns it from here, whatever is returned. Returns 0
 * when the walk should go on and -1 when the run must end.
 * 交付一個項目；不論回傳什麼，此後它歸管線所有。回傳 0 表示走訪應繼續，-1 表示整次執行必須
 * 結束。 */
static int pipeline_add(zip_pipeline *pipeline, struct archive_entry *entry) {
#if defined(SWIFT_TAR_ZIP_PARALLEL) && !defined(_WIN32)
    if (pipeline->thread_count > 0) {
        zip_job *job;
        la_int64_t cost = 0;

        if (archive_entry_filetype(entry) == AE_IFREG && archive_entry_size(entry) > 0 &&
            archive_entry_size(entry) <= ZIP_LARGE_FILE) {
            cost = archive_entry_size(entry);
        }
        while (pipeline->end - pipeline->first == ZIP_WINDOW_JOBS ||
               (pipeline->end != pipeline->first &&
                pipeline->in_flight + cost > ZIP_WINDOW_BYTES)) {
            if (pipeline_write_first(pipeline) != 0) {
                archive_entry_free(entry);
                return -1;
            }
        }
        pthread_mutex_lock(&pipeline->lock);
        job = &pipeline->jobs[pipeline->end % ZIP_WINDOW_JOBS];
        memset(job, 0, sizeof(*job));
        job->entry = entry;
        job->cost = cost;
        job->done = cost == 0;
        pipeline->in_flight += cost;
        pipeline->end++;
        if (cost > 0) pthread_cond_signal(&pipeline->work_ready);
        pthread_mutex_unlock(&pipeline->lock);
        return 0;
    }
#endif
    {
        int result = write_entry(pipeline->writer, entry, pipeline->verbose,
                                 &pipeline->unreadable,
                                 pipeline->error_buffer, pipeline->error_capacity);
        archive_entry_free(entry);
        return result;
    }
}

/* Write everything handed over so far. / 把目前為止交付的全部寫出。 */
static int pipeline_drain(zip_pipeline *pipeline) {
#if defined(SWIFT_TAR_ZIP_PARALLEL) && !defined(_WIN32)
    while (pipeline->end != pipeline->first) {
        if (pipeline_write_first(pipeline) != 0) return -1;
    }
#else
    (void)pipeline;
#endif
    return 0;
}

/* Stop the workers and free what was handed over and never written (after an error).
 * 停止工作執行緒，並釋放已交付而未寫出的東西（發生錯誤之後）。 */
static void pipeline_close(zip_pipeline *pipeline) {
#if defined(SWIFT_TAR_ZIP_PARALLEL) && !defined(_WIN32)
    int index;

    if (pipeline->thread_count > 0) {
        pthread_mutex_lock(&pipeline->lock);
        pipeline->stopping = 1;
        pthread_cond_broadcast(&pipeline->work_ready);
        pthread_mutex_unlock(&pipeline->lock);
    }
    for (index = 0; index < pipeline->started; ++index) pthread_join(pipeline->threads[index], NULL);
    for (; pipeline->jobs != NULL && pipeline->first != pipeline->end; pipeline->first++) {
        zip_job *job = &pipeline->jobs[pipeline->first % ZIP_WINDOW_JOBS];
        free(job->data);
        archive_entry_free(job->entry);
    }
    if (pipeline->thread_count > 0) {
        pthread_cond_destroy(&pipeline->job_done);
        pthread_cond_destroy(&pipeline->work_ready);
        pthread_mutex_destroy(&pipeline->lock);
    }
    free(pipeline->threads);
    free(pipeline->jobs);
    if (pipeline->base_dir >= 0) close(pipeline->base_dir);
#else
    (void)pipeline;
#endif
}

/* Whether an entry the disk reader handed over is left out of the archive. Returns 1 when
 * it is (and has been reported where that is called for), 0 when it should be written.
 * 判斷 disk reader 交出的項目是否不進封存。回傳 1 表示不進（該回報的已回報），0 表示應寫出。 */
static int skip_entry(struct archive_entry *entry,
                      file_id archive_id,
                      int verbose,
                      int (*is_excluded)(const char *path, int is_directory)) {
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
                    entry_sort_name(entry));
            return 1;
        }
    }

    /* --exclude, asked of the tar path's own matcher before descend, so an excluded
     * directory is never walked -- the same order TarWriter.add uses. Until 2026-09-27
     * this backend never consulted --exclude at all.
     * --exclude，於 descend 之前詢問 tar 路徑自己的比對器，故被排除的目錄不會被走進去
     * ——與 TarWriter.add 的順序相同。2026-09-27 之前本後端完全不看 --exclude。 */
    if (is_excluded != NULL) {
        const char *name = archive_entry_pathname_utf8(entry);
        if (name == NULL) name = archive_entry_pathname(entry);
        if (name != NULL && is_excluded(name, archive_entry_filetype(entry) == AE_IFDIR)) {
            if (verbose) fprintf(stderr, "skipping %s / 略過 %s\n", name, name);
            return 1;
        }
    }
    return 0;
}

/* Everything one argument's sorted walk carries from directory to directory.
 * 一個引數的排序走訪，從一個目錄帶到下一個目錄的所有東西。 */
typedef struct {
    zip_pipeline *pipeline;
    struct archive *disk;       /* lists one directory at a time / 一次列出一個目錄 */
    struct archive *stat_disk;  /* reads one file's metadata / 讀取單一檔案的中繼資料 */
    file_id archive_id;
    int verbose;
    int follow_symlinks;
    int (*is_excluded)(const char *path, int is_directory);
    char *error_buffer;
    size_t error_capacity;
} sorted_walk;

/* What to do with what archive_read_next_header2 returned: 1 use the entry, 0 skip it, -1 end
 * the run. Only ARCHIVE_FATAL ends it. ARCHIVE_FAILED and ARCHIVE_RETRY mean this one entry
 * cannot be had -- "Couldn't visit directory" for a directory that cannot be opened, whose
 * own entry was already handed over -- and libarchive carries on with the rest on the next
 * call: reported, counted, skipped. ARCHIVE_WARN means the entry is usable: said, and used.
 * The same rule as the read side (swift_tar_zip_read) and write_entry_header. Until
 * 2026-10-22 anything below ARCHIVE_OK ended the run here.
 * 如何處理 archive_read_next_header2 的回傳：1 使用該項目，0 略過，-1 結束整次執行。只有
 * ARCHIVE_FATAL 會結束。ARCHIVE_FAILED 與 ARCHIVE_RETRY 代表只有這一項拿不到——開不了的目錄
 * 回報的 "Couldn't visit directory"，其自身的項目已經交付——而 libarchive 下一次呼叫會繼續處理
 * 其餘的：回報、計數、略過。ARCHIVE_WARN 代表項目可用：說出原因，照常使用。與讀取端
 * （swift_tar_zip_read）及 write_entry_header 同一條規則。2026-10-22 之前，凡低於 ARCHIVE_OK
 * 都會在這裡結束整次執行。 */
static int next_header_action(int status, struct archive *disk, zip_pipeline *pipeline,
                              char *error_buffer, size_t error_capacity) {
    if (status == ARCHIVE_OK) return 1;
    if (status == ARCHIVE_WARN) {
        fprintf(stderr, "swift_tar: %s\n", archive_reason(disk));
        return 1;
    }
    if (status == ARCHIVE_FAILED || status == ARCHIVE_RETRY) {
        note_unreadable(&pipeline->unreadable, archive_reason(disk),
                        "left out", "未收入", archive_errno(disk));
        return 0;
    }
    set_archive_error(error_buffer, error_capacity, "archive_read_next_header", disk);
    return -1;
}

/* The directories above the one being listed, innermost first, by identity. Only -h reads
 * it: a link that leads back to one of these is stored as a link instead of being followed
 * round again. libarchive's own walk does this from its stack, and listing one directory
 * at a time leaves that stack one deep, so the chain is carried here. The directory
 * being listed is itself not in the chain, as in libarchive: a link to it is followed once.
 * 正在列出的目錄之上的各層目錄，由內而外，以身分表示。只有 -h 會用到：指回其中任何一層的連結
 * 存成連結本身，不再繞進去一次。libarchive 自己的走訪是靠它的堆疊做這件事，而一次只列一個目錄
 * 使那個堆疊只有一層深，所以這條鏈改由這裡帶著。正在列出的目錄本身不在鏈中，與 libarchive 相同：
 * 指向它的連結會被跟進去一次。 */
typedef struct ancestor {
    la_int64_t dev;
    la_int64_t ino;
    const struct ancestor *parent;
} ancestor;

static int is_ancestor(const ancestor *chain, la_int64_t dev, la_int64_t ino) {
    for (; chain != NULL; chain = chain->parent) {
        if (chain->dev == dev && chain->ino == ino) return 1;
    }
    return 0;
}

/* Read one name's entry from its path. `physical` reads a link as the link whatever -h
 * says. Returns NULL with the error set.
 * 依路徑讀出一個名稱的項目。`physical` 表示不論 -h 為何，都把連結當成連結本身來讀。失敗時回傳
 * NULL 並設好錯誤。 */
static struct archive_entry *read_child_entry(sorted_walk *walk,
                                              const sorted_child *child,
                                              int physical) {
    struct archive_entry *entry = archive_entry_new();
    int status;

    if (entry == NULL) {
        set_error(walk->error_buffer, walk->error_capacity, "archive_entry_new failed");
        return NULL;
    }
#ifdef _WIN32
    archive_entry_copy_pathname_w(entry, child->pathname);
    if (child->sourcepath != NULL) archive_entry_copy_sourcepath_w(entry, child->sourcepath);
#else
    archive_entry_copy_pathname(entry, child->pathname);
    archive_entry_copy_sourcepath(entry, child->pathname);
#endif
    if (physical && walk->follow_symlinks) archive_read_disk_set_symlink_physical(walk->stat_disk);
    status = archive_read_disk_entry_from_file(walk->stat_disk, entry, -1, NULL);
    if (physical && walk->follow_symlinks) archive_read_disk_set_symlink_logical(walk->stat_disk);
    if (status < ARCHIVE_OK) {
        set_archive_error(walk->error_buffer, walk->error_capacity,
                          "archive_read_disk_entry_from_file", walk->stat_disk);
        archive_entry_free(entry);
        return NULL;
    }
    return entry;
}

/* The sorted order (the default): write `path` (or, below the argument itself, the directory `from`) and
 * everything under it, each directory's names in sorted order.
 *
 * One directory is listed at a time. Its own entry is written first; then its names are
 * read, the reader is closed, the names are sorted, and each is written in turn -- a
 * directory by calling this again. So what is held is the names of the directories on the
 * way down, not the tree: memory follows the largest directory, not the number of files.
 * Until 2026-10-13 the whole tree's entries were collected and sorted at once, which took
 * 1.79 GB for 1,001,377 entries against 0.18 GB unsorted.
 *
 * The reader is closed before going down so that only one directory is ever open: left
 * open, a tree a few hundred levels deep would run out of file descriptors.
 *
 * Reading each file again at its turn is also what keeps its header honest: the size is
 * taken just before the data is copied, not before every earlier member was compressed.
 *
 * 排序的順序（預設）：寫出 `path`（在引數本身之下則是目錄 `from`）與其下的一切，每個目錄內的名稱
 * 依排序後的順序。
 *
 * 一次只列出一個目錄。先寫出它自己的項目；再讀出它的名稱、關閉 reader、排序，然後逐一寫出
 * ——遇到目錄就再呼叫本函式。所以留在記憶體裡的是一路往下各層目錄的名稱，而不是整棵樹：記憶體
 * 跟著最大的單一目錄走，不跟著檔案總數走。2026-10-13 之前是把整棵樹的項目一次收集再排序，
 * 1,001,377 個項目用掉 1.79 GB，不排序是 0.18 GB。
 *
 * 往下走之前先關閉 reader，使任何時候都只有一個目錄是開著的：若留著不關，幾百層深的樹會把
 * file descriptor 用完。
 *
 * 輪到時才重新讀取每個檔案，同時也讓它的標頭不會說錯：大小是在複製資料之前才取得的，而不是在
 * 壓縮所有先前成員之前。 */
static int add_sorted_tree(sorted_walk *walk, const char *path, const sorted_child *from,
                           const ancestor *above) {
    ancestor self = {0, 0, above};
    struct archive_entry *entry = NULL;
    sorted_child *children = NULL;
    size_t child_count = 0;
    size_t child_capacity = 0;
    size_t index;
    int at_top = 1;
    int result = -1;
    int status;

    if (from == NULL) status = archive_read_disk_open(walk->disk, path);
#ifdef _WIN32
    else status = archive_read_disk_open_w(walk->disk, from->pathname);
#else
    else status = archive_read_disk_open(walk->disk, from->pathname);
#endif
    if (status != ARCHIVE_OK) {
        set_archive_error(walk->error_buffer, walk->error_capacity,
                          "archive_read_disk_open", walk->disk);
        return -1;
    }

    for (;;) {
        sorted_child *child;

        entry = archive_entry_new();
        if (entry == NULL) {
            set_error(walk->error_buffer, walk->error_capacity, "archive_entry_new failed");
            goto close_reader;
        }

        status = archive_read_next_header2(walk->disk, entry);
        if (status == ARCHIVE_EOF) {
            archive_entry_free(entry);
            entry = NULL;
            break;
        }
        status = next_header_action(status, walk->disk, walk->pipeline,
                                    walk->error_buffer, walk->error_capacity);
        if (status < 0) goto close_reader;
        if (status == 0) {
            archive_entry_free(entry);
            entry = NULL;
            continue;
        }

        /* A directory reached from its parent was already asked about there.
         * 從上層目錄走進來的目錄，在上層已經問過了。 */
        if ((!at_top || from == NULL) &&
            skip_entry(entry, walk->archive_id, walk->verbose, walk->is_excluded)) {
            at_top = 0;
            archive_entry_free(entry);
            entry = NULL;
            continue;
        }

        if (at_top) {
            /* The thing this call was opened on. Go one level in, and no further: the
             * names read after this are its own, and none of them is descended into here.
             * 本次呼叫所開啟的對象。只往內走一層：此後讀到的都是它自己的名稱，這裡不再走進
             * 其中任何一個。 */
            at_top = 0;
            self.dev = (la_int64_t)archive_entry_dev(entry);
            self.ino = archive_entry_ino64(entry);
            if (archive_read_disk_can_descend(walk->disk)) archive_read_disk_descend(walk->disk);
            status = pipeline_add(walk->pipeline, entry);
            entry = NULL;
            if (status != 0) goto close_reader;
            continue;
        }

        if (child_count == child_capacity) {
            size_t capacity = child_capacity == 0 ? 64 : child_capacity * 2;
            sorted_child *grown = (sorted_child *)realloc(children, capacity * sizeof(*children));
            if (grown == NULL) {
                set_error(walk->error_buffer, walk->error_capacity,
                          "out of memory while listing files");
                goto close_reader;
            }
            children = grown;
            child_capacity = capacity;
        }
        child = &children[child_count];
        memset(child, 0, sizeof(*child));
        child->is_directory = archive_read_disk_can_descend(walk->disk);
        child->sort_name = copy_string(entry_sort_name(entry));
#ifdef _WIN32
        if (archive_entry_pathname_w(entry) != NULL) {
            child->pathname = copy_wide_string(archive_entry_pathname_w(entry));
        }
        if (archive_entry_sourcepath_w(entry) != NULL) {
            child->sourcepath = copy_wide_string(archive_entry_sourcepath_w(entry));
        }
#else
        if (archive_entry_pathname(entry) != NULL) {
            child->pathname = copy_string(archive_entry_pathname(entry));
        }
#endif
        ++child_count;
        if (child->sort_name == NULL || child->pathname == NULL) {
            set_error(walk->error_buffer, walk->error_capacity,
                      "out of memory while listing files");
            goto close_reader;
        }
        if (walk->follow_symlinks && child->is_directory &&
            is_ancestor(above, (la_int64_t)archive_entry_dev(entry), archive_entry_ino64(entry))) {
            /* It leads back to a directory this walk is already inside. Take it as the
             * link it is, and go in only if it turns out not to be a link at all.
             * 它指回這次走訪已經身在其中的目錄。把它當成連結本身；只有在它其實不是連結時才
             * 走進去。 */
            archive_entry_free(entry);
            entry = read_child_entry(walk, child, 1);
            if (entry == NULL) goto close_reader;
            child->is_directory = archive_entry_filetype(entry) == AE_IFDIR;
        }
        if (!child->is_directory && archive_entry_filetype(entry) != AE_IFREG) {
            child->entry = entry;
        } else {
            archive_entry_free(entry);
        }
        entry = NULL;
    }
    archive_read_close(walk->disk);

    if (child_count > 1) qsort(children, child_count, sizeof(*children), compare_children);

    for (index = 0; index < child_count; ++index) {
        sorted_child *child = &children[index];

        if (child->is_directory) {
            if (add_sorted_tree(walk, NULL, child, &self) != 0) goto cleanup;
            continue;
        }

        entry = child->entry;
        child->entry = NULL;
        if (entry == NULL) {
            entry = read_child_entry(walk, child, 0);
            if (entry == NULL) goto cleanup;
        }

        status = pipeline_add(walk->pipeline, entry);
        entry = NULL;
        if (status != 0) goto cleanup;
    }
    result = 0;
    goto cleanup;

close_reader:
    archive_read_close(walk->disk);

cleanup:
    if (entry != NULL) archive_entry_free(entry);
    for (index = 0; index < child_count; ++index) free_child(&children[index]);
    free(children);
    return result;
}

static int add_path(zip_pipeline *pipeline,
                    const char *path,
                    file_id archive_id,
                    int verbose,
                    int follow_symlinks,
                    int (*is_excluded)(const char *path, int is_directory),
                    int sort_members,
                    char *error_buffer,
                    size_t error_capacity) {
    struct archive *disk = archive_read_disk_new();
    struct archive *stat_disk = NULL;
    struct archive_entry *entry = NULL;
    int result = -1;
    int status;

    if (disk == NULL) {
        set_error(error_buffer, error_capacity, "archive_read_disk_new failed");
        return -1;
    }
    /* -h/--dereference. This used to be physical unconditionally, so `-c --zip -h` stored
     * links as links while the tar path stored what they point to (2026-09-27 review).
     * -h/--dereference。原本一律 physical，於是 `-c --zip -h` 存的是連結本身，而 tar 路徑
     * 存的是它所指向的內容（2026-09-27 審查）。 */
    if (follow_symlinks) archive_read_disk_set_symlink_logical(disk);
    else archive_read_disk_set_symlink_physical(disk);
    /* No disk-read behaviour flags, deliberately. archive_read_disk_new() turns on
     * ARCHIVE_READDISK_MAC_COPYFILE by default, and with it every directory walked had
     * its mtime changed to "now" -- creating a ZIP modified the tree it was reading.
     * Bisected 2026-09-27 with a probe that only walks, against this vendored libarchive:
     * every flag combination containing MAC_COPYFILE changes it, none without does. The
     * flag gathers macOS metadata for AppleDouble members, and this ZIP writer emits none
     * (no `._` or `__MACOSX` entries were ever in its output), so clearing it removes a
     * side effect and changes nothing written. The tar path never read that metadata.
     * 刻意不設任何讀取行為旗標。archive_read_disk_new() 預設會開啟
     * ARCHIVE_READDISK_MAC_COPYFILE，而它使每個被走訪的目錄 mtime 變成「現在」——建立 ZIP
     * 會修改它正在讀取的樹。2026-09-27 以只走訪的探針對這份內附 libarchive 二分：凡含
     * MAC_COPYFILE 的組合都會改動，不含的都不會。該旗標是為 AppleDouble 成員收集 macOS
     * 中繼資料，而本 ZIP 寫出端從不產生這類成員（輸出中從未有 `._` 或 `__MACOSX`），所以
     * 清掉它只移除副作用，不改變任何寫出的內容。tar 路徑本來就不讀這些中繼資料。 */
    archive_read_disk_set_behavior(disk, 0);
    archive_read_disk_set_standard_lookup(disk);

    /* The sorted order lists and writes one directory at a time (add_sorted_tree). It needs a
     * second handle, never opened on a tree, for reading one file's metadata from its path:
     * a handle that has walked a tree no longer does that. Same symlink rule as the walk;
     * nothing but stat.
     * 排序的順序一次列出並寫出一個目錄（add_sorted_tree）。它需要第二個 handle，不對任何樹
     * 開啟，用來依路徑讀取單一檔案的中繼資料：走訪過樹的 handle 不再做這件事。symlink 規則與
     * 走訪相同；只做 stat，不讀其他東西。 */
    if (sort_members) {
        sorted_walk walk;

        stat_disk = archive_read_disk_new();
        if (stat_disk == NULL) {
            set_error(error_buffer, error_capacity, "archive_read_disk_new failed");
            goto cleanup;
        }
        if (follow_symlinks) archive_read_disk_set_symlink_logical(stat_disk);
        else archive_read_disk_set_symlink_physical(stat_disk);
        archive_read_disk_set_behavior(stat_disk,
            ARCHIVE_READDISK_NO_XATTR | ARCHIVE_READDISK_NO_ACL |
            ARCHIVE_READDISK_NO_FFLAGS | ARCHIVE_READDISK_NO_SPARSE);
        archive_read_disk_set_standard_lookup(stat_disk);
        /* Here `disk` lists names: apart from the entry for the thing it was opened on, every
         * entry it makes is thrown away and read again through stat_disk, with these same
         * flags. Without them it opened each file for its flags and sparse map on the way.
         * 在這裡 `disk` 用來列出名稱：除了它被開啟的那個對象本身之外，它做出的每個項目都被丟掉，
         * 再經由 stat_disk 以同樣這組旗標重讀。少了這些旗標，它會順路開啟每個檔案去讀 flags 與
         * sparse map。 */
        archive_read_disk_set_behavior(disk,
            ARCHIVE_READDISK_NO_XATTR | ARCHIVE_READDISK_NO_ACL |
            ARCHIVE_READDISK_NO_FFLAGS | ARCHIVE_READDISK_NO_SPARSE);

        walk.pipeline = pipeline;
        walk.disk = disk;
        walk.stat_disk = stat_disk;
        walk.archive_id = archive_id;
        walk.verbose = verbose;
        walk.follow_symlinks = follow_symlinks;
        walk.is_excluded = is_excluded;
        walk.error_buffer = error_buffer;
        walk.error_capacity = error_capacity;
        result = add_sorted_tree(&walk, path, NULL, NULL);
        goto cleanup;
    }

    status = archive_read_disk_open(disk, path);
    if (status != ARCHIVE_OK) {
        set_archive_error(error_buffer, error_capacity, "archive_read_disk_open", disk);
        goto cleanup;
    }

    /* --zip-unsorted: write each entry as the walk hands it over. Nothing is held, so memory
     * does not grow with the tree, and the order is the filesystem's -- which differs
     * between filesystems, so one tree gave different archives on APFS and on tmpfs
     * (2026-10-13).
     * --zip-unsorted：走訪交出一個項目就寫一個。不保留任何東西，記憶體不隨樹的大小成長；順序則是
     * 檔案系統的——它因檔案系統而異，所以同一棵樹在 APFS 與 tmpfs 上得到不同的封存
     * （2026-10-13）。 */
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
            break;
        }
        status = next_header_action(status, disk, pipeline, error_buffer, error_capacity);
        if (status < 0) goto cleanup;
        if (status == 0) {
            archive_entry_free(entry);
            entry = NULL;
            continue;
        }

        if (skip_entry(entry, archive_id, verbose, is_excluded)) {
            archive_entry_free(entry);
            entry = NULL;
            continue;
        }

        if (archive_read_disk_can_descend(disk)) archive_read_disk_descend(disk);

        status = pipeline_add(pipeline, entry);
        entry = NULL;
        if (status != 0) goto cleanup;
    }
    result = 0;

cleanup:
    if (entry != NULL) archive_entry_free(entry);
    if (stat_disk != NULL) archive_read_free(stat_disk);
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
                         int follow_symlinks,
                         int (*is_excluded)(const char *path, int is_directory),
                         int sort_members,
                         int threads,
                         char *error_buffer,
                         size_t error_capacity) {
    adopt_environment_charset();
    struct archive *writer = NULL;
    char *original_dir = NULL;
    file_id archive_id = {0};
    int result = -1;
    int status;
    size_t index;
    zip_pipeline pipeline;
    int pipeline_opened = 0;

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
        archive_write_set_format_option(writer, "zip", "compression-level",
                                        ZIP_DEFLATE_LEVEL_TEXT) != ARCHIVE_OK) {
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
                archive_reason(writer));
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
                char text[256];
                snprintf(error_buffer, error_capacity, "cannot chdir to '%s': %s",
                         change_dir, error_text(errno, text, sizeof(text)));
            }
            goto cleanup;
        }
    }

    pipeline_opened = 1;
    if (pipeline_open(&pipeline, writer, verbose, threads, error_buffer, error_capacity) != 0) {
        goto cleanup;
    }

    for (index = 0; index < path_count; ++index) {
        if (add_path(&pipeline, paths[index], archive_id, verbose, follow_symlinks, is_excluded,
                     sort_members,
                     error_buffer, error_capacity) != 0) {
            goto cleanup;
        }
    }
    if (pipeline_drain(&pipeline) != 0) goto cleanup;
    /* Everything readable is written; the ZIP is finished in cleanup either way (its central
     * directory is written by archive_write_free), so a run that left entries out still
     * leaves a complete archive and exits 1, as the tar path does.
     * 讀得到的都已寫出；ZIP 不論如何都在 cleanup 完成收尾（中央目錄由 archive_write_free
     * 寫出），所以略過了項目的執行仍會留下完整的封存並以 1 結束，與 tar 路徑相同。 */
    if (pipeline.unreadable > 0) {
        if (error_buffer != NULL && error_capacity > 0) {
            snprintf(error_buffer, error_capacity,
                     "%ld unreadable item(s) left out; the archive holds the rest / "
                     "有 %ld 項讀不到而未收入；封存含其餘內容",
                     pipeline.unreadable, pipeline.unreadable);
        }
        goto cleanup;
    }
    result = 0;

cleanup:
    if (pipeline_opened) pipeline_close(&pipeline);
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
                char text[256];
                snprintf(error_buffer, error_capacity, "write stdout: %s",
                         error_text(errno, text, sizeof(text)));
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

#ifdef _WIN32
/* Windows only: is some ancestor of `path` an existing non-directory? If so, copy it into
 * `out` and return 1.
 *
 * On POSIX libarchive refuses `a/b` when `a` is a file: check_symlinks lstat()s each
 * component, gets ENOTDIR, and reports "Could not stat a/b". On Windows the same walk
 * gets ERROR_PATH_NOT_FOUND, which archive_windows.c maps to ENOENT -- read as "the
 * parent does not exist yet" -- so it proceeds to create_dir(), which unlinks the file to
 * make room. Measured 2026-10-07: a ZIP holding `a` (file), `a/b` and `c` extracted on
 * Windows to a directory `a` holding `b`, the file's content gone, exit 0, nothing on
 * stderr. This restores the POSIX outcome, including for a file that was on disk before
 * the run (decided 2026-10-07: the ZIP path matches the ZIP path on other platforms,
 * where refusing loses nothing and replacing does).
 *
 * 僅 Windows：`path` 的某個上層是否為既有的非目錄？是則複製到 `out` 並回傳 1。
 * POSIX 上 libarchive 拒絕 `a` 為檔案時的 `a/b`：check_symlinks 逐層 lstat()，得到
 * ENOTDIR，回報「Could not stat a/b」。Windows 上同一次走訪得到 ERROR_PATH_NOT_FOUND，
 * 被 archive_windows.c 對應成 ENOENT——被當成「上層還不存在」——於是進到 create_dir()，
 * 把檔案刪掉騰出位置。2026-10-07 實測：含 `a`（檔案）、`a/b`、`c` 的 ZIP 在 Windows 解出
 * 後 `a` 成了目錄、內含 `b`，檔案內容消失，以 0 結束且 stderr 無訊息。這裡恢復 POSIX 的
 * 結果，解出前就在磁碟上的檔案亦同（2026-10-07 決定：ZIP 路徑與其他平台的 ZIP 路徑一致——
 * 拒絕不會遺失資料，取代會）。
 *
 * Returns 2 instead when the ancestor is a name-surrogate reparse point: a symlink, a junction
 * or an LX symlink (tag bit 0x20000000, IsReparseTagNameSurrogate). libarchive's
 * SECURE_SYMLINKS refuses a symlink there but sees a junction as a directory, so a junction
 * `j` already under -C, pointing outside, let `j/evil.txt` be written outside with exit 0
 * (2026-10-24 review). Same rule as winIsNameSurrogate in swift_tar.swift. Folded into this
 * walk so each ancestor is still asked once.
 * 上層若為 name-surrogate reparse point——symlink、junction 或 LX symlink（tag 位元
 * 0x20000000，IsReparseTagNameSurrogate）——則改回傳 2。libarchive 的 SECURE_SYMLINKS 會在此
 * 拒絕 symlink，卻把 junction 當成目錄，於是 -C 之下既有、指向外部的 junction `j` 讓
 * `j/evil.txt` 寫到外部並以 0 結束（2026-10-24 審查）。規則同 swift_tar.swift 的
 * winIsNameSurrogate。併入這次走訪，使每個上層仍只被詢問一次。
 *
 * Returns 3 when the walk cannot be made (no working directory, no memory): the caller refuses
 * the entry, since "not checked" must never read as "not blocked". On 1 or 2 `*blocker` is set
 * to a malloc'd copy of the blocking ancestor as the archive names it, for the caller to report
 * and free; otherwise it is NULL.
 * 走訪無法進行時（取不到工作目錄、記憶體不足）回傳 3：呼叫端拒絕該項目，因為「沒檢查」絕不能
 * 讀成「沒擋住」。回傳 1 或 2 時 `*blocker` 指向一份 malloc 出來、以封存中寫法表示的阻擋上層，
 * 由呼叫端回報並釋放；其他情況為 NULL。
 *
 * CORRECTED 2026-10-30 (review finding A): this took a fixed 1040-character buffer and returned
 * 0 -- "not blocked" -- for any name that did not fit, and asked GetFileAttributesW about a
 * relative, unprefixed path, which fails past MAX_PATH since swift_tar.exe is not longPathAware.
 * Both failed open: a ZIP member `j/<5 x 240 a>/evil.txt` under a junction `j` was written
 * outside -C with exit 0 and nothing on stderr, while the short name was refused. Each ancestor
 * is now asked through a heap-built absolute `\\?\` path, with no length limit, and `.` and
 * empty components are skipped as libarchive skips them -- under `\\?\` they would be passed
 * through literally, fail the lookup, and let `./j/evil.txt` through instead.
 * 2026-10-30 更正（審查發現 A）：原本用固定 1040 字元的緩衝區，放不下的名稱一律回傳 0——「沒擋住」；
 * 並以相對、未加前綴的路徑詢問 GetFileAttributesW，而 swift_tar.exe 沒有 longPathAware，超過
 * MAX_PATH 就失敗。兩者都是失敗時放行：junction `j` 之下的 ZIP 成員 `j/<5 x 240 個 a>/evil.txt`
 * 被寫到 -C 之外，以 0 結束且 stderr 無訊息，短名稱卻會被拒絕。現在每個上層都以堆積上組出的絕對
 * `\\?\` 路徑詢問，沒有長度上限；`.` 與空的路徑段如 libarchive 一樣略過——在 `\\?\` 之下它們會被
 * 原樣傳下去、查詢失敗，反而讓 `./j/evil.txt` 通過。 */
/* With `check_self`, the entry's own last component is asked too, and 4 is returned when it is a
 * name surrogate other than a native symlink -- a junction or an LX symlink. The caller passes it
 * for directory entries: libarchive replaces a native symlink at `j/` with a real directory, as
 * the tar extractor does, but takes a junction for a directory and later sets ITS TIME THROUGH
 * IT, so a ZIP entry `j/` over a junction `j` pointing outside changed the outside directory's
 * mtime, exit 0 (2026-10-30 review, finding B; tar left it alone). Nothing is written through
 * the junction otherwise; members below it already return 2.
 * 帶 `check_self` 時也詢問項目自身的最後一段；若它是原生 symlink 以外的 name surrogate——junction 或
 * LX symlink——則回傳 4。呼叫端對目錄項目傳入此旗標：libarchive 會把 `j/` 處的原生 symlink 換成真的
 * 目錄，與 tar 解出器相同，但把 junction 當成目錄，之後**穿過它設定時間**，於是 junction `j` 指向外部時，
 * ZIP 項目 `j/` 改了外部目錄的 mtime 並以 0 結束（2026-10-30 審查，發現 B；tar 不會動它）。除此之外
 * 不會穿過 junction 寫入任何東西；其下的成員本來就回傳 2。 */
static int blocking_ancestor(const wchar_t *path, int check_self, wchar_t **blocker) {
    *blocker = NULL;
    size_t len = wcslen(path);
    /* Only true ancestors count: a directory entry `a/` is `a` itself, not something
     * below it. On POSIX that entry replaces an existing file `a` -- libarchive's default
     * overwrite, as bsdtar and the tar extractor also do -- and only an entry *below* a
     * file (`a/b` with no `a/` entry) is refused. Measured on WSL 2026-10-07: a ZIP of
     * `a/` and `a/b` replaced `a`; one holding only `a/b` reported "Could not stat a/b"
     * and kept it. Without trimming, Windows refused the `a/` entry too.
     * 只算真正的上層：目錄項目 `a/` 就是 `a` 本身，不在它之下。POSIX 上該項目會取代既有的
     * 檔案 `a`——libarchive 的預設覆寫，bsdtar 與 tar 解出器亦同——只有位於檔案*之下*的
     * 項目（沒有 `a/` 項目時的 `a/b`）才會被拒絕。2026-10-07 於 WSL 實測：含 `a/` 與 `a/b`
     * 的 ZIP 取代了 `a`；只含 `a/b` 的回報「Could not stat a/b」並保留 `a`。若不去掉結尾
     * 分隔符，Windows 連 `a/` 項目也會拒絕。 */
    while (len > 0 && (path[len - 1] == L'/' || path[len - 1] == L'\\')) len--;
    if (len == 0) return 0;

    /* The absolute base: the working directory (the bridge has already chdir'd to -C) under
     * `\\?\`, or `\\?\UNC\` for a share. GetCurrentDirectoryW(0, NULL) counts the terminator.
     * 絕對路徑的基底：工作目錄（橋接層此時已 chdir 到 -C）加上 `\\?\`，網路共用則是 `\\?\UNC\`。
     * GetCurrentDirectoryW(0, NULL) 的長度含結尾字元。 */
    DWORD cwd_cap = GetCurrentDirectoryW(0, NULL);
    if (cwd_cap == 0) return 3;
    wchar_t *cwd = malloc(cwd_cap * sizeof *cwd);
    /* "\\?\UNC" + cwd + one '\' per component + the member + NUL / 前綴 + cwd + 每段一個 '\' + 成員 + NUL */
    size_t abs_cap = 7 + (size_t)cwd_cap + len + 1;
    wchar_t *abs = malloc(abs_cap * sizeof *abs);
    wchar_t *rel = malloc((len + 1) * sizeof *rel);
    DWORD cwd_len = cwd != NULL ? GetCurrentDirectoryW(cwd_cap, cwd) : 0;
    if (cwd == NULL || abs == NULL || rel == NULL || cwd_len == 0 || cwd_len >= cwd_cap) {
        free(cwd); free(abs); free(rel);
        return 3;
    }
    static const wchar_t plain_prefix[] = L"\\\\?\\";
    static const wchar_t unc_prefix[] = L"\\\\?\\UNC";
    const wchar_t *prefix = plain_prefix;
    const wchar_t *base = cwd;
    if (cwd_len >= 4 && cwd[0] == L'\\' && cwd[1] == L'\\' && cwd[2] == L'?' && cwd[3] == L'\\') {
        prefix = L"";                     /* already `\\?\` / 已帶 `\\?\` */
    } else if (cwd_len >= 2 && cwd[0] == L'\\' && cwd[1] == L'\\') {
        prefix = unc_prefix;              /* \\server\share -> \\?\UNC\server\share */
        base = cwd + 1;
    }
    size_t pos = 0;
    for (const wchar_t *p = prefix; *p != L'\0'; p++) abs[pos++] = *p;
    for (const wchar_t *p = base; *p != L'\0'; p++) abs[pos++] = *p;
    while (pos > 0 && abs[pos - 1] == L'\\') pos--;    /* "C:\" ends in one / "C:\" 結尾就有一個 */

    /* memcpy, not wmemcpy: the UCRT defines wmemcpy inline in <wchar.h> with no exported
     * symbol, so a call without that header fails to link (LNK2019, measured).
     * 用 memcpy 而非 wmemcpy：UCRT 把 wmemcpy 以 inline 定義在 <wchar.h>，沒有匯出符號，
     * 未引入該標頭時呼叫會連結失敗（LNK2019，實測）。 */
    memcpy(rel, path, len * sizeof *rel);
    rel[len] = L'\0';   /* len may stop short of the original terminator / len 可能已去掉結尾分隔符 */
    int result = 0;
    size_t i = 0;
    while (i < len) {
        size_t start = i;
        while (i < len && rel[i] != L'/' && rel[i] != L'\\') i++;
        int self = i >= len;
        if (self && !check_self) break;   /* the last component is the entry itself / 最後一段是項目本身 */
        size_t clen = i - start;
        if (clen == 0 || (clen == 1 && rel[start] == L'.')) { i++; continue; }
        /* SECURE_NODOTDOT refuses the whole entry downstream. / 下游的 SECURE_NODOTDOT 會拒絕整個項目。 */
        if (clen == 2 && rel[start] == L'.' && rel[start + 1] == L'.') break;
        abs[pos++] = L'\\';
        memcpy(abs + pos, rel + start, clen * sizeof *abs);
        pos += clen;
        abs[pos] = L'\0';
        DWORD attrs = GetFileAttributesW(abs);
        if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
            /* Only a reparse point pays for the tag lookup. / 只有 reparse point 才查 tag。 */
            WIN32_FIND_DATAW data;
            HANDLE h = FindFirstFileW(abs, &data);
            if (h != INVALID_HANDLE_VALUE) {
                FindClose(h);
                if (self) {
                    if ((data.dwReserved0 & 0x20000000u) && data.dwReserved0 != IO_REPARSE_TAG_SYMLINK) {
                        result = 4;
                    }
                    break;
                }
                if (data.dwReserved0 & 0x20000000u) { result = 2; break; }
            }
        }
        if (self) break;   /* only the surrogate question applies to the entry itself / 項目自身只問 surrogate */
        if (attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
            result = 1;
            break;
        }
        i++;
    }
    free(cwd);
    free(abs);
    if (result != 0) {
        rel[i] = L'\0';
        *blocker = rel;
    } else {
        free(rel);
    }
    return result;
}
#endif

/* For a link under --no-links: the reason libarchive's SECURE_NODOTDOT or
 * SECURE_NOABSOLUTEPATHS would give for refusing `name`, or NULL if the name is safe. Backslash
 * and a drive letter count only on Windows, where they are separators and roots; elsewhere they
 * are ordinary name bytes. The caller refuses and counts the link itself rather than passing it
 * on, so a misjudged name can change how a link is reported but never lets one be created.
 * 供 --no-links 下的連結使用：libarchive 的 SECURE_NODOTDOT 或 SECURE_NOABSOLUTEPATHS 拒絕
 * `name` 時會給的理由；名稱安全則回 NULL。反斜線與磁碟代號只在 Windows 上算數——在那裡它們是
 * 分隔符與根；其他平台上只是名稱裡的普通位元組。呼叫端自行拒絕並計數，不再往下傳，所以判斷
 * 失準只會改變連結被回報的方式，永遠不會讓連結被建立。 */
static const char *unsafe_name_reason(const char *name) {
#ifdef _WIN32
#define SWIFT_TAR_IS_SEP(c) ((c) == '/' || (c) == '\\')
#else
#define SWIFT_TAR_IS_SEP(c) ((c) == '/')
#endif
    if (name == NULL || name[0] == '\0') return NULL;
    if (SWIFT_TAR_IS_SEP(name[0])) return "Path is absolute";
#ifdef _WIN32
    if (((name[0] >= 'A' && name[0] <= 'Z') || (name[0] >= 'a' && name[0] <= 'z')) && name[1] == ':') {
        return "Path is absolute";
    }
#endif
    for (const char *p = name; *p != '\0'; ) {
        const char *end = p;
        while (*end != '\0' && !SWIFT_TAR_IS_SEP(*end)) end++;
        if (end - p == 2 && p[0] == '.' && p[1] == '.') return "Path contains '..'";
        p = (*end == '\0') ? end : end + 1;
    }
    return NULL;
#undef SWIFT_TAR_IS_SEP
}

int swift_tar_zip_read(const char *archive_path,
                       const char *destination_dir,
                       int extract,
                       int to_stdout,
                       int verbose,
                       int restore_mtime,
                       int strict,
                       int no_links,
                       int (*is_excluded)(const char *path, int is_directory),
                       char *error_buffer,
                       size_t error_capacity) {
    adopt_environment_charset();
    struct archive *reader = NULL;
    struct archive *disk = NULL;
    struct archive_entry *entry;
    char *original_dir = NULL;
    int result = -1;
    int status;
    /* Members skipped while extracting, for --strict: reported at the end, after every
     * other member is written. --exclude matches are not counted.
     * 解出時略過的成員數，供 --strict 使用：在其他成員都寫完後才回報。--exclude 命中者不計。 */
    long skipped = 0;
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
                    char text[256];
                    snprintf(error_buffer, error_capacity, "cannot chdir to '%s': %s",
                             destination_dir, error_text(errno, text, sizeof(text)));
                }
                goto cleanup;
            }
        }
    }

    /* The same rule as the create side (add_path): only ARCHIVE_FATAL ends the run.
     * ARCHIVE_FAILED or ARCHIVE_RETRY means this one entry cannot be handled -- report it
     * and move on; ARCHIVE_WARN means it can, so report and carry on with it. This loop
     * used to stop at anything below ARCHIVE_OK, so one member that could not be written
     * (for instance `a/b` when `a` is a file) left every member after it unextracted,
     * while bsdtar skipped it and went on. Decided 2026-09-27 that both sides match.
     * A skipped member is reported on stderr and the run still exits 0, as the create
     * side and the tar extractor already do.
     *
     * 與建立端（add_path）同一條規則：只有 ARCHIVE_FATAL 結束整次執行。ARCHIVE_FAILED
     * 或 ARCHIVE_RETRY 代表這一項處理不了——報告後往下走；ARCHIVE_WARN 代表可以處理——
     * 報告後照常處理它。這個迴圈原本遇到任何小於 ARCHIVE_OK 的狀態就停止，於是一個寫不
     * 進去的成員（例如 `a` 是檔案時的 `a/b`）會讓其後所有成員都沒被解出，而 bsdtar 是略過
     * 它並繼續。2026-09-27 決定兩端一致。略過的成員會印在 stderr，整次執行仍以 0 結束，
     * 與建立端和 tar 解出路徑既有的作法相同。 */
    while ((status = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        const char *path;
        if (status == ARCHIVE_FATAL) {
            set_archive_error(error_buffer, error_capacity, "archive_read_next_header", reader);
            goto cleanup;
        }
        /* UTF-8 first, as at the other two name lookups in this file. On Windows the narrow
         * archive_entry_pathname goes through the ANSI code page and returns NULL for a name it
         * cannot represent, so `-t` of a ZIP printed an empty line for `t/中文/檔.txt` while the
         * archive held the correct UTF-8 bytes -- and every check that compares a ZIP listing
         * (test_zip_sorted's order and --exclude cases) failed on Windows only (2026-10-19).
         * 先取 UTF-8，與本檔另外兩處取名稱的寫法相同。Windows 上窄字元的 archive_entry_pathname
         * 會經 ANSI 字碼頁，對無法表示的名稱回傳 NULL，於是 ZIP 的 `-t` 對 `t/中文/檔.txt` 印出
         * 空行，而封存檔裡其實是正確的 UTF-8 位元組——所有比對 ZIP 清單的檢查（test_zip_sorted 的
         * 順序與 --exclude 案例）只在 Windows 失敗（2026-10-19）。 */
        path = archive_entry_pathname_utf8(entry);
        if (path == NULL) path = archive_entry_pathname(entry);
        if (status == ARCHIVE_FAILED || status == ARCHIVE_RETRY) {
            /* The next archive_read_next_header skips whatever data is left unread.
             * 下一次 archive_read_next_header 會自動略過尚未讀取的資料。 */
            fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                    archive_reason(reader));
            if (extract) skipped++;
            continue;
        }
        if (status < ARCHIVE_OK) {
            fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                    archive_reason(reader));
        }
        /* --exclude on reading, the same Swift function the tar reader calls
         * (TarReader.memberIsExcluded), so -t and -x mean the same on both backends. The
         * next archive_read_next_header skips the unread data.
         * 讀取端的 --exclude，呼叫與 tar 讀取端相同的 Swift 函式（TarReader.memberIsExcluded），
         * 使 -t 與 -x 在兩個後端意義相同。下一次 archive_read_next_header 會略過未讀的資料。 */
        if (is_excluded != NULL) {
            const char *name = archive_entry_pathname_utf8(entry);
            if (name == NULL) name = path;
            if (name != NULL && is_excluded(name, archive_entry_filetype(entry) == AE_IFDIR)) {
                continue;
            }
        }
        /* --no-links, the same rule and the same stderr line as the tar reader (tarNoLinks in
         * swift_tar.swift): a symlink or hard link member is named and not created, and not
         * counted for --strict. A link with an unsafe name is refused as unsafe instead, with
         * libarchive's wording, and counted, as the tar reader and README promise. It is refused
         * here rather than passed on to SECURE_*, so no misjudged name can reach the disk.
         * --no-links，規則與 stderr 訊息皆與 tar 讀取端相同（見 swift_tar.swift 的 tarNoLinks）：
         * 符號連結或硬連結成員只報出名稱、不建立，也不計入 --strict。名稱不安全的連結則改以不安全
         * 路徑拒絕（沿用 libarchive 的措辭）並計數，與 tar 讀取端及 README 的承諾一致。在此直接
         * 拒絕而不交給 SECURE_*，使判斷失準的名稱也不可能落到磁碟上。
         *
         * CORRECTED 2026-10-29. This comment used to say "Unsafe names never get here as links:
         * libarchive's SECURE_* flags refuse them when writing". They did get here, and this
         * branch ran first and dropped them, so `--no-links` on a ZIP holding a symlink named
         * `../portal` exited 0 where tar exits 1. The SECURE_* refusal is real, but it is
         * downstream of this branch, so it never saw the name.
         * 2026-10-29 更正。此註解原本寫「名稱不安全者不會以連結身分走到這裡：libarchive 的 SECURE_*
         * 旗標在寫入時拒絕它們」。它們確實會走到這裡，而本分支先執行並把它們略過，於是 ZIP 中名為
         * `../portal` 的 symlink 在 `--no-links` 下以 0 結束，tar 則以 1 結束。SECURE_* 的拒絕是真的，
         * 但位在本分支之後，所以從沒看到那個名稱。 */
        if (extract && !to_stdout && no_links) {
            const char *hard = archive_entry_hardlink_utf8(entry);
            if (hard == NULL) hard = archive_entry_hardlink(entry);
            if (hard != NULL || archive_entry_filetype(entry) == AE_IFLNK) {
                const char *unsafe = unsafe_name_reason(path);
                if (unsafe != NULL) {
                    fprintf(stderr, "swift_tar: %s: %s\n", path, unsafe);
                    skipped++;
                    continue;
                }
                const char *target = hard;
                if (target == NULL) target = archive_entry_symlink_utf8(entry);
                if (target == NULL) target = archive_entry_symlink(entry);
                if (target == NULL) target = "";
                const char *name = path != NULL ? path : "";
                if (hard != NULL) {
                    fprintf(stderr, "swift_tar: skipping link '%s' (hardlink -> %s) / 略過連結 '%s'（硬連結 -> %s）\n",
                            name, target, name, target);
                } else {
                    fprintf(stderr, "swift_tar: skipping link '%s' (symlink -> %s) / 略過連結 '%s'（符號連結 -> %s）\n",
                            name, target, name, target);
                }
                continue;
            }
        }
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
#ifdef _WIN32
            {
                /* Wide path: the narrow one goes through the ANSI code page and would
                 * mangle a non-ASCII name. / 用寬字元路徑：窄字元會經 ANSI 字碼頁而弄壞非 ASCII 名稱。 */
                const wchar_t *wpath = archive_entry_pathname_w(entry);
                wchar_t *blocker = NULL;
                int is_dir = archive_entry_filetype(entry) == AE_IFDIR;
                int blocked = wpath != NULL ? blocking_ancestor(wpath, is_dir, &blocker) : 0;
                if (blocked == 4) {
                    /* `j/` over an existing junction: keep the junction, touch nothing through it,
                     * and say nothing -- what the tar extractor does with the same entry, which
                     * is not a skip of anything the archive asked for. Finding B.
                     * 既有 junction 上的 `j/`：保留 junction、不穿過它碰任何東西、也不出聲——與 tar
                     * 解出器對同一項目的處理相同，這並未略過封存要求的任何內容。發現 B。 */
                    free(blocker);
                    archive_read_data_skip(reader);
                    continue;
                }
                if (blocked == 3) {
                    fprintf(stderr, "swift_tar: %s: Cannot check the path for links or files in the way\n",
                            path != NULL ? path : "");
                } else if (blocked == 2) {
                    fprintf(stderr, "swift_tar: %s: Cannot extract through symlink or junction '%ls'\n",
                            path != NULL ? path : "", blocker);
                } else if (blocked) {
                    fprintf(stderr, "swift_tar: %s: Can't create directory '%ls': a file is in the way\n",
                            path != NULL ? path : "", blocker);
                }
                free(blocker);
                if (blocked) {
                    archive_read_data_skip(reader);
                    skipped++;
                    continue;
                }
            }
#endif
            status = archive_write_header(disk, entry);
            if (status == ARCHIVE_FATAL) {
                set_archive_error(error_buffer, error_capacity, "archive_write_header", disk);
                goto cleanup;
            }
            if (status == ARCHIVE_FAILED || status == ARCHIVE_RETRY) {
                fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                        archive_reason(disk));
                skipped++;
                continue;
            }
            if (status < ARCHIVE_OK) {
                fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                        archive_reason(disk));
            }
            if (copy_archive_data(reader, disk, error_buffer, error_capacity) != 0) {
                goto cleanup;
            }
            status = archive_write_finish_entry(disk);
            if (status == ARCHIVE_FATAL) {
                set_archive_error(error_buffer, error_capacity, "archive_write_finish_entry", disk);
                goto cleanup;
            }
            if (status < ARCHIVE_OK) {
                fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                        archive_reason(disk));
            }
        } else {
            archive_read_data_skip(reader);
        }
    }
    if (to_stdout && fflush(stdout) != 0) {
        if (error_buffer != NULL && error_capacity > 0) {
            char text[256];
            snprintf(error_buffer, error_capacity, "flush stdout: %s",
                     error_text(errno, text, sizeof(text)));
        }
        goto cleanup;
    }
    /* Close the disk writer here, while the working directory is still -C. libarchive
     * defers directory times (and modes) to close, keyed by the relative path each
     * directory was written under; cleanup used to chdir back first and only then free the
     * writer, so every deferred time landed on a path relative to the wrong directory and
     * failed in silence. Measured 2026-10-09: all 3,442 directories of a ZIP came out with
     * the extraction time, while bsdtar restored them from the same file. Before the strict
     * check, so a run that reports skipped members still gets its directory times.
     * 在工作目錄仍是 -C 時就在此關閉 disk writer。libarchive 把目錄時間（與權限）延到關閉
     * 時才套用，以各目錄寫出時的相對路徑為鍵；cleanup 原本先 chdir 回去才釋放 writer，於是
     * 每個延後的時間都落在相對於錯誤目錄的路徑上，靜默失敗。2026-10-09 實測：一個 ZIP 的
     * 3,442 個目錄全部變成解壓當下的時間，而 bsdtar 從同一個檔案正確還原。放在嚴格檢查之前，
     * 使回報略過成員的那次執行仍能得到正確的目錄時間。 */
    if (disk != NULL) {
        status = archive_write_close(disk);
        if (status == ARCHIVE_FATAL) {
            set_archive_error(error_buffer, error_capacity, "archive_write_close", disk);
            goto cleanup;
        }
        if (status < ARCHIVE_OK) {
            fprintf(stderr, "swift_tar: %s\n", archive_reason(disk));
        }
    }
    if (strict && skipped > 0) {
        if (error_buffer != NULL && error_capacity > 0) {
            snprintf(error_buffer, error_capacity,
                     "%ld member(s) skipped; pass --no-strict to exit 0 anyway / "
                     "略過了 %ld 個成員；如仍要以 0 結束請加 --no-strict", skipped, skipped);
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
