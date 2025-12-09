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
#
# Multi-VM comparison (find cheapest spot across multiple VM sizes):
#   python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5,D4s_v5" --return-region
#   python vm-spot-price.py --vm-sizes "B4ls_v2,B4s_v2,D4as_v5"
#
# PowerShell usage (--return-region outputs: "region vmsize price unit"):
#   $result = python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2" --return-region
#   $region, $vmSize, $price, $unit = $result -split ' ', 4
#   New-AzVM -ResourceGroupName $rg -Name $vmName -Location $region -Size $vmSize ...

from argparse import ArgumentParser, Namespace
from json import JSONDecodeError
from sys import exit, stderr
from typing import List, Dict, Any
import time
from functools import wraps

from requests import Response, Session, exceptions
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

            if retail_price <= 0:
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
    bar = '#' * filled_length + '-' * (bar_length - filled_length)
    print(f'\r{prefix}: |{bar}| {percent:.1f}%', end='', flush=True)


def extract_series_from_vm_size(vm_size: str) -> str:
    """Extract series name from VM size for API query.

    Examples:
        D4pls_v5 -> Dplsv5
        F4s_v2 -> Fsv2
        D4as_v5 -> Dasv5
        B4ls_v2 -> Blsv2
    """
    import re
    # Remove leading Standard_ if present
    vm_size = vm_size.replace("Standard_", "")
    # Remove numeric part (the vCPU count)
    # Pattern: letter(s) + digits + rest
    match = re.match(r'^([A-Za-z]+)(\d+)(.*)$', vm_size)
    if match:
        prefix = match.group(1)  # e.g., 'D', 'F', 'B'
        suffix = match.group(3)  # e.g., 'pls_v5', 's_v2'
        # Remove underscores for series name
        series = (prefix + suffix).replace("_", "")
        return series
    return vm_size.replace("_", "")


def main() -> None:
    import logging
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s')

    table_data: List[List[Any]] = []
    parser: ArgumentParser = ArgumentParser(description='Get Azure VM spot prices')
    parser.add_argument('--cpu', default=DEFAULT_SEARCH_VMSIZE, type=int, help='Number of CPUs (default: %(default)s)')
    parser.add_argument('--sku-pattern', default=DEFAULT_SEARCH_VMPATTERN, type=str, help='VM instance size SKU pattern (default: %(default)s)')
    parser.add_argument('--series-pattern', default=DEFAULT_SEARCH_VMPATTERN, type=str, help='VM instance size Series pattern (optional)')
    parser.add_argument('--vm-sizes', type=str, help='Comma-separated list of VM sizes (e.g., D4pls_v5,D4ps_v5,F4s_v2). Overrides --sku-pattern and --series-pattern')
    parser.add_argument('--non-spot', action='store_true', help='Only return non-spot instances')
    parser.add_argument('--low-priority', action='store_true', help='Include low priority instances (by default, skip VMs with "Low Priority" in meterName)')
    parser.add_argument('--return-region', action='store_true', help='Return only one region output if found')
    parser.add_argument('--exclude-regions', type=str, help='Comma-separated list of regions to exclude (e.g., centralindia,eastus)')
    parser.add_argument('--exclude-regions-file', type=str, action='append', help='File containing regions to exclude (one per line). Can be specified multiple times.')
    parser.add_argument('--exclude-vm-sizes', type=str, help='Comma-separated list of VM sizes to exclude (e.g., D4pls_v5,D4ps_v5)')
    parser.add_argument('--exclude-vm-sizes-file', type=str, help='File containing VM sizes to exclude (one per line)')
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

    non_spot: bool = args.non_spot
    low_priority: bool = args.low_priority
    return_region: bool = args.return_region

    # Build excluded regions set
    excluded_regions: set = set()
    if args.exclude_regions:
        for region in args.exclude_regions.split(','):
            region = region.strip().lower()
            if region:
                excluded_regions.add(region)
    if args.exclude_regions_file:
        for exclude_file in args.exclude_regions_file:
            try:
                with open(exclude_file, 'r') as f:
                    for line in f:
                        region = line.strip().lower()
                        if region and not region.startswith('#'):
                            excluded_regions.add(region)
                logging.debug(f"Loaded exclusions from {exclude_file}")
            except IOError as e:
                logging.warning(f"Could not read exclude-regions-file {exclude_file}: {e}")
    if excluded_regions:
        logging.debug(f"Excluding regions: {', '.join(sorted(excluded_regions))}")

    # Build excluded VM sizes set
    excluded_vm_sizes: set = set()
    if args.exclude_vm_sizes:
        for vm_size in args.exclude_vm_sizes.split(','):
            vm_size = vm_size.strip()
            if vm_size:
                # Normalize: remove Standard_ prefix if present, store lowercase
                vm_size = vm_size.replace("Standard_", "").lower()
                excluded_vm_sizes.add(vm_size)
    if args.exclude_vm_sizes_file:
        try:
            with open(args.exclude_vm_sizes_file, 'r') as f:
                for line in f:
                    vm_size = line.strip()
                    if vm_size and not vm_size.startswith('#'):
                        vm_size = vm_size.replace("Standard_", "").lower()
                        excluded_vm_sizes.add(vm_size)
        except IOError as e:
            logging.warning(f"Could not read exclude-vm-sizes-file: {e}")
    if excluded_vm_sizes:
        logging.debug(f"Excluding VM sizes: {', '.join(sorted(excluded_vm_sizes))}")

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

    # Build list of VM sizes to query
    vm_sizes_list: List[tuple] = []  # List of (sku, series) tuples

    if args.vm_sizes:
        # Parse comma-separated VM sizes
        for vm_size in args.vm_sizes.split(','):
            vm_size = vm_size.strip()
            if not vm_size:
                continue
            # Check if this VM size is excluded
            normalized = vm_size.replace("Standard_", "").lower()
            if normalized in excluded_vm_sizes:
                logging.debug(f"Skipping excluded VM size: {vm_size}")
                continue
            series = extract_series_from_vm_size(vm_size)
            vm_sizes_list.append((vm_size, series))
        if not vm_sizes_list:
            logging.error("No valid VM sizes provided in --vm-sizes (all may be excluded)")
            exit(1)
    else:
        # Use legacy sku-pattern and series-pattern
        sku_pattern: str = args.sku_pattern
        series_pattern: str = args.series_pattern
        if not series_pattern:
            series_pattern = sku_pattern
        sku: str = sku_pattern.replace("#", str(args.cpu))
        series: str = series_pattern.replace("#", "").replace("_", "")
        vm_sizes_list.append((sku, series))

    api_url: str = "https://prices.azure.com/api/retail/prices"

    if args.dry_run:
        print("DRY RUN - API Queries:")
        print(f"URL: {api_url}")
        for sku, series in vm_sizes_list:
            query = f"armSkuName eq 'Standard_{sku}' and priceType eq 'Consumption' and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'"
            if not non_spot:
                query += " and contains(meterName, 'Spot')"
            if not (DEFAULT_SEARCH_VMWINDOWS and DEFAULT_SEARCH_VMLINUX):
                windows_suffix = " Windows" if DEFAULT_SEARCH_VMWINDOWS else ""
                if not DEFAULT_SEARCH_VMLINUX and not DEFAULT_SEARCH_VMWINDOWS:
                    logging.error("Both SEARCH_VMWINDOWS and SEARCH_VMLINUX cannot be set to False")
                    exit(1)
                query += f" and productName eq 'Virtual Machines {series} Series{windows_suffix}'"
            print(f"SKU: {sku}, Series: {series}")
            print(f"Filter: {query}")
            print()
        return

    # Create session and fetch data
    session = create_resilient_session()
    max_pages = 50  # Safety limit per VM size

    try:
        if not return_region:
            print(f"Fetching Azure VM pricing data for {len(vm_sizes_list)} VM size(s)...")

        for idx, (sku, series) in enumerate(vm_sizes_list):
            if len(vm_sizes_list) > 1 and not return_region:
                print(f"\n[{idx + 1}/{len(vm_sizes_list)}] Querying {sku} (series: {series})...")

            # Build query for this VM size
            query = f"armSkuName eq 'Standard_{sku}' and priceType eq 'Consumption' and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'"

            if not non_spot:
                query += " and contains(meterName, 'Spot')"

            if not (DEFAULT_SEARCH_VMWINDOWS and DEFAULT_SEARCH_VMLINUX):
                windows_suffix = ""
                if DEFAULT_SEARCH_VMWINDOWS:
                    windows_suffix = " Windows"
                else:
                    if not DEFAULT_SEARCH_VMLINUX:
                        logging.error("Both SEARCH_VMWINDOWS and SEARCH_VMLINUX cannot be set to False")
                        exit(1)
                query += f" and productName eq 'Virtual Machines {series} Series{windows_suffix}'"

            logging.debug(f"Query: {query}")

            # Initial request
            json_data = fetch_pricing_data(api_url, {"$filter": query}, session)
            build_pricing_table(json_data, table_data, non_spot, low_priority)

            next_page: str = json_data.get("NextPageLink", "")
            page_count = 1

            # Follow pagination
            while next_page and page_count < max_pages:
                if not return_region:
                    print_progress(page_count, min(page_count + 10, max_pages), "Fetching pages")
                json_data = fetch_pricing_data(next_page, {}, session)
                next_page = json_data.get("NextPageLink", "")
                build_pricing_table(json_data, table_data, non_spot, low_priority)
                page_count += 1

            if page_count >= max_pages and next_page and not return_region:
                print(f"\nWarning: Reached maximum page limit ({max_pages}) for {sku}. Results may be incomplete.")
            elif page_count > 1 and not return_region:
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

    # Filter out excluded regions
    if excluded_regions:
        original_count = len(table_data)
        table_data = [row for row in table_data if row[3].lower() not in excluded_regions]
        filtered_count = original_count - len(table_data)
        if filtered_count > 0:
            logging.debug(f"Filtered out {filtered_count} entries from excluded regions")

    # Output results
    if return_region:
        if table_data:
            region: str = table_data[0][3]
            vm_size: str = table_data[0][0]  # SKU e.g., Standard_D4pls_v5
            price: float = table_data[0][1]
            unit: str = table_data[0][2]
            # Output format: region vmsize price unit (space-separated)
            # Usage in PowerShell: $region, $vmSize, $price, $unit = (python vm-spot-price.py ...) -split ' ', 4
            print(f"{region} {vm_size} {price} {unit}")
        else:
            logging.error("No region found")
            exit(1)
    else:
        print(f"Found {len(table_data)} pricing entries")
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
