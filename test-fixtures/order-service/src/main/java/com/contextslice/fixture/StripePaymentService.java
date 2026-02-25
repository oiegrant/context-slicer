package com.contextslice.fixture;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Service;

@Service
public class StripePaymentService implements PaymentService {

    @Autowired
    private Environment environment;

    @Override
    public PaymentResult charge(PaymentRequest request) {
        String provider = environment.getProperty("order.payment.provider");
        if (!"stripe".equals(provider)) {
            return new PaymentResult(false, null, null, "Provider mismatch: expected stripe, got " + provider);
        }
        // Simulate successful Stripe charge
        String transactionId = "stripe-txn-" + System.currentTimeMillis();
        String chargeId = "ch_" + System.currentTimeMillis();
        return new PaymentResult(true, transactionId, chargeId, null);
    }
}
