package com.contextslice.fixture;

import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;

/**
 * Mock payment service — only active under the "test" profile.
 * Should NOT appear in a production slice of the submit-order scenario.
 */
@Service
@Profile("test")
public class MockPaymentService implements PaymentService {

    @Override
    public PaymentResult charge(PaymentRequest request) {
        return new PaymentResult(true, "mock-txn-001", "ch_mock001", null);
    }
}
