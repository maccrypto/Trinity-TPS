#property strict
#property script_show_inputs

#include <TrinitySim.mqh>
#include <TrinityCore.mqh>      // ← 追加：実体ロジックを取り込む
// ===== 実体定義 =================================================

// ===== 入力 & パターン処理 ======================================
input bool   InpDoHalfStep = true;
input string InpPattern    = "0,1,2,1,0,1,2,1,0";

void Trim(string &s){ StringTrimLeft(s); StringTrimRight(s); }

int LoadPattern(int &arr[])
{
   string patternStr = InpPattern;
   Trim(patternStr);
   if(patternStr == "") return 0;

   string parts[];
   int n = StringSplit(patternStr, ',', parts);
   if(n <= 0) return 0;

   ArrayResize(arr, n);
   for(int i=0;i<n;i++)
   {
      Trim(parts[i]);
      arr[i] = (int)StringToInteger(parts[i]);
   }
   return n;
}
// ===============================================================

void OnStart()
{
   Print("[Replay] start");
   ResetAll();

   int pattern[];
   int n = LoadPattern(pattern);
   if(n == 0)
   {
      Print("Pattern empty – abort.");
      return;
   }

   for(int i=0;i<n;i++)
   {
      int tgt = pattern[i];
      PrintFormat("➡ SimulateMove(%d)", tgt);
      SimulateMove(tgt);

      if(InpDoHalfStep)
      {
         Print("➡ SimulateHalfStep()");
         SimulateHalfStep();
      }
   }

   PrintFormat("[Replay] end lastRow=%d steps=%d", lastRow, StepCount);
}
