//--- TrinitySim.mqh : シミュレーション補助関数群（Include 方式）

#ifndef __TRINITY_SIM_MQH__
#define __TRINITY_SIM_MQH__

// 他ファイル（Trinity.mq5）側で定義済みのグローバル / 関数を参照。
// 未定義エラーが出る場合のみコメントアウトを外して使用してください。
extern int  lastRow;                 // Trinity.mq5 で実体を持つこと
void StepRow(const int newRow, const int dir);  // StepRow 本体は Trinity.mq5 側

//==================================================================
// SimulateMove: 指定 targetRow まで lastRow を 1 行ずつ進め StepRow を呼ぶ
//==================================================================
void SimulateMove(const int targetRow)
{
   PrintFormat("DBG SimMove: enter target=%d  lastRow=%d", targetRow, lastRow);

   if(targetRow == lastRow)
   {
      PrintFormat("DBG SimMove: target==lastRow – skip");
      PrintFormat("✅ SimulateMove(%d) END", targetRow);
      return;
   }

   const int dir = (targetRow > lastRow ? 1 : -1);
   int safety    = 100;

   while(lastRow != targetRow && safety-- > 0)
   {
      const int next = lastRow + dir;
      PrintFormat("DBG SimMove: about to StepRow  r=%d  lastRow(before)=%d  dir=%d",
                  next, lastRow, dir);

      StepRow(next, dir);   // StepRow が内部で lastRow を更新する前提

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
