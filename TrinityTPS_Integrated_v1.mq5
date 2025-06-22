//  Trinity-TPS Integrated EA - Step A
//  2025-06-23 build-A0  (compile-clean template)

#property copyright "Trinity-TPS Integrated EA"
#property version   "1.3-A0"
#property strict

#include <Trade\Trade.mqh>         // CTrade

//––– Inputs
input double InpGrid        = 0.50;         // grid (JPY 0.5 = 500 points)
input double InpLots        = 0.01;         // lot size
input int    InpMagicBase   = 20250623;     // magic
input double InpEquityTgt   = 5000.0;       // equity TP
input bool   InpDebug       = true;         // log

#define  DBG(x)  if(InpDebug) Print(x)
#define  MAX_COLS 2048

//––– Enum / structs -------------------------------------------------
enum ColRole
  {
   ROLE_NONE   = 0,
   ROLE_TP     = 1,
   ROLE_BS     = 2,
   ROLE_ALT    = 3,
   ROLE_PROFIT = 4
  };

struct ColState
  {
   ColRole role;
   double  lots;
   ulong   ticket;
   ColState(){ Reset(); }
   ColState(ColRole r,double l=0,ulong t=0){ role=r; lots=l; ticket=t; }
   void Reset(){ role=ROLE_NONE; lots=0; ticket=0; }
  };

struct ProfitInfo
  {
   int    col;
   double tgt;
   double wp;
   ProfitInfo(){ col=-1; tgt=0; wp=0; }
  };

//––– Globals --------------------------------------------------------
static ColState g_cols[MAX_COLS];
static int      g_altClosedRow[MAX_COLS];

static double   gGrid        = 0.0;
static double   gBasePrice   = 0.0;
static double   gStartEquity = 0.0;
static int      gLastRow     = 0;
static int      gRowAnchor   = 0;
static int      gTrendSign   = 0;
static int      gTrendBCol   = 1;
static int      gNextCol     = 1;

static CTrade   trade;                      // << MT5 trade helper

//––– fwd decl.
void ResetState();
void CreateTrendPair(int row);
void CreatePreBsPair(int row);
void PromoteBsToAlt(int dir,int row);
void UpdateAlternateCols();
void CheckAltBE();
void StepRow(int dir,int newRow,bool pivot);

//------------------------------------------------------------------
//  OnInit
//------------------------------------------------------------------
int OnInit()
  {
 // --- TICK SIZE ---
 double tickSize = SymbolInfoDouble(_Symbol,
                                    SYMBOL_TRADE_TICK_SIZE);       // OK: Double
 if(tickSize <= 0.0)
    tickSize = _Point;      // フォールバック
   if(tickSize <= 0)   // 万一取得失敗
     tickSize = 1;

   gGrid       = InpGrid * _Point / (double)tickSize;   // grid (points)
   gBasePrice  = NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_BID),_Digits);
   gStartEquity= AccountInfoDouble(ACCOUNT_EQUITY);

   ArrayInitialize(g_altClosedRow,-1);
   ResetState();

   CreateTrendPair(0);
   CreatePreBsPair(0);

   DBG(StringFormat("[EA] Init grid=%.2f base=%.5f",gGrid,gBasePrice));
   return(INIT_SUCCEEDED);
  }

//------------------------------------------------------------------
//  OnTick
//------------------------------------------------------------------
void OnTick()
  {
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   int row = (int)MathFloor((bid - gBasePrice)/gGrid + 0.5);
   if(row==gLastRow) return;

   int  dir     = (row>gLastRow)? 1 : -1;
   bool isPivot = (gTrendSign!=0 && dir!=gTrendSign);

   StepRow(dir,row,isPivot);

   gTrendSign = dir;
   gLastRow   = row;
  }

//------------------------------------------------------------------
//  StepRow – skeleton
//------------------------------------------------------------------
void StepRow(int dir,int newRow,bool pivot)
  {
   DBG(StringFormat("[STEP] row=%d dir=%d pivot=%s",newRow,dir,(pivot?"YES":"NO")));

   if(pivot)
     {
      g_cols[gTrendBCol  ].role = ROLE_PROFIT;
      g_cols[gTrendBCol+1].role = ROLE_ALT;
      CreateTrendPair(newRow);
     }
   else
     {
      gRowAnchor = newRow;
      PromoteBsToAlt(dir,newRow);
      CreatePreBsPair(newRow);
     }

   UpdateAlternateCols();
   CheckAltBE();
  }

//------------------------------------------------------------------
//  TrendPair – Buy & Sell 同時
//------------------------------------------------------------------
void CreateTrendPair(int row)
  {
   int bCol=gNextCol++;
   int sCol=gNextCol++;

   double price = gBasePrice + gGrid*row;

   ulong bticket=0, sticket=0;
   if(trade.PositionOpen(_Symbol,ORDER_TYPE_BUY ,InpLots,price,0,0,"TP B"))
      bticket=trade.ResultOrder();
   if(trade.PositionOpen(_Symbol,ORDER_TYPE_SELL,InpLots,price,0,0,"TP S"))
      sticket=trade.ResultOrder();

   g_cols[bCol] = ColState(ROLE_TP ,InpLots,bticket);
   g_cols[sCol] = ColState(ROLE_TP ,InpLots,sticket);
   gTrendBCol   = bCol;

   DBG(StringFormat("[TP] row=%d B=%d S=%d",row,bCol,sCol));
  }

//------------------------------------------------------------------
//  Pre-BS pair
//------------------------------------------------------------------
void CreatePreBsPair(int row)
  {
   int bCol=gNextCol++;
   int sCol=gNextCol++;

   double price = gBasePrice + gGrid*row;

   ulong bticket=0, sticket=0;
   if(trade.PositionOpen(_Symbol,ORDER_TYPE_BUY ,InpLots,price,0,0,"BS B"))
      bticket=trade.ResultOrder();
   if(trade.PositionOpen(_Symbol,ORDER_TYPE_SELL,InpLots,price,0,0,"BS S"))
      sticket=trade.ResultOrder();

   g_cols[bCol] = ColState(ROLE_BS,InpLots,bticket);
   g_cols[sCol] = ColState(ROLE_BS,InpLots,sticket);

   DBG(StringFormat("[BS] row=%d bsB=%d bsS=%d",row,bCol,sCol));
  }

//------------------------------------------------------------------
//  Promote / Update / BE – stub
//------------------------------------------------------------------
void PromoteBsToAlt(int dir,int row) { /* TODO: implement */ }
void UpdateAlternateCols()          { /* TODO */ }
void CheckAltBE()                   { /* TODO */ }

//------------------------------------------------------------------
//  helpers
//------------------------------------------------------------------
void ResetState()
  {
   for(int i=0;i<MAX_COLS;i++) g_cols[i].Reset();
   gNextCol   = 1;
   gTrendBCol = 1;
   gLastRow   = 0;
   gRowAnchor = 0;
   gTrendSign = 0;
  }
