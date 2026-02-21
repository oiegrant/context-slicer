package com.contextslice.fixture;

/**
 * Interface for order processing.
 * Implementation: StripeOrderService.
 */
public interface OrderService {
    OrderResponse createOrder(OrderRequest request);
}
