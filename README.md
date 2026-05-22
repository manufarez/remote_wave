# Remote.com to Wave invoice sync

Ruby CLI that reads paid invoices from a Remote.com CSV export and creates matching invoices in Wave accounting, with automatic payment recording.

## What it does

For each paid invoice in the CSV, the script:

1. Matches the contractor name to a Wave customer (fuzzy match)
2. Skips if the invoice already exists in Wave (by invoice number)
3. Creates the invoice in Wave with the Remote invoice number
4. Approves and marks it as sent
5. Records the payment against the invoice (marks it as paid)

## Setup

### Prerequisites

- Ruby 3.x
- A [Wave developer app](https://developer.waveapps.com) with an access token

Make sure the following are created in Wave before running the script:

- **Customers** matching your Remote.com contractor names (used for fuzzy matching)
- **A bank account** (used as the anchor for payment transactions)
- **A product/service** (used as the line item on invoices)

### Install dependencies

```
bundle install
```

### Configure credentials

Create a `.env` file:

```
WAVE_ACCESS_TOKEN=...
WAVE_BUSINESS_ID=...
WAVE_ANCHOR_ACCOUNT_ID=...
WAVE_PRODUCT_ID=...
```

To find your IDs, set `WAVE_ACCESS_TOKEN` first, then run:

```
bin/sync setup
```

This will list your Wave businesses, bank accounts, and products with their IDs.

## Usage

### Preview (dry run)

```
bin/sync run_sync --csv contractor-invoices.csv --dry-run
```

### Sync all invoices

```
bin/sync run_sync --csv contractor-invoices.csv
```

### Sync invoices after a specific date

```
bin/sync run_sync --csv contractor-invoices.csv --since 2026-01-01
```

### Export CSV from Remote.com

Go to Remote.com -> Contractor Invoices -> Export to download the CSV file -> Save it as `contractor-invoices.csv` in the root of the project.

## Currency

The CSV contains two amounts per invoice: the invoice amount (what the client was billed) and the payout amount (what you received). The script uses the **payout amount** since that's what hits your bank account and matches your Wave business currency.

## Duplicate prevention

The script checks existing Wave invoices by invoice number before creating new ones. It's safe to run multiple times against the same CSV.

## Reconciliation against Revolut

Verify that the money for `paid_out` invoices actually landed in your Revolut Business EUR account.

### Export a Revolut statement

1. In the Revolut Business app or web: **Accounts → EUR Main → Statement**.
2. Pick a date range that covers your invoices (going back at least 2x the longest payout lag).
3. Download as **CSV** (not PDF).
4. Save into the project root — any filename, but the `transaction-statement_*.csv` pattern is what Revolut uses by default.

### Run reconciliation

Standalone:

```
bin/sync reconcile --csv contractor-invoices.csv --revolut-csv transaction-statement_<dates>.csv
```

Or as part of the sync:

```
bin/sync run_sync --csv contractor-invoices.csv --revolut-csv transaction-statement_<dates>.csv
```

Both commands accept `--since YYYY-MM-DD` to restrict the window.

### What the report shows

Five buckets:

- `[OK]` **Matched** — Revolut deposit's reference matches a CSV `paid_out` row, amounts agree to the cent.
- `[WARN]` **Amount mismatch** — Reference matches but amount or currency differs.
- `[PENDING]` **Money not landed yet** — CSV row with no matching deposit, less than 60 days old.
- `[MISSING]` **Should have landed** — CSV row with no matching deposit, 60+ days old. Worth investigating.
- `[?]` **Unaccounted Revolut deposits** — Deposit from Remote whose reference doesn't appear in the CSV (likely an invoice not in the latest CSV export).

The CLI only matches deposits whose Revolut `Description` contains `REMOTE TECHNOLOGY`. Payments from other clients are silently ignored.
