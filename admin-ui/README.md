# Admin UI authentication

Current low-budget deployment uses two independent credentials:

- Mount an htpasswd file at `/run/secrets/openpay_admin_htpasswd`. Nginx Basic authentication protects HTML, assets, readiness routes, session bootstrap, and analytics. `/ui-healthz` is the only public route.
- Set `OPENPAY_ADMIN_BACKEND_TOKEN` at runtime through the deployment secret manager. Value must contain 32 to 2,048 bearer-safe bytes.

Container refuses startup when either credential is absent or malformed. Htpasswd file must be a regular, readable 1-to-16,384-byte file; contain at most 64 unique usernames; use bounded usernames matching `[A-Za-z0-9._@-]`; contain bcrypt or SHA-512 crypt password hashes; and have mode `0400`, `0440`, `0444`, `0600`, `0640`, or `0644`. Generate hashes with a trusted tool and strong work factor. Never use plaintext, legacy SHA-1, or committed production hashes.

After Basic authentication, Nginx replaces browser `Authorization` with backend bearer authentication while proxying `/backend/v1/session/bootstrap` and `/backend/v1/analytics/sales`. It forwards bounded authenticated username as `X-OpenPay-Admin-User`. Backend never receives Basic credentials. Browser JavaScript never receives, stores, or sends backend token. Do not bake credentials into image, source, Compose used outside tests, command-line arguments, or browser config.

`GET /v1/session/bootstrap` must derive `tenant_id` and opaque `session_cache_id` from the verified backend principal. It returns `Cache-Control: private, no-store` and `Vary: Authorization`. Analytics returns its existing private revalidation headers.

Rotate current access by replacing mounted htpasswd/backend-token secrets, then restarting container. No current browser-managed login, logout, or token rotation exists.

This bridge is transitional. Replace Basic authentication with administrator OAuth backed by a Secure, HttpOnly, SameSite session cookie. Future token exchange, refresh, logout, CSRF protection, and session rotation belong to backend; browser-facing analytics client remains bearer-token blind.
