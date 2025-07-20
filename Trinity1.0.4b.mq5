//+------------------------------------------------------------------+
//| Trinity.mq5 – Generic GridTPS Entry Core  (rev T1.0.4)           |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//────────────────────────── Inputs ────────────────────────────────
input string InpSymbol       = "USDJPY";
input double InpLot          = 0.01;
input double InpGridSize     = 0.50;
input double InpTargetEquity = 5000.0;
input uint   InpMagic        = 20250607;
input bool   InpDbgLog       = true;

//────────────────────────── Types & Globals ────────────────────────
enum ColRole { ROLE_PENDING, ROLE_PROFIT, ROLE_ALT, ROLE_TREND };
struct ColState {
    uint    id;
    ColRole role;
    int     lastDir;
    int     altRefRow;
    int     altRefDir;
    uint    posCnt;
};
#define MAX_COL 2048
static ColState colTab[MAX_COL+2];
static int   altClosedRow[MAX_COL+2];
static double GridSize=0.0, basePrice=0.0, rowAnchor=0.0, startEquity=0.0;
static int    lastRow=0, trendSign=0;
static uint   nextCol=1, trendBCol=0, trendSCol=0;
struct ProfitInfo { bool active; uint col; int refRow; };
static ProfitInfo profit = { false, 0, 0 };

//──────────────────────── Utility Functions ──────────────────────
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
}

//──────────────── Market Order Helper ────────────────────────────
bool Place(ENUM_ORDER_TYPE orderType, uint col, int row, bool isAltFirst = false) {
    // Do not place if a position at this exact cell (row,col) already exists
    if(HasPos(col, row)) return false;
    // Determine order price (use current Ask for Buy, Bid for Sell)
    double price = (orderType == ORDER_TYPE_BUY) 
                   ? SymbolInfoDouble(InpSymbol, SYMBOL_ASK)
                   : SymbolInfoDouble(InpSymbol, SYMBOL_BID);
    bool ok = false;
    if(orderType == ORDER_TYPE_BUY)
        ok = trade.Buy(InpLot, InpSymbol, price, 0, 0, Cmnt(row, col));
    else 
        ok = trade.Sell(InpLot, InpSymbol, price, 0, 0, Cmnt(row, col));
    // Post-order handling on success
    if(ok) {
        colTab[col].posCnt++;
        colTab[col].lastDir = (orderType == ORDER_TYPE_BUY ? +1 : -1);
        if(isAltFirst) {
            // For first entry in an Alternate column, set reference row and direction
            colTab[col].altRefRow = row;
            colTab[col].altRefDir = -colTab[col].lastDir;  // store opposite of initial trade direction
        }
        if(InpDbgLog) {
            PrintFormat("[NEW] r=%d c=%u role=%d dir=%s altFirst=%d posCnt=%u",
                        row, col, colTab[col].role,
                        (orderType == ORDER_TYPE_BUY ? "Buy" : "Sell"),
                        isAltFirst, colTab[col].posCnt);
        }
    }
    return ok;
}

// Forward declarations for functions called ahead
void SafeRollTrendPair(int curRow, int dir);
void UpdateAlternateCols(int curRow);

//──────────────── Trend Pair Management ──────────────────────────
void CreateTrendPair(int row) {
    // Create a new trend pair (one Buy and one Sell) at the given row
    uint b = nextCol++;
    uint s = nextCol++;
    if(s > MAX_COL) {
        Print("Error: column overflow in CreateTrendPair");
        return;
    }
    colTab[b].id = b; colTab[b].role = ROLE_TREND;
    colTab[s].id = s; colTab[s].role = ROLE_TREND;
    trendBCol = b;
    trendSCol = s;
    Place(ORDER_TYPE_BUY,  b, row);  // open Buy leg
    Place(ORDER_TYPE_SELL, s, row);  // open Sell leg
}
void FixTrendPair(int dir, int curRow) {
    // Pivot detected – convert current trend pair roles and mark profit/alt
    if(trendBCol == 0 || trendSCol == 0) return;
    if(dir > 0) {
        // Trend pivot up: losing side was Sell, winning side Buy
        colTab[trendBCol].role = ROLE_PROFIT;   // Buy side becomes Profit (should close at pivot)
        colTab[trendSCol].role = ROLE_ALT;      // Sell side becomes Alternate
        colTab[trendSCol].altRefRow = curRow;
        colTab[trendSCol].altRefDir = -colTab[trendSCol].lastDir;  // flip direction for alt sequence
        profit.active = false;  // profit side (Buy) will be handled immediately
    } else {
        // Trend pivot down: losing side was Buy, winning side Sell
        colTab[trendSCol].role = ROLE_PROFIT;   // Sell side becomes Profit
        colTab[trendBCol].role = ROLE_ALT;      // Buy side becomes Alternate
        colTab[trendBCol].altRefRow = curRow;
        colTab[trendBCol].altRefDir =  colTab[trendBCol].lastDir;  // do not flip for downtrend alt (alternate will start same direction)
        profit.active = true;
        profit.col  = trendSCol;   // track the Sell (profit) column and pivot row
        profit.refRow = curRow;
    }
    // Reset trend pair markers (they'll be recreated for new trend)
    trendBCol = trendSCol = 0;
}
void SafeRollTrendPair(int curRow, int dir) {
    // Continue trend: close previous row's trend positions and open new ones at curRow
    int prevRow = curRow - dir;
    bool closedB = false, closedS = false;
    // Close existing trend pair positions from the previous row
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!SelectPosByIndex(i)) continue;
        int r; uint c;
        if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;
        ulong tk = PositionGetTicket(i);
        if(r == prevRow && c == trendBCol && trade.PositionClose(tk)) {
            closedB = true;
            colTab[c].posCnt--;
        }
        if(r == prevRow && c == trendSCol && trade.PositionClose(tk)) {
            closedS = true;
            colTab[c].posCnt--;
        }
    }
    if(!(closedB && closedS)) {
        // If we failed to close both legs, do not open new ones (avoid doubling positions)
        return;
    }
    // Open a new Buy/Sell pair at the current row (Place has duplicate-guard by HasPos)
    Place((dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), trendBCol, curRow);
    Place((dir > 0 ? ORDER_TYPE_SELL: ORDER_TYPE_BUY ), trendSCol, curRow);
    if(InpDbgLog) PrintFormat("SafeRollTrendPair rolled to Row %d", curRow);
}

//──────────────── Alternate Column Helpers ───────────────────────
ENUM_ORDER_TYPE AltDir(uint col, int curRow) {
    // Determine the order type (Buy/Sell) for the alternate column based on row parity
    int diff = curRow - colTab[col].altRefRow;
    int parity = diff >= 0 ? diff % 2 : (-diff) % 2;  // even=0, odd=1 (handles negative diff)
    int dir = (parity == 0 ? colTab[col].altRefDir : -colTab[col].altRefDir);
    return (dir == +1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
}
void UpdateAlternateCols(int curRow) {
    // On each new row movement, add counter-trend positions to alternate columns
    for(uint c = 1; c < nextCol; c++) {
        if(colTab[c].role != ROLE_ALT) continue;
        // If this alternate column recently closed at this row, skip re-entry until next row
        if(curRow == altClosedRow[c]) continue;
        // Place a new position in alternate column c at curRow, alternating buy/sell direction
        ENUM_ORDER_TYPE newType = AltDir(c, curRow);
        Place(newType, c, curRow);
        // Mark the first entry in an alt column with altFirst flag if posCnt was 0 prior (not strictly needed here since alt becomes ALT after pivot with posCnt=1)
    }
}

//──────────────── Profit Close (Partial Take-Profit at Pivot) ────
void CheckProfitClose() {
    if(!profit.active) return;
    // Only close profit position when price has moved at least one grid beyond the pivot reference
    if(trendSign < 0) {
        // Downtrend: wait until we've moved down at least one row below the pivot
        if(lastRow > profit.refRow - 1) return;
    } else if(trendSign > 0) {
        // Uptrend: wait until moved up at least one row above the pivot
        if(lastRow < profit.refRow + 1) return;
    }
    // Close all positions in the profit column
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!SelectPosByIndex(i)) continue;
        int r; uint c;
        if(!Parse(PositionGetString(POSITION_COMMENT), r, c)) continue;
        if(c == profit.col && trade.PositionClose(PositionGetTicket(i))) {
            colTab[c].posCnt--;
        }
    }
    if(InpDbgLog) {
        PrintFormat("ProfitClose: closed Profit col %u at pivot row %d", profit.col, profit.refRow);
    }
    // Deactivate profit tracking and initiate a new alternate position in base column (col 1) to continue strategy
    profit.active = false;
    Place(ORDER_TYPE_SELL, 1, profit.refRow - 1, true);
}

//──────────────── Break-Even Close (WeightedClose) ───────────────
void CheckWeightedClose() {
    /* Determine dynamic near-zero profit threshold in account currency */
    double tickVal = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
    double epsProfit = tickVal * InpLot * 0.5;  // ~0.5 pip in account currency
    for(uint c = 1; c < nextCol; c++) {
        if(colTab[c].role != ROLE_ALT || colTab[c].posCnt < 3) continue;       // only consider alternate cols with ≥3 positions
        if((colTab[c].posCnt & 1) == 0) continue;                              // skip if even number of positions (must be odd)
        double sumProfit = 0.0;
        int netDirCount = 0;
        int minBuyRow =  999999999, maxSellRow = -999999999;
        // Accumulate total profit for column c and track extreme position rows
        ulong tickets[128];  int n = 0;
        for(int i = PositionsTotal() - 1; i >= 0; i--) {
            if(!SelectPosByIndex(i)) continue;
            int r; uint col;
            if(!Parse(PositionGetString(POSITION_COMMENT), r, col)) continue;
            if(col != c) continue;
            // Summation
            sumProfit += PositionGetDouble(POSITION_PROFIT);
            // Count net direction and find lowest Buy/highest Sell rows
            long type = PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY) {
                netDirCount++;
                if(r < minBuyRow) minBuyRow = r;
            } else if(type == POSITION_TYPE_SELL) {
                netDirCount--;
                if(r > maxSellRow) maxSellRow = r;
            }
            // Store ticket for closing later
            tickets[n++] = PositionGetTicket(i);
        }
        if(n == 0) continue;  // no positions found (safety check)
        // Check break-even condition: total P/L >= 0 (allow tiny negative within eps for safety)
        if(sumProfit >= -epsProfit) {
            // Determine which position to keep (most favorable)
            int keepRow = -999999999;
            if(netDirCount > 0) {
                // net long positions -> keep lowest-price Buy (min row index)
                keepRow = minBuyRow;
            } else if(netDirCount < 0) {
                // net short positions -> keep highest-price Sell (max row index)
                keepRow = maxSellRow;
            }
            uint closedCount = 0;
            // Close all positions except the one at keepRow
            for(int k = 0; k < n; k++) {
                if(!PositionSelectByTicket(tickets[k])) continue;
                int r; uint cc;
                if(Parse(PositionGetString(POSITION_COMMENT), r, cc)) {
                    if(r == keepRow && cc == c) {
                        // skip closing this position (keep it)
                        continue;
                    }
                }
                if(trade.PositionClose(tickets[k])) {
                    closedCount++;
                    colTab[c].posCnt--;
                }
            }
            // Mark this column as just break-even closed at this row
            altClosedRow[c] = lastRow;  
            // If all positions were closed (posCnt goes to 0, which can happen if logic mis-identified keepRow), reset column role
            if(colTab[c].posCnt == 0) {
                colTab[c].role = ROLE_PENDING;
            }
            if(InpDbgLog) {
                PrintFormat("WeightedClose BE col=%u | Total P/L=%.2f | closed=%u positions", c, sumProfit, closedCount);
            }
        }
    }
}

//──────────────── Equity Target Check ────────────────────────────
void CheckTargetEquity() {
    double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(curEquity - startEquity < InpTargetEquity - 1e-9) return;
    // Profit target reached – close ALL positions and reset the engine state
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(SelectPosByIndex(i)) {
            trade.PositionClose(PositionGetTicket(i));
        }
    }
    if(InpDbgLog) {
        PrintFormat("Target %.2f reached! Equity %.2f – resetting EA state.", InpTargetEquity, curEquity);
    }
    // Reset internal state for a fresh cycle
    ClearColTab();
    ArrayInitialize(altClosedRow, -9999);
    nextCol    = 1;
    trendBCol  = 0;
    trendSCol  = 0;
    lastRow    = 0;
    trendSign  = 0;
    // Reinitialize base price, anchor, and start a new initial trend pair
    basePrice = rowAnchor = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
    colTab[1].id = 1; colTab[1].role = ROLE_TREND;
    colTab[2].id = 2; colTab[2].role = ROLE_TREND;
    trendBCol = 1; trendSCol = 2;
    nextCol   = 3;
    Place(ORDER_TYPE_BUY,  trendBCol, 0);
    Place(ORDER_TYPE_SELL, trendSCol, 0);
    startEquity = curEquity;
}

//──────────────── Row Step Handler ───────────────────────────────
void StepRow(int newRow, int dir) {
    bool pivot = (trendSign != 0 && dir != trendSign);
    if(InpDbgLog) {
        PrintFormat("StepRow: newRow=%d dir=%d pivot=%s", newRow, dir, pivot ? "YES" : "NO");
    }
    if(pivot || trendSign == 0) {
        // Trend direction changed (or first step) – handle pivot
        FixTrendPair(dir, newRow);
        CreateTrendPair(newRow);
    } else {
        // Trend continues in same direction – roll the trend pair forward
        SafeRollTrendPair(newRow, dir);
    }
    // Update trend sign after handling row step
    trendSign = dir;
    // Update current lastRow
    lastRow = newRow;
    // If price has moved beyond the current row band, adjust anchor and fill intermediate rows
    // (Not explicitly needed here, as StepRow is likely called iteratively in OnTick loop)
}

//+------------------------------------------------------------------+
