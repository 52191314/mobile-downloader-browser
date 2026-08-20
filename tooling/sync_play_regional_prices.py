#!/usr/bin/env python3
"""
sync_play_regional_prices.py

Automates Regional Pricing & Purchasing Power Parity (PPP) for Aurora Downloader
in-app products on Google Play Console using the Google Play Developer API.

Usage:
  python tooling/sync_play_regional_prices.py --key service_account.json [--dry-run]

Requirements:
  pip install google-api-python-client google-auth
"""

import argparse
import json
import sys
from typing import Dict, Any

# Target package ID
PACKAGE_NAME = "com.personal.aurora_downloader"

# Products and their base USD prices
PRODUCTS = [
    {
        "sku": "aurora_pro_unlock",
        "title": "Aurora Pro Unlock (Lifetime)",
        "base_usd": 1.99,
    },
    {
        "sku": "aurora_ultra_unlock",
        "title": "Aurora Ultra Unlock (Lifetime)",
        "base_usd": 5.99,
    },
    {
        "sku": "aurora_ultra_upgrade",
        "title": "Aurora Pro to Ultra Upgrade",
        "base_usd": 3.99,
    },
]

# Purchasing Power Parity (PPP) multipliers and standard currency formatting rules
# Tier 1 (1.0x): US, CA, EU, UK, AU, JP, CH, SG, etc.
# Tier 2 (0.6x - 0.7x): KR, TW, PL, CZ, SA, AE, etc.
# Tier 3 (0.3x - 0.4x): IN, BR, ID, VN, PH, TH, MX, TR, EG, NG, PK, BD, etc.
REGIONAL_PROFILES = {
    # Tier 3 — High volume, price-sensitive emerging markets
    "IN": {"currency": "INR", "mult": 0.30, "round_to": "int", "ending": 49},   # ₹49 / ₹179 / ₹119
    "BR": {"currency": "BRL", "mult": 0.45, "round_to": "99"},                 # R$4.99 / R$14.99 / R$9.99
    "ID": {"currency": "IDR", "mult": 0.30, "round_to": "int_k", "ending": 15000}, # Rp 15,000 / Rp 45,000
    "VN": {"currency": "VND", "mult": 0.30, "round_to": "int_k", "ending": 25000}, # 25,000 ₫ / 79,000 ₫
    "PH": {"currency": "PHP", "mult": 0.40, "round_to": "int", "ending": 49},   # ₱49 / ₱149 / ₱99
    "TH": {"currency": "THB", "mult": 0.40, "round_to": "int", "ending": 39},   # ฿39 / ฿119 / ฿79
    "MX": {"currency": "MXN", "mult": 0.45, "round_to": "99"},                 # MX$19.99 / MX$59.99
    "TR": {"currency": "TRY", "mult": 0.35, "round_to": "99"},                 # ₺29.99 / ₺89.99
    "EG": {"currency": "EGP", "mult": 0.30, "round_to": "99"},                 # EGP 29.99 / EGP 89.99
    "NG": {"currency": "NGN", "mult": 0.30, "round_to": "int_k", "ending": 1500}, # ₦1,500 / ₦4,500
    "PK": {"currency": "PKR", "mult": 0.30, "round_to": "int", "ending": 199},  # Rs 199 / Rs 599
    "BD": {"currency": "BDT", "mult": 0.30, "round_to": "int", "ending": 99},   # ৳99 / ৳299
    "CO": {"currency": "COP", "mult": 0.40, "round_to": "int_k", "ending": 3900}, # COP 3,900 / 11,900
    "ZA": {"currency": "ZAR", "mult": 0.45, "round_to": "99"},                 # R 19.99 / R 59.99
    "AR": {"currency": "ARS", "mult": 0.35, "round_to": "int_k", "ending": 990}, # ARS 990 / 2990

    # Tier 2 — Mid-range economies
    "KR": {"currency": "KRW", "mult": 0.75, "round_to": "int_k", "ending": 1900}, # ₩1,900 / ₩5,900
    "TW": {"currency": "TWD", "mult": 0.75, "round_to": "int", "ending": 50},   # NT$50 / NT$150
    "PL": {"currency": "PLN", "mult": 0.70, "round_to": "99"},                 # zł 6.99 / zł 19.99
    "CZ": {"currency": "CZK", "mult": 0.70, "round_to": "int", "ending": 39},   # 39 Kč / 119 Kč
    "HU": {"currency": "HUF", "mult": 0.65, "round_to": "int", "ending": 690},  # 690 Ft / 1990 Ft
    "SA": {"currency": "SAR", "mult": 0.85, "round_to": "99"},                 # SAR 7.99 / SAR 23.99
    "AE": {"currency": "AED", "mult": 0.85, "round_to": "99"},                 # AED 7.99 / AED 23.99

    # Tier 1 — Standard high-income baseline (1.0x)
    "US": {"currency": "USD", "mult": 1.00, "round_to": "99"},                 # $1.99 / $5.99 / $3.99
    "GB": {"currency": "GBP", "mult": 1.00, "round_to": "99"},                 # £1.79 / £4.99 / £3.49
    "DE": {"currency": "EUR", "mult": 1.00, "round_to": "99"},                 # €1.99 / €5.99 / €3.99
    "FR": {"currency": "EUR", "mult": 1.00, "round_to": "99"},
    "IT": {"currency": "EUR", "mult": 1.00, "round_to": "99"},
    "ES": {"currency": "EUR", "mult": 0.90, "round_to": "99"},
    "CA": {"currency": "CAD", "mult": 1.00, "round_to": "99"},
    "AU": {"currency": "AUD", "mult": 1.00, "round_to": "99"},
    "JP": {"currency": "JPY", "mult": 1.00, "round_to": "int", "ending": 250},  # ¥250 / ¥750 / ¥500
    "CH": {"currency": "CHF", "mult": 1.00, "round_to": "95"},
}

def calculate_local_price_micros(base_usd: float, country_code: str) -> Dict[str, Any]:
    """Calculate price in micro-units (price * 1,000,000) based on PPP multipliers."""
    profile = REGIONAL_PROFILES.get(country_code, {"currency": "USD", "mult": 1.0, "round_to": "99"})
    currency = profile["currency"]
    mult = profile.get("mult", 1.0)
    
    fx_rates = {
        "USD": 1.0, "EUR": 0.92, "GBP": 0.79, "INR": 86.5, "BRL": 5.60,
        "IDR": 16000.0, "VND": 25000.0, "PHP": 58.0, "THB": 35.0, "MXN": 19.5,
        "TRY": 34.0, "EGP": 48.0, "NGN": 1600.0, "PKR": 278.0, "BDT": 120.0,
        "COP": 4100.0, "ZAR": 18.0, "ARS": 980.0, "KRW": 1380.0, "TWD": 32.5,
        "PLN": 4.0, "CZK": 23.5, "HUF": 365.0, "SAR": 3.75, "AED": 3.67,
        "CAD": 1.38, "AUD": 1.52, "JPY": 152.0, "CHF": 0.88,
    }
    
    fx = fx_rates.get(currency, 1.0)
    raw_local = base_usd * fx * mult
    
    round_type = profile.get("round_to", "99")
    if round_type == "99":
        val = max(0.99, round(raw_local) - 0.01 if round(raw_local) > raw_local else round(raw_local) + 0.99)
        val = round(val, 2)
    elif round_type == "95":
        val = round(raw_local * 2) / 2 - 0.05
        val = round(val, 2)
    elif round_type == "int":
        if base_usd <= 2.0:
            val = float(profile.get("ending", round(raw_local)))
        else:
            if raw_local < 100:
                val = max(9.0, round(raw_local / 10) * 10 - 1)
            else:
                val = max(49.0, round(raw_local / 50) * 50 - 1)
    elif round_type == "int_k":
        if base_usd <= 2.0:
            val = float(profile.get("ending", max(100.0, round(raw_local / 500) * 500)))
        else:
            val = max(1000.0, round(raw_local / 500) * 500)
    else:
        val = round(raw_local, 2)

    val = max(val, 0.99)
    price_micros = int(val * 1_000_000)
    return {
        "currency": currency,
        "priceMicros": str(price_micros),
        "displayPrice": f"{val:,.2f} {currency}",
    }


def main():
    parser = argparse.ArgumentParser(description="Sync Regional PPP Prices to Google Play Developer API")
    parser.add_argument(
        "--key",
        required=False,
        default="secret/aurora-503413-e73b026ea355.json",
        help="Path to Service Account JSON key"
    )
    parser.add_argument("--dry-run", action="store_true", help="Print price calculations without calling Google Play API")
    args = parser.parse_args()

    print("=" * 70)
    print("AURORA DOWNLOADER — REGIONAL PPP PRICING CALCULATOR")
    print(f"Package: {PACKAGE_NAME}")
    print("=" * 70)

    for product in PRODUCTS:
        sku = product["sku"]
        base_usd = product["base_usd"]
        print(f"\nProduct: {product['title']} ({sku}) — Base: ${base_usd} USD")
        print("-" * 70)
        print(f"{'Country':<10} | {'Currency':<8} | {'Calculated Price':<20} | {'Price in Micros':<15}")
        print("-" * 70)

        prices_payload = {}
        for country, prof in REGIONAL_PROFILES.items():
            calc = calculate_local_price_micros(base_usd, country)
            prices_payload[country] = {
                "currency": calc["currency"],
                "priceMicros": calc["priceMicros"],
            }
            print(f"{country:<10} | {calc['currency']:<8} | {calc['displayPrice']:<20} | {calc['priceMicros']:<15}")

        if args.dry_run:
            continue

        try:
            from google.oauth2 import service_account
            from googleapiclient.discovery import build

            creds = service_account.Credentials.from_service_account_file(
                args.key,
                scopes=["https://www.googleapis.com/auth/androidpublisher"]
            )
            service = build("androidpublisher", "v3", credentials=creds)

            body = {
                "packageName": PACKAGE_NAME,
                "sku": sku,
                "status": "active",
                "defaultPrice": {
                    "currency": "USD",
                    "priceMicros": str(int(base_usd * 1_000_000)),
                },
                "prices": prices_payload,
            }

            res = service.inappproducts().patch(
                packageName=PACKAGE_NAME,
                sku=sku,
                autoConvertMissingPrices=True,
                body=body,
            ).execute()

            print(f"Successfully synced SKU {sku} to Google Play Console!")
        except ImportError:
            print("\nMissing libraries. Install them via: pip install google-api-python-client google-auth")
            sys.exit(1)
        except Exception as e:
            print(f"\nError updating SKU {sku}: {e}")

    print("\n" + "=" * 70)
    if args.dry_run:
        print("Dry run complete. No changes were sent to Google Play.")
    else:
        print("All SKUs synced. Changes will propagate across Google Play within 1-4 hours.")
    print("=" * 70)

if __name__ == "__main__":
    main()
