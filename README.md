# swift_tar

A multi-core `tar` archiver written in Swift, built on the `lzfse2`
compression engine and modeled on **libarchive**'s filter architecture.

- **繁體中文說明： [README.zh-TW.md](./README.zh-TW.md)**

## Highlights

- **ustar + pax** container: long paths, files > 8 GiB, symlinks, hardlink
  dedup — interoperable with `bsdtar` / GNU `tar`.
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
./build.sh                    # → release/swift_tar
```

`build.sh` detects the platform with `uname` and runs that platform's build —
`compile_tar.sh` on macOS, `compile_tar-linux.sh` on Linux,
`compile_tar-win.bat` on Windows — so the same command works on all three.
`./build.sh --platform` prints the detected name without building. Calling the
platform script directly still works.

### Linux

`compile_tar-linux.sh` needs a Swift toolchain and the codec headers and shared
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

`compile_no_lzfse.sh` (a wrapper for `compile_tar.sh --no-lzfse`) builds a
public/distributable binary that ships **none** of the private LZFSE engine —
`lzfse-cli.swift` is not compiled in, so the binary can neither create nor decode
any LZFSE-family archive (`other3` / `bvx3` / `bvx2`) and contains no LZFSE code
or format strings. The standard external codecs (gzip / bzip2 / xz / zstd / lz4),
plain tar, and ZIP/ZIP64 are unaffected. This build does not need the `lzfse2`
submodule.

```sh
./compile_no_lzfse.sh         # → release/swift_tar (public, LZFSE-free)
./test_no_lzfse.sh            # verify the exclusion + standard codecs still work
```

### Windows

Windows requires Swift, CMake, and the Visual Studio 2022 C++ workload. The
build compiles the pinned zlib, zstd, and libarchive submodules as static MSVC
libraries, then links gzip, zstd, and ZIP support directly into `swift_tar.exe`; no `zlib.dll`,
external `gzip.exe`, or per-chunk `zstd.exe` is required at runtime.

```bat
git submodule update --init
zsh ./build_zlib-win.sh
zsh ./build_zstd-win.sh
compile_tar-win.bat
```

`build_zlib-win.sh` and `build_zstd-win.sh` are dependency-maintenance steps:
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
Scoop CLI tools; `build_tool_install-win.sh` installs the complete toolchain.

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

The output format is selected by the codec flag, not by the filename
extension. For example, `--gzip -f archive.zip` still writes a gzip-compressed
tar stream (magic `1f 8b`), not a ZIP container. Use `--zip` for a true ZIP;
libarchive automatically emits ZIP64 when required, while `--zip64` forces
ZIP64 records for compatibility testing or explicit format selection.

### Encryption and decryption

`--encrypt` encrypts the archive with **ChaCha20-Poly1305**. The layer sits
*outside* the compression codec, so any codec — or plain tar — can be
encrypted, and the codec inside is still auto-detected on the way out.

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
Run them with `--crypto-selftest`, or the full suite with `./test_encrypt.sh`.
On Windows/MSYS, `verifications/encrypt_windows_correctness.sh` reruns the
self-test and a CLI smoke suite against `release/swift_tar.exe`; use
`verifications/encrypt_mbps_win.sh` for Windows MB/s throughput.

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
- `-u` (update): appends a member only when it is newer than the archived copy
  (or absent), never rewriting or deleting the old entry — extraction takes the
  last copy.
- `--delete`: rewrites the archive without the named members (matching entry by
  name, directory names with or without a trailing `/`). This is a swift_tar
  extension — BSD tar, the `tar` shipped with macOS, has no `--delete`.

### Extract / list (codec auto-detected)

```sh
release/swift_tar -t -f src.tar.gz
release/swift_tar -t -f src.zip
release/swift_tar -x -f src.tar.bvx3 -C /tmp/out
release/swift_tar --cat -f package.rpm > payload.cpio          # strip RPM wrapper
```

### Identify an unknown file

Reading never looks at the extension — the codec is auto-detected by magic
bytes. `--identify` exposes that detection as a `file`-like report without
extracting anything, and it also reads from stdin:

```sh
release/swift_tar --identify -f mystery.bin     # e.g. "mystery.bin: gzip → tar"
cat mystery.bin | release/swift_tar --identify  # "<stdin>: gzip → tar"
```

On a normal read, `-v` prints the same detection (`compression format: gzip`,
or `none` when the archive is uncompressed).

## Codec flags (create only)

Reading files always auto-detects. `--zip` may also be supplied when ZIP input
comes from stdin, where probing without consuming input is not possible.

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

| Option | Meaning |
|--------|---------|
| `-f <path>` | Archive file (`-` = stdin/stdout; default `-`) |
| `-C <dir>`  | Change input directory before create; extract into it when reading |
| `--strip-components <N>` | (`-x` tar extraction only) Remove N leading path components before writing entries; also accepts `--strip-components=N` |
| `-n <N>`    | In-flight parallel chunks (default: one per core, capped at 4 × cores) |
| `-v`        | Verbose (list entries / show the applied filter chain) |
| `--encrypt` | (`-c` only) Encrypt with ChaCha20-Poly1305; prompts for a passphrase |
| `--keyfile <path>` | Use the file's bytes as key material instead of a passphrase (create and read; required when stdin is not a terminal) |
| `-h`        | Help |
| `--version` | Show the fixed build-date version (`yyyyMMdd-HHmmss`) |
| `--crypto-selftest` | Run the crypto unit tests (published vectors, header parsing, chunk framing), then exit |

`--version` reports the local date and time captured when the binary was
compiled, for example `swift_tar 20260712-143015`. The same value is stored as
`swift_tar_version` in the packaged `version.txt`.

## Layout

```
swift_tar.swift    tar writer/reader + codecs + libarchive-style filters
crypto.swift       ChaCha20-Poly1305 / scrypt + the encrypted container
rgb1.swift         RGB1 raw image container
build.sh           platform-detecting entry point → the build below
compile_tar.sh     macOS build script → release/swift_tar
compile_tar-linux.sh  Linux build script → release/swift_tar
platform.sh        sourced: the one place the platform suffix is decided
version-mac.txt / version-linux.txt / version-win.txt   per-platform build stamp + linkage provenance
build_libarchive.sh / build_libarchive-win.sh  static ZIP backend builds
libarchive_zip_bridge.c  shared macOS/Windows ZIP C ABI
build_zlib-win.sh  sync/rebuild the pinned Windows static zlib dependency
build_zstd-win.sh  sync/rebuild the pinned Windows static zstd dependency
release/swift_tar  compiled binary
lzfse2/            submodule — LZFSE engine (other3 / bvx3)
libarchive/        submodule — active static ZIP/ZIP64 backend
zlib/              submodule — pinned static gzip backend on Windows
zstd/              submodule — pinned static zstd backend on Windows
```

## License

See [lzfse2](./lzfse2) for the compression engine's license; libarchive and
zlib retain their own licenses.
