# libarchive: two findings outside swift_tar's fixes

**Two libarchive behaviours turned up while the 2026-10-31 review fixes were verified on
Windows. Neither is a swift_tar bug, and swift_tar does not work around either.** They are
written down so the next person who sees a ZIP dated 2096, or a Windows message naming no
file, does not take it for a swift_tar regression.

**2026-10-31 審查修正在 Windows 上驗證時，發現兩個 libarchive 的行為。兩者都不是 swift_tar
的錯誤，swift_tar 也沒有替它們繞路。** 記下來，是為了讓下一個看到「日期是 2096 年的 ZIP」或
「Windows 訊息沒有指名檔案」的人，不會把它當成 swift_tar 的回歸。

This is recorded here rather than in the README because it is a finding about libarchive and
the tools that read its output, not about this tool. See also [bsdtar-bug.md](bsdtar-bug.md).

此處記錄的是關於 libarchive 及讀取其輸出之工具的發現，而非本工具的行為，故不放在 README。
另見 [bsdtar-bug.md](bsdtar-bug.md)。

---

## 1. A ZIP entry dated before 1970 reads as 2096 or 1980 / 1970 年以前的 ZIP 項目被讀成 2096 或 1980 年

**What is in the archive is right. Two common readers show it wrong, in two different ways.**

**封存裡的值是對的。兩個常見的讀取工具都顯示錯，而且錯法不同。**

A ZIP entry carries its time twice:
- the DOS date/time field, which cannot go below 1980-01-01;
- the "UT" extra field (ID 0x5455), a 32-bit Unix time.

For a file dated 1960 the UT field holds a negative number. libarchive writes it, and that is
the correct signed value. Each reader then takes one of the two fields:

ZIP 項目把時間存兩次：
- DOS 日期時間欄位，最早只到 1980-01-01；
- 「UT」擴充欄位（ID 0x5455），32 位元的 Unix 時間。

1960 年的檔案，UT 欄位裡是負數。libarchive 寫出的就是這個正確的有號值。之後各個讀取工具各取
其中一個欄位：

| reader / 讀取工具 | reads / 讀哪個欄位 | shows / 顯示 |
| --- | --- | --- |
| `bsdtar 3.5.3 - libarchive 3.7.4` (macOS) | UT, as **unsigned** / UT，當成**無號數** | `Jul 21 2096` |
| `UnZip 6.00` (macOS) | DOS field only / 只看 DOS 欄位 | `01-01-1980 00:00` |
| `swift_tar` (8c9100c) | UT, signed / UT，有號數 | `1960-06-15 12:00:00` ✓ |

2096-07-21 is exactly what the 1960 value becomes when read as unsigned: −301233600 + 2³² =
3993733696.

2096-07-21 正是 1960 年那個值被當成無號數讀的結果：−301233600 + 2³² = 3993733696。

- Reported by Swift_tar-W11 on Windows, 2026-10-31, "on all platforms".
- Reproduced on macOS 27.2 the same day, Swift_tar-M4, with `swift_tar 0.1.4
  (v0.1.4-27-g8c9100ca)`, `bsdtar 3.5.3 - libarchive 3.7.4`, `UnZip 6.00 of 20 April 2009`:

```zsh
mkdir -p src && print x > src/old.txt && touch -d 1960-06-15T12:00:00 src/old.txt
swift_tar -c --zip -f z.zip -C src old.txt     # rc=0
bsdtar -tvf z.zip                              # ... Jul 21  2096 old.txt
unzip -l z.zip                                 # 01-01-1980 00:00   old.txt
zipinfo -v z.zip                               # DOS: 1980 Jan 1 00:00:00; a 0x5455 (UT) subfield
swift_tar -xf z.zip -C out                     # out/old.txt: 1960-06-15 12:00:00
```

**Why swift_tar leaves it / 為什麼 swift_tar 不處理：**
- The ZIP format has no other field that can hold a time before 1970. The DOS field stops at
  1980, and the UT field is the standard place for a Unix time.
- Writing the UT field unsigned, or leaving it out, would make bsdtar or unzip agree, but the
  archive would then be wrong.
- The tar formats are not affected: they carry the time as a pax `mtime=-N` record, which
  GNU tar 1.35 and swift_tar read to the nanosecond.

- ZIP 格式沒有別的欄位能放 1970 年以前的時間。DOS 欄位止於 1980，UT 欄位就是放 Unix 時間的
  標準位置。
- 把 UT 改寫成無號數、或乾脆不寫，可以讓 bsdtar 或 unzip 看起來一致，但封存本身就錯了。
- tar 格式不受影響：時間以 pax `mtime=-N` 記錄帶出，GNU tar 1.35 與 swift_tar 都讀得到奈秒。

---

## 2. Windows: "Couldn't visit directory" names no file, and may read freed memory / Windows：「Couldn't visit directory」沒有指名檔案，且可能讀到已釋放的記憶體

**On Windows, libarchive's directory reader builds this message after it has already removed
the path it is about.** The name in the message is empty or garbage, even for an ASCII name.
Measured 2026-10-31 by Swift_tar-W11: stray environment strings appeared where the name
should be.

**在 Windows 上，libarchive 的目錄讀取器在組這則訊息時，已經把它要講的那個路徑移除了。** 訊息
裡的名稱是空的或是亂碼，連 ASCII 名稱也一樣。Swift_tar-W11 於 2026-10-31 實測：名稱的位置
出現了環境變數字串的殘渣。

Where / 位置：`libarchive/libarchive/archive_read_disk_windows.c`, in the tree walk's
`TREE_ERROR_DIR` case (line 928 in the submodule at `v3.7.5-2164-g7f149b10`):

```c
case TREE_ERROR_DIR:
    archive_set_error(&a->archive, t->tree_errno,
        "%ls: Couldn't visit directory",
        tree_current_path(t));
    return (ARCHIVE_FAILED);
```

- By the time this runs, the path has been popped off the walk's stack.
- `tree_current_path(t)` can therefore point at memory that is no longer the path, and `%ls`
  reads it until it finds a wide NUL.
- This is a possible **over-read**, not only a cosmetic problem. It has not been confirmed
  with a memory checker.
- The POSIX reader (`archive_read_disk_posix.c`) keeps the name, so this is Windows-only.

- 執行到這裡時，路徑已經從走訪的堆疊彈出。
- 所以 `tree_current_path(t)` 可能指向已經不是那個路徑的記憶體，而 `%ls` 會一路讀到遇見寬字元
  NUL 為止。
- 這可能是**越界讀取**，不只是外觀問題。尚未以記憶體檢查工具確認。
- POSIX 的讀取器（`archive_read_disk_posix.c`）保留了名稱，所以只有 Windows 有此問題。

**What swift_tar does / swift_tar 的處理：** since `8c9100c` the ZIP bridge does not print
libarchive's text for this message on Windows. It prints the UTF-8 name of the directory or
operand it asked libarchive to visit, which is the only thing the message can be about. See
`next_header_action` in `libarchive_zip_bridge.c`. libarchive itself is unchanged, so the
read may still happen inside `archive_set_error`; swift_tar only stops printing its result.

**swift_tar 的處理：** 自 `8c9100c` 起，ZIP 橋接層在 Windows 上不再印出 libarchive 這則訊息的
文字，改印它請 libarchive 走訪的目錄或運算元的 UTF-8 名稱——那是這則訊息唯一可能指的對象。見
`libarchive_zip_bridge.c` 的 `next_header_action`。libarchive 本身沒有改，所以那次讀取仍可能在
`archive_set_error` 裡發生；swift_tar 只是不再印出它的結果。

**Not done / 尚未做：**
- No upstream report has been filed.
- No ASan or Application Verifier run has confirmed the over-read.

- 尚未向上游回報。
- 尚未以 ASan 或 Application Verifier 確認越界讀取。
