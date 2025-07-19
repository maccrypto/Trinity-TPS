//+------------------------------------------------------------------+
//| TrinityReplayTest.mq5  ― 行番号を手動で再生するだけの簡易スクリプト |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs   // スクリプト用 Inputs を自動表示

//――――――――――――――――――――――――――――――
// 他 EA の export 関数をインポート
//（Trinity.mq5 をビルドして生成された Trinity.ex5 と同じフォルダに置く）
//――――――――――――――――――――――――――――――
#import "Trinity.ex5"
void ResetAll();             // export void ResetAll()
void SimulateMove(int row);  // export void SimulateMove(int)
void SimulateHalfStep();     // export void SimulateHalfStep()
#import
//――――――――――――――――――――――――――――――

// 入力：カンマ区切りで行番号シーケンスを渡す
input string Rows = "0,1,2,3,2,1,0";

void OnStart()
{
   Print("⚙️ Replay start");

   // ① 完全リセット
   ResetAll();

   // ② Rows を ["0","1","2",…] に分割
   string list[];
   int n = StringSplit(Rows, ',', list);
   PrintFormat("Rows raw=\"%s\" n=%d", Rows, n);

   // ③ １行ずつ SimulateMove() を呼び出し
   for(int i = 0; i < n; i++)
   {
      int row = (int)StringToInteger(list[i]);
      PrintFormat("➡ SimulateMove(%d)", row);
      SimulateMove(row);
      PrintFormat("✅ SimulateMove(%d) END", row);
      
   Print("➡ SimulateHalfStep()");
   SimulateHalfStep();
   Print("✅ SimulateHalfStep END");
   }

   Print("✅ Replay end");
}
