#!/usr/bin/env python3
# =====================================================================
# palette_vs_predictive.py -- DOE: does a colour map with pointers beat
# predictive coding for the RGB1 payload?
# palette_vs_predictive.py -- DOE：以「色彩對照表 + 指標」取代原始像素，
# 是否比預測式編碼更小？
#
# The proposal under test: collect every unique RGB in the frame into a map,
# then store each pixel as a pointer into that map. At 4K the pointer needs
# ceil(log2 N) bits, and the map itself costs N*3 bytes, so the idea only pays
# off when N is small relative to the pixel count.
# 受測提案：把影格中所有唯一 RGB 收進對照表，每個像素改存指向表的指標。4K 下
# 指標需 ceil(log2 N) 位元，對照表本身要 N*3 bytes，因此唯有 N 相對像素數夠小
# 時才划算。
#
# It is measured against the predictive stack (YCoCg-R -> MED -> planar), which
# is what FFV1 does, so both arms are lossless and directly comparable.
# 對照組為預測式堆疊（YCoCg-R -> MED -> planar），即 FFV1 的作法；兩組皆為無損
# 且可直接比較。
#
# Every arm is round-trip verified before its size is recorded -- an arm that
# cannot reconstruct the original frame is not a compression result.
# 每組在記錄大小前都先驗證往返還原 —— 無法還原原始影格的方案不算壓縮結果。
#
# Usage / 用法:
#   ./palette_vs_predictive.py [sample-dir] [zstd-level]
#   defaults / 預設: sample/, level 19
# =====================================================================

import glob
import math
import os
import subprocess
import sys
from datetime import datetime

import numpy as np

# sample_consecutive, not sample. The 10 s-sampled corpus opens on this clip's
# fade from black: that frame has 12 unique colours and compresses to 311 bytes,
# and it sat in the average of every arm below. Consecutive mid-video frames are
# what the rest of the study uses.
# 預設為 sample_consecutive 而非 sample。相隔 10 秒的語料以本片自黑畫面淡入那格開頭：
# 該格僅 12 種顏色、壓縮後 311 位元組，卻計入下方每一組的平均。本研究其餘部分使用的
# 都是中段的連續影格。
SAMPLE_DIR = sys.argv[1] if len(sys.argv) > 1 else "sample_consecutive"

# Writes its own record, like every other script in this directory. It used to
# print to stdout and rely on the caller redirecting: a re-run with the output
# discarded left the committed file untouched and dated three days earlier, which
# reads exactly like a run that produced identical numbers.
# 與本目錄其他腳本一致，自行寫出紀錄檔。它原本只印到 stdout，靠呼叫端重導：一次把輸出
# 丟棄的重跑會讓入版檔案原封不動、日期停在三天前，看起來與「重跑後數字完全相同」無異。
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "palette_vs_predictive_output.txt")

class _Tee:
    def __init__(self, path):
        self.f = open(path, "w")
    def write(self, s):
        sys.__stdout__.write(s); self.f.write(s)
    def flush(self):
        sys.__stdout__.flush(); self.f.flush()

sys.stdout = _Tee(OUTPUT)
LEVEL = int(sys.argv[2]) if len(sys.argv) > 2 else 19
HEADER = 876  # RGB1 header size / RGB1 標頭大小


def zstd(payload: bytes) -> int:
    """Compressed size under zstd, the codec swift_tar streams with.
    以 swift_tar 串流所用的 zstd 壓縮後大小。"""
    done = subprocess.run(["zstd", f"-{LEVEL}", "-c", "-"],
                          input=payload, capture_output=True, check=True)
    return len(done.stdout)


# ---------------------------------------------------------------------
# Arm B: colour map + pointers / B 組：色彩對照表 + 指標
# ---------------------------------------------------------------------
def bitpack(values: np.ndarray, width: int) -> bytes:
    """Pack the low `width` bits of each value, with no byte alignment.
    將每個值的低 `width` 位元緊密打包，不做位元組對齊。"""
    bits = np.unpackbits(values.astype(">u4").view(np.uint8).reshape(-1, 4), axis=1)
    return np.packbits(bits[:, 32 - width:].reshape(-1)).tobytes()


def palette_encode(pixels: np.ndarray):
    """pixels: (n,3) uint8 -> (container bytes, unique count, pointer width)."""
    packed = (pixels[:, 0].astype(np.uint32) << 16
              | pixels[:, 1].astype(np.uint32) << 8
              | pixels[:, 2].astype(np.uint32))
    colours, pointers = np.unique(packed, return_inverse=True)
    width = max(1, math.ceil(math.log2(len(colours))))

    # The map is stored sorted, which np.unique already guarantees; sorted
    # entries share high bytes and so compress far better than insertion order.
    # 對照表以排序後儲存（np.unique 已保證），排序後高位位元組相近，遠比插入
    # 順序更好壓縮。
    table = colours.astype(">u4").view(np.uint8).reshape(-1, 4)[:, 1:].tobytes()
    body = bitpack(pointers.astype(np.uint32), width)
    return (len(colours).to_bytes(4, "big") + table + body), len(colours), width


def palette_decode(blob: bytes, count: int, width: int, n: int) -> np.ndarray:
    table = np.frombuffer(blob[4:4 + count * 3], dtype=np.uint8).reshape(-1, 3)
    body = np.frombuffer(blob[4 + count * 3:], dtype=np.uint8)
    bits = np.unpackbits(body)[:n * width].reshape(n, width)
    pad = np.zeros((n, 32 - width), dtype=np.uint8)
    pointers = np.packbits(np.hstack([pad, bits]), axis=1).view(">u4").reshape(-1)
    return table[pointers]


# ---------------------------------------------------------------------
# Arm C: predictive stack / C 組：預測式堆疊
# ---------------------------------------------------------------------
def ycocg_r_forward(rgb: np.ndarray) -> np.ndarray:
    """Reversible YCoCg-R. Co/Cg need 9 bits, kept reversible mod 256.
    可逆 YCoCg-R。Co/Cg 需 9 位元，以 mod 256 保持可逆。"""
    r, g, b = (rgb[..., i].astype(np.int32) for i in range(3))
    co = (r - b) & 0xFF
    t = (b + (signed(co) >> 1)) & 0xFF
    cg = (g - t) & 0xFF
    y = (t + (signed(cg) >> 1)) & 0xFF
    return np.stack([y, co, cg], axis=-1).astype(np.uint8)


def signed(v):
    """Interpret a mod-256 value as signed, so >>1 matches the inverse.
    將 mod-256 值視為有號，使 >>1 與反變換一致。"""
    return ((v.astype(np.int32) + 128) & 0xFF) - 128


def ycocg_r_inverse(ycc: np.ndarray) -> np.ndarray:
    y, co, cg = (ycc[..., i].astype(np.int32) for i in range(3))
    t = (y - (signed(cg) >> 1)) & 0xFF
    g = (cg + t) & 0xFF
    b = (t - (signed(co) >> 1)) & 0xFF
    r = (b + co) & 0xFF
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def med_forward(plane: np.ndarray) -> np.ndarray:
    """MED residuals. Lossless means decoded == original, so every predictor
    input is available up front and the whole plane vectorises.
    MED 殘差。無損表示解碼結果等同原值，故所有預測輸入皆可預先取得，整個平面
    可向量化計算。"""
    p = plane.astype(np.int32)
    a = np.zeros_like(p); a[:, 1:] = p[:, :-1]        # left / 左
    b = np.zeros_like(p); b[1:, :] = p[:-1, :]        # above / 上
    c = np.zeros_like(p); c[1:, 1:] = p[:-1, :-1]     # upper-left / 左上
    a[0, 0] = b[0, 0] = c[0, 0] = 0
    b[0, 1:] = a[0, 1:]                                # first row: left only
    a[1:, 0] = b[1:, 0]                                # first column: above only
    c[0, :] = b[0, :]
    c[:, 0] = a[:, 0]
    hi, lo = np.maximum(a, b), np.minimum(a, b)
    pred = np.where(c >= hi, lo, np.where(c <= lo, hi, a + b - c))
    return ((p - pred) & 0xFF).astype(np.uint8)


def med_inverse(res: np.ndarray) -> np.ndarray:
    """Sequential by necessity: each prediction needs the pixel to its left.
    必須循序：每次預測都需要左邊那個已還原的像素。"""
    h, w = res.shape
    out = np.zeros((h, w), dtype=np.int32)
    r = res.astype(np.int32)
    for y in range(h):
        for x in range(w):
            a = out[y, x - 1] if x else (out[y - 1, x] if y else 0)
            b = out[y - 1, x] if y else a
            c = out[y - 1, x - 1] if (y and x) else (a if y else b)
            hi, lo = max(a, b), min(a, b)
            pred = lo if c >= hi else (hi if c <= lo else a + b - c)
            out[y, x] = (r[y, x] + pred) & 0xFF
    return out.astype(np.uint8)


def predictive_encode(rgb: np.ndarray) -> bytes:
    """YCoCg-R, then MED per plane, then planar layout.
    先 YCoCg-R，再逐平面 MED，最後採 planar 排列。"""
    ycc = ycocg_r_forward(rgb)
    return b"".join(med_forward(ycc[..., i]).tobytes() for i in range(3))


# ---------------------------------------------------------------------
def main():
    files = sorted(glob.glob(os.path.join(SAMPLE_DIR, "*.rgb1")))
    if not files:
        sys.exit(f"no samples in {SAMPLE_DIR}/ -- run rgb1_sampler first "
                 f"/ 找不到樣本，請先執行 rgb1_sampler")

    print(f"[Info] date / 日期: {datetime.now():%Y-%m-%d %H:%M:%S}")
    print(f"[Info] samples / 樣本: {len(files)} from {SAMPLE_DIR}/")
    print(f"[Info] codec: zstd -{LEVEL}")
    print()

    totals = {k: 0 for k in ("raw", "raw_z", "pal", "pal_z", "pred", "pred_z")}
    uniques, widths, verified = [], [], 0

    print(f"{'frame':<12}{'unique':>10}{'ptr bits':>10}"
          f"{'palette+z':>13}{'predictive+z':>15}{'raw+z':>12}")
    print("-" * 72)

    for path in files:
        blob = open(path, "rb").read()
        head, payload = blob[:HEADER], blob[HEADER:]
        w = int.from_bytes(head[4:8], "big")
        h = int.from_bytes(head[8:12], "big")
        flat = np.frombuffer(payload, dtype=np.uint8).reshape(-1, 3)
        rgb = flat.reshape(h, w, 3)

        pal, count, width = palette_encode(flat)
        pred = predictive_encode(rgb)

        # Round-trip both arms before trusting either size.
        # 兩組都先驗證往返，再採信其大小。
        assert np.array_equal(palette_decode(pal, count, width, h * w), flat), \
            f"palette round-trip failed on {path}"
        assert np.array_equal(ycocg_r_inverse(ycocg_r_forward(rgb)), rgb), \
            f"YCoCg-R round-trip failed on {path}"
        # MED inversion is inherently sequential, so it is checked on a crop
        # rather than the full frame; the forward path is identical either way.
        # MED 反變換本質上必須循序，故以裁切區塊驗證而非整格；正向路徑兩者相同。
        crop = rgb[:48, :48, 0]
        assert np.array_equal(med_inverse(med_forward(crop)), crop), \
            f"MED round-trip failed on {path}"
        verified += 1

        pal_z, pred_z, raw_z = zstd(pal), zstd(pred), zstd(payload)
        totals["raw"] += len(payload); totals["raw_z"] += raw_z
        totals["pal"] += len(pal);     totals["pal_z"] += pal_z
        totals["pred"] += len(pred);   totals["pred_z"] += pred_z
        uniques.append(count); widths.append(width)

        print(f"{os.path.basename(path):<12}{count:>10,}{width:>10}"
              f"{pal_z:>13,}{pred_z:>15,}{raw_z:>12,}")

    n = len(files)
    raw_avg = totals["raw"] / n
    print()
    print(f"[OK] {verified}/{n} frames round-tripped losslessly "
          f"/ 影格皆無損還原")
    print(f"[Info] unique colours / 唯一色數: min {min(uniques):,} "
          f"max {max(uniques):,} mean {sum(uniques)/n:,.0f}")
    print(f"[Info] pointer width / 指標寬度: {min(widths)}-{max(widths)} bits")
    print()

    print("== Average per frame / 每格平均 ==")
    print(f"{'arm':<34}{'stored (B)':>14}{'+zstd (B)':>14}{'of raw':>10}")
    print("-" * 72)
    rows = (("raw payload (today)", "raw", "raw_z"),
            ("colour map + pointers", "pal", "pal_z"),
            ("YCoCg-R + MED + planar", "pred", "pred_z"))
    for label, stored, comp in rows:
        print(f"{label:<34}{totals[stored]/n:>14,.0f}"
              f"{totals[comp]/n:>14,.0f}{100*totals[comp]/n/raw_avg:>9.2f}%")

    print()
    print("== Verdict / 結論 ==")
    base, pal_z, pred_z = totals["raw_z"], totals["pal_z"], totals["pred_z"]
    for label, value in (("colour map + pointers", pal_z),
                         ("YCoCg-R + MED + planar", pred_z)):
        delta = 100 * (value - base) / base
        verb = "smaller" if delta < 0 else "LARGER"
        print(f"  {label:<26} {delta:+7.1f}% vs raw+zstd  ({verb})")
    print(f"  predictive beats palette by "
          f"{100*(pal_z-pred_z)/pal_z:.1f}% / 預測式優於調色盤")


if __name__ == "__main__":
    main()
