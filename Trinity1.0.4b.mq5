//+------------------------------------------------------------------+
//|  Trinity.mq5  –  Generic Grid‑TPS Entry Core                     |
//+------------------------------------------------------------------+
#property strict
#define UNIT_TEST
#include <TrinitySim.mqh>

int lastRow = 0;
int StepCount = 0;

void StepRow(const int r, const int dir)
{
   lastRow = r;
   StepCount++;
}

void SimulateMove(const int targetRow)
{
   if(targetRow == lastRow) return;
   const int dir = (targetRow > lastRow ? 1 : -1);
   int safety = 400;
   while(lastRow != targetRow && safety-- > 0)
      StepRow(lastRow + dir, dir);
}

// （以下、既存の Fake API ブロック / 以降のロジックはそのまま）

#define UNIT_TEST
/*──────────────── Fake Position pool & API for UNIT_TEST ───────────────*/
#ifdef UNIT_TEST

// ⚠️ この塊は <Trade/Trade.mqh> より前にマクロを張り替える必要があります。
//    1) 先に forward‑declaration とマクロを並べる
//    2) その後で実装を置けば OK（コンパイラは後方参照を許す）
// ---------------------------------------------------------------------

struct FakePos{
   ulong  tk;      // 擬似チケット
   int    row;     // グリッド行
   uint   col;     // 列番号
   double profit;  // 擬似損益
   int    dir;     // +1 Buy / -1 Sell
};
static FakePos fakePos[8192];
static int     fakeCnt = 0;
static ulong   nextTk  = 1;
static int     _fpIdx  = -1;

// ───────────────── forward prototypes ─────────────────
int    Fake_PositionsTotal();
ulong  Fake_PositionGetTicket(int idx);
bool   Fake_PositionSelectByTicket(ulong tk);

double Fake_PositionGetDouble(int property,int index=0);
long   Fake_PositionGetInteger(int property,int index=0);

string Fake_PositionGetString(int property,int index=0);
bool   Fake_PositionGetString(int property,string &value,int index=0);

bool   Fake_PositionClose(ulong tk);

// ───────────────── macro remap ─────────────────
#define PositionsTotal         Fake_PositionsTotal
#define PositionGetTicket      Fake_PositionGetTicket
#define PositionSelectByTicket Fake_PositionSelectByTicket
#define PositionGetInteger     Fake_PositionGetInteger
#define PositionGetDouble      Fake_PositionGetDouble
#define PositionGetString      Fake_PositionGetString
#define PositionClose          Fake_PositionClose

// ───────────────── implementation ─────────────────
int Fake_PositionsTotal(){ return fakeCnt; }

ulong Fake_PositionGetTicket(int idx){ return fakePos[idx].tk; }

bool Fake_PositionSelectByTicket(ulong tk)
{
   for(int i=0;i<fakeCnt;++i)
      if(fakePos[i].tk==tk){ _fpIdx=i; return true; }
   return false;
}

// helper: build "comment" string once
inline string _FakeCmnt(){ return Cmnt(fakePos[_fpIdx].row, fakePos[_fpIdx].col); }

// --- GetString overloads ---
string Fake_PositionGetString(int property,int /*index*/=0)
{
   return (property==POSITION_COMMENT)?_FakeCmnt():"";
}

bool Fake_PositionGetString(int property,string &value,int /*index*/=0)
{
   value=(property==POSITION_COMMENT)?_FakeCmnt():"";
   return true;
}

// --- GetDouble ---
double Fake_PositionGetDouble(int property,int /*index*/=0)
{
   return (property==POSITION_PROFIT)?fakePos[_fpIdx].profit:0.0;
}

// --- GetInteger ---
long Fake_PositionGetInteger(int property,int /*index*/=0)
{
   switch(property)
   {
      case POSITION_MAGIC: return InpMagic;
      case POSITION_TYPE:  return (fakePos[_fpIdx].dir>0)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
      default:             return 0;
   }
}

// --- PositionClose ---
bool Fake_PositionClose(ulong tk)
{
   for(int i=0;i<fakeCnt;++i)
      if(fakePos[i].tk==tk){ fakePos[i]=fakePos[--fakeCnt]; return true; }
   return false;
}

// ───────────────── Fake CTrade wrapper ─────────────────
class FakeTrade{
public:
   bool Buy (double,string,double,double,double,string){ return true; }
   bool Sell(double,string,double,double,double,string){ return true; }
   bool PositionClose(ulong tk){ return Fake_PositionClose(tk); }
   void SetExpertMagicNumber(int) {}
} trade_fake;

#define trade trade_fake   // 本物を完全に置換

#endif // UNIT_TEST

//――― Unit‑Test ビルド用フラグ
//     ※ fake‑API マクロ置換より**前**に宣言しておくこと！


// ---- 本番用ライブラリは UT では読み込まない -----------------
#ifndef UNIT_TEST
   #include <Trade/Trade.mqh>
   CTrade trade;            // ← 実運用時はこちらを使う
#endif                      // --------------------------------



//────────────────────────── Inputs ───────────────────────────────
input string  InpSymbol       = "USDJPY";   // trading symbol
input double  InpLot          = 0.01;        // lot size
input double  InpGridSize     = 0.50;        // grid width (JPY)
input double  InpTargetEquity = 5000.0;      // target profit (account currency)
input uint    InpMagic        = 20250607;    // magic number
input bool    InpDbgLog       = true;        // verbose logging

//────────────────────────── Types / Globals ──────────────────────
enum ColRole { ROLE_PENDING, ROLE_PROFIT, ROLE_ALT, ROLE_TREND };

#define MAX_COL 2048

static int altClosedRow[MAX_COL + 2];  // ← これ１行だけ
int       curRow = 0;                  // ← 必要ならここで１回だけ定義

struct ColState
{
   uint    id;
   ColRole role;
   int     lastDir;     // +1 Buy / -1 Sell
   int     altRefRow;   // reference row for ALT parity
   int     altRefDir;   // first direction (+1/-1)
   uint    posCnt;      // live positions in column
};
/*―――― ProfitInfo : 利食いサイクルを 1 Pivot 単位でロック ――――*/
struct ProfitInfo
{
   bool active;      // 利食いサイクル中フラグ
   uint profitCol;   // 利確対象列（Pivot で確定・上書き禁止）
   uint rebuildCol;  // r-1 に Sell を再建てする列
   int  refRow;      // Pivot 行
};
static ProfitInfo profit = { false, 0, 0, 0 };
#define MAX_COL 2048
static ColState colTab[MAX_COL + 2];

static double GridSize;
static double basePrice   = 0.0;
static double rowAnchor   = 0.0;
static int    trendSign   = 0;      // +1 / -1 (0 = unknown)
static uint   nextCol     = 1;
static uint   trendBCol   = 0, trendSCol = 0;

// Pivot‑ALT bookkeeping
static uint  altBCol = 0;
static uint  altSCol = 0;
static bool  altFirst = false;

//――― ALT 列が「未シード状態」であることを示す番兵値
const int ALT_UNINIT = -2147483647;   // (= INT_MIN 相当)

static double startEquity = 0.0;

// Forward-declarations ──────────────────
 void CheckWeightedClose();
 void FixTrendPair(int dir, int row);
// ▼ Unit-Test 用 API（この 2 行だけ！） -------------------------
#ifdef UNIT_TEST
void ResetAll();         // ← export 削除
void SimulateMove(const int targetRow); // 形式を本体と一致させる（※ただし本体が既に上にあるならこの行すら不要）
void SimulateHalfStep();

//─────────────────────────────────────────────
//  ★ Unit-Test helper bodies
//─────────────────────────────────────────────
#ifdef UNIT_TEST

// ① すべての内部状態を最初の OnInit と同じ “真っさら” に戻す
void ResetAll()
{
   /*―― Fake ポジションプールを初期化 ――*/
   fakeCnt = 0;
   nextTk  = 1;
   _fpIdx  = -1;

   /*―― グローバル管理変数をリセット ――*/
   GridSize   = InpGridSize;
   basePrice  = rowAnchor = CurBidUT();
   lastRow    = 0;
   trendSign  = 0;
   nextCol    = 1;
   trendBCol  = 0;
   trendSCol  = 0;
   profit.active = false;
   // ★ 初期利益基準をアカウントの現在エクイティに合わせる
   startEquity   = AccountInfoDouble(ACCOUNT_EQUITY);

   /*―― テーブル類をクリア ――*/
   ClearColTab();
   ArrayInitialize(altClosedRow, -9999);

   // TREND ペアの初期シード
   //    dir は初期なので使いませんが、2 引数版に合わせて 0, 0 を渡します
   FixTrendPair(0, 0);
}


//─────────────────────────────────────────
// TREND ペアを指定行で組むヘルパー関数
//─────────────────────────────────────────
//--- FixTrendPair: 方向初期化 or Pivot 時にトレンド列を再ラベル／再配置
void FixTrendPair(const int dir, const int row)
{
   // 進入ログ（リセット抑止デバッグ）
   PrintFormat("[FIX] enter FixTrendPair dir=%d row=%d nextCol(before)=%u trendSign=%d",
               dir, row, nextCol, trendSign);

   // 既存トレンド列を 1(BUY) / 2(SELL) に再マップ
   trendBCol = 1;
   trendSCol = 2;
   colTab[trendBCol].id   = trendBCol;
   colTab[trendBCol].role = ROLE_TREND;
   colTab[trendSCol].id   = trendSCol;
   colTab[trendSCol].role = ROLE_TREND;

   // ★ 以前は nextCol = 3; などで“常に”リセットしていた想定
   // 既に拡張済み（nextCol >= 3）なら壊さない。初回だけ初期値保障。
   if(nextCol < 3)
      nextCol = 3;

   // 初回だけ列クリア等の重い初期化をしたい場合はここに条件付きで置く:
   // if(trendSign == 0) { /* 初回のみの初期化処理 (必要なら) */ }

   // 現在の行へトレンド列を再配置
   Place(ORDER_TYPE_BUY , trendBCol, row);
   Place(ORDER_TYPE_SELL, trendSCol, row);

   PrintFormat("[FIX] leave FixTrendPair nextCol(after)=%u", nextCol);
}

//+------------------------------------------------------------------+
// ③ 現在行のまま 0.5 グリッドだけ “半歩” 動かす
void SimulateHalfStep()
{
   rowAnchor += GridSize * 0.5;   // 中間まで動かす
   UpdateFakeProfits();
   CheckWeightedClose();          // 半歩位置でのみ発火を確認
   rowAnchor -= GridSize * 0.5;   // 元に戻す
   UpdateFakeProfits();
}

#endif  // UNIT_TEST helper bodies ここまで

#endif
//=============================================================
//  ★ UT 専用　現在の擬似 Bid 価格を返す
//=============================================================
double CurBidUT()
{
#ifdef UNIT_TEST
   return  basePrice + lastRow * InpGridSize;   // 擬似 Bid
#else
   return  SymbolInfoDouble(InpSymbol, SYMBOL_BID);   // ←本来の Bid
#endif
}

//──────────────────────── Utility ────────────────────────────────
void ClearColTab() {
    // Reset all column states to default (e.g. after closing all positions)
    for(int i = 0; i < MAX_COL + 2; ++i) {
        ZeroMemory(colTab[i]);
    }
}
string Cmnt(int r, uint c) {
    // Construct position comment as "r<row>C<col>"
    return "r" + IntegerToString(r) + "C" + IntegerToString((int)c);
}
bool Parse(const string &cm, int &r, uint &c) {
    // Parse position comment "r<row>C<col>" into row and col values
    long p = StringFind(cm, "C");
    if(p < 1) return false;
    r = (int)StringToInteger(StringSubstr(cm, 1, p - 1));
    c = (uint)StringToInteger(StringSubstr(cm, p + 1));
    return true;
}

/**
 * @brief  インデックスからポジションコメントを取得
 * @param  idx   取得するポジションのインデックス
 * @param  cm    出力：コメント文字列
 * @return true＝コメント取得成功、false＝除外
 */
bool GetPositionComment(int idx, string &cm)
{
#ifdef UNIT_TEST
    // テスト時は fakePos 配列などから取得する実装に合わせてください
    cm = fakeComments[idx];  
    return(true);
#else
    cm = PositionGetString(POSITION_COMMENT);
    return(true);
#endif
}

bool GetPosRC(int idx, int &r, uint &c)
{
    // ポジション選択
    if(!SelectPosByIndex(idx))
        return(false);
    // コメント取得
    string cm;
    if(!GetPositionComment(idx, cm))
        return(false);
    // Parse
    return(Parse(cm, r, c));
}
bool SelectPosByIndex(int idx) {
    // Select the position by index if it belongs to this EA (matching magic)
    if(idx < 0 || idx >= PositionsTotal()) return false;
    ulong ticket = PositionGetTicket(idx);
    if(ticket == 0) return false;
    if(!PositionSelectByTicket(ticket)) return false;
    if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) return false;
    return true;
}
bool HasPos(uint col, int row) {
    // Check if there is an existing position with the given column and row
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!SelectPosByIndex(i)) continue;
        int r; uint c;
        if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;
        if(r == row && c == col) {
            return true;
        }
    }
    return false;
}                     // 見つからず

#ifdef UNIT_TEST			
		
#endif

//──────────────── Market-order helper ──────────────────────────
bool Place(ENUM_ORDER_TYPE t,
           uint             col,
           int              row,
           bool             isAltFirst=false)
{
   /*――― ① 重複＆即時再-entry 防止 ―――*/
   if( HasPos(col,row)                // 同一セル重複
   ||  altClosedRow[col] == row )     // 直前 break-even 行ならスキップ
      return false;

   /*――― ② 発注価格 ―――*/
   double price = (t == ORDER_TYPE_BUY)
                    ? SymbolInfoDouble(InpSymbol, SYMBOL_ASK)
                    : CurBidUT();    // 最新 bid を取得するヘルパ関数

   /*――― ③ 発注実行 ―――*/
   bool ok;
#ifdef UNIT_TEST
   // テスト用ダミー発注
   int idx         = fakeCnt++;
   fakePos[idx].tk  = nextTk++;
   fakePos[idx].row =  row;
   fakePos[idx].col =  col;
   fakePos[idx].dir = (t == ORDER_TYPE_BUY ? +1 : -1);
   fakePos[idx].profit = 0.0;
   ok = true;
#else
   ok = (t == ORDER_TYPE_BUY)
        ? trade.Buy (InpLot, InpSymbol, price, 0, 0, Cmnt(row,col))
        : trade.Sell(InpLot, InpSymbol, price, 0, 0, Cmnt(row,col));
#endif
   if(!ok) return false;

   /*――― ④ 内部ステート更新 ―――*/
   colTab[col].posCnt++;
   colTab[col].lastDir = (t == ORDER_TYPE_BUY ? +1 : -1);
   if(isAltFirst){
      // 交互列１本目の参照行・基準方向を記録
      colTab[col].altRefRow = row;
      colTab[col].altRefDir = colTab[col].lastDir;
   }

   /*――― ⑤ デバッグログ ―――*/
   if(InpDbgLog)
      PrintFormat("[NEW] r=%d c=%u role=%d dir=%s ALTfirst=%d posCnt=%u",
                  row, col, colTab[col].role,
                  (t==ORDER_TYPE_BUY ? "Buy" : "Sell"),
                  isAltFirst, colTab[col].posCnt);

   return true;
}

//──────────────── Trend-pair 作成ヘルパー ────────────────────────
void CreateTrendPair(int row)
{
   // 次の２列をトレンドペアとして予約
   uint b = nextCol++;
   uint s = nextCol++;
   colTab[b].id   = b;  colTab[b].role = ROLE_TREND;
   colTab[s].id   = s;  colTab[s].role = ROLE_TREND;
   trendBCol = b;  trendSCol = s;
   // 実際のオーダーを発注
   Place(ORDER_TYPE_BUY ,  b, row);
   Place(ORDER_TYPE_SELL, s, row);
}

//──────────────── SafeRollTrendPair ─────────────────────────────────
// ローカル curRow 引数を削除し、必ずグローバル curRow を使う
void SafeRollTrendPair(int dir)
{
    // グローバル curRow から前行を計算
    int prevRow = curRow - dir;

    // 前行のトレンドペアをクローズ（ALT 列は除外）
    for(int i = PositionsTotal() - 1; i >= 0; --i)
    {
        if(!SelectPosByIndex(i)) continue;
        int r; uint c;
        if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;
        if(r == prevRow && (c == trendBCol || c == trendSCol))
            if(trade.PositionClose(PositionGetTicket(i)))
                colTab[c].posCnt--;
    }

    // グローバル curRow を使って新規発注
    Place(ORDER_TYPE_BUY ,  trendBCol, curRow);
    Place(ORDER_TYPE_SELL, trendSCol, curRow);
}

ENUM_ORDER_TYPE AltDir(uint col)
{
   int diff = curRow - colTab[col].altRefRow;
   bool even=((diff&1)==0);
   int dir=even?colTab[col].altRefDir:-colTab[col].altRefDir;
   return (dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
}

/*―――― Profit 列決済 & r-1 Sell 再建て ――――*/
void CheckProfitClose()
{
  if(InpDbgLog)
   PrintFormat("▶ CheckProfitClose  bid=%.5f  trigger=%.5f  active=%s",
               CurBidUT(),
               basePrice + (profit.refRow - 1) * GridSize,
               profit.active ? "true":"false");

  
   if(!profit.active) return;

   const double trigger = basePrice + (profit.refRow - 1) * GridSize;
   if(CurBidUT()> trigger + 1e-9)
      return;                               // まだトリガに達していない

   /* ① 利確列を全クローズ */
   uint closed = 0;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      if(!SelectPosByIndex(i)) continue;
      int r; uint c;
      if(!Parse(PositionGetString(POSITION_COMMENT),r,c) || c!=profit.profitCol) continue;
      if(trade.PositionClose(PositionGetTicket(i)))
      { colTab[c].posCnt--; ++closed; }
   }
   if(closed==0) return;                    // 何も無ければ抜ける

   /* ② r-1 行に Sell を 1 本だけ再建て */
   const int newRow = profit.refRow - 1;
   Place(ORDER_TYPE_SELL, profit.rebuildCol, newRow, true);
   colTab[profit.rebuildCol].role = ROLE_ALT;

   if(InpDbgLog)
      PrintFormat("[PROFIT-CLOSE] col=%u closed=%u → Sell re-built in col=%u row=%d",
                  profit.profitCol, closed, profit.rebuildCol, newRow);

   profit.active = false;                  // 次サイクルへ
}


//──────────────── Break‑Even Close (WeightedClose) ─────────────────
void CheckWeightedClose()
{
    // アカウント通貨に換算した近ゼロ判定閾値（約0.5 pip相当）
    double tickVal   = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
    double epsProfit = tickVal * InpLot * 0.5;

    // 全 Alternate 列をチェック
    for(uint c = 1; c < nextCol; c++)
    {
        // ROLE_ALT かつポジ数 ≥3 の奇数のみ対象
        if(colTab[c].role != ROLE_ALT || colTab[c].posCnt < 3 || (colTab[c].posCnt & 1) == 0)
            continue;

        double sumProfit   = 0.0;
        int    netDirCount = 0;
        int    minBuyRow   = INT_MAX;
        int    maxSellRow  = INT_MIN;

        // ポジション情報とチケットを収集
        ulong tickets[128];
        int   n = 0;
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(!SelectPosByIndex(i)) 
                continue;
            int r; uint col;
            if(!Parse(PositionGetString(POSITION_COMMENT), r, col) || col != c) 
                continue;

            // P/L 合計
            double prof = PositionGetDouble(POSITION_PROFIT);
            sumProfit += prof;

            // 売買方向カウント＆最有利行を記録
            long type = PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
            {
                netDirCount++;
                minBuyRow = MathMin(minBuyRow, r);
            }
            else
            {
                netDirCount--;
                maxSellRow = MathMax(maxSellRow, r);
            }

            tickets[n++] = PositionGetTicket(i);
        }
        if(n == 0) 
            continue;

        // ブレイクイーブン判定：合計 P/L ≥ –epsProfit
        if(sumProfit >= -epsProfit)
        {
            // 残すポジションの行を決定
            int keepRow = (netDirCount > 0 ? minBuyRow : maxSellRow);

            uint closedCount = 0;
            // 全ポジションをループし、keepRow 以外をクローズ
            for(int k = 0; k < n; k++)
            {
                ulong tk = tickets[k];
                if(!PositionSelectByTicket(tk)) 
                    continue;
                int r; uint col;
                if(Parse(PositionGetString(POSITION_COMMENT), r, col)
                   && col == c && r == keepRow)
                {
                    // このポジは保持
                    continue;
                }
                if(trade.PositionClose(tk))
                {
                    closedCount++;
                    colTab[c].posCnt--;
                }
            }
            // 再エントリー抑止のため現在行を記録
            altClosedRow[c] = lastRow;

            // 全ポジ消滅時は列を初期化
            if(colTab[c].posCnt == 0)
                colTab[c].role = ROLE_PENDING;

            if(InpDbgLog)
                PrintFormat("WeightedClose BE col=%u | Total P/L=%.2f | closed=%u",
                            c, sumProfit, closedCount);
        }
    }
}

//===== 補助関数: カラム内すべてのポジションを閉じる ==================
void CloseEntireCol(uint col)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetTicket(i)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      int r; uint c;
      if(!Parse(cmt, r, c)) continue;
      if(c != col) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      trade.PositionClose(ticket);
   }
}

//──────────────── CheckTargetEquity() ──────────────────
void CheckTargetEquity()
{
  // UNIT_TEST 時は本物の口座残高判定をスキップ
#ifdef UNIT_TEST
  return;
#endif
   double cur=AccountInfoDouble(ACCOUNT_EQUITY);
   if(cur-startEquity < InpTargetEquity - 1e-9) return;
   for(int i=PositionsTotal()-1;i>=0;i--) if(SelectPosByIndex(i)) trade.PositionClose(PositionGetTicket(i));
   if(InpDbgLog) Print("Target equity reached → reset");
   ClearColTab(); ArrayInitialize(altClosedRow,-9999);
   nextCol=1; trendBCol=trendSCol=0; lastRow=0; trendSign=0;
   basePrice=rowAnchor=CurBidUT();
   colTab[1].id=1; colTab[1].role=ROLE_TREND; colTab[2].id=2; colTab[2].role=ROLE_TREND;
   trendBCol=1; trendSCol=2; nextCol=3;
   Place(ORDER_TYPE_BUY ,trendBCol,0);
   Place(ORDER_TYPE_SELL,trendSCol,0);
   startEquity=cur;
}
 void UpdateAlternateCols()
 {
     // グローバル curRow, dir, seed は不要。ここでは curRow を使ってループ
     for(uint c = 1; c < nextCol; ++c)
     {
         if(colTab[c].role != ROLE_ALT) continue;
         if(altClosedRow[c] == curRow) continue;  // 直前クローズ行はスキップ
         Place(AltDir(c), c, curRow);
     }
 }

#ifdef UNIT_TEST
//─── ダミー損益を毎ステップ更新 ─────────────────
void UpdateFakeProfits()
{
   double bid = CurBidUT();
   for(int i = 0; i < fakeCnt; ++i)
   {
      double entryPrice = basePrice + fakePos[i].row * GridSize;
      fakePos[i].profit = (bid - entryPrice) * fakePos[i].dir; // ロット換算は簡略
   }
}
#endif
// ----------------------------------------------------------------
//  ▼▼▼ ここから UNIT_TEST ブリッジ ▼▼▼
#ifdef UNIT_TEST
#define NO_ROW   (-9999)
   // --- 全リセット（Script 起動のたび呼ばれる） --------------
   
   // --- Script ↔ EA の発注橋渡し ------------------------------
   bool UT_Place(int type,int col,int row,bool isAltFirst)
   {
      ENUM_ORDER_TYPE ot = (type==0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      return Place(ot,col,row,isAltFirst);
   }

   // --- 列単位／行単位の決済 -----------------------------------
   void UT_CloseCol(uint col,int row)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!SelectPosByIndex(i)) continue;
         int r; uint c;
         if(!Parse(PositionGetString(POSITION_COMMENT),r,c)
            || c!=col) continue;
         if(row!=NO_ROW && r!=row) continue;       // 行指定ありなら一致のみ
         if(trade.PositionClose(PositionGetTicket(i)))
             colTab[c].posCnt--;
      }
   }

   // --- 最低限の整合性チェック ---------------------------------
   bool AssertState(string msg)
   {
    // ―― 同セル重複ポジ禁止 ―――――――――――――――
       static int cellHit[MAX_COL+2][201];        // [-100‥+100] なら 201
       ArrayInitialize(cellHit,0);

       bool ok = true;                       // ← 先頭で毎回初期化

   /*―――― ⑥  Weighted-Close 後の整合性チェック ――――*/

   for(uint c=1;c<nextCol;++c)            // ←★ ここで “最初の for” を閉じる
   {
      // “この Step で WeightedClose が発火した” 目印
      if(altClosedRow[c]!=lastRow) continue;

      // ① ポジションが残っていないか？
      if(colTab[c].posCnt!=0)
      {
         PrintFormat("❌ WEIGHTED-CLOSE leak  col=%u  posCnt=%u",c,colTab[c].posCnt);
         ok=false;
      }
    /*―――― ⑦  Safe-Roll 後の TREND ペア健全性チェック ――――
          ・現行 TREND ペア (trendBCol / trendSCol) は
               lastRow にポジが 1 本ずつ
          ・その 1 行前 (lastRow-trendSign) には残っていない
    */
    if(trendBCol && trendSCol && trendSign!=0)
    {
       const int prev = lastRow - trendSign;
       int cntB=0, cntS=0, cntPrevB=0, cntPrevS=0;

       for(int i=PositionsTotal()-1;i>=0;--i)
       {
          if(!SelectPosByIndex(i)) continue;
          int r; uint c;
          if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
          if(c==trendBCol){ if(r==lastRow) cntB++;   if(r==prev) cntPrevB++; }
          if(c==trendSCol){ if(r==lastRow) cntS++;   if(r==prev) cntPrevS++; }
       }

       if(cntB!=1 || cntS!=1 || cntPrevB>0 || cntPrevS>0)
       {
          PrintFormat("❌ SAFEROLL mismatch  r=%d  B:%d/%d  S:%d/%d",
                      lastRow,cntB,cntPrevB,cntS,cntPrevS);
          ok = false;
       }
    }
        /*―――― ⑧  Profit-Close／Weighted-Close 事後チェック ――――*/
    for(uint c=1;c<nextCol;++c)
    {
       // Profit-Close が “直前 Step” で終わった列
       if(profit.active==false && profit.profitCol==c)
       {
          if(colTab[c].posCnt!=0 || colTab[c].role!=ROLE_ALT)
          {
             PrintFormat("❌ PROFIT-CLOSE leak  col=%u  cnt=%u  role=%d",
                         c,colTab[c].posCnt,colTab[c].role);
            ok=false;
          }
       }

       // Weighted-Close が “直前 Step” で走った列
       if(altClosedRow[c]==lastRow &&
          (colTab[c].posCnt!=0 || colTab[c].role!=ROLE_PENDING))
       {
          PrintFormat("❌ WEIGHTED-CLOSE leak  col=%u  cnt=%u  role=%d",
                      c,colTab[c].posCnt,colTab[c].role);
          ok=false;
       }
    }
 
   /*―――― ⑨ 旧ロジック：role / DUP-CELL / PROFIT-列漏れ ――――*/
      if(colTab[c].role!=ROLE_PENDING)
      {
         PrintFormat("❌ WEIGHTED-CLOSE role mismatch  col=%u  role=%d",c,colTab[c].role);
         ok=false;
      }
   }
      for(int i=PositionsTotal()-1;i>=0;--i)
      {
         if(!SelectPosByIndex(i)) continue;
         int r; uint c; if(!Parse(PositionGetString(POSITION_COMMENT),r,c)) continue;
         if(r<-100 || r>100 || c>MAX_COL)        // 範囲外は無視
            continue;
            // Profit 列なのに posCnt==0 → rebuild Sell がない ＝バグ
         if(colTab[c].role==ROLE_PROFIT && colTab[c].posCnt==0)
         {
            Print("❌ PROFIT-CLOSE leak col=",c);  return(false); }

         if(cellHit[c][r+100]++)
         {                                       // 既に 1 件以上 → 重複
            Print("❌ DUP-CELL DETECTED  r=",r," c=",c,"  msg=",msg);
            return(false);
         }
      }
      return ok;
   }
#endif
//  ▲▲▲ ここまで UNIT_TEST ブリッジ ▲▲▲
// ----------------------------------------------------------------

//───────────────────────────────────────────────────────────────
int OnInit()
{
   GridSize=InpGridSize;
   basePrice=rowAnchor=CurBidUT();
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

//───────────────────────────────────────────────────────────────
void OnTick()
{
   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   /*――― 上昇方向 ―――*/
   while(bid >= rowAnchor + GridSize - 1e-9)
   {
      StepRow(lastRow + 1, +1);
      rowAnchor += GridSize;
   }

   /*――― 下降方向 ―――*/
   while(bid <= rowAnchor - GridSize + 1e-9)
   {
      StepRow(lastRow - 1, -1);
      rowAnchor -= GridSize;
   }

   CheckProfitClose();
   CheckWeightedClose();
   CheckTargetEquity();
}
