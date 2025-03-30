#!/usr/bin/env python3

# blob-storage-price.py
# Copyright 2025 by Maxim Masiutin. All rights reserved.

# Returns Azure regions sorted by average blob storage price (page/block, premium/general, etc)
# Based on the code example from https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices

from typing import List, Dict, Tuple, Optional, Set, Any
from json import loads
from argparse import ArgumentParser, Namespace
from collections import defaultdict
from sys import exit
from requests import get, Response
from tabulate import tabulate

def fetch_azure_prices(params: Optional[Dict[str, str]]) -> List[Dict[str, Any]]:
    api_url: str = "https://prices.azure.com/api/retail/prices"

    items: List[Dict[str, Any]] = []
    while True:
        response: Response = get(api_url, params=params)
        if response.status_code != 200:
            exit(f"Error fetching data: {response.status_code}")
        data: Dict[str, Any] = loads(response.text)
        items.extend(data.get('Items', []))
        next_page: Optional[str] = data.get('NextPageLink', None)
        if not next_page:
            break
        api_url = next_page
        params = None  # Clear params for subsequent requests

    return items

def main() -> None:
    print("Requesting Azure blob storage price data, please stand by...")

    default_blob_types_array: List[str] = [
        "Standard Page Blob v2",
        "Standard Page Blob",
        "General Block Blob",
        "Blob Storage",
        "Premium Block Blob",
        "General Block Blob v2"
    ]

    default_blob_types_string: str = ','.join(default_blob_types_array)

    parser: ArgumentParser = ArgumentParser(description='Calculate Azure blob storage prices by region')
    parser.add_argument('--blob-types', 
                       default=default_blob_types_string, 
                       help=f'Comma-separated list of blob types (default: %(default)s)')
    args: Namespace = parser.parse_args()

    blob_types_array: List[str] = [t.strip() for t in args.blob_types.split(',')]

    if len(blob_types_array) < 1:
        exit("No blob types specified")

    product_filter: str = " or ".join(f"productName eq '{blob_type}'" for blob_type in blob_types_array)
    params: Dict[str, str] = {
        "$filter": f"({product_filter}) and priceType eq 'Consumption' and serviceName eq 'Storage'"
    }

    items: List[Dict[str, Any]] = fetch_azure_prices(params)
    print(f"Total items fetched: {len(items)}")

    service_regions: Dict[Tuple[str, str, str], Set[str]] = defaultdict(set)
    service_prices: Dict[Tuple[str, str, str], Dict[str, float]] = defaultdict(dict)
    all_regions: Set[str] = set()
    all_services: Set[Tuple[str, str, str]] = set()
    excluded_regions: Set[str] = set()

    for item in items:
        armRegionName: str = item.get('armRegionName', '')
        if not armRegionName or armRegionName.lower() == 'global':
            excluded_regions.add(armRegionName or 'Unknown')  # Collect excluded region names
            continue  # Skip items without a region or with region 'Global'

        productName: str = item.get('productName', '')
        skuName: str = item.get('skuName', '')
        meterName: str = item.get('meterName', '')
        retailPrice: float = item.get('retailPrice', 0.0)

        service_key: Tuple[str, str, str] = (productName, skuName, meterName)

        service_regions[service_key].add(armRegionName)
        service_prices[service_key][armRegionName] = retailPrice

        all_regions.add(armRegionName)
        all_services.add(service_key)

    print(f"Total regions found (excluding 'Global'): {len(all_regions)}")
    print(f"Total services found: {len(all_services)}")

    if excluded_regions:
        print("\nExcluded regions:")
        for region in excluded_regions:
            print(f"- {region}")
    else:
        print("\nNo regions were excluded.")

    services_in_all_regions: List[Tuple[str, str, str]] = [
        service for service, regions in service_regions.items()
        if regions == all_regions
    ]

    if services_in_all_regions:
        print(f"\nNumber of services available in all regions: {len(services_in_all_regions)}")
    else:
        print("\nNo services are available in all regions.")
        max_regions: int = max(len(regions) for regions in service_regions.values())
        services_in_max_regions: List[Tuple[str, str, str]] = [
            service for service, regions in service_regions.items()
            if len(regions) == max_regions
        ]
        print(f"Using services available in {max_regions} regions.")
        services_in_all_regions = services_in_max_regions
        regions_with_max_services: Set[str] = set.intersection(
            *(service_regions[service] for service in services_in_all_regions)
        )
        all_regions = regions_with_max_services
        print(f"Adjusted total regions: {len(all_regions)}")

    region_prices: Dict[str, List[float]] = defaultdict(list)

    for service in services_in_all_regions:
        for region in all_regions:
            price: Optional[float] = service_prices[service].get(region, None)
            if price is not None:
                region_prices[region].append(price)
            else:
                print(f"Price missing for service {service} in region {region}")

    region_avg_prices: List[Tuple[str, float]] = []

    for region in all_regions:
        prices: List[float] = region_prices.get(region, [])
        if prices:
            average_price: float = sum(prices) / len(prices)
            region_avg_prices.append((region, average_price))
        else:
            print(f"No prices collected for region {region}")

    region_avg_prices.sort(key=lambda x: x[1])

    if len(blob_types_array) > 1:
        table_caption: str = "Average blob storage services ({services}) price per region".format(
            services=", ".join(blob_types_array)
        )
        price_header: str = "Average Price (USD)"
    else:
        table_caption = "Blob storage service ({service}) price per region".format(
            service=blob_types_array[0]
        )
        price_header = "Average Price (USD)"
    
    print("\n" + table_caption)
    headers: List[str] = ["Region", price_header]
    print(tabulate(region_avg_prices, headers=headers, tablefmt="psql"))

if __name__ == "__main__":
    main()
