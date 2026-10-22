# RGB1 verifications / RGB1 驗證

**Python is allowed here.** This directory is an explicit exception to the
project-wide rule against Perl and hand-rolled scripting dependencies, granted by
the project owner.

**這個目錄允許使用 Python。**這是專案層級規則的一項明確例外，由專案負責人給出。

## Do not remove the Python here / 不要移除這裡的 Python

The Python in this directory is intentional, not something a Perl/scripting
cleanup missed: arithmetic in `batch_vs_per_frame.zsh` and `test_interframe.zsh`,
a numpy dependency in the latter, and two first-class `.py` programs
(`build_streaming_budget.py`, `palette_vs_predictive.py`).

這個目錄裡的 Python 是刻意保留的，不是 Perl／腳本清理時漏掉的：
`batch_vs_per_frame.zsh` 與 `test_interframe.zsh` 用它做算術、後者還依賴 numpy，
另有兩支獨立的 `.py` 程式（`build_streaming_budget.py`、`palette_vs_predictive.py`）。

## Scope / 適用範圍

The exception covers this directory. It is not a general licence to add Python
elsewhere in `multissh`, `swift_tar` or `lzfse2`.

The Perl rule applies here too: do not introduce `perl`, and do not use
`shasum`, which is a Perl script (use `sha256sum`, which is present on all four
nodes while `shasum` is absent on the Buildroot guest).

本例外僅適用於這個目錄，不構成在 `multissh`、`swift_tar` 或 `lzfse2` 其他地方加入
Python 的通行證。

Perl 的規則在這裡同樣適用：不要引入 `perl`，也不要使用 `shasum`——它是一支 Perl
腳本（請用
`sha256sum`——四個節點都有，而 Buildroot guest 上沒有 `shasum`）。
