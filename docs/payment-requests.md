# Payment request credit allocation

Payment requests are customer-scoped. They intentionally contain no organization or installation identifier, and each balance is keyed only by `(customer_id, currency)`. An application must not treat its own organization identifier as a customer-credit account.

Creation locks that balance. A sufficient balance charges the request atomically; otherwise the request is stored as `pending`. The policy is deliberately all-or-nothing: a short balance is not partially consumed, and a smaller later request cannot bypass an older shortfall. Set `PAYMENT_REQUEST_PENDING_EXPIRY_DAYS` to a value no lower than 30 days; the conservative default is 90.

A committed provider-credit deposit emits an after-commit event. Its database-queue listener posts the credit once, expires overdue requests, and allocates the remaining unexpired requests by `created_at`, then UUID. Allocation events also dispatch after commit, so callbacks must consume those events rather than reading uncommitted request state. Currency balances never mix. Late deposits leave expired requests expired and available credit unallocated.
