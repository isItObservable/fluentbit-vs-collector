# ============================================================================
# tasks_otel_demo.py — Locust user for the OpenTelemetry Demo frontend.
#
# Drives the demo's frontend HTTP API so the request load produces logs AND
# traces aligned with the load (ISI-1779 methodology). Run headless against
# http://opentelemetry-demo-frontend.otel-demo:8080.
#
# The BenchmarkShape import is what makes this file phase-aware — Locust
# discovers the LoadTestShape subclass in this module's namespace.
# ============================================================================
import random

from locust import HttpUser, between, task

from loadshape import BenchmarkShape  # noqa: F401  (discovered by Locust)

# Static product ids shipped by the OTel demo catalog.
PRODUCTS = [
    "0PUK6V6EV0", "1YMWWN1N4O", "2ZYFJ3GM2N", "66VCHSJNUP",
    "6E92ZMYYFZ", "9SIQT8TOJO", "L9ECAV7KIM", "LS4PSXUNUM", "OLJCESPC7Z",
]


class OtelDemoUser(HttpUser):
    wait_time = between(1, 5)

    @task(2)
    def index(self):
        self.client.get("/", name="index")

    @task(5)
    def browse_product(self):
        pid = random.choice(PRODUCTS)
        self.client.get(f"/api/products/{pid}", name="get_product")
        self.client.get(
            f"/api/recommendations?productIds={pid}", name="get_recommendations"
        )

    @task(3)
    def get_cart(self):
        self.client.get("/api/cart", name="get_cart")

    @task(2)
    def list_currency(self):
        # otel-demo currency is a GET list; selection is client-side, so the
        # load-relevant server call is the list fetch.
        self.client.get("/api/currency", name="list_currency")

    @task(2)
    def add_to_cart(self):
        pid = random.choice(PRODUCTS)
        self.client.post(
            "/api/cart",
            json={"item": {"productId": pid, "quantity": random.randint(1, 5)},
                  "userId": "loadtest"},
            name="add_to_cart",
        )

    @task(1)
    def checkout(self):
        pid = random.choice(PRODUCTS)
        self.client.post(
            "/api/cart",
            json={"item": {"productId": pid, "quantity": random.randint(1, 3)},
                  "userId": "loadtest"},
            name="add_to_cart",
        )
        self.client.post(
            "/api/checkout",
            json={
                "userId": "loadtest",
                "email": "someone@example.com",
                "address": {
                    "streetAddress": "1600 Amphitheatre Parkway",
                    "city": "Mountain View", "state": "CA",
                    "country": "United States", "zipCode": "94043",
                },
                "userCurrency": "USD",
                "creditCard": {
                    "creditCardNumber": "4432-8015-6152-0454",
                    "creditCardCvv": 672,
                    "creditCardExpirationYear": 2030,
                    "creditCardExpirationMonth": 1,
                },
            },
            name="checkout",
        )
