#!/usr/bin/env python3

# blob-storage-price.py
# Copyright 2025 by Maxim Masiutin. All rights reserved.

from typing import List, Dict, Tuple, Optional, Set
import json
from argparse import ArgumentParser
from collections import defaultdict
import sys
import requests
from tabulate import tabulate


def fetch_azure_prices(params: Optional[Dict[str, str]]) -> List[Dict[str, any]]:
    """Fetch Azure retail prices from the API."""
    api_url = "https://prices.azure.com/api/retail/prices"
    items = []

    while True:
        response = requests.get(api_url, params=params)
        if response.status_code != 200:
            sys.exit(f"Error fetching data: {response.status_code}")
        data = response.json()
        items.extend(data.get("Items", []))
        api_url = data.get("NextPageLink")
        if not api_url:
            break
        params = None  # Clear params for subsequent requests

    return items


def parse_arguments() -> Tuple[List[str], Dict[str, str]]:
    """Parse command-line arguments."""
    default_blob_types = [
        "Standard Page Blob v2",
        "Standard Page Blob",
        "General Block Blob",
        "Blob Storage",
        "Premium Block Blob",
        "General Block Blob v2",
    ]

    parser = ArgumentParser(description="Calculate Azure blob storage prices by region")
    parser.add_argument(
        "--blob-types",
        default=",".join(default_blob_types),
        help="Comma-separated list of blob types (default: %(default)s)",
    )
    args = parser.parse_args()

    blob_types = [t.strip() for t in args.blob_types.split(",")]
    if not blob_types:
        sys.exit("No blob types specified")

    product_filter = " or ".join(f"productName eq '{blob_type}'" for blob_type in blob_types)
    params = {
        "$filter": f"({product_filter}) and priceType eq 'Consumption' and serviceName eq 'Storage'"
    }

    return blob_types, params


def process_items(items: List[Dict[str, any]]) -> Tuple[
    Dict[Tuple[str, str, str], Set[str]],
    Dict[Tuple[str, str, str], Dict[str, float]],
    Set[str],
    Set[str],
]:
    """Process fetched items to extract regions, services, and prices."""
    service_regions = defaultdict(set)
    service_prices = defaultdict(dict)
    all_regions = set()
    excluded_regions = set()

    for item in items:
        region = item.get("armRegionName", "").lower()
        if not region or region == "global":
            excluded_regions.add(region or "Unknown")
            continue

        product_name = item.get("productName", "")
        sku_name = item.get("skuName", "")
        meter_name = item.get("meterName", "")
        retail_price = item.get("retailPrice", 0.0)

        service_key = (product_name, sku_name, meter_name)
        service_regions[service_key].add(region)
        service_prices[service_key][region] = retail_price
        all_regions.add(region)

    return service_regions, service_prices, all_regions, excluded_regions


def calculate_region_prices(
    service_regions: Dict[Tuple[str, str, str], Set[str]],
    service_prices: Dict[Tuple[str, str, str], Dict[str, float]],
    all_regions: Set[str],
) -> Dict[str, List[float]]:
    """Calculate prices for each region."""
    region_prices = defaultdict(list)

    for service, regions in service_regions.items():
        for region in all_regions:
            price = service_prices[service].get(region)
            if price is not None:
                region_prices[region].append(price)

    return region_prices


def calculate_average_prices(region_prices: Dict[str, List[float]]) -> List[Tuple[str, float]]:
    """Calculate average prices for each region."""
    region_avg_prices = [
        (region, sum(prices) / len(prices))
        for region, prices in region_prices.items()
        if prices
    ]
    return sorted(region_avg_prices, key=lambda x: x[1])


def print_results(
    blob_types: List[str],
    region_avg_prices: List[Tuple[str, float]],
    excluded_regions: Set[str],
) -> None:
    """Print the results in a tabular format."""
    if excluded_regions:
        print("\nExcluded regions:")
        for region in excluded_regions:
            print(f"- {region}")
    else:
        print("\nNo regions were excluded.")

    table_caption = (
        f"Average blob storage services ({', '.join(blob_types)}) price per region"
        if len(blob_types) > 1
        else f"Blob storage service ({blob_types[0]}) price per region"
    )
    print("\n" + table_caption)
    headers = ["Region", "Average Price (USD)"]
    print(tabulate(region_avg_prices, headers=headers, tablefmt="psql"))


def main() -> None:
    print("Requesting Azure blob storage price data, please stand by...")

    blob_types, params = parse_arguments()
    items = fetch_azure_prices(params)
    print(f"Total items fetched: {len(items)}")

    service_regions, service_prices, all_regions, excluded_regions = process_items(items)
    print(f"Total regions found (excluding 'Global'): {len(all_regions)}")
    print(f"Total services found: {len(service_regions)}")

    region_prices = calculate_region_prices(service_regions, service_prices, all_regions)
    region_avg_prices = calculate_average_prices(region_prices)

    print_results(blob_types, region_avg_prices, excluded_regions)


if __name__ == "__main__":
    main()
