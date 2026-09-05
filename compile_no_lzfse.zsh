#!/bin/zsh
# =====================================================================
# compile_no_lzfse.zsh — build the public/distributable swift_tar that
# ships NONE of the private LZFSE engine.
# compile_no_lzfse.zsh — 建置「公開／可散布」版 swift_tar，完全不含私有
# LZFSE 引擎。
#
# lzfse-cli.swift is NOT compiled in, so the resulting binary can neither
# create nor decode any LZFSE-family archive (other3 / bvx3 / bvx2). Only the
# standard external codecs (gzip / bzip2 / xz / zstd / lz4) and plain tar remain.
# 不編譯 lzfse-cli.swift，產出的 binary 既不能建立也不能解碼任何 LZFSE 家族封存
# （other3 / bvx3 / bvx2）；僅保留標準外部 codec（gzip / bzip2 / xz / zstd / lz4）
# 與純 tar。
#
# Thin wrapper over `compile_tar.zsh --no-lzfse`. Extra args pass through.
# 為 `compile_tar.zsh --no-lzfse` 的精簡包裝；額外參數會一併傳入。
#
#   ./compile_no_lzfse.zsh [args...]   build the public/distributable binary
#                                      建置公開／可散布版執行檔
#   ./compile_no_lzfse.zsh --help      print this synopsis and exit, building nothing
#                                      印出本說明後結束，不進行任何建置
# =====================================================================

# Answered here rather than passed through: --help would otherwise reach
# compile_tar.zsh and describe that script instead of this one.
# 在此回答而非傳遞下去：否則 --help 會傳到 compile_tar.zsh，說明的就是那支腳本而非本檔。
script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '3,21p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

cd "$(dirname "$0")"
exec ./compile_tar.zsh --no-lzfse "$@"
