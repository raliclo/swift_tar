# patch/ — 對 vendored 上游的例外 / exceptions to the vendored upstreams

**規則是「vendored 的上游不改」。這個資料夾是那條規則的例外處。**

例外必須是明示的、可稽核的、且不會靜默消失。這裡的每一份 patch 都要能回答三個問題:
改了什麼、為什麼、以及**上游哪天修好了要怎麼知道**。

The rule is that vendored upstreams are not edited; this folder is where that rule has
exceptions. Each one must say what it changes, why, and how anyone will find out when
upstream makes it unnecessary.

---

## 為什麼需要一個資料夾,而不是直接改 submodule

直接改在 submodule 裡的修正,會在下一次 `sync_all.zsh --update` 時**無聲消失**——那道
指令會把 submodule 切到分支 tip,覆蓋工作區。而消失之後:

- 建置照樣成功
- 測試照樣通過(除非剛好有一項釘住那個行為)
- 只有那個被修掉的行為悄悄回來了

把修改放在這裡、由 `apply_patches.zsh` 重貼,是為了讓「它還在不在」變成**一道可以執行
的指令**,而不是一件要有人記得的事。

An edit made directly inside a submodule disappears at the next `sync_all.zsh --update`,
and after it disappears the build still succeeds and the tests still pass — only the
behaviour is back. Keeping the change here makes "is it still there?" a command.

---

## 平常不必手動執行:建置會自己處理

`build_libarchive.zsh` 會**套用 → 建置 → 還原**,所以 submodule 只在編譯期間是「髒」的,
建置結束後 `git status` 是乾淨的,而剛建好的靜態庫仍帶著修正。

還原用 `trap`,**建置失敗時也會還原**——否則一次失敗的建置會把工作區留在髒狀態,而下一個
人分不出那是 patch 還是自己改的。

這樣安全的理由是:**每一次建置都先套用再還原**,不存在「還原之後某次增量編譯偷偷用到未
修正原始碼」的空隙。

實測(2026-09-06):自乾淨工作區跑 `./build.zsh` → 建置過程印出「已套用」→ 結束後
`git -C libarchive status --porcelain` 為 0 行 → 而產出的 ZIP 仍存 NFC,三項正規化斷言
全過。**原始碼已還原,產物仍帶修正。**

`build_libarchive.zsh` applies, builds, then reverts, so the submodule is dirty only while
compiling. The revert runs from a trap so a failed build reverts too. Safe because every
build applies first: there is no window where an incremental compile silently uses unpatched
sources. Verified: after a full build the submodule shows zero changes and the resulting ZIP
still stores NFC.

---

## 手動用法 / Manual usage

```zsh
./patch/apply_patches.zsh            # 套用全部(已套用者略過)
./patch/apply_patches.zsh --check    # 只檢查,不改任何東西;缺任何一份就以 1 結束
./patch/apply_patches.zsh --revert   # 還原全部
```

`--check` 適合放進提交前的檢查或 CI:**它在 patch 沒套用時以 1 結束**。不過既然建置會
自己套用,`--check` 在建置之外的時機通常會回報「未套用」——那是正常的,不是警訊。它真正
的用途是在**編譯當下**確認,以及檢查 patch 是否已經對不上上游(見下一節的第三種狀態)。

---

## 升級 submodule 的順序

因為建置會自己還原,平常工作區是乾淨的,所以升級通常可以直接:

```zsh
./sync_all.zsh --update libarchive       # 移動 pin
./build.zsh                              # 建置(自動套用 → 建置 → 還原)
# 然後照 sync_all.zsh 印出的六個步驟重測
```

**但若工作區當下是髒的**(例如有人手動套了 patch、或上一次建置被中斷),`sync_all.zsh`
**會跳過那個 submodule**——那是刻意的,它不覆蓋別人未提交的工作。此時要先還原:

```zsh
./patch/apply_patches.zsh --revert       # 先讓工作區乾淨
./sync_all.zsh --update libarchive
```

**跳過還原的後果不是失敗,是什麼都沒發生**:`sync_all.zsh` 印一行「跳過:有本地修改」,
升級沒有進行,而畫面上只是一行提示。

Because the build reverts for you, the tree is normally clean and an upgrade is just
`sync_all.zsh --update` followed by a build. If the tree *is* dirty — someone applied by
hand, or a build was interrupted — sync_all skips that submodule on purpose, so revert
first. Skipping the revert is not a failure; it is nothing happening.

---

## `apply_patches.zsh` 分辨的三種狀態

腳本對每一份 patch 問兩個問題(套得上嗎、反向套得上嗎),得到三種狀態,而**三種要人做
的事完全不同**:

| 狀態 | 意思 | 該做什麼 |
|---|---|---|
| 反向套得上 | 已經在裡面了 | 什麼都不用做 |
| 套得上 | 還沒貼 | 貼上(或 `--check` 時回報缺少) |
| 兩者皆否 | **上游動了** | **需要人判斷** |

第三種是這個腳本存在的主要理由。它可能代表:

- **上游自己修好了** → 該刪掉這份 patch
- **周邊程式碼變了** → 該重做這份 patch

這兩者要做的事相反,腳本不猜,**也絕不用 `--force` 硬套**——硬套出來的結果沒有人驗證過,
而它會看起來像成功。

The third state is why this script exists. It means upstream moved, and whether that calls
for deleting the patch or redoing it is a judgement the script does not make. It never
forces: a forced apply produces something nobody verified and it looks like success.

---

## 目前的 patch / Current patches

### `libarchive/0001-no-apple-nfd-normalisation.patch`

**改什麼**:停用 `archive_string.c` 中 `#if defined(__APPLE__)` 之下的兩處
`SCONV_NORMALIZATION_D`。

**為什麼**:libarchive 在 Apple 平台把檔名正規化為 NFD,其註解說明的理由是
「On Mac OS X, although its filesystem layer automatically convert filenames to NFD...」
——**那描述的是 HFS+**。APFS 不會:它查找時對正規化不敏感、儲存時原樣保留。

實測(本樹,APFS):先建 `caf\xc3\xa9.txt`(NFC)再建 `cafe\xcc\x81.txt`(NFD),磁碟上
只剩**一個**檔案,名稱是 NFC 那一種。**libarchive 轉換了一個檔案系統並未轉換的名稱。**

**後果**:在此 patch 之前,同一支 swift_tar 的兩條路徑對同一個檔案給出不同的名稱——

```
磁碟      63 61 66 c3 a9        NFC
tar       63 61 66 c3 a9        NFC   （純 Swift,忠實)
zip       63 61 66 65 cc 81     NFD   （經 libarchive)
```

macOS 本機看不出差別(APFS 兩種寫法都找得到同一個檔),但封存的用途是離開這台機器,而
**ext4 對正規化是敏感的**:這種 ZIP 解到 Linux 上會得到一個與原始檔名不同的檔案。

**為什麼不在 bridge 端解**:試過三種做法都無效——以 `set_pathname_utf8` 從 `pathname`
設回、停用 `hdrcharset=UTF-8`、改從 `sourcepath` 取值,存出來的名稱都仍是 NFD。能清掉
該旗標的 `SCONV_SET_OPT_NORMALIZATION_C` 是內部 API,只有 tar reader 用得到。細節見
`todo/todo.md`。

**上游修好了要怎麼知道**:`apply_patches.zsh` 會在這份 patch 套不上也反套不上時,以
「需要人看」回報並以 1 結束。屆時請先確認上游是否已移除該正規化——若是,刪掉這份
patch,並在 `todo/todo.md` 把該條目結案。

Disables the two Apple-only NFD normalisation sites in libarchive, whose justifying comment
describes HFS+ behaviour that APFS does not have. Without it, swift_tar's tar and ZIP paths
name the same file differently, and the ZIP form is the lossy one once the archive reaches a
normalisation-sensitive filesystem. Three bridge-level fixes were tried first and none
worked; the option that would clear the flag is internal to libarchive.
