# verifications

- **Traditional Chinese: [README.zh-TW.md](README.zh-TW.md)**

Ad-hoc measurement scripts for swift_tar behavior that isn't covered by the
main benchmark pipeline (`../../benchmark.sh` / `../../benchmark2.sh`). Results
here are exploratory—read the "Status" line on each before trusting a
conclusion.

## Encryption throughput, RSS and size overhead

`encrypt_mbps_rss.sh` measures what the ChaCha20-Poly1305 layer costs: the same
archive with and without `--encrypt`, the layer on its own via
`--encrypt-only` / `--decrypt-only`, and the size overhead. Results in
[`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt).

```sh
ROUNDS=3 ./encrypt_mbps_rss.sh ../../claw-code
```

Runs use a keyfile so they stay non-interactive; `--keyfile` skips the scrypt
KDF, so the numbers measure the AEAD itself rather than key derivation.

For Windows/MSYS throughput, use `encrypt_mbps_win.sh`; it writes
[`encrypt_mbps_win_output.txt`](encrypt_mbps_win_output.txt). It reports MB/s
only. Peak working set is intentionally left to the existing Windows RSS
scripts.

```sh
ROUNDS=1 ./encrypt_mbps_win.sh ../../claw-code
```

The 2026-08-06 Windows run used `release/swift_tar.exe` version
`20260805-193735` on MSYS_NT-10.0-26200 with `claw-code` at 1.40 GB logical
input. It passed `--crypto-selftest` (**44 PASS / 0 FAIL**) and the throughput
script's correctness checks (**6 PASS / 0 FAIL**). Full tree `diff -r` is
available with `VERIFY_TREE=1`, but is disabled by default because it dominates
Windows wall time.

| Codec | create | create + encrypt | extract | extract + decrypt |
| --- | ---: | ---: | ---: | ---: |
| plain tar | 178 MB/s | 147 MB/s | 99 MB/s | 81 MB/s |
| gzip | 166 MB/s | 146 MB/s | 94 MB/s | 94 MB/s |
| zstd | 198 MB/s | 181 MB/s | 106 MB/s | 97 MB/s |

`--encrypt-only` ran at **253 MB/s** and `--decrypt-only` at **269 MB/s**. The
decrypted output was verified byte-identical to the original archive; wrong-key
and tampered-ciphertext inputs were rejected.

### Windows correctness smoke test

`encrypt_windows_correctness.sh` keeps a reusable Windows/MSYS correctness test
for the release executable. It writes
[`encrypt_windows_correctness_output.txt`](encrypt_windows_correctness_output.txt).

```sh
./encrypt_windows_correctness.sh
```

The 2026-08-06 run used `release/swift_tar.exe` version `20260805-193735` on
MSYS_NT-10.0-26200. It passed `--crypto-selftest` (**44 PASS / 0 FAIL**) and the
CLI subset (**6 PASS / 0 FAIL**): encrypted create/extract round-trips for
plain tar, gzip and zstd, byte-for-byte `--encrypt-only` / `--decrypt-only`,
wrong-key rejection, and tamper rejection.

### RSS regression found and fixed (2026-08-03)

The first run exposed a real defect in the new layer, not just a measurement:
encrypting the 1.3 GB corpus peaked at **1454 MB RSS** while the unencrypted
create used 20 MB. Both classic causes from the TGZ investigation below were
present in `crypto.swift`:

- `decryptStream` used the accumulate-then-`removeFirst` buffer pattern, which
  retains its backing store and grows to the size of the whole stream. It now
  reads exactly the bytes each call needs, keeping only the sniffed prefix.
- Neither the encrypt nor the decrypt loop wrapped its per-chunk work in
  `autoreleasepool`, so Foundation's `FileHandle` reads piled up.

| Phase | Unbounded | Bounded serial | Bounded parallel |
| --- | ---: | ---: | ---: |
| plain tar create + encrypt | 1454 MB | 42 MB | **198 MB** |
| extract + decrypt | 1475 MB | 39 MB | **184 MB** |
| `--encrypt-only` | 1438 MB | 24 MB | **228 MB** |
| `--decrypt-only` | 1460 MB | 20 MB | **190 MB** |

The parallel pipeline deliberately holds up to `-n` 4 MiB chunks. Its semaphore
slot is released only after a result is written in order, so memory is bounded
by the configured in-flight count rather than the 1.4 GB stream size.

### Results summary (Apple M4, claw-code 1.40 GB, medians of 3)

| Codec | create | create + encrypt | extract | extract + decrypt |
| --- | ---: | ---: | ---: | ---: |
| plain tar | 550 MB/s | 299 MB/s | 570 MB/s | 426 MB/s |
| gzip | 322 MB/s | 277 MB/s | 474 MB/s | 411 MB/s |
| zstd | 1542 MB/s | 1231 MB/s | 396 MB/s | 460 MB/s |

`--encrypt-only` runs at **542 MB/s** with 228 MB peak RSS and `--decrypt-only`
runs at **392 MB/s** with 190 MB peak RSS. The decrypted output is verified
byte-identical to the original.

Size overhead is **48 bytes of header plus 21 bytes per 4 MiB chunk** — 7125
bytes on a 1.4 GB archive (0.0005%).

Passphrase derivation is measured directly against the same `crypto.swift`:
**0.180 s** per scrypt derivation, with 51.48 MB peak RSS versus 6.13 MB for the
keyfile baseline.

### `-n` scaling of the encryption layer

Each chunk is sealed independently — its nonce and AAD derive only from the
chunk index — so the layer uses the same ordered concurrent pipeline and the
same `-n` budget as the codecs. **The container format did not change**, so
archives written before and after this change are mutually readable.

| `-n` | encrypt | RSS | decrypt | RSS |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 132 MB/s | 28 MB | 133 MB/s | 28 MB |
| 2 | 262 MB/s | 45 MB | 260 MB/s | 41 MB |
| 4 | 479 MB/s | 79 MB | 479 MB/s | 58 MB |
| 8 | 662 MB/s | 147 MB | 656 MB/s | 92 MB |
| 16 | **763 MB/s** | 206 MB | **742 MB/s** | 135 MB |
| 20 (default) | 754 MB/s | 232 MB | 738 MB/s | 152 MB |

Throughput scales cleanly to about `-n 16` on this 10-core machine — a **5.8×**
speed-up over `-n 1` — and the default (`2 × cores` = 20) sits at the plateau,
so it needs no tuning. RSS grows linearly with in-flight chunks (~4 MiB each),
the same trade-off the codecs make.

> **Methodology**: the sweep interleaves settings — every round runs the whole
> sweep and the best time per setting is reported. Running all rounds of one
> `-n` before the next lets the CPU heat up monotonically; an earlier version of
> this script did exactly that and reported a sharp collapse at high `-n`
> (`-n 20` at 146 MB/s) that reversing the order proved to be purely thermal.
> Each phase now deletes its archives as soon as it is done, and the script
> refuses to start without room for them.

> **Status**: macOS throughput/RSS numbers are verified on Apple M4. Windows
> throughput MB/s is verified separately by `encrypt_mbps_win.sh`; Windows peak
> working set is covered by the existing Windows RSS scripts. Correctness is
> enforced rather than assumed — the macOS sweep aborts if any `-n` setting
> fails to round-trip to identical bytes, and `--crypto-selftest` checks all 16
> encrypt/decrypt `-n` combinations across four payload shapes.

## RGB1 container throughput by codec

`../test_swift_tar_rgb1.sh` archives an RGB1 container through every swift_tar
codec and records archive size, compression ratio, create/extract time and MB/s
in [`rgb1_container_mbps_output.txt`](rgb1_container_mbps_output.txt), together
with the run date and build version.

> **Status**: the corpus is a synthetic 1024×1024 RGB1 image (3 MiB payload)
> built from a repeating 4 KiB block, so it is highly compressible by
> construction. The ratios are therefore *not* representative of real
> photographs — read the table for throughput and relative codec cost only.

```sh
../test_swift_tar_rgb1.sh
```

## ZIP throughput and RSS on claw-code

`zip_claw_code_mbps_rss.sh` runs true-ZIP encode and decode against the complete
`claw-code` corpus, reports decimal logical-input MB/s and process peak RSS for each
round, and compares the first extracted tree with the source. By default it
runs three rounds and writes `zip_claw_code_mbps_rss_output.txt`.

```sh
ROUNDS=3 ./zip_claw_code_mbps_rss.sh ../../claw-code
```

## Create-side `-C` compatibility (2026-07-18)

`swift_tar -c` previously parsed `-C` but only passed it to extraction, so a
system-tar-style command such as `swift_tar -c --zstd -f out.tar.zst -C
<parent> <leaf>` tried to stat `<leaf>` in the invocation directory and failed.
Create now opens the archive first, changes the input working directory, and
restores the original directory afterward. This preserves the expected
relative `-f` location while keeping parent paths and `..` out of entry names.

Windows build `swift_tar 20260718-171714` was verified with:

- `swift_tar -test -debug`: all seven checks passed, including plain/gzip
  system-tar interoperability, native ZSTD create-side `-C`, and both Windows
  extraction write backends.
- An isolated `-C ../source leaf` native-ZSTD round-trip: archive output stayed
  in the invocation directory; entries were only `leaf/` and
  `leaf/README.md`; external `zstd` plus Windows system tar listed the same
  entries; extracted content matched byte-for-byte.
- The root Windows helper pipeline was copied into an isolated directory and
  run in both file and nul modes at `n=2`; all eight formats passed in both
  modes, ZSTD file extraction matched the TGZ tree, and raw ZSTD logs recorded
  `native libzstd via swift_tar`.
- The packaged `release/swift_tar_win.zip`: bundled executable reported
  `20260718-171714`, passed its self-test, and retained static zlib 1.3.2 and
  zstd 1.5.7 provenance.

## tgz_inflight_rss.sh

**Question**: Does swift_tar's `-n` flag (in-flight chunk concurrency for
chunk-parallel gzip) control TGZ encode/decode peak RSS? `zshrc.sh`'s `getar()`
never passes `-n`, so TGZ benchmark runs use the default `inflight = cores*2`
(20 on the 10-core R45-Mac test machine). This was raised while investigating
why TGZ showed the highest peak RSS of any format in `OPTIMIZATION.md`
(~2.5–3.3GB for a 1.3GB corpus, versus a few hundred MB for LZFSE formats).

**Usage**:

```sh
swift_tar/verifications/tgz_inflight_rss.sh <path-to-corpus>
```

**Raw output**: [`tgz_inflight_rss_output.txt`](tgz_inflight_rss_output.txt)—
always overwritten with the latest run's stdout. Sweeps use the real
`claw-code` corpus (~1.3GB) on the R45-Mac test machine.

### Root cause found and fixed (2026-07-12)

Before the fix, encode (~2.1–2.6GB) and decode (~2.5–3.0GB) peak RSS were both
roughly corpus-sized and insensitive to `-n`. This is the signature of
Foundation `FileHandle.read` autorelease accumulation in tight CLI loops.
`lzfse-cli.swift` already wrapped its read loops in `autoreleasepool`, while
`swift_tar.swift` had no such pools.

The hot read/write loops were wrapped in `autoreleasepool`: the
`TarWriter.add` file-read loop, `ParallelChunkSink.dispatch` worker,
`gzipDecodeStream`, `TarReader.readExactly`, extract write loop, and trailing
drain loop. It was verified with `swift_tar -test -debug` (4/4 at that phase),
a full `claw-code` round-trip (`diff -rq` clean), and system-tar readability.

### Root cause #2 found and fixed (2026-07-12, phase 2)

After phase 1, RSS was still roughly corpus-sized (~1.3GB). Live `heap`
profiling during encode showed a single ~1.06GB malloc node caused by the
`Data` append + `removeFirst` pattern: `removeFirst` retains the backing store
while `append` keeps extending it, so one buffer grows to the size of the
entire tar stream. Two sites had this pattern:

- `ParallelChunkSink.buffer` (encode): rewritten to fill a staging `Data` to
  exactly `chunkSize`, hand the complete object to a worker, and start a fresh
  buffer for the next chunk.
- `TarReader.pending` (decode): rewritten with an explicit consumed offset and
  `subdata` compaction, keeping the backing store bounded.

### macOS results summary

> **Status**: verified on the R45-Mac machine only. See the Windows section for
> Windows-specific results.

| Side | Pre-fix | Phase 1 (`autoreleasepool`) | Phase 2 (buffer patterns) |
| --- | --- | --- | --- |
| Encode | ~2.1–2.6GB, flat | ~1.0–1.4GB, flat | **90MB (`n=4`) → 300MB (`n=40`); default `n=20` = 219MB** |
| Decode | ~2.5–3.0GB | ~1.2–1.4GB, flat | **~50MB, flat across `-n`** |

No phase introduced a time regression: encode remained 4.3–7.6s and decode
2.8–3.9s. Encode RSS now exposes the true linear `-n` relationship
(in-flight chunks × ~8MiB per chunk) that the leaks previously masked.

### Windows verification: improvement reproduced

**Raw output**:
[`tgz_inflight_rss_win_output.txt`](tgz_inflight_rss_win_output.txt)

The Windows RSS fix was first developed while gzip still ran through an
external CLI process. Per-chunk Foundation `Thread` writers were replaced with
dedicated `DispatchQueue` pipe pumps, and synchronous `readData(ofLength:)`
reads bounded each loop iteration's `Data` lifetime. The later native-zlib
change bypasses that process backend for gzip, while the pipe fix remains in
use for the other external codecs.

A full `-n 4..40` sweep on the same `claw-code` corpus confirms bounded memory
across the full range:

| `-n` | Encode peak WS | Decode peak WS |
| --- | ---: | ---: |
| 4 | 55.6MB | 45.0MB |
| 8 | 75.5MB | 42.9MB |
| 12 | 93.1MB | 44.4MB |
| 16 | 113.9MB | 44.4MB |
| 20 | 139.8MB | 43.0MB |
| 24 | 150.7MB | 42.6MB |
| 28 | 161.0MB | 43.3MB |
| 32 | 176.7MB | 44.7MB |
| 36 | 195.8MB | 44.0MB |
| 40 | 208.0MB | 44.1MB |

Before the Windows-specific fix, encode used 2.5–2.7GB and decode used
2.50–2.55GB. Encode now exposes the expected linear `-n` relationship, while
decode remains flat around 43–45MB.

Native zlib resolves the separate encode-speed gap. The Windows build now
statically links the pinned zlib 1.3.2 submodule instead of spawning one
external `gzip.exe` per chunk. Across the sweep, encode fell from 27–47s to
7.2–15.6s; at the normal parallel plateau (`-n 12..40`) it is 7.2–7.8s,
closely matching the macOS 4.3–7.6s range. Decode improved from 17–19s to
9.7–11.0s, but remains slower than macOS's 2.8–3.9s. Windows extraction and
file-I/O overhead therefore remains a separate optimization target.

### Filename-extension compatibility

Renaming gzip output to `.zip` does not convert it into a ZIP container. A
Windows test using `swift_tar -c -z -f archive.zip` produced gzip magic
`1f 8b`; `unzip -t` failed with `short read`, while Windows system `tar -tf`
and `swift_tar -x` both succeeded. Use `.tgz` or `.tar.gz` for this output.

### Practical takeaway

- On macOS, TGZ memory usage is now comparable to or below the LZFSE formats.
  Default `-n` needs no tuning; lower `-n` can still trade encode speed for
  memory (`n=4` = 90MB at +75% time).
- On Windows, native zlib keeps TGZ encode RSS at 56–208MB (`-n 4–40`, linear)
  and decode RSS at about 43–45MB flat.
- Static zlib removes per-chunk `gzip.exe` spawning: parallel encode is now
  7.2–7.8s. Decode improves to 9.7–11.0s and remains a Windows-specific
  optimization target.
- The current `swift_tar -test -debug` passes all seven checks, including
  create-side `-C`, native ZSTD, both Windows write backends and bidirectional
  system-tar interoperability.

## Extraction: where the time goes, and whether `-n` does anything (2026-08-11)

`verifications/extract_write_path.zsh` → `extract_write_path_output.txt`

macOS 27.0.0 arm64, 10 cores (4P+6E), APFS, 256 MiB per corpus, swift_tar
20260810-170353 vs bsdtar 3.5.3. Three independent runs; the ratios below
reproduced as 1.7/1.9/1.7, 1.1/0.9/1.1, 0.6/0.6/0.6.

### 1. Extraction cost is per-file, and swift_tar WINS on small files

Total bytes held constant, only the file count varies:

| corpus | files | avg size | bsdtar -c | bsdtar -x | swift -c | swift -x | x ratio |
|---|---|---|---|---|---|---|---|
| few  | 8    | 32 MiB | 2142ms | 121ms  | **404ms** | 234ms  | 1.9x slower |
| mid  | 512  | 512 KiB| 2308ms | 288ms  | **401ms** | 309ms  | 1.1x |
| many | 8192 | 32 KiB | 4540ms | 2456ms | **459ms** | **1545ms** | **0.6x — faster** |

Two things fall out of this table:

- **Creation is 4–10x faster than bsdtar in every corpus.** The chunked
  parallel gzip is doing real work.
- **Extraction gets relatively BETTER as files get smaller.** swift_tar loses
  on a handful of huge files and wins on thousands of small ones.

The second point contradicts the hypothesis that motivated this script
(per-file overhead in Foundation). It is bsdtar whose per-file cost dominates
here: 2456ms for 8192 files versus swift_tar's 1545ms.

**Practical consequence:** whether swift_tar or bsdtar is faster depends
entirely on the archive's shape. For a Swift toolchain tarball (few, large
files) bsdtar wins. For a source tree or a rootfs, swift_tar wins.

### 2. The write path is ~90% of extraction for small files

`-t` decodes the whole archive and writes nothing; `-x` decodes and writes.

| corpus | files | swift -t | swift -x | write path | bsdtar -t | bsdtar -x | write path |
|---|---|---|---|---|---|---|---|
| few  | 8    | 120ms | 207ms  | 87ms   | 32ms  | 265ms  | 233ms  |
| many | 8192 | 214ms | 1644ms | 1430ms | 226ms | 2929ms | 2703ms |

Decoding 256 MiB costs ~200ms and is essentially the same for both tools.
Everything else is file I/O.

### 3. Extraction is single-threaded, and `-n` has no effect on it

| operation | wall | user | sys | CPU/wall |
|---|---|---|---|---|
| swift -x (default -n) | 1650ms | 280ms | 1390ms | **1.01** |
| swift -x -n 1 | 1560ms | 270ms | 1310ms | **1.01** |
| swift -x -n 8 | 1540ms | 270ms | 1300ms | **1.02** |
| swift -t (decode only) | 210ms | 170ms | 40ms | 1.00 |
| bsdtar -x | 2450ms | 240ms | 2190ms | 0.99 |

CPU/wall of 1.0 means one core, all three times. **`-n` changes nothing on the
extract path** — 1650 / 1560 / 1540ms is run-to-run noise, not scaling.

This matches the source: the `FileWriterPool` that batches small-file writes
across threads is inside `#if os(Windows)` (`swift_tar.swift:2432`). macOS and
Linux take the `#else` branch, a sequential `createFile` → `FileHandle` →
`write` → `close` loop.

Note also `sys` ≫ `user` (1390 vs 280ms): extraction is **syscall-bound, not
CPU-bound**. Adding compute threads cannot help something that is waiting on
the filesystem.

### Would a parallel write path on macOS/Linux be worth building?

From the numbers above, honestly: **it would help the case that is already
winning, and not the case that is losing.**

- **Many small files** — the write path is 1430 of 1644ms, and it is
  syscall-bound, so overlapping it across cores has real headroom. But
  swift_tar is already 1.6x faster than bsdtar here. This buys a bigger lead,
  not a fix.
- **Few large files** — the write path is 87 of 207ms, and it is a handful of
  large sequential writes. There is nothing to parallelise, and this is
  precisely the case where swift_tar trails bsdtar (1.9x). **Parallel writing
  would not close that gap.**

So the gap on large files is somewhere else — in the read/decode plumbing
feeding the writes, not in the writes. `-t` is 120ms vs bsdtar's 32ms on the
`few` corpus, which is where that 1.9x actually comes from and where a fix
would have to start.

On **compression** the question does not arise: creation is already 4–10x
faster than bsdtar across every corpus tested.

### 4. `--gzip` really does emit one member per 4 MiB — and `gzip -l` cannot see it

| archive | members | uncompressed per member |
|---|---|---|
| bsdtar `-czf` | 1 | 268,520,960 |
| swift_tar `--gzip` | 65 | min 17,920 / **max 4,194,304** |

4,194,304 is exactly 4 MiB. The pigz-style chunking works as documented.

**`gzip -l` cannot verify this and must not be used to try.** It reads the
first member's header and the last 4 bytes of the file for ISIZE, so its
output is always two lines regardless of member count — a single-member and a
65-member archive look identical. The stream has to be walked member by member
(the script does this with `zlib.decompressobj` and `unused_data`).

A corollary worth remembering: for the same reason, `gzip -l` reports the
wrong uncompressed size for any multi-member archive.

## Parallel extraction on macOS and Linux (2026-08-11)

`verifications/parallel_extract_correctness.zsh` → `parallel_extract_correctness_output.txt`

The `FileWriterPool` that batches small-file writes across threads was
`#if os(Windows)` only. It now runs on every platform, with a POSIX writer
(`posixWriteFile`) alongside the existing `winWriteFile`.

### What changed

- **One open per file instead of three.** The inline path did `createFile`,
  then `FileHandle(forWritingAtPath:)`, then `setAttributes` for mtime.
  `posixWriteFile` does a single `open` and then `fchmod`/`futimens` on that
  same descriptor.
- **`fchmod`, not a later path-based `chmod`.** Cheaper, and correct: a
  path-based call after the fact would race with any other worker that has
  since replaced the file at that name. The mode cannot come from `open`'s
  mode argument either — that is masked by umask and only honoured on
  creation, so 0755 would land as `0755 & ~umask`.
- **The ordering barriers are now platform-independent**, because the hazard
  was never the filesystem — it is the queue. A queued write to a name must
  land before a symlink replaces it, `link(2)` needs its target to exist, and
  a duplicate path must let the LAST entry win.

### Result: extraction of 8192 small files (256 MiB total)

| | before | after |
|---|---|---|
| wall | 1528ms | **631ms** |
| write path (`-x` minus `-t`) | 1345ms | **397ms** |
| CPU/wall | 1.01 | **6.40** |
| vs bsdtar (2405ms) | 1.6x faster | **3.8x faster** |

512 files of 512 KiB: 227ms → 133ms.

**Large files are unchanged, by design and in measurement.** Anything above
`smallFileMax` (4 MiB) still streams inline, because the pool buffers each
file whole and its memory ceiling is inflight × smallFileMax. Five runs of
8 × 32 MiB: 169-185ms before, 169-174ms after.

That also means this does **not** close the gap on few-large-file archives,
where swift_tar still trails bsdtar. That gap is in the read/decode plumbing,
not the writes — `-t` alone is 120ms against bsdtar's 32ms.

### Correctness

12/12 on both platforms, across `-n` 1/2/8/16 with repeats — ordering bugs do
not fail every run, so a single pass proves nothing.

| | macOS 27.0.0 arm64 | Linux aarch64 (Buildroot guest) |
|---|---|---|
| tree identical to reference | PASS | PASS |
| modes 0755 / 0600 / 0644 | PASS | PASS |
| symlink not overwritten by a queued write | PASS | PASS |
| hardlink shares its target's inode | PASS | PASS |
| mtime restored by the worker | PASS | PASS |
| 6 MiB inline file byte-identical | PASS | PASS |
| duplicate path: last entry wins | PASS | PASS |
| unwritable destination fails loudly | PASS | PASS |

### Four harness bugs this shook out, all of which faked a product failure

Worth recording, because each produced a confident wrong answer:

1. **`tar -rf` on the guest** silently produced a ONE-member archive (busybox
   has no append), so the duplicate-path case compared against an input that
   did not contain a duplicate — and reported 8/8 failures. Now built with
   swift_tar's own `-r`, and the member count is asserted before the case runs.
2. **No `stat` on the guest.** The permission and hardlink cases read empty
   strings and failed, while the full fingerprint comparison — which also
   covers modes — passed. A measurement tool that disagrees with itself is the
   tool's bug. Now uses zsh's `zsh/stat`.
3. **`07777` is decimal 7777 in zsh.** zsh does not treat a leading zero as
   octal, so the permission mask silently turned 0754 into 0140. Use `8#7777`.
4. **No `diff` on the guest**, and `diff | while read` puts the loop in a
   subshell so appends to the report vanish. The report printed bare "DIFF"
   headers with nothing under them — losing the only evidence a failure
   produces. Now compared in zsh.

A fifth, in the perf harness: two concurrent runs sharing one scratch
directory produced a 512 MiB extraction "taking" 8ms. Both scripts now use
`mktemp -d`.
