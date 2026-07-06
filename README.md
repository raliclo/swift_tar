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
git submodule update --init   # fetch lzfse2 + libarchive
./compile_tar.sh              # → release/swift_tar
```

The build reuses `lzfse2/lzfse-cli.swift` as a library (its top-level
`runCLI()` entry point is stripped, then both files are compiled together)
and links `-lz -lbz2 -llz4 -llzma -lzstd`. The binary is emitted to
**`release/swift_tar`**.

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
tar -cf - src/ | release/swift_tar -c --xz -f src.tar.xz -    # (or pipe in)
```

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
| `--gzip`, `-z`     | zlib                             | one gzip member per chunk (pigz-style `.tar.gz`) |
| `--bzip2`, `-j`    | libbz2                           | one stream per chunk (pbzip2-style `.tar.bz2`) |
| `--xz`, `-J`       | liblzma                          | one xz stream per chunk (xz multi-stream) |
| `--zstd`           | libzstd                          | one zstd frame per chunk |
| `--lz4`            | liblz4                           | standard LZ4 frames |
| *(none)*           | —                                | plain uncompressed tar |

All standard codecs emit concatenatable streams, so `gunzip`, `bunzip2`,
`xz`, `zstd`, `lz4` and `bsdtar` decode swift_tar's output directly.

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
| `-C <dir>`  | Extract into `<dir>` |
| `-n <N>`    | In-flight parallel chunks (default 2 × cores) |
| `-v`        | Verbose (list entries / show the applied filter chain) |
| `-h`        | Help |

## Layout

```
swift_tar.swift    tar writer/reader + codecs + libarchive-style filters
compile_tar.sh     build script → release/swift_tar
release/swift_tar  compiled binary
lzfse2/            submodule — LZFSE engine (other3 / bvx3)
libarchive/        submodule — C reference for the filter model
```

## License

See [lzfse2](./lzfse2) for the compression engine's license; libarchive
retains its own (BSD-2-Clause).
