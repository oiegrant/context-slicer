package com.contextslice.fixture;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class StripeOrderService implements OrderService {

    @Autowired
    private PaymentService paymentService;

    @Override
    @Transactional
    public OrderResponse createOrder(OrderRequest request) {
        PaymentRequest paymentRequest = new PaymentRequest(
            request.getCustomerId(),
            request.getAmount(),
            "USD"
        );
        PaymentResult result = paymentService.charge(paymentRequest);
        if (!result.isSuccess()) {
            throw new RuntimeException("Payment failed: " + result.getErrorMessage());
        }
        String orderId = UUID.randomUUID().toString();
        return new OrderResponse(orderId, "CONFIRMED", result.getTransactionId());
    }
}
