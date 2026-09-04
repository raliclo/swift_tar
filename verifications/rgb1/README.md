# RGB1 verifications / RGB1 驗證

**Python is allowed here.** This directory is an explicit exception to the
project-wide rule against Perl and hand-rolled scripting dependencies, granted by
the project owner on 2026-09-05.

**這個目錄允許使用 Python。**這是專案層級規則的一項明確例外，由專案負責人於
2026-09-05 給出。

## Why this file exists / 這個檔案為什麼存在

Not to explain Python. To stop it being removed.

On 2026-09-05 every Perl call was swept out of `multissh` and `swift_tar` --
including every `shasum`, which is a Perl script despite looking like a C tool.
Two direct `perl -MTime::HiRes` calls became `zmodload zsh/datetime`, and
thirteen `shasum -a 256` call sites became `sha256sum`. The commit messages
describing that sweep are emphatic, and the same sweep grepping for `python3`
finds a great deal of it right here: arithmetic in `batch_vs_per_frame.zsh` and
`test_interframe.zsh`, a numpy dependency in the latter, and two first-class
`.py` programs (`build_streaming_budget.py`, `palette_vs_predictive.py`).

The next reader with a tidy-up instinct will find that and assume it was missed.
It was not. It was raised and explicitly allowed.

不是為了解釋 Python，而是為了阻止它被移除。

2026-09-05 那一輪把 `multissh` 與 `swift_tar` 裡所有的 Perl 呼叫掃乾淨，包括每一個
`shasum`——它看起來像 C 工具，實際上是一支 Perl 腳本。兩處直接的
`perl -MTime::HiRes` 改為 `zmodload zsh/datetime`，十三個 `shasum -a 256` 呼叫點改為
`sha256sum`。那些 commit 訊息語氣很強，而同一輪若改去 grep `python3`，會在這個目錄裡
找到大量結果：`batch_vs_per_frame.zsh` 與 `test_interframe.zsh` 用它做算術、後者還依賴
numpy，另有兩支獨立的 `.py` 程式。

下一個帶著整理習慣的人會看到這些，並認定它們是漏掉的。它們不是漏掉的——這件事被提出過，
而且被明確允許。

## Scope / 適用範圍

The exception covers this directory. It is not a general licence to add Python
elsewhere in `multissh`, `swift_tar` or `lzfse2`.

The Perl rule is unchanged and still applies here: do not introduce `perl`, and
do not use `shasum` (use `sha256sum`, which is present on all four nodes while
`shasum` is absent on the Buildroot guest).

本例外僅適用於這個目錄，不構成在 `multissh`、`swift_tar` 或 `lzfse2` 其他地方加入
Python 的通行證。

Perl 的規則不變，在這裡同樣適用：不要引入 `perl`，也不要使用 `shasum`（請用
`sha256sum`——四個節點都有，而 Buildroot guest 上沒有 `shasum`）。
