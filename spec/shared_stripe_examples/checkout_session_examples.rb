require "spec_helper"

shared_examples "Checkout Session API" do
  # payment_method_types can no longer be passed as of stripe-ruby 20
  let(:card_payment_method_types) do
    if StripeMock::Compat.stripe_gte_20?
      { allowed_payment_method_types: ["card"] }
    else
      { payment_method_types: ["card"] }
    end
  end

  it "creates PaymentIntent with payment mode" do
    line_items = [{
      name: "T-shirt",
      quantity: 2,
      amount: 500,
      currency: "usd",
    }]
    session = Stripe::Checkout::Session.create(
      **card_payment_method_types,
      line_items: line_items,
      success_url: "https://example.com/success"
    )

    expect(session.payment_intent).to_not be_empty
    payment_intent = Stripe::PaymentIntent.retrieve(session.payment_intent)
    expect(payment_intent.amount).to eq(1000)
    expect(payment_intent.currency).to eq("usd")
    expect(payment_intent.customer).to eq(session.customer)
  end

  context "when creating a payment" do
    it "requires line_items" do
      expect do
        session = Stripe::Checkout::Session.create(
          customer: "customer_id",
          success_url: "localhost/nada",
          **card_payment_method_types,
        )
      end.to raise_error(Stripe::InvalidRequestError, /line_items/i)

    end
  end

  it "creates SetupIntent with setup mode" do
    session = Stripe::Checkout::Session.create(
      mode: "setup",
      **card_payment_method_types,
      success_url: "https://example.com/success"
    )

    expect(session.setup_intent).to_not be_empty
    setup_intent = Stripe::SetupIntent.retrieve(session.setup_intent)
    expect(setup_intent.payment_method_types).to eq(["card"])
  end

  context "when creating a subscription" do
    it "requires line_items" do
      expect do
        session = Stripe::Checkout::Session.create(
          customer: "customer_id",
          success_url: "localhost/nada",
          **card_payment_method_types,
          mode: "subscription",
        )
      end.to raise_error(Stripe::InvalidRequestError, /line_items/i)

    end
  end

  context "retrieve a checkout session" do
    let(:checkout_session1) { stripe_helper.create_checkout_session }

    it "can be retrieved by id" do
      checkout_session1

      checkout_session = Stripe::Checkout::Session.retrieve(checkout_session1.id)

      expect(checkout_session.id).to eq(checkout_session1.id)
    end

    it "cannot retrieve a checkout session that doesn't exist" do
      expect { Stripe::Checkout::Session.retrieve("nope") }.to raise_error { |e|
        expect(e).to be_a Stripe::InvalidRequestError
        expect(e.param).to eq("checkout_session")
        expect(e.http_status).to eq(404)
      }
    end

    it "can expand setup_intent" do
      initial_session = Stripe::Checkout::Session.create(
        mode: "setup",
        success_url: "https://example.com",
        **card_payment_method_types
      )

      checkout_session = Stripe::Checkout::Session.retrieve(id: initial_session.id, expand: ["setup_intent"])

      expect(checkout_session.setup_intent).to be_a_kind_of(Stripe::SetupIntent)
    end
  end

  it "sets payment_method_types from allowed and excluded payment method types" do
    session = Stripe::Checkout::Session.create(
      mode: "setup",
      allowed_payment_method_types: ["card", "sepa_debit", "us_bank_account"],
      excluded_payment_method_types: ["us_bank_account"],
      success_url: "https://example.com/success"
    )

    expect(session.payment_method_types).to eq(["card", "sepa_debit"])
    expect(Stripe::SetupIntent.retrieve(session.setup_intent).payment_method_types).to eq(["card", "sepa_debit"])
  end

  it "rejects payment_method_types on stripe >= 20" do
    skip "payment_method_types is still supported in stripe #{Stripe::VERSION}" unless StripeMock::Compat.stripe_gte_20?

    expect {
      Stripe::Checkout::Session.create(
        mode: "setup",
        payment_method_types: ["card"],
        success_url: "https://example.com/success"
      )
    }.to raise_error { |e|
      expect(e).to be_a(Stripe::InvalidRequestError)
      expect(e.http_status).to eq(400)
      expect(e.code).to eq("payment_method_types_no_longer_supported")
    }
  end
end
