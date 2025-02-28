#!/usr/bin/env python3

# vm-spot-price.py
# Copyright 2023-2025 by Maxim Masiutin. All rights reserved.

# Returns sorted (by VM spot price) list of Azure regions
# Based on the code example from https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices

# Examples of use:
#   python vm-spot-price.py --cpu 4 --skupattern "B#s_v2"
#   python vm-spot-price.py --cpu 4 --skupattern "B#ls_v2" --seriespattern "Bsv2"
#   python vm-spot-price.py --skupattern "B4ls_v2" --seriespattern "Bsv2"

from json import loads
from sys import exit
from argparse import ArgumentParser

from requests import get
from tabulate import tabulate

# Define virtual machine to search for
# See https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions


# Default options
SEARCH_VMSIZE = "8"
SEARCH_VMPATTERN = "B#s_v2"
SEARCH_VMWINDOWS = False
SEARCH_VMLINUX = True

def build_pricing_table(json_data, table_data, non_spot):
    for item in json_data["Items"]:
        if non_spot:
            if "Spot" in item["meterName"]:
                continue    
        table_data.append(
            [
                item["armSkuName"],
                item["retailPrice"],
                item["unitOfMeasure"],
                item["armRegionName"],
                item["meterName"],
                item["productName"],
            ]
        )


def main():
    table_data = []

    parser = ArgumentParser(description='Get Azure VM spot prices')
    parser.add_argument('--cpu', default=SEARCH_VMSIZE,type=int, help='Number of CPUs (default: %(default)s)')
    parser.add_argument('--skupattern', default=SEARCH_VMPATTERN,type=str, help='VM instance size SKU pattern (default: %(default)s)')
    parser.add_argument('--seriespattern', default=SEARCH_VMPATTERN,type=str, help='VM instance size Series pattern (optional)')
    parser.add_argument('--non-spot', action='store_true', help='Only return non-spot instances')
    args = parser.parse_args()
    
    skupattern = args.skupattern
    seriespattern = args.seriespattern
    if not seriespattern: seriespattern = skupattern
    sku = skupattern.replace("#", str(args.cpu))
    series = seriespattern.replace("#", "").replace("_", "")
    non_spot = args.non_spot

    api_url = (
        "https://prices.azure.com/api/retail/prices"
    )
    query = "armSkuName eq 'Standard_{sku}' and priceType eq 'Consumption' and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'".format(sku=sku)
    if not non_spot:
        query += " and contains(meterName, 'Spot')" 
    if not (SEARCH_VMWINDOWS and SEARCH_VMLINUX):
        windows_suffix = ""
        if SEARCH_VMWINDOWS:
            windows_suffix = " Windows"
        else:
            if not SEARCH_VMLINUX:
                exit("Both SEARCH_VMWINDOWS and SEARCH_VMLINUX cannot be set to False")
        query = (
            query
            + " and productName eq 'Virtual Machines {series} Series{windows_suffix}'".format(
                series=series, windows_suffix=windows_suffix
            )
        )

    response = get(api_url, params={"$filter": query})
    json_data = loads(response.text)

    build_pricing_table(json_data, table_data, non_spot)
    next_page = json_data["NextPageLink"]

    while next_page:
        response = get(next_page)
        json_data = loads(response.text)
        next_page = json_data["NextPageLink"]
        build_pricing_table(json_data, table_data)

    table_data.sort(key=lambda x: float(x[1])) # the element [1] is retail price

    print(tabulate(table_data, headers=["SKU", "Retail Price", "Unit of Measure", "Region", "Meter", "Product Name"], tablefmt="psql"))


if __name__ == "__main__":
    main()
