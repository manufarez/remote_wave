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
