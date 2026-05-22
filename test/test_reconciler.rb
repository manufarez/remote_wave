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
end
