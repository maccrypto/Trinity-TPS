//+------------------------------------------------------------------+
//| TrinityCore.mqh – ReplayTest 用コア (2025‑07‑27 v2.3‑b)           |
//| ★ 2025‑08‑03 Profit‑Close‑Break & Weighted‑Close 仕様修正          |
//|    • PCB 発火判定 = setPrevMin‑1G （row==MIN‑1）                  |
//|    • ALT 二重発注バグ修正（戻り方向では flip しない）            |
//|    • ToOrderType / set‑helper forward 宣言追加                    |
//|    • EnsureSetInitIfAlive など前方宣言関数のスタブ実装を追加      |
//+------------------------------------------------------------------+
#ifndef __TRINITY_CORE_MQH__
#define __TRINITY_CORE_MQH__

#include <Trade\Trade.mqh>
CTrade trade;

#define MAX_COLS 128

enum ROLE        { ROLE_NONE, ROLE_TREND, ROLE_ALT, ROLE_PROFIT };
enum SIDE        { SIDE_NONE=-1, SIDE_BUY=ORDER_TYPE_BUY, SIDE_SELL=ORDER_TYPE_SELL };
enum ANCHOR_TYPE { ANCH_NONE=0, ANCH_LOW=1, ANCH_HIGH=2 };

struct ColInfo{
   int         id;
   ROLE        role;
   int         setId;
   ANCHOR_TYPE anchor;
   int         originRow;
   SIDE        lastSide;
   int         lastFlipRow;
   int         simCount;      // ALT の休場時カウント
   bool        trendRollLock; // Safe‑Roll: Close 完了までロック
   int         originDir;     // ALT 作成時のトレンド方向 (+1/‑1)
};

ColInfo colTab[MAX_COLS];  // 1‑based 想定

//==== 環境・閾値 ====================================================

double  _lot       = 0.01;
int     _magicBase = 900000;

double basePrice = 0.0;
int    lastRow   = 0;
int    lastDir   = 0;
int    StepCount = 0;

int    colBuy    = 1;
int    colSell   = 2;
int    nextCol   = 3;

bool   g_firstMoveDone        = false;
double g_wclose_eps           = 0.0;   // ★ ここを 0.0 に
bool   g_dryRunIfMarketClosed = true;  // ★ true に
bool   g_marketClosed         = true;  // ★ true に（= 強制 DRY-RUN）
// Profit‑close 閾値
double g_profit_min_net    = 0.0;   // REAL: 合計損益がこれ以上なら確定
int    g_profit_rows_sim   = 1;     // SIM : originRow からこの行数で確定

bool g_forceSim = true; 

// ==== 極値ブレイク用（新規） =======================================
#define MAX_SETS (MAX_COLS/4 + 8)
const int INF_I = 1<<28;

int setPrevMin[MAX_SETS];
int setPrevMax[MAX_SETS];
int setLastMinFiredAt[MAX_SETS];
int setLastMaxFiredAt[MAX_SETS];

void InitSetBreakArrays(){ for(int i=0;i<MAX_SETS;i++){ setPrevMin[i]= INF_I; setPrevMax[i]=-INF_I; setLastMinFiredAt[i]= INF_I; setLastMaxFiredAt[i]=-INF_I; } }

// 利食い側を手動で決める : 高値(SELL) / 低値(BUY)
enum PROFIT_PREF{ PROFIT_AUTO_SWAP = 0, PROFIT_LONG = 1, PROFIT_SHORT = 2 };
int g_profit_pref = PROFIT_AUTO_SWAP;   // ← パラメータで上書き可

//================= ユーティリティ ==================================
string RoleName(const ROLE r){ switch(r){ case ROLE_TREND:  return "TREND"; case ROLE_ALT:    return "ALT"; case ROLE_PROFIT: return "PROFIT"; default:          return "NONE"; } }
void   Log(string tag,string msg){ PrintFormat("%s  %s",tag,msg); }

ENUM_ORDER_TYPE OppositeType(ENUM_ORDER_TYPE t){ return (t==ORDER_TYPE_BUY)? ORDER_TYPE_SELL:ORDER_TYPE_BUY; }
// ----- ★ 新規追加：SIDE → ORDER_TYPE 変換ヘルパ ------------------
ENUM_ORDER_TYPE ToOrderType(SIDE s){ return (s==SIDE_BUY)? ORDER_TYPE_BUY:ORDER_TYPE_SELL; }

int  SetID(int col){ return 1 + (col-1)/4; }

void InitColInfo(int col){ if(col<0 || col>=MAX_COLS) return; colTab[col].id=col; colTab[col].role=ROLE_NONE; colTab[col].setId=SetID(col); colTab[col].anchor=ANCH_NONE; colTab[col].originRow=0; colTab[col].lastSide=SIDE_NONE; colTab[col].lastFlipRow=-999; colTab[col].simCount=0;  colTab[col].trendRollLock=false; }

bool EnsureCols(int need){ if(nextCol + need >= MAX_COLS){ Log("[ERR]","Column capacity exceeded"); return false; } return true; }

void RefreshMarketStatus(){ MqlTradeRequest req; ZeroMemory(req); MqlTradeCheckResult chk; ZeroMemory(chk); double vol_min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN); double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); double vol=MathMax(_lot,vol_min); if(step>0) vol=MathRound(vol/step)*step; req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.type=ORDER_TYPE_BUY; req.volume=vol; req.price=SymbolInfoDouble(_Symbol,SYMBOL_ASK); req.magic=_magicBase; bool ok = OrderCheck(req,chk); bool prev=g_marketClosed; if(!ok){ g_marketClosed=true; }else{ g_marketClosed=(chk.retcode==TRADE_RETCODE_MARKET_CLOSED); } if(g_marketClosed!=prev) Log("[MARKET]", g_marketClosed? "closed → DRY-RUN":"open"); }

//--- ★ 前方宣言 ----------------------------------------------------
void EnsureSetInitIfAlive(const int prev_row);
int  MaxSetIdInUse();
void UpdateSetExtremaEndOfStep(const int newRow);
void UpdateALT(const int curRow); 

// fwd
bool Place(const ENUM_ORDER_TYPE orderType,const int col,const int row,const ROLE role=ROLE_TREND);
bool CloseColumn(int col);

//--- ★ 追加: スタブ実装（アルゴリズムに影響しない最小限） ----------
void EnsureSetInitIfAlive(const int prev_row)
{
   // setPrevMin / setPrevMax が未初期化 (INF_I / -INF_I) の場合だけ
   // 現在の prev_row で初期化しておく。既に値が入っていればスキップ。
   int mx = MaxSetIdInUse();
   for(int s=1; s<=mx; ++s)
   {
      if(setPrevMin[s]==INF_I)  setPrevMin[s]  = prev_row;
      if(setPrevMax[s]==-INF_I) setPrevMax[s] = prev_row;
   }
}

int MaxSetIdInUse()
{
   int mx = 0;
   for(int c=1; c<nextCol; ++c)
   {
      if(colTab[c].role!=ROLE_NONE)
         mx = (colTab[c].setId > mx)? colTab[c].setId : mx;
   }
   return mx;
}

void UpdateSetExtremaEndOfStep(const int newRow)
{
   int mx = MaxSetIdInUse();
   for(int s=1; s<=mx; ++s)
   {
      if(newRow < setPrevMin[s]) setPrevMin[s] = newRow;
      if(newRow > setPrevMax[s]) setPrevMax[s] = newRow;
   }
}
//====================================================================
//  Place – 発注 / ドライラン共通ラッパー
//    • ALT での simCount は「同 row・同 side 1 回のみ」加算
//====================================================================
bool Place(const ENUM_ORDER_TYPE orderType,
           const int col,const int row,const ROLE role=ROLE_TREND)
{
    if(col<=0 || col>=MAX_COLS){
        Log("[NEW-FAIL]", StringFormat("invalid col=%d",col));
        return false;
    }

    /*----- 直前状態を参照して “今回の発注で simCount を増やすか” 判定 ----*/
    SIDE thisSide      = (orderType==ORDER_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
    bool needIncSimCnt = false;

    if(role == ROLE_ALT){
        // 同じ row・同じ side で既に発注済みならカウントしない
        if(!(colTab[col].lastFlipRow == row && colTab[col].lastSide == thisSide))
            needIncSimCnt = true;
    }

    /*========== 市場休場：ドライラン ==========*/
    if(g_dryRunIfMarketClosed && g_marketClosed)
    {
        Log("[NEW-SIM]", StringFormat(
            "r=%d c=%d %s (%s) dry-run",
            row, col,
            (thisSide==SIDE_BUY ? "Buy" : "Sell"),
            RoleName(role)));

        /*--- 状態更新 ---*/
        if(needIncSimCnt) colTab[col].simCount++;
        colTab[col].id            = col;
        colTab[col].role          = role;
        colTab[col].lastSide      = thisSide;
        colTab[col].lastFlipRow   = row;
        return true;
    }

    /*========== 実ブローカー発注 ==========*/
    MqlTradeRequest  req;  MqlTradeResult res;
    ZeroMemory(req); ZeroMemory(res);

    req.action   = TRADE_ACTION_DEAL;
    req.symbol   = _Symbol;
    req.type     = orderType;
    req.volume   = _lot;
    req.price    = (orderType==ORDER_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                     : SymbolInfoDouble(_Symbol,SYMBOL_BID);
    req.deviation = 20;
    req.magic     = _magicBase + col;
    req.comment   = StringFormat("r=%d c=%d",row,col);

    bool sent = OrderSend(req,res);
    long rc   = res.retcode;
    bool ok   = sent && (rc==TRADE_RETCODE_DONE ||
                          rc==TRADE_RETCODE_PLACED ||
                          rc==TRADE_RETCODE_DONE_PARTIAL);

    if(!ok)
    {
        //--- フォールバック：市場閉鎖時はドライランへ ------------------
        if(g_dryRunIfMarketClosed && rc==TRADE_RETCODE_MARKET_CLOSED)
        {
            g_marketClosed = true;
            Log("[NEW-SIM]", StringFormat(
                "r=%d c=%d %s (%s) fallback dry-run (market closed)",
                row, col,
                (thisSide==SIDE_BUY ? "Buy" : "Sell"),
                RoleName(role)));

            if(needIncSimCnt) colTab[col].simCount++;
            colTab[col].id          = col;
            colTab[col].role        = role;
            colTab[col].lastSide    = thisSide;
            colTab[col].lastFlipRow = row;
            return true;
        }

        Log("[NEW-FAIL]", StringFormat(
            "r=%d c=%d %s rc=%ld",
            row, col,
            (thisSide==SIDE_BUY ? "Buy" : "Sell"),
            rc));
        return false;
    }

    /*========== 発注成功時の処理 ==========*/
    Log("[NEW]", StringFormat(
        "r=%d c=%d %s (%s)",
        row, col,
        (thisSide==SIDE_BUY ? "Buy" : "Sell"),
        RoleName(role)));

    if(needIncSimCnt) colTab[col].simCount++;
    colTab[col].id          = col;
    colTab[col].role        = role;
    colTab[col].lastSide    = thisSide;
    colTab[col].lastFlipRow = row;
    return true;
}

//====================================================================
// CloseColumn – 列の全ポジをクローズ
//   true  : 全決済済み（または最初からポジ無し）
//   false : まだポジが残り、次ティックで再試行
//====================================================================
bool CloseColumn(int col)
{
   if(col<=0 || col>=MAX_COLS) return true;

   RefreshMarketStatus();

   // --- 市場休場なら疑似 Close ----------------------------------
   if(g_dryRunIfMarketClosed && g_marketClosed)
   {
      int before = colTab[col].simCount;
      colTab[col].simCount      = 0;
      colTab[col].trendRollLock = false;
      Log("[CLOSE-SIM]", StringFormat("c=%d clear=%d", col, before));
      return true;
   }

   bool anyPos   = false;
   bool allClosed= true;

   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk==0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=_magicBase+col) continue;

      anyPos = true;

      /* --- 決済トライ ----------------------------------------- */
      bool ok = trade.PositionClose(tk);
      long rc = trade.ResultRetcode();

      if(!ok)
      {
         // ★ フォールバック：市場閉鎖なら疑似決済に切り替え
         if(g_dryRunIfMarketClosed && rc==TRADE_RETCODE_MARKET_CLOSED)
         {
            g_marketClosed      = true;
            colTab[col].simCount= 0;
            Log("[CLOSE-SIM]", StringFormat(
                "c=%d fallback (market closed) clear simCount", col));
            continue;           // このポジは“無かった”ことに
         }

         allClosed = false;    // まだ残っている
      }
   }

   if(anyPos && !allClosed)
   {
      Log("[CLOSE-PEND]", StringFormat("c=%d waiting broker close", col));
      return false;            // 次ティックで再試行
   }

   colTab[col].simCount      = 0;
   colTab[col].trendRollLock = false;
   return true;
}

//--------------------------------------------------------------------
// *** HandleFirstMove (ALT を決済せずに転換する版 – 2025-08-03 修正版) ***
//--------------------------------------------------------------------
void HandleFirstMove(int newRow, int dir)
{
   Log("[INIT-MOVE]", StringFormat("dir=%d row=%d", dir, newRow));

   // ── 含み益(①) / 含み損(ALT) 列を判定 ─────────────────────
   SIDE winSide = (dir == 1) ? SIDE_BUY : SIDE_SELL;   // 勝ち側サイド
   int  winCol  = (winSide == SIDE_BUY) ? colBuy : colSell;   // ①列
   int  loseCol = (winCol  == colBuy)   ? colSell : colBuy;   // ALT列

   /*── ①列マーキング ───────────────────────────────*/
   colTab[winCol].role      = ROLE_PROFIT;
   colTab[winCol].anchor    = (winSide == SIDE_BUY) ? ANCH_LOW : ANCH_HIGH;
   colTab[winCol].originRow = lastRow;                 // 直前 row を起点に固定
   Log("[ROLE]", StringFormat("c=%d → ①列 (PROFIT)", winCol));

   /*── ALT 化（既存玉を保持） ──────────────────────*/
   SIDE prevSide          = (loseCol == colBuy) ? SIDE_BUY : SIDE_SELL;
   colTab[loseCol].role   = ROLE_ALT;
   colTab[loseCol].anchor = ANCH_NONE;

       // まだ ALT が動いていない列だけを初期化
    if(colTab[loseCol].simCount == 0){
        colTab[loseCol].originRow = newRow;   // ALT 基点
        colTab[loseCol].originDir = dir;      // トレンド方向記憶
        colTab[loseCol].simCount  = 1;        // 既存1 + 次の flip1 を予約
   }

   colTab[loseCol].lastSide    = prevSide;
   colTab[loseCol].lastFlipRow = lastRow;

   /*── 交互エントリー開始（既存玉の反対サイドを即建てる） ───*/
   SIDE nextAltSide = (prevSide == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
   if(Place(ToOrderType(nextAltSide), loseCol, newRow, ROLE_ALT))
   {
      colTab[loseCol].lastSide    = nextAltSide;
      colTab[loseCol].lastFlipRow = newRow;
      Log("[ROLE]", StringFormat("c=%d → ALT (first flip)", loseCol));
   }

   /*── 新 TREND ペアを同 row で起動 ────────────────────*/
   if(!EnsureCols(2)) return;
   colBuy  = nextCol++;
   colSell = nextCol++;
   InitColInfo(colBuy);  InitColInfo(colSell);

   colTab[colBuy ].role = ROLE_TREND;
   colTab[colSell].role = ROLE_TREND;
   Place(ORDER_TYPE_BUY , colBuy , newRow, ROLE_TREND);
   Place(ORDER_TYPE_SELL, colSell, newRow, ROLE_TREND);

   // 状態更新
   lastRow = newRow;
   lastDir = dir;
}
//--------------------------------------------------------------------
// *** HandlePivot (ALT を決済せず転換 – fixed) ***
//--------------------------------------------------------------------
void HandlePivot(int newRow, int dir)
{
   Log("[PIVOT]", StringFormat("detected dir=%d at row=%d", dir, newRow));

   SIDE winSide = (dir == 1) ? SIDE_BUY : SIDE_SELL;
   int  winCol  = (winSide == SIDE_BUY) ? colBuy : colSell;
   int  loseCol = (winCol  == colBuy)   ? colSell : colBuy;

   /*── ①列固定 ───────────────────────────────*/
   if(colTab[winCol].role != ROLE_PROFIT){
       colTab[winCol].role      = ROLE_PROFIT;
       colTab[winCol].anchor    = (winSide == SIDE_BUY) ? ANCH_LOW : ANCH_HIGH;
       colTab[winCol].originRow = newRow;      // Pivot 時は “今 row” が起点
       Log("[ROLE]", StringFormat("c=%d → ①列 (PROFIT)", winCol));
   }

   /*── loseCol を ALT 化（既存玉を保持） ───────────*/
   SIDE prevSide = (loseCol == colBuy) ? SIDE_BUY : SIDE_SELL;

   colTab[loseCol].role        = ROLE_ALT;
   colTab[loseCol].anchor      = ANCH_NONE;
      // ALT 列が未稼働なら初期化
   if(colTab[loseCol].simCount == 0){
       colTab[loseCol].originRow = newRow;
       colTab[loseCol].originDir = dir;
       colTab[loseCol].simCount  = 1;
   }
   colTab[loseCol].lastSide    = prevSide;
   colTab[loseCol].lastFlipRow = lastRow;

   SIDE nextAltSide = (prevSide == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
   Place(ToOrderType(nextAltSide), loseCol, newRow, ROLE_ALT);
   colTab[loseCol].lastSide    = nextAltSide; // ★ Place 後に上書き
   colTab[loseCol].lastFlipRow = newRow;
   Log("[ROLE]", StringFormat("c=%d → ALT", loseCol));

   /*── 新 TREND ペア ─────────────────────────────*/
   if(!EnsureCols(2)) return;
   colBuy  = nextCol++;
   colSell = nextCol++;
   InitColInfo(colBuy);  InitColInfo(colSell);
   colTab[colBuy ].role = ROLE_TREND;
   colTab[colSell].role = ROLE_TREND;
   Place(ORDER_TYPE_BUY , colBuy , newRow, ROLE_TREND);
   Place(ORDER_TYPE_SELL, colSell, newRow, ROLE_TREND);

   lastRow = newRow;
   lastDir = dir;
}

//--------------------------------------------------------------------
//  Trend-roll : 1 グリッドだけ進んだ（Pivot しない）場合のロール処理
//  Safe-Roll 対応版
//--------------------------------------------------------------------
void HandleTrendRoll(const int newRow,const int dir)
{
   /* ── ❶ static 状態 ─────────────────────────────────────── */
   //   ・rollPending   : 前 Tick で Close 未完了 → 次 Tick で再試行
   //   ・pendingRow    : 待機中 Row（Price が戻ったらキャンセル）
   //   ・buyClosedFlag : Buy 列 Close 完了フラグ
   //   ・sellClosedFlag: Sell 列 Close 完了フラグ
   static bool rollPending    = false;
   static int  pendingRow     = 0;
   static bool buyClosedFlag  = false;
   static bool sellClosedFlag = false;

   /* ── ❷ 直前の Close が未完了なら、まず再試行 ───────────── */
   if(rollPending)
   {
      // Row がズれた場合（逆方向へ 1G 戻った／進んだ）はキャンセル
      if(newRow != pendingRow)
      {
         rollPending    = false;
         buyClosedFlag  = sellClosedFlag = false;
         Log("[TR-CANCEL]", StringFormat("row change %d→%d → cancel pending roll",
                                         pendingRow,newRow));
      }
   }

   /* ── ❸ 今 Tick で Close を実行／再実行 ───────────────── */
   if(!buyClosedFlag)  buyClosedFlag  = CloseColumn(colBuy);
   if(!sellClosedFlag) sellClosedFlag = CloseColumn(colSell);

   /* ── ❹ 両列 Close 完了チェック ─────────────────────── */
   if(!(buyClosedFlag && sellClosedFlag))
   {
      // まだ未完 : 次 Tick へ持ち越し
      rollPending = true;
      pendingRow  = newRow;
      Log("[TR-PEND]", StringFormat("row=%d waiting close (buy=%d sell=%d)",
                                    newRow,buyClosedFlag,sellClosedFlag));
      return;                       // Place() は実行しない
   }

   /* ── ❺ Place()  ※ここに到達するのは Close 完了後だけ ─── */
   rollPending    = false;
   buyClosedFlag  = sellClosedFlag = false;     // 次回用にリセット

   // 新 Row に建て直し（1 回だけ）
   Place(ORDER_TYPE_BUY , colBuy , newRow, ROLE_TREND);
   Place(ORDER_TYPE_SELL, colSell, newRow, ROLE_TREND);

   lastRow = newRow;
   lastDir = dir;

   Log("[StepRow]", StringFormat("row=%d dir=%d Trend rolled (Safe-Roll)", newRow, dir));
}

//================= Stats / Close 判定 ==============================
bool ColumnStats(const int col,int &count,double &minProfit,double &netProfit)
{
   if(g_dryRunIfMarketClosed && g_marketClosed){
      count = colTab[col].simCount; minProfit=0.0; netProfit=0.0;
      return (count>0);
   }

   count=0; minProfit=DBL_MAX; netProfit=0.0;
   for(int i=PositionsTotal()-1;i>=0;--i){
      ulong tk=PositionGetTicket(i);
      if(tk==0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=_magicBase+col) continue;
      double p=PositionGetDouble(POSITION_PROFIT);
      netProfit+=p; if(p<minProfit) minProfit=p; count++;
   }
   if(count==0){ minProfit=0.0; netProfit=0.0; return false; }
   return true;
}

//--------------------------------------------------------------------
//  CheckWeightedClose – BE ロジック
//--------------------------------------------------------------------
void CheckWeightedClose(const int curRow)
{
   for(int c = 1; c < nextCol; ++c)
   {
      if(colTab[c].role != ROLE_ALT) continue;

      int    cnt;  double minP, net;
      if(!ColumnStats(c, cnt, minP, net)) continue;

      bool cnt_ok  = (cnt >= 3) && ((cnt & 1) == 1);
      int  needDist= (cnt - 1) / 2;
      int  curDist = MathAbs(curRow - colTab[c].originRow);
      bool dist_ok = (curDist == needDist);

      int  diff      = curRow - colTab[c].originRow;
      bool is_return = (diff != 0) &&
                       ((diff > 0 && colTab[c].originDir < 0) ||
                        (diff < 0 && colTab[c].originDir > 0));

      /*---------------- 判定 ----------------*/
      bool sim_ok  =  cnt_ok && dist_ok && is_return;                     // DRY-RUN
      bool be_ok   = (net >= 0.0) || (minP >= -g_wclose_eps);             // BE
      bool real_ok =  cnt_ok && be_ok && is_return;                       // REAL

      bool useSim  = g_forceSim || (g_dryRunIfMarketClosed && g_marketClosed);
      bool cond    = useSim ? sim_ok : real_ok;
      string mode  = useSim ? "SIM" : "REAL";

      /*------------- 実行 / ログ --------------*/
      if(cond)
      {
         CloseColumn(c);
         Log("[W-CLOSE]", StringFormat(
             "c=%d cnt=%d dist=%d (mode=%s)", c, cnt, needDist, mode));

         colTab[c].role        = ROLE_NONE;
         colTab[c].lastSide    = SIDE_NONE;
         colTab[c].lastFlipRow = -999;
      }
      else
      {
         Log("[W-CLOSE-DBG]", StringFormat(
            "c=%d cnt=%d min=%.2f net=%.2f cur=%d org=%d dir0=%d diff=%d "
            "ret=%s dist=%d/%d (cnt_ok=%s, dist_ok=%s)",
            c, cnt, minP, net, curRow, colTab[c].originRow,
            colTab[c].originDir, diff,
            is_return ? "T" : "F",
            curDist, needDist,
            cnt_ok  ? "T" : "F",
            dist_ok ? "T" : "F"));
      }
   }
}

//================= UpdateALT =================
void UpdateALT(const int curRow)
{
    if(curRow == lastRow)           // ★ Safe-Roll 直後を除外
        return;

    for(int c = 1; c < nextCol; ++c)
    {
        if(colTab[c].role != ROLE_ALT) continue;
        if(curRow == colTab[c].lastFlipRow) continue;

        int diff = curRow - colTab[c].originRow;
        int dirTrend = (diff > 0) ? +1 : -1;
        if(dirTrend != colTab[c].originDir) continue;

        SIDE nextSide = (colTab[c].lastSide == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
        if(Place(ToOrderType(nextSide), c, curRow, ROLE_ALT))
        {
            colTab[c].lastSide    = nextSide;
            colTab[c].lastFlipRow = curRow;
        }
    }
}

//====================================================================
//  Profit-Close-Break (MIN-1G 発火) 2025-08-03 fixed
//====================================================================
void CheckProfitCloseBreak(const int row,const int prev_row)
{
   // セット配列を必要に応じて初期化
   EnsureSetInitIfAlive(prev_row);
   const int mx = MaxSetIdInUse();

   for(int s = 1; s <= mx; ++s)
   {
      /* --- 発火条件 ------------------------------------------------ */
      int curMin = setPrevMin[s];
      if(curMin == INF_I)         continue;                // 未初期化
      if(prev_row != curMin       // ひとつ前が MIN
      || row      != curMin - 1 ) continue;                // 今回が MIN-1

      /* --- セット内 Hi / Lo 列を抽出 ------------------------------ */
      int hiCol=-1, loCol=-1;
      int hiRow=-INF_I, loRow=INF_I;

      for(int c = 1; c < nextCol; ++c)
      {
         if(colTab[c].setId != s || colTab[c].role == ROLE_NONE) continue;
         int ref = colTab[c].originRow;

         if(ref > hiRow || (ref == hiRow && c > hiCol)){ hiRow = ref; hiCol = c; }
         if(ref < loRow || (ref == loRow && c < loCol)){ loRow = ref; loCol = c; }
      }
      if(hiCol < 0 || loCol < 0) continue;                 // 念のためガード

      /* -------------------------------------------------------------
       * ① 最高値列 hiCol を利食い → role = NONE
       * ------------------------------------------------------------*/
      CloseColumn(hiCol);
      Log("[P-CLOSE]",
          StringFormat("set=%d hiCol=%d MAX at MIN-1 row=%d", s, hiCol, row));

      colTab[hiCol].role        = ROLE_NONE;
      colTab[hiCol].lastSide    = SIDE_NONE;
      colTab[hiCol].lastFlipRow = -999;
      colTab[hiCol].simCount    = 0;

  // ALWAYS rebase loCol as ALT when P→ALT fires
colTab[loCol].role      = ROLE_ALT;
colTab[loCol].anchor    = ANCH_NONE;
colTab[loCol].originRow = row;      // ← このセットの ALT 基点を“今”に更新
colTab[loCol].originDir = lastDir;  // ← その時点のトレンド方向を記録
colTab[loCol].simCount  = 1;        // ← 初期は“既存 1 本”のみに統一
// lastSide / lastFlipRow は Place() が更新するのでここでは触らない
 
      // Sell 1 本追加（Place 成功時に simCount++ / lastSide も更新される）
      if(Place(ORDER_TYPE_SELL, loCol, row, ROLE_ALT))
      {
         Log("[P→ALT]",
             StringFormat("set=%d baseCol=%d Sell-ALT start @row=%d",
                          s, loCol, row));
      }
   }
}   // ★←ここで関数を閉じる

//--- Profit‑close ---------------------------------------------------
void CheckProfitClose(const int row)
{
   for(int c=1;c<nextCol;++c){
      if(colTab[c].role!=ROLE_PROFIT) continue;

      if(g_dryRunIfMarketClosed && g_marketClosed){
         int dist = MathAbs(row - colTab[c].originRow);
         if(dist >= g_profit_rows_sim){
            CloseColumn(c);
            Log("[P-CLOSE]", StringFormat("c=%d rows=%d (mode=SIM)", c, dist));
            colTab[c].role=ROLE_NONE;
         }else{
            Log("[P-CLOSE-DBG]", StringFormat("c=%d rows=%d (need >=%d)", c, dist, g_profit_rows_sim));
         }
         continue;
      }

      int cnt; double minP, net;
      if(!ColumnStats(c,cnt,minP,net)){
         colTab[c].role=ROLE_NONE; // 玉なしで役割だけ残っていたら解放
         continue;
      }
      if(net >= g_profit_min_net && minP >= -g_wclose_eps){
         CloseColumn(c);
         Log("[P-CLOSE]", StringFormat("c=%d cnt=%d net=%.2f", c, cnt, net));
         colTab[c].role=ROLE_NONE;
      }else{
         Log("[P-CLOSE-DBG]", StringFormat("c=%d cnt=%d min=%.2f net=%.2f", c, cnt, minP, net));
      }
   }
}

//================= メイン入口 ======================================
void StepRow(const int newRow,const int dir)
{
   StepCount++;
   RefreshMarketStatus();

   const int prevRow = lastRow;

   if(!g_firstMoveDone && lastDir==0){
      HandleFirstMove(newRow, dir);
      g_firstMoveDone = true;
      lastRow = newRow;
      lastDir = dir;
      UpdateSetExtremaEndOfStep(newRow);
      return;
   }

   if(dir != lastDir) HandlePivot(newRow, dir);
   else               HandleTrendRoll(newRow, dir);

      // 極値±1ブレイク → WeightedClose → ALT更新   ★呼び出し順を変更
   CheckProfitCloseBreak(newRow, prevRow);
   CheckWeightedClose(newRow);   // ← 戻り幅判定を先に実行
   UpdateALT(newRow);            // ← flip はその後

   lastRow = newRow;
   lastDir = dir;

   // セットの極値を更新
   UpdateSetExtremaEndOfStep(newRow);
}

//================= Sim/Reset ======================================
void SimulateMove(const int targetRow)
{
   int guard=200;
   while(lastRow!=targetRow && guard-- > 0){
      int step=(targetRow>lastRow)? +1:-1;
      StepRow(lastRow+step, step);
   }
   if(guard<=0) Log("[ERR]","Guard hit in SimulateMove");
}

void SimulateHalfStep(){ Log("[HalfStep]","no‑op"); }

void ResetAll()
{
   trade.SetAsyncMode(false); trade.SetExpertMagicNumber(_magicBase); trade.SetDeviationInPoints(20);
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_CONNECTED))
      Print("[WARN] terminal not connected. Skip trading.");

   RefreshMarketStatus();

   long mm=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   bool hedging=(mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   Log("[ENV]", StringFormat("MarginMode=%ld (%s)", mm, hedging?"HEDGING":"NETTING/EXCHANGE"));
   if(!hedging) Log("[WARN]","Netting口座ではALT多重建てが統合され、テスト条件は成立しません。");

   for(int i=0;i<MAX_COLS;i++) InitColInfo(i);
   g_firstMoveDone=false; nextCol=3; lastRow=0; lastDir=0; StepCount=0;
   
   InitSetBreakArrays(); // ★極値ブレイク配列を初期化

   if(g_dryRunIfMarketClosed && g_marketClosed){
      // 既存玉から simCount を再構築（参考）
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong tk=PositionGetTicket(i);
         if(tk==0 || !PositionSelectByTicket(tk)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         int mg=(int)PositionGetInteger(POSITION_MAGIC);
         int col=mg-_magicBase; if(col>0 && col<MAX_COLS) colTab[col].simCount++;
      }
      Log("[CLOSE-SIM]","market closed -> skip broker closing");
   }else{
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong tk=PositionGetTicket(i);
         if(tk==0 || !PositionSelectByTicket(tk)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         long mg=PositionGetInteger(POSITION_MAGIC);
         if(mg<_magicBase || mg>_magicBase+MAX_COLS+32) continue;
         trade.PositionClose(tk);
      }
   }

   basePrice=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   Log("⚙️","ResetAll done");

   Place(ORDER_TYPE_BUY , colBuy , 0, ROLE_TREND);
   Place(ORDER_TYPE_SELL, colSell, 0, ROLE_TREND);
}

#endif // __TRINITY_CORE_MQH__
