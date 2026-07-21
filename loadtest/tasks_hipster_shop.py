# ============================================================================
# tasks_hipster_shop.py — Locust user for the Hipster Shop / Online Boutique
# frontend (Google microservices-demo). Mirrors the demo's own locustfile
# flow so traffic exercises the full service graph -> logs + traces aligned
# with the load (ISI-1779 methodology).
#
# Run headless against http://frontend.hipster-shop:80.
# Same BenchmarkShape as otel-demo -> identical VU profile on both apps.
# ============================================================================
import random

from locust import HttpUser, between, task

from loadshape import BenchmarkShape  # noqa: F401  (discovered by Locust)

# Product ids from the Online Boutique catalog.
PRODUCTS = [
    "0PUK6V6EV0", "1YMWWN1N4O", "2ZYFJ3GM2N", "66VCHSJNUP", "6E92ZMYYFZ",
    "9SIQT8TOJO", "L9ECAV7KIM", "LS4PSXUNUM", "OLJCESPC7Z",
]
CURRENCIES = ["EUR", "USD", "JPY", "CAD", "GBP", "TRY"]


class HipsterShopUser(HttpUser):
    wait_time = between(1, 5)

    @task(1)
    def index(self):
        self.client.get("/", name="index")

    @task(2)
    def set_currency(self):
        self.client.post(
            "/setCurrency",
            data={"currency_code": random.choice(CURRENCIES)},
            name="set_currency",
        )

    @task(10)
    def browse_product(self):
        self.client.get("/product/" + random.choice(PRODUCTS), name="browse_product")

    @task(3)
    def view_cart(self):
        self.client.get("/cart", name="view_cart")

    @task(2)
    def add_to_cart(self):
        pid = random.choice(PRODUCTS)
        self.client.get("/product/" + pid, name="browse_product")
        self.client.post(
            "/cart",
            data={"product_id": pid, "quantity": random.choice([1, 2, 3, 4, 5, 10])},
            name="add_to_cart",
        )

    @task(1)
    def checkout(self):
        pid = random.choice(PRODUCTS)
        self.client.post(
            "/cart",
            data={"product_id": pid, "quantity": random.choice([1, 2, 3])},
            name="add_to_cart",
        )
        self.client.post(
            "/cart/checkout",
            data={
                "email": "someone@example.com",
                "street_address": "1600 Amphitheatre Parkway",
                "zip_code": "94043",
                "city": "Mountain View",
                "state": "CA",
                "country": "United States",
                "credit_card_number": "4432-8015-6152-0454",
                "credit_card_expiration_month": "1",
                "credit_card_expiration_year": "2030",
                "credit_card_cvv": "672",
            },
            name="checkout",
        )
