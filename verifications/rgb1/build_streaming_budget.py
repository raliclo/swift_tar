#!/usr/bin/env python3
# =====================================================================
# build_streaming_budget.py -- assemble streaming_budget.csv, one row per step
# of the swift_tar -> wire -> swift_tar -> P6 pipeline.
# build_streaming_budget.py -- 組出 streaming_budget.csv，swift_tar → 線路 →
# swift_tar → P6 管線的每個步驟一列。
#
# Nothing here is hand-typed. Timings come from comparison.csv (produced by
# streaming_budget_benchmark.zsh) and from running P6-DOE, so the table cannot
# drift away from the measurements it claims to summarise.
# 此處沒有任何手動填入的數字。計時取自 comparison.csv（由
# streaming_budget_benchmark.zsh 產生）與實際執行 P6-DOE，故本表不會與其所摘要的
# 量測結果脫節。
#
# Usage / 用法:
#   ./build_streaming_budget.py [fps] [link-MB/s]
#   defaults / 預設: 60 fps, 118 MB/s (1 GbE practical / 1 GbE 實務值)
# =====================================================================

import csv
import os
import re
import subprocess
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
FPS = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
LINK_MBPS = float(sys.argv[2]) if len(sys.argv) > 2 else 118.0   # 1 GbE, practical
BUDGET_MS = 1000.0 / FPS

WIDTH, HEIGHT = 1920, 1080
RGB1_HEADER = 876
RAW = WIDTH * HEIGHT * 3
VARIANT = "ycocg-r+med+planar+slice20"
THREADS = "20"


def measured_codec():
    """Encode/decode ms and wire bytes, from the benchmark's own CSV.
    編碼／解碼毫秒數與線路位元組，取自 benchmark 自身產生的 CSV。"""
    path = os.path.join(HERE, "comparison.csv")
    if not os.path.exists(path):
        sys.exit("comparison.csv missing — run streaming_budget_benchmark.zsh first\n"
                 "缺少 comparison.csv —— 請先執行 streaming_budget_benchmark.zsh")
    for r in csv.DictReader(open(path)):
        if r["variant"] == VARIANT and r["threads"] == THREADS:
            n = int(r["frames"])
            return (float(r["encode_ms_per_frame"]),
                    float(r["decode_ms_per_frame"]),
                    int(r["compressed_bytes"]) / n)
    sys.exit(f"no row for {VARIANT} at -n {THREADS} in comparison.csv")


def measured_render():
    """Three-plane upload + GPU time, by running P6-DOE.
    三平面上傳與 GPU 時間，實際執行 P6-DOE 取得。"""
    doe = os.path.join(HERE, "..", "..", "rgb1", "P6-DOE")
    frame = os.path.join(HERE, "sample", "t000020s.rgb1")
    if not (os.path.exists(doe) and os.path.exists(frame)):
        sys.exit("P6-DOE or sample frame missing — build it and generate samples\n"
                 "缺少 P6-DOE 或樣本影格 —— 請先建置並產生樣本")
    out = subprocess.run([doe, frame, "60"], capture_output=True, text=True).stdout
    m = re.search(r"B\s+3 plane textures \(planar\)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", out)
    if not m:
        sys.exit("could not parse P6-DOE output / 無法解析 P6-DOE 輸出")
    return float(m.group(3))


enc_ms, dec_ms, wire_bytes = measured_codec()
render_ms = measured_render()

# Each row: what the step consumes, what it emits, and what limits it.
# 每列記錄：該步驟消耗什麼、產出什麼、受什麼限制。
# `tool` records the exact invocation a row's timing came from. Concurrency is
# part of that invocation, not a footnote: the same step is 13x slower at -n 1,
# so a row without its -n is not reproducible.
# `tool` 記錄該列計時所來自的確切呼叫方式。並行度屬於呼叫的一部分而非註腳：同一
# 步驟在 -n 1 下慢 13 倍，故未載明 -n 的列無法重現。
SLICES, THREAD_N = 20, 20
steps = [
    dict(step="1 source frame (RGB1 in memory)", side="server", ms=0.0,
         bytes_in=0, bytes_out=RAW + RGB1_HEADER,
         limit="capture rate",
         tool="-", note="uncompressed, 3 B/px / 未壓縮"),
    dict(step="2 transform + zstd-3 encode", side="server", ms=enc_ms,
         bytes_in=RAW + RGB1_HEADER, bytes_out=wire_bytes,
         limit=f"CPU, {SLICES} slices at -n {THREAD_N}",
         tool=f"swift_tar -n {THREAD_N} --zstd (level 3, {SLICES} slices)",
         note="YCoCg-R -> MED -> planar -> zstd / 依序套用"),
    dict(step="3 wire transfer", side="network", ms=0.0,
         bytes_in=wire_bytes, bytes_out=wire_bytes,
         limit=f"link {LINK_MBPS:.0f} MB/s",
         tool="-", note="the binding constraint / 真正的約束"),
    dict(step="4 zstd-3 decode + inverse", side="client", ms=dec_ms,
         bytes_in=wire_bytes, bytes_out=RAW,
         limit=f"CPU, {SLICES} slices at -n {THREAD_N}",
         tool=f"swift_tar -n {THREAD_N} -x (level 3, {SLICES} slices)",
         note="emits planar GBR, ready to upload / 輸出 planar GBR，可直接上傳"),
    dict(step="5 three-plane upload + render", side="client", ms=render_ms,
         bytes_in=RAW, bytes_out=RAW,
         limit="GPU / PCIe-equivalent",
         tool="P6-DOE path C (gbrp)",
         note="3x r8Unorm, no alpha expansion / 三個 r8Unorm，免補 alpha"),
]

rows = []
for s in steps:
    mbps = s["bytes_out"] * FPS / 1e6
    cap_fps = (LINK_MBPS * 1e6 / s["bytes_out"] if s["side"] == "network"
               else (1000.0 / s["ms"] if s["ms"] > 0 else float("inf")))
    rows.append({
        "step": s["step"],
        "side": s["side"],
        "ms_per_frame": f"{s['ms']:.2f}",
        "budget_ms": f"{BUDGET_MS:.2f}",
        "headroom_pct": ("n/a" if s["ms"] == 0
                         else f"{(BUDGET_MS - s['ms']) / BUDGET_MS * 100:.1f}"),
        "bytes_in": int(s["bytes_in"]),
        "bytes_out": int(s["bytes_out"]),
        "MB_per_s": f"{mbps:.1f}",
        "max_fps_capacity": ("inf" if cap_fps == float("inf") else f"{cap_fps:.0f}"),
        "fits": ("yes" if (cap_fps >= FPS) else "NO"),
        "limited_by": s["limit"],
        "tool": s["tool"],
        "note": s["note"],
    })

# Totals are per side: server and client are different machines, so their costs
# do not add against one frame budget.
# 合計依邊計算：伺服器與客戶端是不同機器，其成本不會相加後對照同一個影格預算。
for side in ("server", "client"):
    ms = sum(float(r["ms_per_frame"]) for r in rows if r["side"] == side)
    rows.append({
        "step": f"TOTAL {side}", "side": side,
        "ms_per_frame": f"{ms:.2f}", "budget_ms": f"{BUDGET_MS:.2f}",
        "headroom_pct": f"{(BUDGET_MS - ms) / BUDGET_MS * 100:.1f}",
        "bytes_in": "", "bytes_out": "", "MB_per_s": "",
        "max_fps_capacity": f"{1000.0 / ms:.0f}" if ms else "inf",
        "fits": "yes" if ms <= BUDGET_MS else "NO",
        "limited_by": "CPU" if side == "server" else "CPU + GPU",
        "tool": f"swift_tar -n {THREAD_N}",
        "note": f"sum of {side} steps / {side} 各步驟總和",
    })

out_path = os.path.join(HERE, "streaming_budget.csv")
with open(out_path, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)

print(f"[Info] {datetime.now():%Y-%m-%d %H:%M:%S}  {WIDTH}x{HEIGHT} @ {FPS:.0f} fps, "
      f"budget {BUDGET_MS:.2f} ms, link {LINK_MBPS:.0f} MB/s")
print()
hdr = f"{'step':<34}{'ms':>8}{'bytes/frame':>14}{'MB/s':>9}{'max fps':>9}{'fits':>6}"
print(hdr); print("-" * len(hdr))
for r in rows:
    b = f"{int(r['bytes_out']):,}" if r["bytes_out"] != "" else ""
    print(f"{r['step']:<34}{r['ms_per_frame']:>8}{b:>14}"
          f"{r['MB_per_s']:>9}{r['max_fps_capacity']:>9}{r['fits']:>6}")
print()
print(f"[Done] {out_path}")
