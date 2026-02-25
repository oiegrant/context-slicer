package com.contextslice.fixture;

public class PaymentResult {
    private final boolean success;
    private final String transactionId;
    private final String chargeId;
    private final String errorMessage;

    public PaymentResult(boolean success, String transactionId, String chargeId, String errorMessage) {
        this.success = success;
        this.transactionId = transactionId;
        this.chargeId = chargeId;
        this.errorMessage = errorMessage;
    }

    public boolean isSuccess() { return success; }
    public String getTransactionId() { return transactionId; }
    public String getChargeId() { return chargeId; }
    public String getErrorMessage() { return errorMessage; }
}
