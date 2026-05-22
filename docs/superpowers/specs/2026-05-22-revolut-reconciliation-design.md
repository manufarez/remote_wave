# Revolut Reconciliation — Design

**Date:** 2026-05-22
**Status:** Approved by user, pending implementation plan
**Project:** remote_wave

## Problem

The current CLI (`bin/sync run_sync`) reads paid invoices from a Remote.com CSV export, creates matching invoices in Wave, and records them as paid. This trusts Remote's CSV: if Remote reports an invoice as `paid_out`, Wave is updated accordingly. The user has no automated way to confirm that the money for those `paid_out` invoices actually landed in their Revolut Business EUR account.

We want to add a reconciliation step that compares Remote.com CSV `paid_out` rows against actual incoming Revolut deposits and reports the discrepancies, without making any changes to Wave or Revolut.

## Goal

A pure reporting feature: at the end of a sync (or as a standalone command), print a grouped report of:
- Invoices the user expected to be paid for and were
- Invoices where the money has not yet landed
- Invoices that should have landed by now but haven't
- Deposits that landed but don't correspond to any CSV row

## Non-goals

- No writes to Wave or Revolut.
- No webhook listener — CLI poll only.
- No persistent cache of Revolut transactions; refetch each run within the window.
- No multi-currency reconciliation. EUR payouts only. (All current CSV `paid_out` rows are EUR; if a non-EUR payout ever appears, reconciliation should skip it and surface a warning rather than try to handle FX.)
- No retroactive payment recording in Wave when reconciliation detects a missed deposit.
- No support for matching against payouts that bundle multiple invoices into a single transfer — the observed pattern is one invoice per deposit (confirmed below).

## Background — observed data

From parsing the existing `contractor-invoices.csv` (100 `paid_out` rows) and a sample Revolut transaction screenshot:

- The CSV contains both `Invoice amount` (USD, since the user invoices in USD) and `Payout amount` (EUR, since the Revolut account is EUR). Remote performs the FX conversion before transferring.
- The CSV has only an `Issued date`, not a payout date. Observed lag from issue to deposit is around 27 days in the sampled transaction; the user reports lags of up to a month or more due to Remote's validation cycle.
- Many CSV `Payout amount` values repeat across the history (e.g. €552.66 appears 4 times within a 4-week span), so amount alone is not a unique key.
- All `paid_out` rows so far come from a single client (`Pinpoint Dining, Inc`), and all payouts are EUR.
- Revolut shows incoming Remote transfers with:
  - `from`: `REMOTE TECHNOLOGY SERVICES, INC`
  - `reference`: a numeric string equal to the CSV `Invoice Number` (verified: Revolut reference `26047103` matched CSV row `26047103` with payout €541.51 on Apr 7, 2026)
  - `amount`: exactly equal to the CSV `Payout amount` (no fees on receipt)
  - `fees`: `No fee`

This makes the Revolut `reference` field a deterministic join key onto CSV `Invoice Number`.

## Match strategy

**Primary:** for each Revolut incoming transfer from Remote, look up its `reference` string in the CSV indexed by `Invoice Number`. String equality.

**Verification:** when a reference matches, also compare `amount` to the cent and `currency`. If they disagree, classify the row as a mismatch (rather than as a clean match) so the user investigates.

**No chronological greedy fallback** is included. If a reference is missing or doesn't map to any CSV row, the deposit is reported in the "unaccounted" bucket so the user can decide what to do. This trades some auto-resolution for simplicity and avoids the risk of mis-pairing duplicate amounts.

## Buckets in the report

Each row of input ends up in exactly one bucket:

| Bucket | Definition |
|---|---|
| `matched` | Revolut deposit's reference matches a CSV `paid_out` row's `Invoice Number`, and EUR amounts agree to the cent |
| `amount_mismatch` | Reference matches but amounts differ |
| `pending` | CSV `paid_out` row has no matching Revolut deposit, and `Issued date` is less than 60 days before the reconciliation run date |
| `missing` | CSV `paid_out` row has no matching Revolut deposit, and `Issued date` is 60 or more days before the run date |
| `unaccounted` | Revolut incoming deposit from Remote with a reference that does not appear in the CSV |

The 60-day cutoff between `pending` and `missing` is a heuristic: the observed worst-case lag is ~30 days, so 60 days is a 2x safety margin. It is hard-coded for v1; not exposed as a flag.

CSV rows with status other than `paid_out` (e.g. `issued`, `rejected`) are not part of reconciliation input. Revolut transactions whose counterparty does not look like Remote are filtered out before bucketing.

## CLI surface

- New standalone command: `bin/sync reconcile --csv <path> [--since YYYY-MM-DD]`
  - `--csv` is required, same semantics as `run_sync`.
  - `--since` filters the CSV rows considered and is also passed to the Revolut transaction fetch as the lower bound. If omitted, the lower bound is the oldest `Issued date` in the CSV, minus a small buffer.
  - The upper bound for Revolut fetch is always "now".
- New flag on `run_sync`: `--skip-reconcile` (default false). When `run_sync` finishes, it invokes the reconciler with the same CSV and `--since` arguments and prints the report. `--skip-reconcile` opts out.
- A new helper: `bin/sync revolut_setup` (mirrors the existing `setup` command). Walks through Revolut's OAuth flow once, prints the refresh token to paste into `.env`, and lists the available Revolut Business accounts so the user can pick the EUR account ID. Does not write to `.env` itself.

## Architecture

Three new files, mirroring the existing layout:

### `lib/revolut_client.rb`

Wraps the Revolut Business API.

- Auth: OAuth 2.0 with JWT client assertion. Public X.509 cert uploaded once via the Revolut Business UI (the user has already paid for API access and seen the upload prompt). Private key + client ID + long-lived refresh token live in `.env`. The client exchanges the refresh token for a short-lived access token on each run (or per request, if simpler), caching it in memory for the process lifetime.
- Base URL: production `https://b2b.revolut.com/api/1.0`. Sandbox URL is overridable via `REVOLUT_BASE_URL` for testing.
- Methods needed for v1:
  - `accounts` — list accounts (used by `revolut_setup`)
  - `transactions(from:, to:, type: "topup", account_id: nil, count: 1000)` — list incoming transactions in a window. Handles pagination (Revolut paginates by `from`/`to` cursors or by `count`; the client wraps that).
- Returns plain Hashes with normalized keys: `id`, `reference`, `amount` (Float, EUR), `currency`, `date` (Date), `counterparty_name`.
- Errors raise `RevolutClient::Error` with the response body for easy debugging.

### `lib/reconciler.rb`

Pure logic. No I/O.

- Constructor: `Reconciler.new(csv_rows:, revolut_transactions:, today: Date.today)`
- Single public method: `#reconcile` returns a `Result` struct (or plain Hash) with the five buckets, each an Array of small Hashes containing the originating CSV row, the originating Revolut transaction, and any computed metadata (e.g. `age_in_days` for `pending`/`missing`).
- Easy to test: feed it arrays of stub data, assert bucket membership.

### `bin/sync reconcile` (in existing `bin/sync` Thor CLI)

- Wires the CSV reader (existing `RemoteClient`) and `RevolutClient` together, runs `Reconciler`, then pretty-prints the result.
- Pretty-printer is its own small private method in `bin/sync` — no need for a separate class.
- Exit code is `0` if the report ran successfully, regardless of whether mismatches were found. (Mismatches are a normal output, not an error.)

### Integration with `run_sync`

After `Syncer#sync` completes, `run_sync` builds a `Reconciler` from the same CSV and the freshly-fetched Revolut transactions, then prints the report — unless `--skip-reconcile` was passed.

## Configuration

New env vars added to `.env.example`:

```
REVOLUT_CLIENT_ID=...
REVOLUT_PRIVATE_KEY_PATH=./revolut_private.pem
REVOLUT_REFRESH_TOKEN=...
REVOLUT_ACCOUNT_ID=...           # EUR account ID, from `revolut_setup`
# REVOLUT_BASE_URL=https://sandbox-b2b.revolut.com/api/1.0   # optional sandbox override
```

`REVOLUT_PRIVATE_KEY_PATH` points to a PEM file that should be gitignored alongside `.env`. The setup README will tell the user to add `*.pem` to `.gitignore`.

When the reconcile command runs, missing Revolut env vars yield a clear error pointing the user at `bin/sync revolut_setup` and the README.

## Output format

Plain text, grouped by bucket. Empty buckets are still printed (with `(0)`) so the user sees at a glance that every bucket was checked. Example:

```
=== Reconciliation (CSV ↔ Revolut) ===
Window: 2024-05-01 → 2026-05-22
CSV paid_out rows: 100
Revolut Remote deposits: 99

✅ Matched (97)
⚠️  Amount mismatch (0)
⏳ Pending — money not landed yet (2)
   26052101  Apr 28, 2026  expected €533.08
   26051402  Apr 14, 2026  expected €530.00
❌ Missing — should have landed (1)
   26039201  Feb 14, 2026  expected €548.13  (97 days ago)
❓ Unaccounted Revolut deposits (0)

Summary: 97 matched, 0 mismatches, 2 pending, 1 missing, 0 unaccounted
```

If a bucket has more than ~20 entries, truncate the printed list to the first 20 and print `(… 18 more, run with --verbose for full list)`. A `--verbose` flag on `reconcile` shows the full list. (The `--verbose` flag is the only stretch nicety; if it complicates implementation, omit it for v1 and just always print all rows.)

## Error handling

- Revolut auth failure (invalid refresh token, expired cert): raise with a clear message pointing the user at `revolut_setup`. Do not silently fall back.
- Revolut API transient error (5xx, network): retry once with a short backoff, then surface the error. Reconciliation is read-only and safe to retry.
- CSV row with an invalid `Issued date` format: surface the row in a warning before bucketing, do not crash.
- Run started without any Revolut transactions returned: print the report normally (everything ends up in `pending` or `missing`); do not assume an error.
- `run_sync` with `--skip-reconcile` omitted, but Revolut env vars missing: print a one-line warning and skip the reconciliation step; do not block the sync from completing.

## Testing

- Unit tests for `Reconciler` covering all five bucket transitions, plus the `pending`/`missing` boundary at exactly 60 days.
- Unit tests for `RevolutClient`'s response normalization using stubbed HTTP (WebMock or similar) — at minimum, one success fixture and one error fixture per method.
- Manual end-to-end verification once against the user's real CSV and real Revolut account, with a dry-run-equivalent: since reconcile is read-only, the manual run itself is the verification.

## Open items deferred to implementation

- Exact Revolut transactions endpoint shape and pagination details — to be confirmed against Revolut's Business API docs during implementation.
- Whether `RevolutClient` should accept the private key as PEM contents (env var) or as a file path. File path is the current plan; revisit if it's awkward.
- Whether `revolut_setup` should be fully automated (browser redirect handling) or print URLs for the user to paste codes back. Print-and-paste is the current plan for simplicity.
