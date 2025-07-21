//──────────────── Weighted‑Close (±0) ───────────────────────────
void CheckWeightedClose()
{
   // テスト環境では CurBidUT() を使う想定
   double bid = CurBidUT();
   double ask = CurBidUT();
   double eps = Point() * 10;  // 10 pips 相当の許容幅

   for(uint c = 1; c < nextCol; c++)
   {
      // ALT 列かつポジション数が奇数 3 以上のみ対象
      if(colTab[c].role != ROLE_ALT || colTab[c].posCnt < 3 || (colTab[c].posCnt & 1) == 0)
         continue;

      double sumDir     = 0.0;
      double sumDirOpen = 0.0;

      // 列 c の全ポジションを集計
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!SelectPosByIndex(i)) continue;
         int r; uint col;
         if(!Parse(PositionGetString(POSITION_COMMENT), r, col) || col != c) continue;

         double price = PositionGetDouble(POSITION_PRICE_OPEN);
         double vol   = PositionGetDouble(POSITION_VOLUME);
         int    type  = (int)PositionGetInteger(POSITION_TYPE);
         double dir   = (type == POSITION_TYPE_BUY ? 1.0 : -1.0);

         sumDir     += dir * vol;
         sumDirOpen += dir * vol * price;
      }

      // 現在の Bid/Ask で理論上の損益ゼロ判定
      double px = (sumDir > 0.0 ? bid : ask);
      if(MathAbs(sumDirOpen - sumDir * px) <= eps)
      {
         PrintFormat("[WEIGHTED] col=%u posCnt=%u px=%.5f",
                     c, colTab[c].posCnt, px);

         // 全クローズ＆ROLE_PENDING へリセット
         CloseEntireCol(c);
         colTab[c].posCnt     = 0;
         colTab[c].role       = ROLE_PENDING;
         colTab[c].altRefRow  = ALT_UNINIT;
         altClosedRow[c]      = curRow;
      }
   }
}
