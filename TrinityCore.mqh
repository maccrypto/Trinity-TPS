//+------------------------------------------------------------------+
//| TrinityCore.mqh – ReplayTest 用コア (2025‑07‑27 v2.3‑c)           |
//| ★ 2025‑08‑07 方向フィルタ撤廃パッチ                                |
//|    • UpdateALT() から dirTrend 判定を削除し両方向で flip 可能に     |
//|    • その他ロジックは 2025‑08‑05 版と同一                        |
//+------------------------------------------------------------------+
#ifndef __TRINITY_CORE_MQH__
#define __TRINITY_CORE_MQH__

#include <Trade\Trade.mqh>
CTrade trade;あ

#define MAX_COLS 128
#define MAX_SETS (MAX_COLS/4 + 8)   // ★ セット数上限（4 列＝1 セット + 予備）

//===== (global) 先頭の #define 群のすぐ下あたりに追加 ==================
//==== TPS 表示ID割り当て（改良版） =====================================
// セット帯(500/600/…)の再利用をやめ、生涯一意なグローバル連番を採番。
// セット情報は dispTag ("S{setId}-{id}") でログ可視化する。
static int g_dispGlobalSeq = 0;                 // ★ グローバル連番（生涯一意）
inline int AllocDispId(const int setId){ return 500 + (++g_dispGlobalSeq); }
string MakeDispTag(const int setId,const int dispId){ return StringFormat("S%d-%04d", setId, dispId); }

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
   int         tpsGroup;      // TPS 論理グループID (0=未リンク, s=セットID)
   int         dispId;        // 表示用カラム番号（TPSは500+連番）
   string      dispTag;       // 表示タグ（例: "S3-0721"）
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

//==== 実運用向けフラグ / スワップ優先設定 / グローバルTP ==================
bool   g_enableLog   = true;        // 実運用では false（必要最低限のログだけ）

enum SWAP_KEEP { KEEP_LONG=1, KEEP_SHORT=2 };
int    g_swap_keep   = KEEP_LONG;    // 1=ロング残し, 2=ショート残し（EA側で上書き）
inline bool IsSwapKeepLong(){ return g_swap_keep==KEEP_LONG; }

bool   g_tp_enable   = false;        // 全体TP(利益到達で全決済→即時再起動)
double g_tp_amount   = 0.0;          // 口座通貨建ての目標利益

double g_equity_start= 0.0;          // ResetAll() 時の基準エクイティ
//==== TPS 表示用カラム番号（人が見やすい識別用。内部Indexは従来通り） ====
int g_tpsDisplayBase = 500;
int g_tpsDisplaySeq  = 0; 

// ==== 極値ブレイク用（新規） =======================================
//#define MAX_SETS (MAX_COLS/4 + 8)   // ← ★ 既に定義済み
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
void   Log(string tag,string msg){ if(!g_enableLog) return; PrintFormat("%s  %s",tag,msg); }

//==== 統一クローズログ（理由コード付） ===============================
enum CLOSE_REASON { CLOSE_WCLOSE, CLOSE_PCB_HI, CLOSE_TPS_BE, CLOSE_PROFIT, CLOSE_SAFE_ROLL, CLOSE_SIM, CLOSE_PENDING, CLOSE_FORCE, CLOSE_RESET };
string CloseReasonName(CLOSE_REASON r){
    switch(r){
        case CLOSE_WCLOSE: return "W-CLOSE";
        case CLOSE_PCB_HI: return "PCB-HI";
        case CLOSE_TPS_BE: return "TPS-BE";
        case CLOSE_PROFIT: return "PROFIT";
        case CLOSE_SAFE_ROLL: return "SAFE-ROLL";
        case CLOSE_SIM: return "SIM";
        case CLOSE_PENDING: return "PENDING";
        case CLOSE_FORCE: return "FORCE";
        case CLOSE_RESET: return "RESET";
        default: return "UNKNOWN";
    }
}
void LogCloseStd(const int col, const CLOSE_REASON reason, const int row, const string mode, const string extra=""){
    int dc = (colTab[col].dispId>0 ? colTab[col].dispId : col);
    string lab = (StringLen(colTab[col].dispTag)>0) ? StringFormat(" tag=%s", colTab[col].dispTag) : "";
    Log("[CLOSE]", StringFormat("reason=%s c=%d dc=%d%s row=%d mode=%s %s",
        CloseReasonName(reason), col, dc, lab, row, mode, extra));
}


ENUM_ORDER_TYPE OppositeType(ENUM_ORDER_TYPE t){ return (t==ORDER_TYPE_BUY)? ORDER_TYPE_SELL:ORDER_TYPE_BUY; }
// ----- ★ 新規追加：SIDE → ORDER_TYPE 変換ヘルパ ------------------
ENUM_ORDER_TYPE ToOrderType(SIDE s){ return (s==SIDE_BUY)? ORDER_TYPE_BUY:ORDER_TYPE_SELL; }

int  SetID(int col){ return 1 + (col-1)/4; }

void InitColInfo(int col){ if(col<0 || col>=MAX_COLS) return; colTab[col].id=col; colTab[col].role=ROLE_NONE; colTab[col].setId=SetID(col); colTab[col].anchor=ANCH_NONE; colTab[col].originRow=0; colTab[col].lastSide=SIDE_NONE; colTab[col].lastFlipRow=-999; colTab[col].simCount=0;  colTab[col].trendRollLock=false; colTab[col].originDir=0; colTab[col].tpsGroup=0; colTab[col].dispId=0; colTab[col].dispTag=""; }

bool EnsureCols(int need){ if(nextCol + need >= MAX_COLS){ Log("[ERR]","Column capacity exceeded"); return false; } return true; }

void RefreshMarketStatus(){ MqlTradeRequest req; ZeroMemory(req); MqlTradeCheckResult chk; ZeroMemory(chk); double vol_min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN); double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); double vol=MathMax(_lot,vol_min); if(step>0) vol=MathRound(vol/step)*step; req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.type=ORDER_TYPE_BUY; req.volume=vol; req.price=SymbolInfoDouble(_Symbol,SYMBOL_ASK); req.magic=_magicBase; bool ok = OrderCheck(req,chk); bool prev=g_marketClosed; if(!ok){ g_marketClosed=true; }else{ g_marketClosed=(chk.retcode==TRADE_RETCODE_MARKET_CLOSED); } if(g_marketClosed!=prev) Log("[MARKET]", g_marketClosed? "closed → DRY-RUN":"open"); }

//--- ★ 前方宣言 ----------------------------------------------------
void EnsureSetInitIfAlive(const int prev_row);
int  MaxSetIdInUse();
void UpdateSetExtremaEndOfStep(const int newRow);
void UpdateALT(const int curRow); 

// TPS 追加分（前方宣言）
void CheckTPS(const int newRow, const int prev_row)
{
   const int mx = MaxSetIdInUse();
   for(int s=1; s<=mx; ++s){
      int curMin = setPrevMin[s];
      int curMax = setPrevMax[s];
      if(IsSwapKeepLong()){
         if(curMin!=INF_I && prev_row == curMin && newRow == curMin-1){
            Log("[TPS]", StringFormat("trigger set=%d row=%d (MIN-1)", s, newRow));
            TPS_FireForSet(s, newRow);
         }
      }else{
         if(curMax!=-INF_I && prev_row == curMax && newRow == curMax+1){
            Log("[TPS]", StringFormat("trigger set=%d row=%d (MAX+1)", s, newRow));
            TPS_FireForSet(s, newRow);
         }
      }
   }
}

int MaxSetIdInUse()
{
   int mx = 0;
   for(int c=1; c<nextCol; ++c)
   {
      if(colTab[c].role != ROLE_NONE)
         mx = (colTab[c].setId > mx) ? colTab[c].setId : mx;
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

// fwd
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

    int dc = (colTab[col].dispId>0 ? colTab[col].dispId : col); // 表示用Col番号

    /*========== 市場休場：ドライラン ==========*/
    if(g_dryRunIfMarketClosed && g_marketClosed)
    {
        Log("[NEW-SIM]", StringFormat(
            "r=%d c=%d dc=%d %s (%s) dry-run",
            row, col, dc,
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
    req.comment   = StringFormat("r=%d c=%d dc=%d",row,col,dc);

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
                "r=%d c=%d dc=%d %s (%s) fallback dry-run (market closed)",
                row, col, dc,
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
            "r=%d c=%d dc=%d %s rc=%ld",
            row, col, dc,
            (thisSide==SIDE_BUY ? "Buy" : "Sell"),
            rc));
        return false;
    }

    /*========== 発注成功時の処理 ==========*/
    Log("[NEW]", StringFormat(
        "r=%d c=%d dc=%d %s (%s)",
        row, col, dc,
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
      LogCloseStd(col, CLOSE_SIM, lastRow, "SIM", StringFormat("clear=%d", before));
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
            LogCloseStd(col, CLOSE_SIM, lastRow, "SIM", "fallback market closed; clear simCount");
            continue;           // このポジは“無かった”ことに
         }

         allClosed = false;    // まだ残っている
      }
   }

   if(anyPos && !allClosed)
   {
      LogCloseStd(col, CLOSE_PENDING, lastRow, "REAL", "waiting broker close");
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
         LogCloseStd(c, CLOSE_WCLOSE, curRow, mode, StringFormat("cnt=%d dist=%d", cnt, needDist));

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

void UpdateALT(const int curRow)
{
    // Safe‑Roll 直後は同じ row に留まるので除外
    if(curRow == lastRow)
        return;

    for(int c = 1; c < nextCol; ++c)
    {
        if(colTab[c].role != ROLE_ALT)           continue;   // ALT 列のみ
        if(curRow == colTab[c].lastFlipRow)      continue;   // 同 row 重複防止

        /* ★★★ 方向フィルタを完全撤廃 ★★★
         *   ‑ dirTrend != originDir の判定を削除。
         *   これにより往路／復路どちらでも一定間隔ごとに flip が入るため、
         *   cnt は必ず奇数 (3,5,7,…) へ伸び、Weighted‑Close の cnt_ok を満たす。*/

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
   EnsureSetInitIfAlive(prev_row);
   const int mx = MaxSetIdInUse();

   for(int s = 1; s <= mx; ++s)
   {
      int curMin = setPrevMin[s];
      int curMax = setPrevMax[s];

      bool fireLong  = IsSwapKeepLong() && (curMin!=INF_I)  && (prev_row==curMin && row==curMin-1);
      bool fireShort = (!IsSwapKeepLong()) && (curMax!=-INF_I) && (prev_row==curMax && row==curMax+1);
      if(!(fireLong || fireShort)) continue;

      // --- セット内 Hi / Lo / HiSell を抽出 -----------------------
      int hiCol=-1, loCol=-1, hiSellCol=-1;
      int hiRow=-INF_I, loRow=INF_I, hiSellRow=-INF_I;

      for(int c = 1; c < nextCol; ++c)
      {
         if(colTab[c].setId != s || colTab[c].role == ROLE_NONE) continue;
         int ref = colTab[c].originRow;
         if(ref > hiRow || (ref == hiRow && c > hiCol)){ hiRow = ref; hiCol = c; }
         if(ref < loRow || (ref == loRow && c < loCol)){ loRow = ref; loCol = c; }
         if((c%2)==0 && (ref>hiSellRow || (ref==hiSellRow && c>hiSellCol))){ hiSellRow=ref; hiSellCol=c; }
      }
      if(hiCol<0 || loCol<0) continue; // 念のため

      if(fireLong)
      {
         // (ロング残し) MIN-1 で MAX 列を利食いし、最も低いBuy列をALT化して初手SELL
         CloseColumn(hiCol);
         Log("[P-CLOSE]", StringFormat("set=%d hiCol=%d MAX at MIN-1 row=%d", s, hiCol, row));

         colTab[hiCol].role = ROLE_NONE; colTab[hiCol].lastSide=SIDE_NONE; colTab[hiCol].lastFlipRow=-999; colTab[hiCol].simCount=0;

         colTab[loCol].role      = ROLE_ALT;
         colTab[loCol].anchor    = ANCH_NONE;
         colTab[loCol].originRow = row;
         colTab[loCol].originDir = lastDir;
         colTab[loCol].simCount  = 1;
         if(Place(ORDER_TYPE_SELL, loCol, row, ROLE_ALT))
            Log("[P→ALT]", StringFormat("set=%d baseCol=%d Sell-ALT start @row=%d", s, loCol, row));
      }
      else // fireShort
      {
         // (ショート残し) MAX+1 で MIN 列を利食いし、最も高いSell列をALT化して初手BUY
         if(hiSellCol<0) continue; // アンカーSell列が見つからない場合はスキップ

         CloseColumn(loCol);
         Log("[P-CLOSE]", StringFormat("set=%d loCol=%d MIN at MAX+1 row=%d", s, loCol, row));

         colTab[loCol].role = ROLE_NONE; colTab[loCol].lastSide=SIDE_NONE; colTab[loCol].lastFlipRow=-999; colTab[loCol].simCount=0;

         colTab[hiSellCol].role      = ROLE_ALT;
         colTab[hiSellCol].anchor    = ANCH_NONE;
         colTab[hiSellCol].originRow = row;
         colTab[hiSellCol].originDir = lastDir;
         colTab[hiSellCol].simCount  = 1;
         if(Place(ORDER_TYPE_BUY, hiSellCol, row, ROLE_ALT))
            Log("[P→ALT]", StringFormat("set=%d baseCol=%d Buy-ALT start @row=%d", s, hiSellCol, row));
      }
   }
}   // ★←ここで関数を閉じる

//====================================================================
//  TPS 機能：検出・発火・補助
//====================================================================

int FindLowestBuyColInSet(const int setId)
{
   int loCol=-1; int loRow=INF_I;
   for(int c=1;c<nextCol;++c){
      if(colTab[c].role==ROLE_NONE) continue;
      if(colTab[c].setId!=setId) continue;
      if((c%2)==1){ // 規約：奇数カラム=Buy列
         int r = colTab[c].originRow;
         if(r<loRow){ loRow=r; loCol=c; }
      }
   }
   return loCol;
}

int FindHighestSellColInSet(const int setId)
{
   int hiCol=-1; int hiRow=-INF_I;
   for(int c=1;c<nextCol;++c){
      if(colTab[c].role==ROLE_NONE) continue;
      if(colTab[c].setId!=setId) continue;
      if((c%2)==0){ // 規約：偶数カラム=Sell列
         int r = colTab[c].originRow;
         if(r>hiRow){ hiRow=r; hiCol=c; }
      }
   }
   return hiCol;
}

int TPS_GatherCols(const int setId, int &outCols[], const int outMax)
{
   bool used[MAX_COLS]; ArrayInitialize(used,0);
   int n=0;
   for(int c=1;c<nextCol;++c){
      if(colTab[c].role==ROLE_NONE) continue;
      if(colTab[c].setId==setId || colTab[c].tpsGroup==setId || colTab[c].setId==1){
         if(!used[c]){ if(n<outMax){ outCols[n++]=c; used[c]=true; } }
      }
   }
   return n;
}

bool TPS_IsAllNonAnchorBE(const int setId, const int anchorCol, const double eps)
{
   int cols[MAX_COLS]; int n = TPS_GatherCols(setId, cols, MAX_COLS);
   for(int i=0;i<n;++i){ int c=cols[i]; if(c==anchorCol) continue; int cnt; double minP, net; if(!ColumnStats(c,cnt,minP,net)) continue; if(net < -eps) return false; }
   return true;
}

//====================================================================
//  TPS_OpenTrendPair – 500/600… の dispId を自動付番する版
//====================================================================
void TPS_OpenTrendPair(const int setId, const int row,
                       int &newBuyCol, int &newSellCol)
{
    newBuyCol  = -1;
    newSellCol = -1;

    if(!EnsureCols(2)) return;

    newBuyCol  = nextCol++;
    newSellCol = nextCol++;

    InitColInfo(newBuyCol);
    InitColInfo(newSellCol);

    colTab[newBuyCol ].role     = ROLE_TREND;
    colTab[newSellCol].role     = ROLE_TREND;

    colTab[newBuyCol ].tpsGroup = setId;
    colTab[newSellCol].tpsGroup = setId;

    // ★ dispId はセット毎の 500/600/… 帯で採番
    colTab[newBuyCol ].dispId   = AllocDispId(setId);
    colTab[newSellCol].dispId   = AllocDispId(setId);
    colTab[newBuyCol ].dispTag  = MakeDispTag(setId, colTab[newBuyCol].dispId);
    colTab[newSellCol].dispTag  = MakeDispTag(setId, colTab[newSellCol].dispId);

    Place(ORDER_TYPE_BUY , newBuyCol ,  row, ROLE_TREND);
    Place(ORDER_TYPE_SELL, newSellCol, row, ROLE_TREND);

    Log("[TPS-OPEN]", StringFormat(
        "set=%d newB=%d newS=%d row=%d",
        setId, newBuyCol, newSellCol, row));
}

void TPS_FireForSet(const int setId, const int row)
{
   int loCol = FindLowestBuyColInSet(setId);
   if(loCol<0){ Log("[TPS-DBG]", StringFormat("set=%d no Buy col found", setId)); return; }

      // PCB未実行ケースに備え、loCol の ALT化と S エントリーを保証
   if(colTab[loCol].role != ROLE_ALT || colTab[loCol].lastFlipRow != row)
   {
      colTab[loCol].role      = ROLE_ALT;
      colTab[loCol].anchor    = ANCH_NONE;
      colTab[loCol].originRow = row;
      colTab[loCol].originDir = lastDir;

      // ★ dispId が未設定ならセット帯の番号を付与
      if(colTab[loCol].dispId == 0){
          colTab[loCol].dispId = AllocDispId(setId);
          colTab[loCol].dispTag = MakeDispTag(setId, colTab[loCol].dispId);
      }

      Place(ORDER_TYPE_SELL, loCol, row, ROLE_ALT);

      Log("[TPS-ALT]", StringFormat(
          "set=%d ensure ALT+S on loCol=%d row=%d",
          setId, loCol, row));
   }


   int nb, ns; TPS_OpenTrendPair(setId, row, nb, ns);

   if(TPS_IsAllNonAnchorBE(setId, loCol, g_wclose_eps)){
      int cols[MAX_COLS]; int n = TPS_GatherCols(setId, cols, MAX_COLS); int closed=0;
      for(int i=0;i<n;++i){ int c=cols[i]; if(c==loCol) continue; if(CloseColumn(c)){
      LogCloseStd(c, CLOSE_TPS_BE, row, (g_dryRunIfMarketClosed && g_marketClosed)?"SIM":"REAL", StringFormat("set=%d anchor=%d", setId, loCol));
      colTab[c].role=ROLE_NONE;
      ++closed; } }
      Log("[TPS-BE]", StringFormat("set=%d anchor=%d closed=%d", setId, loCol, closed));
   }else{
      Log("[TPS-BE-DBG]", StringFormat("set=%d anchor=%d not all >=0", setId, loCol));
   }
}

void CheckTPS(const int newRow, const int prev_row)
{
   const int mx = MaxSetIdInUse();
   for(int s=1; s<=mx; ++s){
      int curMin = setPrevMin[s]; if(curMin==INF_I) continue;
      if(prev_row == curMin && newRow == curMin-1){ Log("[TPS]", StringFormat("trigger set=%d row=%d", s, newRow)); TPS_FireForSet(s, newRow); }
   }
}


//--- Profit‑close ---------------------------------------------------
void CheckProfitClose(const int row)
{
   for(int c=1;c<nextCol;++c){
      if(colTab[c].role!=ROLE_PROFIT) continue;

      if(g_dryRunIfMarketClosed && g_marketClosed){
         int dist = MathAbs(row - colTab[c].originRow);
         if(dist >= g_profit_rows_sim){
            CloseColumn(c);
            LogCloseStd(c, CLOSE_PROFIT, row, "SIM", StringFormat("rows=%d", dist));
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
         LogCloseStd(c, CLOSE_PROFIT, row, "REAL", StringFormat("cnt=%d net=%.2f", cnt, net));
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

   // ★ 全体TP：利益到達で全決済→再起動
   if(TryGlobalTPRestart(newRow)) return;

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
   // ★ TPS：PCB直後に起動
   CheckTPS(newRow, prevRow);
   CheckWeightedClose(newRow);   // ← 戻り幅判定を先に実行
   UpdateALT(newRow);            // ← flip はその後

   lastRow = newRow;
   lastDir = dir;

   // セットの極値を更新
   UpdateSetExtremaEndOfStep(newRow);
}

//================= 全体TP補助 ======================================
bool CloseAllPositionsNow()
{
   if(g_dryRunIfMarketClosed && g_marketClosed){
      for(int c=1;c<nextCol;++c){ colTab[c].simCount=0; colTab[c].role=ROLE_NONE; }
      Log("[GLOBAL-TP]","dry-run close all");
      return true;
   }
   for(int i=PositionsTotal()-1;i>=0;--i){
      ulong tk=PositionGetTicket(i);
      if(tk==0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      trade.PositionClose(tk);
   }
   Log("[GLOBAL-TP]","broker close all sent");
   return true;
}

bool TryGlobalTPRestart(const int curRow)
{
   if(!g_tp_enable || g_tp_amount<=0.0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq - g_equity_start < g_tp_amount) return false;

   Log("[GLOBAL-TP]", StringFormat("hit: start=%.2f now=%.2f gain=%.2f >= %.2f",
                                   g_equity_start, eq, eq-g_equity_start, g_tp_amount));
   CloseAllPositionsNow();
   ResetAll();
   return true;
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

   // ★ 基準エクイティ更新（グローバルTP用）
   g_equity_start = AccountInfoDouble(ACCOUNT_EQUITY);


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

