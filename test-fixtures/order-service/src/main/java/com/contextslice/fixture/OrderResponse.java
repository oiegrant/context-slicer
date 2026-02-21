package com.contextslice.fixture;

public class OrderResponse {
    private String orderId;
    private String status;
    private String paymentRef;

    public OrderResponse(String orderId, String status, String paymentRef) {
        this.orderId = orderId;
        this.status = status;
        this.paymentRef = paymentRef;
    }

    public String getOrderId() { return orderId; }
    public String getStatus() { return status; }
    public String getPaymentRef() { return paymentRef; }
}
