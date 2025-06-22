//+------------------------------------------------------------------+
//|  TrinityTPS_Integrated_v1.mq5                                     |
//|  Unified Trinity + TPS Expert Advisor                             |
//|  Implements Trend‑Pair, Pivot Profit/Alt, Pre‑BS pair,            |
//|  Alternate ±0 break‑even, WeightedClose profit, Magic=base+col    |
//|  rev‑I1.0  (2025‑06‑21)                                           |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//───────────────────────── Inputs ───────────────────────────────
input string  InpSymbol       = "USDJPY";      // Trading symbol
input double  InpLot          = 0.01;           // Lot size per leg
input double  InpGridSize     = 0.50;           // Grid width (price units)
input double  InpTargetEquity = 5000.0;         // Equity target (account cur)
input uint    InpMagicBase    = 300000;         // Base magic number  ( +col )
input bool    InpDbgLog       = true;           // Verbose journal

//───────────────────────── Constants ────────────────────────────
#define MAX_COL    2048
#define MAX_SETS   512

// Column roles
enum ColRole { ROLE_NONE=0, ROLE_TREND, ROLE_PROFIT, ROLE_ALT, ROLE_BS };

//───────────────────────── Structures ───────────────────────────
struct ColState
{
   uint     id;              // column no.
   uint     setId;           // set id (4‑col group)
   ColRole  role;            // current role
   int      lastDir;         // +1 buy ‑1 sell (last entry)
   int      altRefRow;       // reference row for ALT parity
   int      altRefDir;       // initial dir for ALT parity
   uint     posCnt;          // live position count
};
struct ProfitInfo { bool active; uint col; int refRow; };

//───────────────────────── Globals ──────────────────────────────
static ColState g_cols[MAX_COL+2];
static int      g_altClosedRow[MAX_COL+2];

static double   gGrid          = 0.0;   // actual grid size
static double   gBasePrice     = 0.0;   // anchor bid at EA start / reset
static double   gRowAnchor     = 0.0;   // price representing current logical row band
static int      gLastRow       = 0;     // current logical row index
static int      gTrendSign     = 0;     // +1 up, ‑1 down, 0 none

// column indices
static uint     gTrendBCol     = 0;     // Trend‑Pair BUY
static uint     gTrendSCol     = 0;     // Trend‑Pair SELL
static uint     gBsBuyCol      = 0;     // Pre‑BS BUY column (bs1)
static uint     gBsSelCol      = 0;     // Pre‑BS SELL column (bs2)
static uint     gNextCol       = 1;     // next unused column number
static uint     gSetCounter    = 1;     // set id generator

static ProfitInfo g_profit = {false,0,0};
static double     gStartEquity = 0.0;

//───────────────────────── Utility (comment) ────────────────────
string MakeComment(int row,uint col) { return "r"+IntegerToString(row)+"C"+IntegerToString((int)col);}  
bool   ParseComment(const string &cm,int &row,int &col)
{
   int p = StringFind(cm,"C");
   if(p<2) return false;
   row = (int)StringToInteger(StringSubstr(cm,1,p-1));
   col = (int)StringToInteger(StringSubstr(cm,p+1));
   return true;
}

bool SelectPosByIndex(int idx)
{
   if(idx<0||idx>=PositionsTotal()) return false;
   ulong tk = PositionGetTicket(idx);
   if(tk==0) return false;
   if(!PositionSelectByTicket(tk))  return false;
   return true;
}

//───────────────────────── Order helpers ────────────────────────
bool HasPos(uint col,int row)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r,c; if(!ParseComment(PositionGetString(POSITION_COMMENT),r,c)) continue;
      if(r==row && (uint)c==col) return true;
   }
   return false;
}

bool Place(ENUM_ORDER_TYPE type,uint col,int row,bool isAltFirst=false)
{
   if(col==0||col>MAX_COL) return false;
   if(HasPos(col,row))     return false;

   // set magic per column
   trade.SetExpertMagicNumber(InpMagicBase + col);

   double price = (type==ORDER_TYPE_BUY)?SymbolInfoDouble(InpSymbol,SYMBOL_ASK)
                                       :SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   bool ok = (type==ORDER_TYPE_BUY)? trade.Buy (InpLot,InpSymbol,price,0,0,MakeComment(row,col))
                                   : trade.Sell(InpLot,InpSymbol,price,0,0,MakeComment(row,col));
   if(ok)
   {
      g_cols[col].posCnt++;
      g_cols[col].lastDir = (type==ORDER_TYPE_BUY?+1:-1);
      if(isAltFirst)
      {
         g_cols[col].altRefRow = row;
         g_cols[col].altRefDir = -g_cols[col].lastDir;
      }
      if(InpDbgLog)
         PrintFormat("[NEW] r=%d c=%u role=%d dir=%s posCnt=%u",
                     row,col,g_cols[col].role,(type==ORDER_TYPE_BUY?"Buy":"Sell"),g_cols[col].posCnt);
   }
   return ok;
}

// convenient wrappers
void PlaceBuy(uint col,int row,bool altFirst=false)  { Place(ORDER_TYPE_BUY ,col,row,altFirst); }
void PlaceSell(uint col,int row,bool altFirst=false) { Place(ORDER_TYPE_SELL,col,row,altFirst); }

//───────────────────────── Trend‑Pair & BS helpers ──────────────
void CreateTrendPair(int row)
{
   uint b=gNextCol++, s=gNextCol++;
   if(s>MAX_COL) { Print("[EA] column overflow"); return; }
   g_cols[b].id=b; g_cols[b].setId=gSetCounter; g_cols[b].role=ROLE_TREND;
   g_cols[s].id=s; g_cols[s].setId=gSetCounter; g_cols[s].role=ROLE_TREND;
   gTrendBCol=b; gTrendSCol=s;
   PlaceBuy (b,row);
   PlaceSell(s,row);
   if(InpDbgLog) PrintFormat("[TP] TrendPair created rows=%d B=%u S=%u",row,b,s);
}

void CreateBsPair(int row)
{
   uint b=gNextCol++, s=gNextCol++;
   if(s>MAX_COL) { Print("[EA] column overflow"); return; }
   g_cols[b].id=b; g_cols[b].setId=gSetCounter; g_cols[b].role=ROLE_BS;
   g_cols[s].id=s; g_cols[s].setId=gSetCounter; g_cols[s].role=ROLE_BS;
   gBsBuyCol=b; gBsSelCol=s;
   // Always simultaneous Buy & Sell
   PlaceBuy (b,row);
   PlaceSell(s,row);
   if(InpDbgLog) PrintFormat("[BS] Pre‑BS pair created row=%d bsB=%u bsS=%u",row,b,s);
}

void FixTrendPair(int dir,int curRow)
{
   // Convert current Trend‑Pair into Profit & Alt roles at pivot
   if(gTrendBCol==0||gTrendSCol==0) return;
   if(dir>0)
   {
      g_cols[gTrendBCol].role = ROLE_PROFIT; // upward pivot: Buy side lowest becomes Profit
      g_cols[gTrendSCol].role = ROLE_ALT;    // Sell side becomes Alt
      g_cols[gTrendSCol].altRefRow = curRow;
      g_cols[gTrendSCol].altRefDir = -g_cols[gTrendSCol].lastDir;
   }
   else
   {
      g_cols[gTrendSCol].role = ROLE_PROFIT; // downward pivot: Sell side Profit
      g_cols[gTrendBCol].role = ROLE_ALT;    // Buy side Alt
      g_cols[gTrendBCol].altRefRow = curRow;
      g_cols[gTrendBCol].altRefDir = -g_cols[gTrendBCol].lastDir;
   }
   // store profit column for later WeightedClose target
   g_profit.active = true;
   g_profit.col    = (dir>0)? gTrendBCol : gTrendSCol;
   g_profit.refRow = curRow;

   gTrendBCol=gTrendSCol=0; // cleared; a new Trend‑Pair will be created
}

// Safe roll Trend‑Pair when no pivot (continue trend): close previous‑row entries and reopen in new row
void SafeRollTrendPair(int curRow,int dir)
{
   if(gTrendBCol==0||gTrendSCol==0) return;
   int prevRow=curRow-dir;
   bool closedB=false,closedS=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r,c; if(!ParseComment(PositionGetString(POSITION_COMMENT),r,c)) continue;
      ulong tk=PositionGetTicket(i);
      if(r==prevRow && (uint)c==gTrendBCol && trade.PositionClose(tk))
      { closedB=true; g_cols[c].posCnt--; }
      if(r==prevRow && (uint)c==gTrendSCol && trade.PositionClose(tk))
      { closedS=true; g_cols[c].posCnt--; }
   }
   if(!(closedB && closedS)) return;  // unable to close both

   // reopen in current row keeping directions aligned with trend
   Place((dir>0?ORDER_TYPE_BUY :ORDER_TYPE_SELL),gTrendBCol,curRow);
   Place((dir>0?ORDER_TYPE_SELL:ORDER_TYPE_BUY ),gTrendSCol,curRow);
   if(InpDbgLog) PrintFormat("[TP] Safe rolled to row %d",curRow);
}

//───────────────────────── Alternate helpers ────────────────────
ENUM_ORDER_TYPE AltDir(uint col,int curRow)
{
   // parity‑based alternating direction
   int diff=curRow-g_cols[col].altRefRow;
   int dir = ((diff & 1)==0)? g_cols[col].altRefDir : -g_cols[col].altRefDir;
   return (dir==+1)? ORDER_TYPE_BUY:ORDER_TYPE_SELL;
}

void UpdateAlternateCols(int curRow)
{
   for(uint col=1; col<gNextCol; col++)
      if(g_cols[col].role==ROLE_ALT && g_altClosedRow[col]!=curRow)
         Place(AltDir(col,curRow),col,curRow);
}

//───────────────────────── Break‑even for ALT ───────────────────
void CheckAltBE(int curRow)
{
   double bid = SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   for(uint col=1; col<gNextCol; col++)
   {
      if(g_cols[col].role!=ROLE_ALT || g_cols[col].posCnt<1) continue;

      double sumDir=0, sumDirOpen=0;
      ulong  tks[256]; int n=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!SelectPosByIndex(i)) continue;
         int r,c; if(!ParseComment(PositionGetString(POSITION_COMMENT),r,c)) continue;
         if((uint)c!=col) continue;
         int dir = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)? +1:-1;
         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         sumDir     += dir;
         sumDirOpen += dir*op;
         if(n<256) tks[n++] = PositionGetTicket(i);
      }
      if(n==0 || MathAbs(sumDir)<1e-9) continue;
      double be = sumDirOpen/sumDir;      // break‑even price
      bool hit  = (sumDir>0)? (bid<=be+1e-9):(bid>=be-1e-9);
      if(!hit) continue;

      uint closed=0;
      for(int k=0;k<n;k++) if(trade.PositionClose(tks[k])) { closed++; g_cols[col].posCnt--; }
      g_altClosedRow[col]=curRow;
      if(g_cols[col].posCnt==0) g_cols[col].role=ROLE_NONE;
      if(InpDbgLog) PrintFormat("[ALT] BE close col=%u BE=%.5f bid=%.5f closed=%u",col,be,bid,closed);
   }
}

//───────────────────────── WeightedClose for Profit ─────────────
inline double WeightedPrice()
{
   // 現在バーの High/Low/Close を取得
   double h = iHigh(InpSymbol, PERIOD_CURRENT, 0);
   double l = iLow (InpSymbol, PERIOD_CURRENT, 0);
   double c = iClose(InpSymbol, PERIOD_CURRENT, 0);
   return (h + l + 2.0*c) * 0.25;
}

void CheckProfitWeightedClose()
{
   if(!g_profit.active) return;
   double wp = WeightedPrice();
   double tgt = gBasePrice + (g_profit.refRow - 1) * gGrid; // 1 grid below refRow
   if(wp > tgt + 1e-9) return;     // target not yet reached

   uint closed=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r,c; if(!ParseComment(PositionGetString(POSITION_COMMENT),r,c)) continue;
      if((uint)c==g_profit.col && trade.PositionClose(PositionGetTicket(i)))
      { closed++; g_cols[c].posCnt--; }
   }
   if(InpDbgLog) PrintFormat("[PROFIT] WeightedClose col=%u tgt=%.5f wp=%.5f closed=%u",g_profit.col,tgt,wp,closed);
   g_profit.active=false;
}

//───────────────────────── Equity target ──────────────────────
void CheckTargetEquity()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity - gStartEquity < InpTargetEquity - 1e-9) return;
   // flat everything
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(SelectPosByIndex(i)) trade.PositionClose(PositionGetTicket(i));
   if(InpDbgLog) PrintFormat("[EA] Target %.2f reached – reset",InpTargetEquity);
   // reset internal state (simple)
   // Relaunch via OnInit logic
   EventKillTimer();
   OnInit();
}

//───────────────────────── Row stepping ─────────────────────────
void StepRow(int newRow,int dir)
{
   bool pivot = (gTrendSign!=0 && dir!=gTrendSign);
   if(InpDbgLog) PrintFormat("[STEP] newRow=%d dir=%d pivot=%s",newRow,dir,pivot?"YES":"NO");

   if(pivot || gTrendSign==0)
   {
      // pivot: finalize current trend pair, create BS pair, then new trend pair
      FixTrendPair(dir,newRow);
      CreateBsPair(newRow);          //先乗せ BS
      CreateTrendPair(newRow);       // new Trend‑Pair in same row
   }
   else
   {
      SafeRollTrendPair(newRow,dir);
   }

   UpdateAlternateCols(newRow);
   CheckAltBE(newRow);          // break‑even closures

   gLastRow   = newRow;
   gTrendSign = dir;
   gRowAnchor = gBasePrice + newRow*gGrid;
}

//───────────────────────── Init / Tick ─────────────────────────
void ResetState()
{
    // ─── 配列を手動で初期化 ───
   for(uint i=0;i<=MAX_COL+1;i++)
   {
      g_cols[i].id         = 0;
      g_cols[i].setId      = 0;
      g_cols[i].role       = ROLE_NONE;
      g_cols[i].lastDir    = 0;
      g_cols[i].altRefRow  = 0;
      g_cols[i].altRefDir  = 0;
      g_cols[i].posCnt     = 0;
      g_altClosedRow[i]    = -9999;
   }
   gGrid          = InpGridSize;
   gBasePrice     = gRowAnchor = SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   gLastRow       = 0;
   gTrendSign     = 0;
   gTrendBCol     = gTrendSCol = 0;
   gBsBuyCol      = gBsSelCol  = 0;
   gNextCol       = 1;
   gSetCounter++;
   if(gSetCounter>MAX_SETS) gSetCounter=1;

   // first Trend‑Pair at row 0
   CreateTrendPair(0);
   gStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicBase); // default; per order we overwrite
   ResetState();
   if(InpDbgLog)
      PrintFormat("[EA] Init grid=%.5f equityTarget=%.2f basePrice=%.5f",gGrid,InpTargetEquity,gBasePrice);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   double bid=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   while(bid >= gRowAnchor + gGrid - 1e-9) StepRow(++gLastRow,+1);
   while(bid <= gRowAnchor - gGrid + 1e-9) StepRow(--gLastRow,-1);

   CheckProfitWeightedClose();
   CheckTargetEquity();
}
//+------------------------------------------------------------------+
