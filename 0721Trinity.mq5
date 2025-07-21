//+------------------------------------------------------------------+
//|  Trinity.mq5  –  Generic Grid‑TPS Entry Core                     |
//+------------------------------------------------------------------+
#property strict
//────────────────── UNIT_TEST フェイクロジック ────────────────────
#ifdef UNIT_TEST

// テスト時に SetFakeComment() でコメントを入れておくための配列
static string fakeComments[2048];

// テスト時にコメントをセットするヘルパー（テストコード側で呼び出してください）
void SetFakeComment(int idx, const string &cm)
{
    if(idx >= 0 && idx < ArraySize(fakeComments))
        fakeComments[idx] = cm;
}

// Fake_PositionGetString の正しいシグネチャ
bool Fake_PositionGetString(int idx, string &cm)
{
    if(idx >= 0 && idx < ArraySize(fakeComments))
    {
        cm = fakeComments[idx];
        return true;
    }
    cm = "";
    return false;
}

#endif
//───────────────────────────────────────────────────────────────────

#define UNIT_TEST
#include <TrinitySim.mqh>

int lastRow = 0;
int StepCount = 0;

void StepRow(const int r, const int dir)
{
   lastRow = r;
   StepCount++;
}

void SimulateMove(const int targetRow)
{
   if(targetRow == lastRow) return;
   const int dir = (targetRow > lastRow ? 1 : -1);
   int safety = 400;
   while(lastRow != targetRow && safety-- > 0)
      StepRow(lastRow + dir, dir);
}

// （以下、既存の Fake API ブロック / 以降のロジックはそのまま）

#define UNIT_TEST

// ---- 本番用ライブラリは UT では読み込まない -----------------
#ifndef UNIT_TEST
   #include <Trade/Trade.mqh>
   CTrade trade;            // ← 実運用時はこちらを使う
#endif                      // --------------------------------

//────────────────────────── Inputs ───────────────────────────────
input string  InpSymbol       = "USDJPY";   // trading symbol
input double  InpLot          = 0.01;        // lot size
input double  InpGridSize     = 0.50;        // grid width (JPY)
input double  InpTargetEquity = 5000.0;      // target profit (account currency)
input uint    InpMagic        = 20250607;    // magic number
input bool    InpDbgLog       = true;        // verbose logging

//────────────────────────── Types / Globals ──────────────────────
enum ColRole { ROLE_PENDING, ROLE_PROFIT, ROLE_ALT, ROLE_TREND };

#define MAX_COL 2048

static int altClosedRow[MAX_COL + 2];  // ← これ１行だけ
int       curRow = 0;                  // ← 必要ならここで１回だけ定義

struct ColState
{
   uint    id;
   ColRole role;
   int     lastDir;     // +1 Buy / -1 Sell
   int     altRefRow;   // reference row for ALT parity
   int     altRefDir;   // first direction (+1/-1)
   uint    posCnt;      // live positions in column
};
/*―――― ProfitInfo : 利食いサイクルを 1 Pivot 単位でロック ――――*/
struct ProfitInfo
{
   bool active;      // 利食いサイクル中フラグ
   uint profitCol;   // 利確対象列（Pivot で確定・上書き禁止）
   uint rebuildCol;  // r-1 に Sell を再建てする列
   int  refRow;      // Pivot 行
};
static ProfitInfo profit = { false, 0, 0, 0 };
#define MAX_COL 2048
static ColState colTab[MAX_COL + 2];

static double GridSize;
static double basePrice   = 0.0;
static double rowAnchor   = 0.0;
static int    trendSign   = 0;      // +1 / -1 (0 = unknown)
static uint   nextCol     = 1;
static uint   trendBCol   = 0, trendSCol = 0;

// Pivot‑ALT bookkeeping
static uint  altBCol = 0;
static uint  altSCol = 0;
static bool  altFirst = false;

//――― ALT 列が「未シード状態」であることを示す番兵値
const int ALT_UNINIT = -2147483647;   // (= INT_MIN 相当)

static double startEquity = 0.0;

// Forward-declarations ──────────────────
 void CheckWeightedClose();
 void FixTrendPair(int dir, int row);
// ▼ Unit-Test 用 API（この 2 行だけ！） -------------------------
#ifdef UNIT_TEST
void ResetAll();         // ← export 削除
void SimulateMove(const int targetRow); // 形式を本体と一致させる（※ただし本体が既に上にあるならこの行すら不要）
void SimulateHalfStep();

//─────────────────────────────────────────────
//  ★ Unit-Test helper bodies
//─────────────────────────────────────────────
#ifdef UNIT_TEST

// ① すべての内部状態を最初の OnInit と同じ “真っさら” に戻す
void ResetAll()
{
   /*―― Fake ポジションプールを初期化 ――*/
   fakeCnt = 0;
   nextTk  = 1;
   _fpIdx  = -1;

   /*―― グローバル管理変数をリセット ――*/
   GridSize   = InpGridSize;
   basePrice  = rowAnchor = CurBidUT();
   lastRow    = 0;
   trendSign  = 0;
   nextCol    = 1;
   trendBCol  = 0;
   trendSCol  = 0;
   profit.active = false;
   // ★ 初期利益基準をアカウントの現在エクイティに合わせる
   startEquity   = AccountInfoDouble(ACCOUNT_EQUITY);

   /*―― テーブル類をクリア ――*/
   ClearColTab();
   ArrayInitialize(altClosedRow, -9999);

   // TREND ペアの初期シード
   //    dir は初期なので使いませんが、2 引数版に合わせて 0, 0 を渡します
   FixTrendPair(0, 0);
}


//─────────────────────────────────────────
// TREND ペアを指定行で組むヘルパー関数
//─────────────────────────────────────────
//--- FixTrendPair: 方向初期化 or Pivot 時にトレンド列を再ラベル／再配置
void FixTrendPair(const int dir, const int row)
{
   // 進入ログ（リセット抑止デバッグ）
   PrintFormat("[FIX] enter FixTrendPair dir=%d row=%d nextCol(before)=%u trendSign=%d",
               dir, row, nextCol, trendSign);

   // 既存トレンド列を 1(BUY) / 2(SELL) に再マップ
   trendBCol = 1;
   trendSCol = 2;
   colTab[trendBCol].id   = trendBCol;
   colTab[trendBCol].role = ROLE_TREND;
   colTab[trendSCol].id   = trendSCol;
   colTab[trendSCol].role = ROLE_TREND;

   // ★ 以前は nextCol = 3; などで“常に”リセットしていた想定
   // 既に拡張済み（nextCol >= 3）なら壊さない。初回だけ初期値保障。
   if(nextCol < 3)
      nextCol = 3;

   // 初回だけ列クリア等の重い初期化をしたい場合はここに条件付きで置く:
   // if(trendSign == 0) { /* 初回のみの初期化処理 (必要なら) */ }

   // 現在の行へトレンド列を再配置
   Place(ORDER_TYPE_BUY , trendBCol, row);
   Place(ORDER_TYPE_SELL, trendSCol, row);

   PrintFormat("[FIX] leave FixTrendPair nextCol(after)=%u", nextCol);
}

//+------------------------------------------------------------------+
// ③ 現在行のまま 0.5 グリッドだけ “半歩” 動かす
void SimulateHalfStep()
{
   rowAnchor += GridSize * 0.5;   // 中間まで動かす
   UpdateFakeProfits();
   CheckWeightedClose();          // 半歩位置でのみ発火を確認
   rowAnchor -= GridSize * 0.5;   // 元に戻す
   UpdateFakeProfits();
}

#endif  // UNIT_TEST helper bodies ここまで

#endif
//=============================================================
//  ★ UT 専用　現在の擬似 Bid 価格を返す
//=============================================================
double CurBidUT()
{
#ifdef UNIT_TEST
   return  basePrice + lastRow * InpGridSize;   // 擬似 Bid
#else
   return  SymbolInfoDouble(InpSymbol, SYMBOL_BID);   // ←本来の Bid
#endif
}

//──────────────────────── Utility ────────────────────────────────
void ClearColTab() {
    // Reset all column states to default (e.g. after closing all positions)
    for(int i = 0; i < MAX_COL + 2; ++i) {
        ZeroMemory(colTab[i]);
    }
}
string Cmnt(int r, uint c) {
    // Construct position comment as "r<row>C<col>"
    return "r" + IntegerToString(r) + "C" + IntegerToString((int)c);
}
bool Parse(const string &cm, int &r, uint &c) {
    // Parse position comment "r<row>C<col>" into row and col values
    long p = StringFind(cm, "C");
    if(p < 1) return false;
    r = (int)StringToInteger(StringSubstr(cm, 1, p - 1));
    c = (uint)StringToInteger(StringSubstr(cm, p + 1));
    return true;
}

bool GetPositionComment(int idx, string &cm)
{
#ifdef UNIT_TEST
    return Fake_PositionGetString(idx, cm);
#else
    cm = PositionGetString(POSITION_COMMENT);
    return(true);
#endif
}

bool GetPosRC(int idx, int &r, uint &c)
{
    // ポジション選択
    if(!SelectPosByIndex(idx))
        return(false);
    // コメント取得
    string cm;
    if(!GetPositionComment(idx, cm))
        return(false);
    // Parse
    return(Parse(cm, r, c));
}
bool SelectPosByIndex(int idx) {
    // Select the position by index if it belongs to this EA (matching magic)
    if(idx < 0 || idx >= PositionsTotal()) return false;
    ulong ticket = PositionGetTicket(idx);
    if(ticket == 0) return false;
    if(!PositionSelectByTicket(ticket)) return false;
    if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) return false;
    return true;
}
bool HasPos(uint col, int row) {
    // Check if there is an existing position with the given column and row
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!SelectPosByIndex(i)) continue;
        int r; uint c;
        if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;
        if(r == row && c == col) {
            return true;
        }
    }
    return false;
}                     // 見つからず



//──────────────── Market-order helper ──────────────────────────
bool Place(ENUM_ORDER_TYPE t,
           uint             col,
           int              row,
           bool             isAltFirst=false)
{
   /*――― ① 重複＆即時再-entry 防止 ―――*/
   if( HasPos(col,row)                // 同一セル重複
   ||  altClosedRow[col] == row )     // 直前 break-even 行ならスキップ
      return false;

   /*――― ② 発注価格 ―――*/
   double price = (t == ORDER_TYPE_BUY)
                    ? SymbolInfoDouble(InpSymbol, SYMBOL_ASK)
                    : CurBidUT();    // 最新 bid を取得するヘルパ関数

   /*――― ③ 発注実行 ―――*/
   bool ok;
#ifdef UNIT_TEST
   // テスト用ダミー発注
   int idx         = fakeCnt++;
   fakePos[idx].tk  = nextTk++;
   fakePos[idx].row =  row;
   fakePos[idx].col =  col;
   fakePos[idx].dir = (t == ORDER_TYPE_BUY ? +1 : -1);
   fakePos[idx].profit = 0.0;
   ok = true;
#else
   ok = (t == ORDER_TYPE_BUY)
        ? trade.Buy (InpLot, InpSymbol, price, 0, 0, Cmnt(row,col))
        : trade.Sell(InpLot, InpSymbol, price, 0, 0, Cmnt(row,col));
#endif
   if(!ok) return false;

   /*――― ④ 内部ステート更新 ―――*/
   colTab[col].posCnt++;
   colTab[col].lastDir = (t == ORDER_TYPE_BUY ? +1 : -1);
   if(isAltFirst){
      // 交互列１本目の参照行・基準方向を記録
      colTab[col].altRefRow = row;
      colTab[col].altRefDir = colTab[col].lastDir;
   }

   /*――― ⑤ デバッグログ ―――*/
   if(InpDbgLog)
      PrintFormat("[NEW] r=%d c=%u role=%d dir=%s ALTfirst=%d posCnt=%u",
                  row, col, colTab[col].role,
                  (t==ORDER_TYPE_BUY ? "Buy" : "Sell"),
                  isAltFirst, colTab[col].posCnt);

   return true;
}

//──────────────── Trend-pair 作成ヘルパー ────────────────────────
void CreateTrendPair(int row)
{
   // 次の２列をトレンドペアとして予約
   uint b = nextCol++;
   uint s = nextCol++;
   colTab[b].id   = b;  colTab[b].role = ROLE_TREND;
   colTab[s].id   = s;  colTab[s].role = ROLE_TREND;
   trendBCol = b;  trendSCol = s;
   // 実際のオーダーを発注
   Place(ORDER_TYPE_BUY ,  b, row);
   Place(ORDER_TYPE_SELL, s, row);
}

//──────────────── SafeRollTrendPair ─────────────────────────────────
// ローカル curRow 引数を削除し、必ずグローバル curRow を使う
void SafeRollTrendPair(int dir)
{
    // 前行を計算（curRow はグローバルに現在行を保持）
    int prevRow = curRow - dir;

    // 前行のトレンドペアをクローズ
    for(int i = PositionsTotal() - 1; i >= 0; --i)
    {
        int r = 0; uint c = 0;
        if(!GetPosRC(i, r, c)) 
            continue;
        if(r == prevRow && (c == trendBCol || c == trendSCol))
        {
            if(trade.PositionClose(PositionGetTicket(i)))
                colTab[c].posCnt--;
        }
    }

    // curRow 上で新規トレンドペア発注
    ENUM_ORDER_TYPE buyType  = (dir > 0 ? ORDER_TYPE_BUY  : ORDER_TYPE_SELL);
    ENUM_ORDER_TYPE sellType = (dir > 0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY );
    Place(buyType,  trendBCol, curRow);
    Place(sellType, trendSCol, curRow);
}

//──────────────── Alternate Direction (AltDir) ───────────────────────
ENUM_ORDER_TYPE AltDir(uint col)
{
    // 差分の絶対値で偶奇を判定
    int diff = MathAbs(curRow - colTab[col].altRefRow);
    bool even = (diff % 2 == 0);
    int  base = (even ? colTab[col].altRefDir : -colTab[col].altRefDir);
    return (base > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
}

//──────────────── Profit‑Close (Pivot) ────────────────────────────
void CheckProfitClose()
{
    // ① profit.active フラグチェック
    if(!profit.active) 
        return;

    // ② Pivot後１グリッド動くまで待機
    if(trendSign > 0)
    {
        if(lastRow < profit.refRow + 1) 
            return;
    }
    else
    {
        if(lastRow > profit.refRow - 1) 
            return;
    }

    // ③ 利確列を全ポジションクローズ
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        int  r = 0; uint c = 0;
        // ここで Select＋コメント取得＋Parse をまとめてチェック
        if(!GetPosRC(i, r, c) || c != profit.profitCol) 
            continue;
        if(trade.PositionClose(PositionGetTicket(i)))
            colTab[c].posCnt--;
    }

    // ④ r-1 行に１本だけ交互エントリーを再建て
    int rebuildRow = profit.refRow - 1;
    ENUM_ORDER_TYPE t 
      = (trendSign > 0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
    Place(t, profit.rebuildCol, rebuildRow, true);
    colTab[profit.rebuildCol].role = ROLE_ALT;

    if(InpDbgLog)
        PrintFormat("[PROFIT-CLOSE] closed col=%u → rebuilt col=%u row=%d",
                    profit.profitCol, profit.rebuildCol, rebuildRow);

    // ⑤ フラグクリア
    profit.active = false;
}

//──────────────── Break‑Even Close (WeightedClose) ─────────────────
void CheckWeightedClose()
{
    // 近ゼロ判定の閾値（約0.5 pip 相当）
    double tickVal   = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
    double epsProfit = tickVal * InpLot * 0.5;

    for(uint c = 1; c < nextCol; c++)
    {
        // ALT 列かつポジ数 ≥3 の奇数のみ対象
        if(colTab[c].role != ROLE_ALT || colTab[c].posCnt < 3 || (colTab[c].posCnt & 1) == 0)
            continue;

        // --- ① P/L 集計＆方向カウント ---
        double sumProfit   = 0.0;
        int    netDirCount = 0;
        int    minBuyRow   = INT_MAX;
        int    maxSellRow  = INT_MIN;

        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            int r = 0; uint col2 = 0;
            if(!GetPosRC(i, r, col2) || col2 != c)
                continue;

            // P/L
            sumProfit += PositionGetDouble(POSITION_PROFIT);

            // Buy/Sell カウント＆行記録
            long type = PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
            {
                netDirCount++;
                minBuyRow = MathMin(minBuyRow, r);
            }
            else
            {
                netDirCount--;
                maxSellRow = MathMax(maxSellRow, r);
            }
        }

        // P/L データなしなら次へ
        if(netDirCount == 0 && sumProfit == 0.0)
            continue;

        // --- ② ブレイクイーブン判定 ---
        if(sumProfit >= -epsProfit)
        {
            // 残すべきポジションの行を決定
            int keepRow = (netDirCount > 0 ? minBuyRow : maxSellRow);

            // --- ③ 実際のクローズループ ---
            uint closedCount = 0;
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                int r2 = 0; uint col3 = 0;
                if(!GetPosRC(i, r2, col3) || col3 != c || r2 == keepRow)
                    continue;

                ulong tk = PositionGetTicket(i);
                if(trade.PositionClose(tk))
                {
                    closedCount++;
                    colTab[c].posCnt--;
                }
            }

            // 即時再エントリー抑止
            altClosedRow[c] = lastRow;

            // 全ポジション消滅なら列リセット
            if(colTab[c].posCnt == 0)
                colTab[c].role = ROLE_PENDING;

            if(InpDbgLog)
                PrintFormat("[WeightedClose] col=%u P/L=%.2f closed=%u",
                            c, sumProfit, closedCount);
        }
    }
}


//===== 補助関数: カラム内すべてのポジションを閉じる ==================
void CloseEntireCol(uint col)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetTicket(i)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      int r; uint c;
      if(!Parse(cmt, r, c)) continue;
      if(c != col) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      trade.PositionClose(ticket);
   }
}

//──────────────── CheckTargetEquity() ──────────────────
void CheckTargetEquity()
{
  // UNIT_TEST 時は本物の口座残高判定をスキップ
#ifdef UNIT_TEST
  return;
#endif
   double cur=AccountInfoDouble(ACCOUNT_EQUITY);
   if(cur-startEquity < InpTargetEquity - 1e-9) return;
   for(int i=PositionsTotal()-1;i>=0;i--) if(SelectPosByIndex(i)) trade.PositionClose(PositionGetTicket(i));
   if(InpDbgLog) Print("Target equity reached → reset");
   ClearColTab(); ArrayInitialize(altClosedRow,-9999);
   nextCol=1; trendBCol=trendSCol=0; lastRow=0; trendSign=0;
   basePrice=rowAnchor=CurBidUT();
   colTab[1].id=1; colTab[1].role=ROLE_TREND; colTab[2].id=2; colTab[2].role=ROLE_TREND;
   trendBCol=1; trendSCol=2; nextCol=3;
   Place(ORDER_TYPE_BUY ,trendBCol,0);
   Place(ORDER_TYPE_SELL,trendSCol,0);
   startEquity=cur;
}
 void UpdateAlternateCols()
 {
     // グローバル curRow, dir, seed は不要。ここでは curRow を使ってループ
     for(uint c = 1; c < nextCol; ++c)
     {
         if(colTab[c].role != ROLE_ALT) continue;
         if(altClosedRow[c] == curRow) continue;  // 直前クローズ行はスキップ
         Place(AltDir(c), c, curRow);
     }
 }

#ifdef UNIT_TEST
//─── ダミー損益を毎ステップ更新 ─────────────────
void UpdateFakeProfits()
{
   double bid = CurBidUT();
   for(int i = 0; i < fakeCnt; ++i)
   {
      double entryPrice = basePrice + fakePos[i].row * GridSize;
      fakePos[i].profit = (bid - entryPrice) * fakePos[i].dir; // ロット換算は簡略
   }
}
#endif
// ----------------------------------------------------------------
//  ▼▼▼ ここから UNIT_TEST ブリッジ ▼▼▼
#ifdef UNIT_TEST
#define NO_ROW   (-9999)
   // --- 全リセット（Script 起動のたび呼ばれる） --------------
   
   // --- Script ↔ EA の発注橋渡し ------------------------------
   bool UT_Place(int type,int col,int row,bool isAltFirst)
   {
      ENUM_ORDER_TYPE ot = (type==0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      return Place(ot,col,row,isAltFirst);
   }

   // --- 列単位／行単位の決済 -----------------------------------
   void UT_CloseCol(uint col,int row)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!SelectPosByIndex(i)) continue;
         int r; uint c;
         if(!Parse(PositionGetString(POSITION_COMMENT),r,c)
            || c!=col) continue;
         if(row!=NO_ROW && r!=row) continue;       // 行指定ありなら一致のみ
         if(trade.PositionClose(PositionGetTicket(i)))
             colTab[c].posCnt--;
      }
   }

   // --- 最低限の整合性チェック ---------------------------------
   bool AssertState(string msg)
   {
    // ―― 同セル重複ポジ禁止 ―――――――――――――――
       static int cellHit[MAX_COL+2][201];        // [-100‥+100] なら 201
       ArrayInitialize(cellHit,0);

       bool ok = true;                       // ← 先頭で毎回初期化

   /*―――― ⑥  Weighted-Close 後の整合性チェック ――――*/

   for(uint c=1;c<nextCol;++c)            // ←★ ここで “最初の for” を閉じる
   {
      // “この Step で WeightedClose が発火した” 目印
      if(altClosedRow[c]!=lastRow) continue;

      // ① ポジションが残っていないか？
      if(colTab[c].posCnt!=0)
      {
         PrintFormat("❌ WEIGHTED-CLOSE leak  col=%u  posCnt=%u",c,colTab[c].posCnt);
         ok=false;
      }
    /*―――― ⑦  Safe-Roll 後の TREND ペア健全性チェック ――――
          ・現行 TREND ペア (trendBCol / trendSCol) は
               lastRow にポジが 1 本ずつ
          ・その 1 行前 (lastRow-trendSign) には残っていない
    */
    if(trendBCol && trendSCol && trendSign!=0)
    {
       const int prev = lastRow - trendSign;
       int cntB=0, cntS=0, cntPrevB=0, cntPrevS=0;

       for(int i=PositionsTotal()-1;i>=0;--i)
       {
          if(!SelectPosByIndex(i)) continue;
          int r; uint c;
          if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
          if(c==trendBCol){ if(r==lastRow) cntB++;   if(r==prev) cntPrevB++; }
          if(c==trendSCol){ if(r==lastRow) cntS++;   if(r==prev) cntPrevS++; }
       }

       if(cntB!=1 || cntS!=1 || cntPrevB>0 || cntPrevS>0)
       {
          PrintFormat("❌ SAFEROLL mismatch  r=%d  B:%d/%d  S:%d/%d",
                      lastRow,cntB,cntPrevB,cntS,cntPrevS);
          ok = false;
       }
    }
        /*―――― ⑧  Profit-Close／Weighted-Close 事後チェック ――――*/
    for(uint c=1;c<nextCol;++c)
    {
       // Profit-Close が “直前 Step” で終わった列
       if(profit.active==false && profit.profitCol==c)
       {
          if(colTab[c].posCnt!=0 || colTab[c].role!=ROLE_ALT)
          {
             PrintFormat("❌ PROFIT-CLOSE leak  col=%u  cnt=%u  role=%d",
                         c,colTab[c].posCnt,colTab[c].role);
            ok=false;
          }
       }

       // Weighted-Close が “直前 Step” で走った列
       if(altClosedRow[c]==lastRow &&
          (colTab[c].posCnt!=0 || colTab[c].role!=ROLE_PENDING))
       {
          PrintFormat("❌ WEIGHTED-CLOSE leak  col=%u  cnt=%u  role=%d",
                      c,colTab[c].posCnt,colTab[c].role);
          ok=false;
       }
    }
 
   /*―――― ⑨ 旧ロジック：role / DUP-CELL / PROFIT-列漏れ ――――*/
      if(colTab[c].role!=ROLE_PENDING)
      {
         PrintFormat("❌ WEIGHTED-CLOSE role mismatch  col=%u  role=%d",c,colTab[c].role);
         ok=false;
      }
   }
      for(int i=PositionsTotal()-1;i>=0;--i)
      {
         if(!SelectPosByIndex(i)) continue;
         int r; uint c; if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
         if(r<-100 || r>100 || c>MAX_COL)        // 範囲外は無視
            continue;
            // Profit 列なのに posCnt==0 → rebuild Sell がない ＝バグ
         if(colTab[c].role==ROLE_PROFIT && colTab[c].posCnt==0)
         {
            Print("❌ PROFIT-CLOSE leak col=",c);  return(false); }

         if(cellHit[c][r+100]++)
         {                                       // 既に 1 件以上 → 重複
            Print("❌ DUP-CELL DETECTED  r=",r," c=",c,"  msg=",msg);
            return(false);
         }
      }
      return ok;
   }
#endif
//  ▲▲▲ ここまで UNIT_TEST ブリッジ ▲▲▲
// ----------------------------------------------------------------

//───────────────────────────────────────────────────────────────
int OnInit()
{
   GridSize=InpGridSize;
   basePrice=rowAnchor=CurBidUT();
   startEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   ClearColTab(); ArrayInitialize(altClosedRow,-9999);
   trade.SetExpertMagicNumber(InpMagic);
   colTab[1].id=1; colTab[1].role=ROLE_TREND; colTab[2].id=2; colTab[2].role=ROLE_TREND;
   trendBCol=1; trendSCol=2; nextCol=3;
   Place(ORDER_TYPE_BUY ,trendBCol,0);
   Place(ORDER_TYPE_SELL,trendSCol,0);
   if(InpDbgLog) Print("Stable snapshot initialised");
   return INIT_SUCCEEDED;
}

//───────────────────────────────────────────────────────────────
void OnTick()
{
   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   /*――― 上昇方向 ―――*/
   while(bid >= rowAnchor + GridSize - 1e-9)
   {
      StepRow(lastRow + 1, +1);
      rowAnchor += GridSize;
   }

   /*――― 下降方向 ―――*/
   while(bid <= rowAnchor - GridSize + 1e-9)
   {
      StepRow(lastRow - 1, -1);
      rowAnchor -= GridSize;
   }

   CheckProfitClose();
   CheckWeightedClose();
   CheckTargetEquity();
}
