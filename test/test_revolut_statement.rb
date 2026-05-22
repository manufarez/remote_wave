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
