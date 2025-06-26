# Trinity‑TPS 統合プロジェクト ― 開発計画書

## 1. 目的

Trinity（グリッド＆交互エントリー）と TPS（Take‑Profit Sets／Safe‑Roll）を統合した EA を **堅牢かつ拡張性の高い状態** で完成させ、実運用・ストレステストまでを一気通貫で進める。

## 2. 現行リポジトリ構成（`main` ブランチ）

```
src/
├─ trinity1.0.3.mq5          : Trinity コア（安定版）
├─ TPS0.2.0.mq5              : TPS モジュール（β版）
├─ TPSSetManager.mqh         : TPS 補助クラス
└─ TrinityTPS_Integrated_v1.mq5 (任意)
```

* **raw 取得用 URL** は `https://raw.githubusercontent.com/maccrypto/Trinity-TPS/main/src/...`
* ドキュメント類は後述 `docs/` ディレクトリに配置。

## 3. ブランチ戦略（Git Flow 準拠）

| ブランチ        | 用途                                 |
| ----------- | ---------------------------------- |
| `main`      | リリース済み安定版。常にコンパイル可能＆バックテストパス       |
| `develop`   | 次リリース用統合版。Pull Request はここへマージ     |
| `feature/*` | 個別機能開発（例: `feature/alt-cell-lock`） |
| `hotfix/*`  | 本番バグ緊急修正                           |

## 4. 開発フェーズ & マイルストーン

### **Phase 0 環境整備（M0）**

* [ ] GitHub Actions で **MQL5 MetaEditor CLI コンパイル**→ artefact 保存
* [ ] Strategy Tester `.set` とヒストリカルデータのバージョン固定手順を `docs/env.md` に記載

### **Phase 1 Trinity 安定化（M1）**

*目標: 同一セル重複エントリー 0・Pivot 処理完全一致*

1. `feature/cell-lock` : `HasPos()` をビットマップロック方式に変更
2. `feature/profit-close-fix` : min‑Buy –1 判定バグ修正 & 単体テスト
3. **回帰テスト**: 上昇→下降→再上昇３サイクル

### **Phase 2 TPS 差分再導入（M2）**

*目標: Safe‑Roll／SetID／WeightedClose を統合し、セル重複無しで動作*

1. `feature/set-id` : SetID 付与のみを埋め込み
2. `feature/weighted-close-set` : 加重平均クローズを Set 集計に置換
3. `feature/profit-bs-chain` : ProfitClose → BS エントリー連鎖実装
4. **統合テスト**: 3 ヒストリ期間 × 3 通貨ペア

### **Phase 3 ストレス & 本番準備（M3）**

* マルチセット 512 Col／2,048 Col 拡張試験
* 通貨横断フォワード（デモ）30 日走行
* `docs/release_notes_v3.md` 作成→ `main` にタグ `v3.0`

## 5. Issue テンプレート（`docs/issue_template.md`）

````
### 概要
<簡潔に>  

### 再現手順
1. …
2. …

### 期待結果
- [ ] …

### 実際の結果
ログ: ```
<抜粋>
````

### 追加情報

バックテスト set / ヒストリ URL など

```

## 6. コーディング規約
- **MQL5 標準ライブラリのみ使用** (`Trade\Trade.mqh` 他)
- 株式会社名／バージョンは `#property version "x.y"` のみ更新
- 変数命名: `gGlobal`, `sStatic`, `lLocal` プレフィックス廃止 → `camelCase`
- 魔法数字禁止：すべて `const double GRID_SIZE_PIPS = 50;` 形式

## 7. コミットメッセージ規約（Conventional Commits 拡張）
```

fix(trinity): duplicate cell entry lock
feat(tps): weighted-close by set total
refactor(core): extract position utils

```

## 8. CI / CD
- **GitHub Actions** ワークフロー `ci.yml`
  1. MetaEditor CLI で `.mq5` をビルド
  2. 成功時 artefact とコンパイルログを保存
  3. 失敗時 PR に自動コメント

## 9. テスト指針
| 種別 | ツール | 成功基準 |
|---|---|---|
| 単体テスト | `assertEquals` マクロ | 100 % pass |
| バックテスト | Strategy Tester CLI | Net Profit > 0／エラー 0 |
| フォワード | デモ口座 | 30 日間ドローダウン < 5 % |

## 10. エスカレーション手順
1. 重大バグ → `hotfix/*` ブランチ＋Issue `severity:critical`
2. Discord/Slack 共有（任意）
3. 修正後 24 h 以内に `main` へタグ付きマージ

## 11. 参考リンク
- Trinity v1.0.3 raw: <https://raw.githubusercontent.com/maccrypto/Trinity-TPS/main/src/trinity1.0.3.mq5>
- TPS0.2.0 raw: <https://raw.githubusercontent.com/maccrypto/Trinity-TPS/main/src/TPS0.2.0.mq5>
- MQL5 CLI docs: <https://www.mql5.com/en/docs/editor_metaconsole>

---
*最終更新: 2025‑06‑26*

```
