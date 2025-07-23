//+------------------------------------------------------------------+
//| TrinityCore.mqh  –  ReplayTest 用ロジック共通ヘッダ (Task-1 Fix) |
//+------------------------------------------------------------------+
#ifndef __TRINITY_CORE_MQH__
#define __TRINITY_CORE_MQH__

#include <Trade\Trade.mqh>
CTrade trade;

//================= 定数・型 =========================================
#define MAX_COLS 128

//==== ROLE / SIDE / ANCHOR =======================================
enum ROLE        { ROLE_NONE, ROLE_TREND, ROLE_ALT, ROLE_PROFIT };
enum SIDE        { SIDE_NONE=-1, SIDE_BUY=ORDER_TYPE_BUY, SIDE_SELL=ORDER_TYPE_SELL };
enum ANCHOR_TYPE { ANCH_NONE=0, ANCH_LOW=1, ANCH_HIGH=2 };

//==== 列情報 ======================================================
struct ColInfo{
   int         id;
   ROLE        role;
   int         setId;
   ANCHOR_TYPE anchor;
   int         originRow;
   SIDE        lastSide;
   int         lastFlipRow;
};

// 配列
ColInfo colTab[64];

//==== マクロで旧名を吸収（速攻で直す用）===========================
#define anchorType  anchor
#define lastType    lastSide
//==== グローバル =================================================
double  _lot       = 0.01;
int     _magicBase = 900000;

double basePrice = 0;
int    lastRow   = 0;
int    lastDir   = 0;
int    StepCount = 0;

int    colBuy    = 1;
int    colSell   = 2;
int    nextCol   = 3;

bool   g_firstMoveDone = false;

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
// ★これだけ残す（デフォルト引数で3引数呼び出しもOKにする）
void Place(const int orderType,
           const int col,
           const int row,
           const ROLE role = ROLE_NONE)
{
   MqlTradeRequest req;  MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.type     = (ENUM_ORDER_TYPE)orderType;
   req.volume   = _lot;
   req.price    = (orderType==ORDER_TYPE_BUY)
                    ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                    : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.deviation = 20;
   req.magic     = _magicBase + col;
   req.comment   = StringFormat("r=%d c=%d",row,col);

   trade.OrderSend(req,res);

   string side = (orderType==ORDER_TYPE_BUY) ? "Buy" : "Sell";
   Log("[NEW]", StringFormat("r=%d c=%d %s (%s)",
        row,col,side,
        role==ROLE_TREND ?"TREND":
        role==ROLE_ALT   ?"ALT":
        role==ROLE_PROFIT?"PROFIT":""));
   // colTab 更新など…
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
void UpdateAltColumns(int row,int dir)
{
   for(int c=1;c<64;c++){
      if(colTab[c].role != ROLE_ALT) continue;
      if(colTab[c].lastFlipRow == row) continue; // 同rowで二重処理禁止

      // 前玉クローズ
      CloseColumn(c);

      // 直前の反対サイド
      SIDE side = (colTab[c].lastSide==SIDE_BUY)? SIDE_SELL : SIDE_BUY;
      Place((int)side, c, row, ROLE_ALT);
      colTab[c].lastSide    = side;
      colTab[c].lastFlipRow = row;
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
 Place((int)firstAltType, altCol, newRow, ROLE_ALT);
   Log("[ROLE]", StringFormat("c=%d → ALT (first flip)", altCol));

   // 新 TrendPair
   colBuy  = nextCol++;
   colSell = nextCol++;
   InitColInfo(colBuy);  InitColInfo(colSell);
   colTab[colBuy].role  = ROLE_TREND;
   colTab[colSell].role = ROLE_TREND;

   Place(ORDER_TYPE_BUY ,  colBuy ,  newRow, ROLE_TREND);
   Place(ORDER_TYPE_SELL,  colSell, newRow, ROLE_TREND);

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

   Place(ORDER_TYPE_BUY ,  colBuy ,  newRow, ROLE_TREND); 
   Place(ORDER_TYPE_SELL,  colSell, newRow, ROLE_TREND);

   lastRow = newRow;
   lastDir = dir;
}

void HandleTrendRoll(int newRow,int dir)
{
   CloseColumn(colBuy);
   CloseColumn(colSell);

   Place(ORDER_TYPE_BUY ,  colBuy ,  newRow, ROLE_TREND);
   Place(ORDER_TYPE_SELL,  colSell, newRow, ROLE_TREND);

   lastRow = newRow;
   lastDir = dir;
   Log("[StepRow]", StringFormat("row=%d dir=%d Trend rolled", newRow, dir));
}

//================= メイン入口 =======================================
void StepRow(const int newRow,const int dir)
{
   StepCount++;

   // --- 初動 ---------------------------------------------------
   if(!g_firstMoveDone && lastDir==0){
      HandleFirstMove(newRow, dir);
      lastRow = newRow;
      lastDir = dir;
      g_firstMoveDone = true;
      return;
   }

   // --- Pivot or Trend roll -----------------------------------
   if(dir != lastDir){
      HandlePivot(newRow, dir);     // 旧Trendを PROFIT/ALT に格上げ、新TrendPair生成
   }else{
      HandleTrendRoll(newRow, dir); // 旧Trendを決済して建て直し
   }

   // --- ALT 更新（rowごと1回） --------------------------------
   UpdateAltColumns(newRow, dir);

   lastRow = newRow;
   lastDir = dir;
}


//================= Sim/Reset =======================================
void SimulateMove(const int targetRow)
{
   int guard = 200;
   while(lastRow != targetRow && guard-- > 0){
      int step = (targetRow > lastRow) ? +1 : -1;
      int next = lastRow + step;
      StepRow(next, step);
   }
   if(guard<=0) Log("[ERR]","Guard hit in SimulateMove");
}

void SimulateHalfStep()
{
   Log("[HalfStep]","no‑op");
}

void ResetAll()
{
   // 配列初期化
   for(int i=0;i<ArraySize(colTab);i++){
      colTab[i].id         = 0;
      colTab[i].role       = ROLE_NONE;
      colTab[i].setId      = 0;
      colTab[i].anchorType = 0;
      colTab[i].lastSide   = SIDE_NONE;
      colTab[i].lastFlipRow= -999;
   }

   g_firstMoveDone = false;
   nextCol   = 3;
   lastRow   = 0;
   lastDir   = 0;
   StepCount = 0;

   // 既存ポジ全クローズ
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk = PositionGetTicket(i);
      if(tk==0 || !PositionSelectByTicket(tk)) continue;
      trade.PositionClose(tk);
   }

   basePrice = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   Log("⚙️","ResetAll done");

   // Row0 TrendPair
   Place(ORDER_TYPE_BUY , colBuy , 0, ROLE_TREND);
   Place(ORDER_TYPE_SELL, colSell, 0, ROLE_TREND);
}

#endif // __TRINITY_CORE_MQH__
