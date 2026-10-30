# 容易犯的錯誤 / Mistakes That Are Easy to Make

本檔只收錄**在 swift_tar 這棵樹上實際發生過**的錯誤，且每一條都符合同一個條件：**它們都沒有讓
任何工具報錯。** 每一條都產生了一個看起來完全合理的結果。沒有實際踩過的事情不要加進來；加入
一條時請一併寫出**當初是什麼症狀**，因為下一個人是先看到症狀才找到這裡的。

This file records only mistakes that actually happened in the swift_tar tree, and every one
shares a property: none of them made any tool report an error. Do not add anything that has
not happened; write down the symptom, as that is what the next person sees first.

可攜的規則與工具在 skill `mistakes_prevention`（`~/.claude/skills/mistakes_prevention/`）。上層
lzfse2 有它自己的一份 `mistakes.md`；兩份互不寫入，同形的條目在本文裡互相指明。
The portable rules and tools are the `mistakes_prevention` skill. The parent lzfse2 repository
keeps its own `mistakes.md`; neither writes into the other, and entries of the same shape
point at each other in the text.

---

## 計數表 / The counter

次數的權威來源是 [`mistakes_counter.csv2`](./mistakes_counter.csv2)，不是本文。以 `csv2` 讀寫：
`shape` 與 `guard` 欄含引號內的逗號，逗號切割會靜默切錯。
The counts live in `mistakes_counter.csv2`, read and written through `csv2`.

```sh
S=~/.claude/skills/mistakes_prevention/scripts
$S/counter.zsh -i mistakes_counter.csv2 list            # 出表 / the table
$S/counter.zsh -i mistakes_counter.csv2 bump 1 <date>   # 第 1 條再犯一次 / entry 1 again
```

| # | 標題 | 總次數 | 單日最多 | 發生天數 | 矯正措施 |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | 樣式要 `extended_glob` 而未開，檢查的一部分不可能失敗 | 1 | 1 | 1 | — |

---

## 1. 樣式要 `extended_glob` 而未開，檢查的一部分不可能失敗 — **已發生 1 次（2026-10-30）**

**症狀**：一支新的測試以 0 結束、4/4 通過，修正前的原始碼讓它 4 項全部失敗，加回一處直接呼叫也
讓它失敗——**而它的其中一段從來沒有作用過**。

**實際狀況**：`test/test_bridge_errors.zsh` 檢查 `archive_error_string(` 只出現在
`archive_reason` 裡。為了不把註解裡提到這個名稱的行算進去，它先略過註解行：

```zsh
[[ $line == [[:space:]]#(/\*|\*)* ]] && continue   # ← 沒有 setopt extended_glob
```

`#`（前一項重複零次以上）需要 **EXTENDED_GLOB**，而該檔沒有 `setopt`。沒開時 `#` 是字面字元，
樣式只會比對開頭真的有 `#` 的行——**一行註解都不會被略過**。測試照樣通過，只因為當時的註解裡
寫的是 `archive_error_string returns`，後面沒有括號，本來就不會被算到。

**怎麼發現的**：提交前以 `zsh -f` 重跑，再造一份含 `archive_error_string(a)` 註解行的原始碼：
沒有 `setopt` 時兩行註解被算成呼叫（2 項失敗），加上之後正確忽略。**對照組本來就跑了三組，卻
沒有一組落在「被過濾」那一邊**——修正前的原始碼、加回呼叫的原始碼、修好的原始碼，三者的註解都
不含括號。

**與 lzfse2 `mistakes.md` 第 10 條同形**：那次是 `(#c7,40)` 少了 `extended_glob`，守門讓整道檢查
不可能失敗；這次是一個過濾器不作用，讓檢查的一部分不可能失敗。兩次都是「對照組只驗了會失敗的
那一邊」。

**現在怎麼防**：

- 用到 `#`、`##`、`(#c…)`、`(#i)`、`(#a…)` 就在該處 `setopt extended_glob`（函式內用
  `setopt local_options extended_glob`），不要假設呼叫端或使用者的設定開了它。
- 新檢查以 `zsh -f` 跑一次，排除個人設定。
- **過濾器自己也要有對照組**：放一個必定落在被過濾那一邊的輸入，證明它真的被略過；只證明
  「該失敗的會失敗」，不足以說明過濾器有作用。

A test skipped comment lines with `[[:space:]]#(/\*|\*)*`, whose `#` needs EXTENDED_GLOB, which
the file did not set; the pattern never matched, so no comment line was ever skipped. The test
passed 4/4 only because no comment then held the call with its parenthesis. Three controls had
run, none of them on the filtered side. Caught before commit by rerunning under `zsh -f` with a
source whose comments do name the call. Same shape as lzfse2's entry 10. Set `extended_glob`
where it is used, run new checks under `zsh -f`, and give every filter an input it must filter.
