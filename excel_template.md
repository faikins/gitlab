# Prompt: Build a Dataset Validation Excel Template

## Task
Create a Python script using `openpyxl` that generates a reusable Excel workbook
for comparing an OLD vs NEW dataset exported from Snowflake. The output file should
be fully formula-driven with zero hardcoded calculated values.

---

## Context
- Data comes from **two separate Snowflake queries** — one for OLD, one for NEW
- Both queries return the same schema: `REPORT_MONTH, CUSTOMER_ID, <metric_col_1>, <metric_col_2>, ...`
- The analyst pastes each query result into a raw data sheet, then all analysis
  sheets recalculate automatically
- Audience: internal technical team
- Platform: Excel on Mac (no VBA, no Power Query — formulas only)

---

## Sheet Architecture (in tab order)

### 1. `CONFIG`
The control panel. All other sheets reference this sheet via cell links.
Sections and their named parameters:

| Section | Parameter | Default Value |
|---|---|---|
| Analysis Identity | Analysis Name | (empty) |
| | Report Month | (empty) |
| | Analyst | (empty) |
| | Date Prepared | (empty) |
| Join Keys | Key 1 Column Name | `REPORT_MONTH` |
| | Key 2 Column Name | `CUSTOMER_ID` |
| Metric Columns | Metric 1 | `<first metric column name>` |
| | Metric 2 | `<second metric column name>` |
| | Metric 3 | `<third metric column name>` |
| | Metric 4 | (empty — reserved) |
| Match Tolerance | Absolute Tolerance ($) | `1.00` |
| | Percentage Tolerance | `0.001` (= 0.1%) |
| Spend Buckets | Bucket 1 Upper Bound | `500` |
| | Bucket 2 Upper Bound | `2000` |
| | Bucket 3 Upper Bound | `5000` |
| | Bucket 4 Upper Bound | `10000` |
| | Bucket 5 Upper Bound | `99999999` |

Parameter labels in column A (bold), editable values in column B (yellow fill),
notes/descriptions in column C (italic gray).

### 2. `RAW_OLD`
- Row 1: instruction banner (do not put instruction text in row 3 — it will break RECONCILIATION formulas)
- Row 2: frozen header row with column names matching CONFIG join keys + metric columns
- Row 3 onward: data paste zone (up to 500 rows supported)
- Column widths sized to column name length

### 3. `RAW_NEW`
- Identical structure to RAW_OLD
- Different header color to visually distinguish from RAW_OLD

### 4. `RECONCILIATION`
Row-level comparison joined on Key1 + Key2 (composite key lookup).

**Column layout (per metric):**
- Cols A–B: Key columns pulled from RAW_OLD (REPORT_MONTH, CUSTOMER_ID)
- Cols C–E: OLD metric values (direct reference to RAW_OLD)
- Cols F–H: NEW metric values (XLOOKUP on composite key `A&"|"&B` against RAW_NEW)
- Cols I–K: Absolute diff (`NEW - OLD`)
- Cols L–N: % diff (`diff / OLD`, guarded for zero denominator)
- Col O: STATUS — plain text values: `EXACT MATCH`, `NEAR MATCH`, `MISMATCH`, `ORPHAN`

**Critical formula rules:**
- XLOOKUP composite key pattern:
  `=IFERROR(XLOOKUP(A3&"|"&B3, RAW_NEW!$A$3:$A$502&"|"&RAW_NEW!$B$3:$B$502, RAW_NEW!$C$3:$C$502, "ORPHAN"), "")`
- Status formula must use plain text strings only (no emoji inside formula logic —
  emoji in formula strings cause `#VALUE!` errors in LibreOffice/recalc environments)
- Status logic: if NEW value = "ORPHAN" → "ORPHAN"; else if all abs diffs ≤ CONFIG abs tolerance → "EXACT MATCH"; else if all % diffs ≤ CONFIG % tolerance → "NEAR MATCH"; else "MISMATCH"
- All diff/status formulas must short-circuit when A column is empty (no data row)
- % diff formula must guard against zero OLD value: `=IF(old_val=0, IF(diff=0, 0, "N/A"), diff/old_val)`

**Freeze panes:** column C, row 3.

### 5. `SUMMARY`
Scorecard with 5 sections:

**Section 1 — Structural Integrity**
- Row count (OLD vs NEW)
- Distinct customer count — use `IFERROR(SUMPRODUCT(...),0)` pattern to guard
  against empty range `#DIV/0!`
- Null customer IDs
- Orphan row count (rows in OLD with no NEW match)

**Section 2 — Total Spend Reconciliation**
Per metric: OLD total, NEW total, abs diff, % diff, status
- Status formula: `=IF(OR(B=0, D=""), "N/A", IF(ABS(E)<=CONFIG!%_tol, "Within Tolerance", "Review"))`
  where D = abs diff and E = % diff. Guard against empty % diff (when OLD total = 0)

**Section 3 — Row-Level Match Summary**
Count and % for each STATUS value (EXACT MATCH, NEAR MATCH, MISMATCH, ORPHAN).
Include a simple bar sparkline using `=REPT("█", ROUND(pct*40, 0))`.
COUNTIF must match plain text strings (no emoji): `=COUNTIF(range, "*EXACT MATCH*")`

**Section 4 — Coverage Check**
- % of OLD customers found in NEW
- Count of customers in OLD but not in NEW
- % of rows with non-exact-match status

**Section 5 — Analyst Notes**
Three free-text sections with yellow-fill merge cells:
- Summary of findings
- Known differences / expected variances
- Recommendation (promote / hold / investigate)

### 6. `DISTRIBUTION`
Spend bucket breakdown for each metric column.

Per metric, build a table with 5 bucket rows:
- `$0 – Bucket1`: `COUNTIFS(range, ">="&0, range, "<="&CONFIG!bucket1_cell)`
- `Bucket1 – Bucket2`: `COUNTIFS(range, ">"&CONFIG!bucket1_cell, range, "<="&CONFIG!bucket2_cell)`
- ... (continue pattern)
- `Bucket4+`: `COUNTIFS(range, ">"&CONFIG!bucket4_cell)`

Columns per bucket row: Bucket Label, OLD Count, OLD Sum, OLD % of Rows, NEW Count, NEW Sum, NEW % of Rows, Δ Count

---

## Critical Implementation Rules

### Formulas — general
- Every calculated value MUST be an Excel formula, never a Python-computed hardcode
- Use `IFERROR()` wrappers on any formula that could produce `#DIV/0!`, `#N/A`, or `#VALUE!`
- Percentage format: `0.00%`, Currency: `$#,##0.00`, Zero display: `"-"`
- Cross-sheet references format: `SheetName!CellRef` (e.g. `RAW_OLD!C3`)

### Formulas — known pitfall: emoji in formula strings
**Do NOT use emoji characters inside formula string literals** (e.g. `"✅ EXACT MATCH"`).
They cause `#VALUE!` errors when the file is recalculated via LibreOffice.
- Use plain text in formula logic: `"EXACT MATCH"`, `"ORPHAN"`, `"MISMATCH"`, `"NEAR MATCH"`
- Emoji are acceptable only in static cell values or display labels that are never
  evaluated by a formula

### Formulas — known pitfall: instruction text in data rows
**Do NOT place instruction text in RAW_OLD row 3 or RAW_NEW row 3.**
RECONCILIATION pulls `=IF(RAW_OLD!A3="","",RAW_OLD!A3)`. A non-empty instruction
string in A3 is treated as a real data row, breaking XLOOKUP and producing `#VALUE!`.
Place all instructions in row 1 banners only.

### Formulas — known pitfall: distinct count on empty range
The SUMPRODUCT distinct count pattern `=SUMPRODUCT(1/COUNTIF(range, range))` produces
`#DIV/0!` when the range is empty. Always wrap: `=IFERROR(SUMPRODUCT(...), 0)`.

### Styling
- Font: Arial throughout
- Tab colors: CONFIG=gray, RAW_OLD=blue, RAW_NEW=green, RECONCILIATION=purple,
  SUMMARY=red, DISTRIBUTION=orange
- Section headers: dark filled rows with white bold text
- Editable input cells: yellow fill (`FFF2CC`)
- Match status row colors: EXACT MATCH=green (`C6EFCE`), NEAR MATCH=amber (`FFF2CC`),
  MISMATCH=red/orange (`FCE4D6`), ORPHAN=yellow (`FFF2CC`)
- Column widths: set explicitly, sized to longest expected content

### Validation workflow
After generating the `.xlsx` file, run:
```bash
python scripts/recalc.py output.xlsx 60
```
The script returns JSON. Target: `"status": "success"` with `"total_errors": 0`.
If errors remain, check:
1. `#VALUE!` in RECONCILIATION → likely emoji in formula string or text in data row 3
2. `#DIV/0!` in SUMMARY → likely unguarded SUMPRODUCT or division by zero
3. `#VALUE!` in SUMMARY status cols → likely `ABS()` applied to an empty string `""`

---

## Deliverable
A single Python script `build_validation_template.py` that:
1. Imports only `openpyxl` (standard install)
2. Accepts optional CLI args for output path and analysis name
3. Generates the `.xlsx` with all 6 sheets as described
4. Prints the output path on success

Output file: `dataset_validation_template.xlsx`
