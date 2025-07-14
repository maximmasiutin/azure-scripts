#!/usr/bin/env python3

# vm-spot-price.py
# Copyright 2023-2025 by Maxim Masiutin. All rights reserved.

# Returns sorted (by VM spot price) list of Azure regions
# Based on the code example from https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices

# Examples of use:
#   python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"
#   python vm-spot-price.py --cpu 4 --sku-pattern "B#ls_v2" --series-pattern "Bsv2"

#   python vm-spot-price.py --sku-pattern "B8s_v2" --series-pattern "Bsv2" --non-spot --return-region
#   python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2"
#   python vm-spot-price.py --sku-pattern "B2ts_v2" --series-pattern "Bsv2"

from argparse import ArgumentParser, Namespace
from json import loads
from sys import exit, stderr
from typing import List, Dict, Any

from requests import get, Response
from tabulate import tabulate

# Define virtual machine to search for
# See https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions
# (default options)
DEFAULT_SEARCH_VMSIZE: str = "8"
DEFAULT_SEARCH_VMPATTERN: str = "B#s_v2"
DEFAULT_SEARCH_VMWINDOWS: bool = False
DEFAULT_SEARCH_VMLINUX: bool = True

def build_pricing_table(json_data: Dict[str, Any], table_data: List[List[Any]], non_spot: bool, low_priority: bool) -> None:
    for item in json_data["Items"]:
        arm_sku_name: str = item["armSkuName"]
        retail_price: float = item["retailPrice"]
        unit_of_measure: str = item["unitOfMeasure"]
        arm_region_name: str = item["armRegionName"]
        meter_name: str = item["meterName"]
        product_name: str = item["productName"]
        if non_spot:
            if "Spot" in meter_name:
                continue    
        if not low_priority:
            if "Low Priority" in meter_name:
                continue    
        table_data.append(
            [
                arm_sku_name,
                retail_price,
                unit_of_measure,
                arm_region_name,
                meter_name,
                product_name,
            ]
        )

def main() -> None:
    import logging
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s')
    table_data: List[List[Any]] = []
    parser: ArgumentParser = ArgumentParser(description='Get Azure VM spot prices')
    parser.add_argument('--cpu', default=DEFAULT_SEARCH_VMSIZE, type=int, help='Number of CPUs (default: %(default)s)')
    parser.add_argument('--sku-pattern', default=DEFAULT_SEARCH_VMPATTERN, type=str, help='VM instance size SKU pattern (default: %(default)s)')
    parser.add_argument('--series-pattern', default=DEFAULT_SEARCH_VMPATTERN, type=str, help='VM instance size Series pattern (optional)')
    parser.add_argument('--non-spot', action='store_true', help='Only return non-spot instances')
    parser.add_argument('--low-priority', action='store_true', help='Include low priority instances (by default, skip VMs with "Low Priority" in meterName)')
    parser.add_argument('--return-region', action='store_true', help='Return only one region output if found')
    parser.add_argument('--log-level', type=str, help='Set the logging level')
    args: Namespace = parser.parse_args()

    sku_pattern: str = args.sku_pattern
    series_pattern: str = args.series_pattern
    if not series_pattern: series_pattern = sku_pattern
    sku: str = sku_pattern.replace("#", str(args.cpu))
    series: str = series_pattern.replace("#", "").replace("_", "")
    non_spot: bool = args.non_spot
    low_priority: bool = args.low_priority
    return_region: bool = args.return_region
    if args.log_level:
        allowed_levels = ("ERROR", "INFO", "WARNING", "DEBUG")
        normalized_level = args.log_level.upper()
        if normalized_level not in allowed_levels:
            logging.error(f"Invalid log level: {args.log_level}. Valid options are: {', '.join(allowed_levels)}")
            exit(1)
        logging.getLogger().setLevel(getattr(logging, normalized_level))
    else:
        if args.return_region:
            logging.getLogger().setLevel(logging.ERROR)
        else:
            logging.getLogger().setLevel(logging.DEBUG)

    api_url: str = "https://prices.azure.com/api/retail/prices"
    query: str = f"armSkuName eq 'Standard_{sku}' and priceType eq 'Consumption' and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'"
    if not non_spot:
        query += " and contains(meterName, 'Spot')"
    if not (DEFAULT_SEARCH_VMWINDOWS and DEFAULT_SEARCH_VMLINUX):
        windows_suffix: str = ""
        if DEFAULT_SEARCH_VMWINDOWS:
            windows_suffix = " Windows"
        else:
            if not DEFAULT_SEARCH_VMLINUX:
                logging.error("Both SEARCH_VMWINDOWS and SEARCH_VMLINUX cannot be set to False")
                exit(1)
        query = query + f" and productName eq 'Virtual Machines {series} Series{windows_suffix}'"


    logging.debug(f"Query: {query}")
    logging.debug(f"URL: {api_url}")

    response: Response = get(api_url, params={"$filter": query})
    json_data: Dict[str, Any] = loads(response.text)

    build_pricing_table(json_data, table_data, non_spot, low_priority)
    next_page: str = json_data["NextPageLink"]

    while next_page:
        logging.debug(f"URL: {next_page}")
        response  = get(next_page)
        json_data = loads(response.text)
        next_page = json_data["NextPageLink"]
        build_pricing_table(json_data, table_data, non_spot, low_priority)

    table_data.sort(key=lambda x: float(x[1])) # the element [1] is retail price

    if return_region:
        if table_data:
            region: str = table_data[0][3]
            print(region)
        else:
            logging.error("No region found")
            exit(1)
    else:
        print(tabulate(table_data, headers=["SKU", "Retail Price", "Unit of Measure", "Region", "Meter", "Product Name"], tablefmt="psql"))


if __name__ == "__main__":
    main()
