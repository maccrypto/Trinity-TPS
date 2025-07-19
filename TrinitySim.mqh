//--- TrinitySim.mqh : Simulation helper functions (include style)
#ifndef __TRINITY_SIM_MQH__
#define __TRINITY_SIM_MQH__

// Forward externs (real definitions are in Trinity.mq5)
extern int  lastRow;
void StepRow(const int newRow, const int dir);

//------------------------------------------------------------------
// SimulateMove: move lastRow stepwise toward targetRow calling StepRow
//------------------------------------------------------------------
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

      StepRow(next, dir);   // StepRow updates lastRow internally

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
