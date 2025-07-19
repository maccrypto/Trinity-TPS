//+------------------------------------------------------------------+
//| TrinityReplayTest.mq5                                           |
//| Replay harness: row sequence → simulated moves & half-steps     |
//| 改訂版 (include 方式)                                           |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

// === Include shared simulation helpers (SimulateMove 等) =========
#include "TrinitySim.mqh"     // SimulateMove をここから取得

// --- 他の共有関数が別ヘッダならここで追加 ---
// #include "TrinityExtra.mqh"

// === もし ResetAll や SimulateHalfStep がまだ共有化されていない場合の extern ====
// 既存 EA (Trinity.mq5) 内にあるなら、暫定で extern 宣言してリンク。
// 後で TrinitySim.mqh に本体移動すれば extern は不要。
extern void ResetAll();
extern void SimulateHalfStep();

// === Inputs ======================================================
// 移動行シーケンス（カンマ区切り整数）
// 例: "0,1,2,1,0,1,2,1,0"
input string InpRowsSequence = "0,1,2,1,0,1,2,1,0";

// ハーフステップを各移動後に挿入するか
input bool   InpDoHalfStep   = true;

// 初期化時にリセットするか
input bool   InpResetOnStart = true;

// デバッグ詳細ログ
input bool   InpVerbose      = true;

// === 内部状態 ====================================================
static int   rows[];          // 解析後の行配列
static int   rowsCount = 0;

//+------------------------------------------------------------------+
//| 文字列トリム補助                                                 |
//+------------------------------------------------------------------+
string Trim(const string s)
{
   int a = 0, b = StringLen(s)-1;
   while(a <= b && (ushort)StringGetCharacter(s,a) <= ' ') a++;
   while(b >= a && (ushort)StringGetCharacter(s,b) <= ' ') b--;
   if(b < a) return "";
   return StringSubstr(s, a, b - a + 1);
}

//+------------------------------------------------------------------+
//| カンマ区切り整数列パース                                         |
//+------------------------------------------------------------------+
bool ParseRows(const string csv)
{
   ArrayFree(rows);
   rowsCount = 0;
   string work = csv;
   // 安全: 全角カンマを半角へ
   StringReplace(work, "，", ",");
   // 連続カンマ簡易正規化
   while(StringFind(work, ",,") >= 0) StringReplace(work, ",,", ",");
   // 末尾カンマ除去
   while(StringLen(work) > 0 && StringGetCharacter(work, StringLen(work)-1) == ',')
      work = StringSubstr(work, 0, StringLen(work)-1);

   int start = 0;
   while(true)
   {
      int pos = StringFind(work, ",", start);
      string token;
      if(pos < 0)
      {
         token = Trim(StringSubstr(work, start));
      }
      else
      {
         token = Trim(StringSubstr(work, start, pos - start));
      }
      if(token != "")
      {
         int val = (int)StringToInteger(token);
         int n   = ArraySize(rows);
         ArrayResize(rows, n+1);
         rows[n] = val;
      }
      if(pos < 0) break;
      start = pos + 1;
   }
   rowsCount = ArraySize(rows);
   if(InpVerbose)
      PrintFormat("Rows parsed count=%d raw=\"%s\"", rowsCount, csv);
   return (rowsCount > 0);
}

//+------------------------------------------------------------------+
//| 実行エントリ (Script Main)                                      |
//+------------------------------------------------------------------+
void OnStart()
{
   if(InpResetOnStart)
   {
      if(InpVerbose) Print("⚙️  ResetAll()");
      ResetAll();
   }

   if(!ParseRows(InpRowsSequence))
   {
      Print("❌ Rows parse failed (empty?)");
      return;
   }

   if(InpVerbose)
      PrintFormat("⚙️ Replay start  sequence length=%d", rowsCount);

   // 最初の行を “起点” として SimulateMove( same ) を呼ぶ必要はないので
   // 2 番目以降の各ターゲット行へ移動
   for(int i=0; i<rowsCount; ++i)
   {
      int target = rows[i];
      PrintFormat("➡ SimulateMove(%d)", target);
      SimulateMove(target);

      if(InpDoHalfStep)
      {
         Print("➡ SimulateHalfStep()");
         SimulateHalfStep();
      }
   }

   Print("✅ Replay end");
}
