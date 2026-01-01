#!/usr/bin/python3

# monitor-eviction.py
# Copyright 2023 by Maxim Masiutin. All rights reserved.

# This script monitors an Azure spot VM on which it is running to determine whether
# the VM is being evicted. Upon detecting an eviction event, it optionally executes
# a specified hook script and stops specified Linux services gracefully before the
# VM instance is stopped.

# The script uses the Azure Instance Metadata Service to check for scheduled events
# and determines if the VM is being evicted. It can be run as a systemd service or in
# a container.

# Usage:
# 1. Make the script executable: chmod +x monitor-eviction.py
# 2. Run the script: ./monitor-eviction.py --stop-services <service1,service2> --hook <path_to_hook> [--skip-azure-check]
# 3. The script will run indefinitely, checking for eviction events every second.

# The hook is executed before stopping the services.

import os
import re
from argparse import ArgumentParser
from os import path, access, X_OK
from platform import uname, node
from subprocess import run
from sys import stderr, exit
from time import sleep

from requests import get, exceptions

metadataUrl = "http://169.254.169.254/metadata/scheduledevents"
endpointTimeout = 10
headerValue = {"Metadata": "true"}
queryParams = {"api-version": "2020-07-01"}
stopStatuses = ["Scheduled", "Started"]
stopTypes = ["Reboot", "Redeploy", "Freeze", "Preempt", "Terminate"]


def get_scheduled_events(max_retries=3, backoff_factor=2):
    """Get scheduled events with retry logic and better error handling."""
    for attempt in range(max_retries):
        try:
            resp = get(
                metadataUrl,
                headers=headerValue,
                params=queryParams,
                timeout=endpointTimeout,
            )
            resp.raise_for_status()
            return resp.json()
        except exceptions.RequestException as e:
            if attempt == max_retries - 1:
                print(
                    f"Failed to get scheduled events after {max_retries} attempts: {e}",
                    file=stderr,
                )
                return {}
            wait_time = backoff_factor**attempt
            print(
                f"Metadata service error (attempt {attempt + 1}), retrying in {wait_time}s: {e}"
            )
            sleep(wait_time)
    return {}


def validate_hook_path(hook_path):
    """
    Validate hook script path for security.
    Raises ValueError if invalid. Returns None if valid.
    """
    if not hook_path:
        return

    # Check if file exists and is executable
    if not (path.exists(hook_path) and access(hook_path, X_OK)):
        raise ValueError(f"Hook script not executable or doesn't exist: {hook_path}")

    # Get real path to prevent symlink attacks
    real_path = os.path.realpath(hook_path)

    # Allow hooks in safe directories
    allowed_dirs = ["/opt/", "/usr/local/bin/", "/home/"]
    if not any(real_path.startswith(safe_dir) for safe_dir in allowed_dirs):
        raise ValueError(
            f"Hook script must be in allowed directories {allowed_dirs}: {real_path}"
        )

    # Prevent directory traversal
    if ".." in hook_path:
        raise ValueError("Hook path cannot contain '..' (directory traversal)")


def eviction_action(a_services, a_hook):
    """Execute hook and stop services on eviction with improved security."""
    if a_hook:
        try:
            validate_hook_path(a_hook)
            print("Executing hook:", a_hook)
            # Use array form to prevent shell injection
            rc = run([a_hook], check=False, timeout=300).returncode
            if rc != 0:
                print("Hook execution failed with return code", rc)
        except ValueError as e:
            print(f"Hook validation failed: {e}")
        except Exception as e:
            print(f"Hook execution error: {e}")

    for service in a_services:
        print("Stopping the service", service, "...")
        try:
            # Try systemctl first (modern systems)
            rc = run(["systemctl", "stop", service], check=False, timeout=60).returncode
            if rc == 0:
                print("Stopped service", service, "with systemctl")
            else:
                # Fallback to service command
                rc = run(
                    ["/usr/sbin/service", service, "stop"], check=False, timeout=60
                ).returncode
                if rc == 0:
                    print("Stopped service", service, "with service command")
                else:
                    print("Error stopping service", service, "Return code", rc)
        except Exception as e:
            print(f"Error stopping service {service}: {e}")


def is_valid_service_name(service_name):
    """Validate service name with stricter rules."""
    if not service_name or len(service_name) > 64:
        return False
    # Only allow alphanumeric, hyphens, underscores, and dots
    return re.match(r"^[a-zA-Z0-9_\-\.]+$", service_name) is not None


def parse_args():
    parser = ArgumentParser(description="Monitor Azure spot VM eviction events.")
    parser.add_argument(
        "--stop-services",
        type=str,
        help="Comma-separated list of services to stop on eviction event.",
    )
    parser.add_argument(
        "--hook", type=str, help="Path to executable file to run on eviction event."
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

    if not args.stop_services and not args.hook:
        parser.error("At least one of --stop-services or --hook must be provided.")

    ret_skip_azure_check = args.skip_azure_check
    ret_services = args.stop_services.split(",") if args.stop_services else []
    ret_hook = args.hook if args.hook else None
    ret_dry_run = args.dry_run

    # Validate service names
    for service in ret_services:
        service = service.strip()
        if not is_valid_service_name(service):
            parser.error(f"Invalid service name: {service}")

    # Validate hook if provided
    if ret_hook:
        try:
            validate_hook_path(ret_hook)
        except ValueError as e:
            parser.error(f"Hook validation failed: {e}")

    return ret_services, ret_hook, ret_skip_azure_check, ret_dry_run


if __name__ == "__main__":
    services, hook, skip_azure_check, dry_run = parse_args()

    if not skip_azure_check:
        s = uname().release
        if "azure" not in s.lower():
            print(
                f'The release "{s}" does not indicate Azure! (use --skip-azure-check to avoid this check)',
                file=stderr,
            )
            exit(1)

    myComputer = node()

    if dry_run:
        print("DRY RUN MODE - No actual actions will be performed")
        print(f"Would monitor computer: {myComputer}")
        if services:
            print(f"Would stop services: {', '.join(services)}")
        if hook:
            print(f"Would execute hook: {hook}")
        exit(0)

    print(f"Monitoring eviction events for computer: {myComputer}")
    if services:
        print(f"Will stop services: {', '.join(services)}")
    if hook:
        print(f"Will execute hook: {hook}")

    continueLoop = True
    error_count = 0
    max_errors = 10

    while continueLoop:
        payload = get_scheduled_events()

        if not payload:
            error_count += 1
            if error_count >= max_errors:
                print(
                    f"Too many consecutive errors ({error_count}), exiting", file=stderr
                )
                exit(1)
            sleep(5)  # Wait longer on errors
            continue

        error_count = 0  # Reset error count on successful response

        if "Events" in payload:
            print("Received payload", payload)
            for event in payload["Events"]:
                eventStatus = event.get("EventStatus")
                eventType = event.get("EventType")
                resourceType = event.get("ResourceType")
                resources = event.get("Resources", [])

                if (
                    eventStatus in stopStatuses
                    and eventType in stopTypes
                    and resourceType == "VirtualMachine"
                    and myComputer in resources
                ):
                    print(f"Handling eviction signal: {eventType}")
                    eviction_action(services, hook)
                    continueLoop = False
                    break

        if continueLoop:
            sleep(1)

    print("Eviction monitoring completed")
