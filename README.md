# Trinity‑TPS 開発者向け README（日本語版 完全統合）

> **目的**
>
> * このドキュメントだけで **Trinity (GridTPS エントリーエンジン)** と **TPS (Pivot Set 追随エンジン)** の全ロジックを再構築できることを目指す。
> * 「次に何を書けばよいか」「どこを改造すればよいか」で迷ったら、まずここを読む。
> * **o3**（本 AI）がロジックを失念した時も、この README を読めば 3 分で再同期できるレベルの密度にしている。

---

## 0. 用語集

| 用語                    | 意味                                                               |
| --------------------- | ---------------------------------------------------------------- |
| **GridSize**          | 1 グリッドの価格幅（pips ではなく価格値）                                         |
| **Row (行)**           | 直近 Pivot 行から価格が何グリッド離れたか。<br>+n は上昇方向、−n は下降方向。                  |
| **Pivot**             | Row の符号が反転した点（例: … →2→1→0→-1→… なら +2 と -1 が Pivot）               |
| **Column (列)**        | エンジン内部で付与する建玉セット ID。常に **偶数\:Sell 偏 / 奇数\:Buy 偏** になるとは限らないので注意。 |
| **TrendPair**         | そのグリッドでトレンド方向を追随する Buy/Sell 1 本ずつのペア (例: Col1/Col2, Col3/Col4 …) |
| **ROLE\_TREND**       | 現行ペア。Pivot で ALT/PROFIT 等にロールされるまで「現役」                           |
| **ROLE\_ALT**         | 反転時の種(タネ)玉。必ず **Row=n 全セルに 1 枚** を維持する。                          |
| **ROLE\_PROFIT**      | Pivot 直後に利確対象としてマークされた列。                                         |
| **ROLE\_PENDING**     | 空列。過去 ALT を全決済して空になった列がここへ戻る。                                    |
| **Alternate (ALT) 列** | ROLE\_ALT の列を総称。Buy/Sell を 1 グリッド毎に交互に入れ替える。                     |
| **WeightedClose**     | ALT 列が “損益合計≥0 かつ 奇数枚 かつ 3 枚以上” で列丸ごと一括決済。=> BE 決済に統一。           |

---

## 1. Trinity の責務

1. **常時エントリー** : 市場が動く限りひとつ以上の TrendPair を開き続ける。
2. **Pivot 監視** : Row の符号反転だけを Pivot と判定。Pivot ごとに TrendPair を新設。
3. **Alternate 敷設** : Pivot 直後に ALT 2 列の種玉を敷設、以降はグリッド毎にロール。
4. **BE 決済** : WeightedClose 条件を満たした ALT 列を丸ごとブレイクイーブン決済。
5. **Equity Target** : 口座 Equity が `startEquity + InpTargetEquity` に達した瞬間、全建玉を即時一括決済して内部状態をリセット。

> Trinity は “ベースラインの玉張り職人”。**損大利小** を厭わずガンガン張る。

---

## 2. TPS の責務

1. **Pivot セット管理** : Trinity が作った **１つ前の Pivot 行** に存在する全建玉（Buy/Sell/ALT）を 1 セット扱いとして追跡。
2. **追加利食い** : セット内部で “最安値 Buy / 最高値 Sell” を除く全玉が ±0 になった瞬間、残玉を加重平均決済して厚めの利を抜く。
3. **トレンド追随** : Trinity が Row をロールしている間は **TPS は何もしない**。Pivot 毎にのみ動く。
4. **独立マジック番号** : TPS 側 EA には Trinity と衝突しない別 `InpMagic` を割り振る。

> TPS は “山谷パックの回収係”。**勝ち逃げ専用** であり、建玉は必ず Trinity 由来。

---

## 3. フロー詳細（Trinity）

```
OnTick →
  ├─① Row チェック (bid vs rowAnchor)
  │    ├─ +Grid → StepRow(+1)
  │    └─ -Grid → StepRow(-1)
  │
  ├─② CheckProfitClose()    // ROLE_PROFIT の列のみ
  ├─③ CheckWeightedClose()  // ROLE_ALT の列のみ
  └─④ CheckTargetEquity()   // 口座全体
```

### 3‑1. StepRow の仕事

| 順序  | 処理                | 説明                                                |
| --- | ----------------- | ------------------------------------------------- |
| 1   | Pivot 判定          | `trendSign != 0 && dir != trendSign`              |
| 2‑a | **Pivot 時**       | `FixTrendPair`→`CreateTrendPair`→`SeedPivotAlts`  |
| 2‑b | **継続時**           | `SafeRollTrendPair` で現役 TrendPair をそのまま 1 行上/下へ移動 |
| 3   | Pending→Trend 昇格  | 前回 WeightedClose で空になった列を再利用                      |
| 4   | RollAlternateCols | 既存 ALT 全列を **現行 Row** へ張り直し                       |
| 5   | 状態更新              | `lastRow=newRow; trendSign=dir;`                  |

### 3‑2. Alternate のルール

* **altRefRow / altRefDir** : 列内すべての張り直しの基準。
* `AltDir(col,curRow)` : `(curRow - altRefRow) % 2 == 0` で dir 反転。
* **Pivot 行** では `SeedPivotAlts` が **ALT 2 列のみ** を敷設。
* **通常行** は `RollAlternateCols` が全 ALT 列を張り直す。

---

## 4. フロー詳細（TPS）

> **※実装は別 EA／別 README で管理。ここでは最小の握りを記す。**

1. Trinity が Pivot を確定したら、TPS はその行を **SetID++** で記録。
2. 各 Set には

   * 最安値 Buy チケット
   * 最高値 Sell チケット
   * それ以外（ミドル玉）
     を保持。
3. `Equity(set) ≥ 0` かつ `ミドル玉が奇数枚` になった瞬間、ミドル玉を即時全決済。
4. 最安値 Buy / 最高値 Sell は **Trinity が再びその行を通過するまで** 放置（深追いしない）。

---

## 5. コードレイヤ構成

```
/Trinity-TPS
 ├─ Trinity.mq5     // 本 README に準拠
 ├─ TPS0.2.0.mq5    // Set 決済ロジック (別ファイル)
 ├─ include/
 │    └─ GridCore.mqh   // 共通ヘルパ (Row/Pivot 判定など)
 └─ README_JP.md    // ←本ドキュメント
```

---

## 6. 今後の TODO

1. **Trinity**

   * SafeRollTrendPair 内の Close→Open コスト削減 (同チケット価格変更案)
   * Alt 列が肥大化した際のメモリ圧縮 (MAX\_COL→動的拡張)
2. **TPS**

   * Set 決済アルゴのパラメータ外出し (最安値許容幅 etc.)
   * マルチシンボル対応 (Trinity 1 対 TPS N)
3. **テスト**

   * MQL5 Strategy Tester 用 “リプレイスクリプト” で 5 月 27 日建玉 CSV を自動照合
   * GitHub CI: PR 時に 2023‑2025 のヒストリカルテストを Jenkins で回して PnL 逸脱を検出

---

## 7. Q & A チートシート

| 質問                      | 即答                                                                      |
| ----------------------- | ----------------------------------------------------------------------- |
| **Pivot はどこ?**          | Row の符号が反転した行 (Row=0 になるとは限らない)                                         |
| **初期ペアを毎行決済する?**        | しない。Pivot 時だけ TrendPair を更新。継続時はロールのみ。                                  |
| **Alternate 列はいつ張り直す?** | Pivot 行: `SeedPivotAlts` で 2 列だけ。<br>通常行: `RollAlternateCols` で全 ALT 列。 |
| **WeightedClose の閾値?**  | `Sum(Profit) ≥ 0` かつ **(枚数 >=3 && 奇数)**                                 |
| **Equity Target**       | `startEquity + InpTargetEquity` に到達した瞬間、Trinity が全建玉をクローズしてリセット         |
| **TPS はどう絡む?**          | Pivot 行ごとに 1 セットとして後追い利確するだけ。Trinity の建玉を増やしたりはしない。                     |

---

これで **README\_JP.md** は完成。以後、ロジックを見失ったらここに戻ること。
