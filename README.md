# Trinity‑TPS Project – Developer Reference  (rev 2025‑07‑02)

> **Audience**  This document is written **for future‐me and for ChatGPT o3**.
> It encodes the *canonical* trading logic so that, whenever memory drifts, we can quickly re‑synchronise and continue development without reinventing, mis‑remembering or breaking things.

---

## 0. Nomenclature – shared by **Trinity** & **TPS**

| Term                                                                                                                                                      | Meaning                                                                                                                                                 |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Grid**                                                                                                                                                  | A fixed price interval `InpGridSize` (e.g. 0.50 JPY). All decisions are expressed in integer multiples of a grid.                                       |
| **Row (r)**                                                                                                                                               | Current price location relative to the **latest Pivot**.                                                                                                |
| `row = ⌊ ( bid – pivotPrice ) / GridSize ⌋`. Positive in the trend direction, negative against it. **Row changes by ±1 every time price moves one grid.** |                                                                                                                                                         |
| **Column (c)**                                                                                                                                            | A *logical* lane that contains one *stack* of positions.                                                                                                |
| Columns are never re‑used; we only increment `nextCol` (1‑based index) when a *new* pair is needed.                                                       |                                                                                                                                                         |
| **Roles**                                                                                                                                                 |                                                                                                                                                         |
| `ROLE_TREND` – the *current* trend‑following Buy/Sell pair (always 2 columns).                                                                            |                                                                                                                                                         |
| `ROLE_ALT` – the counter‑trend “ladder” that alternates side every grid.                                                                                  |                                                                                                                                                         |
| `ROLE_PROFIT` – a former TREND column awaiting a Take‑Profit flush at the next pivot.                                                                     |                                                                                                                                                         |
| `ROLE_PENDING` – a dormant column, emptied by a break‑even close and waiting to be promoted back to TREND.                                                |                                                                                                                                                         |
| **Pivot**                                                                                                                                                 | The *first* row that flips the sign of trend (`dir`) relative to previous movement. **It is *not* the row==0 event**; instead it is `dir != trendSign`. |

---

## 1. Trinity Core Logic  – quick recap

1. **Initialisation** – create a TREND pair on `row 0` (`c1 = Buy`, `c2 = Sell`).
2. **StepRow(newRow, dir)** is the *only* entry point when price crosses a grid:

   * Detect **pivot** (`dir != trendSign`).
   * If a pivot:
     a. `FixTrendPair` demotes the *old* TREND pair → `PROFIT`+`ALT`.
     b. Record `altBCol` / `altSCol` so that the pivot row gets two fresh ALT “seed” orders (`SeedPivotAlts`).
     c. `CreateTrendPair` spawns a brand‑new TREND pair at `newRow`.
   * Else (trend continues): `SafeRollTrendPair` *moves* the TREND pair one row without closing other roles.
   * Every row –

     * `RollAlternateCols` lays **all existing ALT columns** onto the new row using `AltDir()` (alternating Buy/Sell every grid).
     * Empty PENDING columns with no positions are promoted back to TREND (except the one that was just closed at this row).
3. **WeightedClose (Break‑Even)** – when an ALT column accumulates *≥3* positions **and** total P/L ≥ 0 **and** position count is *odd*, close the whole column, mark it PENDING and remember the row in `altClosedRow` (to avoid instant re‑promotion).
4. **Profit Close** – at the first price tick *inside* the pivot grid (`SymbolInfoBid ≤ pivotTarget`), flush the single `ROLE_PROFIT` column, then instantly convert its column into a new ALT seed for the *next* cycle.
5. **SafeRollTrendPair** never deletes the historical TREND columns – it merely closes/opens *their* positions one row higher/lower, keeping the column identity intact (eliminating double‑spread hit that plagued earlier prototypes).

---

## 2. TPS Overlay Logic  – layered *on top* of Trinity

TPS treats every **mountain / valley** created by Trinity as a *Set* and mines additional profit while preserving the net hedged structure.

### 2.1 Set definition

A **Set** begins when Trinity creates a new TREND pair at a pivot (Row 0) and ends once **every position inside that mini‑range except the *cheapest* Buy (or *highest* Sell) has been break‑even‑flushed**.

* Within a Set all rows are labelled sequentially (0, ±1, ±2 …). The example from the journal:
  `0 → 1 → 0 → -1 → 0 → 1 …` shows 3 consecutive Sets.
* TPS mirrors Trinity’s TREND+ALT columns inside **its own columns – c a, b, c, …** (letters start after Trinity’s numeric range for clarity).

### 2.2 TPS trade rules (derived from *TPSLogic test.txt*)

| Journal No. | Event                  | TPS Action                                                                                                 |
| ----------- | ---------------------- | ---------------------------------------------------------------------------------------------------------- |
| **No.1**    | New Set born at Row 0  | Create pair `c1=Buy`, `c2=Sell`.                                                                           |
| **No.2**    | Row +1                 | `c2` (now loss) flips to Buy (ALT rule), *plus* spawn fresh pair `c3=Buy`, `c4=Sell` ready for next pivot. |
| **No.3**    | Price reverts to Row 0 | `c3` turns Sell, spawn `c5=Buy`, `c6=Sell`.                                                                |
| **No.4**    | Row ‑1 pivot           | Old pair becomes Profit+Alt, new pair born `c5/6` etc.                                                     |
| …           | …                      | …                                                                                                          |

The mechanical translation:

1. **Follow Trinity rows 1‑to‑1** but operate in a *disjoint* column namespace.
2. When Row moves **+1** (price up): the *lowest* existing Sell column becomes ALT (close Sell→ open Buy **in the same row**); simultaneously add a new TREND pair one column to the right.
3. When Row moves **‑1**: symmetric to above.
4. **Break‑Even Sweep** – when the aggregate P/L of *all but the extreme Buy/Sell* within the current Set ≥ 0, close them all, leaving only the extreme anchor open (the “cheapest B / highest S”).

### 2.3 Why TPS is an overlay?

* Trinity ensures *continuous market presence* with minimal two‑column structure.<br>
* TPS enters **only if** Trinity has produced a slope (≥ ±1 row), thereby building a *thicker ladder* inside the mini‑range **without altering Trinity’s columns**.
* Closing logic is independent – TPS disposes its positions as soon as their *own* BE rule is met, regardless of Trinity still carrying its ALT ladders.

---

## 3. Implementation Checklist

| Area                   | Trinity                       | TPS                                                                                                           |
| ---------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Column pool**        | Numeric `c1…c2048`            | Alphabetic (or `c1000+`) to avoid clash.                                                                      |
| **StepRow hook**       | Exists (`OnTick` → `StepRow`) | Needs *observer* that subscribes to Trinity’s `lastRow` and `trendSign` and duplicates the logic table above. |
| **Profit Close**       | single‑column, grid‑based     | Set‑wide BE flush (extreme anchor spared).                                                                    |
| **WeightedClose flag** | per ALT column                | *Disabled* inside TPS; BE is managed at Set level.                                                            |
| **Magic numbers**      | `InpMagic`                    | Use a different `InpMagicTPS = InpMagic + 100000` to allow independent accounting.                            |

---

## 4. Common Pitfalls & How to avoid

* **Pivot ≠ Row 0** – never key logic off `row==0`. Always compare `dir` vs `trendSign`.
* **ALT duplicate guard** – always call `HasPos()` before placing; otherwise overlaps silently break alternating parity.
* **SafeRollTrendPair** must *move* positions, **not close the columns**. If you see the initial Buy/Sell disappearing then re‑appearing, you are still paying two spreads per grid – fix the logic.
* **Memory drift** – When ChatGPT forgets, ***read this file*** first, then open the journal & spreadsheet for concrete examples.

---

## 5. To Do (2025‑07‑02)

1. Finalise Trinity v1.0.5 – confirm that StepRow no longer closes the initial pair on the first grid.
2. Implement TPS observer EA skeleton; share state via global variables or custom events.
3. Stress‑test both EAs in tandem on 2020‑2025 USDJPY tickdata.
4. Refactor magic‑number handling so multiple Trinity instances (different symbols) can coexist with one TPS instance per symbol.
5. Write unit tests for `AltDir`, `WeightedClose`, `SeedPivotAlts`.

---

*End of README*
