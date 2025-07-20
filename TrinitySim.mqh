//--- TrinitySim.mqh : Simulation helper functions (include style)
#ifndef __TRINITY_SIM_MQH__
#define __TRINITY_SIM_MQH__

// Forward externs (real definitions are in Trinity.mq5)
extern int  lastRow;
void StepRow(const int newRow, const int dir);

#ifndef __TRINITY_SIM_MQH__
#define __TRINITY_SIM_MQH__

extern int  lastRow;
void StepRow(const int newRow, const int dir);

void SimulateMove(const int targetRow);  // ← 本体なし宣言のみ

#endif // __TRINITY_SIM_MQH__

#endif // __TRINITY_SIM_MQH__
