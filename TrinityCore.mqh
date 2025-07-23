//+------------------------------------------------------------------+
//| TrinityCore.mqh  –  ReplayTest 用ロジック共通ヘッダ (Task-1 Fix) |
//+------------------------------------------------------------------+
#ifndef __TRINITY_CORE_MQH__
#define __TRINITY_CORE_MQH__

#include <Trade\Trade.mqh>
CTrade trade;

//================= 定数・型 =========================================
#define MAX_COLS 128

enum ROLE        { ROLE_NONE, ROLE_TREND, ROLE_ALT, ROLE_PROFIT };
enum ANCHOR_TYPE { ANCH_NONE, ANCH_LOW,  ANCH_HIGH };

struct ColInfo
{
   int         id;          // 列ID (=col)
   ROLE        role;        // TREND / ALT / PROFIT / NONE
   int         setId;       // 1 + (id-1)/4
   ANCHOR_TYPE anchor;      // LOW/HIGH アンカー
   int         lastType;    // 最後に建てた注文タイプ (ORDER_TYPE_BUY/SELL) ALT用
   int         originRow;   // 役割が決まった基準row（初動/Pivot）
};
static ColInfo colTab[MAX_COLS];

//================= グローバル状態 ==================================
double basePrice = 0;     // Row0 価格
int    lastRow   = 0;     // 直近Row
int    lastDir   = 0;     // 直近進行方向 (+1/-1/0)
int    colBuy    = 1;     // 現Trend Buy列
int    colSell   = 2;     // 現Trend Sell列
int    nextCol   = 3;     // 次割当列
int    StepCount = 0;     // Sim用カウンタ
bool g_firstMoveDone = false;
int  lastAltFlipRow[64];   // 初期値 -999

//================= ユーティリティ ==================================
void Log(string tag,string msg){ PrintFormat("%s  %s",tag,msg); }

int  OppositeType(int t){ return (t==ORDER_TYPE_BUY)? ORDER_TYPE_SELL:ORDER_TYPE_BUY; }
int  SetID(int col){ return 1 + (col-1)/4; }

void InitColInfo(int col)
{
   colTab[col].id       = col;
   colTab[col].role     = ROLE_NONE;
   colTab[col].setId    = SetID(col);
   colTab[col].anchor   = ANCH_NONE;
   colTab[col].lastType = -1;
   colTab[col].originRow= 0;
}

//================= オーダーヘルパー群 ==============================
void Place(int orderType,int col,int row,string tag="")
{
   MqlTradeRequest req;  MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);

   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.type      = orderType;
   req.volume    = 0.01;
   req.price     = (orderType==ORDER_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                     : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.deviation = 20;
   req.magic     = 900000 + col;
   req.comment   = StringFormat("r=%d c=%d %s",row,col,tag);

   OrderSend(req,res);

   colTab[col].lastType = orderType;

   string side = (orderType==ORDER_TYPE_BUY) ? "Buy":"Sell";
   Log("[NEW]", StringFormat("r=%d c=%d %s (%s)", row, col, side, tag));
}

void CloseColumn(int col)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != 900000 + col) continue;

      trade.PositionClose(ticket);
      Log("[CLOSE]", StringFormat("c=%d ticket=%I64u", col, ticket));
   }
}

//================= ALT 更新 =========================================
void UpdateAltColumns(int row)
{
   for(int c=1; c<nextCol; ++c)
   {
      if(colTab[c].role != ROLE_ALT) continue;

      int newType = (colTab[c].lastType==-1)
                      ? ORDER_TYPE_SELL
                      : OppositeType(colTab[c].lastType);

      CloseColumn(c);
      Place(newType, c, row, "ALT");
      Log("[ALT]", StringFormat("row=%d c=%d %s", row, c, (newType==ORDER_TYPE_BUY?"Buy":"Sell")));
   }
}

//================= 役割付けヘルパー ================================
void HandleFirstMove(int newRow,int dir)
{
   Log("[INIT-MOVE]", StringFormat("dir=%d row=%d", dir, newRow));

   int profitCol = (dir== 1) ? colBuy  : colSell;
   int altCol    = (dir== 1) ? colSell : colBuy;

   colTab[profitCol].role      = ROLE_PROFIT;
   colTab[profitCol].anchor    = (dir==1)? ANCH_LOW : ANCH_HIGH;
   colTab[profitCol].originRow = lastRow;
   Log("[ROLE]", StringFormat("c=%d → PROFIT (%s)", profitCol,
                              (dir==1?"LOW":"HIGH")));

   colTab[altCol].role      = ROLE_ALT;
   colTab[altCol].anchor    = ANCH_NONE;
   colTab[altCol].originRow = lastRow;

   // ALT 再建て（逆サイド）
   CloseColumn(altCol);
   int firstAltType = OppositeType(colTab[altCol].lastType);
   Place(firstAltType, altCol, newRow, "ALT");
   Log("[ROLE]", StringFormat("c=%d → ALT (first flip)", altCol));

   // 新 TrendPair
   colBuy  = nextCol++;
   colSell = nextCol++;
   InitColInfo(colBuy);  InitColInfo(colSell);
   colTab[colBuy].role  = ROLE_TREND;
   colTab[colSell].role = ROLE_TREND;

   Place(ORDER_TYPE_BUY , colBuy , newRow, "TREND_B");
   Place(ORDER_TYPE_SELL, colSell, newRow, "TREND_S");

   lastRow = newRow;
   lastDir = dir;
}

void HandlePivot(int newRow,int dir)
{
   Log("[PIVOT]", StringFormat("detected dir=%d at row=%d", dir, newRow));

   int winnerCol = (dir==-1) ? colSell : colBuy;
   int loserCol  = (winnerCol==colBuy) ? colSell : colBuy;

   colTab[winnerCol].role      = ROLE_PROFIT;
   colTab[winnerCol].anchor    = (dir==1)? ANCH_LOW : ANCH_HIGH; // 暫定
   colTab[winnerCol].originRow = newRow;

   colTab[loserCol].role      = ROLE_ALT;
   colTab[loserCol].anchor    = ANCH_NONE;
   colTab[loserCol].originRow = newRow;

   Log("[ROLE]", StringFormat("c=%d → PROFIT", winnerCol));
   Log("[ROLE]", StringFormat("c=%d → ALT",    loserCol));

   colBuy  = nextCol++;
   colSell = nextCol++;
   InitColInfo(colBuy);  InitColInfo(colSell);
   colTab[colBuy].role  = ROLE_TREND;
   colTab[colSell].role = ROLE_TREND;

   Place(ORDER_TYPE_BUY , colBuy , newRow, "TREND_B");
   Place(ORDER_TYPE_SELL, colSell, newRow, "TREND_S");

   lastRow = newRow;
   lastDir = dir;
}

void HandleTrendRoll(int newRow,int dir)
{
   CloseColumn(colBuy);
   CloseColumn(colSell);

   Place(ORDER_TYPE_BUY , colBuy , newRow, "TREND_B");
   Place(ORDER_TYPE_SELL, colSell, newRow, "TREND_S");

   lastRow = newRow;
   lastDir = dir;
   Log("[StepRow]", StringFormat("row=%d dir=%d Trend rolled", newRow, dir));
}

//================= メイン入口 =======================================
void StepRow(const int newRow,const int dir)
{
   StepCount++;

   bool isFirstMove = (lastDir==0);
   bool pivot       = (!isFirstMove && dir!=lastDir);

   Log("[DBG]", StringFormat("row=%d dir=%d lastDir=%d pivot=%s",
                             newRow, dir, lastDir, pivot?"YES":"NO"));

   if(isFirstMove){
      HandleFirstMove(newRow,dir);
      //UpdateAltColumns(newRow);
      return;
   }

   if(pivot){
      HandlePivot(newRow,dir);
      UpdateAltColumns(newRow);
      return;
   }

   HandleTrendRoll(newRow,dir);
   UpdateAltColumns(newRow);
}

//================= Sim/Reset =======================================
void SimulateMove(const int targetRow)
{
   int step = (targetRow > lastRow)? +1 : -1;
   while(lastRow != targetRow)
   {
      int nextRow = lastRow + step;
      StepRow(nextRow, step);
   }
}

void SimulateHalfStep()
{
   Log("[HalfStep]","no‑op");
}

void ResetAll()
{
   for(int i=0;i<MAX_COLS;i++) InitColInfo(i);

   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      trade.PositionClose(ticket);
   }

   basePrice = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   lastRow   = 0;
   lastDir   = 0;
   colBuy    = 1;
   colSell   = 2;
   nextCol   = 3;
   StepCount = 0;

   InitColInfo(colBuy);  InitColInfo(colSell);
   colTab[colBuy].role  = ROLE_TREND;
   colTab[colSell].role = ROLE_TREND;

   Log("⚙️","ResetAll done");

   Place(ORDER_TYPE_BUY , colBuy , 0, "TREND_B");
   Place(ORDER_TYPE_SELL, colSell, 0, "TREND_S");
}

#endif // __TRINITY_CORE_MQH__
