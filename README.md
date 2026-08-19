# swift_tar

A multi-core `tar` archiver written in Swift, built on the `lzfse2`
compression engine and modeled on **libarchive**'s filter architecture.

- **繁體中文說明： [README.zh-TW.md](./README.zh-TW.md)**
- **[FAQ.md](./FAQ.md)** — measured answers on VM cores, emulation cost, and
  whether to pack with swift_tar or bsdtar when transferring

## Highlights

- **ustar + pax** container: long paths, files > 8 GiB, symlinks, hardlink
  dedup, FIFOs (POSIX) — interoperable with `bsdtar` / GNU `tar`.
- **Multi-core compression**: the archive byte stream is split into 4 MiB
  chunks compressed concurrently and written back in order — the same
  concurrency skeleton as `lzfse2`'s `runParallelEncode`.
- **libarchive-style read filters**: the codec is auto-detected by magic
  bytes and filters stack (e.g. `payload.tar.gz.uu`).
- **True ZIP/ZIP64 backend**: the bundled libarchive creates and reads standard
  ZIP containers on macOS and Windows; ZIP64 is automatic or can be forced.
- **Authenticated encryption**: ChaCha20-Poly1305 over 4 MiB chunks, sealed
  concurrently across `-n` like the codecs, layered outside the codec so any
  archive can be encrypted. Reading detects and decrypts it automatically —
  no flag needed. Tampering, reordering and truncation are all detected.
  Pure Swift — no CryptoKit or OpenSSL.
- **C libraries used the libarchive way**: `zlib` / `libbz2` / `liblzma` /
  `libzstd` / `liblz4` supply the compression primitive; the container
  framing is assembled by swift_tar. `compress`/LZW, uudecode and the RPM
  wrapper are pure-Swift ports of libarchive's built-in filters.

## Build

Requires the Xcode toolchain (`swiftc`) and a few Homebrew libraries:

```sh
brew install lz4 xz zstd      # liblz4 / liblzma / libzstd
git submodule update --init   # fetch lzfse2 + libarchive + zlib
./build.zsh                    # → release/swift_tar
```

`build.zsh` detects the platform with `uname` and runs that platform's build —
`compile_tar.zsh` on macOS, `compile_tar-linux.zsh` on Linux,
`compile_tar-win.bat` on Windows — so the same command works on all three.
`./build.zsh --platform` prints the detected name without building. Calling the
platform script directly still works.

### Linux

`compile_tar-linux.zsh` needs a Swift toolchain and the codec headers and shared
libraries. Both are probed rather than assumed: it uses `/workspace/opt/swift`
and `/workspace/sysroot` when they exist (the buildroot aarch64 appliance under
`sos/linux_kernal_vm_interactive`), otherwise `swiftc` from `PATH` and `/usr`.
Override with `SWIFT_PREFIX` and `SYSROOT`.

Two differences from the macOS build. libarchive is linked shared from the
sysroot, because the appliance it was first proven on has no cmake; set
`LIBARCHIVE_STATIC=1` on a distro that does to build the bundled static copy
instead. And `-DEXCLUDE_LZFSE` is applied automatically when `lzfse2/` is not
checked out, so the same script serves a full clone and a source drop without a
flag.

Verified on aarch64 Linux (buildroot, glibc, Swift 6.3.3) under QEMU: builds
clean, records its RPATH, and reports its linked libraries in
`version-linux.txt`.

The build reuses `lzfse2/lzfse-cli.swift` as a library (its top-level
`runCLI()` entry point is stripped, then both files are compiled together)
and links `-lz -lbz2 -llz4 -llzma -lzstd` plus the bundled static libarchive
ZIP backend. The binary is emitted to
**`release/swift_tar`**. If the `lzfse2` submodule is missing, the build stops
with an error suggesting `git submodule update --init` or the LZFSE-free build
below.

### Public build without LZFSE

`compile_no_lzfse.zsh` (a wrapper for `compile_tar.zsh --no-lzfse`) builds a
public/distributable binary that ships **none** of the private LZFSE engine —
`lzfse-cli.swift` is not compiled in, so the binary can neither create nor decode
any LZFSE-family archive (`other3` / `bvx3` / `bvx2`) and contains no LZFSE code
or format strings. The standard external codecs (gzip / bzip2 / xz / zstd / lz4),
plain tar, and ZIP/ZIP64 are unaffected. This build does not need the `lzfse2`
submodule.

```sh
./compile_no_lzfse.zsh         # → release/swift_tar (public, LZFSE-free)
./test_no_lzfse.zsh            # verify the exclusion + standard codecs still work
```

### Windows

Windows requires Swift, CMake, and the Visual Studio 2022 C++ workload. The
build compiles the pinned zlib, zstd, and libarchive submodules as static MSVC
libraries, then links gzip, zstd, and ZIP support directly into `swift_tar.exe`; no `zlib.dll`,
external `gzip.exe`, or per-chunk `zstd.exe` is required at runtime.

```bat
git submodule update --init
zsh ./build_zlib-win.zsh
zsh ./build_zstd-win.zsh
compile_tar-win.bat
```

`build_zlib-win.zsh` and `build_zstd-win.zsh` are dependency-maintenance steps:
each syncs its pinned gitlink, rebuilds the static library (`zs.lib` /
`zstd_static.lib`), and writes the exact tag/commit/linkage to
`version-win.txt`.
Run them after cloning or changing either submodule. Normal
`compile_tar-win.bat` rebuilds the incremental libarchive backend and reuses the
existing zlib/zstd libraries. Build-version generation preserves the `zlib_*`, `zstd_*`, and `libarchive_*`
provenance fields in `version-win.txt`, and the packaging step copies that file
into the Windows ZIP as `version.txt` for release verification.

The stamp file is suffixed by platform — `version-mac.txt`, `version-linux.txt`,
`version-win.txt` — because it records which libraries *this* build linked
against. A single shared file meant whichever platform built last overwrote the
other's provenance.

The remaining external codecs (bzip2, xz, lz4, lzip) require their corresponding
Scoop CLI tools; `build_tool_install-win.zsh` installs the complete toolchain.

The Windows ZIP contains the statically linked executable, Swift runtime DLLs,
`version.txt` (staged from `version-win.txt`), `zlib-LICENSE.txt`, `zstd-LICENSE.txt`, and
`libarchive-COPYING.txt`. It intentionally
excludes `zs.lib`, `zstd_static.lib`, headers, and the CMake build trees
because they are development artifacts, not runtime dependencies.

## Usage

```
swift_tar -c|-x|-t|-r|-u|--delete|--identify|--cat|--encrypt-only|--decrypt-only
          [-f <archive>] [codec]
          [--encrypt|--keyfile <path>] [-C <dir>] [--strip-components N] [-n N] [-v] [files...]
```

| Command | Meaning |
|---------|---------|
| `-c`    | Create an archive |
| `-x`    | Extract an archive (decrypts automatically if encrypted) |
| `-t`    | List archive contents (decrypts automatically if encrypted) |
| `-r`    | Append files to the end of an archive (uncompressed tar only) |
| `-u`    | Append files newer than the archived copy, or not yet present (uncompressed tar only) |
| `--delete` | Remove named members from an archive in place (uncompressed tar only; swift_tar-only — BSD tar has no `--delete`) |
| `--identify` | Detect the compression format by magic bytes and print the filter chain (e.g. `gzip → tar`), then stop — no extraction. Works on any filename |
| `--cat` | Decrypt and decompress the filter chain only, raw payload to stdout (≈ `bsdcat`) |
| `--encrypt-only` | Encrypt the `-f` file as-is (no tar, no codec) to stdout |
| `--decrypt-only` | Strip only the encryption layer from `-f` to stdout; a compressed payload stays compressed |
| `--rgb1-pack` / `--rgb1-info` / `--rgb1-raw` | RGB1 raw image container: wrap raw RGB bytes with a header, print its fields, or strip it back to the raw payload |

`-f -` (or omitting `-f`) reads stdin / writes stdout, so swift_tar composes
in pipelines.

### Create examples

```sh
release/swift_tar -c --bvx3-optimal -f src.tar.bvx3 src/
release/swift_tar -c --gzip         -f src.tar.gz    src/     # standard .tar.gz
release/swift_tar -c --zip          -f src.zip       src/     # standard ZIP
release/swift_tar -c --zip64        -f src.zip       src/     # force ZIP64 records
release/swift_tar -c --zstd -f src.tar.zst -C /path/to parent-leaf
tar -cf - src/ | release/swift_tar -c --xz -f src.tar.xz -    # (or pipe in)
```

For create mode, `-C <dir>` changes the input working directory before the
listed leaf paths are archived, matching system tar. The archive named by a
relative `-f` path is still created relative to the original invocation
directory. Using `-C <parent> <leaf>` keeps parent paths and `..` out of archive
entry names.

The two sides of `-C` treat a missing directory differently:

| mode | `-C` target does not exist | |
|---|---|---|
| extract (`-x`) | **created, including intermediate levels**, then extracted into | exit 0 |
| create (`-c`) | refused: `cannot chdir to '<dir>'` | exit 1 |

Because extraction creates the directory rather than failing, a mistyped `-C`
path produces a new tree at the mistyped location and exits 0. Check the
directory yourself before extracting if your script needs to catch that.

The output format is selected by the codec flag, not by the filename
extension. For example, `--gzip -f archive.zip` still writes a gzip-compressed
tar stream (magic `1f 8b`), not a ZIP container. Use `--zip` for a true ZIP;
libarchive automatically emits ZIP64 when required, while `--zip64` forces
ZIP64 records for compatibility testing or explicit format selection.

### Encryption and decryption

`--encrypt` encrypts the archive with **ChaCha20-Poly1305**. The layer sits
*outside* the compression codec, so any **tar** codec — or plain tar — can be
encrypted, and the codec inside is still auto-detected on the way out.

**`--zip` and `--zip64` cannot be encrypted.** Encryption applies to the tar
codecs only. Combining it with ZIP output is refused:

```sh
release/swift_tar -c --zip --encrypt -f out.zip src/
# -> Error: --encrypt is not supported for ZIP output ...   exit 1, no file written
```

Encrypt with a tar codec instead (`--zstd`, `--gzip`, or plain tar).

```sh
release/swift_tar -c --encrypt        -f secret.tar.enc src/   # prompts for a passphrase
release/swift_tar -c --encrypt --gzip -f secret.tgz.enc src/   # encrypted .tar.gz
release/swift_tar -c --keyfile k.bin  -f secret.tar.enc src/   # key from a file
```

#### Decrypting

**There is no `--decrypt` flag, because none is needed.** Reading detects the
encryption by magic and decrypts automatically, exactly like it auto-detects
gzip or zstd. Supply the key and use whichever read mode you already wanted:

| Command | What you get |
|---------|--------------|
| `-x` | Files extracted (decrypt → decompress → untar) |
| `-t` | Entry listing |
| `--cat` | Raw payload on stdout (decrypt **and** decompress) |
| `--decrypt-only` | The still-compressed archive on stdout (decrypt only) |
| `--identify` | The filter chain and tar/raw type; for encrypted input, decrypts only enough data to identify inner filters and payload type, without extracting files |

```sh
release/swift_tar -x -f secret.tar.enc -C /tmp/out      # prompts for the passphrase
release/swift_tar -t --keyfile k.bin -f secret.tar.enc  # key from a file
release/swift_tar --identify --keyfile k.bin -f secret.tgz.enc
#   secret.tgz.enc: encrypted (ChaCha20-Poly1305) → gzip → tar
```

A wrong key, tampering, or truncation makes the command fail with a non-zero
exit status. Decryption is streaming: plaintext chunks that authenticated
before a later failure may already have reached stdout or the extraction
directory. Treat all output from a failed command as incomplete and discard it.

#### Encrypting or decrypting without repacking

`--decrypt-only` strips **just** the encryption layer, leaving the payload
compressed, and `--encrypt-only` encrypts an existing file as-is. Both take the
input with `-f` and write to stdout, like `--cat`:

```sh
swift_tar --decrypt-only --keyfile k.bin -f secret.tgz.enc > secret.tar.gz
swift_tar --encrypt-only --keyfile k.bin -f archive.tar.gz > archive.tgz.enc
```

Use `--cat` instead when you want the compression undone as well — it returns
the raw tar, whereas `--decrypt-only` hands back a still-valid `.tar.gz`.

#### Keys

A passphrase is read from the terminal without echo (so it never reaches the
shell history) and is confirmed on create; it is stretched with **scrypt**
(N=2¹⁵, r=8, p=1). `--keyfile <path>` uses the file's bytes as key material
instead and is **required when stdin is not a terminal**, such as in a
pipeline — swift_tar refuses to write an archive it cannot key rather than
silently leaving it unencrypted.

A keyfile has **no format requirement**: text or binary, any length, and the
bytes are used exactly as they are. Only an empty file is rejected. Two
consequences are worth knowing:

- **A trailing newline is part of the key.** `printf 'secret' > k` and
  `echo secret > k` produce *different* keys. Generate keyfiles instead of
  typing them: `head -c 64 /dev/urandom > k.bin && chmod 600 k.bin`.
- **`--keyfile` does not run the KDF**, because the material is assumed to be
  high-entropy. Do not put a short human-chosen password in a keyfile — use
  `--encrypt` so it goes through scrypt.

**What the format protects against.** Each 4 MiB chunk is sealed separately,
and every chunk's AAD binds the full header plus the chunk index, with an
authenticated end-of-stream marker:

| Attack | Detected by |
|--------|-------------|
| Modified ciphertext | per-chunk Poly1305 tag |
| Modified header (salt, KDF cost) | whole header is part of every chunk's AAD |
| Reordered or duplicated chunks | chunk index in the AAD and the nonce |
| Truncated archive | authenticated final marker must be present |

A wrong key, any tampering, or a truncated file makes the command fail with a
non-zero exit status; it never returns partial plaintext as if it were valid.

`-r`, `-u` and `--delete` do not apply to encrypted archives.

The primitives are implemented from the specifications and checked against
their published test vectors (RFC 8439, RFC 4231, RFC 7914, FIPS 180-4).
Run them with `--crypto-selftest`, or the full suite with `./test_encrypt.zsh`.
On Windows/MSYS, `verifications/encrypt_windows_correctness.zsh` reruns the
self-test and a CLI smoke suite against `release/swift_tar.exe`; use
`verifications/encrypt_mbps_win.zsh` for Windows MB/s throughput.

### Append / update / delete

```sh
release/swift_tar -r -f archive.tar -C src newfile      # append newfile
release/swift_tar -u -f archive.tar -C src src/         # append only newer/absent members
release/swift_tar --delete -f archive.tar old.txt dir/  # remove members in place
```

`-r`, `-u`, and `--delete` operate on **uncompressed** tar only — the codec flag
is rejected and a compressed `-f` archive is refused. No mainstream tar (GNU,
BSD/libarchive, star) supports these on compressed archives either, for the same
reason: the trailing EOF lives inside the final compressed frame, so a cheap
seek-and-append is impossible. All three need a seekable `-f` archive (not
stdin/stdout).

- `-r` (append): a missing archive is created (GNU tar semantics).

**A missing `-f` archive is created by the two appending modes and refused by the
rest**, so which mode you are in decides whether a typo in the archive path is
caught:

| mode | `-f` archive does not exist |
|---|---|
| `-r`, `-u` | created, then the members are appended — exit 0 |
| `--delete`, `-t`, `-x` | refused: `cannot open '<path>'` — exit 1 |

For `-u` this follows from its own rule rather than being a special case: it
appends members that are newer *or absent*, and in an archive that does not exist
yet every member is absent.
- `-u` (update): appends a member only when it is newer than the archived copy
  (or absent), never rewriting or deleting the old entry — extraction takes the
  last copy.
- `--delete`: rewrites the archive without the named members (matching entry by
  name, directory names with or without a trailing `/`). This is a swift_tar
  extension — BSD tar, the `tar` shipped with macOS, has no `--delete`.

Duplicate member names are legal in a tar archive and both `-r` and `-u` can
create them. Two rules follow, and neither depends on how the duplicate arose:

- **Extraction takes the last copy.** `-r` appends unconditionally, so appending
  a name that already exists leaves two entries in the listing and extracts the
  newer one.
- **`--delete` removes every copy of the name, not just one.** Deleting `a.txt`
  from an archive holding two `a.txt` entries leaves neither.

### Extract / list (codec auto-detected)

```sh
release/swift_tar -t -f src.tar.gz
release/swift_tar -t -f src.zip
release/swift_tar -x -f src.tar.bvx3 -C /tmp/out
release/swift_tar --cat -f package.rpm > payload.cpio          # strip RPM wrapper
```

**Two members of one archive may not land on the same file.** An archive written
on a case-sensitive filesystem can hold `file.txt` and `File.txt`; on a
destination that does not distinguish case the second would destroy the first.
That is refused:

```sh
release/swift_tar -x -f from-linux.tar
# -> 'File.txt' would overwrite 'file.txt', written earlier in this archive
#    (the destination does not distinguish case); pass --force to allow it
```

`--force` restores the overwrite. A file already on disk from a *previous* run is
overwritten as usual — this covers only collisions inside one extraction. The
same name appearing twice in an archive is legal and unaffected: the last copy
wins, as documented above.

**Extraction stays inside `-C`.** A member name is treated as hostile, because an
archive need not have been written by this tool:

| member name in the archive | what happens |
|---|---|
| `../../x`, `dir/../../x`, `..\..\x` | entry skipped: `skipping unsafe path '<name>'` |
| `/etc/x`, `C:\Windows\x` | leading `/` and any drive letter dropped; written **inside** the destination |
| a member whose path runs through a symlink an earlier entry created | entry skipped: `path passes through a symlink` |

That last row is a separate attack from the first: an archive can carry a symlink
`portal -> ../../..` and then a member `portal/pwned.txt`, and neither name
contains `..` once the link is resolved. Symlinks that do not lead out of the
extraction target are unaffected and extract normally.

Nothing an archive can name will be written above the extraction directory. Note
that a skipped entry does not change the exit code — the run still ends 0 — so a
script extracting an untrusted archive should read stderr, or compare the
extracted tree against `-t`, rather than trusting the status alone.

**Which entry types are stored and restored.** Regular files, directories,
symlinks, hardlinks and FIFOs. A FIFO is included because `mkfifo` needs no
privilege on any POSIX system, so the entry can always be restored — and it
costs nothing: it is one `mknod`, marginally cheaper than an empty regular
file. Device nodes and sockets are not: the first needs root, and a socket
cannot be meaningfully recreated from an archive. Either is reported and
skipped:

```sh
release/swift_tar -c -f out.tar /dev/null
# -> swift_tar: skipping special file '/dev/null'
```

On Windows a FIFO member is named on stderr and skipped, because the platform
has no FIFOs. **The exit code does not change** — an archive holding a pipe is
an ordinary archive, and everything else in it extracts normally:

```sh
release/swift_tar -x -f from-linux.tar -C out
# -> swift_tar: skipping FIFO 'pipe': Windows has no FIFOs
# -> exit 0, every other member extracted
```

**Extracting over an existing tree replaces what it finds.** Re-running an
extraction to refresh a directory is a normal thing to do, and the destination is
rarely pristine:

| what is already at the destination | what happens |
|---|---|
| a writable regular file | overwritten |
| a read-only file (`chmod 444`, or the Windows read-only attribute) | overwritten — permission to replace a file comes from its directory, not from the file |
| a FIFO, socket, or device node | removed, then the member is written in its place |
| a symlink | removed, **not** followed — the member is never written through it to the link's target |
| a plain file, where the archive holds a **directory** of that name | removed, and the directory created in its place — a `config` file becoming a `config/` directory is an ordinary event, and GNU tar and bsdtar both do the same |
| a directory, where the archive holds a **file** of that name | that member fails; the rest of the archive still extracts, and the run ends non-zero |

Only the last row stops anything, and it stops only that member. A member that
cannot be written is named on stderr; the others still land. Note that `-v`
lists members as it processes them, so a failing member appears in the `-v`
output too — read stderr and the exit status to tell what was actually written,
not the `-v` list alone.

### Identify an unknown file

Reading never looks at the extension — the codec is auto-detected by magic
bytes. `--identify` exposes that detection as a `file`-like report without
extracting anything, and it also reads from stdin:

```sh
release/swift_tar --identify -f mystery.bin     # e.g. "mystery.bin: gzip → tar"
cat mystery.bin | release/swift_tar --identify  # "<stdin>: gzip → tar"
```

On a normal read, `-v` prints the same detection, on stderr, in the bilingual
form the rest of the tool uses:

```
swift_tar: compression format / 壓縮格式：gzip
swift_tar: compression format / 壓縮格式：none
```

Grep for `compression format`, not for `compression format: gzip` — the value
follows a full-width colon after the Chinese half of the label.

**ZIP is the exception**: `-v` prints no such line for a ZIP archive, because
ZIP is a container rather than a filter over tar. Use `--identify`, which does
report `zip`.

### RGB1 raw image container

`--rgb1-pack` wraps a raw RGB byte stream in a header carrying image dimensions,
a WGS84 location and provenance metadata. `--rgb1-info` prints those fields back;
`--rgb1-raw` strips the header and writes the original payload to stdout.

**`--rgb1-pack` requires ten metadata flags.** There are no defaults for them —
omit any one and the command fails with `Missing RGB1 argument ...` and exit 1.

```sh
release/swift_tar --rgb1-pack \
  --width 4 --height 4 \
  --lat 25.0330 --lng 121.5654 --height-m 12.5 \
  --title "test tile" --country "Taiwan" \
  --creator-email "you@example.com" --right "CC" \
  --created-ms 1755500000000 \
  -f out.rgb1 raw.rgb

release/swift_tar --rgb1-info -f out.rgb1     # prints the fields below
release/swift_tar --rgb1-raw  -f out.rgb1 > back.rgb   # byte-identical to raw.rgb
```

| flag | type / range | notes |
|---|---|---|
| `--width <W>` | UInt32 pixels | required |
| `--height <H>` | UInt32 pixels | required |
| `--lat <deg>` | WGS84 degrees, −90…90 | required; negative values are fine |
| `--lng <deg>` | WGS84 degrees, −180…180 | required; negative values are fine |
| `--height-m <m>` | metres | required; **stored in the header as millimetres** |
| `--title <text>` | ASCII, at most 64 bytes | required |
| `--country <text>` | ASCII, at most 512 bytes | required |
| `--creator-email <email>` | ASCII, at most 254 bytes | required |
| `--right <text>` | 1–4 English letters | required |
| `--created-ms <unix_ms>` | Int64, UTC Unix milliseconds | required |
| `--tz-offset-min <minutes>` | Int16 | **optional**, default `480` (Taiwan) |

The positional argument is the raw input, and `-f` names the output — the reverse
of the roles they play in `-x`. `--rgb1-info` reports `format`, `width`, `height`,
`latitude`, `longitude`, `height_m`, `geo_datum_code`, `title`, `country`,
`creator_email`, `right`, `created_unix_ms`, `timezone_offset_minutes` and
`payload_bytes`. Verified round-trip: a 48-byte payload packed with the command
above produced a 924-byte container, and `--rgb1-raw` returned the payload
`cmp`-identical.

## Codec flags (create only)

Reading files always auto-detects. `--zip` may also be supplied when ZIP input
comes from stdin, where probing without consuming input is not possible.

**At most one flag from this table.** Two different ones are rejected with
`at most one codec flag`, exit 1, and no output file. Repeating the same flag
(`--gzip --gzip`) is accepted. Note that this makes **`--zip64` a codec in its own
right, not a modifier for `--zip`** — `--zip --zip64` is a conflict and is
refused, so pass `--zip64` on its own.

| Flag | Equivalent | Notes |
|------|------------|-------|
| `--zip`             | libarchive ZIP                   | Deflate; ZIP64 automatic when required |
| `--zip64`           | libarchive ZIP64                 | Deflate; forces ZIP64 records |
| `--other3-fast`    | `lzfse -algo other3`             | standard bvx2, Apple-decodable |
| `--other3-optimal` | `lzfse -algo other3 -optimal3`   | price-driven DP, still standard bvx2 |
| `--bvx3-fast`      | `lzfse -algo bvx3`               | private big-alphabet blocks (this tool only) |
| `--bvx3-optimal`   | `lzfse -algo bvx3 -optimal`      | best ratio, slowest |
| `--gzip`, `-z`     | zlib                             | one gzip member per chunk (pigz-style `.tar.gz`; not ZIP) |
| `--bzip2`, `-j`    | libbz2                           | one stream per chunk (pbzip2-style `.tar.bz2`) |
| `--xz`, `-J`       | liblzma                          | one xz stream per chunk (xz multi-stream) |
| `--lzip`           | lzip CLI                         | one lzip stream per chunk |
| `--zstd`           | libzstd                          | one zstd frame per chunk |
| `--lz4`            | liblz4                           | standard LZ4 frames |
| *(none)*           | —                                | plain uncompressed tar |

The tar compression codecs emit concatenatable streams, so `gunzip`, `bunzip2`,
`xz`, `lzip`, `zstd`, and `lz4` decode those outputs directly. ZIP/ZIP64 is a
container backend and interoperates with `unzip`, `bsdtar`, and other ZIP tools.

## Read filters (auto-detected, stackable)

uuencoded files (classic + base64) · files with an RPM wrapper · gzip ·
bzip2 · compress/LZW (`.Z`) · lzma · lzip · xz · lz4 · zstandard · the LZFSE
family (bvx2/bvx3, decoded with the multi-core parallel decoder) ·
swift_tar's own encryption layer (decrypted first, then the codec inside it is
detected as usual).

`lzop` is detected but reports as unavailable unless `liblzo2` is present —
the same behavior as a libarchive built without lzo support.

## Options

**`--` ends the options.** Everything after it is treated as a file name, which
is how you archive a name that begins with a dash:

```sh
swift_tar -c -f out.tar -- -report.csv notes.txt   # archives -report.csv
swift_tar -c -f out.tar ./-report.csv              # also works, without --
swift_tar -c -f out.tar -report.csv                # rejected: read as short flags
```

Without `--`, a leading dash is read as a cluster of short options, so
`-report.csv` reports `unknown option -e` — a flag this tool does not have. Names
beginning with a dash arrive by ordinary means: downloads, extraction from someone
else's archive, generated report names.

**Repeat an option and the first occurrence wins**, not the last. This is the
opposite of the usual convention, and it applies to every option that takes a
value, not just one of them:

```sh
swift_tar -c -f out.tar -C c1 -C c2 f.txt        # archives c1/f.txt
swift_tar -c --zstd --zstd-level 1 --zstd-level 19 ...   # compresses at level 1
swift_tar -c -f first.tar -f second.tar ...      # writes first.tar; second.tar is not created
```

Nothing is reported when a later occurrence is dropped — the command exits 0 and
produces an archive built from the earlier value. A duplicate introduced by
editing a long command line, or by a script that appends a flag to an existing
argument list, therefore takes effect silently and in the direction most people
would not predict.

| Option | Meaning |
|--------|---------|
| `-f <path>` | Archive file (`-` = stdin/stdout; default `-`) |
| `-C <dir>`  | Change input directory before create (must exist); extract into it when reading (created if missing) |
| `--strip-components <N>` | (`-x` tar extraction only) Remove N leading path components before writing entries; also accepts `--strip-components=N` |
| `--zstd-level <N>` | (`--zstd` only) Compression level, `1`…`22`, default `9`. Out of range or non-numeric exits **2**. Silently ignored if `--zstd` is not also given — see below |
| `-n <N>`    | In-flight parallel chunks (default: one per core, capped at 4 × cores) |
| `-v`        | Verbose (list entries / show the applied filter chain) |
| `--touch`   | (`-x` only) Do **not** restore the archived mtime; extracted files get the current time |
| `-i`, `--ignore-zeros` | (`-x`, `-t`) Read past the zero blocks that end an archive, so concatenated archives are read as one |
| `-o`, `--no-same-owner` | Accepted for `tar` compatibility and does nothing: swift_tar never restores ownership, with or without it |
| `--encrypt` | (`-c` only) Encrypt with ChaCha20-Poly1305; prompts for a passphrase |
| `--keyfile <path>` | Use the file's bytes as key material instead of a passphrase (create and read; required when stdin is not a terminal) |
| `--force`   | (`-x` only) Allow a member to overwrite one written earlier in the *same* extraction; without it that case is refused |
| `-h`        | Help |
| `--version` | Show the fixed build-date version (`yyyyMMdd-HHmmss`) |
| `--crypto-selftest` | Run the crypto unit tests (published vectors, header parsing, chunk framing), then exit |

`--zstd-level` is honoured only when `--zstd` is also given. On its own it is
accepted and writes a plain uncompressed tar, the level discarded. Check with
`--identify`: an archive built by `-c --zstd-level 9 -f out.tar dir` reports
`tar`, not `zstd → tar`. See [Exit status](#exit-status) for what the codes mean.

### Which way `-f` points

`-f` names the archive, but whether that archive is being read or written is
decided by the command, not by `-f`:

| Command | `-f` is the |
|---|---|
| `-c`, `--rgb1-pack` | **output** — the file being written |
| `-x`, `-t`, `--cat`, `--identify`, `--encrypt-only`, `--decrypt-only`, `--rgb1-info`, `--rgb1-raw` | **input** — the file being read |
| `-r`, `-u`, `--delete` | **both** — modified in place |

This catches people out on `--rgb1-pack`, which sits next to `--encrypt-only`
and `--decrypt-only` in the table above but points the other way: those two read
`-f` and write to stdout, whereas `--rgb1-pack` *writes* `-f`.

`--version` reports the local date and time captured when the binary was
compiled, for example `swift_tar 20260712-143015`. The same value is stored as
`swift_tar_version` in the packaged `version.txt`.

## Reproducible output

**Nothing about how swift_tar runs changes the bytes it writes** — not the
parallelism, not the run. What does change them is the metadata tar stores, and
**file mtimes are part of that**:

```sh
# same content, same name, same permissions -- only mtime differs
swift_tar -c -f a.tar -C a f.txt
swift_tar -c -f b.tar -C b f.txt
cmp a.tar b.tar     # -> differ at byte 138
```

Since tar headers carry each file's mtime, that timestamp is part of the input.
**A `git clone`, an extracted tarball or a CI checkout sets mtimes to the time of
the operation**, so two machines archiving byte-identical trees still produce
different archives. There is no `--mtime` flag and `SOURCE_DATE_EPOCH` is not
consulted; normalise the timestamps yourself if you need checksums to match
across machines.

With the timestamps held fixed, the guarantee below holds. Measured on a 12 MB
corpus spanning three 4 MiB chunks:

| what | reproducible? |
|---|---|
| plain tar and every stream codec (`--zstd`, `--gzip`, `--xz`, `--bzip2`, `--lz4`) | **yes**, across runs |
| the same, across `-n 1`, `2`, `4`, `8`, `16` | **yes** — parallelism does not change a byte |
| `--encrypt` | **no, by design** — a fresh nonce each run; the decrypted plaintext is identical |
| `--zip` | no — the ZIP container records its own timestamps |

The `-n` result is the useful one: chunking is deterministic, not merely
reassembled in the right order, so an archive built with `-n 16` on one machine
matches one built with `-n 1` on another. Encryption is deliberately the
exception — an encrypted archive that did not change between runs would mean a
reused nonce.

## Exit status

**Test for zero versus non-zero. Do not branch on a particular non-zero value** —
which one you get is not a stable interface and may change between builds.

| status | meaning |
|---|---|
| `0` | the requested operation completed |
| non-zero | it did not; the reason goes to stderr |

**A non-zero exit does not mean nothing was written.** Work is streamed, not
staged, so whatever completed before the failure stays on disk:

```sh
swift_tar -c -f mixed.tar tree/a.txt tree/typo.txt tree/sub/b.txt
# -> cannot stat 'tree/typo.txt', exit 1
# -> mixed.tar exists, is a valid readable tar, and contains ONLY tree/a.txt.
#    tree/sub/b.txt was never reached and is silently absent.
```

Measured behaviour on failure:

| case | left behind |
|---|---|
| create, bad path among good ones | a valid archive holding the entries processed before it |
| create, bad path first | the archive file, empty (0 bytes) |
| extract, archive truncated mid-stream | the entries already extracted, complete; the member the cut fell inside is not created at all, so no half-written file is left |
| create or extract rejected before any work (unknown option, missing archive, wrong key) | nothing |

`-f` is opened once the run is under way, so **a failed create destroys whatever
archive was already at that path.** Measured: a 365,568-byte archive re-created
with a mistyped input path became 0 bytes, exit 1. The exception is a failure
caught during option validation, which happens before `-f` is opened — an unknown
flag leaves the previous archive intact.

**Treat a non-zero exit as "the output is undefined": delete it and start over.
Never read it as "the output is untouched".** If the previous archive has to
survive a failed run, write to a temporary path and move it into place only after
a zero exit.

Two cases deserve their own line because a script will otherwise get them wrong:

- **`--identify` exits `0` even when it cannot identify the input.** It prints
  `<file>: unrecognized (not tar)` and succeeds, in the same spirit as `file`.
  Only an unreadable file makes it fail. So `swift_tar --identify -f x && ...`
  does **not** mean "x is an archive" — match the printed text if that is what
  you need to know.
- **`-x` with `-C` pointing at a missing directory exits `0`** and creates the
  directory. See the `-C` table above.

## Layout

```
swift_tar.swift    tar writer/reader + codecs + libarchive-style filters
crypto.swift       ChaCha20-Poly1305 / scrypt + the encrypted container
rgb1.swift         RGB1 raw image container
build.zsh           platform-detecting entry point → the build below
compile_tar.zsh     macOS build script → release/swift_tar
compile_tar-linux.zsh  Linux build script → release/swift_tar
platform.zsh        sourced: the one place the platform suffix is decided
version-mac.txt / version-linux.txt / version-win.txt   per-platform build stamp + linkage provenance
build_libarchive.zsh / build_libarchive-win.zsh  static ZIP backend builds
libarchive_zip_bridge.c  shared macOS/Windows ZIP C ABI
build_zlib-win.zsh  sync/rebuild the pinned Windows static zlib dependency
build_zstd-win.zsh  sync/rebuild the pinned Windows static zstd dependency
release/swift_tar  compiled binary
lzfse2/            submodule — LZFSE engine (other3 / bvx3)
libarchive/        submodule — active static ZIP/ZIP64 backend
zlib/              submodule — pinned static gzip backend on Windows
zstd/              submodule — pinned static zstd backend on Windows
```

## License

See [lzfse2](./lzfse2) for the compression engine's license; libarchive and
zlib retain their own licenses.
