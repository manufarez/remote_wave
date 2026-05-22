# Revolut Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reconciliation feature that compares Remote.com paid_out CSV rows against incoming Revolut deposits (parsed from the Revolut Business statement CSV export) and prints a grouped report with five buckets: matched, amount mismatch, pending, missing, unaccounted.

**Architecture:** Two new pure-Ruby classes (`RevolutStatement`, `Reconciler`) mirror the existing `RemoteClient` / `Syncer` pattern. The CLI extends the existing Thor app in `bin/sync` with a new `reconcile` command and a `--revolut-csv` flag on `run_sync`. No new gems; uses stdlib `minitest` for tests.

**Tech Stack:** Ruby 3.x, Thor, HTTParty (unchanged), Minitest (stdlib, no Gemfile change needed).

**Spec:** `docs/superpowers/specs/2026-05-22-revolut-reconciliation-design.md`

---

## File Structure

**New:**
- `lib/revolut_statement.rb` — CSV parser, single public method `#remote_topups(since: nil)`. Filters to `TYPE=TOPUP`, `STATE=COMPLETED`, `Description` contains `REMOTE TECHNOLOGY`. Normalizes rows to hashes with `:id`, `:reference`, `:extracted_ref`, `:amount`, `:currency`, `:completed_at`, `:description`.
- `lib/reconciler.rb` — Pure logic. Constructor takes `csv_rows:, revolut_topups:, today: Date.today`. Single public method `#reconcile` returns a `Result` struct with five Array buckets plus a `warnings` array (for non-EUR CSV rows).
- `test/test_helper.rb` — Loads minitest/autorun and sets up `$LOAD_PATH` for `lib/`.
- `test/test_revolut_statement.rb` — Unit tests against a small fixture.
- `test/test_reconciler.rb` — Unit tests with inline hash inputs.
- `test/fixtures/revolut_statement_sample.csv` — 5-row sanitized sample exercising the filter rules and digit-extraction.

**Modified:**
- `bin/sync` — Add `reconcile` Thor command. Add `--revolut-csv` option to `run_sync`. Add a private `print_reconciliation_report` helper.
- `Gemfile` — No change required (minitest is in Ruby stdlib).
- `README.md` — Add a "Reconciliation" section.

**Note:** `.gitignore` already ignores `*.csv`, which covers the statement export.

---

## Conventions

- **Money comparison**: always convert to integer cents via `(amount * 100).round` before comparing. Avoids Float drift across the file boundary.
- **Date parsing**: `RemoteClient` returns `:invoice_date` as a String like `"2026-04-07"`. The reconciler parses it with `Date.parse`.
- **Test runner**: `ruby -Ilib -Itest test/test_FILE.rb` — no Rakefile needed.
- **Commits**: one logical commit per task, using Conventional Commits (`feat:`, `test:`, `refactor:`, `docs:`).

---

## Task 1: Test scaffolding

**Files:**
- Create: `test/test_helper.rb`
- Create: `test/fixtures/revolut_statement_sample.csv`
- Create: `test/test_smoke.rb` (temporary — deleted after Task 2)

**Goal:** Confirm minitest works from a one-liner before writing real tests.

- [ ] **Step 1: Write `test/test_helper.rb`**

```ruby
# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
```

- [ ] **Step 2: Write the fixture `test/fixtures/revolut_statement_sample.csv`**

This is the canonical fixture used by every `RevolutStatement` test. Five rows exercise: a clean Remote TOPUP, a Remote TOPUP with prefixed reference, a non-Remote TOPUP (filter out), an EXCHANGE (filter out), and a non-COMPLETED TOPUP (filter out).

```csv
"Date started (UTC)","Date completed (UTC)","Date started (Europe/Paris)","Date completed (Europe/Paris)","ID","Type","State","Description","Reference","Payer","Card number","Card label","Card state","Orig currency","Orig amount","Payment currency","Amount","Total amount","Exchange rate","Fee","Fee currency","Balance","Account","Beneficiary account number","Beneficiary sort code or routing number","Beneficiary IBAN","Beneficiary BIC","MCC","Related transaction id","Spend program"
"2026-05-04","2026-05-04","2026-05-04","2026-05-04","tx-1","TOPUP","COMPLETED","Money added from REMOTE TECHNOLOGY SERVICES, INC","26047103",,,,,"EUR","541.51","EUR","541.51","541.51",,"0.00","EUR","100.00","EUR Main",,,,,,,
"2026-04-10","2026-04-10","2026-04-10","2026-04-10","tx-2","TOPUP","COMPLETED","Money added from REMOTE TECHNOLOGY SERVICES, INC","Invoice 26021797","","","","","EUR","300.00","EUR","300.00","300.00","","0.00","EUR","200.00","EUR Main","","","","","","",""
"2026-05-12","2026-05-12","2026-05-12","2026-05-12","tx-3","TOPUP","COMPLETED","Money added from MAMICHE SAS","2512286","","","","","EUR","1140.00","EUR","1140.00","1140.00","","0.00","EUR","300.00","EUR Main","","","","","","",""
"2026-05-21","2026-05-21","2026-05-21","2026-05-21","tx-4","EXCHANGE","COMPLETED","Main · USD → Main · EUR","","","","","","EUR","87.11","EUR","87.11","87.11","","0.00","EUR","400.00","EUR Main","","","","","","",""
"2026-05-22","2026-05-22","2026-05-22","2026-05-22","tx-5","TOPUP","PENDING","Money added from REMOTE TECHNOLOGY SERVICES, INC","26050102","","","","","EUR","500.00","EUR","500.00","500.00","","0.00","EUR","500.00","EUR Main","","","","","","",""
```

- [ ] **Step 3: Write smoke test**

```ruby
# test/test_smoke.rb
# frozen_string_literal: true

require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_minitest_runs
    assert true
  end
end
```

- [ ] **Step 4: Run smoke test**

Run: `ruby -Ilib -Itest test/test_smoke.rb`
Expected: `1 runs, 1 assertions, 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Commit**

```bash
git add test/test_helper.rb test/fixtures/revolut_statement_sample.csv test/test_smoke.rb
git commit -m "test: scaffold minitest with fixture for Revolut statement parsing"
```

---

## Task 2: RevolutStatement returns Remote TOPUPs from the fixture

**Files:**
- Create: `lib/revolut_statement.rb`
- Create: `test/test_revolut_statement.rb`
- Delete: `test/test_smoke.rb` (no longer needed)

**Goal:** Implement the minimum needed to extract Remote TOPUPs from the sample fixture, filtering out everything else.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_revolut_statement.rb
# frozen_string_literal: true

require_relative "test_helper"
require "revolut_statement"

class RevolutStatementTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/revolut_statement_sample.csv", __dir__)

  def test_returns_only_completed_remote_topups
    rows = RevolutStatement.new(csv_path: FIXTURE).remote_topups
    assert_equal 2, rows.length
    assert_equal %w[tx-1 tx-2], rows.map { |r| r[:id] }
  end

  def test_normalizes_remote_topup_fields
    row = RevolutStatement.new(csv_path: FIXTURE).remote_topups.first
    assert_equal "tx-1", row[:id]
    assert_equal "26047103", row[:reference]
    assert_equal "26047103", row[:extracted_ref]
    assert_in_delta 541.51, row[:amount], 0.001
    assert_equal "EUR", row[:currency]
    assert_equal Date.new(2026, 5, 4), row[:completed_at]
    assert_equal "Money added from REMOTE TECHNOLOGY SERVICES, INC", row[:description]
  end

  def test_extracts_longest_digit_run_when_reference_has_prefix
    rows = RevolutStatement.new(csv_path: FIXTURE).remote_topups
    prefixed = rows.find { |r| r[:id] == "tx-2" }
    assert_equal "Invoice 26021797", prefixed[:reference]
    assert_equal "26021797", prefixed[:extracted_ref]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_revolut_statement.rb`
Expected: FAIL with `cannot load such file -- revolut_statement`

- [ ] **Step 3: Implement `lib/revolut_statement.rb`**

```ruby
# frozen_string_literal: true

require "csv"
require "date"

class RevolutStatement
  REMOTE_DESCRIPTION = /REMOTE TECHNOLOGY/i

  def initialize(csv_path:)
    @csv_path = csv_path
  end

  def remote_topups(since: nil)
    rows = []
    CSV.foreach(@csv_path, headers: true) do |row|
      next unless row["Type"] == "TOPUP"
      next unless row["State"] == "COMPLETED"
      next unless row["Description"]&.match?(REMOTE_DESCRIPTION)

      completed_at = Date.parse(row["Date completed (UTC)"])
      next if since && completed_at < Date.parse(since)

      rows << normalize(row, completed_at)
    end
    rows
  end

  private

  def normalize(row, completed_at)
    reference = row["Reference"].to_s
    {
      id: row["ID"],
      reference: reference,
      extracted_ref: reference.scan(/\d+/).max_by(&:length),
      amount: row["Amount"].to_f,
      currency: row["Payment currency"],
      completed_at: completed_at,
      description: row["Description"]
    }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Ilib -Itest test/test_revolut_statement.rb`
Expected: `3 runs, 7 assertions, 0 failures`

- [ ] **Step 5: Delete the smoke test**

```bash
rm test/test_smoke.rb
```

- [ ] **Step 6: Commit**

```bash
git add lib/revolut_statement.rb test/test_revolut_statement.rb
git rm test/test_smoke.rb
git commit -m "feat: add RevolutStatement parser for Remote TOPUPs"
```

---

## Task 3: RevolutStatement `since` filter

**Files:**
- Modify: `test/test_revolut_statement.rb`

**Goal:** Verify the `since:` keyword argument filters by `Date completed (UTC)`. (The implementation already supports this from Task 2 — this task is a focused test plus a regression guard.)

- [ ] **Step 1: Add the failing test**

Append to `test/test_revolut_statement.rb` inside the class:

```ruby
  def test_since_excludes_topups_before_the_cutoff
    rows = RevolutStatement.new(csv_path: FIXTURE).remote_topups(since: "2026-05-01")
    assert_equal %w[tx-1], rows.map { |r| r[:id] }
  end

  def test_since_is_inclusive_of_the_cutoff_date
    rows = RevolutStatement.new(csv_path: FIXTURE).remote_topups(since: "2026-05-04")
    assert_includes rows.map { |r| r[:id] }, "tx-1"
  end
```

- [ ] **Step 2: Run tests**

Run: `ruby -Ilib -Itest test/test_revolut_statement.rb`
Expected: `5 runs, 10 assertions, 0 failures` (all pass — Task 2's implementation handles `since`)

- [ ] **Step 3: Commit**

```bash
git add test/test_revolut_statement.rb
git commit -m "test: verify RevolutStatement since filter is inclusive"
```

---

## Task 4: Reconciler `matched` bucket

**Files:**
- Create: `lib/reconciler.rb`
- Create: `test/test_reconciler.rb`

**Goal:** Implement the happy-path bucket where a Revolut TOPUP's `extracted_ref` matches a CSV row's `invoice_number` and amounts agree.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_reconciler.rb
# frozen_string_literal: true

require_relative "test_helper"
require "reconciler"
require "date"

class ReconcilerTest < Minitest::Test
  def csv_row(invoice_number:, amount: 541.51, currency: "EUR", issued_date: "2026-04-07")
    {
      invoice_number: invoice_number,
      company_name: "Pinpoint Dining, Inc",
      invoice_date: issued_date,
      amount: amount,
      currency: currency,
      invoice_amount: 640.00,
      invoice_currency: "USD",
      description: "Remote.com invoice ##{invoice_number}"
    }
  end

  def topup(reference:, amount: 541.51, currency: "EUR", completed_at: Date.new(2026, 5, 4))
    {
      id: "tx-#{reference}",
      reference: reference,
      extracted_ref: reference.scan(/\d+/).max_by(&:length),
      amount: amount,
      currency: currency,
      completed_at: completed_at,
      description: "Money added from REMOTE TECHNOLOGY SERVICES, INC"
    }
  end

  def test_pairs_csv_row_with_topup_when_reference_and_amount_match
    result = Reconciler.new(
      csv_rows: [csv_row(invoice_number: "26047103")],
      revolut_topups: [topup(reference: "26047103")],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_equal 1, result.matched.length
    pair = result.matched.first
    assert_equal "26047103", pair[:csv_row][:invoice_number]
    assert_equal "tx-26047103", pair[:revolut_topup][:id]
    assert_empty result.amount_mismatch
    assert_empty result.pending
    assert_empty result.missing
    assert_empty result.unaccounted
    assert_empty result.warnings
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_reconciler.rb`
Expected: FAIL with `cannot load such file -- reconciler`

- [ ] **Step 3: Implement `lib/reconciler.rb`**

```ruby
# frozen_string_literal: true

require "date"

class Reconciler
  PENDING_CUTOFF_DAYS = 60

  Result = Struct.new(:matched, :amount_mismatch, :pending, :missing, :unaccounted, :warnings, keyword_init: true)

  def initialize(csv_rows:, revolut_topups:, today: Date.today)
    @csv_rows = csv_rows
    @revolut_topups = revolut_topups
    @today = today
  end

  def reconcile
    matched = []
    amount_mismatch = []
    unaccounted = []
    warnings = []
    consumed = {}

    csv_by_invoice = @csv_rows.each_with_object({}) { |r, h| h[r[:invoice_number]] = r }

    @revolut_topups.each do |topup|
      csv_row = csv_by_invoice[topup[:extracted_ref]]

      if csv_row.nil?
        unaccounted << { revolut_topup: topup }
      else
        consumed[csv_row[:invoice_number]] = true
        if amounts_equal?(csv_row[:amount], topup[:amount]) && csv_row[:currency] == topup[:currency]
          matched << { csv_row: csv_row, revolut_topup: topup }
        else
          amount_mismatch << { csv_row: csv_row, revolut_topup: topup }
        end
      end
    end

    pending = []
    missing = []
    @csv_rows.each do |row|
      next if consumed[row[:invoice_number]]

      age = (@today - Date.parse(row[:invoice_date])).to_i
      entry = { csv_row: row, age_in_days: age }
      age < PENDING_CUTOFF_DAYS ? pending << entry : missing << entry
    end

    Result.new(
      matched: matched,
      amount_mismatch: amount_mismatch,
      pending: pending,
      missing: missing,
      unaccounted: unaccounted,
      warnings: warnings
    )
  end

  private

  def amounts_equal?(a, b)
    (a.to_f * 100).round == (b.to_f * 100).round
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Ilib -Itest test/test_reconciler.rb`
Expected: `1 runs, 7 assertions, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/reconciler.rb test/test_reconciler.rb
git commit -m "feat: add Reconciler with matched bucket"
```

---

## Task 5: Reconciler `amount_mismatch` bucket

**Files:**
- Modify: `test/test_reconciler.rb`

**Goal:** Verify that a reference match with disagreeing amount or currency ends up in `amount_mismatch`, not `matched`.

- [ ] **Step 1: Add two failing tests**

Append inside the class:

```ruby
  def test_classifies_as_amount_mismatch_when_amounts_differ
    result = Reconciler.new(
      csv_rows: [csv_row(invoice_number: "26047103", amount: 541.51)],
      revolut_topups: [topup(reference: "26047103", amount: 540.00)],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_empty result.matched
    assert_equal 1, result.amount_mismatch.length
  end

  def test_classifies_as_amount_mismatch_when_currency_differs
    result = Reconciler.new(
      csv_rows: [csv_row(invoice_number: "26047103", amount: 541.51, currency: "EUR")],
      revolut_topups: [topup(reference: "26047103", amount: 541.51, currency: "USD")],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_empty result.matched
    assert_equal 1, result.amount_mismatch.length
  end
```

- [ ] **Step 2: Run tests**

Run: `ruby -Ilib -Itest test/test_reconciler.rb`
Expected: `3 runs, 9 assertions, 0 failures` (Task 4's implementation already handles this; the tests are regression guards)

- [ ] **Step 3: Commit**

```bash
git add test/test_reconciler.rb
git commit -m "test: guard Reconciler amount_mismatch on amount and currency diffs"
```

---

## Task 6: Reconciler `unaccounted` bucket

**Files:**
- Modify: `test/test_reconciler.rb`

- [ ] **Step 1: Add failing test**

Append inside the class:

```ruby
  def test_classifies_topup_with_unknown_reference_as_unaccounted
    result = Reconciler.new(
      csv_rows: [csv_row(invoice_number: "26047103")],
      revolut_topups: [topup(reference: "99999999")],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_empty result.matched
    assert_equal 1, result.unaccounted.length
    assert_equal "99999999", result.unaccounted.first[:revolut_topup][:extracted_ref]
  end
```

- [ ] **Step 2: Run tests**

Run: `ruby -Ilib -Itest test/test_reconciler.rb`
Expected: `4 runs, 12 assertions, 0 failures`

- [ ] **Step 3: Commit**

```bash
git add test/test_reconciler.rb
git commit -m "test: guard Reconciler unaccounted bucket"
```

---

## Task 7: Reconciler `pending` vs `missing` boundary

**Files:**
- Modify: `test/test_reconciler.rb`

**Goal:** Pin the 60-day cutoff. CSV rows under 60 days old → `pending`; 60+ days → `missing`.

- [ ] **Step 1: Add three failing tests**

Append inside the class:

```ruby
  def test_classifies_unmatched_csv_row_as_pending_when_under_cutoff
    result = Reconciler.new(
      csv_rows: [csv_row(invoice_number: "26047103", issued_date: "2026-04-01")],
      revolut_topups: [],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_equal 1, result.pending.length
    assert_equal 51, result.pending.first[:age_in_days]
    assert_empty result.missing
  end

  def test_classifies_unmatched_csv_row_as_missing_when_at_cutoff
    result = Reconciler.new(
      csv_rows: [csv_row(invoice_number: "26047103", issued_date: "2026-03-23")],
      revolut_topups: [],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_empty result.pending
    assert_equal 1, result.missing.length
    assert_equal 60, result.missing.first[:age_in_days]
  end

  def test_classifies_unmatched_csv_row_as_missing_when_well_past_cutoff
    result = Reconciler.new(
      csv_rows: [csv_row(invoice_number: "26047103", issued_date: "2026-01-01")],
      revolut_topups: [],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_empty result.pending
    assert_equal 1, result.missing.length
    assert_equal 141, result.missing.first[:age_in_days]
  end
```

- [ ] **Step 2: Run tests**

Run: `ruby -Ilib -Itest test/test_reconciler.rb`
Expected: `7 runs, 17 assertions, 0 failures`

- [ ] **Step 3: Commit**

```bash
git add test/test_reconciler.rb
git commit -m "test: pin Reconciler pending/missing 60-day boundary"
```

---

## Task 8: Reconciler warns on non-EUR CSV rows

**Files:**
- Modify: `lib/reconciler.rb`
- Modify: `test/test_reconciler.rb`

**Goal:** A CSV row whose `:currency` is not `"EUR"` is excluded from reconciliation and surfaces in `result.warnings` (per spec error-handling section).

- [ ] **Step 1: Add failing test**

Append inside the class:

```ruby
  def test_excludes_non_eur_csv_rows_and_records_a_warning
    result = Reconciler.new(
      csv_rows: [
        csv_row(invoice_number: "26047103"),
        csv_row(invoice_number: "26050200", currency: "USD")
      ],
      revolut_topups: [topup(reference: "26047103")],
      today: Date.new(2026, 5, 22)
    ).reconcile

    assert_equal 1, result.matched.length
    assert_empty result.pending
    assert_empty result.missing
    assert_equal 1, result.warnings.length
    assert_match(/26050200/, result.warnings.first)
    assert_match(/USD/, result.warnings.first)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_reconciler.rb`
Expected: FAIL — the non-EUR row is currently being treated as a regular paid_out row and classified as `pending` or `missing`.

- [ ] **Step 3: Update `lib/reconciler.rb`**

In `Reconciler#reconcile`, replace the line `csv_by_invoice = @csv_rows.each_with_object({}) { |r, h| h[r[:invoice_number]] = r }` and the surrounding initialization with:

```ruby
    matched = []
    amount_mismatch = []
    unaccounted = []
    warnings = []
    consumed = {}

    eur_rows, non_eur_rows = @csv_rows.partition { |r| r[:currency] == "EUR" }
    non_eur_rows.each do |row|
      warnings << "Skipping CSV row ##{row[:invoice_number]}: payout currency is #{row[:currency]}, not EUR"
    end

    csv_by_invoice = eur_rows.each_with_object({}) { |r, h| h[r[:invoice_number]] = r }
```

And in the loop that builds `pending` / `missing`, iterate over `eur_rows` instead of `@csv_rows`:

```ruby
    eur_rows.each do |row|
      next if consumed[row[:invoice_number]]

      age = (@today - Date.parse(row[:invoice_date])).to_i
      entry = { csv_row: row, age_in_days: age }
      age < PENDING_CUTOFF_DAYS ? pending << entry : missing << entry
    end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_reconciler.rb`
Expected: `8 runs, 22 assertions, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/reconciler.rb test/test_reconciler.rb
git commit -m "feat: exclude non-EUR CSV rows from reconciliation with a warning"
```

---

## Task 9: `bin/sync reconcile` Thor command

**Files:**
- Modify: `bin/sync`

**Goal:** Wire `RemoteClient` + `RevolutStatement` + `Reconciler` together and pretty-print the report. No new tests for the CLI itself — the spec specifies manual end-to-end verification.

- [ ] **Step 1: Add the `reconcile` command and printer**

At the top of `bin/sync`, alongside the existing `require_relative` lines, add:

```ruby
require_relative "../lib/revolut_statement"
require_relative "../lib/reconciler"
```

Inside the `CLI < Thor` class, before the `private` section, add:

```ruby
  desc "reconcile", "Compare Remote.com CSV paid_out rows against a Revolut Business statement CSV"
  option :csv, type: :string, required: true, desc: "Path to Remote.com contractor invoices CSV"
  option :revolut_csv, type: :string, required: true, desc: "Path to Revolut Business statement CSV"
  option :since, type: :string, desc: "Only include rows on or after this date (YYYY-MM-DD)"

  def reconcile
    validate_file!(options[:csv], "CSV")
    validate_file!(options[:revolut_csv], "Revolut statement CSV")

    csv_rows = RemoteClient.new(csv_path: options[:csv]).paid_invoices(since: options[:since])
    topups = RevolutStatement.new(csv_path: options[:revolut_csv]).remote_topups(since: options[:since])
    result = Reconciler.new(csv_rows: csv_rows, revolut_topups: topups).reconcile

    print_reconciliation_report(
      csv_path: options[:csv],
      statement_path: options[:revolut_csv],
      since: options[:since],
      csv_rows: csv_rows,
      topups: topups,
      result: result
    )
  end
```

In the `private` section, add `validate_file!` (replacing the existing `validate_csv!` if and only if you also update the call site in `run_sync`; otherwise leave both):

```ruby
  def validate_file!(path, label)
    return if File.exist?(path)
    puts "#{label} not found: #{path}"
    exit 1
  end
```

And add the printer:

```ruby
  def print_reconciliation_report(csv_path:, statement_path:, since:, csv_rows:, topups:, result:)
    puts "=== Reconciliation (CSV ↔ Revolut statement) ==="
    puts "CSV file:     #{csv_path}"
    puts "Statement:    #{statement_path}"
    puts "Since:        #{since}" if since
    puts "CSV paid_out: #{csv_rows.length}"
    puts "Remote TOPUPs in statement: #{topups.length}"
    puts

    result.warnings.each { |w| puts "[WARN] #{w}" }
    puts unless result.warnings.empty?

    print_bucket("[OK]      Matched", result.matched) do |entry|
      "  #{entry[:csv_row][:invoice_number]}  #{entry[:csv_row][:invoice_date]}  €#{format("%.2f", entry[:csv_row][:amount])}"
    end

    print_bucket("[WARN]    Amount mismatch", result.amount_mismatch) do |entry|
      csv = entry[:csv_row]
      tx = entry[:revolut_topup]
      "  ##{csv[:invoice_number]}  CSV: #{format("%.2f", csv[:amount])} #{csv[:currency]}  Revolut: #{format("%.2f", tx[:amount])} #{tx[:currency]}"
    end

    print_bucket("[PENDING] Money not landed yet", result.pending) do |entry|
      csv = entry[:csv_row]
      "  ##{csv[:invoice_number]}  #{csv[:invoice_date]}  expected €#{format("%.2f", csv[:amount])}  (#{entry[:age_in_days]} days old)"
    end

    print_bucket("[MISSING] Should have landed", result.missing) do |entry|
      csv = entry[:csv_row]
      "  ##{csv[:invoice_number]}  #{csv[:invoice_date]}  expected €#{format("%.2f", csv[:amount])}  (#{entry[:age_in_days]} days old)"
    end

    print_bucket("[?]       Unaccounted Revolut deposits", result.unaccounted) do |entry|
      tx = entry[:revolut_topup]
      "  Ref #{tx[:reference].inspect}  #{tx[:completed_at]}  €#{format("%.2f", tx[:amount])}"
    end

    puts "\nSummary: #{result.matched.length} matched, " \
         "#{result.amount_mismatch.length} mismatches, " \
         "#{result.pending.length} pending, " \
         "#{result.missing.length} missing, " \
         "#{result.unaccounted.length} unaccounted"
  end

  def print_bucket(label, entries)
    puts "#{label} (#{entries.length})"
    entries.first(20).each { |e| puts yield(e) }
    puts "  (… #{entries.length - 20} more)" if entries.length > 20
    puts
  end
```

- [ ] **Step 2: Manual verification with real data**

Run: `bin/sync reconcile --csv contractor-invoices.csv --revolut-csv transaction-statement_01-May-2024_22-May-2026.csv`

Expected: a complete report printed to stdout with `Matched (100)` and all other buckets at `(0)`. Exit code `0`. No exceptions.

- [ ] **Step 3: Re-run with `--since` and confirm filtering**

Run: `bin/sync reconcile --csv contractor-invoices.csv --revolut-csv transaction-statement_01-May-2024_22-May-2026.csv --since 2026-04-01`

Expected: a smaller report covering only April 2026 onward. Bucket counts add up to the filtered totals printed in the header.

- [ ] **Step 4: Commit**

```bash
git add bin/sync
git commit -m "feat: add bin/sync reconcile command and report printer"
```

---

## Task 10: `--revolut-csv` flag on `run_sync`

**Files:**
- Modify: `bin/sync`

**Goal:** When `run_sync` is invoked with `--revolut-csv`, run reconciliation after the Wave sync completes and print the report. Without the flag, behavior is unchanged.

- [ ] **Step 1: Add the option and the post-sync hook**

In the `run_sync` command definition, add the new option below the existing ones:

```ruby
  option :revolut_csv, type: :string, desc: "If provided, also run reconciliation against this Revolut statement CSV after sync"
```

At the bottom of the `run_sync` method body, after `syncer.sync(since: options[:since])`, add:

```ruby
    return unless options[:revolut_csv]

    validate_file!(options[:revolut_csv], "Revolut statement CSV")

    csv_rows = remote.paid_invoices(since: options[:since])
    topups = RevolutStatement.new(csv_path: options[:revolut_csv]).remote_topups(since: options[:since])
    result = Reconciler.new(csv_rows: csv_rows, revolut_topups: topups).reconcile

    puts
    print_reconciliation_report(
      csv_path: options[:csv],
      statement_path: options[:revolut_csv],
      since: options[:since],
      csv_rows: csv_rows,
      topups: topups,
      result: result
    )
```

- [ ] **Step 2: Manual verification**

Run with `--dry-run` to avoid touching Wave:

```
bin/sync run_sync --csv contractor-invoices.csv --revolut-csv transaction-statement_01-May-2024_22-May-2026.csv --dry-run
```

Expected: the dry-run sync output, followed by the reconciliation report.

- [ ] **Step 3: Verify `run_sync` without the flag is unchanged**

Run: `bin/sync run_sync --csv contractor-invoices.csv --dry-run`
Expected: no reconciliation output appears.

- [ ] **Step 4: Commit**

```bash
git add bin/sync
git commit -m "feat: add --revolut-csv flag to run_sync for post-sync reconciliation"
```

---

## Task 11: README update

**Files:**
- Modify: `README.md`

**Goal:** Document the new feature so a future user knows it exists.

- [ ] **Step 1: Append a new section after "Currency"**

Add the following section to `README.md`:

````markdown
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
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document the reconcile command and Revolut statement workflow"
```

---

## Final verification

- [ ] **Step 1: Run the full test suite**

Run: `ruby -Ilib -Itest test/test_revolut_statement.rb && ruby -Ilib -Itest test/test_reconciler.rb`
Expected: all tests pass, zero failures, zero errors.

- [ ] **Step 2: Re-run the manual end-to-end against real data**

Run: `bin/sync reconcile --csv contractor-invoices.csv --revolut-csv transaction-statement_01-May-2024_22-May-2026.csv`
Expected: Matched count equals CSV paid_out count (100). All other buckets empty.

- [ ] **Step 3: Use verification-before-completion skill**

Per `superpowers:verification-before-completion`: confirm that every spec requirement is exercised by either a passing test or the manual run before marking the feature complete.

---

## Out of scope (reaffirmed from spec)

- No writes to Wave.
- No Revolut API integration.
- No multi-currency reconciliation.
- No `--verbose` flag in v1.
- No reconciliation for non-Remote deposits.
