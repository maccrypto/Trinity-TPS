//+------------------------------------------------------------------+
//| Trinity‑TPS Expert Advisor                                      |
//| rev 0.2.0  (2025‑06‑08)                                         |
//| Trend‑Pair  +  Set  logic  –  FULL SOURCE                       |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
CTrade trade;

//──────────────────────── inputs ───────────────────────────────
input string  InpSymbol       = "USDJPY";     // Trading symbol
input double  InpLot          = 0.01;          // Lot size per leg
input double  InpGridSize     = 0.50;          // Grid width (price units)
input double  InpTargetEquity = 5000.0;        // Profit target (account cur)
input uint    InpMagic        = 20250607;      // Magic number
input bool    InpDbgLog       = true;          // Verbose journal

//──────────────────────── constants ─────────────────────────────
#define MAX_COL    2048
#define MAX_SETS    512

//──────────────────────── types ────────────────────────────────
enum ColRole{ ROLE_NONE=0, ROLE_PENDING, ROLE_PROFIT, ROLE_ALT, ROLE_TREND };
struct ColState
{
   uint     id;
   uint     setId;
   ColRole  role;
   int      lastDir;      // +1 buy ‑1 sell
   int      altRefRow;
   int      altRefDir;
   uint     posCnt;
};
struct ProfitInfo{ bool active; uint col; int refRow; };

//──────────────────────── globals ───────────────────────────────
static ColState g_cols[MAX_COL+2];
static int      g_altClosedRow[MAX_COL+2];

static double   gGrid          = 0.0;   // actual grid size
static double   gBasePrice     = 0.0;   // initial anchor bid
static double   gRowAnchor     = 0.0;   // anchor for current row band
static int      gLastRow       = 0;     // current logical row
static int      gTrendSign     = 0;     // +1 up  ‑1 down  0 none

static uint     gNextCol       = 1;     // next unused column number
static uint     gTrendBCol     = 0;     // current trend‑pair Buy col
static uint     gTrendSCol     = 0;     // current trend‑pair Sell col
static uint     gSetCounter    = 1;     // set id generator

static ProfitInfo g_profit = {false,0,0};
static double     gStartEquity = 0.0;

//────────────────────── utility (comment) ───────────────────────
string MakeComment(int row,uint col){ return "r"+IntegerToString(row)+"C"+IntegerToString((int)col);}  
bool   ParseComment(const string &cm,int &row,int &col)
{
   int p = StringFind(cm,"C");
   if(p<2) return false;
   row = (int)StringToInteger(StringSubstr(cm,1,p-1));
   col = (int)StringToInteger(StringSubstr(cm,p+1));
   return true;
}

//────────────────────── utility (positions) ─────────────────────
bool SelectPosByIndex(int idx)
{
   if(idx<0||idx>=PositionsTotal()) return false;
   ulong tk = PositionGetTicket(idx);
   if(tk==0) return false;
   if(!PositionSelectByTicket(tk))  return false;
   if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) return false;
   return true;
}

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

bool Place(ENUM_ORDER_TYPE type,uint col,int row,bool altFirst=false)
{
   if(col==0||col>MAX_COL) return false;
   if(HasPos(col,row))     return false;
   double price = (type==ORDER_TYPE_BUY)?SymbolInfoDouble(InpSymbol,SYMBOL_ASK)
                                       :SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   bool ok = (type==ORDER_TYPE_BUY)? trade.Buy (InpLot,InpSymbol,price,0,0,MakeComment(row,col))
                                   : trade.Sell(InpLot,InpSymbol,price,0,0,MakeComment(row,col));
   if(ok)
   {
      g_cols[col].posCnt++;
      g_cols[col].lastDir = (type==ORDER_TYPE_BUY?+1:-1);
      if(altFirst)
      {
         g_cols[col].altRefRow = row;
         g_cols[col].altRefDir = -g_cols[col].lastDir;
      }
      if(InpDbgLog)
         PrintFormat("[TPS] NEW r=%d c=%u set=%u role=%d dir=%s posCnt=%u",
                      row,col,g_cols[col].setId,g_cols[col].role,
                      (type==ORDER_TYPE_BUY?"Buy":"Sell"),g_cols[col].posCnt);
   }
   return ok;
}

// forward declarations
void CreateTrendPair(int row,uint setId);
void FixTrendPair(int dir,int curRow);
void SafeRollTrendPair(int curRow,int dir);
void ResetEngineState();
void StepRow(int newRow,int dir);

//────────────────── trend‑pair management ──────────────────────
void CreateTrendPair(int row,uint setId)
{
   uint b=gNextCol++;
   uint s=gNextCol++;
   if(s>MAX_COL) { Print("[TPS] column overflow"); return; }
   g_cols[b].id=b; g_cols[b].setId=setId; g_cols[b].role=ROLE_TREND;
   g_cols[s].id=s; g_cols[s].setId=setId; g_cols[s].role=ROLE_TREND;
   gTrendBCol=b; gTrendSCol=s;
   Place(ORDER_TYPE_BUY ,b,row);
   Place(ORDER_TYPE_SELL,s,row);
}

void FixTrendPair(int dir,int curRow)
{
   if(gTrendBCol==0||gTrendSCol==0) return;
   if(dir>0) // up‑trend pivot
   {
      g_cols[gTrendBCol].role=ROLE_PROFIT;
      g_cols[gTrendSCol].role=ROLE_ALT;
      g_cols[gTrendSCol].altRefRow=curRow;
      g_cols[gTrendSCol].altRefDir=-g_cols[gTrendSCol].lastDir;
      g_profit.active=false;
   }
   else       // down‑trend pivot
   {
      g_cols[gTrendSCol].role=ROLE_PROFIT;
      g_cols[gTrendBCol].role=ROLE_ALT;
      g_cols[gTrendBCol].altRefRow=curRow;
      g_cols[gTrendBCol].altRefDir=-g_cols[gTrendBCol].lastDir;
      g_profit.active=true; g_profit.col=gTrendSCol; g_profit.refRow=curRow;
   }
   gTrendBCol=gTrendSCol=0;
}

void SafeRollTrendPair(int curRow,int dir)
{
   int prevRow=curRow-dir;  // row where current trend‑pair was opened
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
   if(!(closedB&&closedS)) return;   // could not close both legs
   Place((dir>0?ORDER_TYPE_BUY :ORDER_TYPE_SELL),gTrendBCol,curRow);
   Place((dir>0?ORDER_TYPE_SELL:ORDER_TYPE_BUY ),gTrendSCol,curRow);
   if(InpDbgLog) PrintFormat("[TPS] SafeRoll → row %d",curRow);
}

//────────────────── alternate helpers ──────────────────────────
ENUM_ORDER_TYPE AltDir(uint col,int curRow)
{
   int diff=curRow-g_cols[col].altRefRow;
   int dir =((diff&1)==0)? g_cols[col].altRefDir : -g_cols[col].altRefDir;
   return (dir==+1)? ORDER_TYPE_BUY:ORDER_TYPE_SELL;
}
void UpdateAlternateCols(int curRow)
{
   for(uint col=1; col<gNextCol; col++)
      if(g_cols[col].role==ROLE_ALT && g_altClosedRow[col]!=curRow)
         Place(AltDir(col,curRow),col,curRow);
}

//────────────────── weighted close (set wide) ─────────────────
void CheckWeightedClose()
{
   double bid=SymbolInfoDouble(InpSymbol,SYMBOL_BID);

   struct Agg{ double sumDir; double sumDirOpen; ulong tks[256]; int n; int minBuyRow; };
   Agg agg[MAX_SETS+1];
   for(int s=1;s<=MAX_SETS;s++){ agg[s].sumDir=0; agg[s].sumDirOpen=0; agg[s].n=0; agg[s].minBuyRow=INT_MAX; }

   // aggregate by set
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int row,col; if(!ParseComment(PositionGetString(POSITION_COMMENT),row,col)) continue;
      uint set=g_cols[col].setId; if(set==0||set>MAX_SETS) continue;
      int dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)? +1:-1;
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      agg[set].sumDir     += dir;
      agg[set].sumDirOpen += dir*op;
      if(dir==+1 && row<agg[set].minBuyRow) agg[set].minBuyRow=row; // track lowest buy row
      int n=agg[set].n; if(n<256) agg[set].tks[n]=PositionGetTicket(i);
      agg[set].n++;
   }

   // evaluate each set
   for(int s=1;s<gSetCounter && s<=MAX_SETS; s++)
   {
      if(agg[s].n==0) continue;
      double div=agg[s].sumDir;
      if(MathAbs(div)<1e-9) continue;               // should not happen
      double be=agg[s].sumDirOpen/div;              // break‑even price of set
      bool hit=(div>0)? (bid<=be+1e-9) : (bid>=be-1e-9);
      if(!hit) continue;

      // close everything except the lowest LONG (minBuyRow) in this set
      uint closed=0;
      for(int i=0;i<agg[s].n;i++)
      {
         ulong tk=agg[s].tks[i]; if(!PositionSelectByTicket(tk)) continue;
         int row,col; if(!ParseComment(PositionGetString(POSITION_COMMENT),row,col)) continue;
         if(row==agg[s].minBuyRow && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) continue; // keep lowest B
         if(trade.PositionClose(tk)) { closed++; g_cols[col].posCnt--; }
      }
      if(closed>0 && InpDbgLog)
         PrintFormat("[TPS] WeightedClose set=%u BE=%.5f bid=%.5f closed=%u",s,be,bid,closed);

      // mark alt closed to inhibit immediate re‑entry
      for(uint col=1; col<gNextCol; col++)
         if(g_cols[col].setId==s) g_altClosedRow[col]=gLastRow;
   }
}

//────────────────── profit close (trend pivot) ────────────────
void CheckProfitClose()
{
   if(!g_profit.active) return;
   double tgt=gBasePrice+(g_profit.refRow-1)*gGrid;
   double bid=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   if(bid>tgt+1e-9) return;
   uint closed=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int row,col; if(!ParseComment(PositionGetString(POSITION_COMMENT),row,col)) continue;
      if(col==g_profit.col && trade.PositionClose(PositionGetTicket(i))) { closed++; g_cols[col].posCnt--; }
   }
   if(InpDbgLog) PrintFormat("[TPS] ProfitClose col=%u closed=%u",g_profit.col,closed);
   g_profit.active=false;
   Place(ORDER_TYPE_SELL,1,g_profit.refRow-1,true);
}

//────────────────── equity target check ───────────────────────
void CheckTargetEquity()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity-gStartEquity<InpTargetEquity-1e-9) return;
   // goal reached – flat everything
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(SelectPosByIndex(i)) trade.PositionClose(PositionGetTicket(i));
   if(InpDbgLog) PrintFormat("[TPS] Target %.2f reached – reset.",InpTargetEquity);
   ResetEngineState();
}

//────────────────── engine reset helper ───────────────────────
void ResetEngineState()
{
   ZeroMemory(g_cols);
   for(int i=0;i<=MAX_COL;i++) g_altClosedRow[i]=-9999;
   gNextCol=1; gTrendBCol=gTrendSCol=0; gLastRow=0; gTrendSign=0;
   gBasePrice=gRowAnchor=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   gSetCounter++;
   // start new first set
   uint set=gSetCounter;
   g_cols[1].id=1; g_cols[1].setId=set; g_cols[1].role=ROLE_TREND;
   g_cols[2].id=2; g_cols[2].setId=set; g_cols[2].role=ROLE_TREND;
   gTrendBCol=1; gTrendSCol=2; gNextCol=3;
   Place(ORDER_TYPE_BUY ,gTrendBCol,0);
   Place(ORDER_TYPE_SELL,gTrendSCol,0);
   gStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
}

//────────────────── row stepping ───────────────────────────────
void StepRow(int newRow,int dir)
{
   bool pivot=(gTrendSign!=0 && dir!=gTrendSign);
   if(InpDbgLog) PrintFormat("[TPS] StepRow new=%d dir=%d pivot=%s",newRow,dir,pivot?"YES":"NO");
   if(pivot||gTrendSign==0) { FixTrendPair(dir,newRow); CreateTrendPair(newRow,gSetCounter); }
   else                     { SafeRollTrendPair(newRow,dir); }
   for(uint col=1; col<gNextCol; col++)
      if(g_cols[col].role==ROLE_PENDING && g_cols[col].posCnt==0)
         g_cols[col].role=ROLE_TREND;
   UpdateAlternateCols(newRow);
   gLastRow=newRow; gTrendSign=dir; gRowAnchor=gBasePrice+newRow*gGrid;
}

//────────────────── OnInit / OnTick ────────────────────────────
int OnInit()
{
   gGrid      = InpGridSize;
   gBasePrice = gRowAnchor = SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   gStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   ZeroMemory(g_cols);
   for(int i=0;i<=MAX_COL;i++) g_altClosedRow[i]=-9999;
   trade.SetExpertMagicNumber(InpMagic);
   // first set
   gSetCounter=1;
   g_cols[1].id=1; g_cols[1].setId=1; g_cols[1].role=ROLE_TREND;
   g_cols[2].id=2; g_cols[2].setId=1; g_cols[2].role=ROLE_TREND;
   gTrendBCol=1; gTrendSCol=2; gNextCol=3;
   Place(ORDER_TYPE_BUY ,gTrendBCol,0);
   Place(ORDER_TYPE_SELL,gTrendSCol,0);
   if(InpDbgLog)
      PrintFormat("[TPS] Init  Grid=%.5f  Target=%.2f %s  Equity=%.2f",
                  gGrid,InpTargetEquity,AccountInfoString(ACCOUNT_CURRENCY),gStartEquity);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   double bid=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   while(bid>=gRowAnchor+gGrid-1e-9) StepRow(++gLastRow,+1);
   while(bid<=gRowAnchor-gGrid+1e-9) StepRow(--gLastRow,-1);
   CheckProfitClose();
   CheckWeightedClose();
   CheckTargetEquity();
}
//+------------------------------------------------------------------+
