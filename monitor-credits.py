#!/usr/bin/python3

# monitor-credits.py
# Copyright 2026 by Maxim Masiutin. All rights reserved.

# This script monitors Azure Burstable (B-series) VM CPU credits on the VM where
# it is running. When banked credits fall below a low threshold (default 10), it
# stops specified Linux services. When credits recover above a high threshold
# (default 90% of the VM size maximum), it starts those services again.

# Prerequisites - Managed Identity Setup:
#
# 1. Enable system-assigned managed identity on the VM:
#      az vm identity assign --resource-group <RG> --name <VM>
#
# 2. Get the managed identity principal ID:
#      az vm identity show --resource-group <RG> --name <VM> --query principalId -o tsv
#
# 3. Assign the "Monitoring Reader" role to the identity. On Windows with Git
#    Bash, prefix with MSYS_NO_PATHCONV=1 to prevent path mangling:
#      MSYS_NO_PATHCONV=1 az role assignment create \
#        --assignee <PRINCIPAL_ID> \
#        --role "Monitoring Reader" \
#        --scope "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Compute/virtualMachines/<VM>"
#
# 4. Verify from within the VM:
#      curl -s -H "Metadata: true" \
#        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
#        | python -m json.tool
#    You should see an "access_token" field in the response.
#
# Alternative - Service Principal (if managed identity is not available):
#   Set these environment variables before running the script:
#     export AZURE_CLIENT_ID=<app-id>
#     export AZURE_CLIENT_SECRET=<secret>
#     export AZURE_TENANT_ID=<tenant-id>
#   The service principal needs "Monitoring Reader" role on the VM resource.

# Usage:
# 1. Make the script executable: chmod +x monitor-credits.py
# 2. Run the script:
#    ./monitor-credits.py --stop-services <service1,service2> [options]
# 3. The script will run indefinitely, checking credits at the configured interval.

# Options:
#   --stop-services    Comma-separated list of services to manage
#   --hook             Path to executable to run on credit state changes
#   --low-threshold    Credit level below which services are stopped (default: 10)
#   --high-percent     Percentage of max credits above which services restart (default: 90)
#   --max-credits      Override auto-detected max credits for the VM size
#   --interval         Seconds between checks (default: 60)
#   --skip-azure-check Skip the Azure environment check
#   --dry-run          Show what would be done without executing

import os
import re
from argparse import ArgumentParser
from datetime import datetime, timezone, timedelta
from os import path, access, X_OK
from platform import uname, node
from subprocess import run
from sys import stderr, exit
from time import sleep

from requests import get, post, exceptions

# IMDS endpoints
imdsBase = "http://169.254.169.254"
imdsComputeUrl = imdsBase + "/metadata/instance/compute"
imdsTokenUrl = imdsBase + "/metadata/identity/oauth2/token"
imdsHeaders = {"Metadata": "true"}
imdsApiVersion = "2020-09-01"

# Azure Monitor endpoint template
monitorUrlTemplate = (
    "https://management.azure.com"
    "/subscriptions/{subscription_id}"
    "/resourceGroups/{resource_group}"
    "/providers/Microsoft.Compute/virtualMachines/{vm_name}"
    "/providers/microsoft.insights/metrics"
)
monitorApiVersion = "2018-01-01"

# Maximum banked credits by VM size (case-insensitive lookup)
# Values from Azure documentation for B-series VMs
maxCreditsBySize = {
    # Bv1 series
    "standard_b1ls": 72,
    "standard_b1s": 144,
    "standard_b1ms": 288,
    "standard_b2s": 576,
    "standard_b2ms": 864,
    "standard_b4ms": 1296,
    "standard_b8ms": 1944,
    "standard_b12ms": 2908,
    "standard_b16ms": 3888,
    "standard_b20ms": 4867,
    # Bsv2 series (Intel)
    "standard_b2ts_v2": 576,
    "standard_b2ls_v2": 864,
    "standard_b2s_v2": 1152,
    "standard_b4ls_v2": 1728,
    "standard_b4s_v2": 2304,
    "standard_b8ls_v2": 3456,
    "standard_b8s_v2": 4608,
    "standard_b16ls_v2": 6912,
    "standard_b16s_v2": 9216,
    "standard_b32ls_v2": 13824,
    "standard_b32s_v2": 18432,
    # Basv2 series (AMD)
    "standard_b2ats_v2": 576,
    "standard_b2als_v2": 864,
    "standard_b2as_v2": 1152,
    "standard_b4als_v2": 1728,
    "standard_b4as_v2": 2304,
    "standard_b8als_v2": 3456,
    "standard_b8as_v2": 4608,
    "standard_b16als_v2": 6912,
    "standard_b16as_v2": 9216,
    "standard_b32als_v2": 13824,
    "standard_b32as_v2": 18432,
    # Bpsv2 series (ARM)
    "standard_b2pts_v2": 576,
    "standard_b2pls_v2": 864,
    "standard_b2ps_v2": 1152,
    "standard_b4pls_v2": 1728,
    "standard_b4ps_v2": 2304,
    "standard_b8pls_v2": 3456,
    "standard_b8ps_v2": 4608,
    "standard_b16pls_v2": 6912,
    "standard_b16ps_v2": 9216,
}


def get_vm_metadata():
    """Get VM compute metadata from IMDS (subscription, resource group, name, size)."""
    try:
        resp = get(
            imdsComputeUrl,
            headers=imdsHeaders,
            params={"api-version": imdsApiVersion},
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
        return {
            "subscription_id": data["subscriptionId"],
            "resource_group": data["resourceGroupName"],
            "vm_name": data["name"],
            "vm_size": data["vmSize"],
        }
    except exceptions.RequestException as e:
        print(f"Failed to get VM metadata from IMDS: {e}", file=stderr)
        return None


def get_access_token_managed_identity():
    """Get Azure access token using VM managed identity via IMDS."""
    try:
        resp = get(
            imdsTokenUrl,
            headers=imdsHeaders,
            params={
                "api-version": "2018-02-01",
                "resource": "https://management.azure.com/",
            },
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()["access_token"]
    except exceptions.RequestException as e:
        print(f"Failed to get managed identity token from IMDS: {e}", file=stderr)
        return None


def get_access_token_service_principal():
    """Get Azure access token using service principal credentials from env vars."""
    client_id = os.environ.get("AZURE_CLIENT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")
    tenant_id = os.environ.get("AZURE_TENANT_ID")

    if not all([client_id, client_secret, tenant_id]):
        return None

    token_url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    try:
        resp = post(
            token_url,
            data={
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
                "scope": "https://management.azure.com/.default",
            },
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()["access_token"]
    except exceptions.RequestException as e:
        print(f"Failed to get service principal token: {e}", file=stderr)
        return None


def get_access_token():
    """Get access token, trying managed identity first, then service principal."""
    token = get_access_token_managed_identity()
    if token:
        return token
    print("Managed identity token failed, trying service principal...", file=stderr)
    token = get_access_token_service_principal()
    if token:
        return token
    print(
        "No authentication method succeeded. Ensure the VM has a managed identity "
        "with Monitoring Reader role, or set AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, "
        "and AZURE_TENANT_ID environment variables.",
        file=stderr,
    )
    return None


def get_cpu_credits(vm_meta, access_token):
    """Query Azure Monitor for CPU Credits Remaining metric."""
    url = monitorUrlTemplate.format(
        subscription_id=vm_meta["subscription_id"],
        resource_group=vm_meta["resource_group"],
        vm_name=vm_meta["vm_name"],
    )

    now = datetime.now(timezone.utc)
    start = now - timedelta(minutes=5)
    timespan = start.strftime("%Y-%m-%dT%H:%M:%SZ") + "/" + now.strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )

    try:
        resp = get(
            url,
            headers={"Authorization": f"Bearer {access_token}"},
            params={
                "api-version": monitorApiVersion,
                "metricnames": "CPU Credits Remaining",
                "timespan": timespan,
                "interval": "PT1M",
            },
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()

        for metric in data.get("value", []):
            timeseries = metric.get("timeseries", [])
            if not timeseries:
                continue
            points = timeseries[0].get("data", [])
            # Walk backwards to find the most recent non-null value
            for point in reversed(points):
                val = point.get("average")
                if val is not None:
                    return val
        return None
    except exceptions.RequestException as e:
        print(f"Failed to query CPU credits: {e}", file=stderr)
        return None


def get_max_credits(vm_size, override=None):
    """Get max banked credits for the VM size. Returns override if provided."""
    if override is not None:
        return override
    key = vm_size.lower()
    if key in maxCreditsBySize:
        return maxCreditsBySize[key]
    print(
        f"Warning: VM size '{vm_size}' not in credit table. "
        f"Use --max-credits to specify manually.",
        file=stderr,
    )
    return None


def validate_hook_path(hook_path):
    """
    Validate hook script path for security.
    Raises ValueError if invalid. Returns the validated real path if valid.
    """
    if not hook_path:
        return None

    if ".." in hook_path:
        raise ValueError("Hook path cannot contain '..' (directory traversal)")

    dangerous_chars = [";", "&", "|", "$", "`", "(", ")", "{", "}", "<", ">", "\n", "\r"]
    for char in dangerous_chars:
        if char in hook_path:
            raise ValueError(f"Hook path contains forbidden character: {repr(char)}")

    real_path = os.path.realpath(hook_path)

    if not (path.exists(real_path) and access(real_path, X_OK)):
        raise ValueError(f"Hook script not executable or doesn't exist: {hook_path}")

    if not path.isfile(real_path):
        raise ValueError(f"Hook path is not a regular file: {real_path}")

    allowed_dirs = ["/opt/", "/usr/local/bin/", "/home/"]
    if not any(real_path.startswith(safe_dir) for safe_dir in allowed_dirs):
        raise ValueError(
            f"Hook script must be in allowed directories {allowed_dirs}: {real_path}"
        )

    return real_path


def is_valid_service_name(service_name):
    """Validate service name with stricter rules."""
    if not service_name or len(service_name) > 64:
        return False
    return re.match(r"^[a-zA-Z0-9_\-\.]+$", service_name) is not None


def stop_services(services, hook):
    """Execute hook and stop services."""
    if hook:
        try:
            validated_path = validate_hook_path(hook)
            if validated_path is None:
                print("Hook path validation returned None")
                return
            print("Executing hook (credits low):", validated_path)
            rc = run([validated_path, "low"], shell=False, check=False, timeout=300).returncode
            if rc != 0:
                print("Hook execution failed with return code", rc)
        except ValueError as e:
            print(f"Hook validation failed: {e}")
        except Exception as e:
            print(f"Hook execution error: {e}")

    for service in services:
        print("Stopping the service", service, "...")
        try:
            rc = run(["systemctl", "stop", service], check=False, timeout=60).returncode
            if rc == 0:
                print("Stopped service", service)
            else:
                rc = run(
                    ["/usr/sbin/service", service, "stop"], check=False, timeout=60
                ).returncode
                if rc == 0:
                    print("Stopped service", service, "with service command")
                else:
                    print("Error stopping service", service, "Return code", rc)
        except Exception as e:
            print(f"Error stopping service {service}: {e}")


def start_services(services, hook):
    """Execute hook and start services."""
    if hook:
        try:
            validated_path = validate_hook_path(hook)
            if validated_path is None:
                print("Hook path validation returned None")
                return
            print("Executing hook (credits recovered):", validated_path)
            rc = run([validated_path, "high"], shell=False, check=False, timeout=300).returncode
            if rc != 0:
                print("Hook execution failed with return code", rc)
        except ValueError as e:
            print(f"Hook validation failed: {e}")
        except Exception as e:
            print(f"Hook execution error: {e}")

    for service in services:
        print("Starting the service", service, "...")
        try:
            rc = run(["systemctl", "start", service], check=False, timeout=60).returncode
            if rc == 0:
                print("Started service", service)
            else:
                rc = run(
                    ["/usr/sbin/service", service, "start"], check=False, timeout=60
                ).returncode
                if rc == 0:
                    print("Started service", service, "with service command")
                else:
                    print("Error starting service", service, "Return code", rc)
        except Exception as e:
            print(f"Error starting service {service}: {e}")


def parse_args():
    parser = ArgumentParser(
        description="Monitor Azure B-series VM CPU credits and manage services."
    )
    parser.add_argument(
        "--stop-services",
        type=str,
        required=True,
        help="Comma-separated list of services to stop/start based on credit level.",
    )
    parser.add_argument(
        "--hook",
        type=str,
        help="Path to executable to run on credit state changes. "
        "Called with argument 'low' or 'high'.",
    )
    parser.add_argument(
        "--low-threshold",
        type=float,
        default=10.0,
        help="Stop services when credits fall below this value (default: 10).",
    )
    parser.add_argument(
        "--high-percent",
        type=float,
        default=90.0,
        help="Start services when credits rise above this percent of max (default: 90).",
    )
    parser.add_argument(
        "--max-credits",
        type=float,
        default=None,
        help="Override auto-detected max credits for the VM size.",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=60,
        help="Seconds between credit checks (default: 60).",
    )
    parser.add_argument(
        "--skip-azure-check",
        action="store_true",
        help="Skip the check for Azure environment.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without executing.",
    )
    args = parser.parse_args()

    ret_services = [s.strip() for s in args.stop_services.split(",")]
    ret_hook = args.hook if args.hook else None

    for service in ret_services:
        if not is_valid_service_name(service):
            parser.error(f"Invalid service name: {service}")

    if ret_hook:
        try:
            validate_hook_path(ret_hook)
        except ValueError as e:
            parser.error(f"Hook validation failed: {e}")

    if args.low_threshold < 0:
        parser.error("--low-threshold must be non-negative")

    if not (0 < args.high_percent <= 100):
        parser.error("--high-percent must be between 0 and 100")

    if args.max_credits is not None and args.max_credits <= 0:
        parser.error("--max-credits must be positive")

    if args.interval < 10:
        parser.error("--interval must be at least 10 seconds")

    return args, ret_services, ret_hook


if __name__ == "__main__":
    args, services, hook = parse_args()

    if not args.skip_azure_check:
        s = uname().release
        if "azure" not in s.lower():
            print(
                f'The release "{s}" does not indicate Azure! '
                f"(use --skip-azure-check to avoid this check)",
                file=stderr,
            )
            exit(1)

    myComputer = node()

    if args.dry_run:
        print("DRY RUN MODE - No actual actions will be performed")
        print(f"Would monitor computer: {myComputer}")
        print(f"Services: {', '.join(services)}")
        print(f"Low threshold: {args.low_threshold} credits")
        print(f"High threshold: {args.high_percent}% of max credits")
        if args.max_credits:
            print(f"Max credits override: {args.max_credits}")
        if hook:
            print(f"Hook: {hook}")
        print(f"Check interval: {args.interval}s")
        exit(0)

    # Get VM metadata
    vm_meta = get_vm_metadata()
    if vm_meta is None:
        print("Cannot retrieve VM metadata. Is this an Azure VM?", file=stderr)
        exit(1)

    vm_size = vm_meta["vm_size"]
    max_credits = get_max_credits(vm_size, args.max_credits)
    if max_credits is None:
        print(
            f"Cannot determine max credits for VM size '{vm_size}'. "
            f"Use --max-credits to specify.",
            file=stderr,
        )
        exit(1)

    high_threshold = max_credits * (args.high_percent / 100.0)

    print(f"Monitoring CPU credits for: {myComputer}")
    print(f"VM size: {vm_size}")
    print(f"Max banked credits: {max_credits}")
    print(f"Low threshold: {args.low_threshold} credits (stop services)")
    print(f"High threshold: {high_threshold:.0f} credits ({args.high_percent}% of max, start services)")
    print(f"Services: {', '.join(services)}")
    print(f"Check interval: {args.interval}s")

    # State: True = services running, False = services stopped
    services_running = True
    error_count = 0
    max_errors = 10
    access_token = None
    token_acquired_at = None
    token_lifetime = 3000  # Refresh token every ~50 minutes (tokens last ~60 min)

    while True:
        # Refresh access token if needed
        now_ts = datetime.now(timezone.utc).timestamp()
        if access_token is None or (now_ts - token_acquired_at) > token_lifetime:
            access_token = get_access_token()
            if access_token is None:
                error_count += 1
                if error_count >= max_errors:
                    print(
                        f"Too many consecutive auth errors ({error_count}), exiting",
                        file=stderr,
                    )
                    exit(1)
                sleep(args.interval)
                continue
            token_acquired_at = now_ts

        credits = get_cpu_credits(vm_meta, access_token)
        if credits is None:
            error_count += 1
            if error_count >= max_errors:
                print(
                    f"Too many consecutive errors ({error_count}), exiting",
                    file=stderr,
                )
                exit(1)
            # Token may have expired or been revoked; force refresh
            access_token = None
            sleep(args.interval)
            continue

        error_count = 0

        now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        print(f"[{now_str}] CPU Credits Remaining: {credits:.1f}")

        if services_running and credits < args.low_threshold:
            print(
                f"Credits ({credits:.1f}) below low threshold ({args.low_threshold}). "
                f"Stopping services."
            )
            stop_services(services, hook)
            services_running = False
        elif not services_running and credits > high_threshold:
            print(
                f"Credits ({credits:.1f}) above high threshold ({high_threshold:.0f}). "
                f"Starting services."
            )
            start_services(services, hook)
            services_running = True

        sleep(args.interval)
