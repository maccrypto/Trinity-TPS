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

//──────────────────────── Utility ────────────────────────────────
void ClearColTab()
{
   for(int i=0;i<MAX_COL+2;i++) ZeroMemory(colTab[i]);
}

string Cmnt(int r,uint c){ return "r"+IntegerToString(r)+"C"+IntegerToString(c); }

bool Parse(const string &cm,int &r,uint &c)
{
   // StringFind の戻り値は long なので long で受ける
   long p = StringFind(cm,"C");
   if(p < 1) return false;
   // 'r' の次から 'C' の直前までを整数化
   r = (int)StringToInteger(StringSubstr(cm,1,(int)p-1));
   c = (uint)StringToInteger(StringSubstr(cm,p+1));
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
// （SafeRollTrendPair は実装をそのまま残し、前方宣言を削除）
void UpdateAlternateCols(int curRow);

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
// 上昇・下降ともに altRefDir = -lastDir で統一
//────────────────────────────────────────────────────────────────
void FixTrendPair(int dir, int curRow)
{
    if(trendBCol == 0 || trendSCol == 0) return;

    if(dir > 0)
    {
          // 上昇トレンド：B→PROFIT, S→ALT
    colTab[trendBCol].role = ROLE_PROFIT;  // ← 利確列を残す
    colTab[trendSCol].role = ROLE_ALT;
        colTab[trendSCol].altRefRow  = curRow;
        colTab[trendSCol].altRefDir  = -colTab[trendSCol].lastDir;
        profit.active = false;
    }
    else
    {
        // 下降トレンド：S→PROFIT, B→ALT
        colTab[trendSCol].role       = ROLE_PROFIT;
        colTab[trendBCol].role       = ROLE_ALT;
        colTab[trendBCol].altRefRow  = curRow;
        colTab[trendBCol].altRefDir  = -colTab[trendBCol].lastDir;  // 反転で統一
        profit.active = true;
        profit.col    = trendSCol;
        profit.refRow = curRow;
    }
    trendBCol = trendSCol = 0;
}

//────────────────────────────────────────────────────────────────
// SafeRollTrendPair(int curRow, int dir)
// 前方宣言を削除し、実装だけを残す
//────────────────────────────────────────────────────────────────
void SafeRollTrendPair(int curRow, int dir)
{
    int prevRow = curRow - dir;
    bool closedB = false, closedS = false;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!SelectPosByIndex(i)) continue;
        int r; uint c;
        if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;
        ulong tk = PositionGetTicket(i);

        if(r == prevRow && c == trendBCol)             // 閉じない
        closedB = true;
        if(r == prevRow && c == trendSCol)             // 閉じない
        closedS = true;
    }
    if(!(closedB && closedS))
    {
        // 旧行にポジが残っていない場合は、そのまま新行へロール
        Place((dir > 0 ? ORDER_TYPE_BUY  : ORDER_TYPE_SELL), trendBCol, curRow);
        Place((dir > 0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY ), trendSCol, curRow);
        return;
    }

    // 新しい Row にロール
    Place((dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL),  trendBCol, curRow);
    Place((dir > 0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY), trendSCol, curRow);

    if(InpDbgLog)
        PrintFormat("SafeRollTrendPair rolled to Row %d", curRow);
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
// 合計損益が “完全ゼロ” の場合のみ全決済
//────────────────────────────────────────────────────────────────
void CheckWeightedClose()
{

    // 完全ゼロ判定のため、しきい値は 0 に固定
    double epsProfit = 0.0;

    for(uint c = 1; c < nextCol; c++)
    {
        if(colTab[c].role != ROLE_ALT) continue;
        // 奇数本のみ対象
        if((colTab[c].posCnt & 1) == 0) continue;

        double sumProfit = 0.0;
        ulong  tks[128];
        int    n = 0;
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(!SelectPosByIndex(i)) continue;
            int r; uint col;
            if(!Parse(PositionGetString(POSITION_COMMENT), r, col) || col != c) continue;
            tks[n++]   = PositionGetTicket(i);
            sumProfit += PositionGetDouble(POSITION_PROFIT);
        }
        if(n == 0) continue;

        // 完全ゼロなら全決済
        if(MathAbs(sumProfit) <= epsProfit /* == 0 */)
        {
            uint closed = 0;
            for(int k = 0; k < n; k++)
            {
                if(trade.PositionClose(tks[k]))
                {
                    closed++;
                    colTab[c].posCnt--;
                }
            }
            altClosedRow[c] = lastRow;
            if(colTab[c].posCnt == 0) colTab[c].role = ROLE_PENDING;
            if(InpDbgLog)
                PrintFormat("WeightedClose ZERO col=%u  P/L=%.2f  closed=%u",
                            c, sumProfit, closed);
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

//──────────────── Row step ──────────────────────────────────────
void StepRow(int newRow, int dir)
{
    bool pivot = (trendSign != 0 && dir != trendSign);

    if(InpDbgLog)
        PrintFormat("StepRow newRow=%d dir=%d pivot=%s",
                    newRow, dir, pivot ? "YES" : "NO");

       if(pivot || trendSign==0)
   {
       FixTrendPair(dir, newRow);
       CreateTrendPair(newRow);
   }
   else
   {
       SafeRollTrendPair(newRow, dir);
   }

    // ❸ PENDING → TREND への昇格チェック
    for(uint c = 1; c < nextCol; c++)
        if(colTab[c].role == ROLE_PENDING && colTab[c].posCnt == 0)
            colTab[c].role = ROLE_TREND;

    // ❹ 最後に行進の状態を更新
    lastRow   = newRow;
    trendSign = dir;
}

//────────────────────────────────────────────────────────────────
// UpdateAlternateCols(int curRow)
// altClosedRow[c] == curRow の場合のみ建て直しを抑止
//────────────────────────────────────────────────────────────────
void UpdateAlternateCols(int curRow)
{
    for(uint c = 1; c < nextCol; c++)
    {
        if(colTab[c].role == ROLE_ALT && altClosedRow[c] != curRow)
            Place(AltDir(c, curRow), c, curRow);
    }
}
//────────────────────────────────────────────────────────────────
// SyncRowByPrice()
//   basePrice からの乖離を GridSize 刻みで丸めて「行番号」を返す
//────────────────────────────────────────────────────────────────
int SyncRowByPrice()
{
    // 現在の Bid と基準価格の差分を取得
    double bid   = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
    double delta = bid - basePrice;
    // 0.5グリッド分をシフトして丸め、行番号として返す
    return (int)MathFloor((delta + GridSize * 0.5) / GridSize);
}

//──────────────── OnInit / OnTick ───────────────────────────────
int OnInit()
{
   GridSize=InpGridSize;
   basePrice=rowAnchor=SymbolInfoDouble(InpSymbol,SYMBOL_BID);
   startEquity=AccountInfoDouble(ACCOUNT_EQUITY);

   ClearColTab(); ArrayInitialize(altClosedRow,-9999);
   trade.SetExpertMagicNumber(InpMagic);

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
   // ① 現在の行番号をシンキング
   int newRow = SyncRowByPrice();
   // ② 方向を決定
   int dir = (newRow > lastRow ? +1 : (newRow < lastRow ? -1 : 0));
   if(dir != 0)
   {
       // ③ 一行分だけステップ
       StepRow(newRow, dir);
       // ④ 行アンカーを再計算
       rowAnchor = basePrice + newRow * GridSize;
       // ⑤ trendSign を更新
       trendSign = dir;
       lastRow   = newRow;
   }

   // ⑥ ほかの機能
   CheckProfitClose();
   CheckWeightedClose();
   CheckTargetEquity();
}


//+------------------------------------------------------------------+
