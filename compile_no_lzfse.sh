#!/bin/zsh
# =====================================================================
# compile_no_lzfse.sh — build the public/distributable swift_tar that
# ships NONE of the private LZFSE engine.
# compile_no_lzfse.sh — 建置「公開／可散布」版 swift_tar，完全不含私有
# LZFSE 引擎。
#
# lzfse-cli.swift is NOT compiled in, so the resulting binary can neither
# create nor decode any LZFSE-family archive (other3 / bvx3 / bvx2). Only the
# standard external codecs (gzip / bzip2 / xz / zstd / lz4) and plain tar remain.
# 不編譯 lzfse-cli.swift，產出的 binary 既不能建立也不能解碼任何 LZFSE 家族封存
# （other3 / bvx3 / bvx2）；僅保留標準外部 codec（gzip / bzip2 / xz / zstd / lz4）
# 與純 tar。
#
# Thin wrapper over `compile_tar.sh --no-lzfse`. Extra args pass through.
# 為 `compile_tar.sh --no-lzfse` 的精簡包裝；額外參數會一併傳入。
# =====================================================================
cd "$(dirname "$0")"
exec ./compile_tar.sh --no-lzfse "$@"
