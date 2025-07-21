
//+------------------------------------------------------------------+
//| TrinityCore.mqh  –  ReplayTest 用ロジック共通ヘッダ (Turn‑0)     |
//+------------------------------------------------------------------+
#ifndef __TRINITY_CORE_MQH__
#define __TRINITY_CORE_MQH__

#include <Trade\Trade.mqh>
CTrade trade;

//─── パラメータ（固定値。EA ではないので input は使わない）──────
double  _lot       = 0.01;    // ロットサイズ
int     _magicBase = 900000;  // マジック基底

//─── グローバル状態 ───────────────────────────────────────────────
double basePrice = 0;  // Row=0 の価格（リセット時に上書き）
int    lastRow   = 0;  // 現在 Row
int    colBuy    = 1;  // Trend Buy 列
int    colSell   = 2;  // Trend Sell 列
int    StepCount = 0;   // ← 追加：Sim.mqh の extern に対する実体
int lastDir=0; 
int nextCol=3;

//─── ★ 追加 定義 ────────────────────────────────────────────────
enum ROLE { ROLE_NONE, ROLE_TREND, ROLE_PROFIT, ROLE_ALT };

struct ColInfo
{
   int  id;      // 列 ID
   ROLE role;    // 現在の役割
};
ColInfo colTab[64];            // シンプル固定長

//─── ユーティリティ ─────────────────────────────────────────────
void Log(string tag,string msg) { PrintFormat("%s  %s",tag,msg); }

//─── 建玉ヘルパー ────────────────────────────────────────────────
void Place(int orderType,int col,int row)
{
   MqlTradeRequest req;  MqlTradeResult res;
   ZeroMemory(req);  ZeroMemory(res);

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

   OrderSend(req,res);

   string side = (orderType==ORDER_TYPE_BUY) ? "Buy" : "Sell";
   Log("[NEW]",StringFormat("r=%d c=%d %s",row,col,side));
   // ★ 追加：列情報を更新
colTab[col].id   = col;
colTab[col].role = ROLE_TREND;
}


//─── Trend／ALT 列を丸ごと決済 ─────────────────────
void CloseColumn(int col)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != _magicBase + col) continue;

      trade.PositionClose(ticket);
      Log("[CLOSE]", StringFormat("c=%d ticket=%I64u", col, ticket));
   }
}

void StepRow(const int newRow,const int dir)
{
   // 行カウンタ
   StepCount++;

   // ── Pivot 判定 & デバッグ表示 ──────────────────────────
   bool pivot = (lastDir != 0 && dir != lastDir);
   Log("[DBG]", StringFormat("row=%d dir=%d lastDir=%d pivot=%s",
                             newRow, dir, lastDir, pivot ? "YES":"NO"));


// ===== Pivot が成立したらここに入る =====
if(pivot)
{
   Log("[PIVOT]", StringFormat("detected dir=%d at row=%d", dir, newRow));

   // ── ★勝ち負けを方向だけで決定★ ──
   int winnerCol = (dir == -1) ? colSell : colBuy; // 下向きPivotなら Sell 列が勝者
   int loserCol  = (winnerCol == colBuy) ? colSell : colBuy;

   colTab[winnerCol].role = ROLE_PROFIT;
   colTab[loserCol].role  = ROLE_ALT;

   Log("[ROLE]", StringFormat("c=%d → PROFIT", winnerCol)); // ← この2行がログを出す
   Log("[ROLE]", StringFormat("c=%d → ALT",    loserCol));

   // ── 新 TrendPair を列 3/4/… に建てる ──
   colBuy  = nextCol++;
   colSell = nextCol++;

   Place(ORDER_TYPE_BUY , colBuy , newRow);
   Place(ORDER_TYPE_SELL, colSell, newRow);

   lastRow = newRow;
   lastDir = dir;
   return;
}

   // ── 通常ロール ────────────────────────────────────
   CloseColumn(colBuy);
   CloseColumn(colSell);

   Place(ORDER_TYPE_BUY , colBuy , newRow);
   Place(ORDER_TYPE_SELL, colSell, newRow);

   lastRow = newRow;
   lastDir = dir;              // ← 通常ロールでも更新
   Log("[StepRow]", StringFormat("row=%d dir=%d Trend rolled", newRow, dir));
}


//─── SimulateMove：targetRow までループ呼び出し ─────────────────
void SimulateMove(const int targetRow)
{
   int step = (targetRow > lastRow) ? +1 : -1;
   while(lastRow != targetRow)
   {
      int next = lastRow + step;
      StepRow(next, step);
   }
}

//─── SimulateHalfStep：半ステップ判定用（現段階は空） ────────────
void SimulateHalfStep()
{
   Log("[HalfStep]","no‑op");
}

//─── ResetAll：全ポジション／状態リセット＋Row0 TrendPair 建て直し ─
void ResetAll()
{
          for(int i=0; i<ArraySize(colTab); i++)   // ★ 構造体を手動で初期化
   {
      colTab[i].id   = 0;
      colTab[i].role = ROLE_NONE;
   }
   // 既存ポジ一括クローズ
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      trade.PositionClose(ticket);
   }

   // 内部状態クリア
   basePrice = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   lastRow   = 0;
   Log("⚙️","ResetAll done");

   // Row0 TrendPair 再建
   Place(ORDER_TYPE_BUY , colBuy , 0);
   Place(ORDER_TYPE_SELL, colSell, 0);
}
#endif   // __TRINITY_CORE_MQH__
