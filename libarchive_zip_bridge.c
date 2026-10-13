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

/* Write one entry and, for a regular file, its data. Returns 0 when the walk should go on
 * (the entry was written, or could not be and was reported) and -1 when the run must end.
 * 寫出一個項目；若為一般檔案，連同其資料。回傳 0 表示走訪應繼續（項目已寫出，或寫不進去且已
 * 回報），-1 表示整次執行必須結束。 */
static int write_entry(struct archive *writer,
                       struct archive_entry *entry,
                       int verbose,
                       char *error_buffer,
                       size_t error_capacity) {
    int status;

    if (verbose) fprintf(stderr, "a %s\n", archive_entry_pathname(entry));

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
                archive_entry_pathname(entry), archive_error_string(writer));
        return 0;
    }
    if (status < ARCHIVE_OK) {
        /* ARCHIVE_WARN: the header was written, so keep going and copy the data,
         * but do not let the reason go unsaid.
         * ARCHIVE_WARN：標頭已寫入，故繼續複製資料，但不讓原因無聲消失。 */
        fprintf(stderr, "swift_tar: %s: %s\n",
                archive_entry_pathname(entry), archive_error_string(writer));
    }
    return copy_file_to_archive(writer, entry, error_buffer, error_capacity);
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
                    archive_entry_pathname(entry));
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
    struct archive *writer;
    struct archive *disk;       /* lists one directory at a time / 一次列出一個目錄 */
    struct archive *stat_disk;  /* reads one file's metadata / 讀取單一檔案的中繼資料 */
    file_id archive_id;
    int verbose;
    int follow_symlinks;
    int (*is_excluded)(const char *path, int is_directory);
    char *error_buffer;
    size_t error_capacity;
} sorted_walk;

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
        if (status < ARCHIVE_OK) {
            set_archive_error(walk->error_buffer, walk->error_capacity,
                              "archive_read_next_header", walk->disk);
            goto close_reader;
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
            if (write_entry(walk->writer, entry, walk->verbose,
                            walk->error_buffer, walk->error_capacity) != 0) {
                goto close_reader;
            }
            archive_entry_free(entry);
            entry = NULL;
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

        if (write_entry(walk->writer, entry, walk->verbose,
                        walk->error_buffer, walk->error_capacity) != 0) {
            goto cleanup;
        }
        archive_entry_free(entry);
        entry = NULL;
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

static int add_path(struct archive *writer,
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

        walk.writer = writer;
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
        if (status < ARCHIVE_OK) {
            set_archive_error(error_buffer, error_capacity, "archive_read_next_header", disk);
            goto cleanup;
        }

        if (skip_entry(entry, archive_id, verbose, is_excluded)) {
            archive_entry_free(entry);
            entry = NULL;
            continue;
        }

        if (archive_read_disk_can_descend(disk)) archive_read_disk_descend(disk);

        if (write_entry(writer, entry, verbose, error_buffer, error_capacity) != 0) {
            goto cleanup;
        }
        archive_entry_free(entry);
        entry = NULL;
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
        if (add_path(writer, paths[index], archive_id, verbose, follow_symlinks, is_excluded,
                     sort_members,
                     error_buffer, error_capacity) != 0) {
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
 * 拒絕不會遺失資料，取代會）。 */
static int blocking_ancestor(const wchar_t *path, wchar_t *out, size_t out_count) {
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
    if (len == 0 || len >= out_count) return 0;
    /* memcpy, not wmemcpy: the UCRT defines wmemcpy inline in <wchar.h> with no exported
     * symbol, so a call without that header fails to link (LNK2019, measured).
     * 用 memcpy 而非 wmemcpy：UCRT 把 wmemcpy 以 inline 定義在 <wchar.h>，沒有匯出符號，
     * 未引入該標頭時呼叫會連結失敗（LNK2019，實測）。 */
    memcpy(out, path, len * sizeof *out);
    out[len] = L'\0';   /* len may stop short of the original terminator / len 可能已去掉結尾分隔符 */
    for (size_t i = 1; i < len; i++) {
        if (out[i] != L'/' && out[i] != L'\\') continue;
        wchar_t sep = out[i];
        out[i] = L'\0';
        DWORD attrs = GetFileAttributesW(out);
        if (attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
            return 1;
        }
        out[i] = sep;
    }
    return 0;
}
#endif

int swift_tar_zip_read(const char *archive_path,
                       const char *destination_dir,
                       int extract,
                       int to_stdout,
                       int verbose,
                       int restore_mtime,
                       int strict,
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
                    snprintf(error_buffer, error_capacity, "cannot chdir to '%s': %s",
                             destination_dir, strerror(errno));
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
        path = archive_entry_pathname(entry);
        if (status == ARCHIVE_FAILED || status == ARCHIVE_RETRY) {
            /* The next archive_read_next_header skips whatever data is left unread.
             * 下一次 archive_read_next_header 會自動略過尚未讀取的資料。 */
            fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                    archive_error_string(reader));
            if (extract) skipped++;
            continue;
        }
        if (status < ARCHIVE_OK) {
            fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                    archive_error_string(reader));
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
                wchar_t blocker[MAX_PATH * 4];
                if (wpath != NULL && blocking_ancestor(wpath, blocker, sizeof blocker / sizeof blocker[0])) {
                    fprintf(stderr, "swift_tar: %s: Can't create directory '%ls': a file is in the way\n",
                            path != NULL ? path : "", blocker);
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
                        archive_error_string(disk));
                skipped++;
                continue;
            }
            if (status < ARCHIVE_OK) {
                fprintf(stderr, "swift_tar: %s: %s\n", path != NULL ? path : "",
                        archive_error_string(disk));
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
                        archive_error_string(disk));
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
            fprintf(stderr, "swift_tar: %s\n", archive_error_string(disk));
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
