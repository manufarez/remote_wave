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
