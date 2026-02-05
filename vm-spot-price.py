#!/usr/bin/env python3
# pylint: disable=invalid-name,too-many-lines,logging-fstring-interpolation
# pylint: disable=too-many-locals,too-many-branches,too-many-statements
# pylint: disable=too-many-arguments,too-many-positional-arguments,broad-exception-caught
# pylint: disable=too-many-return-statements,too-many-nested-blocks,line-too-long
# pylint: disable=global-statement
"""
vm-spot-price.py - Azure VM Spot Price Finder

Copyright 2023-2025 by Maxim Masiutin. All rights reserved.

Returns sorted (by VM spot price) list of Azure regions.
Based on: https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
VM naming: https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions

CPU vendor detection uses the Azure VM naming convention additive features:
  'a' = AMD-based processor, 'p' = ARM-based processor, neither = Intel

Examples:
  python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"
  python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2" --return-region
  python vm-spot-price.py --cpu 64 --no-burstable --region eastus
  python vm-spot-price.py --all-vm-series --region eastus --cpu 4
"""

import json
import logging
import os
import re
import sys
import time
import warnings
from argparse import ArgumentParser, Namespace
from functools import wraps
from json import JSONDecodeError
from typing import List, Dict, Any, Optional
from urllib.parse import urlparse

from requests import Response, Session, exceptions
from requests.adapters import HTTPAdapter
from tabulate import tabulate
from urllib3.util.retry import Retry

# Allowed API domains for SSRF protection
ALLOWED_API_DOMAINS = ["prices.azure.com"]


def validate_api_url(url: str) -> bool:
    """
    Validate that a URL is from an allowed Azure API domain.
    Returns True if valid, False otherwise.
    """
    try:
        parsed = urlparse(url)
        # Must be HTTPS
        if parsed.scheme != "https":
            return False
        # Must be from allowed domain
        if parsed.hostname not in ALLOWED_API_DOMAINS:
            return False
        return True
    except Exception:
        return False


def validate_file_path(file_path: str, operation: str = "write") -> str:
    """
    Validate file path to prevent path traversal attacks.
    Returns the validated real path. Raises ValueError if invalid.
    """
    if not file_path:
        raise ValueError(f"Empty file path for {operation}")

    # Check for path traversal sequences before resolving
    if ".." in file_path:
        raise ValueError(f"Path traversal detected in {operation}: '..' not allowed")

    # Resolve to absolute path
    real_path = os.path.realpath(file_path)

    # Verify the resolved path is within expected boundaries
    cwd = os.path.realpath(".")
    is_absolute_input = os.path.isabs(file_path)

    # If relative path, must resolve within current directory tree
    if not is_absolute_input:
        if not real_path.startswith(cwd):
            raise ValueError(
                f"Path traversal detected in {operation}: resolved path escapes working directory"
            )

    return real_path


# Define virtual machine to search for
# See https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions
# (default options)
DEFAULT_SEARCH_VMSIZE: str = "8"
DEFAULT_SEARCH_VMPATTERN: str = "B#s_v2"
DEFAULT_SEARCH_VMWINDOWS: bool = False
DEFAULT_SEARCH_VMLINUX: bool = True
SPOT_FILTER_CLAUSE: str = " and contains(meterName, 'Spot')"


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
    adapter = HTTPAdapter(
        max_retries=retry_strategy, pool_connections=10, pool_maxsize=10
    )
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session


@rate_limit(calls_per_second=2)
def fetch_pricing_data(
    api_url: str, params: Dict[str, str], session: Session, verbose: bool = False
) -> Dict[str, Any]:
    """Fetch pricing data with error handling and rate limiting."""
    # Validate URL to prevent SSRF attacks
    if not validate_api_url(api_url):
        raise ValueError(f"Invalid or untrusted API URL: {api_url}")

    try:
        if verbose:
            print(f"[VERBOSE] API URL: {api_url}", file=sys.stderr)
            if params:
                print(f"[VERBOSE] Query params: {params}", file=sys.stderr)

        response: Response = session.get(api_url, params=params, timeout=30)

        if verbose:
            print(
                f"[VERBOSE] HTTP Status: {response.status_code} {response.reason}",
                file=sys.stderr,
            )

        response.raise_for_status()

        try:
            data = response.json()
            if verbose:
                items_count = len(data.get("Items", []))
                next_page = "Yes" if data.get("NextPageLink") else "No"
                print(
                    f"[VERBOSE] Response: {items_count} items, NextPage: {next_page}",
                    file=sys.stderr,
                )
            return data
        except JSONDecodeError as e:
            print(f"Error: Invalid JSON response from API: {e}", file=sys.stderr)
            raise

    except exceptions.HTTPError as e:
        print(f"HTTP Error: {e}", file=sys.stderr)
        if hasattr(e.response, "status_code") and e.response.status_code == 429:
            print("Rate limited. Try again later.", file=sys.stderr)
        raise
    except exceptions.RequestException as e:
        print(f"Network Error: {e}", file=sys.stderr)
        raise


def build_pricing_table(
    json_data: Dict[str, Any],
    table_data: List[List[Any]],
    non_spot: bool,
    low_priority: bool,
) -> None:
    """Build pricing table from JSON data with validation."""
    items = json_data.get("Items", [])
    if not items:
        print("Warning: No items found in API response", file=sys.stderr)
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

            # Client-side Windows/Linux filtering (for ARM VMs that skip productName API filter)
            if DEFAULT_SEARCH_VMLINUX and not DEFAULT_SEARCH_VMWINDOWS:
                if "Windows" in product_name:
                    continue
            # Filter Linux if only Windows requested
            if DEFAULT_SEARCH_VMWINDOWS and not DEFAULT_SEARCH_VMLINUX:
                if "Windows" not in product_name:
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
        except (ValueError, TypeError) as e:
            print(f"Warning: Skipping invalid item: {e}", file=sys.stderr)
            continue


def format_output(table_data: List[List[Any]], output_format: str) -> str:
    """Format output in the requested format."""
    if not table_data:
        return "No pricing data found."

    if output_format == "json":
        headers = [
            "SKU",
            "Retail Price",
            "Unit of Measure",
            "Region",
            "Meter",
            "Product Name",
        ]
        json_data = []
        for row in table_data:
            json_data.append(dict(zip(headers, row)))
        return json.dumps(json_data, indent=2)

    if output_format == "csv":
        lines = ["SKU,Retail_Price,Unit_of_Measure,Region,Meter,Product_Name"]
        for row in table_data:
            # Escape commas in strings
            escaped_row = [str(field).replace(",", ";") for field in row]
            lines.append(",".join(escaped_row))
        return "\n".join(lines)

    # table format (default)
    headers = [
        "SKU",
        "Retail Price",
        "Unit of Measure",
        "Region",
        "Meter",
        "Product Name",
    ]
    return tabulate(table_data, headers=headers, tablefmt="psql")


def print_progress(current: int, total: int, prefix: str = "Progress") -> None:
    """Print progress bar."""
    if total == 0:
        return
    percent = (current / total) * 100
    bar_length = 50
    filled_length = int(bar_length * current // total)
    progress_bar = "#" * filled_length + "-" * (bar_length - filled_length)
    print(f"\r{prefix}: |{progress_bar}| {percent:.1f}%", end="", flush=True)


class PageEstimator:
    """Estimate total pages and track ETA for API fetching."""

    # Empirical page count estimates based on query type and scope
    # Azure API returns 100 items per page
    ESTIMATES = {
        "single_sku": 1,  # Single SKU pattern query
        "multi_sku_per_vm": 1,  # Per VM size in multi-VM query
        "per_core_single_region": 4,  # Single query with --region filter
        "per_core_all_regions": 130,  # Single query, all regions
        "all_series_single_region": 5,  # --all-vm-series with --region
        "all_series_all_regions": 140,  # --all-vm-series without --region
        "per_series_query": 2,  # Per series in multi-query mode
    }

    # Typical fetch time per page (seconds) - used for initial ETA
    AVG_PAGE_TIME = 0.6

    def __init__(self) -> None:
        self.page_times: List[float] = []
        self.start_time: float = 0.0
        self.estimated_total: int = 0

    def estimate_pages(
        self,
        query_type: str,
        has_region: bool = False,
        series_count: int = 0,
        vm_count: int = 0,
    ) -> int:
        """Estimate total pages based on query type and parameters."""
        if query_type == "single_sku":
            return self.ESTIMATES["single_sku"] * max(1, vm_count)
        if query_type == "multi_sku":
            return self.ESTIMATES["multi_sku_per_vm"] * max(1, vm_count)
        if query_type == "per_core_single":
            if has_region:
                return self.ESTIMATES["per_core_single_region"]
            return self.ESTIMATES["per_core_all_regions"]
        if query_type == "per_core_multi":
            return self.ESTIMATES["per_series_query"] * max(1, series_count)
        if query_type == "all_series":
            if has_region:
                return self.ESTIMATES["all_series_single_region"]
            return self.ESTIMATES["all_series_all_regions"]
        return 10  # Default fallback

    def start(self, estimated_total: int) -> None:
        """Start tracking with estimated total pages."""
        self.estimated_total = estimated_total
        self.start_time = time.time()
        self.page_times = []

    def record_page(self, page_time: float) -> None:
        """Record time taken for a page fetch."""
        self.page_times.append(page_time)

    def get_avg_page_time(self) -> float:
        """Get average page fetch time based on recorded times."""
        if not self.page_times:
            return self.AVG_PAGE_TIME
        return sum(self.page_times) / len(self.page_times)

    def get_eta_str(self, current_page: int, total_pages: int) -> str:
        """Get ETA string for remaining pages."""
        remaining = max(0, total_pages - current_page)
        if remaining == 0:
            return "done"
        avg_time = self.get_avg_page_time()
        eta_seconds = remaining * avg_time
        if eta_seconds < 60:
            return f"{eta_seconds:.0f}s"
        if eta_seconds < 3600:
            minutes = int(eta_seconds // 60)
            seconds = int(eta_seconds % 60)
            return f"{minutes}m{seconds:02d}s"
        hours = int(eta_seconds // 3600)
        minutes = int((eta_seconds % 3600) // 60)
        return f"{hours}h{minutes:02d}m"

    def format_progress(
        self, current_page: int, total_pages: int, prefix: str = "Fetching"
    ) -> str:
        """Format progress string with page count and ETA."""
        eta = self.get_eta_str(current_page, total_pages)
        return f"{prefix} page {current_page}/{total_pages} (ETA: {eta})"


# Global page estimator instance
PAGE_ESTIMATOR = PageEstimator()


def extract_series_from_vm_size(vm_size: str) -> str:
    """Extract series name from VM size for API query.

    Examples:
        D4pls_v5 -> Dplsv5
        F4s_v2 -> Fsv2
        D4as_v5 -> Dasv5
        B4ls_v2 -> Blsv2
    """
    # Remove leading Standard_ if present
    vm_size = vm_size.replace("Standard_", "")
    # Remove numeric part (the vCPU count)
    # Pattern: letter(s) + digits + rest
    match = re.match(r"^([A-Za-z]+)(\d+)(.*)$", vm_size)
    if match:
        prefix = match.group(1)  # e.g., 'D', 'F', 'B'
        suffix = match.group(3)  # e.g., 'pls_v5', 's_v2'
        # Remove underscores for series name
        series = (prefix + suffix).replace("_", "")
        return series
    return vm_size.replace("_", "")


def extract_cores_from_sku(sku_name: str) -> int:
    """Extract vCPU count from SKU name.

    Examples:
        Standard_D4pls_v5 -> 4
        Standard_F8s_v2 -> 8
        Standard_B2ts_v2 -> 2
        Standard_E96as_v5 -> 96
    """
    # Remove Standard_ prefix if present
    sku_name = sku_name.replace("Standard_", "")
    # Pattern: letter(s) + digits (the core count)
    match = re.match(r"^[A-Za-z]+(\d+)", sku_name)
    if match:
        return int(match.group(1))
    return 0


def is_burstable_vm(sku_name: str) -> bool:
    """Check if VM is burstable (B-series).

    Examples:
        Standard_B4ls_v2 -> True
        Standard_D4pls_v5 -> False
    """
    # Remove Standard_ prefix if present
    sku_name = sku_name.replace("Standard_", "")
    # B-series VMs start with 'B'
    return sku_name.upper().startswith("B")


def is_arm_vm(sku_name: str) -> bool:
    """Check if VM is ARM-based (has 'p' in size designator indicating ARM processor).

    See https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions
    Azure ARM VM naming convention: The 'p' additive feature indicates Arm-based processors.
    Examples:
        Standard_D4ps_v5 -> True (ARM Ampere Altra)
        Standard_D4pls_v5 -> True (ARM Ampere Altra, low memory)
        Standard_D4s_v5 -> False (Intel)
        Standard_D4as_v5 -> False (AMD)
        Dpsv5 -> True (series name)
        Dplsv6 -> True (series name)
    """
    # Remove Standard_ prefix if present
    sku_name = sku_name.replace("Standard_", "")
    # ARM VMs have 'p' after the first letter(s) and before 's' or 'l'
    # Pattern: letter(s) + digits + 'p' + optional 'l/d' + 's'
    # Or for series names: letter(s) + 'p' + optional letters + 'v' + digit
    arm_patterns = [
        r"^[A-Za-z]+\d*p[lds]*_v\d+$",  # SKU: D4ps_v5, D4pls_v5, D4pds_v5
        r"^[A-Za-z]+p[lds]*v\d+$",  # Series: Dpsv5, Dplsv5, Dpdsv6
        r"^[BE]p[lds]*v\d+$",  # Series: Epsv5, Bpsv2
    ]
    for pattern in arm_patterns:
        if re.match(pattern, sku_name, re.IGNORECASE):
            return True
    return False


def is_amd_vm(sku_name: str) -> bool:
    """Check if VM is AMD-based (has 'a' in size designator indicating AMD processor).

    See https://learn.microsoft.com/en-us/azure/virtual-machines/vm-naming-conventions
    Azure AMD VM naming convention: The 'a' additive feature indicates AMD processors.
    Examples:
        Standard_D4as_v5 -> True (AMD EPYC)
        Standard_D4ads_v5 -> True (AMD EPYC, with local disk)
        Standard_E64-16as_v7 -> True (AMD, constrained CPU)
        Standard_F64ams_v6 -> True (AMD, high memory)
        Standard_D4s_v5 -> False (Intel)
        Standard_D4ps_v5 -> False (ARM)
        Dasv5 -> True (series name)
        Famsv6 -> True (series name, AMD high memory)
    """
    sku_name = sku_name.replace("Standard_", "")
    amd_patterns = [
        r"^[A-Za-z]+\d+(?:-\d+)?a[ldms]*_v\d+",  # SKU: D4as_v5, E64-16as_v7
        r"^[A-Za-z]+\d+(?:-\d+)?a[ldms]*_[A-Za-z]",  # SKU with suffix: NV72ads_A10_v5
        r"^[A-Za-z]+a[ldms]*v\d+$",  # Series: Dasv5, Falsv7, Famsv6
    ]
    for pattern in amd_patterns:
        if re.match(pattern, sku_name, re.IGNORECASE):
            return True
    return False


def is_intel_vm(sku_name: str) -> bool:
    """Check if VM is Intel-based (not AMD and not ARM).

    Intel VMs have neither 'a' nor 'p' in the modifier position.
    Examples:
        Standard_D4s_v5 -> True (Intel Xeon)
        Standard_F8s_v2 -> True (Intel Xeon)
        Standard_D64ls_v6 -> True (Intel, low memory)
        Standard_D4as_v5 -> False (AMD)
        Standard_D4ps_v5 -> False (ARM)
    """
    return not is_amd_vm(sku_name) and not is_arm_vm(sku_name)


def should_skip_by_vendor(sku_name: str, args: Any) -> bool:
    """Check if a VM should be skipped based on CPU vendor flags.

    Returns True if the VM should be filtered out.
    """
    if getattr(args, "intel_only", False) and not is_intel_vm(sku_name):
        return True
    if getattr(args, "amd_only", False) and not is_amd_vm(sku_name):
        return True
    if getattr(args, "arm_only", False) and not is_arm_vm(sku_name):
        return True
    if getattr(args, "exclude_intel", False) and is_intel_vm(sku_name):
        return True
    if getattr(args, "exclude_amd", False) and is_amd_vm(sku_name):
        return True
    if getattr(args, "exclude_arm", False) and is_arm_vm(sku_name):
        return True
    return False


# Comprehensive list of Azure VM series for per-core search
# Based on official Azure documentation as of 2024-2025

VM_SERIES_BURSTABLE = ["Bsv2", "Blsv2", "Bpsv2", "Bplsv2"]

# =============================================================================
# COMPUTE OPTIMIZED (F-family) - High CPU-to-memory ratio
# =============================================================================

# Intel Compute Optimized
VM_SERIES_F_INTEL = [
    "Fsv2",  # Intel Xeon Platinum 8272CL (Cascade Lake), 72 vCPUs, 2 GiB/vCPU
]

# AMD v6 Compute Optimized (EPYC 9004 Genoa @ 3.7 GHz)
VM_SERIES_F_AMD_V6 = [
    "Fasv6",  # 64 vCPUs, 256 GiB (4:1)
    "Falsv6",  # 64 vCPUs, 128 GiB (2:1, low memory)
    "Famsv6",  # 64 vCPUs, 512 GiB (8:1, high memory)
]

# AMD v7 Compute Optimized (EPYC 9005 Turin @ 4.5 GHz) - Preview
VM_SERIES_F_AMD_V7 = [
    "Fasv7",  # 80 vCPUs, 320 GiB (4:1)
    "Fadsv7",  # 80 vCPUs + local disk
    "Falsv7",  # 80 vCPUs, 160 GiB (2:1)
    "Faldsv7",  # 80 vCPUs + local disk
    "Famsv7",  # 80 vCPUs, 640 GiB (8:1)
    "Famdsv7",  # 80 vCPUs + local disk
]

# FX Series - High frequency Intel (4.0 GHz)
VM_SERIES_FX = [
    "FXmdsv2",  # Intel Xeon Gold 6246R, 48 vCPUs, 1152 GiB, EDA workloads
]

# =============================================================================
# GENERAL PURPOSE (D-family) - Balanced CPU-to-memory ratio
# =============================================================================

# Intel v5 (Xeon Platinum 8370C Ice Lake)
VM_SERIES_D_INTEL_V5 = [
    "Dv5",
    "Dsv5",  # 96 vCPUs, 384 GiB, no local disk
    "Ddv5",
    "Ddsv5",  # 96 vCPUs, 384 GiB, with local disk
    "Dlsv5",
    "Dldsv5",  # 96 vCPUs, 192 GiB (2:1, low memory)
]

# AMD v5 (EPYC 7763v Milan)
VM_SERIES_D_AMD_V5 = [
    "Dasv5",
    "Dadsv5",  # 96 vCPUs, 384 GiB
]

# Intel v6 (Xeon Platinum 8473C Sapphire Rapids)
VM_SERIES_D_INTEL_V6 = [
    "Dsv6",
    "Ddsv6",  # 128 vCPUs, 512 GiB (4:1)
    "Dlsv6",
    "Dldsv6",  # 128 vCPUs, 256 GiB (2:1)
]

# Intel v7 (Xeon 6 Granite Rapids) - Preview
VM_SERIES_D_INTEL_V7 = [
    "Dsv7",
    "Ddsv7",  # (4:1)
    "Dlsv7",
    "Dldsv7",  # (2:1, low memory)
]

# AMD v6 (EPYC 9004 Genoa @ 3.7 GHz)
VM_SERIES_D_AMD_V6 = [
    "Dasv6",
    "Dadsv6",  # 96 vCPUs, 384 GiB (4:1)
    "Dalsv6",
    "Daldsv6",  # 96 vCPUs, 192 GiB (2:1)
]

# AMD v7 (EPYC 9005 Turin @ 4.5 GHz) - Preview
VM_SERIES_D_AMD_V7 = [
    "Dasv7",
    "Dadsv7",  # 160 vCPUs, 640 GiB (4:1)
    "Dalsv7",
    "Daldsv7",  # 160 vCPUs, 320 GiB (2:1)
]

# ARM v5 (Ampere Altra)
VM_SERIES_D_ARM_V5 = [
    "Dpsv5",
    "Dpdsv5",  # 64 vCPUs, 208 GiB (4:1)
    "Dplsv5",
    "Dpldsv5",  # 64 vCPUs, 128 GiB (2:1)
]

# ARM v6 (Azure Cobalt 100 @ 3.4 GHz) - Best price-performance
VM_SERIES_D_ARM_V6 = [
    "Dpsv6",
    "Dpdsv6",  # 96 vCPUs, 384 GiB (4:1)
    "Dplsv6",
    "Dpldsv6",  # 96 vCPUs, 192 GiB (2:1)
]

# =============================================================================
# COMBINED LISTS
# =============================================================================

# All Compute Optimized
VM_SERIES_COMPUTE_OPTIMIZED = (
    VM_SERIES_F_INTEL + VM_SERIES_F_AMD_V6 + VM_SERIES_F_AMD_V7 + VM_SERIES_FX
)

# All General Purpose (current gen)
VM_SERIES_GENERAL_PURPOSE = (
    VM_SERIES_D_INTEL_V5
    + VM_SERIES_D_INTEL_V6
    + VM_SERIES_D_INTEL_V7
    + VM_SERIES_D_AMD_V5
    + VM_SERIES_D_AMD_V6
    + VM_SERIES_D_AMD_V7
    + VM_SERIES_D_ARM_V5
    + VM_SERIES_D_ARM_V6
)

# General compute = D + F series (non-exotic)
VM_SERIES_GENERAL_COMPUTE = VM_SERIES_GENERAL_PURPOSE + VM_SERIES_COMPUTE_OPTIMIZED

# =============================================================================
# MEMORY OPTIMIZED (E-family) - High memory-to-CPU ratio
# =============================================================================

# Intel v5 (Xeon Platinum 8370C Ice Lake)
VM_SERIES_E_INTEL_V5 = [
    "Ev5",
    "Esv5",  # 104 vCPUs, 672 GiB, no local disk
    "Edv5",
    "Edsv5",  # 104 vCPUs, 672 GiB, with local disk
    "Ebsv5",
    "Ebdsv5",  # 104 vCPUs, with bandwidth optimized storage
]

# AMD v5 (EPYC 7763v Milan)
VM_SERIES_E_AMD_V5 = [
    "Easv5",
    "Eadsv5",  # 96 vCPUs, 672 GiB
]

# Intel v6 (Xeon Platinum 8473C Sapphire Rapids)
VM_SERIES_E_INTEL_V6 = [
    "Esv6",
    "Edsv6",  # 128 vCPUs, 1024 GiB (8:1)
    "Ebsv6",
    "Ebdsv6",  # 128 vCPUs, storage optimized
]

# Intel v7 (Xeon 6 Granite Rapids) - Preview
VM_SERIES_E_INTEL_V7 = [
    "Esv7",
    "Edsv7",  # (8:1)
    "Ebsv7",
    "Ebdsv7",  # storage optimized
]

# AMD v6 (EPYC 9004 Genoa @ 3.7 GHz)
VM_SERIES_E_AMD_V6 = [
    "Easv6",
    "Eadsv6",  # 96 vCPUs, 672 GiB
]

# AMD v7 (EPYC 9005 Turin @ 4.5 GHz) - Preview
VM_SERIES_E_AMD_V7 = [
    "Easv7",
    "Eadsv7",  # 160 vCPUs, 1024 GiB (8:1)
    "Ealsv7",
    "Ealdsv7",  # 160 vCPUs, 512 GiB (4:1, low memory)
]

# ARM v5 (Ampere Altra)
VM_SERIES_E_ARM_V5 = [
    "Epsv5",
    "Epdsv5",  # 64 vCPUs, 208 GiB
]

# ARM v6 (Azure Cobalt 100 @ 3.4 GHz)
VM_SERIES_E_ARM_V6 = [
    "Epsv6",
    "Epdsv6",  # 96 vCPUs, 384 GiB
]

# All Memory Optimized
VM_SERIES_MEMORY_OPTIMIZED = (
    VM_SERIES_E_INTEL_V5
    + VM_SERIES_E_INTEL_V6
    + VM_SERIES_E_INTEL_V7
    + VM_SERIES_E_AMD_V5
    + VM_SERIES_E_AMD_V6
    + VM_SERIES_E_AMD_V7
    + VM_SERIES_E_ARM_V5
    + VM_SERIES_E_ARM_V6
)

# All non-burstable series
VM_SERIES_NON_BURSTABLE = VM_SERIES_GENERAL_COMPUTE + VM_SERIES_MEMORY_OPTIMIZED

# Latest generation only (v6/v7) - for fast queries
VM_SERIES_LATEST = (
    # D-series latest (Intel v6/v7 + AMD v6/v7 + ARM v6)
    VM_SERIES_D_INTEL_V6
    + VM_SERIES_D_INTEL_V7
    + VM_SERIES_D_AMD_V6
    + VM_SERIES_D_AMD_V7
    + VM_SERIES_D_ARM_V6
    +
    # F-series latest (AMD v6/v7)
    VM_SERIES_F_AMD_V6
    + VM_SERIES_F_AMD_V7
    +
    # E-series latest (Intel v6/v7 + AMD v6/v7 + ARM v6)
    VM_SERIES_E_INTEL_V6
    + VM_SERIES_E_INTEL_V7
    + VM_SERIES_E_AMD_V6
    + VM_SERIES_E_AMD_V7
    + VM_SERIES_E_ARM_V6
)


def _process_per_core_item(
    item: Dict[str, Any],
    args: Any,
    per_core_data: List[List[Any]],
    non_spot: bool,
    low_priority: bool,
    excluded_regions: set,
    excluded_vm_sizes: set,
    excluded_sku_patterns: Optional[List[re.Pattern]] = None,
) -> None:
    """Process a single pricing item for per-core mode."""
    try:
        arm_sku_name: str = item.get("armSkuName", "")
        retail_price: float = float(item.get("retailPrice", 0.0))
        unit_of_measure: str = item.get("unitOfMeasure", "")
        arm_region_name: str = item.get("armRegionName", "")
        meter_name: str = item.get("meterName", "")
        product_name: str = item.get("productName", "")

        if not arm_sku_name or retail_price <= 0:
            return

        # Filter Windows if only Linux requested
        if DEFAULT_SEARCH_VMLINUX and not DEFAULT_SEARCH_VMWINDOWS:
            if "Windows" in product_name:
                return
        # Filter Linux if only Windows requested
        if DEFAULT_SEARCH_VMWINDOWS and not DEFAULT_SEARCH_VMLINUX:
            if "Windows" not in product_name:
                return

        if non_spot and "Spot" in meter_name:
            return
        if not low_priority and "Low Priority" in meter_name:
            return

        # Extract core count and filter
        cores = extract_cores_from_sku(arm_sku_name)
        if cores < args.min_cores or cores > args.max_cores:
            return

        # Filter by burstable
        is_burstable = is_burstable_vm(arm_sku_name)
        if args.burstable_only and not is_burstable:
            return
        if args.no_burstable and is_burstable:
            return

        # Filter by CPU vendor
        if should_skip_by_vendor(arm_sku_name, args):
            return

        # Filter for general-compute: only D and F series (non-burstable)
        if getattr(args, "general_compute", False):
            sku_upper = arm_sku_name.replace("Standard_", "").upper()
            # Only allow D-series and F-series (general purpose + compute optimized)
            if not (sku_upper.startswith("D") or sku_upper.startswith("F")):
                return
            # Exclude burstable B-series
            if is_burstable:
                return

        # Filter excluded regions
        if arm_region_name.lower() in excluded_regions:
            return

        # Filter excluded VM sizes
        normalized_sku = arm_sku_name.replace("Standard_", "").lower()
        if normalized_sku in excluded_vm_sizes:
            return

        # Filter excluded SKU patterns
        if excluded_sku_patterns:
            for pattern in excluded_sku_patterns:
                if pattern.match(normalized_sku):
                    return

        price_per_core = retail_price / cores

        per_core_data.append(
            [
                arm_sku_name,
                retail_price,
                price_per_core,
                cores,
                unit_of_measure,
                arm_region_name,
                meter_name,
                product_name,
            ]
        )
    except (ValueError, TypeError):
        pass


def main() -> None:
    """Main entry point for Azure VM spot price finder."""
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s"
    )

    table_data: List[List[Any]] = []
    parser: ArgumentParser = ArgumentParser(description="Get Azure VM spot prices")
    parser.add_argument(
        "--cpu",
        default=DEFAULT_SEARCH_VMSIZE,
        type=int,
        help="Number of CPUs (default: %(default)s)",
    )
    parser.add_argument(
        "--sku-pattern",
        default=DEFAULT_SEARCH_VMPATTERN,
        type=str,
        help="VM instance size SKU pattern (default: %(default)s)",
    )
    parser.add_argument(
        "--series-pattern",
        default=DEFAULT_SEARCH_VMPATTERN,
        type=str,
        help="VM instance size Series pattern (optional)",
    )
    parser.add_argument(
        "--vm-sizes",
        type=str,
        help="Comma-separated VM sizes (e.g., D4pls_v5,D4ps_v5). "
        "Overrides --sku-pattern and --series-pattern",
    )
    parser.add_argument(
        "--non-spot", action="store_true", help="Only return non-spot instances"
    )
    parser.add_argument(
        "--low-priority",
        action="store_true",
        help='Include low priority instances (by default, skip VMs with "Low Priority" in meterName)',
    )
    parser.add_argument(
        "--return-region",
        action="store_true",
        help="Return only one region output if found",
    )
    parser.add_argument(
        "--exclude-regions",
        type=str,
        help="Comma-separated list of regions to exclude (e.g., centralindia,eastus)",
    )
    parser.add_argument(
        "--exclude-regions-file",
        type=str,
        action="append",
        help="File containing regions to exclude (one per line). Can be specified multiple times.",
    )
    parser.add_argument(
        "--exclude-vm-sizes",
        type=str,
        help="Comma-separated list of VM sizes to exclude (e.g., D4pls_v5,D4ps_v5)",
    )
    parser.add_argument(
        "--exclude-vm-sizes-file",
        type=str,
        help="File containing VM sizes to exclude (one per line)",
    )
    parser.add_argument(
        "--exclude-sku-patterns",
        type=str,
        help='Comma-separated SKU patterns to exclude (# = digits). Example: "D#ps_v6,E#pds_v6"',
    )
    parser.add_argument(
        "--exclude-sku-patterns-file",
        type=str,
        help="File containing SKU patterns to exclude (one per line, # = digits)",
    )
    parser.add_argument("--log-level", type=str, help="Set the logging level")
    parser.add_argument(
        "--output-format",
        choices=["table", "json", "csv"],
        default="table",
        help="Output format (default: %(default)s)",
    )
    parser.add_argument("--output-file", help="Save output to file instead of stdout")
    parser.add_argument(
        "--dry-run", action="store_true", help="Show API query without executing"
    )
    parser.add_argument(
        "--validate-config", action="store_true", help="Validate configuration and exit"
    )

    # Per-core pricing arguments
    parser.add_argument(
        "--min-cores", type=int, help="Minimum vCPU count for per-core pricing search"
    )
    parser.add_argument(
        "--max-cores", type=int, help="Maximum vCPU count for per-core pricing search"
    )
    parser.add_argument(
        "--burstable-only",
        action="store_true",
        help="Only B-series. Single query mode (~4 pages/region, ~130 all regions)",
    )
    parser.add_argument(
        "--no-burstable",
        action="store_true",
        help="Exclude B-series. Single query mode (~4 pages/region, ~130 all regions)",
    )
    parser.add_argument(
        "--general-compute",
        action="store_true",
        help="Only D+F series. Single query mode (~4 pages/region, ~130 all regions)",
    )
    parser.add_argument(
        "--latest",
        action="store_true",
        help="Only v6/v7 series. Multi-query mode (1 page per series)",
    )
    parser.add_argument(
        "--series",
        type=str,
        help="Specific series list (e.g., Dasv6,Fasv7). Multi-query (1 page/series)",
    )
    parser.add_argument(
        "--region",
        type=str,
        help="Filter to region(s) (e.g., eastus). Reduces pages from ~130 to ~4",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print verbose debug info (API URL, query, HTTP status, raw data)",
    )
    parser.add_argument(
        "--exclude-arm",
        action="store_true",
        help="Exclude ARM-based VMs (those with p suffix like D4ps_v5)",
    )
    parser.add_argument(
        "--exclude-intel",
        action="store_true",
        help="Exclude Intel-based VMs",
    )
    parser.add_argument(
        "--exclude-amd",
        action="store_true",
        help="Exclude AMD-based VMs (those with a suffix like D4as_v5)",
    )
    parser.add_argument(
        "--intel-only",
        action="store_true",
        help="Show only Intel-based VMs (mutually exclusive with --amd-only, --arm-only)",
    )
    parser.add_argument(
        "--amd-only",
        action="store_true",
        help="Show only AMD-based VMs (mutually exclusive with --intel-only, --arm-only)",
    )
    parser.add_argument(
        "--arm-only",
        action="store_true",
        help="Show only ARM-based VMs (mutually exclusive with --intel-only, --amd-only)",
    )
    parser.add_argument(
        "--return-region-json",
        action="store_true",
        help="Return single region output in JSON format (for PowerShell parsing)",
    )
    parser.add_argument(
        "--show-deprecation-warnings",
        action="store_true",
        help="Show deprecation warnings from libraries (hidden by default)",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=20,
        help="Number of results to display (default: 20, use 0 for all)",
    )
    parser.add_argument(
        "--all-vm-series",
        action="store_true",
        help="Query all VM series without filters. Only region and spot/non-spot "
        "filters apply. Use --cpu for client-side core filtering.",
    )
    parser.add_argument(
        "--windows",
        action="store_true",
        help="Search for Windows VMs instead of Linux (default: Linux). "
        "Windows VMs typically cost 8-15%% more due to OS license fees. "
        "Uses 'productName contains Windows' filter for accurate results.",
    )

    args: Namespace = parser.parse_args()

    # Validate CPU vendor flags
    only_flags = [
        ("--intel-only", getattr(args, "intel_only", False)),
        ("--amd-only", getattr(args, "amd_only", False)),
        ("--arm-only", getattr(args, "arm_only", False)),
    ]
    active_only = [name for name, val in only_flags if val]
    if len(active_only) > 1:
        logging.error(
            f"Cannot specify multiple --*-only flags: {', '.join(active_only)}"
        )
        sys.exit(1)
    if getattr(args, "intel_only", False) and getattr(args, "exclude_intel", False):
        logging.error("Cannot specify both --intel-only and --exclude-intel")
        sys.exit(1)
    if getattr(args, "amd_only", False) and getattr(args, "exclude_amd", False):
        logging.error("Cannot specify both --amd-only and --exclude-amd")
        sys.exit(1)
    if getattr(args, "arm_only", False) and getattr(args, "exclude_arm", False):
        logging.error("Cannot specify both --arm-only and --exclude-arm")
        sys.exit(1)
    exclude_count = sum([
        getattr(args, "exclude_intel", False),
        getattr(args, "exclude_amd", False),
        getattr(args, "exclude_arm", False),
    ])
    if exclude_count >= 3:
        logging.error("Cannot exclude all three CPU vendors (Intel, AMD, ARM)")
        sys.exit(1)

    # Configure deprecation warnings (suppress by default unless explicitly requested)
    if not args.show_deprecation_warnings:
        warnings.filterwarnings("ignore", category=DeprecationWarning)
        warnings.filterwarnings("ignore", category=PendingDeprecationWarning)
        warnings.filterwarnings("ignore", category=FutureWarning)

    # Override OS filtering based on --windows argument
    global DEFAULT_SEARCH_VMWINDOWS, DEFAULT_SEARCH_VMLINUX
    if args.windows:
        DEFAULT_SEARCH_VMWINDOWS = True
        DEFAULT_SEARCH_VMLINUX = False

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
    return_region: bool = args.return_region or args.return_region_json

    # Validate per-core pricing arguments
    # Per-core mode is triggered by:
    # 1. Explicit --min-cores or --max-cores
    # 2. --no-burstable or --burstable-only (uses --cpu as exact core count if no min/max specified)
    # 3. --general-compute or --latest
    has_core_range = args.min_cores is not None or args.max_cores is not None
    has_filter_flags = (
        args.burstable_only
        or args.no_burstable
        or getattr(args, "general_compute", False)
        or getattr(args, "latest", False)
    )
    per_core_mode: bool = has_core_range or has_filter_flags

    if per_core_mode:
        # Set core range defaults
        if args.min_cores is None and args.max_cores is None:
            # Use --cpu as exact core count when filter flags are used without explicit range
            args.min_cores = args.cpu
            args.max_cores = args.cpu
        elif args.min_cores is None:
            args.min_cores = 1
        elif args.max_cores is None:
            args.max_cores = 128

        if args.min_cores > args.max_cores:
            logging.error("--min-cores cannot be greater than --max-cores")
            sys.exit(1)
        if args.burstable_only and args.no_burstable:
            logging.error("Cannot specify both --burstable-only and --no-burstable")
            sys.exit(1)
        if args.vm_sizes:
            logging.error("Cannot use --vm-sizes with per-core mode flags")
            sys.exit(1)
        if getattr(args, "all_vm_series", False):
            logging.error("Cannot use --all-vm-series with per-core mode flags")
            sys.exit(1)

    # Build excluded regions set
    excluded_regions: set = set()
    if args.exclude_regions:
        for rgn in args.exclude_regions.split(","):
            rgn = rgn.strip().lower()
            if rgn:
                excluded_regions.add(rgn)
    if args.exclude_regions_file:
        for exclude_file in args.exclude_regions_file:
            try:
                with open(exclude_file, "r", encoding="utf-8") as f:
                    for line in f:
                        rgn = line.strip().lower()
                        if rgn and not rgn.startswith("#"):
                            excluded_regions.add(rgn)
                logging.debug(f"Loaded exclusions from {exclude_file}")
            except IOError as e:
                logging.warning(
                    f"Could not read exclude-regions-file {exclude_file}: {e}"
                )
    if excluded_regions:
        logging.debug(f"Excluding regions: {', '.join(sorted(excluded_regions))}")

    # Build excluded VM sizes set
    excluded_vm_sizes: set = set()
    if args.exclude_vm_sizes:
        for sz in args.exclude_vm_sizes.split(","):
            sz = sz.strip()
            if sz:
                # Normalize: remove Standard_ prefix if present, store lowercase
                sz = sz.replace("Standard_", "").lower()
                excluded_vm_sizes.add(sz)
    if args.exclude_vm_sizes_file:
        try:
            with open(args.exclude_vm_sizes_file, "r", encoding="utf-8") as f:
                for line in f:
                    sz = line.strip()
                    if sz and not sz.startswith("#"):
                        sz = sz.replace("Standard_", "").lower()
                        excluded_vm_sizes.add(sz)
        except IOError as e:
            logging.warning(f"Could not read exclude-vm-sizes-file: {e}")
    if excluded_vm_sizes:
        logging.debug(f"Excluding VM sizes: {', '.join(sorted(excluded_vm_sizes))}")

    # Build excluded SKU patterns list (as compiled regex)
    excluded_sku_patterns: List[re.Pattern] = []
    sku_pattern_strings: List[str] = []
    if args.exclude_sku_patterns:
        for pattern in args.exclude_sku_patterns.split(","):
            pattern = pattern.strip()
            if pattern:
                sku_pattern_strings.append(pattern)
    if args.exclude_sku_patterns_file:
        try:
            with open(args.exclude_sku_patterns_file, "r", encoding="utf-8") as f:
                for line in f:
                    pattern = line.strip()
                    if pattern and not pattern.startswith("#"):
                        sku_pattern_strings.append(pattern)
        except IOError as e:
            logging.warning(f"Could not read exclude-sku-patterns-file: {e}")
    # Convert patterns to regex (# = one or more digits)
    for pattern in sku_pattern_strings:
        # Escape regex special chars except #, then replace # with \d+
        regex_pattern = re.escape(pattern).replace(r"\#", r"\d+")
        # Match full SKU name (case insensitive)
        regex_pattern = f"^{regex_pattern}$"
        try:
            excluded_sku_patterns.append(re.compile(regex_pattern, re.IGNORECASE))
            logging.debug(f"SKU exclusion pattern: {pattern} -> {regex_pattern}")
        except re.error as e:
            logging.warning(f"Invalid SKU pattern '{pattern}': {e}")
    if excluded_sku_patterns:
        logging.debug(f"Excluding {len(excluded_sku_patterns)} SKU patterns")

    # Configure logging (default: WARNING, use --log-level to change)
    if args.log_level:
        allowed_levels = ("ERROR", "INFO", "WARNING", "DEBUG")
        normalized_level = args.log_level.upper()
        if normalized_level not in allowed_levels:
            logging.error(
                f"Invalid log level: {args.log_level}. Valid options are: {', '.join(allowed_levels)}"
            )
            sys.exit(1)
        logging.getLogger().setLevel(getattr(logging, normalized_level))
    else:
        if return_region:
            logging.getLogger().setLevel(logging.ERROR)
        else:
            logging.getLogger().setLevel(logging.WARNING)

    # Per-core pricing mode
    if per_core_mode:
        api_url = "https://prices.azure.com/api/retail/prices"
        session = create_resilient_session()
        max_pages = 200  # Increased for single-query mode

        per_core_data: List[List[Any]] = (
            []
        )  # [sku, price, price_per_core, cores, unit, region, meter, product]

        # Determine query mode: single query (all VMs) vs multi-query (specific series)
        # Single query mode: no series filter, all VMs returned, client-side filtering
        # Multi-query mode: specific series list, one API call per series
        use_single_query = False
        series_list: List[str] = []

        if args.series:
            # Explicit series list - use multi-query mode
            series_list = [s.strip() for s in args.series.split(",") if s.strip()]
        elif getattr(args, "latest", False):
            # Latest generation - use multi-query (specific known series)
            series_list = list(VM_SERIES_LATEST)
        elif getattr(args, "general_compute", False):
            # General compute (D+F series) - use single query with client-side filter
            use_single_query = True
        elif args.burstable_only:
            # Burstable only - use single query with client-side filter
            use_single_query = True
        elif args.no_burstable:
            # No burstable - use single query with client-side filter
            use_single_query = True
        else:
            # Default: all VMs - use single query
            use_single_query = True

        # Pre-filter series list by vendor to avoid unnecessary API calls
        if series_list:
            original_count = len(series_list)
            series_list = [
                s for s in series_list if not should_skip_by_vendor(s, args)
            ]
            if len(series_list) < original_count:
                logging.debug(
                    f"Vendor filter reduced series from {original_count} to {len(series_list)}"
                )
            if not series_list:
                logging.error(
                    "No VM series remain after applying CPU vendor filters"
                )
                sys.exit(1)

        try:
            if use_single_query:
                # Single API call for all VMs, client-side filtering
                has_region = bool(args.region)
                estimated_pages = PAGE_ESTIMATOR.estimate_pages(
                    "per_core_single", has_region=has_region
                )
                PAGE_ESTIMATOR.start(estimated_pages)

                if not return_region:
                    print(
                        f"Searching for cheapest spot price per core ({args.min_cores}-{args.max_cores} vCPUs)..."
                    )
                    print(
                        f"Fetching all VM pricing data (~{estimated_pages} pages expected)..."
                    )

                query = (
                    "priceType eq 'Consumption' and serviceName eq 'Virtual Machines' "
                    "and serviceFamily eq 'Compute'"
                )
                if not non_spot:
                    query += SPOT_FILTER_CLAUSE
                # Add region filter if specified
                if args.region:
                    regions = [r.strip() for r in args.region.split(",") if r.strip()]
                    if len(regions) == 1:
                        query += f" and armRegionName eq '{regions[0]}'"
                    elif len(regions) > 1:
                        region_filter = " or ".join(
                            [f"armRegionName eq '{r}'" for r in regions]
                        )
                        query += f" and ({region_filter})"

                logging.debug(f"Query: {query}")

                page_start = time.time()
                json_data = fetch_pricing_data(
                    api_url, {"$filter": query}, session, verbose=args.verbose
                )
                PAGE_ESTIMATOR.record_page(time.time() - page_start)
                items = json_data.get("Items", [])
                next_page = json_data.get("NextPageLink", "")
                page_count = 1

                while next_page and page_count < max_pages:
                    if not return_region:
                        progress_msg = PAGE_ESTIMATOR.format_progress(
                            page_count + 1, estimated_pages
                        )
                        print(f"\r{progress_msg}        ", end="", flush=True)
                    try:
                        page_start = time.time()
                        json_data = fetch_pricing_data(
                            next_page, {}, session, verbose=args.verbose
                        )
                        PAGE_ESTIMATOR.record_page(time.time() - page_start)
                        items.extend(json_data.get("Items", []))
                        next_page = json_data.get("NextPageLink", "")
                        page_count += 1
                    except Exception:
                        break

                if not return_region:
                    print(f"\rFetched {len(items)} items from {page_count} pages        ")

                # Process all items with client-side filtering
                for item in items:
                    _process_per_core_item(
                        item,
                        args,
                        per_core_data,
                        non_spot,
                        low_priority,
                        excluded_regions,
                        excluded_vm_sizes,
                        excluded_sku_patterns,
                    )
            else:
                # Multi-query mode: one API call per series
                estimated_pages = PAGE_ESTIMATOR.estimate_pages(
                    "per_core_multi", series_count=len(series_list)
                )
                PAGE_ESTIMATOR.start(estimated_pages)

                if not return_region:
                    print(
                        f"Searching for cheapest spot price per core ({args.min_cores}-{args.max_cores} vCPUs)..."
                    )
                    print(
                        f"Querying {len(series_list)} VM series (~{estimated_pages} pages expected)..."
                    )

                for idx, series_name in enumerate(series_list):
                    if not return_region:
                        eta = PAGE_ESTIMATOR.get_eta_str(idx, len(series_list))
                        print(
                            f"\r[{idx + 1}/{len(series_list)}] {series_name} (ETA: {eta})     ",
                            end="",
                            flush=True,
                        )

                    query = (
                        "priceType eq 'Consumption' and serviceName eq 'Virtual Machines' "
                        "and serviceFamily eq 'Compute'"
                    )
                    query += f" and productName eq 'Virtual Machines {series_name} Series'"
                    if not non_spot:
                        query += SPOT_FILTER_CLAUSE
                    # Add region filter if specified
                    if args.region:
                        regions = [
                            r.strip() for r in args.region.split(",") if r.strip()
                        ]
                        if len(regions) == 1:
                            query += f" and armRegionName eq '{regions[0]}'"
                        elif len(regions) > 1:
                            region_filter = " or ".join(
                                [f"armRegionName eq '{r}'" for r in regions]
                            )
                            query += f" and ({region_filter})"

                    logging.debug(f"Query: {query}")

                    try:
                        page_start = time.time()
                        json_data = fetch_pricing_data(
                            api_url, {"$filter": query}, session, verbose=args.verbose
                        )
                        PAGE_ESTIMATOR.record_page(time.time() - page_start)
                    except Exception as e:
                        logging.debug(f"No data for {series_name}: {e}")
                        continue

                    items = json_data.get("Items", [])
                    next_page = json_data.get("NextPageLink", "")
                    page_count = 1

                    while next_page and page_count < 50:
                        try:
                            page_start = time.time()
                            json_data = fetch_pricing_data(
                                next_page, {}, session, verbose=args.verbose
                            )
                            PAGE_ESTIMATOR.record_page(time.time() - page_start)
                            items.extend(json_data.get("Items", []))
                            next_page = json_data.get("NextPageLink", "")
                            page_count += 1
                        except Exception:
                            break

                    # Process items for this series
                    for item in items:
                        _process_per_core_item(
                            item,
                            args,
                            per_core_data,
                            non_spot,
                            low_priority,
                            excluded_regions,
                            excluded_vm_sizes,
                            excluded_sku_patterns,
                        )

            if not return_region:
                print()  # New line after progress

        except Exception as e:
            logging.error(f"Failed to fetch pricing data: {e}")
            sys.exit(1)
        finally:
            session.close()

        if not per_core_data:
            logging.error("No pricing data found for the specified criteria")
            sys.exit(1)

        # Sort by price per core
        per_core_data.sort(key=lambda x: x[2])

        # Output results
        if return_region:
            best = per_core_data[0]
            best_region = best[5]
            best_vm_size = best[0]
            best_price = best[1]
            best_unit = best[4]
            if args.return_region_json:
                # JSON format for PowerShell parsing
                result = {
                    "region": best_region,
                    "vmSize": best_vm_size,
                    "price": best_price,
                    "unit": best_unit,
                }
                print(json.dumps(result))
            else:
                print(f"{best_region} {best_vm_size} {best_price} {best_unit}")
        else:
            print(
                f"\nFound {len(per_core_data)} VM options in {args.min_cores}-{args.max_cores} vCPU range"
            )
            top_label = f"Top {args.top}" if args.top > 0 else "All"
            print(f"{top_label} cheapest per-core options:\n")

            headers = ["SKU", "$/Hour", "$/Core/Hr", "Cores", "Region"]
            display_data = []
            seen = set()  # Deduplicate by SKU+region
            for row in per_core_data:
                key = (row[0], row[5])
                if key in seen:
                    continue
                seen.add(key)
                display_data.append(
                    [
                        row[0],  # SKU
                        f"{row[1]:.6f}",  # Price (6 decimals for very low prices)
                        f"{row[2]:.7f}",  # Price per core (7 decimals)
                        row[3],  # Cores
                        row[5],  # Region
                    ]
                )
                if args.top > 0 and len(display_data) >= args.top:
                    break

            print(
                tabulate(
                    display_data,
                    headers=headers,
                    tablefmt="psql",
                    disable_numparse=True,
                )
            )
        sys.exit(0)

    # All VM series mode - query without series filter, client-side filtering
    if getattr(args, "all_vm_series", False):
        api_url = "https://prices.azure.com/api/retail/prices"
        session = create_resilient_session()
        max_pages = 300  # Large limit for unfiltered queries

        all_series_data: List[List[Any]] = []

        # Estimate pages for all-vm-series mode
        has_region = bool(args.region)
        estimated_pages = PAGE_ESTIMATOR.estimate_pages(
            "all_series", has_region=has_region
        )
        PAGE_ESTIMATOR.start(estimated_pages)

        try:
            if not return_region:
                print(
                    f"Querying all VM series (~{estimated_pages} pages expected)..."
                )

            # Build minimal query - no productName, no armSkuName
            query = "priceType eq 'Consumption' and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'"
            if not non_spot:
                query += SPOT_FILTER_CLAUSE
            # Add region filter if specified
            if args.region:
                regions = [r.strip() for r in args.region.split(",") if r.strip()]
                if len(regions) == 1:
                    query += f" and armRegionName eq '{regions[0]}'"
                elif len(regions) > 1:
                    region_filter = " or ".join(
                        [f"armRegionName eq '{r}'" for r in regions]
                    )
                    query += f" and ({region_filter})"

            logging.debug(f"Query: {query}")

            if args.dry_run:
                print("DRY RUN - All VM Series Query:")
                print(f"URL: {api_url}")
                print(f"Filter: {query}")
                sys.exit(0)

            page_start = time.time()
            json_data = fetch_pricing_data(
                api_url, {"$filter": query}, session, verbose=args.verbose
            )
            PAGE_ESTIMATOR.record_page(time.time() - page_start)
            items = json_data.get("Items", [])
            next_page = json_data.get("NextPageLink", "")
            page_count = 1

            while next_page and page_count < max_pages:
                if not return_region:
                    progress_msg = PAGE_ESTIMATOR.format_progress(
                        page_count + 1, estimated_pages
                    )
                    print(f"\r{progress_msg}        ", end="", flush=True)
                try:
                    page_start = time.time()
                    json_data = fetch_pricing_data(
                        next_page, {}, session, verbose=args.verbose
                    )
                    PAGE_ESTIMATOR.record_page(time.time() - page_start)
                    items.extend(json_data.get("Items", []))
                    next_page = json_data.get("NextPageLink", "")
                    page_count += 1
                except Exception:
                    break

            if not return_region:
                print(f"\rFetched {len(items)} items from {page_count} pages        ")

            # Client-side filtering
            cpu_filter = args.cpu if args.cpu != int(DEFAULT_SEARCH_VMSIZE) else None

            for item in items:
                try:
                    arm_sku_name: str = item.get("armSkuName", "")
                    retail_price: float = float(item.get("retailPrice", 0.0))
                    unit_of_measure: str = item.get("unitOfMeasure", "")
                    arm_region_name: str = item.get("armRegionName", "")
                    meter_name: str = item.get("meterName", "")
                    product_name: str = item.get("productName", "")

                    if not arm_sku_name or retail_price <= 0:
                        continue

                    # Filter Windows if only Linux requested
                    if DEFAULT_SEARCH_VMLINUX and not DEFAULT_SEARCH_VMWINDOWS:
                        if "Windows" in product_name:
                            continue
                    # Filter Linux if only Windows requested
                    if DEFAULT_SEARCH_VMWINDOWS and not DEFAULT_SEARCH_VMLINUX:
                        if "Windows" not in product_name:
                            continue

                    if non_spot and "Spot" in meter_name:
                        continue
                    if not low_priority and "Low Priority" in meter_name:
                        continue

                    # Filter by CPU count if specified
                    if cpu_filter is not None:
                        cores = extract_cores_from_sku(arm_sku_name)
                        if cores != cpu_filter:
                            continue

                    # Filter by CPU vendor
                    if should_skip_by_vendor(arm_sku_name, args):
                        continue

                    # Filter excluded regions
                    if arm_region_name.lower() in excluded_regions:
                        continue

                    # Filter excluded VM sizes
                    normalized_sku = arm_sku_name.replace("Standard_", "").lower()
                    if normalized_sku in excluded_vm_sizes:
                        continue

                    # Filter excluded SKU patterns
                    if excluded_sku_patterns:
                        skip = False
                        for pattern in excluded_sku_patterns:
                            if pattern.match(normalized_sku):
                                skip = True
                                break
                        if skip:
                            continue

                    all_series_data.append(
                        [
                            arm_sku_name,
                            retail_price,
                            unit_of_measure,
                            arm_region_name,
                            meter_name,
                            product_name,
                        ]
                    )
                except (ValueError, TypeError):
                    continue

        except Exception as e:
            logging.error(f"Failed to fetch pricing data: {e}")
            sys.exit(1)
        finally:
            session.close()

        if not all_series_data:
            logging.error("No pricing data found for the specified criteria")
            sys.exit(1)

        # Sort by price
        all_series_data.sort(key=lambda x: x[1])

        # Output results
        if return_region:
            best = all_series_data[0]
            best_region = best[3]
            best_vm_size = best[0]
            best_price = best[1]
            best_unit = best[2]
            if args.return_region_json:
                result = {
                    "region": best_region,
                    "vmSize": best_vm_size,
                    "price": best_price,
                    "unit": best_unit,
                }
                print(json.dumps(result))
            else:
                print(f"{best_region} {best_vm_size} {best_price} {best_unit}")
        else:
            print(f"\nFound {len(all_series_data)} VM options")
            if cpu_filter:
                print(f"Filtered to {cpu_filter} vCPU VMs")
            top_label = f"Top {args.top}" if args.top > 0 else "All"
            print(f"{top_label} cheapest options:\n")

            headers = [
                "SKU",
                "Retail Price",
                "Unit of Measure",
                "Region",
                "Meter",
                "Product Name",
            ]
            display_data = all_series_data
            if args.top > 0:
                display_data = all_series_data[: args.top]
            print(tabulate(display_data, headers=headers, tablefmt="psql"))
        sys.exit(0)

    # Build list of VM sizes to query
    vm_sizes_list: List[tuple] = []  # List of (sku, series) tuples

    if args.vm_sizes:
        # Parse comma-separated VM sizes
        for vm_sz in args.vm_sizes.split(","):
            vm_sz = vm_sz.strip()
            if not vm_sz:
                continue
            # Check if this VM size is excluded
            normalized = vm_sz.replace("Standard_", "").lower()
            if normalized in excluded_vm_sizes:
                logging.debug(f"Skipping excluded VM size: {vm_sz}")
                continue
            extracted_series = extract_series_from_vm_size(vm_sz)
            vm_sizes_list.append((vm_sz, extracted_series))
        if not vm_sizes_list:
            logging.error(
                "No valid VM sizes provided in --vm-sizes (all may be excluded)"
            )
            sys.exit(1)
    else:
        # Use legacy sku-pattern and series-pattern
        sku_pattern: str = args.sku_pattern
        series_pattern: str = args.series_pattern
        if not series_pattern:
            series_pattern = sku_pattern

        # Early validation: warn if using default B-series pattern with cpu > 32
        if sku_pattern == DEFAULT_SEARCH_VMPATTERN and args.cpu > 32:
            logging.warning(
                f"B-series VMs max out at 32 vCPUs. Requested: {args.cpu} cores.\n"
                f"Consider using --no-burstable, --general-compute, or --sku-pattern D#as_v5"
            )

        sku: str = sku_pattern.replace("#", str(args.cpu))
        series: str = series_pattern.replace("#", "").replace("_", "")
        vm_sizes_list.append((sku, series))

    api_url = "https://prices.azure.com/api/retail/prices"

    if args.dry_run:
        print("DRY RUN - API Queries:")
        print(f"URL: {api_url}")
        for sku, series in vm_sizes_list:
            query = (
                f"armSkuName eq 'Standard_{sku}' and priceType eq 'Consumption' "
                f"and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'"
            )
            if not non_spot:
                query += SPOT_FILTER_CLAUSE
            if not (DEFAULT_SEARCH_VMWINDOWS and DEFAULT_SEARCH_VMLINUX):
                windows_suffix = " Windows" if DEFAULT_SEARCH_VMWINDOWS else ""
                if not DEFAULT_SEARCH_VMLINUX and not DEFAULT_SEARCH_VMWINDOWS:
                    logging.error(
                        "Both SEARCH_VMWINDOWS and SEARCH_VMLINUX cannot be set to False"
                    )
                    sys.exit(1)
                # Skip productName filter for ARM VMs - they have different naming in Azure API
                # ARM VMs will be filtered client-side for Windows exclusion
                if not is_arm_vm(sku) and not is_arm_vm(series):
                    query += f" and productName eq 'Virtual Machines {series} Series{windows_suffix}'"
                else:
                    logging.debug(
                        f"ARM VM detected ({sku}), skipping productName filter (client-side Windows filter)"
                    )
            print(f"SKU: {sku}, Series: {series}")
            print(f"Filter: {query}")
            print()
        return

    # Create session and fetch data
    session = create_resilient_session()
    max_pages = 50  # Safety limit per VM size

    # Estimate total pages for SKU queries
    estimated_pages = PAGE_ESTIMATOR.estimate_pages(
        "multi_sku", vm_count=len(vm_sizes_list)
    )
    PAGE_ESTIMATOR.start(estimated_pages)

    try:
        if not return_region:
            print(
                f"Fetching Azure VM pricing data for {len(vm_sizes_list)} VM size(s) "
                f"(~{estimated_pages} pages expected)..."
            )

        for idx, (sku, series) in enumerate(vm_sizes_list):
            if len(vm_sizes_list) > 1 and not return_region:
                eta = PAGE_ESTIMATOR.get_eta_str(idx, len(vm_sizes_list))
                print(
                    f"\n[{idx + 1}/{len(vm_sizes_list)}] Querying {sku} (ETA: {eta})..."
                )

            # Build query for this VM size
            query = (
                f"armSkuName eq 'Standard_{sku}' and priceType eq 'Consumption' "
                f"and serviceName eq 'Virtual Machines' and serviceFamily eq 'Compute'"
            )

            if not non_spot:
                query += SPOT_FILTER_CLAUSE

            # Add region filter if specified
            if args.region:
                regions = [r.strip() for r in args.region.split(",") if r.strip()]
                if len(regions) == 1:
                    query += f" and armRegionName eq '{regions[0]}'"
                elif len(regions) > 1:
                    region_filter = " or ".join(
                        [f"armRegionName eq '{r}'" for r in regions]
                    )
                    query += f" and ({region_filter})"

            if not (DEFAULT_SEARCH_VMWINDOWS and DEFAULT_SEARCH_VMLINUX):
                windows_suffix = ""
                if DEFAULT_SEARCH_VMWINDOWS:
                    windows_suffix = " Windows"
                else:
                    if not DEFAULT_SEARCH_VMLINUX:
                        logging.error(
                            "Both SEARCH_VMWINDOWS and SEARCH_VMLINUX cannot be set to False"
                        )
                        sys.exit(1)
                # Skip productName filter for ARM VMs - they have different naming in Azure API
                # ARM VMs will be filtered client-side for Windows exclusion
                if not is_arm_vm(sku) and not is_arm_vm(series):
                    query += f" and productName eq 'Virtual Machines {series} Series{windows_suffix}'"
                else:
                    logging.debug(
                        f"ARM VM detected ({sku}), skipping productName filter (client-side Windows filter)"
                    )

            logging.debug(f"Query: {query}")

            # Initial request
            page_start = time.time()
            json_data = fetch_pricing_data(
                api_url, {"$filter": query}, session, verbose=args.verbose
            )
            PAGE_ESTIMATOR.record_page(time.time() - page_start)
            build_pricing_table(json_data, table_data, non_spot, low_priority)

            next_page = json_data.get("NextPageLink", "")
            page_count = 1

            # Follow pagination
            while next_page and page_count < max_pages:
                if not return_region:
                    progress_msg = PAGE_ESTIMATOR.format_progress(
                        page_count + 1, max_pages
                    )
                    print(f"\r{progress_msg}        ", end="", flush=True)
                page_start = time.time()
                json_data = fetch_pricing_data(
                    next_page, {}, session, verbose=args.verbose
                )
                PAGE_ESTIMATOR.record_page(time.time() - page_start)
                next_page = json_data.get("NextPageLink", "")
                build_pricing_table(json_data, table_data, non_spot, low_priority)
                page_count += 1

            if page_count >= max_pages and next_page and not return_region:
                print(
                    f"\nWarning: Reached maximum page limit ({max_pages}) for {sku}. Results may be incomplete."
                )
            elif page_count > 1 and not return_region:
                print()  # New line after progress

    except Exception as e:
        logging.error(f"Failed to fetch pricing data: {e}")
        sys.exit(1)
    finally:
        session.close()

    if not table_data:
        error_msg = "No pricing data found for the specified criteria"
        # Provide helpful suggestions if using default B-series pattern with high core count
        if args.sku_pattern == DEFAULT_SEARCH_VMPATTERN and not args.vm_sizes:
            sku = args.sku_pattern.replace("#", str(args.cpu))
            error_msg += f"\n\nSearched for: {sku}"
            if args.cpu > 32:
                error_msg += f"\n\nNote: B-series VMs max out at 32 vCPUs. For {args.cpu} cores, try:"
                error_msg += (
                    "\n  --no-burstable           (search all non-burstable VMs)"
                )
                error_msg += "\n  --general-compute        (search D and F series)"
                error_msg += "\n  --sku-pattern D#as_v5    (specific series pattern)"
            else:
                error_msg += (
                    "\n\nTry using --no-burstable or --general-compute for more options"
                )
        logging.error(error_msg)
        sys.exit(1)

    # Sort by price (element [1] is retail price)
    table_data.sort(key=lambda x: float(x[1]))

    # Filter out excluded regions
    if excluded_regions:
        original_count = len(table_data)
        table_data = [
            row for row in table_data if row[3].lower() not in excluded_regions
        ]
        filtered_count = original_count - len(table_data)
        if filtered_count > 0:
            logging.debug(
                f"Filtered out {filtered_count} entries from excluded regions"
            )

    # Filter by CPU vendor
    has_vendor_filter = (
        getattr(args, "intel_only", False)
        or getattr(args, "amd_only", False)
        or getattr(args, "arm_only", False)
        or getattr(args, "exclude_intel", False)
        or getattr(args, "exclude_amd", False)
        or getattr(args, "exclude_arm", False)
    )
    if has_vendor_filter:
        original_count = len(table_data)
        table_data = [
            row for row in table_data if not should_skip_by_vendor(row[0], args)
        ]
        filtered_count = original_count - len(table_data)
        if filtered_count > 0:
            logging.debug(f"Filtered out {filtered_count} entries by CPU vendor")

    # Output results
    if return_region:
        if table_data:
            region: str = table_data[0][3]
            vm_size: str = table_data[0][0]  # SKU e.g., Standard_D4pls_v5
            price: float = table_data[0][1]
            unit: str = table_data[0][2]
            if args.return_region_json:
                # JSON format for PowerShell parsing
                result = {
                    "region": region,
                    "vmSize": vm_size,
                    "price": price,
                    "unit": unit,
                }
                print(json.dumps(result))
            else:
                # Output format: region vmsize price unit (space-separated)
                # Usage in PowerShell: $region, $vmSize, $price, $unit = (python vm-spot-price.py ...) -split ' ', 4
                print(f"{region} {vm_size} {price} {unit}")
        else:
            logging.error("No region found")
            sys.exit(1)
    else:
        print(f"Found {len(table_data)} pricing entries")
        content = format_output(table_data, args.output_format)

        if args.output_file:
            try:
                # Validate file path to prevent path traversal
                validated_path = validate_file_path(args.output_file, "output")
                # Use basename to sanitize and break taint chain
                safe_dir = os.path.dirname(os.path.realpath(validated_path))
                safe_name = os.path.basename(validated_path)
                safe_path = os.path.join(safe_dir, safe_name)
                with open(safe_path, "w", encoding="utf-8") as f:
                    f.write(content)
                print(f"Results saved to: {safe_path}")
            except ValueError as e:
                print(f"Invalid output path: {e}", file=sys.stderr)
                print("Results:")
                print(content)
            except IOError as e:
                print(f"Error writing to file: {e}", file=sys.stderr)
                print("Results:")
                print(content)
        else:
            print(content)


if __name__ == "__main__":
    main()
