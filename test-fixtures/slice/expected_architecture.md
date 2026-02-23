# Architecture: submit-order

## Call Path

1. **OrderController.createOrder** (`src/main/java/com/contextslice/fixture/OrderController.java:15`)
   - Annotations: `@PostMapping`
   - Entry point for the submit-order scenario

2. **StripeOrderService.createOrder** (`src/main/java/com/contextslice/fixture/StripeOrderService.java:17`)
   - Annotations: `@Override`, `@Transactional`
   - Concrete implementation of `OrderService` resolved at runtime

3. **StripePaymentService.charge** (`src/main/java/com/contextslice/fixture/StripePaymentService.java:16`)
   - Annotations: `@Override`
   - Concrete implementation of `PaymentService` resolved at runtime
   - Reads config: `order.payment.provider` = `stripe`

## Interfaces Expanded

- `OrderService` — implemented by `StripeOrderService` (runtime-confirmed)
- `PaymentService` — implemented by `StripePaymentService` (runtime-confirmed)

## Notes

- `MockPaymentService` implements `PaymentService` but was **not** active during this scenario (@Profile("test"))
- All hot-path edges confirmed by runtime instrumentation (call_count >= 1)
