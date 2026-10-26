module StripeMock
  module RequestHandlers
    module Helpers
      PAYMENT_METHOD_TYPES_PARAMS = [:payment_method_types, :allowed_payment_method_types, :excluded_payment_method_types]

      # As of API version 2026-09-30.endive (stripe-ruby 20), payment_method_types
      # can no longer be passed to PaymentIntents, SetupIntents and Checkout Sessions.
      def reject_payment_method_types_param(params)
        return unless Compat.stripe_gte_20? && params[:payment_method_types]

        raise Stripe::InvalidRequestError.new(
          'The `payment_method_types` parameter is no longer supported. Use `allowed_payment_method_types`, `excluded_payment_method_types` or dynamic payment methods instead.',
          'payment_method_types',
          http_status: 400,
          code: 'payment_method_types_no_longer_supported'
        )
      end

      # The read-only payment_method_types computed from allowed_payment_method_types
      # and excluded_payment_method_types, or nil when neither is given.
      def computed_payment_method_types(params)
        allowed = params[:allowed_payment_method_types]
        excluded = params[:excluded_payment_method_types]
        return nil if allowed.nil? && excluded.nil?

        types = allowed ? payment_method_types_list(allowed) : ['card']
        types - payment_method_types_list(excluded)
      end

      private

      def payment_method_types_list(value)
        value = value.values if value.respond_to?(:values)
        Array(value).map(&:to_s)
      end
    end
  end
end
