#!/usr/bin/python3

# monitor-eviction.py
# Copyright 2023 by Maxim Masiutin. All rights reserved.

import json
from os import system, uname
from platform import node
from time import sleep

from requests import get

serviceToStop = "fishtest"
metadataUrl = "http://169.254.169.254/metadata/scheduledevents"
headerValur = {"Metadata": "true"}
queryParams = {"api-version": "2020-07-01"}
stopStatuses = ["Scheduled", "Started"]
stopTypes = ["Reboot", "Redeploy", "Freeze", "Preempt", "Terminate"]


def get_scheduled_events():
    resp = get(metadataUrl, headers=headerValur, params=queryParams)
    data = resp.json()
    return data


def stop_service():
    print("Stopping the service", serviceToStop, "...")
    rc = system("/usr/sbin/service " + serviceToStop + " stop")
    if rc == 0:
        print("Stopped.")
    else:
        print("Error! Return code", rc)


continueLoop = True

s = uname().release
if "azure" in s:
    myComputer = node()
    while continueLoop:
        payload = get_scheduled_events()
        if "Events" in payload.keys():
            print("Received payload", payload)
            for event in payload["Events"]:
                eventStatus = None
                if "EventStatus" in event.keys():
                    eventStatus = event["EventStatus"]
                eventType = None
                if "EventType" in event.keys():
                    eventType = event["EventType"]
                resourceType = None
                if "ResourceType" in event.keys():
                    resourceType = event["ResourceType"]
                resources = None
                if "Resources" in event.keys():
                    resources = event["Resources"]
                if (
                    (eventStatus in stopStatuses)
                    & (eventType in stopTypes)
                    & (resourceType == "VirtualMachine")
                    & (myComputer in resources)
                ):
                    print("Handling signal", eventType)
                    stop_service()
                    continueLoop = False
                    break
        if not continueLoop:
            break
        sleep(1)
else:
    print(s, "is not Azure!")
