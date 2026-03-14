
import os
import json
import time
import uuid
import random
import logging
import argparse
from dataclasses import dataclass
from typing import Dict, List, Tuple

from faker import Faker
from kafka import KafkaProducer

fake = Faker()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("generator")

COUNTRIES = ["ES", "FR", "DE", "IT", "NL", "BE", "PT", "GB", "US", "BR", "MX", "JP", "SG", "AU"]
CURRENCIES = ["EUR", "EUR", "EUR", "EUR", "USD"]  # skew to EUR
MERCHANTS = [
    # Grocery & Supermarkets
    "mercadona-001", "carrefour-madrid", "lidl-barcelona", "aldi-sevilla",
    "el-corte-ingles-food", "dia-supermercados", "eroski-bilbao", "coviran-granada",
    # Restaurants & Cafes
    "mcdonalds-gran-via", "burger-king-passeig", "starbucks-callao", "taco-bell-castellana",
    "vips-montera", "telepizza-online", "dominos-delivery", "foster-hollywood",
    "100-montaditos", "dunkin-donuts-sol", "five-guys-malasana", "la-tagliatella",
    # Fuel & Transport
    "repsol-station-a4", "bp-fuel-m30", "cepsa-m40-norte", "galp-getafe",
    "renfe-ave-online", "blablacar-ride", "cabify-madrid", "bolt-ride-bcn",
    "aena-parking-t4", "emtmadrid-card",
    # Retail & Fashion
    "zara-serrano", "hm-preciados", "mango-paseo-gracia", "primark-gran-via",
    "pull-and-bear-online", "bershka-barcelona", "massimo-dutti", "nike-factory",
    "adidas-flagship-mad", "decathlon-alcobendas", "ikea-vallecas", "leroy-merlin",
    "mediamarkt-xanadu", "fnac-callao", "el-corte-ingles-tech", "pccomponentes",
    # Entertainment & Streaming
    "netflix-monthly", "spotify-premium", "amazon-prime-es", "hbo-max-sub",
    "disney-plus-sub", "twitch-subscribe", "steam-games", "playstation-store",
    "xbox-gamepass", "apple-itunes-es",
    # Travel & Hotels
    "booking-hotel-mad", "airbnb-host-bcn", "iberia-flights", "vueling-online",
    "ryanair-booking", "easy-jet-web", "melia-hotel-mad", "nh-hoteles",
    "marriott-madrid", "hilton-barcelona",
    # Health & Pharmacy
    "farmacia-el-globo", "farmacia-mayor-1", "clinica-baviera", "sanitas-cuota",
    "adeslas-seguro", "gympass-monthly", "fitness-first-mad", "anytime-fitness",
    # Utilities & Telecom
    "movistar-factura", "vodafone-es", "orange-spain", "jazztel-fibra",
    "endesa-luz", "iberdrola-hogar", "naturgy-gas", "ayto-madrid-iba",
    # eCommerce & Marketplaces
    "amazon-es-shop", "aliexpress-order", "ebay-purchase", "zalando-order",
    "pccomponentes-web", "elcorteingles-web", "carrefour-online", "ulabox-delivery",
    # Food Delivery
    "glovo-delivery", "uber-eats-order", "just-eat-es", "deliveroo-bcn",
    # Finance & Insurance
    "paypal-transfer", "revolut-topup", "wise-fx", "coinbase-buy",
    "mapfre-seguro", "linea-directa", "mutua-madrilena", "axa-seguros",
    # High-risk
    "m-666", "m-999",
]

# ─── Card generation ──────────────────────────────────────────────────────────
_CARD_BRANDS: List[Tuple[str, List[str], int]] = [
    ("Visa",             ["4539", "4556", "4916", "4532", "4929"], 16),
    ("Mastercard",       ["5105", "5204", "5303", "5404", "5521"], 16),
    ("American Express", ["3714", "3782", "3787", "3404"],         15),
]
_BRAND_WEIGHTS = [50, 35, 15]


def _luhn_check_digit(partial: str) -> str:
    digits = [int(d) for d in reversed(partial)]
    total = sum(d * 2 - 9 if (i % 2 == 0 and d * 2 > 9)
                else d * 2   if (i % 2 == 0)
                else d
                for i, d in enumerate(digits))
    return str((10 - total % 10) % 10)


def _generate_card() -> Tuple[str, str, str]:
    """Return (pan, masked_pan, brand). PAN is never emitted."""
    brand, prefixes, length = random.choices(_CARD_BRANDS, weights=_BRAND_WEIGHTS, k=1)[0]
    prefix = random.choice(prefixes)
    middle = "".join(str(random.randint(0, 9)) for _ in range(length - len(prefix) - 1))
    pan    = prefix + middle + _luhn_check_digit(prefix + middle)
    masked = pan[:2] + "*" * (length - 4) + pan[-2:]
    return pan, masked, brand


# ─── Card state ───────────────────────────────────────────────────────────────
@dataclass
class CardState:
    account_id:    str
    masked_pan:    str
    card_brand:    str
    last_country:  str
    last_event_ms: int


def now_ms() -> int:
    return int(time.time() * 1000)


def mk_tx(card_id: str, st: CardState, *,
          amount: float,
          merchant_id: str,
          country: str,
          event_ms: int) -> Dict:
    return {
        "txId":       uuid.uuid4().hex,
        "cardId":     card_id,
        "cardNumber": st.masked_pan,
        "cardBrand":  st.card_brand,
        "accountId":  st.account_id,
        "amount":     round(float(amount), 2),
        "currency":   random.choice(CURRENCIES),
        "merchantId": merchant_id,
        "country":    country,
        "eventTime":  int(event_ms),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bootstrap",              default=os.getenv("KAFKA_BOOTSTRAP", "my-cluster-kafka-bootstrap.kafka:9092"))
    ap.add_argument("--topic",                  default=os.getenv("TX_TOPIC", "transactions"))
    ap.add_argument("--rate",                   type=float, default=10.0)
    ap.add_argument("--cards",                  type=int,   default=200)
    ap.add_argument("--burst-rate",             type=float, default=0.000005,
                    help="probability [0-1] that an iteration triggers a velocity burst (R2)")
    ap.add_argument("--burst-size",             type=int,   default=8)
    ap.add_argument("--high-amount-rate",       type=float, default=0.000005,
                    help="probability [0-1] that an iteration triggers a high-value txn (R1)")
    ap.add_argument("--impossible-travel-rate", type=float, default=0.000005,
                    help="probability [0-1] that an iteration triggers an impossible-travel pair (R3)")
    ap.add_argument("--high-amount-threshold",  type=float, default=5000.0)
    ap.add_argument("--normal-amount-max",      type=float, default=120.0)
    ap.add_argument("--min-sleep",              type=float, default=0.0)
    args = ap.parse_args()

    producer = KafkaProducer(
        bootstrap_servers=args.bootstrap,
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8"),
        acks="all",
        linger_ms=5,
    )

    states: Dict[str, CardState] = {}
    start = now_ms()
    for i in range(args.cards):
        card_id = f"card-{i:04d}"
        _, masked, brand = _generate_card()
        states[card_id] = CardState(
            account_id    = f"acct-{fake.bothify(text='####')}",
            masked_pan    = masked,
            card_brand    = brand,
            last_country  = random.choice(COUNTRIES),
            last_event_ms = start - random.randint(0, 60_000),
        )

    base_sleep = 1.0 / max(0.1, args.rate)
    log.info("bootstrap=%s topic=%s cards=%d rate~%.1f/s  "
             "high_amount_rate=%.3f  impossible_travel_rate=%.3f  burst_rate=%.3f",
             args.bootstrap, args.topic, args.cards, args.rate,
             args.high_amount_rate, args.impossible_travel_rate, args.burst_rate)

    def send(tx: Dict):
        producer.send(args.topic, key=tx["cardId"], value=tx)

    try:
        while True:
            card_id = random.choice(list(states.keys()))
            st      = states[card_id]

            t_ms     = max(now_ms(), st.last_event_ms + random.randint(50, 600))
            country  = st.last_country
            merchant = random.choice(MERCHANTS)

            # ── Single weighted roll: one outcome per iteration ───────────────
            # Rates are the independent desired probabilities for each rule.
            # A mutual-exclusive weighted choice means the rates directly control
            # how often each rule fires without the three checks interfering.
            r_normal = max(0.0, 1.0 - args.high_amount_rate
                                     - args.impossible_travel_rate
                                     - args.burst_rate)
            outcome = random.choices(
                ["normal", "high_value", "impossible_travel", "burst"],
                weights=[r_normal,
                         args.high_amount_rate,
                         args.impossible_travel_rate,
                         args.burst_rate],
                k=1,
            )[0]

            if outcome == "high_value":
                amount = max(args.high_amount_threshold,
                             random.uniform(args.high_amount_threshold,
                                            args.high_amount_threshold * 2.0))
                # ── R1 log ────────────────────────────────────────────────────
                log.info("💸 R1 HIGH-VALUE  amount=%.2f  card=%s", amount, st.masked_pan)
                tx = mk_tx(card_id, st, amount=amount, merchant_id=merchant,
                           country=country, event_ms=t_ms)
                send(tx)
                st.last_event_ms = t_ms

            elif outcome == "impossible_travel":
                amount = random.uniform(1.5, args.normal_amount_max)
                c1  = st.last_country
                c2  = random.choice([c for c in COUNTRIES if c != c1])
                # ── R3 log ────────────────────────────────────────────────────
                log.info("🌍 R3 GEO-VELOCITY  card=%s  %s → %s", st.masked_pan, c1, c2)

                tx1 = mk_tx(card_id, st, amount=amount, merchant_id=merchant,
                            country=c1, event_ms=t_ms)
                send(tx1)

                delta_min = random.randint(1, 10)
                t2_ms     = t_ms + delta_min * 60_000 + random.randint(0, 15_000)
                tx2       = mk_tx(card_id, st,
                                  amount=random.uniform(10, args.normal_amount_max),
                                  merchant_id=random.choice(MERCHANTS),
                                  country=c2, event_ms=t2_ms)
                send(tx2)

                st.last_country  = c2
                st.last_event_ms = t2_ms

            elif outcome == "burst":
                burst_start_ms = st.last_event_ms
                for _ in range(args.burst_size):
                    t_ms         = st.last_event_ms + random.randint(100, 1200)
                    burst_amount = random.uniform(30, args.normal_amount_max) * random.uniform(1.0, 2.5)
                    txb          = mk_tx(card_id, st, amount=burst_amount,
                                        merchant_id=random.choice(MERCHANTS),
                                        country=st.last_country, event_ms=t_ms)
                    send(txb)
                    st.last_event_ms = t_ms
                # ── R2 log ────────────────────────────────────────────────────
                log.info("⚡ R2 VELOCITY  card=%s  count=%d  span_ms=%d",
                         st.masked_pan, args.burst_size, st.last_event_ms - burst_start_ms)

            else:  # normal
                amount = random.uniform(1.5, args.normal_amount_max)
                tx = mk_tx(card_id, st, amount=amount, merchant_id=merchant,
                           country=country, event_ms=t_ms)
                send(tx)
                st.last_event_ms = t_ms

            producer.flush(timeout=1)
            time.sleep(max(args.min_sleep, base_sleep))

    except KeyboardInterrupt:
        log.info("stopping...")
    finally:
        producer.flush(timeout=5)
        producer.close()


if __name__ == "__main__":
    main()
