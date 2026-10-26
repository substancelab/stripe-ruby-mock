module StripeMock
  module RequestHandlers
    module Invoices

      def Invoices.included(klass)
        klass.add_handler 'post /v1/invoices',               :new_invoice
        klass.add_handler 'get /v1/invoices/upcoming',       :upcoming_invoice
        klass.add_handler 'post /v1/invoices/create_preview', :create_preview_invoice
        klass.add_handler 'get /v1/invoices/(.*)/lines',     :get_invoice_line_items
        klass.add_handler 'get /v1/invoices/((?!search).*)', :get_invoice
        klass.add_handler 'get /v1/invoices/search',         :search_invoices
        klass.add_handler 'get /v1/invoices',                :list_invoices
        klass.add_handler 'post /v1/invoices/(.*)/pay',      :pay_invoice
        klass.add_handler 'post /v1/invoices/(.*)',          :update_invoice
      end

      def new_invoice(route, method_url, params, headers)
        id = new_id('in')
        invoice_item = Data.mock_line_item()
        invoices[id] = Data.mock_invoice([invoice_item], params.merge(:id => id))
      end

      def update_invoice(route, method_url, params, headers)
        route =~ method_url
        params.delete(:lines) if params[:lines]
        assert_existence :invoice, $1, invoices[$1]
        invoices[$1].merge!(params)
      end

      SEARCH_FIELDS = ["currency", "customer", "number", "receipt_number", "subscription", "total"].freeze
      def search_invoices(route, method_url, params, headers)
        require_param(:query) unless params[:query]

        results = search_results(invoices.values, params[:query], fields: SEARCH_FIELDS, resource_name: "invoices")
        Data.mock_list_object(results, params)
      end

      def list_invoices(route, method_url, params, headers)
        params[:offset] ||= 0
        params[:limit] ||= 10

        result = invoices.clone

        if params[:customer]
          result.delete_if { |k,v| v[:customer] != params[:customer] }
        end

        Data.mock_list_object(result.values, params)
      end

      def get_invoice(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]
      end

      def get_invoice_line_items(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]
        invoices[$1][:lines]
      end

      def pay_invoice(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]
        charge = invoice_charge(invoices[$1])
        invoices[$1].merge!(
          :paid => true,
          :status => "paid",
          :attempted => true,
          :charge => charge[:id],
        )
      end

      # Accepts both the subscription_details params (stripe >= 15, API version
      # 2025-03-31.basil) and the older top-level subscription_* params.
      def create_preview_invoice(route, method_url, params, headers = {})
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        details = params[:subscription_details] || {}
        items = list_param(details[:items] || params[:subscription_items])
        invoice_items = list_param(params[:invoice_items])
        proration_date = details[:proration_date] || params[:subscription_proration_date]
        trial_end = details[:trial_end] || params[:subscription_trial_end]

        raise Stripe::InvalidRequestError.new('Missing required param: customer', nil, http_status: 400) if params[:customer].nil? && params[:subscription].nil?

        customer =
          if params[:customer]
            assert_existence :customer, params[:customer], customers[stripe_account][params[:customer]]
          else
            subscription = assert_existence :subscription, params[:subscription], subscriptions[params[:subscription]]
            customers[stripe_account][subscription[:customer]]
          end

        if Compat.stripe_gte_15? && params[:subscription].nil? && items.empty? && invoice_items.empty?
          raise Stripe::InvalidRequestError.new('You must specify either `subscription` or `subscription_details.items` when previewing an invoice', nil, http_status: 400)
        end

        subscription =
          if params[:subscription]
            customer[:subscriptions][:data].find { |s| s[:id] == params[:subscription] } ||
              raise(Stripe::InvalidRequestError.new("No such subscription: #{params[:subscription]}", nil, http_status: 404))
          elsif items.empty?
            customer[:subscriptions][:data].min_by { |sub| sub[:current_period_end] }
          end

        extra_lines = invoice_items.map do |item|
          Data.mock_line_item(
            id: new_id('ii'),
            amount: item[:amount].to_i,
            description: item[:description] || 'Invoice item',
            quantity: (item[:quantity] || 1).to_i
          )
        end

        invoice =
          if subscription
            upcoming_params = { customer: customer[:id], subscription: subscription[:id] }
            if (item = items.first)
              upcoming_params[:subscription_plan] = item[:price] || item[:plan]
              upcoming_params[:subscription_quantity] = item[:quantity]&.to_i
            end
            upcoming_params[:subscription_proration_date] = proration_date.to_i if proration_date
            upcoming_params[:subscription_trial_end] = trial_end.to_i if trial_end
            build_upcoming_invoice(upcoming_params, stripe_account, extra_lines)
          else
            raise Stripe::InvalidRequestError.new('Cannot specify proration date without specifying a subscription', nil, http_status: 400) if proration_date

            # Previewing a new subscription with the given items
            lines = items.map do |item|
              plan_id = item[:price] || item[:plan]
              plan = assert_existence :plan, plan_id, plans[plan_id.to_s]
              quantity = (item[:quantity] || 1).to_i
              Data.mock_line_item(
                id: new_id('ii'),
                type: 'subscription',
                plan: plan,
                amount: (plan[:amount] || plan[:unit_amount]) * quantity,
                quantity: quantity
              )
            end
            now = Time.now.to_i
            Data.mock_invoice(lines + extra_lines,
              customer: customer[:id],
              discount: customer[:discount],
              created: now,
              starting_balance: customer[:account_balance],
              period_start: now,
              period_end: now,
              next_payment_attempt: now + 3600)
          end

        invoice[:id] = new_id(Compat.stripe_gte_15? ? 'upcoming_in' : 'in')
        invoice
      end

      def upcoming_invoice(route, method_url, params, headers = {})
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url
        build_upcoming_invoice(params, stripe_account)
      end

      private

      def build_upcoming_invoice(params, stripe_account, extra_lines = [])
        raise Stripe::InvalidRequestError.new('Missing required param: customer if subscription is not provided', nil, http_status: 400) if params[:customer].nil? && params[:subscription].nil?
        raise Stripe::InvalidRequestError.new('When previewing changes to a subscription, you must specify either `subscription` or `subscription_items`', nil, http_status: 400) if !params[:subscription_proration_date].nil? && params[:subscription].nil? && params[:subscription_plan].nil?
        raise Stripe::InvalidRequestError.new('Cannot specify proration date without specifying a subscription', nil, http_status: 400) if !params[:subscription_proration_date].nil? && params[:subscription].nil?

        if params[:subscription] && params[:customer].nil?
          params[:customer] = subscriptions[params[:subscription]][:customer]
        end
        customer = customers[stripe_account][params[:customer]]
        assert_existence :customer, params[:customer], customer

        raise Stripe::InvalidRequestError.new("No upcoming invoices for customer: #{customer[:id]}", nil, http_status: 404) if customer[:subscriptions][:data].length == 0

        subscription =
          if params[:subscription]
            customer[:subscriptions][:data].select{|s|s[:id] == params[:subscription]}.first
          else
            customer[:subscriptions][:data].min_by { |sub| sub[:current_period_end] }
          end

        if params[:subscription_proration_date] && !((subscription[:current_period_start]..subscription[:current_period_end]) === params[:subscription_proration_date])
          raise Stripe::InvalidRequestError.new('Cannot specify proration date outside of current subscription period', nil, http_status: 400)
        end

        prorating = false
        subscription_proration_date = nil
        subscription_plan_id = params[:subscription_plan] || subscription[:plan][:id]
        subscription_quantity = params[:subscription_quantity] || subscription[:quantity]
        if subscription_plan_id != subscription[:plan][:id] || subscription_quantity != subscription[:quantity]
          prorating = true
          invoice_date = Time.now.to_i
          subscription_plan = assert_existence :plan, subscription_plan_id, plans[subscription_plan_id.to_s]
          preview_subscription = Data.mock_subscription
          preview_subscription = resolve_subscription_changes(preview_subscription, [subscription_plan], customer, { trial_end: params[:subscription_trial_end] })
          preview_subscription[:id] = subscription[:id]
          preview_subscription[:quantity] = subscription_quantity
          subscription_proration_date = params[:subscription_proration_date] || Time.now
        else
          preview_subscription = subscription
          invoice_date = subscription[:current_period_end]
        end

        invoice_lines = []

        if prorating
          plan_amount = subscription[:plan][:amount] || subscription[:plan][:unit_amount]
          unused_amount = (
            plan_amount.to_f *
              subscription[:quantity] *
              (subscription[:current_period_end] - subscription_proration_date.to_i) / (subscription[:current_period_end] - subscription[:current_period_start])
            ).ceil

          invoice_lines << Data.mock_line_item(
                                   id: new_id('ii'),
                                   amount: -unused_amount,
                                   description: 'Unused time',
                                   plan: subscription[:plan],
                                   subscription: subscription[:id],
                                   subscription_item: subscription.dig(:items, :data, 0, :id),
                                   period: {
                                       start: subscription_proration_date.to_i,
                                       end: subscription[:current_period_end]
                                   },
                                   quantity: subscription[:quantity],
                                   proration: true
          )

          preview_plan = assert_existence :plan, params[:subscription_plan], plans[params[:subscription_plan]]
          if preview_plan[:interval] == subscription[:plan][:interval] && preview_plan[:interval_count] == subscription[:plan][:interval_count] && params[:subscription_trial_end].nil?
            remaining_amount = preview_plan[:amount] * subscription_quantity * (subscription[:current_period_end] - subscription_proration_date.to_i) / (subscription[:current_period_end] - subscription[:current_period_start])
            invoice_lines << Data.mock_line_item(
                                     id: new_id('ii'),
                                     amount: remaining_amount,
                                     description: 'Remaining time',
                                     plan: preview_plan,
                                     subscription: subscription[:id],
                                     subscription_item: subscription.dig(:items, :data, 0, :id),
                                     period: {
                                         start: subscription_proration_date.to_i,
                                         end: subscription[:current_period_end]
                                     },
                                     quantity: subscription_quantity,
                                     proration: true
            )
          end
        end

        subscription_line = get_mock_subscription_line_item(preview_subscription)
        invoice_lines << subscription_line
        invoice_lines.concat(extra_lines)

        Data.mock_invoice(invoice_lines,
          id: new_id('in'),
          customer: customer[:id],
          discount: customer[:discount],
          created: invoice_date,
          starting_balance: customer[:account_balance],
          subscription: preview_subscription[:id],
          period_start: prorating ? invoice_date : preview_subscription[:current_period_start],
          period_end: prorating ? invoice_date : preview_subscription[:current_period_end],
          next_payment_attempt: preview_subscription[:current_period_end] + 3600 )
      end


      # Array params can arrive as arrays or as hashes keyed by index
      def list_param(value)
        value = value.values if value.respond_to?(:values)
        Array(value)
      end

      def get_mock_subscription_line_item(subscription)
        plan_amount = subscription[:plan][:amount] || subscription[:plan][:unit_amount]

        Data.mock_line_item(
          id: subscription[:id],
          type: "subscription",
          plan: subscription[:plan],
          subscription: subscription[:id],
          subscription_item: subscription.dig(:items, :data, 0, :id),
          amount: subscription[:status] == 'trialing' ? 0 : plan_amount * subscription[:quantity],
          discountable: true,
          quantity: subscription[:quantity],
          period: {
            start: subscription[:current_period_end],
            end: get_ending_time(subscription[:current_period_start], subscription[:plan], 2)
          })
      end

      ## charge the customer on the invoice, if one does not exist, create
      #anonymous charge
      def invoice_charge(invoice)
        begin
          new_charge(nil, nil, {customer: invoice[:customer]["id"], amount: invoice[:amount_due], currency: StripeMock.default_currency}, nil)
        rescue Stripe::InvalidRequestError
          new_charge(nil, nil, {source: generate_card_token, amount: invoice[:amount_due], currency: StripeMock.default_currency}, nil)
        end
      end

    end
  end
end
