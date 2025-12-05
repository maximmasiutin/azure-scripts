# Standard Deviation Health Status Monitor

## Overview
The **Standard Deviation Health Status Monitor** is a website monitoring tool that evaluates the health of websites using various metrics such as latency, error rate, and the standard deviation of latency. The program periodically checks the specified website, calculates relevant statistics, and determines the health status based on predefined thresholds. Additionally, it supports storing the results in Azure Blob Storage.

## Features
- Monitors website latency and error rates.
- Calculates average and standard deviation of latency.
- Determines website health status based on defined thresholds.
- Supports Azure Blob Storage for saving JSON and HTML reports.
- Generates a simple HTML report displaying the current health status.
- Customizable user agent for website requests.

## Requirements
- Python 3.x
- `curl_cffi` package (impersonates Chrome TLS fingerprint to avoid Cloudflare bot detection)
- `azure-storage-blob` package
- `azure-data-tables` package
- `Pillow` package (PIL)
- `statistics` package (standard since Python 3.4)
- `argparse` package (standard since Python 3.2)

## Installation

Install the required Python packages using `pip`:
```sh
pip install curl_cffi azure-storage-blob azure-data-tables Pillow
```
or
```sh
pip install -r requirements.txt
```

Note: `curl_cffi` replaces the standard `requests` library to provide browser-like TLS fingerprinting, which helps avoid bot detection on sites protected by Cloudflare.

## Using
### Calling format
To run the program, use the following command with the appropriate parameters:
```sh
python monitor-stddev.py --url <website_url> --timeout <request_timeout> --deviation-threshold <std_dev_threshold> --latency-threshold <latency_threshold> --error-rate-threshold <error_rate_threshold> --azure-connection-string <connection_string> --azure-container-name <container_name> --save-name-json <json_file_name> --save-name-html <html_file_name> --tz-offset <timezone_offset> --tz-caption <timezone_caption> --user-agent <user_agent_string>
```

### Calling example
```sh
python monitor-stddev.py --url "https://example.com" --timeout 10 --deviation-threshold 0.5 --latency-threshold 2.0 --error-rate-threshold 5.0 --azure-connection-string "your_azure_connection_string" --azure-container-name "your_container_name" --save-name-json "status.json" --save-name-html "status.html" --tz-offset 2 --tz-caption "EET" --user-agent "MyWebsiteMonitor"
```

### Output example

You can see the real-time monitoring results of github.com at https://web.archive.org/web/20250623162753/http://web.archive.org/screenshot/https://githubmonitoring.azureedge.net/

An example of an unstable website can be seen at https://web.archive.org/web/20250623162756/http://web.archive.org/screenshot/https://monitoring4.azureedge.net/

## Parameters

- `--url`: The URL of the website to monitor. This is a required parameter. It should start with `http://` or `https://`.

- `--authorization`: Value of the "Authorization" HTTP header

- `--user-agent`: The user agent string to be used in the HTTP request header. This is optional and can be used to customize the User-Agent sent with each probe.

- `--timeout`: The maximum amount of time to wait for a response from the website, in seconds. It is also used to calculate "adjusted" latency value: if the request returns non-200-status, the adjusted latency is considered as big as the timeout value. The default value is `2.0` seconds.

- `--deviation-threshold`: The threshold value for the standard deviation of latency. If the standard deviation of latency exceeds this value, the website is considered unhealthy. The default value is `0.2` seconds.

- `--latency-threshold`: The threshold value for the average latency. If the average latency exceeds this value, the website is considered unhealthy. The default value is `0.5` seconds.

- `--error-rate-threshold`: The threshold value for the error rate, expressed as a percentage (but without the % sign). If the error rate exceeds this value, the website is considered unhealthy. The default value is `5.0` percent.

- `--probe-interval`: Interval between probes in seconds (1-60); default: 1.

- `--azure-blob-storage-connection-string`: The connection string for your Azure Storage account. This is optional. If provided, the monitoring results will be saved to Azure Blob Storage. Otherwise, the last results will be saved to disk files, overwriting previous results.

- `--azure-blob-storage-container-name`: The name of the Azure Blob Storage container where the results will be stored. The default value is `$web`. This is optional and used only if `--azure-blob-storage-connection-string` is provided.

- `--save-name-json`: The name of the JSON file (or Azure Blob) where the monitoring results will be saved. The default value is `results.json`.

- `--save-name-html`: The name of the HTML file (or Azure Blob) where the health status page will be saved. The default value is `index.html`.

- `--tz-offset`: The timezone offset from UTC, expressed in hours. This parameter is used to display the local time in the HTML report. The default value is `0.0` hours.

- `--tz-caption`: A text caption representing the timezone. This is used in the HTML report to display the local time. The default value is `"UTC"`.

- `--render-history-input` Render history from a JSON file (if specified, then you should also specify `--render-history-output`).

- `--render-history-output`: Output PNG file for history.

- `--cosmosdb-connection-string`: Cosmos DB connection string for Table API storage.

- `--cosmosdb-table-name`: Cosmos DB table name for metrics storage.

- `--cosmosdb-test-store`: Perform Cosmos DB store value test (value must be 0 or 1) and exit.

- `--cosmosdb-print-table`: Print all entries in the Cosmos DB table and exit.

- `--font-file`: Font file to use for PNG rendering (default: font.otf).

- `--use-session`: Use persistent HTTP session with keep-alive (default: false).



## License
This project is licensed under the GPLv3 license - see the LICENSE file for details.
