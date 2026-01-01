#!/usr/bin/env python3

# blob-storage-price.py
# Copyright 2025 by Maxim Masiutin. All rights reserved.
#
# SECURITY IMPROVEMENTS:
# - Added input validation and sanitization
# - Improved error handling with proper exception management
# - Added SSL certificate verification
# - Enhanced logging and debugging capabilities
# - Added rate limiting awareness
# - Implemented safer HTTP requests with timeouts
# - Added comprehensive argument validation

import json
import sys
import time
from argparse import ArgumentParser, RawDescriptionHelpFormatter
from collections import defaultdict
from typing import List, Dict, Tuple, Optional, Set, Any
from urllib.parse import urlparse

import requests
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry
from tabulate import tabulate


class AzurePricesFetcher:
    """Secure Azure prices fetcher with proper error handling and security features."""

    def __init__(self, timeout: int = 30, max_retries: int = 3):
        self.timeout = timeout
        self.max_retries = max_retries
        self.api_url = "https://prices.azure.com/api/retail/prices"
        self.session = self._create_secure_session()

    def _create_secure_session(self) -> requests.Session:
        """Create a secure HTTP session with proper SSL verification and retry strategy."""
        session = requests.Session()

        # Configure retry strategy
        retry_strategy = Retry(
            total=self.max_retries,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("https://", adapter)

        # Ensure SSL verification is enabled
        session.verify = True

        # Set secure headers
        session.headers.update(
            {
                "User-Agent": "azure-blob-storage-price-tool/2.0.0",
                "Accept": "application/json",
                "Accept-Encoding": "gzip, deflate",
            }
        )

        return session

    def fetch_azure_prices(
        self, params: Optional[Dict[str, str]]
    ) -> List[Dict[str, Any]]:
        """
        Fetch Azure retail prices from the API with proper error handling and security.

        Args:
            params: Query parameters for the API request

        Returns:
            List of price items from the API

        Raises:
            SystemExit: On critical errors that prevent execution
        """
        items = []
        api_url = self.api_url
        request_count = 0
        max_requests = 100  # Prevent infinite loops

        try:
            while api_url and request_count < max_requests:
                request_count += 1

                print(f"Fetching page {request_count}...", file=sys.stderr)

                try:
                    response = self.session.get(
                        api_url,
                        params=params,
                        timeout=self.timeout,
                        allow_redirects=True,
                    )
                    response.raise_for_status()  # Raise exception for bad status codes

                except requests.exceptions.SSLError as e:
                    print(f"SSL verification failed: {e}", file=sys.stderr)
                    sys.exit(1)
                except requests.exceptions.Timeout as e:
                    print(
                        f"Request timed out after {self.timeout} seconds: {e}",
                        file=sys.stderr,
                    )
                    sys.exit(1)
                except requests.exceptions.ConnectionError as e:
                    print(f"Connection error: {e}", file=sys.stderr)
                    sys.exit(1)
                except requests.exceptions.HTTPError as e:
                    print(f"HTTP error {response.status_code}: {e}", file=sys.stderr)
                    if response.status_code == 429:
                        print(
                            "Rate limit exceeded. Please wait and try again later.",
                            file=sys.stderr,
                        )
                    sys.exit(1)
                except requests.exceptions.RequestException as e:
                    print(f"Request failed: {e}", file=sys.stderr)
                    sys.exit(1)

                # Validate content type
                content_type = response.headers.get("content-type", "")
                if "application/json" not in content_type.lower():
                    print(f"Unexpected content type: {content_type}", file=sys.stderr)
                    sys.exit(1)

                try:
                    data = response.json()
                except json.JSONDecodeError as e:
                    print(f"Failed to decode JSON response: {e}", file=sys.stderr)
                    sys.exit(1)

                # Validate response structure
                if not isinstance(data, dict):
                    print(
                        "Invalid response format: expected JSON object", file=sys.stderr
                    )
                    sys.exit(1)

                current_items = data.get("Items", [])
                if not isinstance(current_items, list):
                    print(
                        "Invalid response format: Items should be a list",
                        file=sys.stderr,
                    )
                    sys.exit(1)

                items.extend(current_items)

                # Get next page URL
                next_page = data.get("NextPageLink")
                if next_page:
                    # Validate next page URL for security
                    try:
                        parsed_url = urlparse(next_page)
                        if (
                            parsed_url.scheme != "https"
                            or "prices.azure.com" not in parsed_url.netloc
                        ):
                            print(
                                f"Suspicious next page URL: {next_page}",
                                file=sys.stderr,
                            )
                            sys.exit(1)
                    except Exception as e:
                        print(f"Failed to parse next page URL: {e}", file=sys.stderr)
                        sys.exit(1)

                    api_url = next_page
                    params = None  # Clear params for subsequent requests
                else:
                    break

                # Rate limiting: small delay between requests
                time.sleep(0.1)

            if request_count >= max_requests:
                print(
                    f"Warning: Stopped after {max_requests} requests to prevent infinite loop",
                    file=sys.stderr,
                )

        except KeyboardInterrupt:
            print("\nOperation cancelled by user", file=sys.stderr)
            sys.exit(130)
        except Exception as e:
            print(f"Unexpected error during API requests: {e}", file=sys.stderr)
            sys.exit(1)

        return items


def validate_blob_types(blob_types_str: str) -> List[str]:
    """
    Validate and sanitize blob type names.

    Args:
        blob_types_str: Comma-separated string of blob types

    Returns:
        List of validated blob type names

    Raises:
        SystemExit: If validation fails
    """
    if not blob_types_str or not blob_types_str.strip():
        print("Error: No blob types specified", file=sys.stderr)
        sys.exit(1)

    blob_types = [t.strip() for t in blob_types_str.split(",")]
    validated_types = []

    # Define allowed characters for blob type names (security measure)
    allowed_chars = set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-."
    )

    for blob_type in blob_types:
        if not blob_type:
            continue

        # Validate length
        if len(blob_type) > 100:
            print(f"Error: Blob type name too long: {blob_type}", file=sys.stderr)
            sys.exit(1)

        # Validate characters
        if not set(blob_type).issubset(allowed_chars):
            print(
                f"Error: Invalid characters in blob type: {blob_type}", file=sys.stderr
            )
            sys.exit(1)

        validated_types.append(blob_type)

    if not validated_types:
        print("Error: No valid blob types found after validation", file=sys.stderr)
        sys.exit(1)

    return validated_types


def parse_arguments() -> Tuple[List[str], Dict[str, str], Any]:
    """Parse and validate command-line arguments."""
    default_blob_types = [
        "Standard Page Blob v2",
        "Standard Page Blob",
        "General Block Blob",
        "Blob Storage",
        "Premium Block Blob",
        "General Block Blob v2",
    ]

    parser = ArgumentParser(
        description="Calculate Azure blob storage prices by region",
        epilog="""
Examples:
  %(prog)s
  %(prog)s --blob-types "General Block Blob v2"
  %(prog)s --blob-types "General Block Blob v2,Premium Block Blob"

Security Notes:
  - All API requests use HTTPS with SSL verification
  - Input validation prevents injection attacks
  - Rate limiting is respected automatically
        """,
        formatter_class=RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "--blob-types",
        default=",".join(default_blob_types),
        help="Comma-separated list of blob types (default: %(default)s)",
        metavar="TYPES",
    )

    parser.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="HTTP request timeout in seconds (default: %(default)s)",
        metavar="SECONDS",
    )

    parser.add_argument(
        "--max-retries",
        type=int,
        default=3,
        help="Maximum number of retry attempts (default: %(default)s)",
        metavar="COUNT",
    )

    parser.add_argument(
        "--output-format",
        choices=["table", "json", "csv"],
        default="table",
        help="Output format (default: %(default)s)",
    )

    parser.add_argument("--verbose", action="store_true", help="Enable verbose output")

    args = parser.parse_args()

    # Validate timeout
    if args.timeout < 1 or args.timeout > 300:
        print("Error: Timeout must be between 1 and 300 seconds", file=sys.stderr)
        sys.exit(1)

    # Validate max_retries
    if args.max_retries < 0 or args.max_retries > 10:
        print("Error: Max retries must be between 0 and 10", file=sys.stderr)
        sys.exit(1)

    # Validate and process blob types
    blob_types = validate_blob_types(args.blob_types)

    # Build API filter safely
    try:
        # Escape single quotes in blob type names for the filter
        escaped_types = [blob_type.replace("'", "''") for blob_type in blob_types]
        product_filter = " or ".join(
            f"productName eq '{blob_type}'" for blob_type in escaped_types
        )
        params = {
            "$filter": f"({product_filter}) and priceType eq 'Consumption' and serviceName eq 'Storage'"
        }
    except Exception as e:
        print(f"Error building API filter: {e}", file=sys.stderr)
        sys.exit(1)

    return blob_types, params, args


def process_items(items: List[Dict[str, Any]], verbose: bool = False) -> Tuple[
    Dict[Tuple[str, str, str], Set[str]],
    Dict[Tuple[str, str, str], Dict[str, float]],
    Set[str],
    Set[str],
]:
    """Process fetched items to extract regions, services, and prices with validation."""
    service_regions: Dict[Tuple[str, str, str], Set[str]] = defaultdict(set)
    service_prices: Dict[Tuple[str, str, str], Dict[str, float]] = defaultdict(dict)
    all_regions: Set[str] = set()
    excluded_regions: Set[str] = set()
    invalid_items = 0

    for i, item in enumerate(items):
        try:
            # Validate item structure
            if not isinstance(item, dict):
                if verbose:
                    print(
                        f"Warning: Item {i} is not a dictionary, skipping",
                        file=sys.stderr,
                    )
                invalid_items += 1
                continue

            # Extract and validate required fields
            region = item.get("armRegionName", "").strip().lower()
            product_name = item.get("productName", "").strip()
            sku_name = item.get("skuName", "").strip()
            meter_name = item.get("meterName", "").strip()

            # Validate retail price
            try:
                retail_price = float(item.get("retailPrice", 0.0))
                if retail_price < 0:
                    if verbose:
                        print(
                            f"Warning: Negative price in item {i}, skipping",
                            file=sys.stderr,
                        )
                    invalid_items += 1
                    continue
            except (ValueError, TypeError):
                if verbose:
                    print(
                        f"Warning: Invalid price in item {i}, skipping", file=sys.stderr
                    )
                invalid_items += 1
                continue

            # Skip invalid or global regions
            if not region or region == "global" or len(region) > 50:
                excluded_regions.add(region or "Unknown")
                continue

            # Validate field lengths and content
            if len(product_name) > 200 or len(sku_name) > 100 or len(meter_name) > 200:
                if verbose:
                    print(
                        f"Warning: Field too long in item {i}, skipping",
                        file=sys.stderr,
                    )
                invalid_items += 1
                continue

            # Create service key
            service_key = (product_name, sku_name, meter_name)
            service_regions[service_key].add(region)
            service_prices[service_key][region] = retail_price
            all_regions.add(region)

        except Exception as e:
            if verbose:
                print(f"Warning: Error processing item {i}: {e}", file=sys.stderr)
            invalid_items += 1
            continue

    if verbose and invalid_items > 0:
        print(
            f"Processed {len(items)} items, {invalid_items} invalid items skipped",
            file=sys.stderr,
        )

    return service_regions, service_prices, all_regions, excluded_regions


def calculate_region_prices(
    service_regions: Dict[Tuple[str, str, str], Set[str]],
    service_prices: Dict[Tuple[str, str, str], Dict[str, float]],
    all_regions: Set[str],
) -> Dict[str, List[float]]:
    """Calculate prices for each region."""
    region_prices = defaultdict(list)

    for service, _regions in service_regions.items():
        for region in all_regions:
            price = service_prices[service].get(region)
            if price is not None:
                region_prices[region].append(price)

    return region_prices


def calculate_average_prices(
    region_prices: Dict[str, List[float]]
) -> List[Tuple[str, float]]:
    """Calculate average prices for each region."""
    region_avg_prices = []

    for region, prices in region_prices.items():
        if prices:
            avg_price = sum(prices) / len(prices)
            region_avg_prices.append((region, avg_price))

    return sorted(region_avg_prices, key=lambda x: x[1])


def format_output(
    blob_types: List[str],
    region_avg_prices: List[Tuple[str, float]],
    excluded_regions: Set[str],
    output_format: str,
) -> None:
    """Format and print the results in the specified format."""

    if output_format == "json":
        # JSON output
        result = {
            "blob_types": blob_types,
            "region_prices": [
                {"region": region, "avg_price": price}
                for region, price in region_avg_prices
            ],
            "excluded_regions": list(excluded_regions),
        }
        print(json.dumps(result, indent=2))

    elif output_format == "csv":
        # CSV output
        print("Region,Average_Price_USD")
        for region, price in region_avg_prices:
            print(f"{region},{price:.6f}")

    else:
        # Table output (default)
        if excluded_regions:
            print("\nExcluded regions:")
            for region in sorted(excluded_regions):
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
        formatted_data = [
            (region, f"{price:.6f}") for region, price in region_avg_prices
        ]
        print(tabulate(formatted_data, headers=headers, tablefmt="psql"))


def main() -> None:
    """Main function with comprehensive error handling."""
    try:
        print(
            "Requesting Azure blob storage price data, please stand by...",
            file=sys.stderr,
        )

        blob_types, params, args = parse_arguments()

        # Create fetcher with validated parameters
        fetcher = AzurePricesFetcher(timeout=args.timeout, max_retries=args.max_retries)

        # Fetch data
        items = fetcher.fetch_azure_prices(params)
        print(f"Total items fetched: {len(items)}", file=sys.stderr)

        if not items:
            print("No pricing data found for the specified blob types", file=sys.stderr)
            sys.exit(1)

        # Process data
        service_regions, service_prices, all_regions, excluded_regions = process_items(
            items, verbose=args.verbose
        )

        if args.verbose:
            print(
                f"Total regions found (excluding 'Global'): {len(all_regions)}",
                file=sys.stderr,
            )
            print(f"Total services found: {len(service_regions)}", file=sys.stderr)

        # Calculate prices
        region_prices = calculate_region_prices(
            service_regions, service_prices, all_regions
        )
        region_avg_prices = calculate_average_prices(region_prices)

        if not region_avg_prices:
            print("No valid pricing data found after processing", file=sys.stderr)
            sys.exit(1)

        # Output results
        format_output(
            blob_types, region_avg_prices, excluded_regions, args.output_format
        )

    except KeyboardInterrupt:
        print("\nOperation cancelled by user", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        if args.verbose if "args" in locals() else False:
            import traceback

            traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
