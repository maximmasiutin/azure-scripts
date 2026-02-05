#!/usr/bin/python
"""
monitor-stddev: A website monitoring script that evaluates site stability and health.

It goes beyond simple up/down checks by calculating the standard deviation of latency
to detect inconsistent performance (jitter) and stability issues.

Copyright (C) 2025 Maxim Masiutin. All rights reserved.

See monitor-stddev.md for details.

You can install the requirements using `python -m pip install curl_cffi azure-storage-blob azure-data-tables Pillow`
"""

from time import time, sleep
from statistics import mean, stdev
from argparse import ArgumentParser, Namespace
from json import load, dump, dumps, JSONDecodeError
from os import path
from io import BytesIO
from sys import stderr
from collections import Counter
from datetime import datetime, timezone, timedelta, date
from typing import List, Optional, Union, Dict, Any
from types import FrameType
from abc import ABC, abstractmethod
import signal
import sys
import csv

from PIL import Image, ImageDraw, ImageFont
from curl_cffi import requests as cffi_requests  # type: ignore
from curl_cffi.requests import Session, Response  # type: ignore
from azure.storage.blob import (
    BlobServiceClient,
    BlobClient,
    ContentSettings,
)
from azure.data.tables import TableClient


def validate_file_path(file_path: str, operation: str = "access") -> str:
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
    real_path = path.realpath(file_path)

    # After resolving, verify no traversal occurred by checking original didn't escape
    # Get the absolute path of the original (without following symlinks initially)
    abs_original = path.abspath(file_path)

    # Verify the resolved path is within the current working directory or an absolute path
    # that was explicitly provided (starts with / or drive letter on Windows)
    cwd = path.realpath(".")
    is_absolute_input = path.isabs(file_path)

    # If relative path, must resolve within current directory tree
    if not is_absolute_input:
        if not real_path.startswith(cwd):
            raise ValueError(
                f"Path traversal detected in {operation}: resolved path escapes working directory"
            )

    return real_path


def sanitize_filename(filename: str) -> str:
    """
    Sanitize a filename by extracting only the basename.
    This breaks any path traversal attempts by removing directory components.
    """
    # Use basename to extract only the filename without directory path
    safe_name = path.basename(filename)
    # Additional check: ensure no path separators remain
    if "/" in safe_name or "\\" in safe_name:
        raise ValueError("Invalid filename after sanitization")
    if not safe_name:
        raise ValueError("Empty filename after sanitization")
    return safe_name


# Constants - made configurable
RESULTS_COUNT_MINUTES: int = 60 * 24 * 3
SAMPLE_SIZE_SECONDS: int = 240
UPDATE_INTERVAL_SECONDS: int = 60
STATUS_UNHEALTHY: int = 0
STATUS_HEALTHY: int = 1
MAX_HISTORY_SIZE: int = (
    SAMPLE_SIZE_SECONDS * 3
)  # Keep some buffer to prevent memory leaks


def cleanup_old_data(data_list: List[Any], max_size: int) -> None:
    """Clean up old data to prevent memory leaks."""
    if len(data_list) > max_size:
        del data_list[: len(data_list) - max_size]


def export_data(
    data: List[Dict[str, Union[str, int]]],
    filename: str,
    format_type: str,
    debug_output: bool,
) -> None:
    """Export data to a file in the specified format."""
    if not data:
        print("Warning: No historical data found to export.", file=stderr)

    # Validate file path to prevent path traversal
    try:
        validated_path = validate_file_path(filename, "export")
    except ValueError as e:
        print(f"Invalid export path: {e}", file=stderr)
        return

    if debug_output:
        print(f"Exporting {len(data)} records to {validated_path} in {format_type} format...")

    try:
        if format_type == "json":
            # Use basename to sanitize and break taint chain, then join with directory
            safe_dir = path.dirname(path.realpath(validated_path))
            safe_name = path.basename(validated_path)
            safe_path = path.join(safe_dir, safe_name)
            with open(safe_path, "w", encoding="utf-8") as f:
                dump(data, f, indent=4)
        elif format_type == "csv":
            if not data:
                # Create an empty file with standard headers
                # Use QUOTE_ALL to prevent CSV formula injection
                with open(validated_path, "w", encoding="utf-8", newline="") as f:
                    csv_writer = csv.writer(f, quoting=csv.QUOTE_ALL)
                    csv_writer.writerow(["timestamp", "healthy"])
            else:
                # Collect all unique keys to handle potentially inconsistent records
                all_keys: set[str] = set()
                for d in data:
                    all_keys.update(d.keys())
                fieldnames: List[str] = sorted(list(all_keys))

                # Use QUOTE_ALL to prevent CSV formula injection
                with open(validated_path, "w", encoding="utf-8", newline="") as f:
                    dict_writer = csv.DictWriter(
                        f, fieldnames=fieldnames, quoting=csv.QUOTE_ALL
                    )
                    dict_writer.writeheader()
                    dict_writer.writerows(data)

        print(f"Successfully exported data to {validated_path}")

    except (IOError, OSError) as e:
        print(f"Error writing to file {validated_path}: {e}", file=stderr)
    except Exception as e:
        print(f"An unexpected error occurred during export: {e}", file=stderr)


class DataStorage(ABC):
    def __init__(self) -> None:
        self.historical_data: List[Dict[str, Union[str, int]]] = []

    @abstractmethod
    def load_historical_data(
        self, debug_output: bool
    ) -> List[Dict[str, Union[str, int]]]:
        pass

    @abstractmethod
    def append_metric(
        self, record: Dict[str, Union[str, int]], debug_output: bool
    ) -> None:
        pass

    @abstractmethod
    def print_raw_entities(self) -> None:
        pass


class JsonFileStorage(DataStorage):
    def __init__(self, filename: str, debug_output: bool) -> None:
        super().__init__()
        # Validate file path to prevent path traversal
        try:
            self.filename = validate_file_path(filename, "storage")
        except ValueError as e:
            print(f"Invalid storage path: {e}", file=stderr)
            raise
        self.historical_data = self.load_historical_data(debug_output=debug_output)

    def load_historical_data(
        self, debug_output: bool
    ) -> List[Dict[str, Union[str, int]]]:
        # self.filename is already validated in __init__
        # Use basename to sanitize and break taint chain
        safe_dir = path.dirname(path.realpath(self.filename))
        safe_name = path.basename(self.filename)
        safe_filename = path.join(safe_dir, safe_name)
        if path.isfile(safe_filename):
            try:
                with open(safe_filename, "r", encoding="utf-8") as file:
                    data = load(file)
                    if not isinstance(data, list):
                        print(
                            f"Warning: Expected list in {self.filename}, got {type(data)}",
                            file=stderr,
                        )
                        return []
                    return data
            except JSONDecodeError as json_err:
                print(f"JSON decode error in {self.filename}: {json_err}", file=stderr)
            except (OSError, IOError) as file_err:
                print(
                    f"File error while reading {self.filename}: {file_err}", file=stderr
                )
            except Exception as e:
                print(
                    f"Unexpected error while loading historical data: {e}", file=stderr
                )
            return []
        else:
            if debug_output:
                print(
                    f"No existing historical data file found at {self.filename}. Starting fresh."
                )
            return []

    def append_metric(
        self, record: Dict[str, Union[str, int]], debug_output: bool
    ) -> None:
        self.historical_data.append(record)
        try:
            with open(self.filename, "w", encoding="utf-8") as file:
                dump(self.historical_data, file, indent=4)
            if debug_output:
                print(f"Successfully appended metric to {self.filename}")
        except (OSError, IOError) as file_err:
            print(
                f"File error while writing to {self.filename}: {file_err}", file=stderr
            )
        except TypeError as type_err:
            print(f"Type error during JSON serialization: {type_err}", file=stderr)
        except Exception as e:
            print(f"Unexpected error while appending metric: {e}", file=stderr)

    def print_raw_entities(self) -> None:
        raise NotImplementedError(
            "This method is not applicable for JSON file storage."
        )


class CosmosDBTableStorage(DataStorage):
    def __init__(
        self, connection_string: str, table_name: str, debug_output: bool
    ) -> None:
        super().__init__()
        try:
            self.table_client = TableClient.from_connection_string(
                conn_str=connection_string, table_name=table_name
            )
            self.historical_data = self.load_historical_data(debug_output=debug_output)
        except Exception as e:
            print(f"Failed to initialize Cosmos DB connection: {e}", file=stderr)
            raise

    def load_historical_data(
        self, debug_output: bool
    ) -> List[Dict[str, Union[str, int]]]:
        try:
            entities = list(self.table_client.list_entities())
            metrics: List[Dict[str, Union[str, int]]] = [
                {
                    "timestamp": str(entity["RowKey"]),
                    "healthy": int(entity["PartitionKey"]),
                }
                for entity in entities
            ]
            metrics.sort(key=lambda x: datetime.fromisoformat(str(x["timestamp"])))
            return metrics
        except Exception as e:
            print(f"Error loading data from Cosmos DB: {e}", file=stderr)
            return []

    def append_metric(
        self, record: Dict[str, Union[str, int]], debug_output: bool
    ) -> None:
        entity = {
            "PartitionKey": str(record["healthy"]),
            "RowKey": str(record["timestamp"]),
        }
        try:
            if debug_output:
                print(f"Appending record to Cosmos DB: {entity}")
            self.table_client.create_entity(entity=entity)
            self.historical_data.append(record)
        except Exception as e:
            print(f"Error appending to Cosmos DB: {e}", file=stderr)

    def print_raw_entities(self) -> None:
        try:
            entities = list(self.table_client.list_entities())
            for entity in entities:
                print(entity)
            print(f"Total entities: {len(entities)}")
        except Exception as e:
            print(f"Error printing Cosmos DB entities: {e}", file=stderr)


class ResultsSaver(ABC):
    @abstractmethod
    def save_json(self, content: str, debug_output: bool) -> None:
        pass

    @abstractmethod
    def save_html(self, content: str, debug_output: bool) -> None:
        pass

    @abstractmethod
    def save_png(self, content: BytesIO, debug_output: bool) -> None:
        pass

    @abstractmethod
    def save_last_error_json(self, content: str, debug_output: bool) -> None:
        pass


class FileSaver(ResultsSaver):
    def __init__(self, save_name_json: str, save_name_html: str) -> None:
        self.save_name_json = save_name_json
        self.save_name_html = save_name_html
        self.save_name_png = f"{path.splitext(save_name_html)[0]}.png"
        self.save_name_last_error_json = (
            f"{path.splitext(save_name_json)[0]}-last_error.json"
        )

    def save_json(self, content: str, debug_output: bool) -> None:
        try:
            with open(self.save_name_json, "w", encoding="utf-8") as f:
                f.write(content)
        except Exception as e:
            print(f"Error saving JSON file: {e}", file=stderr)

    def save_html(self, content: str, debug_output: bool) -> None:
        try:
            with open(self.save_name_html, "w", encoding="utf-8") as f:
                f.write(content)
        except Exception as e:
            print(f"Error saving HTML file: {e}", file=stderr)

    def save_png(self, content: BytesIO, debug_output: bool) -> None:
        try:
            with open(self.save_name_png, "wb") as f:
                f.write(content.getvalue())
        except Exception as e:
            print(f"Error saving PNG file: {e}", file=stderr)

    def save_last_error_json(self, content: str, debug_output: bool) -> None:
        try:
            with open(self.save_name_last_error_json, "w", encoding="utf-8") as f:
                f.write(content)
        except Exception as e:
            print(f"Error saving last error JSON: {e}", file=stderr)


class AzureBlobSaver(ResultsSaver):
    def __init__(
        self,
        azure_connection_string: str,
        azure_container_name: str,
        save_name_json: str,
        save_name_html: str,
    ) -> None:
        try:
            blob_service_client: BlobServiceClient = (
                BlobServiceClient.from_connection_string(azure_connection_string)
            )
            self.azure_container_name = azure_container_name
            self.save_name_json = save_name_json
            self.save_name_html = save_name_html
            self.save_name_png = f"{path.splitext(save_name_html)[0]}.png"
            self.save_name_last_error_json = (
                f"{path.splitext(save_name_json)[0]}-last_error.json"
            )
            self.blob_client_json: BlobClient = blob_service_client.get_blob_client(
                container=azure_container_name, blob=self.save_name_json
            )
            self.blob_client_html: BlobClient = blob_service_client.get_blob_client(
                container=azure_container_name, blob=self.save_name_html
            )
            self.blob_client_png: BlobClient = blob_service_client.get_blob_client(
                container=azure_container_name, blob=self.save_name_png
            )
            self.blob_client_last_error_json: BlobClient = (
                blob_service_client.get_blob_client(
                    container=azure_container_name, blob=self.save_name_last_error_json
                )
            )
        except Exception as e:
            print(f"Failed to initialize Azure Blob Storage: {e}", file=stderr)
            raise

    def save_json(self, content: str, debug_output: bool) -> None:
        try:
            self.blob_client_json.upload_blob(
                content,
                overwrite=True,
                content_settings=ContentSettings(
                    content_type="application/json", cache_control="max-age=60"
                ),
            )
            if debug_output:
                print(
                    f"JSON data uploaded to Azure: {self.azure_container_name}/{self.save_name_json}"
                )
        except Exception as e:
            print(f"Error uploading JSON to Azure: {e}", file=stderr)

    def save_html(self, content: str, debug_output: bool) -> None:
        try:
            self.blob_client_html.upload_blob(
                content,
                overwrite=True,
                content_settings=ContentSettings(
                    content_type="text/html", cache_control="max-age=60"
                ),
            )
            if debug_output:
                print(
                    f"HTML data uploaded to Azure: {self.azure_container_name}/{self.save_name_html}"
                )
        except Exception as e:
            print(f"Error uploading HTML to Azure: {e}", file=stderr)

    def save_png(self, content: BytesIO, debug_output: bool) -> None:
        try:
            self.blob_client_png.upload_blob(
                content,
                overwrite=True,
                content_settings=ContentSettings(
                    content_type="image/png", cache_control="max-age=60"
                ),
            )
            if debug_output:
                print(
                    f"PNG data uploaded to Azure: {self.azure_container_name}/{self.save_name_png}"
                )
        except Exception as e:
            print(f"Error uploading PNG to Azure: {e}", file=stderr)

    def save_last_error_json(self, content: str, debug_output: bool) -> None:
        try:
            self.blob_client_last_error_json.upload_blob(
                content,
                overwrite=True,
                content_settings=ContentSettings(
                    content_type="application/json", cache_control="max-age=60"
                ),
            )
            if debug_output:
                print(
                    f"Last error JSON uploaded: {self.azure_container_name}/{self.save_name_last_error_json}"
                )
        except Exception as e:
            print(f"Error uploading last error JSON to Azure: {e}", file=stderr)


def save_json(file_name: str, data: List[Dict[str, Union[str, int]]]) -> None:
    """Save JSON data to file."""
    try:
        with open(file_name, "w", encoding="utf-8") as file:
            dump(data, file, indent=4)
    except Exception as e:
        print(f"Error saving JSON file {file_name}: {e}", file=stderr)


def trim_data(
    data: List[Dict[str, Union[str, int]]]
) -> List[Dict[str, Union[str, int]]]:
    """
    Remove one-minute-duplicates (entries with time difference < 59.99s) and keep only the last DATASET_LENGTH_MINUTES items.
    """
    if not data:
        return []

    try:
        data_sorted: List[Dict[str, Union[str, int]]] = sorted(
            data, key=lambda x: datetime.fromisoformat(str(x["timestamp"]))
        )
        filtered_data: List[Dict[str, Union[str, int]]] = []
        last_timestamp: Optional[datetime] = None

        for entry in data_sorted:
            try:
                current_timestamp = datetime.fromisoformat(str(entry["timestamp"]))
                if (
                    not last_timestamp
                    or (current_timestamp - last_timestamp).total_seconds() >= 59.99
                ):
                    filtered_data.append(entry)
                last_timestamp = current_timestamp
            except (ValueError, KeyError) as e:
                print(f"Warning: Skipping invalid timestamp entry: {e}", file=stderr)
                continue

        if len(filtered_data) > RESULTS_COUNT_MINUTES:
            filtered_data = filtered_data[-RESULTS_COUNT_MINUTES:]
        return filtered_data
    except Exception as e:
        print(f"Error trimming data: {e}", file=stderr)
        return data


def create_graphical_representation(
    data_sorted: List[Dict[str, Union[str, int]]], font_file_name: Optional[str] = None
) -> BytesIO:
    """Create a memory buffer with a PNG image showing health status over time."""
    width: int = RESULTS_COUNT_MINUTES
    height: int = 200

    try:
        img: Image.Image = Image.new("P", (width, height))
        palette = [
            128,
            128,
            128,  # Gray
            0,
            255,
            0,  # Green
            255,
            0,
            0,  # Red
            0,
            0,
            0,  # Black
        ]
        img.putpalette(palette)
        pixels = img.load()
        assert pixels is not None

        # Initialize with gray background
        for x in range(width):
            for y in range(height):
                pixels[x, y] = 0  # Gray

        # Plot health data
        for i, item in enumerate(reversed(data_sorted)):
            if i >= width:
                break
            color_index: int = 0
            if "healthy" in item:
                try:
                    health = int(item["healthy"])
                    if health == STATUS_HEALTHY:
                        color_index = 1
                    elif health == STATUS_UNHEALTHY:
                        color_index = 2
                except (ValueError, TypeError):
                    color_index = 0  # Default to gray
            for y in range(height):
                pixels[width - i - 1, y] = color_index

        # Add date markers
        if font_file_name and path.exists(font_file_name):
            try:
                font: Union[ImageFont.FreeTypeFont, ImageFont.ImageFont] = (
                    ImageFont.truetype(font_file_name, size=40)
                )
            except Exception:
                font = ImageFont.load_default()
        else:
            font = ImageFont.load_default()

        draw = ImageDraw.Draw(img)
        previous_date: Optional[date] = None
        for i, item in enumerate(data_sorted):
            try:
                current_date = datetime.fromisoformat(str(item["timestamp"])).date()
                if previous_date and current_date != previous_date:
                    x_pos = i - len(data_sorted) + width
                    if 0 <= x_pos < width:
                        for y_pos in range(min(20, height)):
                            pixels[x_pos, y_pos] = 3
                        date_str: str = current_date.strftime("%Y-%m-%d")
                        text_bbox = draw.textbbox((0, 0), date_str, font=font)
                        text_width = text_bbox[2] - text_bbox[0]
                        if x_pos - text_width // 2 < 0:
                            anchor = "la"
                        elif x_pos + text_width // 2 > width:
                            anchor = "ra"
                        else:
                            anchor = "ma"
                        draw.text(
                            (x_pos, 10), date_str, font=font, fill=3, anchor=anchor
                        )
                previous_date = current_date
            except (ValueError, KeyError):
                continue

        image_data: BytesIO = BytesIO()
        img.save(image_data, format="PNG")
        image_data.seek(0)
        return image_data
    except Exception as e:
        print(f"Error creating graphical representation: {e}", file=stderr)
        # Return empty PNG on error
        empty_img = Image.new("RGB", (width, height), color="gray")
        image_data = BytesIO()
        empty_img.save(image_data, format="PNG")
        image_data.seek(0)
        return image_data


def render_history_to_png_file(
    data_sorted: List[Dict[str, Union[str, int]]],
    filename_output_png: str,
    font_file_name: Optional[str] = None,
) -> None:
    """Render historical data as a PNG image and save it to a file."""
    # Validate file path to prevent path traversal
    try:
        validated_path = validate_file_path(filename_output_png, "PNG output")
    except ValueError as e:
        print(f"Invalid PNG output path: {e}", file=stderr)
        return

    png_image_data: BytesIO = create_graphical_representation(
        data_sorted, font_file_name=font_file_name
    )
    try:
        # Use basename to sanitize and break taint chain
        safe_dir = path.dirname(path.realpath(validated_path))
        safe_name = path.basename(validated_path)
        safe_path = path.join(safe_dir, safe_name)
        with open(safe_path, "wb") as png_file:
            png_file.write(png_image_data.getvalue())
    except Exception as e:
        print(f"Error saving PNG file {validated_path}: {e}", file=stderr)


def get_firefox_impersonate() -> str:
    """Get best available Firefox impersonation for curl_cffi.

    Returns newest available Firefox version, falling back to Chrome.
    """
    try:
        from curl_cffi.requests import BrowserType
        # Prefer newest Firefox version available
        for browser in ['firefox144', 'firefox135', 'firefox133']:
            if hasattr(BrowserType, browser):
                return browser
    except (ImportError, AttributeError):
        pass
    return "chrome"  # Fallback


def build_request_headers(
    user_agent: Optional[str], authorization: Optional[str]
) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    if user_agent:
        # Strip "User-Agent:" prefix if present to avoid duplication
        ua_value = user_agent
        if ua_value.lower().startswith("user-agent:"):
            ua_value = ua_value[len("user-agent:") :].lstrip()
        headers["User-Agent"] = ua_value
    if authorization:
        headers["Authorization"] = authorization
    return headers


def monitor_website(
    url: str,
    request_timeout: float,
    deviation_threshold: float,
    latency_threshold: float,
    error_rate_threshold: float,
    azure_connection_string: Optional[str],
    azure_container_name: Optional[str],
    save_name_json: str,
    save_name_html: str,
    tz_offset: float,
    tz_caption: str,
    user_agent: Optional[str],
    authorization: Optional[str],
    storage: DataStorage,
    probe_interval: int,
    font_file_name: Optional[str],
    debug_output: bool,
    use_session: bool,
) -> None:
    """Main monitoring loop with improved memory management and error handling."""
    effective_latencies: List[float] = []
    adjusted_latencies: List[float] = []
    response_status_codes: List[Optional[int]] = []
    errors: List[bool] = []

    if azure_connection_string and azure_container_name:
        print("Connecting to Azure storage for results...")
        try:
            saver: ResultsSaver = AzureBlobSaver(
                azure_connection_string,
                azure_container_name,
                save_name_json,
                save_name_html,
            )
            print("Connected to Azure Blob storage.")
        except Exception as e:
            print(f"Failed to connect to Azure Blob storage: {e}", file=stderr)
            print("Falling back to local file storage.")
            saver = FileSaver(save_name_json, save_name_html)
    else:
        print(
            "Not using Azure storage since connection string/container name not supplied."
        )
        saver = FileSaver(save_name_json, save_name_html)

    # Use browser impersonation for TLS fingerprint to avoid bot detection
    # If user-agent contains "Firefox", use Firefox impersonation; otherwise Chrome
    browser_impersonate = "chrome"
    if user_agent and "firefox" in user_agent.lower():
        browser_impersonate = get_firefox_impersonate()
    session = Session(impersonate=browser_impersonate) if use_session else None
    headers = build_request_headers(user_agent, authorization)

    if session:
        session.headers.update(headers)

    try:
        while True:
            start_time: float = time()
            next_probe_time: float = start_time + probe_interval
            effective_latency: Optional[float] = None
            adjusted_latency: Optional[float] = None
            response_status_code: Optional[int] = None
            error_happened: Optional[bool] = None
            probe_timestamp_dt: datetime = datetime.now(timezone.utc)

            try:
                # Use tuple timeout (connect_timeout, read_timeout) for curl_cffi compatibility
                timeout_tuple = (request_timeout, request_timeout)
                if session:
                    response: Response = session.get(url, timeout=timeout_tuple)
                else:
                    response = cffi_requests.get(
                        url,
                        timeout=timeout_tuple,
                        headers=headers,
                        impersonate=browser_impersonate,
                    )
                response_status_code = response.status_code
                probe_end_time = time()
                if response_status_code == 200:
                    effective_latency = probe_end_time - start_time
                    adjusted_latency = effective_latency
                    error_happened = False
                else:
                    effective_latency = probe_end_time - start_time
                    adjusted_latency = request_timeout
                    error_happened = True
                    if debug_output:
                        err_ext = (
                            ".html"
                            if "text/html" in response.headers.get("Content-Type", "")
                            else ".txt"
                        )
                        error_file_name: str = (
                            f"{response_status_code}_{save_name_html.rsplit('.', 1)[0]}{err_ext}"
                        )
                        try:
                            with open(
                                error_file_name, "w", encoding="utf-8"
                            ) as error_file:
                                error_file.write(response.text)
                        except Exception as file_err:
                            print(
                                f"Could not write error file {error_file_name}: {file_err}",
                                file=stderr,
                            )
            except Exception as e:
                probe_end_time = time()
                error_happened = True
                effective_latency = probe_end_time - start_time
                adjusted_latency = request_timeout
                print(f"Probe failed: {e}", file=stderr)

            # Append results for each second in the interval
            current_probe_error: bool = error_happened is True
            current_probe_effective_latency: float = (
                effective_latency if effective_latency is not None else 0.0
            )
            current_probe_adjusted_latency: float = (
                adjusted_latency if adjusted_latency is not None else request_timeout
            )
            current_probe_response_status_code: Optional[int] = response_status_code

            # Propagate results for each second in the interval
            errors.extend([current_probe_error] * probe_interval)
            effective_latencies.extend(
                [current_probe_effective_latency] * probe_interval
            )
            adjusted_latencies.extend([current_probe_adjusted_latency] * probe_interval)
            response_status_codes.extend(
                [current_probe_response_status_code] * probe_interval
            )

            # Clean up old data to prevent memory leaks
            cleanup_old_data(errors, MAX_HISTORY_SIZE)
            cleanup_old_data(effective_latencies, MAX_HISTORY_SIZE)
            cleanup_old_data(adjusted_latencies, MAX_HISTORY_SIZE)
            cleanup_old_data(response_status_codes, MAX_HISTORY_SIZE)

            cur_sample_size: int = len(errors)
            if cur_sample_size > SAMPLE_SIZE_SECONDS:

                analysis_errors = errors[-SAMPLE_SIZE_SECONDS:]
                analysis_eff_latencies = effective_latencies[-SAMPLE_SIZE_SECONDS:]
                analysis_adj_latencies = adjusted_latencies[-SAMPLE_SIZE_SECONDS:]
                analysis_status_codes = response_status_codes[-SAMPLE_SIZE_SECONDS:]

                valid_eff_latencies = [
                    latency for latency in analysis_eff_latencies if latency is not None
                ]
                valid_adj_latencies = [
                    latency for latency in analysis_adj_latencies if latency is not None
                ]

                min_eff = min(valid_eff_latencies) if valid_eff_latencies else 0.0
                max_eff = max(valid_eff_latencies) if valid_eff_latencies else 0.0
                avg_eff = mean(valid_eff_latencies) if valid_eff_latencies else 0.0
                avg_adj = mean(valid_adj_latencies) if valid_adj_latencies else 0.0
                std_dev_eff = (
                    stdev(valid_eff_latencies) if len(valid_eff_latencies) > 1 else 0.0
                )
                std_dev_adj = (
                    stdev(valid_adj_latencies) if len(valid_adj_latencies) > 1 else 0.0
                )

                num_errors = sum(1 for e in analysis_errors if e is True)
                error_rate: float = (num_errors / SAMPLE_SIZE_SECONDS) * 100.0

                # Find most common non-200 status code in the analysis window
                error_codes = [
                    cd for cd in analysis_status_codes if cd is not None and cd != 200
                ]
                most_common_code: Optional[int] = 200
                if error_codes:
                    code_counts = Counter(error_codes)
                    most_common_code, _ = code_counts.most_common(1)[0]

                health_status = STATUS_UNHEALTHY
                if (
                    avg_eff <= latency_threshold
                    and avg_adj <= latency_threshold
                    and error_rate <= error_rate_threshold
                    and std_dev_eff <= deviation_threshold
                    and std_dev_adj <= deviation_threshold
                ):
                    health_status = STATUS_HEALTHY

                if debug_output:
                    print(
                        f"Probe @ {probe_timestamp_dt.strftime('%H:%M:%S')}: "
                        f"AvgEff: {avg_eff:.3f}s, AvgAdj: {avg_adj:.3f}s, Err%: {error_rate:.1f}, "
                        f"StdEff: {std_dev_eff:.3f}s, StdAdj: {std_dev_adj:.3f}s, Code: {most_common_code}, Health: {health_status}"
                    )

                timestamp_str = probe_timestamp_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
                json_data: Dict[str, Union[str, float, int]] = {
                    "timestamp": timestamp_str,
                    "min_effective_latency": round(min_eff, 6),
                    "max_effective_latency": round(max_eff, 6),
                    "avg_effective_latency": round(avg_eff, 6),
                    "avg_adjusted_latency": round(avg_adj, 6),
                    "error_rate": round(error_rate, 2),
                    "std_deviation_effective_latency": round(std_dev_eff, 6),
                    "std_deviation_adjusted_latency": round(std_dev_adj, 6),
                    "healthy": health_status,
                    "probe_interval": probe_interval,
                }
                if isinstance(most_common_code, int) and 100 <= most_common_code <= 599:
                    json_data["status_code"] = most_common_code

                append_health_metric(
                    storage,
                    probe_timestamp_dt,
                    health_status,
                    debug_output=debug_output,
                )

                storage.historical_data = trim_data(storage.historical_data)
                png_image_data = create_graphical_representation(
                    storage.historical_data, font_file_name=font_file_name
                )
                data_json_str: str = dumps(json_data, indent=4)

                health_text: str = (
                    "Healthy" if health_status == STATUS_HEALTHY else "Unhealthy"
                )
                health_color: str = (
                    "green" if health_status == STATUS_HEALTHY else "red"
                )

                local_dt = probe_timestamp_dt.astimezone(
                    timezone(timedelta(hours=tz_offset))
                )
                local_dt_str: str = local_dt.strftime("%Y-%m-%d %H:%M:%S ") + tz_caption

                data_html: str = f"""
                <!DOCTYPE html>
                <html lang="en">
                <head>
                    <meta charset="UTF-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <link rel="icon" href="favicon.ico" type="image/x-icon">
                    <meta http-equiv="refresh" content="60">
                    <title>{health_text}</title>
                    <style>
                        body {{
                            display: flex;
                            flex-direction: column;
                            justify-content: center;
                            align-items: center;
                            height: 100vh;
                            margin: 0;
                            font-family: Helvetica, Arial, sans-serif;
                            text-align: center;
                        }}
                        .link {{
                            font-size: 1.2em;
                        }}
                        .status {{
                            color: {health_color};
                            font-size: 3em;
                            margin-top: 10px;
                        }}
                        .time {{
                            font-size: 1.5em;
                            margin-top: 10px;
                        }}
                        .image-container {{
                            width: 80%;
                            margin-top: 20px;
                        }}
                        .image-container img {{
                            width: 100%;
                            height: auto;
                        }}
                    </style>
                </head>
                <body>
                    <div class="status">{health_text}</div>
                    <div class="time">{local_dt_str}</div>
                    <div class="link"><a href="{save_name_json}">{save_name_json}</a></div>
                    <div class="link"><a href="{path.splitext(save_name_json)[0]}-last_error.json">{path.splitext(save_name_json)[0]}-last_error.json</a></div>
                    <div class="image-container">
                        <img src="{path.splitext(save_name_html)[0]}.png" alt="Health Status for Last {RESULTS_COUNT_MINUTES // (60)} Hours">
                    </div>
                </body>
                </html>
                """

                saver.save_json(data_json_str, debug_output=debug_output)
                saver.save_html(data_html, debug_output=debug_output)
                saver.save_png(png_image_data, debug_output=debug_output)
                if health_status == STATUS_UNHEALTHY:
                    saver.save_last_error_json(data_json_str, debug_output=debug_output)

                # Clean up old data periodically
                points_to_remove = UPDATE_INTERVAL_SECONDS
                if len(effective_latencies) > points_to_remove:
                    del effective_latencies[:points_to_remove]
                    del adjusted_latencies[:points_to_remove]
                    del response_status_codes[:points_to_remove]
                    del errors[:points_to_remove]

            current_time = time()
            sleep_duration = next_probe_time - current_time
            if sleep_duration > 0:
                sleep(sleep_duration)

    except KeyboardInterrupt:
        print("\nMonitoring stopped by user (KeyboardInterrupt).")
        sys.exit(0)
    except SystemExit as e:
        print(f"\nMonitoring stopped (SystemExit: {e}).")
        raise
    except Exception as e:
        print(f"\nAn unexpected error occurred during monitoring: {e}", file=stderr)
        raise
    finally:
        if session:
            session.close()


def append_health_metric(
    storage: DataStorage,
    probe_timestamp_dt: datetime,
    health_status: int,
    debug_output: bool,
) -> None:
    current_timestamp_str = probe_timestamp_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    metric_record: Dict[str, Union[str, int]] = {
        "timestamp": current_timestamp_str,
        "healthy": health_status,
    }
    storage.append_metric(metric_record, debug_output=debug_output)


def handle_sigterm(_signum: int, _frame: Optional[FrameType]) -> None:
    """Handle SIGTERM signal for graceful script exit."""
    print("\nMonitoring stopped by service signal (SIGTERM).")
    sys.exit(0)


def test_url(
    url: str,
    request_timeout: float,
    user_agent: Optional[str],
    authorization: Optional[str],
    use_session: bool,
) -> int:
    """Test URL connectivity and detect Cloudflare blocking. Returns 0 on success, 1 on failure."""
    print(f"Testing: {url}")
    print(f"Timeout: {request_timeout}s")
    print("-" * 60)

    # Use browser impersonation matching user-agent
    browser_impersonate = "chrome"
    if user_agent and "firefox" in user_agent.lower():
        browser_impersonate = get_firefox_impersonate()
    headers = build_request_headers(user_agent, authorization)
    session = Session(impersonate=browser_impersonate) if use_session else None

    if session:
        session.headers.update(headers)

    try:
        start_time = time()
        # Use tuple timeout (connect_timeout, read_timeout) for curl_cffi compatibility
        timeout_tuple = (request_timeout, request_timeout)
        if session:
            response: Response = session.get(url, timeout=timeout_tuple)
        else:
            response = cffi_requests.get(
                url,
                timeout=timeout_tuple,
                headers=headers,
                impersonate=browser_impersonate,
            )
        latency = time() - start_time

        print(f"Status: {response.status_code}")
        print(f"Latency: {latency:.3f}s")

        content_type = response.headers.get("Content-Type", "unknown")
        content_length = response.headers.get("Content-Length", "unknown")
        print(f"Content-Type: {content_type}")
        print(f"Content-Length: {content_length}")

        # Check for Cloudflare blocking indicators
        body_lower = response.text[:5000].lower() if response.text else ""
        cloudflare_indicators = [
            "cloudflare",
            "cf-ray",
            "checking your browser",
            "challenge-platform",
            "cf-chl-bypass",
            "just a moment",
            "enable javascript and cookies",
        ]
        captcha_indicators = [
            "captcha",
            "hcaptcha",
            "recaptcha",
            "challenge",
            "verify you are human",
        ]

        is_cloudflare = any(ind in body_lower for ind in cloudflare_indicators)
        is_captcha = any(ind in body_lower for ind in captcha_indicators)
        cf_ray = response.headers.get("cf-ray", None)

        print("-" * 60)

        if response.status_code == 200 and not is_captcha:
            print("Result: OK - monitoring should work")
            if is_cloudflare:
                print("Note: Cloudflare detected but request succeeded")
            return 0
        elif response.status_code == 403:
            print("Result: BLOCKED - access forbidden")
            if is_cloudflare or cf_ray:
                print("Reason: Cloudflare protection detected")
                print(
                    "Solution: Whitelist monitoring server IP in Cloudflare firewall rules"
                )
            return 1
        elif is_captcha:
            print("Result: BLOCKED - CAPTCHA challenge detected")
            print(
                "Reason: Cloudflare or similar protection requiring human verification"
            )
            print(
                "Solution: Whitelist monitoring server IP in Cloudflare firewall rules"
            )
            if response.text:
                preview = response.text[:500].replace("\n", " ").replace("\r", "")
                print(f"Body preview: {preview}...")
            return 1
        elif response.status_code >= 400:
            print(f"Result: ERROR - HTTP {response.status_code}")
            return 1
        else:
            print(f"Result: OK - status {response.status_code}")
            return 0

    except Exception as e:
        print(f"Result: FAILED - {e}")
        return 1
    finally:
        if session:
            session.close()


def main() -> None:
    signal.signal(signal.SIGTERM, handle_sigterm)

    parser = ArgumentParser(description="Website Health Monitoring Script")
    parser.add_argument("--url", type=str, help="The URL of the website to monitor")
    parser.add_argument(
        "--authorization", type=str, help='Specify "Authorization" header'
    )
    parser.add_argument(
        "--user-agent", type=str, help='Overrides the "User-Agent" header'
    )
    parser.add_argument(
        "--timeout", type=float, default=2.0, help="Request timeout in seconds"
    )
    parser.add_argument(
        "--probe-interval",
        type=int,
        default=1,
        help="Interval between probes in seconds (1-60, default: %(default)s)",
    )
    parser.add_argument(
        "--deviation-threshold",
        type=float,
        default=0.3,
        help="Std deviation threshold in seconds",
    )
    parser.add_argument(
        "--latency-threshold",
        type=float,
        default=0.5,
        help="Avg. latency threshold in seconds",
    )
    parser.add_argument(
        "--error-rate-threshold",
        type=float,
        default=5.0,
        help="Error rate threshold in percent",
    )
    parser.add_argument(
        "--azure-blob-storage-connection-string",
        type=str,
        default=None,
        help="Azure Storage account connection string",
    )
    parser.add_argument(
        "--azure-blob-storage-container-name",
        type=str,
        default="$web",
        help="Azure Blob container name",
    )
    parser.add_argument(
        "--save-name-json",
        type=str,
        default="results.json",
        help="Blob/file name for JSON results",
    )
    parser.add_argument(
        "--save-name-html",
        type=str,
        default="index.html",
        help="Blob/file name for HTML results",
    )
    parser.add_argument(
        "--tz-offset", type=float, default=0.0, help="Time zone offset in hours"
    )
    parser.add_argument("--tz-caption", type=str, default="UTC", help="Time zone label")
    parser.add_argument(
        "--render-history-input", type=str, help="Render history from a JSON file"
    )
    parser.add_argument(
        "--render-history-output", type=str, help="Output PNG file for history"
    )
    parser.add_argument(
        "--cosmosdb-connection-string",
        type=str,
        default=None,
        help="Cosmos DB connection string for Table API storage",
    )
    parser.add_argument(
        "--cosmosdb-table-name",
        type=str,
        default=None,
        help="Cosmos DB table name for metrics storage",
    )
    parser.add_argument(
        "--cosmosdb-test-store",
        type=int,
        choices=[0, 1],
        default=None,
        help="Perform Cosmos DB store value test (value must be 0 or 1) and exit",
    )
    parser.add_argument(
        "--cosmosdb-print-table",
        action="store_true",
        help="Print all entries in the Cosmos DB table and exit",
    )
    parser.add_argument(
        "--font-file",
        type=str,
        default="font.otf",
        help="Font file to use for PNG rendering (default: %(default)s)",
    )
    parser.add_argument(
        "--use-session",
        action="store_true",
        help="Use persistent HTTP session with keep-alive",
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug output")
    parser.add_argument(
        "--test",
        action="store_true",
        help="Test URL connectivity and exit (no data collection)",
    )
    parser.add_argument(
        "--export-file",
        type=str,
        help="Export all historical data to the specified file and exit.",
    )
    parser.add_argument(
        "--export-format",
        type=str,
        choices=["json", "csv"],
        help="Format for the exported data (json or csv).",
    )

    args: Namespace = parser.parse_args()

    font_file_name = args.font_file if path.isfile(args.font_file) else None

    if args.cosmosdb_connection_string and args.cosmosdb_table_name:
        print("Using Cosmos DB Table storage for metrics history.")
        cosmosdb_debug: bool = args.cosmosdb_test_store is not None or args.debug
        try:
            storage: DataStorage = CosmosDBTableStorage(
                args.cosmosdb_connection_string,
                args.cosmosdb_table_name,
                debug_output=cosmosdb_debug,
            )
        except Exception as e:
            print(f"Failed to initialize Cosmos DB storage: {e}", file=stderr)
            sys.exit(1)

        if args.cosmosdb_test_store is not None:
            print("Performing Cosmos DB connection test...")
            append_health_metric(
                storage,
                datetime.now(timezone.utc),
                args.cosmosdb_test_store,
                debug_output=cosmosdb_debug,
            )
            print("Cosmos DB connection test successful.")
            return

        if args.cosmosdb_print_table:
            print("Printing raw entries in the Cosmos DB table:")
            storage.print_raw_entities()
            return

    else:
        history_filename: str = f"{path.splitext(args.save_name_html)[0]}-history.json"
        print("Using local JSON file for metrics history:", history_filename)
        if args.render_history_input and args.render_history_output:
            load_history_filename = args.render_history_input
        else:
            load_history_filename = history_filename
        storage = JsonFileStorage(load_history_filename, debug_output=args.debug)

    if args.export_file:
        if not args.export_format:
            print(
                "Error: --export-format is required when using --export-file.",
                file=sys.stderr,
            )
            sys.exit(1)
        export_data(
            storage.historical_data, args.export_file, args.export_format, args.debug
        )
        return

    storage.historical_data = trim_data(storage.historical_data)

    if args.cosmosdb_print_table:
        print("Printing historical data from Cosmos DB:")
        for entry in storage.historical_data:
            print(entry)
        print(f"Total historical data entries: {len(storage.historical_data)}")
        return

    if args.render_history_input and args.render_history_output:
        print(
            f"Rendering history from {args.render_history_input} to {args.render_history_output}"
        )
        try:
            render_history_to_png_file(
                storage.historical_data,
                args.render_history_output,
                font_file_name=font_file_name,
            )
            print("History rendering completed successfully.")
        except Exception as e:
            print(f"Error rendering history: {e}", file=stderr)
            sys.exit(1)

    elif args.url:
        allowed_prefixes = ["http://", "https://"]
        if not args.url.startswith(tuple(allowed_prefixes)):
            print(
                f"Error: URL must start with {' or '.join(allowed_prefixes)}",
                file=stderr,
            )
            sys.exit(1)

        if args.test:
            exit_code = test_url(
                url=args.url,
                request_timeout=args.timeout,
                user_agent=args.user_agent,
                authorization=args.authorization,
                use_session=args.use_session,
            )
            sys.exit(exit_code)

        if not 1 <= args.probe_interval <= 60:
            print(
                "Error: Probe interval must be between 1 and 60 seconds.", file=stderr
            )
            sys.exit(1)

        print(f"Starting website monitoring for: {args.url}")
        monitor_website(
            url=args.url,
            request_timeout=args.timeout,
            deviation_threshold=args.deviation_threshold,
            latency_threshold=args.latency_threshold,
            error_rate_threshold=args.error_rate_threshold,
            azure_connection_string=args.azure_blob_storage_connection_string,
            azure_container_name=args.azure_blob_storage_container_name,
            save_name_json=args.save_name_json,
            save_name_html=args.save_name_html,
            tz_offset=args.tz_offset,
            tz_caption=args.tz_caption,
            user_agent=args.user_agent,
            authorization=args.authorization,
            storage=storage,
            probe_interval=args.probe_interval,
            font_file_name=font_file_name,
            debug_output=args.debug,
            use_session=args.use_session,
        )
    else:
        parser.print_help(stderr)


if __name__ == "__main__":
    main()
