#ifndef __TRINITY_SIM_MQH__
#define __TRINITY_SIM_MQH__

// ここは宣言ヘッダのみ。実体は Trinity.mq5 に 1 つだけ持つ。
extern int lastRow;

// StepRow 実体は Trinity.mq5
void StepRow(const int newRow, const int dir);

// SimulateMove 実体は Trinity.mq5
void SimulateMove(const int targetRow);

#endif // __TRINITY_SIM_MQH__
