Use the following prompt to build an excel template. Ask any clarifying questions.
Just a note that `TOTAL_AT_CLASSIFIED_SPEND' is not necessarily the sum of `USED_AT_CLASSIFIED_SPEND` and `NEW_AT_CLASSIFIED_SPEND`
-----
# AT Classification Dataset Validation — Old vs New

## What to build
A Python script using `openpyxl` that generates a single Excel workbook comparing
an OLD and NEW version of the AT classification spend dataset. Both datasets come
from separate Snowflake queries and share the same schema. The goal is to give a
technical analyst enough evidence to decide whether the NEW dataset is valid and
ready to replace the OLD.

---

## Input data schema
Both OLD and NEW datasets have exactly these 5 columns in this order:

| Column | Type | Notes |
|---|---|---|
| `REPORT_MONTH` | Date | Format MM/DD/YYYY. e.g. 2/28/2026 |
| `CUSTOMER_ID` | Integer | e.g. 66344 |
| `USED_AT_CLASSIFIED_SPEND` | Decimal | Dollar amount, can be 0 |
| `NEW_AT_CLASSIFIED_SPEND` | Decimal | Dollar amount, can be 0 |
| `TOTAL_AT_CLASSIFIED_SPEND` | Decimal | Should equal USED + NEW |

Join key: `REPORT_MONTH + CUSTOMER_ID` (composite — both fields together identify a unique row)

---

## Sheet layout (6 tabs in this order)

### Tab 1: `RAW_OLD`
- Row 1: dark blue banner — text: "OLD Dataset — Paste Snowflake export starting at row 3. Do not modify row 2 headers."
- Row 2: frozen header row — columns A–E with exact names above, white bold on dark blue
- Row 3 onward: empty paste zone (supports up to 1000 rows)
- **Do NOT place any text or instructions in row 3** — formulas in RECONCILIATION pull from row 3 directly

### Tab 2: `RAW_NEW`
- Identical structure to RAW_OLD
- Dark green banner and header instead of blue
- Row 1 text: "NEW Dataset — Paste Snowflake export starting at row 3. Do not modify row 2 headers."

### Tab 3: `RECONCILIATION`
Row-level side-by-side comparison of every OLD row matched to its NEW counterpart.

**Columns:**

| Col | Header | Formula / Source |
|---|---|---|
| A | REPORT_MONTH | `=IF(RAW_OLD!A3="","",RAW_OLD!A3)` |
| B | CUSTOMER_ID | `=IF(RAW_OLD!B3="","",RAW_OLD!B3)` |
| C | OLD: USED_AT | `=IF(A3="","",RAW_OLD!C3)` |
| D | OLD: NEW_AT | `=IF(A3="","",RAW_OLD!D3)` |
| E | OLD: TOTAL | `=IF(A3="","",RAW_OLD!E3)` |
| F | NEW: USED_AT | XLOOKUP on composite key — see formula below |
| G | NEW: NEW_AT | XLOOKUP on composite key |
| H | NEW: TOTAL | XLOOKUP on composite key |
| I | DIFF: USED_AT ($) | `=IF(OR(A3="",F3="NOT FOUND"),"",F3-C3)` |
| J | DIFF: NEW_AT ($) | `=IF(OR(A3="",G3="NOT FOUND"),"",G3-D3)` |
| K | DIFF: TOTAL ($) | `=IF(OR(A3="",H3="NOT FOUND"),"",H3-E3)` |
| L | DIFF: USED_AT (%) | `=IF(OR(A3="",C3=0),"",I3/C3)` |
| M | DIFF: NEW_AT (%) | `=IF(OR(A3="",D3=0),"",J3/D3)` |
| N | DIFF: TOTAL (%) | `=IF(OR(A3="",E3=0),"",K3/E3)` |
| O | INTERNAL_CHECK | `=IF(A3="","",IF(OR(C3="",F3="NOT FOUND"),"",C3+D3-E3))` — validates OLD USED+NEW=TOTAL |
| P | NEW_INTERNAL_CHECK | Same logic for NEW row |
| Q | STATUS | Plain text status string — see logic below |

**XLOOKUP formula for NEW columns (F, G, H):**
```
=IF(A3="","",IFERROR(
  XLOOKUP(
    A3&"|"&B3,
    RAW_NEW!$A$3:$A$1002&"|"&RAW_NEW!$B$3:$B$1002,
    RAW_NEW!$C$3:$C$1002,
    "NOT FOUND"
  ),"NOT FOUND"))
```
Use `RAW_NEW!$C$`, `$D$`, `$E$` for F, G, H respectively.

**STATUS formula — use plain text strings only, no emoji in formula logic:**
```
=IF(A3="","",
  IF(F3="NOT FOUND","ORPHAN",
    IF(AND(ABS(I3)<=1, ABS(J3)<=1, ABS(K3)<=1),"EXACT MATCH",
      IF(AND(ABS(L3)<=0.001, ABS(M3)<=0.001, ABS(N3)<=0.001),"NEAR MATCH",
        "MISMATCH"))))
```
Tolerance: $1.00 absolute OR 0.1% relative — a row passes if it meets EITHER threshold.

**Formatting:**
- Currency columns (C–K): `$#,##0.00`
- Percent columns (L–N): `0.000%`
- Status column (Q): conditional fill — green for EXACT MATCH, yellow for NEAR MATCH, red for MISMATCH, orange for ORPHAN
- Freeze panes at C3
- Tab color: purple

### Tab 4: `TOTALS_CHECK`
Grand total comparison for each of the 3 spend columns.

Build a clean table with these rows:

| Metric | OLD Total | NEW Total | Absolute Diff | % Diff | Status |
|---|---|---|---|---|---|
| USED_AT_CLASSIFIED_SPEND | `=SUM(RAW_OLD!C3:C1002)` | `=SUM(RAW_NEW!C3:C1002)` | `=NEW-OLD` | `=diff/OLD` | Within $1 or 0.1%? |
| NEW_AT_CLASSIFIED_SPEND | same pattern | | | | |
| TOTAL_AT_CLASSIFIED_SPEND | same pattern | | | | |
| **TOTAL COMBINED** | sum of all OLD | sum of all NEW | | | |

Below the totals table, add a second table: **Internal Consistency Check**

| Check | OLD Result | NEW Result |
|---|---|---|
| USED + NEW = TOTAL (row count where true) | `=COUNTIF(RECONCILIATION!O3:O1002,"0")` approx — see note | same for NEW |
| Max discrepancy in TOTAL (USED+NEW vs TOTAL col) | `=MAX(ABS(RAW_OLD!C3:C1002+RAW_OLD!D3:D1002-RAW_OLD!E3:E1002))` as array formula | same for NEW |
| Rows where TOTAL ≠ USED+NEW (>$0.01) | COUNTIFS pattern | same |

Tab color: dark blue.

### Tab 5: `MATCH_SUMMARY`
The main decision-support scorecard. Three sections:

**Section A — Row Coverage**

| Metric | Value |
|---|---|
| OLD row count | `=COUNTA(RAW_OLD!B3:B1002)` |
| NEW row count | `=COUNTA(RAW_NEW!B3:B1002)` |
| Row count delta | `=NEW - OLD` |
| Customers in OLD | distinct CUSTOMER_ID count in OLD — use `=IFERROR(SUMPRODUCT((1/COUNTIF(RAW_OLD!B3:INDEX(RAW_OLD!B:B,COUNTA(RAW_OLD!B:B)+2),RAW_OLD!B3:INDEX(RAW_OLD!B:B,COUNTA(RAW_OLD!B:B)+2)))*(RAW_OLD!B3:INDEX(RAW_OLD!B:B,COUNTA(RAW_OLD!B:B)+2)<>"")),0)` |
| Customers in NEW | same pattern for NEW |
| Customers in OLD missing from NEW (orphans) | `=COUNTIF(RECONCILIATION!Q3:Q1002,"ORPHAN")` |
| Customers in NEW not in OLD | needs reverse XLOOKUP count — use helper in RECONCILIATION or COUNTIFS |
| Coverage rate (OLD→NEW) | `=1-(orphan_count/old_row_count)` formatted as % |

**Section B — Match Quality**

| Status | Count | % of OLD Rows | Bar |
|---|---|---|---|
| EXACT MATCH | `=COUNTIF(RECONCILIATION!Q3:Q1002,"EXACT MATCH")` | `=count/old_rows` | `=REPT("█",ROUND(pct*40,0))` |
| NEAR MATCH | same | | |
| MISMATCH | same | | |
| ORPHAN | same | | |
| **TOTAL** | `=SUM(above)` | | |

**Section C — Spend Variance by Metric**
For each of the 3 spend columns, show:
- Total OLD spend
- Total NEW spend  
- $ variance
- % variance
- Among MISMATCH rows only: average abs % diff
- Among MISMATCH rows only: max abs $ diff (use `MAXIFS`)
- Count of mismatches where diff > $100
- Count of mismatches where diff > $1,000

Use `AVERAGEIF`, `MAXIFS`, `COUNTIFS` against RECONCILIATION columns.

Tab color: red.

### Tab 6: `DISTRIBUTION`
Spend bucket breakdown to validate that the NEW dataset has the same
customer spend profile as OLD.

For `TOTAL_AT_CLASSIFIED_SPEND`, build a bucket table using these bands:

| Band | Lower | Upper |
|---|---|---|
| $0 (zero spend) | 0 | 0 |
| $1 – $500 | 0.01 | 500 |
| $501 – $2,000 | 500 | 2000 |
| $2,001 – $5,000 | 2000 | 5000 |
| $5,001 – $10,000 | 5000 | 10000 |
| $10,001 – $25,000 | 10000 | 25000 |
| $25,001+ | 25000 | 99999999 |

Columns: Band Label, OLD Count, OLD % of Total, OLD Sum ($), NEW Count, NEW % of Total, NEW Sum ($), Count Delta, % Point Delta

Use `COUNTIFS` and `SUMIFS` against `RAW_OLD!E3:E1002` and `RAW_NEW!E3:E1002`.

Also repeat the same bucket table for `USED_AT_CLASSIFIED_SPEND` and
`NEW_AT_CLASSIFIED_SPEND` — one table per metric, stacked vertically with
a section header row between them.

Tab color: orange.

---

## Critical implementation rules

### Rule 1 — No emoji inside formula strings
`"✅ EXACT MATCH"` inside a formula causes `#VALUE!` errors during recalculation.
Use plain text only: `"EXACT MATCH"`, `"NEAR MATCH"`, `"MISMATCH"`, `"ORPHAN"`, `"NOT FOUND"`.
Emoji are fine in static cell labels that are never referenced by other formulas.

### Rule 2 — Never put text in RAW_OLD row 3 or RAW_NEW row 3
RECONCILIATION row 3 pulls `=IF(RAW_OLD!A3="","",RAW_OLD!A3)`. Any non-empty
string in A3 (like an instruction note) is treated as a real data row and
cascades `#VALUE!` through every diff and status formula for that row.
All instructions go in row 1 banners only.

### Rule 3 — Guard every potential #DIV/0!
- SUMPRODUCT distinct count: always wrap in `=IFERROR(..., 0)`
- % diff: always check `IF(old_value=0, "", diff/old_value)`
- Coverage rate: always check `IF(old_row_count=0, "", ...)`
- Status column tolerance check: `ABS()` must never be applied to an empty string `""`

### Rule 4 — Formulas not hardcodes
Every number in analysis tabs must be a formula referencing RAW_OLD or RAW_NEW
directly. No Python-computed values written as static numbers into cells.

### Rule 5 — Array formulas
For `MAX(ABS(...))` patterns in TOTALS_CHECK, write these as regular formulas
where possible, or note that the analyst must Ctrl+Shift+Enter them if on
older Excel. Prefer `AGGREGATE` or `MAXIFS` where it avoids array entry.

---

## Validation step
After generating the file, run:
```bash
python scripts/recalc.py at_classification_validation.xlsx 60
```
Target: `"status": "success"`, `"total_errors": 0`.

Common errors and fixes:
- `#VALUE!` in RECONCILIATION cols I–Q → check for emoji in STATUS formula or text in RAW_OLD row 3
- `#DIV/0!` in MATCH_SUMMARY → wrap SUMPRODUCT distinct count in IFERROR
- `#VALUE!` in MATCH_SUMMARY Section C → ABS() applied to empty string in diff columns

---

## Output
Script filename: `build_at_validation.py`
Workbook filename: `at_classification_validation.xlsx`
