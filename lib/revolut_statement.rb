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
