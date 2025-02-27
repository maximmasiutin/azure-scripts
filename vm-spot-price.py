#!/usr/bin/env python3

# vm-spot-price.py
# Copyright 2023-2025 by Maxim Masiutin. All rights reserved.

# Returns sorted (by VM spot price) list of Azure regions
# Based on the code example from https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices

from json import loads
from sys import exit

from requests import get
from tabulate import tabulate

# Define virtual machine to search for
# See https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions

SEARCH_VMSIZE = "8"
SEARCH_VMPATTERN = "B#s_v2"
SEARCH_VMWINDOWS = False
SEARCH_VMLINUX = True


def key_value(arg):
    return arg[1]


def build_pricing_table(json_data, table_data):
    for item in json_data["Items"]:
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

    sku = SEARCH_VMPATTERN.replace("#", SEARCH_VMSIZE)
    series = SEARCH_VMPATTERN.replace("#", "").replace("_", "")

    api_url = (
        "https://prices.azure.com/api/retail/prices"
    )
    query = "armSkuName eq 'Standard_{sku}' and contains(meterName, 'Spot') and priceType eq 'Consumption' and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'".format(
        sku=sku
    )
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

    build_pricing_table(json_data, table_data)
    next_page = json_data["NextPageLink"]

    while next_page:
        response = get(next_page)
        json_data = loads(response.text)
        next_page = json_data["NextPageLink"]
        build_pricing_table(json_data, table_data)

    table_data.sort(key=key_value)

    print(tabulate(table_data, headers=["SKU", "Retail Price", "Unit of Measure", "Region", "Meter", "Product Name"], tablefmt="psql"))


if __name__ == "__main__":
    main()
