# verifications

- **Traditional Chinese: [README.zh-TW.md](README.zh-TW.md)**

Ad-hoc measurement scripts for swift_tar behavior that isn't covered by the
main benchmark pipeline (`../../benchmark.sh` / `../../benchmark2.sh`). Results
here are exploratory—read the "Status" line on each before trusting a
conclusion.

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
