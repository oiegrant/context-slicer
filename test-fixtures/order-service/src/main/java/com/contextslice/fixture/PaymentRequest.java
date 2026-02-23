package com.contextslice.fixture;

public class PaymentRequest {
    private String customerId;
    private double amount;
    private String currency;

    public PaymentRequest(String customerId, double amount, String currency) {
        this.customerId = customerId;
        this.amount = amount;
        this.currency = currency;
    }

    public String getCustomerId() { return customerId; }
    public double getAmount() { return amount; }
    public String getCurrency() { return currency; }
}
