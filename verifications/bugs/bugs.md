# Third-party tool defects met while verifying swift_tar / 驗證 swift_tar 時遇到的第三方工具缺陷

Defects in tools swift_tar is compared against, not in swift_tar. They are here
because each one **looks like a swift_tar defect the first time you meet it**, and
because a verification script that does not know about them will assert something
it cannot ever be right about.

這些是 swift_tar 所比對的工具本身的缺陷，不是 swift_tar 的。之所以記在此處，是因為每一項
**初次遇到時都會像是 swift_tar 的缺陷**，而且不知情的驗證腳本會寫出永遠不可能成立的斷言。

Every claim below was measured on 2026-08-18. Versions:

以下每一項皆為 2026-08-18 實測。版本：

| tool | version | path |
|---|---|---|
| bsdtar | 3.8.4 / libarchive 3.8.4 | `C:\Windows\System32\tar.exe` (shipped with Windows) |
| GNU tar | 1.35 | `/usr/bin/tar` (shipped with Git for Windows) |

Note which is which: in Git Bash a bare `tar` is **GNU tar**, because `/usr/bin`
precedes `System32` on `PATH`. The Windows-native bsdtar is shadowed. The common
shorthand "GNU on Linux, bsdtar on Windows and macOS" does not describe this
machine, and a comparison that says "bsdtar" while invoking a bare `tar` is
measuring GNU tar.

請注意兩者之別：在 Git Bash 中，裸 `tar` 是 **GNU tar**，因為 `PATH` 上 `/usr/bin` 排在
`System32` 之前，Windows 內建的 bsdtar 被遮蔽。常見的簡化說法「Linux 用 GNU、Windows 與
macOS 用 bsdtar」並不描述這台機器，而任何寫著 bsdtar、實際卻執行裸 `tar` 的比較，量到的
都是 GNU tar。

---

## 1. bsdtar on Windows mangles non-ASCII names in its listing output / 在 Windows 上把列表輸出中的非 ASCII 名稱轉成亂碼

**The archive is fine. Only the display is wrong.** bsdtar transcodes entry names
into the ANSI code page on the way to stdout:

**封存本身沒問題，錯的只是顯示。** bsdtar 在寫往 stdout 時會把項目名稱轉為 ANSI 碼頁：

```
GNU tar -tf t.tar   ->  src/中文檔名.txt                    (correct UTF-8)
bsdtar  -tf t.tar   ->  src/<mojibake>.txt
bsdtar  -tf, bytes  ->  73 72 63 2f a3 55 5c 33 37 31 ...   (CP950, not UTF-8)
```

`chcp 65001` does **not** change it — the conversion is not driven by the console
code page, so there is no terminal setting that makes the listing readable.

`chcp 65001` **不會**改變此行為——該轉換並非由主控台碼頁決定，故沒有任何終端機設定能讓
這份列表變得可讀。

**Consequence for verification scripts.** Comparing `-tf` output between swift_tar
and bsdtar byte-for-byte can never pass on Windows for a non-ASCII entry, and the
failure says nothing about the archive. `tar_interop_matrix.zsh` originally did
exactly this and reported `FAIL bsdtar lists the same names as swift_tar` against
an archive bsdtar extracts perfectly. It now compares listings for ASCII names
only — that is where name *shape* lives, trailing slashes and prefixes and
separators — and asserts the non-ASCII half where it is meaningful: extract with
bsdtar and check the name that lands on disk.

**對驗證腳本的影響。** 在 Windows 上逐位元組比對 swift_tar 與 bsdtar 的 `-tf` 輸出，對非
ASCII 項目永遠不可能通過，而該失敗完全無法說明封存的狀況。`tar_interop_matrix.zsh` 原本
正是這麼做，對一個 bsdtar 能完美解出的封存回報
`FAIL bsdtar lists the same names as swift_tar`。現已改為僅就 ASCII 名稱比對列表——名稱的
**形狀**（尾隨斜線、prefix、分隔符）就在那裡——非 ASCII 的部分則在有意義之處斷言：以
bsdtar 解出，檢查落地的檔名。

---

## 2. bsdtar on Windows needs a pax record to extract a non-ASCII name correctly / 在 Windows 上需要 pax 記錄才能正確解出非 ASCII 名稱

Extraction, not display, and it is a real difference between archives:

這一項關乎解出而非顯示，且是封存之間的真實差異：

```
GNU tar --format=ustar  ->  bsdtar extracts  Σ╕¡µûçµ¬öσÉì.txt     WRONG
GNU tar --format=pax    ->  bsdtar extracts  中文檔名.txt         correct
swift_tar (pax records) ->  bsdtar extracts  中文檔名.txt         correct
```

pax records are defined to be UTF-8, so the record is what declares the name's
encoding. Given only ustar bytes, GNU tar passes them through and is right by
accident; bsdtar consults the code page and is wrong.

pax 記錄依規範即為 UTF-8，故該記錄正是宣告名稱編碼的東西。若只拿到裸 ustar 位元組，
GNU tar 原樣通過而恰好正確，bsdtar 參考碼頁因而出錯。

**This is why swift_tar now emits a `path` record for any name containing a byte
≥ 0x80**, not only for names too long for the ustar fields. Before that change
`bsdtar_compat.zsh` carried this as a Windows XFAIL with the note "not yet
diagnosed — which side normalises the name". Neither side normalised anything;
the record was simply absent.

**這正是 swift_tar 現在對任何含有 ≥ 0x80 位元組的名稱都寫出 `path` 記錄的原因**，而不僅
限於長度塞不進 ustar 欄位的名稱。在該修正之前，`bsdtar_compat.zsh` 將此列為 Windows
XFAIL，並註明「尚未診斷——究竟是哪一端對檔名做了正規化」。兩端都沒有做任何正規化，只是
缺少那筆記錄而已。

---

## 3. bsdtar's ZIP writer silently corrupts a non-ASCII name and exits 0 / ZIP 寫入端會默默毀掉非 ASCII 名稱並回傳 0

The worst-behaved of the three, because it reports success:

三者中行為最糟的一個，因為它回報成功：

```
bsdtar --format zip -cf z.zip -C . src
  stderr : tar.exe: src/中文檔名.txt: Can't translate Pathname to CP437
  rc     : 0                       <- warning only
  stored : src/????.txt            <- name destroyed in the archive
  extract: oz/src/____.txt
```

A warning on stderr, exit 0, and an archive whose entry name is permanently lost.
Anything keying on the exit code sees success.

stderr 一則警告、離開碼 0，而封存中的項目名稱已永久遺失。任何以離開碼判定的流程都會看到
成功。

**Relevant to swift_tar because it was once used as counter-evidence.** A note in
`todo/todo.md` originally justified a swift_tar ZIP fix with "bsdtar writes the
same name without complaint, so it was never a libarchive limitation." That was
wrong twice over: the comparison had actually run GNU tar (which has no ZIP writer
at all and quietly produced a *tar* file named `.zip`), and the real bsdtar fails
here too. swift_tar's original behaviour — refusing outright, exit 1 — was the
safer of the two; it now sets `hdrcharset=UTF-8` and stores the name intact, which
is better than either.

**與 swift_tar 相關，是因為它一度被當成反證。** `todo/todo.md` 中原有一則說明，以「bsdtar
寫同一個名稱毫無問題，故此事從來不是 libarchive 的限制」來佐證某項 swift_tar 的 ZIP 修正。
那是雙重錯誤：該比較實際執行的是 GNU tar（它根本沒有 ZIP writer，只是安靜地產生了一個名為
`.zip` 的 *tar* 檔），而真正的 bsdtar 在此同樣會失敗。swift_tar 原本的行為——直接拒絕、
離開碼 1——反而是兩者中較安全的；它現在設定 `hdrcharset=UTF-8` 並完整存下名稱，比兩者都好。

---

## Reproducing / 重現

All three need only a file with a non-ASCII name:

三項都只需要一個帶非 ASCII 名稱的檔案：

```sh
mkdir -p src && printf 'x\n' > 'src/中文檔名.txt'
BSD=/c/Windows/System32/tar.exe

/usr/bin/tar -cf t.tar src
"$BSD" -tf t.tar | od -An -tx1 | head -1     # 1: CP950 bytes in the listing
rm -rf o && mkdir o && "$BSD" -xf t.tar -C o && find o -type f   # 2: mangled on disk
"$BSD" --format zip -cf z.zip src; echo "rc=$?"                  # 3: rc=0, name lost
```

Compare against a swift_tar-written archive, which carries the pax record: the
listing is still mangled (defect 1 is display-only and unavoidable) but the
extracted name is correct.

再與 swift_tar 寫出、帶有 pax 記錄的封存對照：列表仍是亂碼（缺陷 1 屬顯示層，無法避免），
但解出的檔名正確。
