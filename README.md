
# Trinity-TPS 統合 EA プロジェクト

> **最新ビルド:** `Trinity-TPS_Integrated_V1.mq5`  
> **開発ブランチ:** `main`  ─ 安定版 / `dev-o3`, `dev-o4` ─ AI 別作業ライン

---

## 1. 概要
- **Trinity v1.0.3** の *Trend-Pair / Pivot 昇格ロジック* と  
- **TPS v0.1.0** の *Alternate ±0 (WeightedClose) / Profit 列決済* を 1 本の MQL5 EA に統合。  
- **グリッド幅 0.5 円（=500 point）**, 固定 Lot, TP/SL なし。  
- コード作成上の禁止事項（存在しない関数, MQL4 マクロ, 直接構造体初期化 など）を厳守。

---

## 2. フォルダ構成
| パス | 説明 |
| ---- | ---- |
| `/Trinity-TPS_intergrated_V1.mq5` | 統合最新版 |
| `/Trinity1.0.3.txt` | 旧 Trinity リファレンス |
| `/TPS0.1.0.txt` | 旧 TPS リファレンス |
| `/docs/` | 仕様書・参考資料 |
| `/README.md` | このファイル |

---

## 3. 主要仕様

| 機能 | 状態 | 備考 |
| --- | :---: | --- |
| Trend-Pair 常時 2 列 | ✅ | `trendBCol / trendSCol` |
| Pivot ⇒ Profit & Alt 昇格 | ✅ | |
| 先乗せ BS 2 列 | ✅ | `bs1 / bs2` |
| Alt 列 WeightedClose BE | ✅ | Col 単位 BE、Min-B 除外 |
| Profit 列 WeightedClose | ✅ | Min-B 更新で最高値 S 利食い |
| Col 拡張 (90 %) | ⏳ | `EnsureCapacity()`・上限 2048 |
| Spread/手数料補正 | ⏳ | `InpCostPoints` (point 単位) |
| デバッグ切替 | ⏳ | `InpDebug = true/false` |

---

### 3-A. TPS (Trinity Profit Stream)

1. **Min-B 定義**  
   - セット（4 Col）内で *最安値 Buy かつ最古チケット* を **Min-B** とする。  

2. **Min-B 更新トリガ**（同一 Tick）  
   | 手順 | 処理 | 目的 |
   | ---- | ---- | ---- |
   | ① | 最高値 Sell を利食い（存在すれば） | 利益確定 |
   | ② | Min-B の 1 グリッド下に Sell 新規建て | 先乗せ BS 開始 |
   | ③ | 新 Trend-Pair を次行に建て、再び Min-B を作成 | Min-B 恒常化 |

3. **Alternate BE**  
   - BS カラムは **Col 単位** で WeightedClose（±0）を繰り返し、最終的に Min-B だけ残す。

---

### 3-B. Point / Price 換算

```text
gridPoints   = (int)MathRound( InpGridYen  / _Point );   // 500 point (USDJPY) 等
costAdjPrice =              InpCostPoints * _Point;      // コスト補正
