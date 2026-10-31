# Swift 在 aarch64 Linux 上把 `.rodata` 標成可寫 / Swift marks `.rodata` writable on aarch64 Linux

**狀態**：未向 Swift 回報（2026-10-13，使用者決定先留作文件）。本樹在建置時繞過，見下方〈本樹的
處理〉。這份文件是給之後要回報、或要判斷「這個繞過還需不需要」的人看的。

Not reported to Swift; kept here by the user's decision on 2026-10-13. This tree works
around it at build time. The page is for whoever reports it later, or needs to decide
whether the workaround is still required.

---

## 現象 / What happens

Swift 6.3.3（aarch64、Linux、glibc）編出的目的檔裡，有一個名為 `.rodata` 的 section 帶著可寫旗標
（`readelf -SW` 顯示 `WA`，正常應為 `A`）。裡面放的是**無 payload enum 的 protocol conformance
descriptor**。

連結器只是照旗標做事，所以後果因連結器而異，但都不對：

| 連結器 | 後果 |
|---|---|
| GNU ld 2.45.1（依名稱安置 section） | 輸出的 `.rodata` 變成可寫，而它位在 text 區段裡——整個映像成為單一個可寫又可執行的 LOAD 區段，連結器警告 `LOAD segment with RWX permissions`，且沒有 `GNU_RELRO` |
| GNU ld 加 `-z separate-code` | 程式碼有自己的區段，但所有唯讀資料落在 RW 區段，仍沒有 `GNU_RELRO` |
| lld 21.0.0（依旗標安置） | 有 `GNU_RELRO`，但整個 `.rodata`——含每一個字串常數——被放進不受 RELRO 保護的可寫資料區段 |

The object files carry a section named `.rodata` with the writable flag set, holding the
protocol conformance descriptors of payload-free enums. Each linker honours the flag in
its own way and none of the results is right: one RWX segment under GNU ld, all read-only
data in an RW segment with `-z separate-code`, and a writable `.rodata` outside RELRO
under lld.

## 觸發條件 / What triggers it

任何無 payload 的 enum：

```swift
enum E { case a, b }
```

2026-10-13 在 VM 上試了六種宣告與使用方式——隱含合成、明寫 `Equatable`、明寫 `Hashable`，各自
搭配 `==`、`switch`、`Set`——在 `-O` 與 `-Onone` 下**全部**產生可寫的 `.rodata`。所以這不是原始碼
寫法能避開的。本樹中觸發它的是 `TarCodec` 與 `WriteBackend`。

同一台機器上只有 `print("hi")` 的 Swift 程式沒有這個問題，連結後有 `GNU_RELRO`。

Any payload-free enum does it. Six ways of declaring and using one were tried, at `-O`
and `-Onone`, and all of them produced the writable section, so it cannot be avoided in
source. A program that is only `print("hi")` does not show it.

## 怎麼重現 / How to reproduce

在 aarch64 Linux 上，以 Swift 6.3.3：

```sh
printf 'enum E { case a, b }\nprint(E.a == E.b)\n' > e.swift
swiftc -O -c e.swift
readelf -SW e.o | grep ' \.rodata '      # 找旗標欄含 W 的那一列
swiftc -O e.swift -o e
readelf -lW e | grep -E 'LOAD|GNU_RELRO' # GNU ld：一個 RWE 區段、沒有 GNU_RELRO
```

**這段指令是依當時的做法重寫的，不是貼上的紀錄**；回報前請實際跑一次，把輸出貼進去。

These commands restate the procedure that was used; they are not a pasted transcript.
Run them and attach the real output before reporting.

## 量到的事實 / What was measured

- 環境：QEMU aarch64 guest（HVF）、Buildroot、glibc、Swift 6.3.3、GNU ld 2.45.1、
  工具鏈自帶的 LLD 21.0.0。
- lld 連結出的 swift_tar 有 1657 筆動態重定位，**落在 `.rodata` 位址範圍內的是 0 筆**——載入器不
  需要它可寫。
- 把旗標拿掉後（見下），lld 與 GNU ld 連結出的執行檔都把 `.rodata` 放在唯讀區段，兩者都有
  `GNU_RELRO`；20 支測試、`--crypto-selftest`、`-test` 全數以 0 結束，核心 log 沒有任何 fault。

**沒有量到的**：

- Swift runtime 在某條測試沒走到的路徑上會不會寫這些 descriptor。測試全過不能排除。
- 其他 Swift 版本、其他架構（x86_64）、其他 libc（musl）是否相同。只測了上述一種組合。
- 這個旗標是刻意的還是疏漏。沒有讀過 Swift 編譯器的原始碼。

Of 1657 dynamic relocations in the lld build, none lands in `.rodata`, so the loader does
not need it writable. With the flag removed both linkers give a read-only `.rodata` and
GNU_RELRO, and every suite passes with nothing faulting. Not measured: whether an untested
runtime path writes there; other Swift versions, architectures or libcs; whether the flag
is intentional.

## 本樹的處理 / What this tree does

`compile_tar-linux.zsh` 把編譯與連結分成兩步，中間對每個 Swift 目的檔執行：

```sh
llvm-objcopy --set-section-flags .rodata=alloc,readonly,data file.o
```

連結後檢查輸出的 `.rodata`；若仍可寫，建置失敗。找不到 `llvm-objcopy` 或 `objcopy` 時印出 NOTICE，
該次建置的 `.rodata` 維持可寫。

**這是在改寫編譯器的輸出**，是與使用者討論後的決定（2026-10-13），不是自行加上的。若 runtime 真的
會寫那些 descriptor，後果是 SIGSEGV，不是靜默出錯。

The build compiles and links in two steps and removes the flag from each Swift object in
between, then refuses a binary whose `.rodata` is writable. This rewrites compiler output
and was decided with the user. If the runtime does write there, the result is a fault,
not silent corruption.

## 上游修好了要怎麼知道 / How to tell when upstream has fixed it

沒有東西會自動通知。升級 Swift 工具鏈後：

1. 跑上面〈怎麼重現〉的前三行。旗標欄不再含 `W` 就是修好了。
2. 修好之後，`compile_tar-linux.zsh` 的 objcopy 那一步變成沒有作用（不會壞，但已多餘），可以把
   編譯與連結併回一步；連結後的 `.rodata` 檢查建議留著。

Nothing announces a fix. After a toolchain upgrade, repeat the first three reproduction
lines; once the flag column no longer shows `W`, the objcopy step is redundant and compile
and link can be one step again. Keep the post-link check.

## 若要回報 / If it is reported

- 對象：<https://github.com/swiftlang/swift/issues>
- 要附上：`swiftc --version`、上面重現指令的實際輸出、`readelf -SW e.o` 中那一列、以及 GNU ld 的
  RWX 警告原文。
- 值得一提的旁證：0 筆動態重定位落在該 section，所以可寫旗標對載入而言不是必要的。
