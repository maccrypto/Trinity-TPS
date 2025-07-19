//--- TrinitySim.mqh  (新規作成)
// シミュレーション補助関数群。EA と Replay スクリプト双方で共有。

#ifndef __TRINITY_SIM_MQH__
#define __TRINITY_SIM_MQH__

// ここで lastRow, StepRow が他ファイルで宣言済み前提。
// もしコンパイル順で未宣言なら extern 宣言を追加:
// extern int lastRow;
// void StepRow(const int newRow, const int dir);

void SimulateMove(const int targetRow)
{
   PrintFormat("DBG SimMove: enter target=%d  lastRow=%d", targetRow, lastRow);

   if(targetRow == lastRow)
   {
      PrintFormat("DBG SimMove: target==lastRow – skip");
      PrintFormat("✅ SimulateMove(%d) END", targetRow);
      return;
   }

   int dir = (targetRow > lastRow ? 1 : -1);
   int safety = 100;

   while(lastRow != targetRow && safety-- > 0)
   {
      int next = lastRow + dir;
      PrintFormat("DBG SimMove: about to StepRow  r=%d  lastRow(before)=%d  dir=%d",
                  next, lastRow, dir);

      StepRow(next, dir);

      PrintFormat("DBG SimMove: after StepRow  lastRow(after)=%d", lastRow);

      if(lastRow == targetRow)
      {
         PrintFormat("DBG SimMove: reached target=%d – break", targetRow);
         break;
      }
   }

   if(safety <= 0 && lastRow != targetRow)
      PrintFormat("DBG SimMove: SAFETY BREAK (lastRow=%d target=%d)", lastRow, targetRow);

   PrintFormat("✅ SimulateMove(%d) END", targetRow);
}

#endif // __TRINITY_SIM_MQH__
