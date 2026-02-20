# frozen_string_literal: true

require "csv"
require "date"

class RemoteClient
  def initialize(csv_path:)
    @csv_path = csv_path
  end

  def paid_invoices(since: nil)
    invoices = []

    CSV.foreach(@csv_path, headers: true) do |row|
      next unless row["Status"] == "paid_out"

      invoice = parse_invoice(row)
      next if since && invoice[:invoice_date] < since

      invoices << invoice
    end

    invoices
  end

  private

  def parse_invoice(row)
    {
      invoice_number: row["Invoice Number"],
      company_name: row["Issued to"],
      invoice_date: Date.strptime(row["Issued date"], "%b %d, %Y").to_s,
      amount: row["Payout amount"].to_f,
      currency: row["Payout amount currency"],
      invoice_amount: row["Invoice amount"].to_f,
      invoice_currency: row["Invoice amount currency"],
      description: "Remote.com invoice ##{row["Invoice Number"]}"
    }
  end
end
