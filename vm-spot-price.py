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
from json import loads, JSONDecodeError
from sys import exit, stderr
from typing import List, Dict, Any
import time
from functools import wraps

from requests import get, Response, Session, exceptions
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from tabulate import tabulate
import json

# Define virtual machine to search for
# See https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions
# (default options)
DEFAULT_SEARCH_VMSIZE: str = "8"
DEFAULT_SEARCH_VMPATTERN: str = "B#s_v2"
DEFAULT_SEARCH_VMWINDOWS: bool = False
DEFAULT_SEARCH_VMLINUX: bool = True


def rate_limit(calls_per_second=2):
    """Rate limiting decorator to prevent hitting API limits."""
    min_interval = 1.0 / calls_per_second
    last_called = [0.0]

    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            elapsed = time.time() - last_called[0]
            left_to_wait = min_interval - elapsed
            if left_to_wait > 0:
                time.sleep(left_to_wait)
            ret = func(*args, **kwargs)
            last_called[0] = time.time()
            return ret
        return wrapper
    return decorator


def create_resilient_session():
    """Create HTTP session with retry strategy and connection pooling."""
    session = Session()
    retry_strategy = Retry(
        total=3,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
    )
    adapter = HTTPAdapter(max_retries=retry_strategy, pool_connections=10, pool_maxsize=10)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session


@rate_limit(calls_per_second=2)
def fetch_pricing_data(api_url: str, params: Dict[str, str], session: Session) -> Dict[str, Any]:
    """Fetch pricing data with error handling and rate limiting."""
    try:
        response: Response = session.get(api_url, params=params, timeout=30)
        response.raise_for_status()

        try:
            return response.json()
        except JSONDecodeError as e:
            print(f"Error: Invalid JSON response from API: {e}", file=stderr)
            raise

    except exceptions.HTTPError as e:
        print(f"HTTP Error: {e}", file=stderr)
        if hasattr(e.response, 'status_code') and e.response.status_code == 429:
            print("Rate limited. Try again later.", file=stderr)
        raise
    except exceptions.RequestException as e:
        print(f"Network Error: {e}", file=stderr)
        raise


def build_pricing_table(json_data: Dict[str, Any], table_data: List[List[Any]], non_spot: bool, low_priority: bool) -> None:
    """Build pricing table from JSON data with validation."""
    items = json_data.get("Items", [])
    if not items:
        print("Warning: No items found in API response", file=stderr)
        return

    for item in items:
        try:
            arm_sku_name: str = item.get("armSkuName", "")
            retail_price: float = float(item.get("retailPrice", 0.0))
            unit_of_measure: str = item.get("unitOfMeasure", "")
            arm_region_name: str = item.get("armRegionName", "")
            meter_name: str = item.get("meterName", "")
            product_name: str = item.get("productName", "")

            # Validate required fields
            if not all([arm_sku_name, arm_region_name, meter_name, product_name]):
                continue

            if non_spot and "Spot" in meter_name:
                continue
            if not low_priority and "Low Priority" in meter_name:
                continue

            table_data.append([
                arm_sku_name,
                retail_price,
                unit_of_measure,
                arm_region_name,
                meter_name,
                product_name,
            ])
        except (ValueError, TypeError) as e:
            print(f"Warning: Skipping invalid item: {e}", file=stderr)
            continue


def format_output(table_data: List[List[Any]], output_format: str) -> str:
    """Format output in the requested format."""
    if not table_data:
        return "No pricing data found."

    if output_format == "json":
        headers = ["SKU", "Retail Price", "Unit of Measure", "Region", "Meter", "Product Name"]
        json_data = []
        for row in table_data:
            json_data.append(dict(zip(headers, row)))
        return json.dumps(json_data, indent=2)

    elif output_format == "csv":
        lines = ["SKU,Retail_Price,Unit_of_Measure,Region,Meter,Product_Name"]
        for row in table_data:
            # Escape commas in strings
            escaped_row = [str(field).replace(",", ";") for field in row]
            lines.append(",".join(escaped_row))
        return "\n".join(lines)

    else:  # table format
        headers = ["SKU", "Retail Price", "Unit of Measure", "Region", "Meter", "Product Name"]
        return tabulate(table_data, headers=headers, tablefmt="psql")


def print_progress(current: int, total: int, prefix: str = 'Progress') -> None:
    """Print progress bar."""
    if total == 0:
        return
    percent = (current / total) * 100
    bar_length = 50
    filled_length = int(bar_length * current // total)
    bar = '█' * filled_length + '-' * (bar_length - filled_length)
    print(f'\r{prefix}: |{bar}| {percent:.1f}%', end='', flush=True)


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
    parser.add_argument('--output-format', choices=['table', 'json', 'csv'], default='table', help='Output format (default: %(default)s)')
    parser.add_argument('--output-file', help='Save output to file instead of stdout')
    parser.add_argument('--dry-run', action='store_true', help='Show API query without executing')
    parser.add_argument('--validate-config', action='store_true', help='Validate configuration and exit')

    args: Namespace = parser.parse_args()

    if args.validate_config:
        print("Configuration validation:")
        print(f"CPU count: {args.cpu}")
        print(f"SKU pattern: {args.sku_pattern}")
        print(f"Series pattern: {args.series_pattern}")
        print(f"Non-spot only: {args.non_spot}")
        print(f"Include low priority: {args.low_priority}")
        print("Configuration is valid.")
        return

    sku_pattern: str = args.sku_pattern
    series_pattern: str = args.series_pattern
    if not series_pattern:
        series_pattern = sku_pattern
    sku: str = sku_pattern.replace("#", str(args.cpu))
    series: str = series_pattern.replace("#", "").replace("_", "")
    non_spot: bool = args.non_spot
    low_priority: bool = args.low_priority
    return_region: bool = args.return_region

    # Configure logging
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

    # Build API query
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

    if args.dry_run:
        print("DRY RUN - API Query:")
        print(f"URL: {api_url}")
        print(f"Filter: {query}")
        print(f"SKU: {sku}")
        print(f"Series: {series}")
        return

    logging.debug(f"Query: {query}")
    logging.debug(f"URL: {api_url}")

    # Create session and fetch data
    session = create_resilient_session()
    page_count = 0
    max_pages = 50  # Safety limit

    try:
        print("Fetching Azure VM pricing data...")

        # Initial request
        json_data = fetch_pricing_data(api_url, {"$filter": query}, session)
        build_pricing_table(json_data, table_data, non_spot, low_priority)

        next_page: str = json_data.get("NextPageLink", "")
        page_count = 1

        # Follow pagination
        while next_page and page_count < max_pages:
            print_progress(page_count, min(page_count + 10, max_pages), "Fetching pages")
            json_data = fetch_pricing_data(next_page, {}, session)
            next_page = json_data.get("NextPageLink", "")
            build_pricing_table(json_data, table_data, non_spot, low_priority)
            page_count += 1

        if page_count >= max_pages and next_page:
            print(f"\nWarning: Reached maximum page limit ({max_pages}). Results may be incomplete.")
        elif page_count > 1:
            print()  # New line after progress bar

    except Exception as e:
        logging.error(f"Failed to fetch pricing data: {e}")
        exit(1)
    finally:
        session.close()

    if not table_data:
        logging.error("No pricing data found for the specified criteria")
        exit(1)

    # Sort by price (element [1] is retail price)
    table_data.sort(key=lambda x: float(x[1]))

    print(f"Found {len(table_data)} pricing entries")

    # Output results
    if return_region:
        if table_data:
            region: str = table_data[0][3]
            print(region)
        else:
            logging.error("No region found")
            exit(1)
    else:
        content = format_output(table_data, args.output_format)

        if args.output_file:
            try:
                with open(args.output_file, 'w', encoding='utf-8') as f:
                    f.write(content)
                print(f"Results saved to: {args.output_file}")
            except IOError as e:
                print(f"Error writing to file {args.output_file}: {e}", file=stderr)
                print("Results:")
                print(content)
        else:
            print(content)


if __name__ == "__main__":
    main()
