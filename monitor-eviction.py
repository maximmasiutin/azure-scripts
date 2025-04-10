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

from argparse import ArgumentParser
from os import path
from platform import uname, node
from sys import stderr
from subprocess import run
from time import sleep
from requests import get
import re

metadataUrl = "http://169.254.169.254/metadata/scheduledevents"
endpointTimeout = 5
headerValur = {"Metadata": "true"}
queryParams = {"api-version": "2020-07-01"}
stopStatuses = ["Scheduled", "Started"]
stopTypes = ["Reboot", "Redeploy", "Freeze", "Preempt", "Terminate"]

def get_scheduled_events():
    resp = get(metadataUrl, headers=headerValur, params=queryParams, timeout=endpointTimeout)
    data = resp.json()
    return data

def eviction_action(a_services, a_hook):
    if a_hook:
        if path.isfile(a_hook) and path.exists(a_hook):
            print("Executing hook:", a_hook)
            rc = run(a_hook, shell=True, check=False).returncode
            if rc != 0:
                print("Hook execution failed with return code", rc)
        else:
            print("Hook file does not exist or is not executable:", a_hook)

    for service in a_services:
        print("Stopping the service", service, "...")
        rc = run(["/usr/sbin/service", service, "stop"], check=False).returncode
        if rc == 0:
            print("Stopped service", service)
        else:
            print("Error stopping service", service, "Return code", rc)


def is_valid_service_name(service_name):
    return re.match(r'^(?!.*\.\.)[a-zA-Z0-9_\-\.@]+$', service_name) is not None

def parse_args():
    parser = ArgumentParser(description="Monitor Azure spot VM eviction events.")
    parser.add_argument("--stop-services", type=str, help="Comma-separated list of services to stop on eviction event.")
    parser.add_argument("--hook", type=str, help="Path to executable file to run on eviction event.")
    parser.add_argument("--skip-azure-check", action="store_true", help="Skip the check for Azure environment.")
    args = parser.parse_args()

    if not args.stop_services and not args.hook:
        parser.error("At least one of --stop-services or --hook must be provided.")

    ret_skip_azure_check = args.skip_azure_check
    ret_services = args.stop_services.split(",") if args.stop_services else []
    ret_hook = args.hook if args.hook else None

    for service in ret_services:
        if not is_valid_service_name(service):
            parser.error(f"Invalid service name: {service}")

    return ret_services, ret_hook, ret_skip_azure_check

if __name__ == "__main__":
    services, hook, skip_azure_check = parse_args()
    
    if not skip_azure_check:
        s = uname().release  
        if not "azure" in s:
            print(f"The release \"{s}\" does not indicate Azure! (use --skip-azure-check to avoid this check)", file=stderr)
            exit(1)

    myComputer = node()

    continueLoop = True
    while continueLoop:
        payload = get_scheduled_events()
        if "Events" in payload.keys():
            print("Received payload", payload)
            for event in payload["Events"]:
                eventStatus = event.get("EventStatus")
                eventType = event.get("EventType")
                resourceType = event.get("ResourceType")
                resources = event.get("Resources", [])
                if (
                    (eventStatus in stopStatuses)
                    and (eventType in stopTypes)
                    and (resourceType == "VirtualMachine")
                    and (myComputer in resources)
                ):
                    print("Handling signal", eventType)
                    eviction_action(services, hook)
                    continueLoop = False
                    break
        if not continueLoop:
            break
        sleep(1)
