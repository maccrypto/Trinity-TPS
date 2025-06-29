# 引継書（Trinity‑TPS プロジェクト）

## 目的

* 現状・未解決点・作業フローを明文化し、次のアシスタント／開発者が即座に再開できるようにする。
* **GitHub Actions での自動ビルド／テスト**案と**ローカル PC でテスト → GitHub へ push**案の両方を提示する。

---

## 1. リポジトリ構成 <small>(2025‑06‑29 現在)</small>

```text
Trinity-TPS/
├─ src/
│   └─ trinity1.0.3.mq5          # 現行 EA 本体
├─ .github/
│   └─ workflows/
│       └─ ci.yml                # GitHub Actions ワークフロー
└─ README.md
```

* **メインブランチ :** `main`
* **実験ブランチ :** `feature/fix-cell-reuse`  ← WeightedClose / Alternate 修正用

---

## 2. 技術的課題リスト

| # | 症状・要求                | 現状メモ                                                                                                        |
| - | -------------------- | ----------------------------------------------------------------------------------------------------------- |
| 1 | WeightedClose が発動しない | `CheckWeightedClose()` が `ROLE_ALT` かつ `posCnt ≥ 3` (奇数) & EPS 判定。スプレッド許容幅が過大、または `altClosedRow` ロック解放漏れ疑い。 |
| 2 | Col1 が交互エントリーしない     | `altRefDir` の符号管理と `AltDir()` 算出が不一致で BUY/SELL が逆転。                                                         |
| 3 | CI パイプラインが安定しない      | Linux/Wine ルートは DLL 依存で停止。Windows Runner + PowerShell は「MetaEditor パス未検出」or「インストーラ DL 失敗」で停止。               |
| 4 | テストデータ容量が大きい         | GitHub Actions ランタイムでヒストリ同期がタイムアウト → ローカルテスター案を検討中。                                                         |

---

## 3. 推奨フロー①：ローカル PC でテスト → GitHub へ push

### 手順

```bash
git checkout feature/fix-cell-reuse
git pull

# MetaEditor で src/trinity1.0.3.mq5 を修正・コンパイル
# 成功した EX5 を build/ へ保存

# ストラテジーテスターでバックテスト
# レポートを report/Trinity_$(date +%Y%m%d).html に出力

git add src/trinity1.0.3.mq5 build/*.ex5 report/*.html
git commit -m "Fix WeightedClose logic + test report"
git push origin feature/fix-cell-reuse
```

PR を作成し、レビュー担当（次期アシスタント）が差分を確認して追加パッチを提案。

**利点**

* MT5 環境が手元にあるためテストが安定。
* GitHub Actions を "コンパイルエラー検知" 専用に縮小できる。

---

## 4. 推奨フロー②：GitHub Actions でフルテスト

`.github/workflows/ci.yml` を以下テンプレで置換すると、少なくとも「MetaEditor が見つからない」問題が解消する見込み。

```yaml
name: MT5-CI

on:
  push:
    branches: [ main, feature/fix-cell-reuse ]
  pull_request:
  workflow_dispatch:

jobs:
  test:
    runs-on: windows-latest

    steps:
    - uses: actions/checkout@v4

    - name: Download & Install MT5
      shell: pwsh
      run: |
        $url  = 'https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe'
        $dest = "$env:TEMP\\mt5setup.exe"
        Invoke-WebRequest $url -OutFile $dest -UseBasicParsing
        Start-Process -FilePath $dest -ArgumentList '/silent','/dir=C:\\MT5' -Wait
        "C:\\MT5" | Out-File -FilePath $env:GITHUB_PATH -Encoding ascii -Append

    - name: Compile EA
      shell: pwsh
      run: |
        $editor = Get-ChildItem 'C:\\MT5' -Recurse -Include 'metaeditor*.exe' | Select-Object -First 1
        if (-not $editor) { throw "MetaEditor not found" }
        New-Item -ItemType Directory build -Force | Out-Null
        & $editor.FullName /compile:src\\trinity1.0.3.mq5 /log:build\\compile.log /portable /quiet

    # Strategy Tester を走らせる場合は tester64.exe を同様に呼び出す
```

**注意**

* Windows Runner の実行時間上限は **60 min**。長期バックテストは `FromDate` を短縮するかローカル実行を推奨。

---

## 5. 残タスクと優先度

| 優先  | タスク                                                                                |
| --- | ---------------------------------------------------------------------------------- |
| ★★☆ | **WeightedClose 改修** : `posCnt ≥ 3` 条件緩和 + EPS を `SYMBOL_TRADE_TICK_VALUE` などで動的計算 |
| ★★☆ | **Alternate 列ロジック修復** : `altRefDir` 記録と `AltDir()` 反転ロジックの整合性確保                    |
| ★☆☆ | `SafeRollTrendPair` の同 row 多重建てガード強化                                               |
| ★☆☆ | **CI 安定化** : Strategy Tester 部分を省略し "コンパイルのみ" へ切替え or self‑hosted runner 検討        |

---

## 6. 次の担当者へ

* まず `feature/fix-cell-reuse` を最新にしてローカルテストし、問題を再現・デバッグしてください。
* 疑問点は **Issue / PR コメント** にまとめると議論がスムーズです。

---

### 開発環境メモ

```
MetaTrader 5 build ≥ 4150
Symbols : USDJPY (5‑digit)
Timeframe : M1 / H1 バックテスト想定
```

### 参考リンク

* 現行 EA ソース : [https://raw.githubusercontent.com/maccrypto/Trinity-TPS/main/src/trinity1.0.3.mq5](https://raw.githubusercontent.com/maccrypto/Trinity-TPS/main/src/trinity1.0.3.mq5)
