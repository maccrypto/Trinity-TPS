//+------------------------------------------------------------------+
//|  Trinity.mq5  –  Generic GridTPS Entry Core                      |
//|  rev‑T1.0.4   (2025‑6-29)                                       |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//────────────────────────── Inputs ───────────────────────────────
input string  InpSymbol       = "USDJPY";    // 取引銘柄
input double  InpLot          = 0.01;        // ロットa
input double  InpGridSize     = 0.50;        // グリッド幅（価格）
input double  InpTargetEquity = 5000.0;      // 目標利益（口座通貨）
input uint    InpMagic        = 20250607;    // マジック番号
input bool    InpDbgLog       = true;        // 詳細ログ

//────────────────────────── Types ────────────────────────────────
enum ColRole { ROLE_PENDING, ROLE_PROFIT, ROLE_ALT, ROLE_TREND };

struct ColState
{
   uint    id;
   ColRole role;
   int     lastDir;
   int     altRefRow;
   int     altRefDir;
   uint    posCnt;
};

//────────────────────────── Globals ──────────────────────────────
#define MAX_COL 2048                         // ← プリプロセッサ定数に変更
static ColState colTab[MAX_COL+2];           // 構造体配列
static int      altClosedRow[MAX_COL+2];

static double GridSize;                      // 実使用グリッド
static double basePrice   = 0.0;
static double rowAnchor   = 0.0;
static int    lastRow     = 0;
static int    trendSign   = 0;
static uint   nextCol     = 1;
static uint   trendBCol   = 0, trendSCol = 0;

struct ProfitInfo { bool active; uint col; int refRow; };
static ProfitInfo profit = {false,0,0};

static double startEquity = 0.0;

static uint  altBCol   = 0;       // Pivot 行で 1 本目を建てる ALT 列
static uint  altSCol   = 0;       // Pivot 行で 2 本目を建てる ALT 列

static bool altFirst = false;


//──────────────────────── Utility ────────────────────────────────
void ClearColTab()
{
   for(int i=0;i<MAX_COL+2;i++) ZeroMemory(colTab[i]);
}

string Cmnt(int r,uint c){ return "r"+IntegerToString(r)+"C"+IntegerToString(c); }

bool Parse(const string &cm,int &r,uint &c)
{
   long p = StringFind(cm,"C");
   if(p < 1) return false;
   long tmpR = StringToInteger(StringSubstr(cm,1,(int)p-1));
   long tmpC = StringToInteger(StringSubstr(cm,p+1));   // ← まず long で受ける
   r = (int)tmpR;
   c = (uint)tmpC;
   return true;
}
bool SelectPosByIndex(int index)
{
   ulong tk=PositionGetTicket(index);
   return (tk!=0 && PositionSelectByTicket(tk) &&
           PositionGetInteger(POSITION_MAGIC)==InpMagic);
}

// Duplicate-guard : Parse() をそのまま使う
bool HasPos(uint col,int row)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r; uint c;
      if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;
      if(r == row && c == col) return true;
   }
   return false;
}
//──────────────── Market order helper ────────────────────────────
bool Place(ENUM_ORDER_TYPE t, uint col, int row, bool isAltFirst = false)
{
   // 同一セルに既存ポジションがあれば発注せず終了
   if(HasPos(col, row))
      return false;

   // 注文価格を決定
   double price = (t == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(InpSymbol, SYMBOL_ASK)
                  : SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   // 発注実行
   bool ok;
   if(t == ORDER_TYPE_BUY)
      ok = trade.Buy(InpLot, InpSymbol, price, 0, 0, Cmnt(row, col));
   else
      ok = trade.Sell(InpLot, InpSymbol, price, 0, 0, Cmnt(row, col));

   // 発注成功時の後処理
   if(ok)
   {
      colTab[col].posCnt++;
      colTab[col].lastDir = (t == ORDER_TYPE_BUY ? +1 : -1);
      if(isAltFirst)               // 初回は “いま建った玉” の向きを保存
       {
           colTab[col].altRefRow = row;
           colTab[col].altRefDir =  colTab[col].lastDir;  // ← そのまま記憶
       }
      if(InpDbgLog)
         PrintFormat("[NEW] r=%d c=%u role=%d dir=%s ALTfirst=%d posCnt=%u",
                     row, col, colTab[col].role,
                     (t == ORDER_TYPE_BUY ? "Buy" : "Sell"),
                     isAltFirst, colTab[col].posCnt);
   }

   return ok;
}
//──────────────── Forward decls ─────────────────────────────────
void UpdateAlternateCols(int curRow, int dir);   // ← これだけ残す

//──────────────── Trend helpers ──────────────────────────────────
void CreateTrendPair(int row)
{
   uint b=nextCol++, s=nextCol++;
   colTab[b].id=b; colTab[b].role=ROLE_TREND;
   colTab[s].id=s; colTab[s].role=ROLE_TREND;
   trendBCol=b; trendSCol=s;
   Place(ORDER_TYPE_BUY ,b,row);
   Place(ORDER_TYPE_SELL,s,row);
}
//────────────────────────────────────────────────────────────────
// FixTrendPair(int dir, int curRow)
//   ・旧 Trend ペア２本とも ALT 化（片方は Profit-Close 用に flag だけ残す）
//   ・新しい Pivot 用に altBCol / altSCol を確定させる
//────────────────────────────────────────────────────────────────
void FixTrendPair(int dir, int curRow)
{
   if(trendBCol == 0 || trendSCol == 0) return;

   // ── ２本とも ALT 化してから profit トリガを仕込む ──
   colTab[trendBCol].role = ROLE_ALT;
   colTab[trendSCol].role = ROLE_ALT;

   // （向きは “建っていた最後の向き” を基準にする）
   colTab[trendBCol].altRefRow = curRow;
   colTab[trendBCol].altRefDir = colTab[trendBCol].lastDir;
   colTab[trendSCol].altRefRow = curRow;
   colTab[trendSCol].altRefDir = colTab[trendSCol].lastDir;

   // ── Profit-Close させるのは「Pivot 方向に建っていた側」だけ
   if(dir > 0)                  // 上昇 Pivot ⇒ Buy の列を利確対象
   {
      colTab[trendBCol].role = ROLE_PROFIT;
      profit.active  = true;
      profit.col     = trendBCol;
      profit.refRow  = curRow;
   }
   else                          // 下降 Pivot ⇒ Sell の列を利確対象
   {
      colTab[trendSCol].role = ROLE_PROFIT;
      profit.active  = true;
      profit.col     = trendSCol;
      profit.refRow  = curRow;
   }

   /* ★ Pivot 行で使う２本の ALT 列を確定
        ─ 1 本目 ＝ Pivot 直前に ALT だった列
        ─ 2 本目 ＝ Profit 列（利確後に再 ALT 化する）                   */
   altBCol  = (dir > 0) ? trendSCol : trendBCol;   // 先手側
   altSCol  = (dir > 0) ? trendBCol : trendSCol;   // 後手側
   altFirst = false;                               // 毎 Pivot リセット

   trendBCol = trendSCol = 0;                      // 現役ペアは消滅
}

//────────────────────────────────────────────────────────────────
// SafeRollTrendPair(int curRow, int dir)
//   ❶ 旧 Row の TrendPair（B/S）を必ず閉じる
//   ❷ 新しい Row に Buy／Sell を固定で建て直す
//      ＊Place() 内で Duplicate-Guard が働くので多重発注にはならない
//────────────────────────────────────────────────────────────────
void SafeRollTrendPair(int curRow, int dir)

{
   int prevRow = curRow - dir;

   // ── ❶ 旧 Row に残っている TrendPair をクローズ ──
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectPosByIndex(i)) continue;

      int  r;   uint c;
      if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;

      if(r == prevRow && (c == trendBCol || c == trendSCol))
      {
         ulong tk = PositionGetTicket(i);
         if(trade.PositionClose(tk))
            colTab[c].posCnt--;
      }
   }

   // ── ❷ 新 Row に必ず建てる（既に有れば Place が無視） ──
   Place(ORDER_TYPE_BUY , trendBCol, curRow);   // Buy 固定
   Place(ORDER_TYPE_SELL, trendSCol, curRow);   // Sell 固定

   if(InpDbgLog)
      PrintFormat("SafeRollTrendPair rolled from Row %d to Row %d", prevRow, curRow);
}
//───────────────────────────────────────────────────────────────
// ① 通常行で既存 ALT 列を敷き直す
//───────────────────────────────────────────────────────────────
void RollAlternateCols(int curRow)
{
   for(uint c=1; c<nextCol; c++)
   {
      if(colTab[c].role!=ROLE_ALT) continue;
      ENUM_ORDER_TYPE t = AltDir(c,curRow);
      Place(t,c,curRow);     // Duplicate-Guard 付き
   }
}

//───────────────────────────────────────────────────────────────
// ② Pivot 専用 – ALT の“タネ玉”２本だけ建てる
//───────────────────────────────────────────────────────────────
void SeedPivotAlts(int curRow,int dir)
{
   bool buyFirst = (dir>0);
   if(altFirst) buyFirst = !buyFirst;

   if(altBCol)
      Place(buyFirst ? ORDER_TYPE_BUY  : ORDER_TYPE_SELL,
            altBCol,curRow,true);   // ← isAltFirst=true

   if(altSCol)
      Place(buyFirst ? ORDER_TYPE_SELL : ORDER_TYPE_BUY ,
            altSCol,curRow,true);

   altFirst = !altFirst;
}

//────────────────────────────────────────────────────────────────
// AltDir(uint col, int curRow)
// altRefDir の偶奇判定を %2 演算で負値対応し、一律に反転基準を適用
//────────────────────────────────────────────────────────────────
ENUM_ORDER_TYPE AltDir(uint col, int curRow)
{
    int diff = curRow - colTab[col].altRefRow;
    bool even = ((diff % 2) == 0);
    int dir = even ? colTab[col].altRefDir : -colTab[col].altRefDir;
    return (dir == +1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
}

//──────────────── Profit‑Close ───────────────────────────────────
void CheckProfitClose()
{
   if(!profit.active) return;
   double tgt=basePrice+(profit.refRow-1)*GridSize;
   if(SymbolInfoDouble(InpSymbol,SYMBOL_BID)>tgt+1e-9) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!SelectPosByIndex(i)) continue;
      int r; uint c; if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
      if(c==profit.col && trade.PositionClose(PositionGetTicket(i)))
          colTab[c].posCnt--;
   }
   profit.active=false;
   Place(ORDER_TYPE_SELL,1,profit.refRow-1,true);
}
//────────────────────────────────────────────────────────────────
// CheckWeightedClose()
//   ポジション損益が 0 以上になった ALT 列を丸ごと決済
//   ※ ALT 列の枚数が「3 枚以上」かつ「奇数枚」の場合のみ発火
//────────────────────────────────────────────────────────────────
void CheckWeightedClose()
{
   for(uint c = 1; c < nextCol; c++)
   {
      if(colTab[c].role != ROLE_ALT)            // ALT 列のみ対象
         continue;

      double sumProfit = 0.0;
      ulong  tks[128];
      int    n = 0;

      // ── 列 c の全ポジ損益を集計
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!SelectPosByIndex(i)) continue;

         int  r;
         uint col;
         if(!Parse(PositionGetString(POSITION_COMMENT), r, col) || col != c)
            continue;

         tks[n++]   = PositionGetTicket(i);
         sumProfit += PositionGetDouble(POSITION_PROFIT);
      }
      if(n == 0)                // その列に建玉なし
         continue;

      // ── BE 決済条件：0 以上 & 3 枚以上 & 奇数枚
      if(sumProfit >= 0.0 && n >= 3 && (n & 1) == 1)
      {
         uint closed = 0;
         for(int k = 0; k < n; k++)
            if(trade.PositionClose(tks[k]))
            {
               closed++;
               colTab[c].posCnt--;
            }

         if(closed > 0)                       // 実際に決済した場合のみ
         {
            altClosedRow[c] = lastRow;

            if(colTab[c].posCnt == 0)         // 列が空なら PENDING へ
               colTab[c].role = ROLE_PENDING;

            if(InpDbgLog)
               PrintFormat("WeightedClose ≥0  col=%u  P/L=%.2f  closed=%u",
                           c, sumProfit, closed);
         }
      }
   }
}

//──────────────── Equity Target ──────────────────────────────────
void CheckTargetEquity()
{
   double curEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(curEquity-startEquity < InpTargetEquity-1e-9) return;

   // 目標到達 – 全決済
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(SelectPosByIndex(i)) trade.PositionClose(PositionGetTicket(i));

   if(InpDbgLog) PrintFormat("Target %.2f reached! Equity %.2f – reset",InpTargetEquity,curEquity);

   // 内部状態リセット
   ClearColTab(); ArrayInitialize(altClosedRow,-9999);
   nextCol=1; trendBCol=trendSCol=0; lastRow=0; trendSign=0;
   basePrice=rowAnchor=SymbolInfoDouble(InpSymbol,SYMBOL_BID);

   colTab[1].id=1; colTab[1].role=ROLE_TREND;
   colTab[2].id=2; colTab[2].role=ROLE_TREND;
   trendBCol=1; trendSCol=2; nextCol=3;
   Place(ORDER_TYPE_BUY ,trendBCol,0);
   Place(ORDER_TYPE_SELL,trendSCol,0);

   startEquity=curEquity;
}

// ────────────────────────────────────────────────
// ③ StepRow – Trend 継続では TrendPair を触らない
// ────────────────────────────────────────────────
void StepRow(int newRow,int dir)
{
   bool pivot = (trendSign!=0 && dir!=trendSign);   // 方向転換だけ Pivot

   if(InpDbgLog)
      PrintFormat("StepRow newRow=%d dir=%d pivot=%s",
                  newRow,dir,pivot?"YES":"NO");

   /*── TrendPair 処理 ───────────────────────*/
   if(pivot)
   {
      // 旧 TrendPair → PROFIT / ALT 化
      FixTrendPair(dir,newRow);

      // Pivot 行 (newRow==0) に新しい TrendPair を建てる
      CreateTrendPair(newRow);

      // Pivot 行で ALT のタネ玉を 1 本ずつ
      SeedPivotAlts(newRow,dir);
   }
   /* ★ 継続行では TrendPair を「物理的に」動かさない ★ */

   /*── PENDING → TREND 昇格判定 ────────────*/
   for(uint c=1;c<nextCol;c++)
   {
      if(colTab[c].role!=ROLE_PENDING || colTab[c].posCnt!=0) continue;
      if(altClosedRow[c]==lastRow) continue;     // 直前 ALT 列は保留
      colTab[c].role = ROLE_TREND;
   }

   /*── ALT 列を現 Row に敷き直す ───────────*/
   RollAlternateCols(newRow);

   /*── 行・方向フラグ更新 ──────────────────*/
   lastRow   = newRow;
   trendSign = dir;
}

//──────────────────────────────────────────────────────────────
// UpdateAlternateCols(int curRow,int dir)
//   pivot 行に ALT 列をすべて並べる
//   buyFirst = (dir>0) で決定し、altFirst トグルで反転
//──────────────────────────────────────────────────────────────
void UpdateAlternateCols(int curRow,int dir)
{
   bool buyFirst = (dir > 0);          // 上昇 pivot → Buy 始まり

   if(altFirst)                        // 直前 pivot が反転なら裏返す
      buyFirst = !buyFirst;

   // ── 今回 pivot で ALT 化された列だけ処理 ──
   for(uint c = 1; c < nextCol; c++)
   {
      if(colTab[c].role != ROLE_ALT)        continue;
      if(colTab[c].altRefRow != curRow)     continue;

      ENUM_ORDER_TYPE t = buyFirst ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      /* ★ 第4引数 = true（必ず 1 と記録される）★ */
      Place(t, c, curRow, /*isAltFirst=*/true);

      buyFirst = !buyFirst;                 // 列ごとに交互
   }

   altFirst = !altFirst;                    // 次回 pivot 用トグル
}

//───────────────────────OnInit─────────────────────────────────────────
int OnInit()
{
   GridSize    = InpGridSize;
   basePrice   = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   rowAnchor   = basePrice;              // 基準アンカーは BID そのまま
   startEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   ClearColTab(); ArrayInitialize(altClosedRow,-9999);
   trade.SetExpertMagicNumber(InpMagic);

   // 最初の Trend ペア作成
   colTab[1].id=1; colTab[1].role=ROLE_TREND;
   colTab[2].id=2; colTab[2].role=ROLE_TREND;
   trendBCol=1; trendSCol=2; nextCol=3;
   Place(ORDER_TYPE_BUY ,trendBCol,0);
   Place(ORDER_TYPE_SELL,trendSCol,0);

   if(InpDbgLog)
      PrintFormat("EA init: GRID=%.5f Target=%.2f %s StartEquity=%.2f",
                  GridSize,InpTargetEquity,AccountInfoString(ACCOUNT_CURRENCY),startEquity);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   if(bid >= rowAnchor + GridSize - 1e-9)
   {
      StepRow(lastRow + 1, +1);
      rowAnchor += GridSize;
   }
   else if(bid <= rowAnchor - GridSize + 1e-9)
   {
      StepRow(lastRow - 1, -1);
      rowAnchor -= GridSize;
   }

  

   CheckProfitClose();
   CheckWeightedClose();
   CheckTargetEquity();
}

//+------------------------------------------------------------------+
