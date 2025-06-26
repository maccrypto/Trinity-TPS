//+------------------------------------------------------------------+
//|  TPSSetManager.mqh  –  Alternate-column break-even handler       |
//+------------------------------------------------------------------+
#ifndef __TPSSetManager__
#define __TPSSetManager__

#include <Trade\Trade.mqh>

// -- 実体は EA 側で定義。ここでは extern 参照だけ --
extern bool gColIsAlternate[];

CTrade _tpsTrade;

//――― Utility : Magic 番号の下 4 桁から列番号を抽出 ―――
inline int ColFromMagic(long magic) { return (int)(magic % 10000); }

//───────────────────────────────────────────────────────────────
bool CheckAlternateBreakEven(const int col)
{
   if(!gColIsAlternate[col])                // Alternate 列でなければ無視
      return(false);

   double sumDir      = 0.0;
   double sumDirPrice = 0.0;
   ulong  tickets[512];
   int    n = 0;

   //── 当該列のポジションを集計 ────────────────────────
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))                 continue;
      if(ColFromMagic(PositionGetInteger(POSITION_MAGIC)) != col) continue;

      int    dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? +1 : -1);
      double op  = PositionGetDouble (POSITION_PRICE_OPEN);

      sumDir      += dir;
      sumDirPrice += dir * op;
      tickets[n++] = tk;
   }

   // 3 本以上かつ奇数本 & ネットが 0 でないこと
   if(n < 3 || (n & 1) == 0 || MathAbs(sumDir) < 1e-12)
      return(false);

   double be  = sumDirPrice / sumDir;                    // 損益分岐点
   double now = (sumDir > 0)
                ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //── BE 条件を満たしたら全決済 ────────────────────────
   if((sumDir > 0 && now <= be) || (sumDir < 0 && now >= be))
   {
      bool ok = true;
      for(int k = 0; k < n; ++k)
         if(!_tpsTrade.PositionClose(tickets[k]))
            ok = false;

      if(ok)
      {
         gColIsAlternate[col] = false;                  // フラグ解除
         PrintFormat("[TPS] Alternate col %d CLOSED at %.3f (BE)", col, now);
         return(true);
      }
   }
   return(false);
}

#endif  // __TPSSetManager__
