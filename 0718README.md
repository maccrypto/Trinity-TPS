WeightedCloseを起点としたTrinityロジック修正工程とBEテスト対策

Trinity-TPS 現状分析と改修ロードマップ
現在の実装状況と課題
WeightedClose（ブレイクイーブン決済）: コード上はCheckWeightedClose()関数が実装され、ALT列でポジション数が3以上の奇数かつ合計損益がほぼゼロの場合に列内ポジションを一括クローズするロジックになっています
raw.githubusercontent.com
。しかし現在、このWeightedCloseが発動していない状態です
raw.githubusercontent.com
。原因として、許容損益幅（EPS）の設定やaltClosedRowによる再エントリ抑制が適切に機能しておらず、条件を満たしてもトリガーされないケースがあると考えられます
raw.githubusercontent.com
。また、実装上は損益合計の絶対値 < 1e-9（実質ゼロ）という厳しい条件になっており、スプレッドを無視したユニットテスト環境ではともかく、本番環境では閾値が厳しすぎる可能性があります。
利食い（Profit-taking）ロジック: Pivot発生時に旧トレンドペアの一方を利確対象（ROLE_PROFIT）に設定し、価格がPivot行から1グリッド逆行したときに当該列のポジションを全決済する仕組みが実装されています（CheckProfitClose()関数）
raw.githubusercontent.com
。現状、この利食い処理はPivot後の戻しで発動するはずですが、期待通り動作していないようです。具体的には、Pivotが下降転換したケースで利益確定すべきBuy列の決済が行われない、あるいは決済後の処理が適切でない可能性があります。profit.activeフラグ管理やトリガー判定条件（現在Bid <= Pivot行-1の価格）にバグがあり、想定シナリオで発火していない可能性があります。
利食い後の再エントリー: 利食い決済後、同じ列にSellエントリーを建て直す処理が用意されています。CheckProfitClose()内では利確後にprofit.refRow - 1行にSellを1ポジション入れるロジックがあります
raw.githubusercontent.com
。現在のコードでは、この再エントリーにprofit.rebuildCol（Pivot時に設定されたALT列）を使用し、Sell建玉をALTfirst=trueで発注しています。しかし、この再エントリー処理が正しく機能していないようです。テストでは期待していた「r-1 行のSellエントリー」が発生せず
raw.githubusercontent.com
、同一カラムに再エントリーできていない状況です。原因として、profit.rebuildColの設定ミスや、利確後に列の役割更新（ROLE_ALTへのロール戻し）が不足していることが考えられます。
Alternate列のエントリーロジック: Pivot直後に設定されるALT列（交互エントリー列）の挙動にも未実装・不具合があります。初回ALT列（例: Col1）の売買方向が交互にならない問題が報告されており
raw.githubusercontent.com
、altRefDirの記録とAltDir()での反転ロジックが一致していないことが原因とされています
raw.githubusercontent.com
。現在のコードではPivot時にaltRefRowとaltRefDirを設定し、以降UpdateAlternateCols()で各グリッド移動毎にAltDir()計算でBuy/Sellを交互発注する方針です
raw.githubusercontent.com
。しかしALT初期方向の符号管理にバグがあり、Col1が常に同じ方向のポジションを持つなど、交互エントリーが正しく機能していません。
以上のように、WeightedCloseによるブレイクイーブン決済が機能しておらず、利食い＆再エントリー処理も期待通り動いていないため、グリッド戦略の核心部分である損益ゼロ決済と利確後の張り直しが停滞しています。またALT列交互ロジックの不具合により、基本的なBuy/Sell交互建てが乱れる恐れがあります。
改修タスクの優先順位と工程計画
上記課題を踏まえ、1ターン＝1機能のペースで以下の順序で修正を進めます
raw.githubusercontent.com
。各タスクで修正すべきポイントと対応方針を示します。
WeightedCloseの修正（ブレイクイーブン判定）
現状: ALT列のポジション合計損益が±0になるタイミングで列ごと決済する機能が発動していません
raw.githubusercontent.com
。
修正方針: ブレイクイーブン判定ロジックの見直しを行います。具体的には、スプレッドを考慮した微損益でも発動するようEPS幅の動的計算を導入し、判定条件を若干緩和します（例：Tick Valueから1ピップ相当額を算出し閾値とする）。また、altClosedRowの扱いを再検討し、決済直後の行では再エントリーを防ぐが次の行移動では再開できるよう適切に値を設定します。現在テスト中の**「奇数枚＆中央ポジションで合計損益ゼロなら決済」**というアプローチは有効なので
raw.githubusercontent.com
、ユニットテスト環境ではこの条件（ポジション数nが奇数かつ|lastRow - altRefRow| == (n-1)/2で中心価格到達
raw.githubusercontent.com
）によってブレイクイーブン検出を行います。これにより、本番では難しい厳密ゼロもテスト上は検出でき、以降のロジック検証を継続できます。まずはこのWeightedCloseロジックを確実に発火させ、決済後に該当ALT列がROLE_PENDINGへ戻る（一時的に空列化され再利用待ち状態）ことを確認します
raw.githubusercontent.com
。
利食い（ProfitClose）ロジックの実装修正
現状: Pivot後の価格折り返し時に利確対象列を全決済するCheckProfitClose()がうまく動いていません。Pivot確定時にprofit.active=trueとした列が放置され、利益確定が実行されないケースがあります。
修正方針: Pivot時と利確時のフラグ・条件を再検証します。Pivot発生時のFixTrendPair()で、profit.profitColやprofit.refRowの設定に漏れがないか確認し、特に下降Pivot時に正しくprofitサイクルが開始するよう修正します（下降転換ではSell列をROLE_PROFITにし、Buy列をROLE_ALTとしてprofit.active=trueをセット
raw.githubusercontent.com
）。その上で、CheckProfitClose()内のトリガー条件（現在Bid <= profit.refRow-1価格）を見直し、「Pivot行から1グリッド逆行したら決済」というルール通り確実に検知できるようにします
raw.githubusercontent.com
。例えば現在はCurBidUT() > triggerで早期returnしていますが、この条件が適切か再評価します。利確発動時には当該profitCol内の全ポジションをクローズし、colTab[profitCol].posCntをゼロにする処理を確認・修正します
raw.githubusercontent.com
。さらに、利確済みの列profitColのroleをそのままにせずROLE_PENDINGにリセットすることも検討します。そうすることで、そのカラムを将来的に再利用できるようになり、ロジックの整合性が保てます。
利食い後の同一カラム再エントリー修正
現状: 利確直後にPivot行の1つ手前（refRow - 1）にSellを建て直す処理が実装されていますが
raw.githubusercontent.com
、期待した列にエントリーされていない問題があります（例: 本来Sellを入れるべきカラムでBuyが入らない/入るべきSellが入らないなど）
raw.githubusercontent.com
。現コードではprofit.rebuildCol（Pivot時にALTに設定した列）にSellを入れていますが、これが「同一カラム」に見えない原因かもしれません。
修正方針: 再エントリー戦略の確認と修正を行います。利確対象だった列(profitCol)と再エントリー先の列(rebuildCol)の関係を整理し、ユーザーの意図する「同一カラムへのSellエントリー」が何を指すか確認します。もし利確したのと同じ列でポジションを張り直す意味であれば、再エントリー先を現在のaltColではなく**profitCol自身に変更することを検討します。その場合、利確後にprofitColをROLE_ALTに格下げし直した上で、profitColにSellを建てる流れになります（利確に成功していればその列は空になるため再利用可能）
raw.githubusercontent.com
。一方、現在の実装通りALT列側で継続運用**する戦略であれば、profit.rebuildColの指定に誤りがないかを調べます（Pivot時に適切なALT列をセットしているか
raw.githubusercontent.com
）。また、再エントリー時のPlace(..., isAltFirst=true)呼び出しにより、該当列のaltRefRow/altRefDirが正しく更新されているかを確認します
raw.githubusercontent.com
raw.githubusercontent.com
。この再エントリー修正によって、利確→Sell建て直し→グリッド継続という一連のサイクルが途切れず動作することを目指します。
Alternate列ロジックの修復
現状: ALT列で交互に買い売りを張り直すロジックに不整合があります。特にCol1で交互エントリーが行われず方向がずれるバグが確認されています
raw.githubusercontent.com
。Pivot時のaltRefDir設定やAltDir()の偶奇判定に問題があり、BUY/SELLの切り替えタイミングがずれている可能性があります。現在のコードでは上昇PivotでもaltRefDirを反転させずそのままlastDirを保存しており
raw.githubusercontent.com
、旧バージョンとの仕様差異も疑われます。
修正方針: 代替列の交互張りロジックを再整備します。まず、Pivot発生時のFixTrendPair()で設定するaltRefDirの符号ルールを再検討します。旧実装では「上昇Pivotでは向きを反転、下降Pivotでは反転しない」というルールでした
raw.githubusercontent.com
が、この挙動がCol1ズレの原因となっていた可能性があります
raw.githubusercontent.com
。新しい方針では、Pivot時には常に新ALT列の初回方向を現在価格の進行方向と同じにする（例: Pivot後の下降トレンドではSellから始める）か、一貫した規則を決めて実装します。AltDir(col, curRow)関数の計算も見直し、(curRow - altRefRow) % 2の偶奇で確実にBuy/Sellが交互反転するよう調整します
raw.githubusercontent.com
raw.githubusercontent.com
。特に最初の交互種玉（seed）が正しい方向で入るよう、UpdateAlternateCols(..., seed=true)呼び出し時の処理を追加/修正する予定です。最後に、修正後は各グリッド移動ごとに既存ALT列が交互に建玉することをテストで確認し、Col1を含め全ALT列が期待通りBUY→SELL→BUY…と推移することを保証します。
以上の順序で段階的に修正・テストを行います。まずWeightedCloseでブレイクイーブン決済を正しく機能させ、次にPivot利確と再エントリーの流れを完成させ、最後に交互エントリーの安定動作を確保します。このアプローチにより、Trinityエンジンは損益±0の玉を適切に整理しつつ常時エントリーを維持し、TPS側の利食いセット決済（ミドル玉一括利確）とも矛盾なく連携できる状態になるはずです
raw.githubusercontent.com
。各タスク完了後はユニットテスト（Replayテスト）で挙動を検証し、問題が解消されていることを確認しながら開発を進めていきましょう。
