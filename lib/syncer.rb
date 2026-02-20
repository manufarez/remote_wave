# frozen_string_literal: true

class Syncer
  def initialize(remote_client:, wave_client:, dry_run: false, product_id: nil)
    @remote = remote_client
    @wave = wave_client
    @dry_run = dry_run
    @product_id = product_id
  end

  def sync(since: nil)
    invoices = @remote.paid_invoices(since: since)
    puts "Found #{invoices.length} paid invoice(s) from Remote.com CSV"
    return if invoices.empty?

    results = { synced: [], skipped: [], failed: [] }

    invoices.each do |invoice|
      sync_invoice(invoice, results)
    end

    print_summary(results)
  end

  private

  def sync_invoice(invoice, results)
    name = invoice[:company_name]
    amount = invoice[:amount]
    date = invoice[:invoice_date]
    inv_num = invoice[:invoice_number]

    customer = @wave.find_customer_by_name(name)
    unless customer
      puts "  [SKIP] No Wave customer matching '#{name}'"
      results[:skipped] << { invoice: invoice, reason: "No matching customer" }
      return
    end

    if already_synced?(customer["id"], inv_num)
      puts "  [SKIP] Already synced: ##{inv_num} - #{amount} EUR on #{date}"
      results[:skipped] << { invoice: invoice, reason: "Already synced" }
      return
    end

    if @dry_run
      puts "  [DRY RUN] Would sync: ##{inv_num} - #{amount} EUR on #{date}"
      results[:synced] << invoice
      return
    end

    label = "##{inv_num} #{name} - #{amount} EUR on #{date}"

    before_ids = @wave.receivable_account_ids

    wave_invoice = @wave.create_invoice(
      customer_id: customer["id"],
      items: [{ product_id: @product_id, description: invoice[:description], amount: amount }],
      date: date,
      invoice_number: inv_num
    )
    puts "  [INVOICE] #{label} -> created"

    @wave.approve_invoice(wave_invoice["id"])
    @wave.mark_invoice_sent(wave_invoice["id"])
    puts "  [INVOICE] #{label} -> approved & sent"

    after_ids = @wave.receivable_account_ids
    new_ids = after_ids - before_ids

    if new_ids.length == 1
      @wave.record_payment(
        amount: amount,
        date: date,
        description: "Payment from #{name} via Remote.com - Invoice ##{inv_num}",
        receivable_account_id: new_ids.first
      )
      puts "  [PAYMENT] #{label} -> recorded"
    else
      puts "  [WARNING] #{label} -> payment not recorded (could not identify receivable account)"
    end
    results[:synced] << invoice
  rescue StandardError => e
    puts "  [ERROR] ##{inv_num} #{name} - #{e.message}"
    results[:failed] << { invoice: invoice, error: e.message }
  end

  def already_synced?(customer_id, invoice_number)
    @synced_invoices ||= {}
    @synced_invoices[customer_id] ||= begin
      existing = @wave.list_invoices(customer_id: customer_id)
      existing.map { |inv| inv["invoiceNumber"] }.compact
    end

    @synced_invoices[customer_id].include?(invoice_number)
  end

  def print_summary(results)
    puts "\n--- Sync Summary ---"
    puts "Synced:  #{results[:synced].length}"
    puts "Skipped: #{results[:skipped].length}"
    puts "Failed:  #{results[:failed].length}"

    if results[:failed].any?
      puts "\nFailures:"
      results[:failed].each do |f|
        puts "  - ##{f[:invoice][:invoice_number]}: #{f[:error]}"
      end
    end
  end
end
