# Architecture: submit-order

## Call Path

1. `com.contextslice.fixture.OrderController::createOrder(OrderRequest)`
2. `com.contextslice.fixture.OrderService::createOrder(OrderRequest)`
3. `com.contextslice.fixture.StripeOrderService::createOrder(OrderRequest)`
4. `com.contextslice.fixture.OrderRequest::getAmount()`
5. `com.contextslice.fixture.OrderRequest::getCustomerId()`
6. `OrderResponse`
7. `PaymentRequest`
8. `com.contextslice.fixture.PaymentResult::getErrorMessage()`
9. `com.contextslice.fixture.PaymentResult::getTransactionId()`
10. `com.contextslice.fixture.PaymentResult::isSuccess()`
11. `com.contextslice.fixture.PaymentService::charge(PaymentRequest)`
12. `com.contextslice.fixture.StripePaymentService::charge(PaymentRequest)`
13. `PaymentResult`

## Source Files

- `src/main/java/com/contextslice/fixture/OrderController.java`
- `src/main/java/com/contextslice/fixture/OrderService.java`
- `src/main/java/com/contextslice/fixture/StripeOrderService.java`
- `src/main/java/com/contextslice/fixture/OrderRequest.java`
- `src/main/java/com/contextslice/fixture/OrderResponse.java`
- `src/main/java/com/contextslice/fixture/PaymentRequest.java`
- `src/main/java/com/contextslice/fixture/PaymentResult.java`
- `src/main/java/com/contextslice/fixture/PaymentService.java`
- `src/main/java/com/contextslice/fixture/StripePaymentService.java`
