# frozen_string_literal: true

require "httparty"
require "json"

class WaveClient
  ENDPOINT = "https://gql.waveapps.com/graphql/public"

  def initialize(access_token:, business_id: nil, anchor_account_id: nil)
    @access_token = access_token
    @business_id = business_id
    @anchor_account_id = anchor_account_id
  end

  def list_businesses
    query = <<~GQL
      query {
        businesses(page: 1, pageSize: 25) {
          edges {
            node {
              id
              name
              currency { code }
            }
          }
        }
      }
    GQL

    result = execute(query)
    edges = result.dig("data", "businesses", "edges") || []
    edges.map { |e| e["node"] }
  end

  def list_accounts
    all_accounts = []
    page = 1

    loop do
      query = <<~GQL
        query($businessId: ID!, $page: Int!) {
          business(id: $businessId) {
            accounts(page: $page, pageSize: 100) {
              pageInfo { totalPages }
              edges {
                node {
                  id
                  name
                  type { name value }
                  subtype { name value }
                }
              }
            }
          }
        }
      GQL

      result = execute(query, businessId: @business_id, page: page)
      data = result.dig("data", "business", "accounts")
      edges = data&.dig("edges") || []
      all_accounts.concat(edges.map { |e| e["node"] })

      total_pages = data&.dig("pageInfo", "totalPages") || 1
      break if page >= total_pages

      page += 1
    end

    all_accounts
  end

  def list_customers
    query = <<~GQL
      query($businessId: ID!) {
        business(id: $businessId) {
          customers(page: 1, pageSize: 100) {
            edges {
              node {
                id
                name
              }
            }
          }
        }
      }
    GQL

    result = execute(query, businessId: @business_id)
    edges = result.dig("data", "business", "customers", "edges") || []
    edges.map { |e| e["node"] }
  end

  def list_products
    query = <<~GQL
      query($businessId: ID!) {
        business(id: $businessId) {
          products(page: 1, pageSize: 100) {
            edges {
              node {
                id
                name
                unitPrice
              }
            }
          }
        }
      }
    GQL

    result = execute(query, businessId: @business_id)
    edges = result.dig("data", "business", "products", "edges") || []
    edges.map { |e| e["node"] }
  end

  def find_customer_by_name(name)
    customers = list_customers
    customers.find { |c| c["name"].downcase.include?(name.downcase) || name.downcase.include?(c["name"].downcase) }
  end

  def list_invoices(customer_id:)
    query = <<~GQL
      query($businessId: ID!, $customerId: ID!) {
        business(id: $businessId) {
          invoices(customerId: $customerId, page: 1, pageSize: 100) {
            edges {
              node {
                id
                invoiceNumber
                total { value }
                invoiceDate
                status
              }
            }
          }
        }
      }
    GQL

    result = execute(query, businessId: @business_id, customerId: customer_id)
    edges = result.dig("data", "business", "invoices", "edges") || []
    edges.map { |e| e["node"] }
  end

  def create_invoice(customer_id:, items:, date:, invoice_number: nil)
    mutation = <<~GQL
      mutation($input: InvoiceCreateInput!) {
        invoiceCreate(input: $input) {
          didSucceed
          inputErrors { path message }
          invoice {
            id
            total { value }
          }
        }
      }
    GQL

    input = {
      businessId: @business_id,
      customerId: customer_id,
      invoiceNumber: invoice_number,
      invoiceDate: date,
      items: items.map do |item|
        entry = {
          productId: item[:product_id],
          description: item[:description],
          unitPrice: item[:amount].to_s,
          quantity: 1
        }
        entry
      end
    }

    result = execute(mutation, input: input)
    invoice_result = result.dig("data", "invoiceCreate")
    raise_if_errors!(invoice_result)
    invoice_result["invoice"]
  end

  def approve_invoice(invoice_id)
    mutation = <<~GQL
      mutation($input: InvoiceApproveInput!) {
        invoiceApprove(input: $input) {
          didSucceed
          inputErrors { path message }
          invoice { id status }
        }
      }
    GQL

    result = execute(mutation, input: { invoiceId: invoice_id })
    approve_result = result.dig("data", "invoiceApprove")
    raise_if_errors!(approve_result)
    approve_result["invoice"]
  end

  def mark_invoice_sent(invoice_id)
    mutation = <<~GQL
      mutation($input: InvoiceMarkSentInput!) {
        invoiceMarkSent(input: $input) {
          didSucceed
          inputErrors { path message }
          invoice { id status }
        }
      }
    GQL

    result = execute(mutation, input: { invoiceId: invoice_id, sendMethod: "MARKED_SENT" })
    sent_result = result.dig("data", "invoiceMarkSent")
    raise_if_errors!(sent_result)
    sent_result["invoice"]
  end

  def receivable_account_ids
    accounts = list_accounts
    accounts
      .select { |a| a.dig("subtype", "value") == "RECEIVABLE_INVOICES" }
      .map { |a| a["id"] }
  end

  def record_payment(amount:, date:, description:, receivable_account_id:)
    mutation = <<~GQL
      mutation($input: MoneyTransactionCreateInput!) {
        moneyTransactionCreate(input: $input) {
          didSucceed
          inputErrors { path message }
          transaction { id }
        }
      }
    GQL

    input = {
      businessId: @business_id,
      externalId: "remote-pay-#{description.gsub(/\s+/, "-")}",
      date: date,
      description: description,
      anchor: {
        accountId: @anchor_account_id,
        amount: amount.to_s,
        direction: "DEPOSIT"
      },
      lineItems: [
        {
          accountId: receivable_account_id,
          amount: amount.to_s,
          balance: "CREDIT"
        }
      ]
    }

    result = execute(mutation, input: input)
    tx_result = result.dig("data", "moneyTransactionCreate")
    raise_if_errors!(tx_result)
    tx_result["transaction"]
  end

  private

  def execute(query, variables = {})
    response = HTTParty.post(
      ENDPOINT,
      headers: {
        "Authorization" => "Bearer #{@access_token}",
        "Content-Type" => "application/json"
      },
      body: { query: query, variables: variables }.to_json
    )

    parsed = response.parsed_response

    if parsed["errors"]&.any?
      raise "Wave API error: #{parsed["errors"].map { |e| e["message"] }.join(", ")}"
    end

    parsed
  end

  def raise_if_errors!(result)
    return if result["didSucceed"]

    errors = (result["inputErrors"] || []).map { |e| "#{e["path"]}: #{e["message"]}" }.join(", ")
    raise "Wave mutation failed: #{errors}"
  end
end
