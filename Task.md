| タスク順   | 関数 / モジュール                           | 目的                    | 主要修正点                                                                                                      |
| ------ | ------------------------------------ | --------------------- | ---------------------------------------------------------------------------------------------------------- |
| **T1** | `CheckWeightedClose()`               | ブレイクイーブン決済を確実に発火      | - EPS を **動的スプレッド許容幅**に変更<br>- `altClosedRow` を「直後 1 行のみ再建禁止」に緩和<br>- `colTab[].role` を `ROLE_PENDING` に戻す |
| **T2** | `CheckProfitClose()`                 | Pivot 利食い実装バグ修正       | - `profit.active` フラグと `profit.refRow` の整合性<br>- トリガー条件を「Pivot 行から ±1 グリッド」だけに簡素化                          |
| **T3** | `FixTrendPair()` & `Place()`         | 利食い後の **同一カラム再エントリー** | - 決済直後 **同じ Col** に `ROLE_ALT` で Sell/Bu y を建て直す<br>- `profit.rebuildCol` ロジック整理                           |
| **T4** | `AltDir()` / `UpdateAlternateCols()` | ALT 列 Buy↔Sell 交互ズレ修正 | - `altRefDir` 初期化ルールを一貫化<br>- `(curRow - altRefRow) & 1` で偶奇反転                                             |
| **T5** | ロギング強化                               | デバッグ効率向上              | - 各決済／発注時に `[WEIGHTED]`, `[PROFIT]`, `[ALT]` タグ付与                                                          |
