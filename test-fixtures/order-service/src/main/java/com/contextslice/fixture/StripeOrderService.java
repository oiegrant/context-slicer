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
        // Mutate request in-place so transform capture shows orderId/status going from null → value
        request.setOrderId(UUID.randomUUID().toString());
        request.setStatus("PROCESSING");

        PaymentRequest paymentRequest = new PaymentRequest(
            request.getCustomerId(),
            request.getAmount(),
            "USD"
        );
        PaymentResult result = paymentService.charge(paymentRequest);
        if (!result.isSuccess()) {
            throw new RuntimeException("Payment failed: " + result.getErrorMessage());
        }
        return new OrderResponse(request.getOrderId(), "CONFIRMED", result.getTransactionId());
    }
}
