# CLAUDE.md

## Development Culture & Constraints
- **CRITICAL**: All explanations, code comments, and chat responses MUST be written in both English and Traditional Chinese (繁體中文). Do not use Simplified Chinese or English for explanations unless explicitly asked.

## System Prompt Overrides
- **Language**: Always respond in Traditional Chinese (繁體中文).
- **Tone**: Professional, software engineer peer.

## Code Style
- Follow the project specifications.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. For a quick start, see the [README.md](./README.md).
Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.
Tradeoff: These guidelines bias toward caution over speed. For trivial tasks, use judgment.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

## 不得抑制編譯器診斷 / Never suppress a compiler diagnostic

**警告與錯誤要用「修好成因」解決，不是用標註讓它閉嘴。**

禁止用來讓診斷消失的手段，包括但不限於：

```swift
nonisolated(unsafe) var x = 0        // 不要：把並行檢查關掉
@unchecked Sendable                  // 不要
// swiftlint:disable / swift-format-ignore
```

```sh
2>/dev/null            # 不要用來藏建置訊息
-w  -Wno-...           # 不要
|| true                # 不要用來蓋掉非零退出（測試中刻意容忍者除外，且須註明理由）
```

**理由是這棵樹已經付出過的代價。** 被藏起來的診斷不會消失，它只是改在執行期出現，而
且那時已經沒有指向成因的線索。2026-08-28 的 `aea0427` 是同一類：一個正確的安全修正
帶進 O(成員數 × 深度) 的 lstat，沒有任何警告會提到它，於是它一路活到量測輪次才以
「解壓慢 302%」的形式現身，花了一次 9 小時 46 分的輪次加一次 98 筆 commit 的 bisect
才定位。編譯器願意講的話，要讓它講完。

**正確做法**：改結構讓診斷自然消失。全域可變狀態就把它變成不可變、或收進傳遞下去的
值；並行捕獲就讓被捕獲的東西真的是 Sendable。若判斷某個診斷確實不適用，那是**與使用者
討論後的決定**，不是自行標註掉。

**Warnings and errors are resolved by fixing the cause, never by annotating them
into silence.** A suppressed diagnostic does not go away; it moves to run time,
where the thread back to its cause is gone. `aea0427` was the same shape: a
correct security fix carrying an O(members x depth) cost that no warning
mentioned, so it survived until a measurement round showed up as a 302% decode
regression and took a 9h46m round plus a 98-commit bisect to locate. Change the
structure so the diagnostic stops applying; deciding a diagnostic does not apply
is a conversation with the user, not a unilateral annotation.

## 不要用 Python 做編輯或腳本 / Do not use Python for edits or scripting

**改檔案用 Edit／Write 工具；要腳本就用 zsh。** 不要以 `python3 - <<'PY'` 這類 heredoc
代替編輯器。

以 Python 做字串替換時，被替換的目標是一段**看不見的**字面值——它必須與檔案逐字相符，
而任何不符只會得到 `AssertionError` 或更糟的「靜默不替換」。2026-08-28 的
`-h/--dereference` 就是這樣壞掉的：新的一行被插進一個跨行運算式的中間，於是
`|| args.contains("-p")` 這個續行接到了另一個變數上。**它能編譯、能通過型別檢查、以 0
結束**，而 `-p` 同時失去自己的效果並取得一個無關的效果。Edit 工具會呈現前後文。

Use the Edit/Write tools for files and zsh for scripts. A Python string replacement
targets an invisible literal that must match exactly; a mismatch is either an assertion
or a silent no-op. On 2026-08-28 a line inserted that way re-attached the continuation of
one expression to a different variable, and it compiled, type-checked and exited zero.

## 測試中的表格資料用 csv2 / Use csv2 for tabular data in tests

測試若要產出或讀取表格（結果矩陣、逐案例的量測、對照表），存成 `.csv2`（兩列標頭：
英文一列、繁體中文一列）並以 `csv2` 讀寫，不要自行切逗號。全域 CLAUDE.md 的理由在此
同樣成立，而測試更容易踩到：一個把欄位切錯的斷言會**通過**，因為它比對的是錯位之後的
值。`csv2 -get r:c` 取單格，`csv2 -r` 逐筆讀，`csv2 -md` 出表格給文件用。

If a test produces or reads a table, store it as `.csv2` and go through `csv2`. An
assertion that split the fields wrongly passes, because it compares the shifted value.
