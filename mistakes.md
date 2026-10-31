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
| 2 | 管線末端的 `tail` 吞掉 push 失敗，`&&` 照樣推出上層 gitlink | 1 | 1 | 1 | — |
| 3 | 工具選擇的另一條分支從沒跑過：openssl 的 `--` 讓沒有 sha256sum 的 Mac 無法出貨 | 2 | 1 | 2 | — |

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

---

## 2. 管線末端的 `tail` 吞掉 push 失敗，`&&` 照樣推出上層 gitlink — **已發生 1 次（2026-10-30）**

**症狀**：一條「先推子模組、再推上層」的指令跑完，上層那一段印出 `65bbe9e..7278ef3  HEAD -> main`，
看起來兩邊都推好了——**而上層剛推出的 gitlink 指向一個遠端沒有的 commit**（`958741c`）。

**實際狀況**：

```zsh
git push origin master 2>&1 | tail -2 && cd .. && … git commit … && git push origin HEAD
```

swift_tar 的 push 被拒（non-fast-forward：另一處已先推了內容相同的 `fb86de8`），拒絕訊息就在
`tail -2` 印出的那兩行 hint 上方。但 `&&` 判斷的是**管線最後一個指令** `tail` 的退出碼，那是 0，
於是後半段照跑：上層 commit 了 `958741c` 的指標並推了出去。拒絕訊息被 `tail -2` 截到只剩
`hint: use 'git pull' before pushing again.`，而它與成功的輸出一起捲過去。

**怎麼發現的**：讀那次輸出時才看到 `hint:` 兩行與 `[ahead 1, behind 1]`。事後補了一個 commit
（`bba229c`）把上層指標改指 origin 上的 `fb86de8`；沒有 force push，所以上層歷史裡留著一個暫時
指錯的 `7278ef3`。

**與 lzfse2 `mistakes.md` 第 1 條同形**（自己的過濾器把失敗藏起來），正是那裡列的第 7 種偽裝
`cmd | tail -3; rc=$?`：**管線改變了 `$?`（以及 `&&`）指涉的對象。** 這次多了一層代價——後面
接的不是一個摘要，而是一次對外的 push。

**現在怎麼防**：

- **push 不接管線。** `git push … >out 2>&1; rc=$?`，判斷 `rc` 之後才讀 `out`、才走下一步。
  zsh 裡若非接管線不可，用 `setopt pipe_fail`，或看 `${pipestatus[1]}`。
- **推上層 gitlink 之前，先確認子模組的那個 commit 已在遠端**：
  `git -C swift_tar branch -r --contains <commit>` 要有 `origin/master`。這一步與退出碼無關，
  所以前一步不管以什麼方式失敗，它都擋得住。
- 子模組與上層的 push 分成兩條指令，中間看一次 `git status -sb`。

`git push … 2>&1 | tail -2 && …` made `&&` test tail's exit status, so a rejected push
(non-fast-forward) let the next half commit and push a parent gitlink pointing at a commit the
remote did not have. Same shape as lzfse2 entry 1, seventh disguise. Never pipe a push; check
its own status, and before pushing a parent gitlink confirm the submodule commit is on the
remote with `git branch -r --contains`.

---

## 3. 工具選擇的另一條分支從沒跑過：openssl 的 `--` 讓沒有 sha256sum 的 Mac 無法出貨 — **已發生 2 次（2026-10-20、2026-10-30）**

**症狀**：`release.zsh` 的雜湊改寫（`e3c87f4`）帶著四個新案例——原生與交叉各一個「印出非雜湊」、
一個「工具失敗」——全部通過；整套 33 支測試全綠、`claim_check` 全部落地。**而在一台沒有
sha256sum 的 Mac 上，每一次出貨都會被拒絕**：LibreSSL 印出 `usage: dgst [-cdr] …`，接著是
`release.zsh: a command failed`。

**實際狀況**：

```zsh
if command -v sha256sum >/dev/null 2>&1; then h=$(cd -- "$1" && sha256sum -- "$2")
elif command -v openssl >/dev/null 2>&1; then h=$(openssl dgst -sha256 -r -- "$1/$2")   # ← --
```

macOS 的 `/usr/bin/openssl` 是 LibreSSL 3.3.6，它不認得 `--`，以 1 結束（Homebrew 的 OpenSSL
接受，所以 PATH 順序也會改變結果）。`--` 是「為了保險」加的，**從沒在任何一個 openssl 上跑過**：

- 手邊每一台機器都有 sha256sum——macOS 27 的 `/sbin/sha256sum`、Linux 的 coreutils、Windows 的
  Git Bash——所以 `elif` 永遠不會被走到；
- 新案例把**假的** sha256sum 放在 PATH 最前面，那只會讓 `command -v sha256sum` 更確定成立。
  四個案例測的全是同一條分支。

同一行 `openssl dgst -sha256 -r --` 在 `publish.zsh` 的 `sha256_of` 裡**從 `bed0956`
（2026-10-20，發布工具建立時）就在了**，十一天沒有人發現，原因相同。那是第一次；`e3c87f4`
把它抄進 `release.zsh` 是第二次。

**怎麼發現的**：2026-10-31 的審查直接執行 `/usr/bin/openssl dgst -sha256 -r -- f`，得到 rc 1。
再把 `/sbin` 移出 PATH、讓 LibreSSL 排最前，端對端跑 `test_release.zsh`：HEAD 的打包兩項失敗，
`df415e4`（改動之前）通過。修正在 `a079540`。

**與第 1 條同形**（對照組只落在一邊），也是 skill 關口 4 的形狀，只是範圍更窄：**驗證的平台是
對的，但那個平台走不到這條分支。** 「在我的平台上通過」在這裡什麼都沒說，因為我的平台根本不
執行那一行。

**現在怎麼防**：

- **有 `if/elif` 的工具選擇，就讓每一條分支各有一個案例真的走到。** 方法是把前面的工具**移出**
  PATH，而不是在前面放一個假的——後者只會讓第一條分支更確定被選中。`test_release.zsh` 的
  openssl 案例就是這樣做（只在 macOS，那裡 sha256sum 獨佔 `/sbin`）。
- **加 `--` 這類「保險」旗標之前，在每一個目標實作上跑一次**：LibreSSL 與 OpenSSL、GNU 與 BSD
  的同名工具，接受的語法並不相同。保險旗標本身也是一段沒驗過的程式碼。
- 寫完一個分支時問一句：**「這台機器會走哪一條？」** 若每台機器的答案都一樣，另一條就是沒驗過。

`release.zsh` and `publish.zsh` fell back to `openssl dgst -sha256 -r --` when sha256sum was
absent, and macOS's LibreSSL rejects `--`, so a Mac without sha256sum could not release. Every
available machine had sha256sum, and the new cases put a fake one first on PATH, so all of them
ran the sha256sum branch and passed. In `publish.zsh` since `bed0956` (2026-10-20), copied into
`release.zsh` by `e3c87f4` (2026-10-30), fixed in `a079540`. Same shape as entry 1 and as the
skill's gate 4, narrower: the platform was right, but it never reaches that branch. Give every
branch of a tool choice a case that takes it -- by removing the earlier tool from PATH, not by
shadowing it -- and run a "just in case" flag such as `--` on every implementation it targets.
