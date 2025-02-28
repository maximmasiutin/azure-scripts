#!/usr/bin/env python3

# blob-storage-price.py
# Copyright 2025 by Maxim Masiutin. All rights reserved.

# Returns Azure regions sorted by average blob storage price (page/block, premium/general, etc)
# Based on the code example from https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices


from json import loads
from argparse import ArgumentParser
from collections import defaultdict
from sys import exit
from requests import get
from tabulate import tabulate

def fetch_azure_prices(params):
    api_url = "https://prices.azure.com/api/retail/prices"

    items = []
    while True:
        response = get(api_url, params=params)
        if response.status_code != 200:
            exit(f"Error fetching data: {response.status_code}")
        data = loads(response.text)
        items.extend(data.get('Items', []))
        next_page = data.get('NextPageLink', None)
        if not next_page:
            break
        api_url = next_page
        params = None  # Clear params for subsequent requests

    return items

def main():
    print("Requesting Azure blob storage price data, please stand by...")

    default_blob_types_array = [
        "Standard Page Blob v2",
        "Standard Page Blob",
        "General Block Blob",
        "Blob Storage",
        "Premium Block Blob",
        "General Block Blob v2"
    ]

    default_blob_types_string = ','.join(default_blob_types_array)

    parser = ArgumentParser(description='Calculate Azure blob storage prices by region')
    parser.add_argument('--blob-types', 
                       default=default_blob_types_string, 
                       help=f'Comma-separated list of blob types (default: %(default)s)')
    args = parser.parse_args()

    blob_types_array = [t.strip() for t in args.blob_types.split(',')]


    if len(blob_types_array)<1:
        exit("No blob types specified")


    product_filter = " or ".join(f"productName eq '{blob_type}'" for blob_type in blob_types_array)
    params = {
        "$filter": f"({product_filter}) and priceType eq 'Consumption' and serviceName eq 'Storage'"
    }

    items = fetch_azure_prices(params)
    print(f"Total items fetched: {len(items)}")

    # Build mappings
    service_regions = defaultdict(set)
    service_prices = defaultdict(dict)
    all_regions = set()
    all_services = set()
    excluded_regions = set()

    for item in items:
        armRegionName = item.get('armRegionName', '')
        if not armRegionName or armRegionName.lower() == 'global':
            excluded_regions.add(armRegionName or 'Unknown')  # Collect excluded region names
            continue  # Skip items without a region or with region 'Global'

        productName = item.get('productName', '')
        skuName = item.get('skuName', '')
        meterName = item.get('meterName', '')
        retailPrice = item.get('retailPrice', 0.0)

        # Key to uniquely identify a service
        service_key = (productName, skuName, meterName)

        # Add region to service's set of regions
        service_regions[service_key].add(armRegionName)

        # Store the price of the service in the region
        service_prices[service_key][armRegionName] = retailPrice

        # Collect all regions and services
        all_regions.add(armRegionName)
        all_services.add(service_key)

    print(f"Total regions found (excluding 'Global'): {len(all_regions)}")
    print(f"Total services found: {len(all_services)}")

    # Print the names of excluded regions
    if excluded_regions:
        print("\nExcluded regions:")
        for region in excluded_regions:
            print(f"- {region}")
    else:
        print("\nNo regions were excluded.")

    # Identify services available in all regions
    services_in_all_regions = [service for service, regions in service_regions.items()
                               if regions == all_regions]

    if services_in_all_regions:
        print(f"\nNumber of services available in all regions: {len(services_in_all_regions)}")
    else:
        print("\nNo services are available in all regions.")
        # Find the maximum number of regions any service is available in
        max_regions = max(len(regions) for regions in service_regions.values())
        # Select services available in the maximum number of regions
        services_in_max_regions = [service for service, regions in service_regions.items()
                                   if len(regions) == max_regions]
        print(f"Using services available in {max_regions} regions.")
        services_in_all_regions = services_in_max_regions
        # Adjust the set of regions to include only regions where these services are available
        regions_with_max_services = set.intersection(*(service_regions[service] for service in services_in_all_regions))
        all_regions = regions_with_max_services
        print(f"Adjusted total regions: {len(all_regions)}")

    # For each region, calculate average storage price of the selected services
    region_prices = defaultdict(list)

    for service in services_in_all_regions:
        for region in all_regions:
            price = service_prices[service].get(region, None)
            if price is not None:
                region_prices[region].append(price)
            else:
                # In case service is supposed to be in selected regions but price is missing
                print(f"Price missing for service {service} in region {region}")

    region_avg_prices = []

    for region in all_regions:
        prices = region_prices.get(region, [])
        if prices:
            average_price = sum(prices) / len(prices)
            region_avg_prices.append((region, average_price))
        else:
            # No prices collected for this region
            print(f"No prices collected for region {region}")

    # Sort regions by average storage price ascending
    region_avg_prices.sort(key=lambda x: x[1])

    if len(blob_types_array)>1:
        table_caption  = "Average blob storage services ({services}) price per region".format(services=", ".join(blob_types_array))
        price_header = "Average Price (USD)"
    else:
        table_caption = "Blob storage service ({service}) price per region".format(service=blob_types_array[0])
        price_header = "Average Price (USD)"
    
    print("\n" + table_caption)
    headers = ["Region", price_header]
    print(tabulate(region_avg_prices, headers=headers, tablefmt="psql"))

if __name__ == "__main__":
    main()
