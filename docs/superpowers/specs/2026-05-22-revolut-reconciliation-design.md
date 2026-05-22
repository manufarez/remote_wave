# Revolut Reconciliation — Design

**Date:** 2026-05-22
**Status:** Revised — switched data source from Revolut Business API to manual statement CSV export. Pending user re-approval.
**Project:** remote_wave

## Problem

The current CLI (`bin/sync run_sync`) reads paid invoices from a Remote.com CSV export, creates matching invoices in Wave, and records them as paid. It trusts Remote's CSV: if Remote reports an invoice as `paid_out`, Wave is updated accordingly. The user has no automated way to confirm that the money for those `paid_out` invoices actually landed in their Revolut Business EUR account.

We want to add a reconciliation step that compares Remote.com CSV `paid_out` rows against actual incoming Revolut deposits and reports the discrepancies, without making any changes to Wave or Revolut.

## Goal

A pure reporting feature: at the end of a sync (or as a standalone command), print a grouped report of:
- Invoices the user expected to be paid for and were
- Invoices where the money has not yet landed
- Invoices that should have landed by now but haven't
- Deposits that landed from Remote but don't correspond to any CSV row

## Non-goals

- No writes to Wave or Revolut.
- No Revolut Business API integration. (The Revolut API requires the €30/month Grow plan, which is not justified for this use case. The Revolut statement CSV download contains the same fields we'd consume via the API.)
- No multi-currency reconciliation. EUR payouts only. (All current CSV `paid_out` rows are EUR; a non-EUR Remote payout, if it ever appeared, should be skipped with a warning.)
- No reconciliation of deposits from clients *other than* Remote. The user has other direct clients (Mamiche SAS, Marie Hazard, etc.) whose payments also land in Revolut; those are explicitly out of scope because the Remote CSV doesn't claim to know about them. They must not appear in the report at all (not even in the "unaccounted" bucket), or the report will be noisy.
- No retroactive payment recording in Wave when reconciliation detects a missed deposit.
- No support for payouts that bundle multiple invoices into a single transfer. Confirmed below: Remote sends one transfer per invoice.

## Background — observed data

### Remote.com CSV (`contractor-invoices.csv`)

100 `paid_out` rows in the sample, all from a single client (`Pinpoint Dining, Inc`), all in EUR. Contains both `Invoice amount` (USD, since the user invoices in USD) and `Payout amount` (EUR, since the Revolut account is EUR). Remote performs the FX conversion before transferring. The CSV has only `Issued date`, not a payout date. Observed lag from issue to deposit is up to ~30 days due to Remote's validation cycle.

Many CSV `Payout amount` values repeat across the history (e.g. €552.66 appears 4 times within a 4-week span), so amount alone is not a unique key.

### Revolut statement CSV (e.g. `transaction-statement_01-May-2024_22-May-2026.csv`)

Downloaded manually from Revolut Business (Accounts → EUR Main → Statement → CSV/Excel). Columns of interest:

| Column | Use |
|---|---|
| `Type` | Filter: keep only `TOPUP` (incoming wire transfers) |
| `State` | Filter: keep only `COMPLETED` |
| `Description` | Filter: keep only rows containing `REMOTE TECHNOLOGY` (excludes other-client TOPUPs) |
| `Reference` | Join key: contains the Remote invoice number, possibly with surrounding text |
| `Amount` | Verification: must match CSV `Payout amount` to the cent |
| `Payment currency` | Verification: must equal `EUR` |
| `Date completed (UTC)` | Used for `age_in_days` calculation and pending/missing classification |

Verified against the user's real statement: **100 of 100** paid_out CSV rows match a Remote TOPUP in the statement when the join is performed correctly. The other 11 TOPUPs in the statement come from non-Remote clients and are correctly filtered out by the `Description` check.

The `Payer` column is always `nil` for TOPUPs — do not rely on it. Sender identification must come from `Description`.

### Reference field variability

For Remote TOPUPs in the sampled statement, `Reference` is always a bare invoice number string (e.g. `"26047103"`). However, other clients' TOPUPs show formats like `"Invoice 26021797"`, `"/RFB/505828174//WEB DEVELOPMENT POP SERVICES"`, or `"solde honoraires"` — so a future Remote change to prefix the reference is plausible.

To stay robust against that, the match rule extracts the longest contiguous digit run from `Reference` and compares it to CSV `Invoice Number` as strings. For the current sample this is equivalent to exact equality.

## Match strategy

For each Revolut row that survives the filters (`Type=TOPUP`, `State=COMPLETED`, `Description` contains `REMOTE TECHNOLOGY`):

1. Extract the longest digit run from `Reference`. Call it `extracted_ref`.
2. Look up `extracted_ref` in the CSV indexed by `Invoice Number` (string equality).
3. If found, compare `Amount` to the cent and `Payment currency` to `EUR`. If both agree, classify as `matched`; if either disagrees, classify as `amount_mismatch`.
4. If not found, classify as `unaccounted` (a deposit from Remote with a reference that doesn't map to any CSV row — likely an invoice not yet in the export).

For each CSV `paid_out` row that does not get claimed by any Revolut row:
- If `Issued date` is less than 60 days before the run date → `pending`
- Otherwise → `missing`

No chronological greedy fallback. References have proven reliable enough that adding fallback logic would only obscure real problems.

## Buckets in the report

| Bucket | Definition |
|---|---|
| `matched` | Filtered Revolut TOPUP's `extracted_ref` matches a CSV `paid_out` row's `Invoice Number`, and EUR amounts agree to the cent |
| `amount_mismatch` | `extracted_ref` matches, but amount or currency differs |
| `pending` | CSV `paid_out` row not claimed by any Revolut row, and `Issued date` is less than 60 days before run date |
| `missing` | CSV `paid_out` row not claimed by any Revolut row, and `Issued date` is 60+ days before run date |
| `unaccounted` | Filtered Revolut TOPUP whose `extracted_ref` doesn't appear in the CSV |

The 60-day cutoff is a hard-coded constant in `Reconciler` (named, not magic). The observed worst-case lag is ~30 days, so 60 is a 2x safety margin.

CSV rows whose status is not `paid_out` are not part of input. Revolut rows that fail the type/state/description filter are not part of input — they are silently ignored, not bucketed.

## CLI surface

- New standalone command: `bin/sync reconcile --csv <path> --revolut-csv <path> [--since YYYY-MM-DD]`
  - `--csv` is required (same semantics as `run_sync`).
  - `--revolut-csv` is required.
  - `--since` filters both inputs by date and is also used as the lower bound for the report window.
- New flag on `run_sync`: `--revolut-csv <path>`. When provided, `run_sync` invokes the reconciler after the Wave sync completes and prints the report. When omitted, no reconciliation is attempted (no warning, no error — opt-in via the flag).
- No `revolut_setup` helper (no API auth needed).

## Architecture

Three new files, mirroring the existing layout:

### `lib/revolut_statement.rb`

Pure CSV parser. Mirrors the shape of `RemoteClient`.

- Constructor: `RevolutStatement.new(csv_path:)`
- Single public method: `#remote_topups(since: nil)` — returns an array of normalized hashes:
  ```
  {
    id: "<Revolut transaction ID>",
    reference: "<raw Reference string>",
    extracted_ref: "<longest digit run from Reference, or nil>",
    amount: 541.51,         # Float, always positive (TOPUPs have positive Amount in Revolut export)
    currency: "EUR",
    completed_at: Date,
    description: "<full Description string>"
  }
  ```
- Internally filters to `Type == "TOPUP"`, `State == "COMPLETED"`, `Description` matches `/REMOTE TECHNOLOGY/i`. Filtering happens here so the `Reconciler` only sees relevant rows.
- Optionally filters by `since` (using `Date completed (UTC)`).

### `lib/reconciler.rb`

Pure logic. No I/O.

- Constructor: `Reconciler.new(csv_rows:, revolut_topups:, today: Date.today)`
  - `csv_rows` are the hashes already returned by `RemoteClient#paid_invoices` — same shape, no transformation.
  - `revolut_topups` are the hashes returned by `RevolutStatement#remote_topups`.
- Single public method: `#reconcile` — returns a `Result` struct with the five bucket arrays. Each entry includes the originating row(s) and any computed metadata (`age_in_days` for `pending`/`missing`).
- One named constant: `PENDING_CUTOFF_DAYS = 60`.

### `bin/sync reconcile` (added to existing `bin/sync` Thor CLI)

- Wires `RemoteClient` + `RevolutStatement` + `Reconciler` together, then pretty-prints the result.
- The printer is a private method in `bin/sync` (small enough not to warrant its own class).
- Exit code is always `0` on success, regardless of mismatches. Mismatches are normal output, not errors.

### Integration with `run_sync`

When `run_sync` is invoked with `--revolut-csv`, it runs the reconciler after `Syncer#sync` returns and prints the report. Without the flag, behavior is unchanged.

## Configuration

No new env vars. The Revolut statement CSV path is passed via the CLI flag, not the environment, because the file changes each time the user re-exports.

Add `transaction-statement_*.csv` to `.gitignore` to keep statements out of git.

## Output format

Plain text, grouped by bucket. Empty buckets are still printed (with `(0)`) so the user sees at a glance that every bucket was checked. ASCII markers (no emojis) — matches the user's preference. Example:

```
=== Reconciliation (CSV ↔ Revolut statement) ===
CSV file:     contractor-invoices.csv
Statement:    transaction-statement_01-May-2024_22-May-2026.csv
Window:       2024-05-01 → 2026-05-22
CSV paid_out: 100
Remote TOPUPs in statement: 97

[OK]      Matched (97)
[WARN]    Amount mismatch (0)
[PENDING] Money not landed yet (2)
            26052101  Apr 28, 2026  expected €533.08
            26051402  Apr 14, 2026  expected €530.00
[MISSING] Should have landed (1)
            26039201  Feb 14, 2026  expected €548.13  (97 days old)
[?]       Unaccounted Revolut deposits (0)

Summary: 97 matched, 0 mismatches, 2 pending, 1 missing, 0 unaccounted
```

If a bucket has more than 20 entries, print the first 20 and append `(… N more)`. No `--verbose` flag in v1.

## Error handling

- Missing Revolut CSV file → exit 1 with a clear message.
- Revolut CSV is structurally invalid (missing required columns) → raise with a list of the missing columns.
- CSV row with an unparseable date → print a warning, skip the row, continue.
- Empty Revolut statement → print the report normally (everything ends up in `pending` or `missing`).
- A `paid_out` CSV row whose `Payout amount currency` is not EUR → print a warning and exclude from reconciliation; do not silently treat it as matched.

## Testing

- Unit tests for `Reconciler` covering all five bucket transitions, plus the `pending`/`missing` boundary at exactly 60 days, plus the EUR-currency-mismatch warning path.
- Unit tests for `RevolutStatement` covering: the type/state/description filter, reference-digit extraction (bare digits, prefixed text, no-digits-at-all, embedded amongst other text), and `since` filtering.
- A fixture-based test using a sanitized snippet of the real statement CSV (3–4 rows covering: a clean Remote TOPUP, a non-Remote TOPUP that must be filtered, a card payment that must be filtered, and a refund/EXCHANGE that must be filtered).
- Manual end-to-end run against the user's real CSV + statement once — since reconciliation is read-only, the manual run is itself the verification.

## Future possibility (not in v1)

If the user later upgrades to the Revolut Grow plan ($30/mo), the data source can swap to a `RevolutClient` API wrapper with the same `#remote_topups` interface, and `Reconciler` plus the CLI surface won't change. The CSV approach is fully sufficient until then.
