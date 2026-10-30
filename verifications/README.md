# verifications

- **Traditional Chinese: [README.zh-TW.md](README.zh-TW.md)**

Ad-hoc measurement scripts for swift_tar behavior that isn't covered by the
main benchmark pipeline (`../../benchmark.zsh` / `../../benchmark2.zsh`). Results
here are exploratory—read the "Status" line on each before trusting a
conclusion.

## Encryption throughput, RSS and size overhead

`encrypt_mbps_rss.zsh` measures what the ChaCha20-Poly1305 layer costs: the same
archive with and without `--encrypt`, the layer on its own via
`--encrypt-only` / `--decrypt-only`, and the size overhead. Results in
[`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt).

```sh
ROUNDS=3 ./encrypt_mbps_rss.zsh ../../claw-code
```

Runs use a keyfile so they stay non-interactive; `--keyfile` skips the scrypt
KDF, so the numbers measure the AEAD itself rather than key derivation.

For Windows/MSYS throughput, use `encrypt_mbps_win.zsh`; it writes
[`encrypt_mbps_win_output.txt`](encrypt_mbps_win_output.txt). It reports MB/s
only. Peak working set is intentionally left to the existing Windows RSS
scripts.

```sh
ROUNDS=3 ./encrypt_mbps_win.zsh ../../claw-code
```

The recorded run used `release/swift_tar.exe` version
`0.1.2 (v0.1.1-19-g08adeb75)` on MINGW64_NT-10.0-26300 with `claw-code` at
1.40 GB logical input, median of 3 rounds. It passed `--crypto-selftest`
(**51 PASS / 0 FAIL**) and the throughput script's correctness checks
(**8 PASS / 0 FAIL**). Full tree `diff -r` is available with `VERIFY_TREE=1`,
but is disabled by default because it dominates Windows wall time.

Every figure below is section A and B of
[`encrypt_mbps_win_output.txt`](encrypt_mbps_win_output.txt). Do not edit this
table by hand; diff it against that file after each run.

| Codec | create | create + encrypt | extract | extract + decrypt |
| --- | ---: | ---: | ---: | ---: |
| plain tar | 328 MB/s | 166 MB/s | 159 MB/s | 86 MB/s |
| gzip | 155 MB/s | 122 MB/s | 102 MB/s | 73 MB/s |
| zstd | 180 MB/s | 152 MB/s | 139 MB/s | 90 MB/s |

`--encrypt-only` ran at **260 MB/s** and `--decrypt-only` at **259 MB/s**. The
decrypted output was verified byte-identical to the original archive; wrong-key
and tampered-ciphertext inputs were rejected.

### Windows correctness smoke test

`encrypt_windows_correctness.zsh` keeps a reusable Windows/MSYS correctness test
for the release executable. It writes
[`encrypt_windows_correctness_output.txt`](encrypt_windows_correctness_output.txt).

```sh
./encrypt_windows_correctness.zsh
```

The recorded run used `release/swift_tar.exe` version
`0.1.2 (v0.1.1-19-g08adeb75)` on MINGW64_NT-10.0-26300. It passed
`--crypto-selftest` (**51 PASS / 0 FAIL**) and the
CLI subset (**6 PASS / 0 FAIL**): encrypted create/extract round-trips for
plain tar, gzip and zstd, byte-for-byte `--encrypt-only` / `--decrypt-only`,
wrong-key rejection, and tamper rejection.

### Memory bound of the encryption layer

`decryptStream` reads exactly the bytes each call needs, keeping only the
sniffed prefix, and both the encrypt and decrypt loops wrap their per-chunk
work in `autoreleasepool`, so neither grows with the stream (the same two
patterns as in the TGZ section below).

The parallel pipeline deliberately holds up to `-n` 4 MiB chunks. Its semaphore
slot is released only after a result is written in order, so memory is bounded
by the configured in-flight count rather than the 1.4 GB stream size.

### Results summary (Apple M4, claw-code 1.41 GB, medians of 3)

Every figure below is section A and B of
[`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt) — dated
2026-10-22, build `swift_tar 0.1.2 (v0.1.1-17-gd493560e-dirty) 20261022-191859`.
Do not edit this table by hand; diff it against that file after each run.

| Codec | create | create + encrypt | extract | extract + decrypt |
| --- | ---: | ---: | ---: | ---: |
| plain tar | 686 MB/s | 415 MB/s | 703 MB/s | 370 MB/s |
| gzip | 331 MB/s | 277 MB/s | 427 MB/s | 372 MB/s |
| zstd | 537 MB/s | 473 MB/s | 879 MB/s | 636 MB/s |

`--encrypt-only` runs at **401 MB/s** with 181 MB peak RSS and `--decrypt-only`
runs at **347 MB/s** with 109 MB peak RSS. The decrypted output is verified
byte-identical to the original.

**Sections A and B are bound by disk writes, not by the code.** They write
every archive and extracted tree to a temporary directory on the internal
disk, which is 91% full (18 GiB free) on this machine. Two builds (0.1.1 and
0.1.2) writing to that same directory are equally variable, 0.86–2.11 s for
the same step, and the `-n` sweep below, which takes the best round per
setting, is unaffected. Read the plain-tar and `--encrypt-only` /
`--decrypt-only` figures as this disk's write rate.

Size overhead is **48 bytes of header plus 21 bytes per 4 MiB chunk** — 7167
bytes on a 1.4 GB archive (0.0005%).

Passphrase derivation is measured directly against the same `crypto.swift`:
**0.180 s** per scrypt derivation, with 51.31 MB peak RSS versus 6.03 MB for the
keyfile baseline.

### `-n` scaling of the encryption layer

Each chunk is sealed independently — its nonce and AAD derive only from the
chunk index — so the layer uses the same ordered concurrent pipeline and the
same `-n` budget as the codecs. **The container format does not depend on
`-n`**, so an archive encrypted at one `-n` decrypts at any other.

Section B2 of [`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt), same
run as the tables above. Do not edit by hand.

| `-n` | encrypt | RSS | decrypt | RSS |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 134 MB/s | 28 MB | 134 MB/s | 28 MB |
| 2 | 257 MB/s | 45 MB | 257 MB/s | 41 MB |
| 4 | 470 MB/s | 79 MB | 467 MB/s | 62 MB |
| 8 | 660 MB/s | 147 MB | 657 MB/s | 92 MB |
| 16 | 764 MB/s | 206 MB | 736 MB/s | 156 MB |
| 20 (default) | **768 MB/s** | 244 MB | **756 MB/s** | 164 MB |

Throughput scales cleanly to about `-n 16` on this 10-core machine — a **5.7×**
speed-up over `-n 1` — and the default (`2 × cores` = 20) sits at the plateau,
so it needs no tuning. RSS grows linearly with in-flight chunks (~4 MiB each),
the same trade-off the codecs make.

The `--encrypt-only` rate quoted above (**401 MB/s**) is section B's median and
sits below every row here from `-n 4` up. Section B reports the median round and
this sweep the best round, at different in-flight counts, so neither is "the"
encrypt rate on its own; on this disk, section B measures the writes.

> **Methodology**: the sweep interleaves settings — every round runs the whole
> sweep and the best time per setting is reported. Running all rounds of one
> `-n` before the next lets the CPU heat up monotonically, which shows up as a
> purely thermal collapse at high `-n`.
> Each phase deletes its archives as soon as it is done, and the script
> refuses to start without room for them.

> **Status**: macOS throughput/RSS numbers are verified on Apple M4. Windows
> throughput MB/s is verified separately by `encrypt_mbps_win.zsh`; Windows peak
> working set is covered by the existing Windows RSS scripts. Correctness is
> enforced rather than assumed — the macOS sweep aborts if any `-n` setting
> fails to round-trip to identical bytes, and `--crypto-selftest` checks all 16
> encrypt/decrypt `-n` combinations across four payload shapes.

## RGB1 container throughput by codec

`../test/test_swift_tar_rgb1.zsh` archives an RGB1 container through every swift_tar
codec and reports archive size, compression ratio, create/extract time and MB/s,
together with the run date and build version. With `--record` it also writes the
table to the file for its platform:
[`-mac.txt`](rgb1_container_mbps_output-mac.txt) ·
[`-win.txt`](rgb1_container_mbps_output-win.txt).

The corpus is a real sampled 1080p video frame (`sample_consecutive/f000.rgb1`,
6,221,676 B).

> **Recording is opt-in.** Without `--record` this is purely a correctness test
> and the committed tables are left untouched. A run taken under machine load
> comes in uniformly slower with the sizes unchanged, so record deliberately,
> on an idle machine.

```sh
../test/test_swift_tar_rgb1.zsh              # verify only / 僅驗證
../test/test_swift_tar_rgb1.zsh --record     # verify and update this platform's table
```

## ZIP throughput and RSS on claw-code

`zip_claw_code_mbps_rss.zsh` runs true-ZIP encode and decode against the complete
`claw-code` corpus, reports decimal logical-input MB/s and process peak RSS for each
round, and compares the first extracted tree with the source. By default it
runs three rounds and writes `zip_claw_code_mbps_rss_output.txt`.

```sh
ROUNDS=3 ./zip_claw_code_mbps_rss.zsh ../../claw-code
```

On the Apple M4 (claw-code, 5448 files, 1406 MB; build
`swift_tar 0.1.2 (v0.1.1-21-g2f88c70b-dirty) 20261023-115820`), medians of 3:
encode **6.95 s / 202 MB/s** with 301 MB peak RSS, because members are deflated
in parallel by default (see the `-n` section at the end); decode **2.22 s /
633 MB/s** with 10 MB peak RSS. Decode runs through the system libz, which the
macOS build links; with the pinned zlib 1.3.2 it linked before, the same
decode took 3.52 s / 400 MB/s.

## Create-side `-C` compatibility

`swift_tar -c` honours `-C` as system tar does: in
`swift_tar -c --zstd -f out.tar.zst -C <parent> <leaf>`, create opens the
archive first, changes the input working directory, and restores the original
directory afterward. A relative `-f` therefore lands in the invocation
directory, and parent paths and `..` stay out of entry names. `swift_tar -test`
checks this (`create-side -C: native ZSTD round-trip`).

Windows build `swift_tar 20260718-171714` was verified with:

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

## tgz_inflight_rss.zsh

**Question**: Does swift_tar's `-n` flag (in-flight chunk concurrency for
chunk-parallel gzip) control TGZ encode/decode peak RSS? `zshrc.zsh`'s `getar()`
never passes `-n`, so TGZ benchmark runs use the default `inflight = cores*2`
(20 on the 10-core R45-Mac test machine).

**Usage**:

```sh
swift_tar/verifications/tgz_inflight_rss.zsh <path-to-corpus>
```

**Raw output**: [`tgz_inflight_rss_output.txt`](tgz_inflight_rss_output.txt)—
always overwritten with the latest run's stdout. Sweeps use the real
`claw-code` corpus (~1.3GB) on the R45-Mac test machine.

### What keeps memory bounded

Two patterns would otherwise make peak RSS roughly corpus-sized and insensitive
to `-n`:

- Foundation `FileHandle.read` autorelease accumulation in tight CLI loops. The
  hot read/write loops run inside `autoreleasepool`: the `TarWriter.add`
  file-read loop, `ParallelChunkSink.dispatch` worker, `gzipDecodeStream`,
  `TarReader.readExactly`, the extract write loop, and the trailing drain loop.
- The `Data` append + `removeFirst` pattern, where `removeFirst` retains the
  backing store while `append` keeps extending it, so one buffer grows to the
  size of the entire tar stream. `ParallelChunkSink.buffer` (encode) fills a
  staging `Data` to exactly `chunkSize`, hands the complete object to a worker,
  and starts a fresh buffer for the next chunk; `TarReader.pending` (decode)
  keeps an explicit consumed offset with `subdata` compaction.

### macOS results summary

> **Status**: verified on the R45-Mac machine only. See the Windows section for
> Windows-specific results.

| Side | Peak RSS |
| --- | --- |
| Encode | **112MB (`n=4`) → 286MB (`n=40`); default `n=20` = 219MB** |
| Decode | **~70–77MB, flat across `-n`** |

Encode takes 4.2–7.6s and decode 1.9–2.6s (one 4.1s outlier at `n=40`).
Encode RSS follows a linear `-n` relationship (in-flight chunks × ~8MiB per
chunk). Decode runs through the system libz; with the pinned zlib 1.3.2 the
macOS build linked before, decode took 3.3–4.5s.

### Windows verification

**Raw output**:
[`tgz_inflight_rss_win_output.txt`](tgz_inflight_rss_win_output.txt)

On Windows, gzip runs through statically linked zlib 1.3.2 (the pinned
submodule). The other external codecs go through dedicated `DispatchQueue` pipe
pumps, with synchronous `readData(ofLength:)` reads bounding each loop
iteration's `Data` lifetime.

A full `-n 4..40` sweep on the same `claw-code` corpus confirms bounded memory
across the full range:

| `-n` | Encode peak WS | Decode peak WS |
| --- | ---: | ---: |
| 4 | 61.9MB | 44.7MB |
| 8 | 80.3MB | 45.3MB |
| 12 | 102.7MB | 44.7MB |
| 16 | 117.5MB | 46.6MB |
| 20 | 134.1MB | 45.8MB |
| 24 | 146.3MB | 45.6MB |
| 28 | 162.1MB | 46.5MB |
| 32 | 176.9MB | 45.1MB |
| 36 | 189.6MB | 45.4MB |
| 40 | 191.2MB | 47.1MB |

Encode follows the expected linear `-n` relationship, while decode stays flat
around 45–47MB.

Across the sweep, encode takes 8.2–19.5s; at the normal parallel plateau
(`-n 12..40`) it is 8.2–8.4s, close to the macOS 4.2–7.6s range.
Decode takes 13.4–13.8s, slower than macOS's 1.9–2.6s. Windows extraction and
file-I/O overhead therefore remains a separate optimization target.

### Filename-extension compatibility

Renaming gzip output to `.zip` does not convert it into a ZIP container. A
Windows test using `swift_tar -c -z -f archive.zip` produced gzip magic
`1f 8b`; `unzip -t` failed with `short read`, while Windows system `tar -tf`
and `swift_tar -x` both succeeded. Use `.tgz` or `.tar.gz` for this output.

### Practical takeaway

- On macOS, TGZ memory usage is comparable to or below the LZFSE formats.
  Default `-n` needs no tuning; lower `-n` can still trade encode speed for
  memory (`n=4` = 112MB at +78% time).
- On Windows, native zlib keeps TGZ encode RSS at 62–191MB (`-n 4–40`, linear)
  and decode RSS at about 45–47MB flat.
- With static zlib, parallel encode takes 8.2–8.4s. Decode takes 13.4–13.8s and
  remains a Windows-specific optimization target.
- `swift_tar -test -debug` covers create-side `-C`, native ZSTD, both Windows
  write backends and bidirectional system-tar interoperability.

## Extraction: where the time goes

`verifications/extract_write_path.zsh` → `extract_write_path_output.txt`

macOS 27.2.0 arm64, 10 cores (4P+6E), APFS, 256 MiB per corpus, swift_tar
`0.1.2 (v0.1.1-16-g72b2bbca-dirty) 20261022-184744` vs bsdtar 3.5.3. The
`swift -x` figures in this section run at the default `-n`, so small files go
through the parallel write path (CPU/wall 3.95 in section 3 of the record,
1.17 at `-n 1`).

### 1. Extraction cost is per-file, and swift_tar WINS on small files

Total bytes held constant, only the file count varies:

| corpus | files | avg size | bsdtar -c | bsdtar -x | swift -c | swift -x | x ratio |
|---|---|---|---|---|---|---|---|
| few  | 8    | 32 MiB | 2074ms | 85ms  | **319ms** | 126ms  | 1.5x slower |
| mid  | 512  | 512 KiB| 2098ms | 136ms  | **335ms** | 153ms  | 1.1x |
| many | 8192 | 32 KiB | 2306ms | 804ms | **384ms** | **428ms** | **0.5x — faster** |

Two things fall out of this table:

- **Creation is about 6x faster than bsdtar in every corpus.** The chunked
  parallel gzip is doing real work.
- **Extraction gets relatively BETTER as files get smaller.** swift_tar loses
  on a handful of huge files and wins on thousands of small ones.

It is bsdtar whose per-file cost dominates here: 804ms for 8192 files versus
swift_tar's 428ms.

**Practical consequence:** whether swift_tar or bsdtar is faster depends
entirely on the archive's shape. For a Swift toolchain tarball (few, large
files) bsdtar wins. For a source tree or a rootfs, swift_tar wins.

### 2. How much of extraction is the write path

`-t` decodes the whole archive and writes nothing; `-x` decodes and writes.

| corpus | files | swift -t | swift -x | write path | bsdtar -t | bsdtar -x | write path |
|---|---|---|---|---|---|---|---|
| few  | 8    | 75ms | 162ms  | 87ms   | 30ms  | 163ms  | 133ms  |
| many | 8192 | 285ms | 438ms | 153ms | 169ms | 765ms | 596ms |

For 8192 small files the write path is 153 of 438ms for swift_tar and 596 of
765ms for bsdtar. Decoding 256 MiB costs swift_tar 75–285ms and bsdtar
30–169ms. The file I/O is **syscall-bound, not CPU-bound** (`sys` ≫ `user`).

For few large files the write path is 87 of 162ms — a handful of large
sequential writes with nothing to parallelise. The gap to bsdtar there is in
the read/decode plumbing feeding the writes: `-t` is 75ms vs bsdtar's 30ms on
the `few` corpus.

### 3. `--gzip` really does emit one member per 4 MiB — and `gzip -l` cannot see it

| archive | members | uncompressed per member |
|---|---|---|
| bsdtar `-czf` | 1 | 268,453,376 |
| swift_tar `--gzip` | 65 | min 51,712 / **max 4,194,304** |

4,194,304 is exactly 4 MiB. The pigz-style chunking works as documented.

**`gzip -l` cannot verify this and must not be used to try.** It reads the
first member's header and the last 4 bytes of the file for ISIZE, so its
output is always two lines regardless of member count — a single-member and a
65-member archive look identical. The stream has to be walked member by member
(the script does this with `zlib.decompressobj` and `unused_data`).

A corollary worth remembering: for the same reason, `gzip -l` reports the
wrong uncompressed size for any multi-member archive.

## Parallel extraction on macOS and Linux

`verifications/parallel_extract_correctness.zsh` → `parallel_extract_correctness_output.txt`

The `FileWriterPool` that batches small-file writes across threads runs on
every platform, with a POSIX writer (`posixWriteFile`) alongside
`winWriteFile`.

### How the POSIX writer works

- **One open per file.** `posixWriteFile` does a single `open` and then
  `fchmod`/`futimens` on that same descriptor.
- **`fchmod`, not a later path-based `chmod`.** Cheaper, and correct: a
  path-based call after the fact would race with any other worker that has
  since replaced the file at that name. The mode cannot come from `open`'s
  mode argument either — that is masked by umask and only honoured on
  creation, so 0755 would land as `0755 & ~umask`.
- **The ordering barriers are platform-independent**, because the hazard is
  not the filesystem — it is the queue. A queued write to a name must
  land before a symlink replaces it, `link(2)` needs its target to exist, and
  a duplicate path must let the LAST entry win.

### Result: extraction of 8192 small files (256 MiB total)

| | swift_tar |
|---|---|
| wall | **631ms** |
| write path (`-x` minus `-t`) | **397ms** |
| CPU/wall | **6.40** |
| vs bsdtar (2405ms) | **3.8x faster** |

512 files of 512 KiB: 133ms.

**Large files stream inline, by design.** Anything above `smallFileMax`
(4 MiB) bypasses the pool, because the pool buffers each file whole and its
memory ceiling is inflight × smallFileMax. Five runs of 8 × 32 MiB: 169-174ms.

So the pool does **not** affect few-large-file archives, where swift_tar
trails bsdtar. That gap is in the read/decode plumbing, not the writes — `-t`
alone is 75ms against bsdtar's 30ms.

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

### Harness constraints

Each of these would make the harness fake a product failure:

1. **busybox `tar` on the guest has no append**, so `tar -rf` silently produces
   a one-member archive. The duplicate-path input is built with swift_tar's own
   `-r`, and the member count is asserted before the case runs.
2. **No `stat` on the guest.** The script uses zsh's `zsh/stat`.
3. **`07777` is decimal 7777 in zsh.** zsh does not treat a leading zero as
   octal; the permission mask is written `8#7777`.
4. **No `diff` on the guest**, and `diff | while read` puts the loop in a
   subshell so appends to the report vanish. Trees are compared in zsh.

Both this script and `extract_write_path.zsh` use `mktemp -d`, so concurrent
runs do not share a scratch directory.

## QoS class and what `Thread.qualityOfService` does not do

`qos-DOE.swift` — run bare for usage; `--skip-timing` for the exact part alone.
Raw output in `qos-DOE_output.txt`.

What each API does:

| api | changes `qos_class_self()` |
| --- | --- |
| `Thread.current.qualityOfService = X` on a **running** thread | **no** |
| `thread.qualityOfService = X` **before** `start()` | yes |
| `pthread_set_qos_class_self_np(X, 0)` | yes |

`Thread.qualityOfService` behaves as documented — it is a creation-time
attribute, not a live control. The trap is that assigning it to an
already-running thread is a **silent no-op**: no error, no warning, and
`qos_class_self()` is unchanged. **The main thread is always already running**,
so it can never be configured through the property; `pthread_set_qos_class_self_np`
is the only option there.

The class is not cosmetic. Interleaved over 5 rounds, same loop:

| class | median | vs userInitiated |
| --- | ---: | ---: |
| userInitiated | 4.7 ms | 1.0x |
| utility | 7.9 ms | 1.7x |
| background | 539.5 ms | **113.9x** |

Two consequences for this repo. A benchmark that sets the property on the main
thread and assumes it took effect is comparing threads it believes are equal but
are not — which is why `swift_tar_DOE` uses the pthread call. And `taskpolicy -c background` is not a mild hint: it is a two-orders-of-magnitude
penalty, so it must never wrap a timed run.

> **Note on why the timing section is interleaved.** Running each class to
> completion in turn makes the same call's time depend on its position, because
> a ten-second `background` arm leaves the machine in a different state than it
> found it. Sequential sweeps of anything scheduler- or thermal-sensitive are not
> trustworthy; the arms are interleaved and the median reported.

---

## Per-platform performance data → `profile/`

[`verifications/profile/`](profile/README.md) holds the timing data for each
platform and the script that produces it. Extraction speed relative to bsdtar
depends on the platform.

Same script, same three shapes, both platforms, minima of interleaved reps
(swift_tar / bsdtar):

| shape | macOS | Linux (QEMU aarch64) |
|---|---|---|
| 20 × 8 MB | 34 / 73 ms = **0.47×** | 24 / 27 ms = **0.89×** |
| 200 × 800 KB | 53 / 89 ms = **0.60×** | 47 / 28 ms = **1.68×** |
| 2000 × 80 KB | 84 / 194 ms = **0.43×** | 51 / 38 ms = **1.34×** |

The extract gap is **Linux-specific** and lies in the fragmented shapes: there
swift_tar is 1.34–1.68× slower on 200 × 800 KB and 2000 × 80 KB, and faster
on 20 × 8 MB. On macOS swift_tar is faster than bsdtar on all three shapes.

Two things in that folder's README are worth knowing before measuring anything
here: sampling profilers do not work against a 0.17 s target (at most 52
samples), and the reference tar must be chosen by asking it
what it is — `/usr/bin/tar` in the Linux VM *is* swift_tar, so choosing by
filename compares it with itself and reports a flawless 1.00×.

## Chunk size: what 4 / 8 / 16 MiB trade

`chunk_size_tradeoff.zsh` → `chunk_size_tradeoff.txt`

`TAR_CHUNK_SIZE` (`swift_tar.swift`, `1 << 22` = 4 MiB) is a compile-time constant:
`ParallelChunkSink` accepts `chunkSize:`, but neither call site passes it and no
build script overrides it, so no flag reaches it. The script therefore
**rebuilds**: it copies the sources to a temp directory, replaces only that one
constant (checking each replacement took), and builds each variant with
`compile_tar.zsh`'s swiftc arguments against the existing `build/` artefacts.
It does not touch the work tree, does not call `generate_version.zsh` (which
writes `version-mac.txt`), and does not replace the installed binary.
`--source REV` builds from a git revision, so uncommitted changes in the work
tree cannot leak into the variants.

The variant equal to the shipped value is built exactly like the others, so the
constant is the only difference between them; the installed binary is measured
too, as a check that this build method matches production.

| chunk | ZSTD size | ZSTD decode | TGZ |
| --- | ---: | ---: | --- |
| **4 MiB** | 385.7 MiB | 1431 MB/s | speed and size unaffected by chunk size |
| 8 MiB | **−2.8%** | −2.6% | |
| 16 MiB | **−4.0%** | −2.9% | |

claw-code, swift_tar work tree @ `d493560`, 5 interleaved rounds, minimum taken,
output on a RAM disk, decode via `--cat`.

**Size differences are deterministic; speed differences are not.** Compressed
size does not depend on load: the control, built separately with the same
value, matches 4 MiB to the printed 0.1 MiB. Speed does not repeat as
exactly: the control deviates from 4 MiB by up to 3.0% on every speed but TGZ
decode. The only consistent speed signal is the direction: larger chunks,
slower ZSTD decode and plain tar.

**TGZ decode is the one place the control differs, and it is the zlib, not the
chunk.** The control (the installed `swift_tar 0.1.1`, a release build) decodes
TGZ at 482 MB/s against 930 MB/s for the 4 MiB variant, −48.2%. Release builds
then linked the pinned zlib submodule statically; the variants are linked with
`-lz`, the system libz, which decodes about 2× faster on macOS. That difference
is why the macOS build went back to the system libz in 0.1.2.

**Keep 4 MiB.** A larger chunk buys at most 4% of ZSTD size and no speed. TGZ
is untouched either way — gzip's window is 32 KiB, so the chunk never reaches it.

`zstd_decode_gap.zsh --mode chunk` answers a different question — frame count
at a fixed chunk size, varied through `--zstd-level` — and the two must not be
cited for each other.

## ZIP: what compressing members on `-n` threads buys

`zip_parallel_speed.zsh` → `zip_parallel_speed.csv2`, `zip_parallel_speed_output.txt`

Each ZIP member is deflated by one thread and the members are written in
order; `-n` is how many are compressed at once, one per core by
default. The script packs one tree with every `-n`, three interleaved rounds,
keeps each case's fastest round, and hashes the output: `record` exits 1 when
any two sorted swift_tar cases differ in sha256, because speed bought by
changing the bytes would be a different result.

claw-code (1.4 GB, 5,448 files):

| | `-n 1` | `-n 2` | `-n 4` | `-n 8` | default | peak memory, `-n 1` → default |
|---|---|---|---|---|---|---|
| Apple M4 (10 cores) | 28.6 s | 14.4 s | 8.7 s | 7.1 s | 6.8 s (4.2×) | 9 MB → 283 MB |
| Linux guest (4 vCPU, HVF) | 28.0 s | 14.3 s | 8.6 s | 8.9 s | 8.6 s (3.3×) | 21 MB → 121 MB |

* **The bytes do not change.** Every `-n` gives the same sha256 on a platform,
  and the M4's is the one `cross_platform_bytes.csv2` holds for `zip`. The
  guest's archive has the same size (497,122,541 bytes) but a different
  sha256: each ZIP entry carries the Unix UID/GID extra field (0x7875), and the
  guest's corpus had a different owner here. With the owner set to 501:20 on
  both sides, `cross_platform_bytes.csv2` shows the two platforms' ZIPs
  byte-identical.
* **Two and four threads scale almost linearly; past that it flattens.** On the
  M4 only four cores are performance cores, and user CPU time rises from 28.1 s
  to 36 s once the efficiency cores join. There is also no parallelism inside
  one file, so the largest members bound the run.
* **`-n` above the core count is slower** (`-n 16`: 7.1 s on the M4, 9.3 s in
  the guest) and holds more memory.
* **Other tools on the same machine are single-threaded:** Info-ZIP `zip -r -6`
  31.2 s and `bsdtar --format zip` 30.5 s on the M4; `bsdtar` 27.9 s in the
  guest.
* **Sorting does not cost time.** `--zip-unsorted` is not faster than the
  default: 7.6 s against 6.8 s on the M4, 8.8 s against 8.6 s in the guest
  (fastest rounds).

Limits of this run: Windows was not measured, and its build has no threaded
path.

## Release 0.1.2: the four archives, each run on its own platform

[`release_0.1.2_output.txt`](release_0.1.2_output.txt) collects the verification
of the four public archives built at tag `v0.1.2` (`1290c3fe`). Each archive was
run on a machine of its own platform and architecture:

| Archive | Built on | Run on | Result |
|---|---|---|---|
| macos-arm64 | Mac M4, Swift 6.4 | Mac M4 | `release.zsh` verified; test/ 0 FAIL |
| linux-aarch64 | Mac (musl cross), Swift 6.4 | aarch64 VM, kernel 7.3 | `verify_release.zsh` VERIFIED, rc=0 |
| linux-x86_64 | Mac (musl cross), Swift 6.4 | WSL2 x86_64 | `verify_release.zsh` VERIFIED, rc=0 |
| windows-x86_64 | Windows, Swift 6.4.1 | Windows | `release.zsh` verified; crypto 51/0; test/ 737/0 |

`verify_release.zsh` checks the `.sha256`, that the binary is static, runs it
in an empty environment, round-trips a `.tar.gz`, sees LZFSE refused, and runs
`--crypto-selftest` and `-test`. The macOS and Linux builds had no warnings; the
Windows build has the same 22 linker warnings as 0.1.1.

## Release 0.1.3: the four archives, and the whole suite on each platform

[`release_0.1.3_output.txt`](release_0.1.3_output.txt) collects the verification
of the four public archives built at tag `v0.1.3` (`6b96dc37`), which adds
`-x --no-links`. Unlike 0.1.2, the whole test suite was also run at the tagged
commit on three platforms before the tag was made:

| Platform | Whole suite at `6b96dc3` | Archive | Run on | Result |
|---|---|---|---|---|
| macOS | 31 files, FAIL 0 (874 counted PASS + `record_zlib` 3/0) | macos-arm64 | Mac M4 | `release.zsh` verified |
| Windows | 31 files, 770/0 | windows-x86_64 | Windows, Swift 6.4.1 | `release.zsh` verified; crypto 51/0 |
| Linux | WSL: 31 files, 845/0 | linux-x86_64 | WSL2 x86_64 | `verify_release.zsh` VERIFIED, rc=0 |
| Linux | — | linux-aarch64 | aarch64 VM | `verify_release.zsh` VERIFIED, rc=0 |

`test_no_links` is 25/0 on all four platforms, with real symlinks on Windows.
The aarch64 VM has no Swift toolchain, so it runs the release binary rather than
the suite. The macOS and Linux builds had no warnings; the Windows build has the
same 22 linker warnings as 0.1.2. Each node then installed the published archive
(brew, scoop, `~/.local/bin` on WSL, LinuxCS's pin on the VM) and reported
`swift_tar 0.1.3 (v0.1.3 / 6b96dc37)`.

## Windows: C dependencies built with clang instead of MSVC

`zstd_bmi2_win.zsh` → `zstd_bmi2_win_output.txt`, `zstd_bmi2_win.csv2`
`win_clang_deps.zsh` → `win_clang_deps_output.txt`, `win_clang_deps.csv2`

```sh
zsh verifications/zstd_bmi2_win.zsh ../claw-code
zsh verifications/win_clang_deps.zsh ../claw-code msvc=OLD.exe zstdclang=MID.exe allclang=release/swift_tar.exe
```

Measured 2026-10-30 on a Ryzen 5 7535HS (Zen 3+, BMI2 and AVX2), Swift 6.4.1 toolchain,
claw-code (1351 MB, 5403 files), best of 5 interleaved rounds. Since then zstd, zlib and
libarchive are built with the Swift toolchain's clang/clang-cl (`build_zstd-win.zsh`,
`build_zlib-win.zsh`, `build_libarchive-win.zsh`), and `libarchive_zip_bridge.c` with clang-cl.
They build through `win_clang_cmake.zsh` with the VS build tools' nmake rather than Ninja, which
the Swift toolchain does not ship; a rebuild that way gave the same `.text`, 1,522,484 bytes.

**The premise was BMI2, and BMI2 does not happen.** zstd's `portability_macros.h` sets
`DYNAMIC_BMI2=1` for any clang, but `compiler.h` defines `TARGET_ATTRIBUTE` only under
`__GNUC__`, which clang does not define when it targets MSVC -- neither clang-cl nor the GNU
driver. The `_bmi2` copies are therefore compiled as plain x86-64: `llvm-objdump` counts 0
`shlx`/`shrx`/`bzhi` in every Windows variant except the `-mbmi2` reference (758/1299/97).
zstd's CMake also adds `-DZSTD_DISABLE_ASM` on Windows, so the BMI2 assembly Huffman decoder is
off throughout. The gain below is clang's code generation.

`zstd -b -B4M --single-thread` (libzstd alone, 4 MiB blocks as in swift_tar), relative to MSVC:

| variant | L9 compress | L9 decompress | L3 compress | L3 decompress | zstd.exe bytes |
|---|---:|---:|---:|---:|---:|
| a MSVC (before) | 44.3 MB/s | 677.4 MB/s | 180.4 MB/s | 624.7 MB/s | 653,312 |
| d clang, `-DDYNAMIC_BMI2=0` | +22.6% | +11.2% | +5.0% | +13.2% | 803,840 |
| **e clang, default (chosen)** | **+24.6%** | **+15.7%** | **+6.7%** | **+17.0%** | 856,064 |
| f clang `-mbmi2` (needs a BMI2 CPU; ceiling only) | +26.6% | +19.6% | +2.9% | +20.1% | 807,424 |

e decodes about 4 points faster than d (4.5 at level 9, 3.8 at level 3) although neither holds a BMI2 instruction; the dispatch
flag selects different code paths. Not investigated further. About one `zstd -b` run in 60
lost its compression result (`->4294967295 (x0.000), 0.00 MB/s`), on MSVC and clang builds
alike; the script retries such a run and prints each retry (1 in the recorded run).

swift_tar end to end (`win_clang_deps.zsh`), relative to the all-MSVC build:

| operation | all MSVC | zstd only clang | **all clang** |
|---|---:|---:|---:|
| tgz create | 177.8 MB/s | +0.2% | **+10.7%** |
| tgz `--cat` | 258.1 MB/s | +1.2% | **−2.0%** |
| zstd create (level 9) | 225.3 MB/s | +4.5% | **+4.7%** |
| zstd `--cat` | 515.0 MB/s | +5.0% | **+7.4%** |
| zip create | 19.3 MB/s | −0.5% | **+8.3%** |
| zip extract (writes files) | 106.4 MB/s | +0.5% | **−1.5%** |

All three builds write byte-identical `.tgz`, `.tzst` and `.zip`. zlib's deflate gains about
10% under clang and its inflate loses 1.5--2%, slower in every one of the five rounds, so that
is real rather than noise; the trade was taken for the encode gain. zstd gains far less inside
swift_tar than in `zstd -b`: compression runs on parallel chunks, and reading, tar framing and
coordination dilute the codec's share. ZIP create at 19 MB/s is single-threaded on Windows, a
separate matter.

Size: swift_tar.exe 1,619,456 → 1,767,424 bytes (+9.1%), all in `.text`. Without
`-ffunction-sections -fdata-sections` (the counterpart of the `/Gy` that MSVC's `/O2` implies)
the zstd-only build was 1,808,384; with them, 1,756,160. The rest is clang `-O3` inlining:
the zstd level is chosen at run time, so every strategy stays reachable.

Warnings: the 22 linker warnings of every earlier Windows build (LNK4217/LNK4286 x11 each) are
gone, and clang-cl showed 7 `-Wdeprecated-declarations` in `libarchive_zip_bridge.c` that cl's
`/W1` had hidden (C4996). They were fixed, not silenced: `strerror_s` behind an `error_text()`
helper, and `_wfsopen`/`_fsopen` with `_SH_DENYNO` -- not `_wfopen_s`, whose `_SH_SECURE`
denies other writers on a read-only open and would stop a file still being written from being
archived. The upstream zstd build carries 3 `-Wunused-function` warnings, left as they are.

Whole suite on the all-clang build: Windows 803/0, the same count as before the change. The
bridge is shared with the other platforms, so WSL was rebuilt with it too: no warnings, 850/0.
