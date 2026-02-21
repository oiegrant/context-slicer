package com.contextslice.fixture;

/**
 * Interface for payment processing.
 * Has two implementations: StripePaymentService (active) and MockPaymentService (inactive).
 */
public interface PaymentService {
    PaymentResult charge(PaymentRequest request);
}
