//+------------------------------------------------------------------+
//|  Trinity.mq5  –  Generic Grid‑TPS Entry Core                    |
//|  roll‑backed "stable" snapshot  (around 2024‑05‑27)             |
//|  reconstructed 2025‑07‑06                                        |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//────────────────────────── Inputs ───────────────────────────────
input string  InpSymbol       = "USDJPY";   // trading symbol
input double  InpLot          = 0.01;        // lot size
input double  InpGridSize     = 0.50;        // grid width (JPY)
input double  InpTargetEquity = 5000.0;      // target profit (account currency)
input uint    InpMagic        = 20250607;    // magic number
input bool    InpDbgLog       = true;        // verbose logging

//────────────────────────── Types / Globals ──────────────────────
enum ColRole { ROLE_PENDING, ROLE_PROFIT, ROLE_ALT, ROLE_TREND };

struct ColState
{
   uint    id;
   ColRole role;
   int     lastDir;     // +1 Buy / -1 Sell
   int     altRefRow;   // reference row for ALT parity
   int     altRefDir;   // first direction (+1/-1)
   uint    posCnt;      // live positions in column
};

#define MAX_COL 2048
static ColState colTab[MAX_COL + 2];
static int      altClosedRow[MAX_COL + 2];

static double GridSize;
static double basePrice   = 0.0;
static double rowAnchor   = 0.0;
static int    lastRow     = 0;
static int    trendSign   = 0;      // +1 / -1 (0 = unknown)
static uint   nextCol     = 1;
static uint   trendBCol   = 0, trendSCol = 0;

// Pivot‑ALT bookkeeping
static uint  altBCol = 0;
static uint  altSCol = 0;
static bool  altFirst = false;

struct ProfitInfo { bool active; uint col; int refRow; };
static ProfitInfo profit;   // declared once only
static double startEquity = 0.0;

//────────────────── Forward-declarations ──────────────────
void UpdateAlternateCols(int curRow,int dir,bool seed);

//──────────────────────── Utility ────────────────────────────────
void ClearColTab(){ for(int i=0;i<MAX_COL+2;i++) ZeroMemory(colTab[i]); }

string Cmnt(int r,uint c){ return "r"+IntegerToString(r)+"C"+IntegerToString(c); }

bool Parse(const string &cm,int &r,uint &c)
{
   long p=StringFind(cm,"C"); if(p<1) return false;
   r=(int)StringToInteger(StringSubstr(cm,1,(int)p-1));
   c=(uint)StringToInteger(StringSubstr(cm,p+1));
   return true;
}

bool SelectPosByIndex(int idx)
{
   ulong tk=PositionGetTicket(idx);
   return (tk!=0 && PositionSelectByTicket(tk) &&
           PositionGetInteger(POSITION_MAGIC)==InpMagic);
}

bool HasPos(uint col,int row)
{
   if(altClosedRow[col]==row) return true;   // BE closed row guard
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r; uint c; if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
      if(r==row && c==col) return true;
   }
   return false;
}

//──────────────── Market-order helper ──────────────────────────
// t   : ORDER_TYPE_BUY / ORDER_TYPE_SELL
// col : 列番号（1-based）
// row : 行番号（± …）
// isAltFirst : Pivot 直後「交互エントリー」1 本目かどうか
bool Place(ENUM_ORDER_TYPE t,
           uint             col,
           int              row,
           bool             isAltFirst = false)
{
   //―――― ① Duplicate-guard ――――
   //   ・同じセルに既存ポジがある
   //   ・WeightedClose 直後の “同じ Row” への再建て
   if(HasPos(col,row)           ||
      altClosedRow[col] == row)      // ← 加重平均決済直後は 1 行スキップ
      return false;

   //―――― ② 発注価格を決定（BID/ASK をそのまま使用）――――
   double price = (t == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(InpSymbol,SYMBOL_ASK)
                  : SymbolInfoDouble(InpSymbol,SYMBOL_BID);

   //―――― ③ 発注実行 ――――
   bool ok = (t == ORDER_TYPE_BUY)
             ? trade.Buy (InpLot,InpSymbol,price,0,0,Cmnt(row,col))
             : trade.Sell(InpLot,InpSymbol,price,0,0,Cmnt(row,col));

   if(!ok)                                     // 失敗したらそのまま返却
      return false;

   //―――― ④ 内部カウンタ / ALT 情報を更新 ――――
   colTab[col].posCnt++;
   colTab[col].lastDir = (t == ORDER_TYPE_BUY ? +1 : -1);

   if(isAltFirst)                              // “交互エントリー” 初回だけ記録
   {
      colTab[col].altRefRow = row;
      colTab[col].altRefDir = colTab[col].lastDir;
   }

   //―――― ⑤ デバッグログ ――――
   if(InpDbgLog)
      PrintFormat("[NEW] r=%d c=%u role=%d dir=%s ALTfirst=%d posCnt=%u",
                  row, col, colTab[col].role,
                  (t==ORDER_TYPE_BUY ? "Buy" : "Sell"),
                  isAltFirst, colTab[col].posCnt);

   return true;
}

//──────────────── Trend helpers ─────────────────────────────────
void CreateTrendPair(int row)
{
   uint b=nextCol++, s=nextCol++;
   colTab[b].id=b; colTab[b].role=ROLE_TREND;
   colTab[s].id=s; colTab[s].role=ROLE_TREND;
   trendBCol=b; trendSCol=s;
   Place(ORDER_TYPE_BUY ,b,row);
   Place(ORDER_TYPE_SELL,s,row);
}
/*──────────────── FixTrendPair ─────────────────────────────*/
// ① altRefDir を必ず “その行で実際に出した方向” で保存
void FixTrendPair(int dir,int curRow)
{
   if(trendBCol==0 || trendSCol==0) return;

   uint profCol, altCol;
   if(dir>0){                     // 上昇 Pivot
      profCol = trendBCol;        // Buy が最高値 → PROFIT
      altCol  = trendSCol;        // Sell が最安値 → ALT
   }else{                         // 下降 Pivot
      profCol = trendSCol;        // Sell が最高値 → PROFIT
      altCol  = trendBCol;        // Buy が最安値 → ALT
   }

   colTab[profCol].role = ROLE_PROFIT;

   colTab[altCol].role      = ROLE_ALT;
   colTab[altCol].altRefRow = curRow;
   colTab[altCol].altRefDir = colTab[altCol].lastDir;   // ← ★反転させない

   profit.active = true;  profit.col = profCol;  profit.refRow = curRow;

   // ALT-pair の基準を更新
   altBCol = altCol;
   altSCol = profCol;   // PROFIT 列は交互には使わないが参照用に保持

   trendBCol = trendSCol = 0;     // 旧 TrendPair 役目終了
}

//──────────────── SafeRollTrendPair ─────────────────────────────────
void SafeRollTrendPair(int curRow,int dir)
{
   int prevRow=curRow-dir;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r; uint c; if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
      if(r==prevRow && (c==trendBCol||c==trendSCol))
      {
         ulong tk=PositionGetTicket(i);
         if(trade.PositionClose(tk)) colTab[c].posCnt--;
      }
   }
   Place(ORDER_TYPE_BUY ,trendBCol,curRow);
   Place(ORDER_TYPE_SELL,trendSCol,curRow);
}

ENUM_ORDER_TYPE AltDir(uint col,int curRow)
{
   int diff=curRow-colTab[col].altRefRow;
   bool even=((diff&1)==0);
   int dir=even?colTab[col].altRefDir:-colTab[col].altRefDir;
   return (dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
}

//──────────────── Profit / BE / Target checks ──────────────────
void CheckProfitClose()
{
   if(!profit.active) return;
   double tgt = basePrice + (profit.refRow-1)*GridSize;
   if(SymbolInfoDouble(InpSymbol,SYMBOL_BID) > tgt + 1e-9) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r; uint c; if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
      if(c==profit.col && trade.PositionClose(PositionGetTicket(i))) colTab[c].posCnt--;
   }
   profit.active=false;
}

void CheckWeightedClose()
{
   for(uint c=1;c<nextCol;c++)
   {
      if(colTab[c].role!=ROLE_ALT) continue;
      double sum=0.0; ulong tks[128]; int n=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!SelectPosByIndex(i)) continue;
         int r; uint col; if(!Parse(PositionGetString(POSITION_COMMENT),r,col)||col!=c) continue;
         tks[n++]=PositionGetTicket(i);
         sum+=PositionGetDouble(POSITION_PROFIT);
      }
      if(n && sum>=0.0 && n>=3 && (n&1))
      {
         for(int k=0;k<n;k++) if(trade.PositionClose(tks[k])) colTab[c].posCnt--;
         altClosedRow[c]=lastRow;
         if(colTab[c].posCnt==0) colTab[c].role=ROLE_PENDING;
      }
   }
}

void CheckTargetEquity()
{
   double cur=AccountInfoDouble(ACCOUNT_EQUITY);
   if(cur-startEquity < InpTargetEquity - 1e-9) return;
   for(int i=PositionsTotal()-1;i>=0;i--) if(SelectPosByIndex(i)) trade.PositionClose(PositionGetTicket(i));
   if(InpDbgLog) Print("Target equity reached → reset");
   ClearColTab(); ArrayInitialize(altClosedRow,-9999);
   nextCol=1; trendBCol=trendSCol=0; lastRow=0; trendSign=0;
   basePrice=rowAnchor=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   colTab[1].id=1; colTab[1].role=ROLE_TREND; colTab[2].id=2; colTab[2].role=ROLE_TREND;
   trendBCol=1; trendSCol=2; nextCol=3;
   Place(ORDER_TYPE_BUY ,trendBCol,0);
   Place(ORDER_TYPE_SELL,trendSCol,0);
   startEquity=cur;
}
/*──────────────── UpdateAlternateCols ─────────────────────────
 * すべての ROLE_ALT 列を対象に交互エントリー。
 *   – “新しく ALT になった列” だけ isFirst=true で parity を初期化
 *   – 既存 ALT 列は AltDir() で自動判定
 */
void UpdateAlternateCols(int curRow,int dir,bool /*seed*/)
{
   for(uint c=1; c<nextCol; ++c)
   {
      if(colTab[c].role != ROLE_ALT) continue;

      const bool isFirst = (colTab[c].altRefRow == curRow);
      ENUM_ORDER_TYPE ot;

      if(isFirst){
         // Pivot 直後 1 本目: 上昇 Pivot→Buy, 下降 Pivot→Sell
         ot = (dir>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      }else{
         // 交互張り継続
         ot = AltDir(c,curRow);
      }

      Place(ot, c, curRow, isFirst);  // isFirst=true で altRefRow/Dir を固定
   }
}

//──────────────── StepRow ───────────────────────────────────
void StepRow(int newRow,int dir)
{
   bool firstMove = (trendSign == 0);          // 初回か？
   bool pivot     = (!firstMove && dir != trendSign);

   if(InpDbgLog)
      PrintFormat("StepRow newRow=%d dir=%d firstMove=%s pivot=%s",
                  newRow, dir,
                  firstMove ? "YES" : "NO",
                  pivot     ? "YES" : "NO");

   if(firstMove || pivot)
   {
      FixTrendPair(dir, newRow);               // 旧 Trend → Profit / ALT
      CreateTrendPair(newRow);                 // 新 Trend ペア
      UpdateAlternateCols(newRow, dir, true);  // ★ ALT 初回 seed=true
   }
   else
   {
      SafeRollTrendPair(newRow, dir);          // 巡行ロール
      UpdateAlternateCols(newRow, dir, false); // ★ seed=false
   }

   // PENDING → TREND 昇格
   for(uint c = 1; c < nextCol; c++)
      if(colTab[c].role == ROLE_PENDING &&
         colTab[c].posCnt == 0         &&
         altClosedRow[c] != lastRow)
            colTab[c].role = ROLE_TREND;

   lastRow   = newRow;
   trendSign = dir;
}

//───────────────────────────────────────────────────────────────
int OnInit()
{
   GridSize=InpGridSize;
   basePrice=rowAnchor=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
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

void OnTick()
{
   double bid=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   if(bid>=rowAnchor+GridSize-1e-9){ StepRow(lastRow+1,+1); rowAnchor+=GridSize; }
   else if(bid<=rowAnchor-GridSize+1e-9){ StepRow(lastRow-1,-1); rowAnchor-=GridSize; }
   CheckProfitClose();
   CheckWeightedClose();
   CheckTargetEquity();
}

//+------------------------------------------------------------------+
