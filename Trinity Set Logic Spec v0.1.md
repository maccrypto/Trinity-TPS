# Trinity 引き継ぎノート v2 (2025‑07‑27)

## 0. サマリ（現状と目的）

* **現況**: コードは **コンパイルOK**。本日は日曜日でマーケット休場のため、**ドライラン挙動の確認が中心**（`rc=10018` 相当の market closed 系ログが想定どおり出力）。
* **目的**: 次担当がすぐテスト・改修に入れるよう、実装仕様／ジャーナル／テスト計画／次アクションを一枚に集約。

---

## 1. 実装仕様（確定ポイント）

### 1.1 役割と列

* `ROLE_TREND`, `ROLE_ALT`, `ROLE_PROFIT` の3種。
* `colBuy`, `colSell` はアクティブなトレンド対。ピボット検知で旧トレンドを `PROFIT/ALT` に昇格し、新しいトレンド対を生成。

### 1.2 週末・休場対応（ドライラン）

* `IsWeekend()` により休場簡易判定（日曜/土曜）。
* `g_dryRunIfMarketClosed=true` の場合、**約定要求はブローカーに出さず**にロジックのみ前進：

  * 新規：`[NEW-SIM]` を出し、列状態（`colTab[col]`）は更新。
  * クローズ：`[CLOSE-SIM]` を出し、ブローカーへの実クローズはスキップ。
* 休場中は実口座ポジションが動かないため、**`CheckWeightedClose()`\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\* はスキップ**（誤判定防止）。

### 1.3 ALT の建玉運用

* `UpdateALT()` は **既存ALTをクローズせず**、**直前サイドの逆サイドを追建て**。
* `lastFlipRow` で同一rowの多重反転を抑止。

### 1.4 Weighted‑Close（確定版仕様）

* 対象：`ROLE_ALT` カラムのみ。
* 条件：

  1. **玉数が3以上の奇数**かつ、
  2. **カラム内の全ポジション損益 ≥ 0**（最小損益 `minP >= 0`）
* 条件成立時：同カラムを一括クローズ（`CloseColumn`）し、`ROLE_NONE` に落として再利用停止。
* 備考：現行条件では **`g_wclose_eps`**\*\* は未使用\*\*（将来「全玉 ≥ −eps」に緩和したい場合は利用候補）。

### 1.5 口座モードの前提

* ログで `MarginMode=2 (HEDGING)` を出力。
* **HEDGING 口座必須**。Netting ではALT多重建てが統合され、Weighted‑Close 条件（奇数≥3 & 全玉≥0）が成立しない。

---

## 2. 主要関数メモ

* `Place(int orderType,int col,int row,ROLE role)`

  * 週末時は `[NEW-SIM]` で列状態のみ更新。
* `CloseColumn(int col)`

  * 週末時は `[CLOSE-SIM]` でブローカー操作をスキップ。
* `UpdateALT(int row)`

  * ALTの逆サイド追建て。クローズはしない。
* `HandleFirstMove/HandlePivot/HandleTrendRoll`

  * 役割遷移と新トレンド対の生成。
* `ColumnStats(int col, int &count, double &minProfit, double &netProfit)`

  * カラム内のポジション数・最小損益・合計損益を集計。
* `CheckWeightedClose()`

  * 週末時はスキップ。平日に実ポジが存在する状況で上記条件を判定。
* `IsWeekend()`

  * `TimeToStruct(TimeTradeServer())` を使った簡易土日判定（環境差を抑制）。

---

## 3. 実行パラメータ（現行）

* `_lot = 0.01`
* `_magicBase = 900000`
* `g_dryRunIfMarketClosed = true`
* `g_wclose_eps = 50.0`（※現行の Weighted‑Close 条件では未使用）

---

## 4. 最新ジャーナル（週末・休場ドライラン）

* 概況：開始時に `MarginMode=2 (HEDGING)` を出力。`OrderSend` は `rc=10018` 系の **market closed** で失敗ログ（想定どおり）。
* `NEW-FAIL/CLOSE-FAIL` が並ぶのは、**休場中にブローカーが約定を拒否**するためで、設計どおり。
* `W-CLOSE-DBG` は休場ビルドによっては出力される場合あり（最新版では休場中に判定をスキップ）。

```text
2025.07.27 17:59:05.130    TrinityReplayTest (USDJPY,M1)    [Replay] start
2025.07.27 17:59:05.130    TrinityReplayTest (USDJPY,M1)    [ENV]  MarginMode=2 (HEDGING)
2025.07.27 17:59:05.384    TrinityReplayTest (USDJPY,M1)    CTrade::OrderSend: market sell 0.01 position #52859507644 USDJPY [market closed]
2025.07.27 17:59:05.637    TrinityReplayTest (USDJPY,M1)    CTrade::OrderSend: market buy 0.01 position #52859507603 USDJPY [market closed]
...（中略：market closed 系の NEW-FAIL/CLOSE-FAIL が継続）...
2025.07.27 17:59:20.385    TrinityReplayTest (USDJPY,M1)    [Replay] end lastRow=0 steps=8
```

> 解析要点：`rc=10018`（market closed）により実約定は発生せず、**ロジックはdry-runで前進**する。HEDGING 環境がログで明示されているため、口座モード誤認は無し。

---

## 5. テスト計画（平日：開場時）

1. **起動直後の環境ログ**

   * `[ENV] MarginMode=2 (HEDGING)` を確認。
2. **Trend/ALT 回転の基本動作**

   * `HandleFirstMove/HandlePivot/HandleTrendRoll` の `[ROLE]` と `[NEW]` の整合を確認。
3. **ALT の累積**

   * 同一 ALT カラムで**奇数（3,5,7…）の建玉**が積み上がることをログで確認（`[ALT] row=... c=...` が交互に記録）。
4. **Weighted‑Close の発火**

   * 条件：`cnt` が奇数≥3、`minP >= 0` 到達。
   * 発火時に `[W-CLOSE] c=.. cnt=.. net=.. (all >=0)` と **カラムの ************************************************************`ROLE_NONE`************************************************************ 落とし** を確認。
5. **回帰**

   * 週末に戻して dry-run が継続すること（`NEW-FAIL`/`CLOSE-FAIL` or `[NEW-SIM]/[CLOSE-SIM]`）を再確認。

---

## 6. 次アクション

* \[担当A] 平日オープン後に **同一条件でリプレイ** → ジャーナルを Canvas のこの章に追記。
* \[担当B] Weighted‑Close の**緩和版**（`全玉 ≥ −eps`）をオプション化する案を検討（`g_wclose_eps` を再活用）。
* \[担当C] 休場中でも損益を動かせる **仮想台帳**（内部PnL）設計草案を作成（擬似価格レールでの評価損益）。

---

## 7. 運用ノート（チャット軽量化のコツ）

* ログは **Canvas 側に全文**、チャットは **要点のみ** に分離。
* テストごとに「開始～終了」範囲だけを貼付し、**長すぎる場合は分割**（Part1/Part2）。
* 変更は **差分（関数単位）** を貼ると読みやすい。

---

## 8. 付録：用語とコード断片（参照）

* retcode 周辺：`rc=10018` は休場由来。週末は `OrderSend/PositionClose` が拒否されるのが通常挙動。
* 関連ログタグ：`[ENV] [NEW] [NEW-SIM] [NEW-FAIL] [CLOSE] [CLOSE-SIM] [CLOSE-FAIL] [ALT] [ROLE] [W-CLOSE] [W-CLOSE-DBG]`。

---

### 9. 「新しいパト」追加実装（受領待ち）

* 目的：
* 発火条件：
* 具体動作：
* 評価指標：

> 仕様を受領次第、この章に詳細とタスクを追記します。

---

**以上** — 次担当は、このノートの「テスト計画」に沿って平日開場時の検証を実施し、結果ログを本Canvasに追記してください。

新しいパトとは現在未実装のLogicを新しいパーツと書き間違い。
