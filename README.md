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
- **C libraries used the libarchive way**: `zlib` / `libbz2` / `liblzma` /
  `libzstd` / `liblz4` supply the compression primitive; the container
  framing is assembled by swift_tar. `compress`/LZW, uudecode and the RPM
  wrapper are pure-Swift ports of libarchive's built-in filters.

## Build

Requires the Xcode toolchain (`swiftc`) and a few Homebrew libraries:

```sh
brew install lz4 xz zstd      # liblz4 / liblzma / libzstd
git submodule update --init   # fetch lzfse2 + libarchive + zlib
./compile_tar.sh              # → release/swift_tar
```

The build reuses `lzfse2/lzfse-cli.swift` as a library (its top-level
`runCLI()` entry point is stripped, then both files are compiled together)
and links `-lz -lbz2 -llz4 -llzma -lzstd`. The binary is emitted to
**`release/swift_tar`**.

### Windows

Windows requires Swift, CMake, and the Visual Studio 2022 C++ workload. The
build compiles the pinned zlib and zstd submodules as static MSVC libraries,
then links gzip and zstd directly into `swift_tar.exe`; no `zlib.dll`,
external `gzip.exe`, or per-chunk `zstd.exe` is required at runtime.

```bat
git submodule update --init
zsh ./build_zlib-win.sh
zsh ./build_zstd-win.sh
compile_tar-win.bat
```

`build_zlib-win.sh` and `build_zstd-win.sh` are dependency-maintenance steps:
each syncs its pinned gitlink, rebuilds the static library (`zs.lib` /
`zstd_static.lib`), and writes the exact tag/commit/linkage to `version.txt`.
Run them after cloning or changing either submodule. Normal
`compile_tar-win.bat` runs reuse the existing static libraries and do not invoke
CMake again. Build-version generation preserves both the `zlib_*` and `zstd_*`
provenance fields in `version.txt`, and the packaging step copies that file
into the Windows ZIP for release verification.

The remaining external codecs (bzip2, xz, lz4, lzip) require their corresponding
Scoop CLI tools; `build_tool_install-win.sh` installs the complete toolchain.

The Windows ZIP contains the statically linked executable, Swift runtime DLLs,
`version.txt`, `zlib-LICENSE.txt`, and `zstd-LICENSE.txt`. It intentionally
excludes `zs.lib`, `zstd_static.lib`, headers, and the CMake build trees
because they are development artifacts, not runtime dependencies.

## Usage

```
swift_tar -c|-x|-t|--cat [-f <archive>] [codec] [-C <dir>] [-n N] [-v] [files...]
```

| Command | Meaning |
|---------|---------|
| `-c`    | Create an archive |
| `-x`    | Extract an archive |
| `-t`    | List archive contents |
| `--cat` | Decompress the filter chain only, raw payload to stdout (≈ `bsdcat`) |

`-f -` (or omitting `-f`) reads stdin / writes stdout, so swift_tar composes
in pipelines.

### Create examples

```sh
release/swift_tar -c --bvx3-optimal -f src.tar.bvx3 src/
release/swift_tar -c --gzip         -f src.tar.gz    src/     # standard .tar.gz
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
tar stream (magic `1f 8b`), not a ZIP container. `unzip` cannot extract it;
name gzip archives `.tgz` or `.tar.gz` and extract them with `tar` or
`swift_tar`. Creating a true `.zip` archive is not currently supported.

### Extract / list (codec auto-detected)

```sh
release/swift_tar -t -f src.tar.gz
release/swift_tar -x -f src.tar.bvx3 -C /tmp/out
release/swift_tar --cat -f package.rpm > payload.cpio          # strip RPM wrapper
```

## Codec flags (create only)

Reading always auto-detects, so codec flags apply to `-c` only.

| Flag | Equivalent | Notes |
|------|------------|-------|
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

All standard codecs emit concatenatable streams, so `gunzip`, `bunzip2`,
`xz`, `lzip`, `zstd`, `lz4` and `bsdtar` decode swift_tar's output directly.

## Read filters (auto-detected, stackable)

uuencoded files (classic + base64) · files with an RPM wrapper · gzip ·
bzip2 · compress/LZW (`.Z`) · lzma · lzip · xz · lz4 · zstandard · the LZFSE
family (bvx2/bvx3, decoded with the multi-core parallel decoder).

`lzop` is detected but reports as unavailable unless `liblzo2` is present —
the same behavior as a libarchive built without lzo support.

## Options

| Option | Meaning |
|--------|---------|
| `-f <path>` | Archive file (`-` = stdin/stdout; default `-`) |
| `-C <dir>`  | Change input directory before create; extract into it when reading |
| `-n <N>`    | In-flight parallel chunks (default 2 × cores) |
| `-v`        | Verbose (list entries / show the applied filter chain) |
| `-h`        | Help |
| `--version` | Show the fixed build-date version (`yyyyMMdd-HHmmss`) |

`--version` reports the local date and time captured when the binary was
compiled, for example `swift_tar 20260712-143015`. The same value is stored as
`swift_tar_version` in the packaged `version.txt`.

## Layout

```
swift_tar.swift    tar writer/reader + codecs + libarchive-style filters
compile_tar.sh     build script → release/swift_tar
build_zlib-win.sh  sync/rebuild the pinned Windows static zlib dependency
build_zstd-win.sh  sync/rebuild the pinned Windows static zstd dependency
release/swift_tar  compiled binary
lzfse2/            submodule — LZFSE engine (other3 / bvx3)
libarchive/        submodule — C reference for the filter model
zlib/              submodule — pinned static gzip backend on Windows
zstd/              submodule — pinned static zstd backend on Windows
```

## License

See [lzfse2](./lzfse2) for the compression engine's license; libarchive and
zlib retain their own licenses.
