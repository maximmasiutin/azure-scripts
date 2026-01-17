# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

A collection of Python, PowerShell, and Bash utilities for Azure cost optimization, monitoring, and infrastructure automation.

GEMINI.md and CLAUDE.md must be untracked. Do not add these files in any location to the repository.


## Scripts

**Python (cost/monitoring):**
- `vm-spot-price.py` - Find cheapest Azure regions for spot VMs
- `blob-storage-price.py` - Compare blob storage pricing across regions
- `monitor-eviction.py` - Handle Azure spot VM evictions gracefully
- `monitor-stddev.py` - Website health monitoring with statistical analysis (see monitor-stddev.md)

**PowerShell (infrastructure):**
- `change-ip-to-static.ps1` - Convert dynamic public IPs to static
- `create-spot-vms.ps1` - Automated spot VM deployment
- `create-192core-vm.ps1` - Create 192-core spot VM, auto-finds cheapest region/VM (x64 only, excludes ARM)
- `set-storage-account-content-headers.ps1` - Configure static website headers

**Bash (Linux VMs):**
- `azure-swap.bash` - Dynamic swap provisioning using Azure temporary storage

## Running Scripts

```bash
# VM spot pricing (single SKU) - ~1 page
python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"
python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2" --return-region

# VM spot pricing (multi-VM comparison) - ~1 page per VM size
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5,D4s_v5" --return-region

# Exclude specific regions or VM sizes
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions "centralindia,eastasia"
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions-file regions1.txt --exclude-regions-file regions2.txt
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-vm-sizes "D4pls_v5"

# Exclude by SKU pattern (# = digits wildcard)
python vm-spot-price.py --min-cores 4 --max-cores 64 --exclude-sku-patterns "D#ps_v6,D#pds_v6"

# Control number of results (default: 20)
python vm-spot-price.py --latest --cpu 64 --top 40   # Show top 40
python vm-spot-price.py --latest --cpu 64 --top 0    # Show all results

# Query all VM series (no series filter - API returns everything)
python vm-spot-price.py --all-vm-series --region eastus              # ~5 pages, all VMs in eastus
python vm-spot-price.py --all-vm-series --region eastus --cpu 4      # ~5 pages, filter to 4-core VMs
python vm-spot-price.py --all-vm-series --cpu 64                     # ~140 pages, all 64-core VMs
python vm-spot-price.py --all-vm-series --non-spot --region westus2  # ~5 pages, non-spot pricing

# Windows VMs (default is Linux) - 8-15% more expensive due to license fees
python vm-spot-price.py --windows --sku-pattern "B4s_v2"             # ~1 page, Windows spot pricing
python vm-spot-price.py --windows --cpu 64 --general-compute         # ~130 pages, 64-core Windows
python vm-spot-price.py --windows --all-vm-series --region eastus    # ~5 pages, all Windows in eastus

# PowerShell integration (--return-region outputs: "region vmsize")
# $result = python vm-spot-price.py --vm-sizes "D4pls_v5,F4s_v2" --return-region
# $region, $vmSize = $result -split ' '
# New-AzVM -Location $region -Size $vmSize -Priority Spot ...

# Blob storage pricing
python blob-storage-price.py
python blob-storage-price.py --blob-types "General Block Blob v2"

# Website monitoring
python monitor-stddev.py --url "https://example.com" --azure-blob-storage-connection-string "..." --azure-blob-storage-container-name '$web'
python monitor-stddev.py --url "https://example.com" --test  # Test URL connectivity before setting up monitoring

# Spot eviction monitoring
./monitor-eviction.py --stop-services nginx,postgresql --hook /path/to/script.sh
```

## Dependencies

**Python:** curl_cffi, tabulate, azure-storage-blob, azure-data-tables, Pillow

```bash
pip install curl_cffi tabulate azure-storage-blob azure-data-tables Pillow
```

Note: `curl_cffi` replaces `requests` for browser-like TLS fingerprinting (avoids Cloudflare bot detection).

**PowerShell:** Azure PowerShell module

## Security Scanning

Local: `S:\ProgramFiles\Utils\trivy.exe` (Version: 0.67.2)
CI: Trivy runs on push/PR via `.github/workflows/trivy-analysis.yaml`
- Don't use Bash to run other commands. We are under Windows.

## Python Static Analysis Tools

Location: `C:\Users\maxim\AppData\Local\Programs\Python\Python313\Scripts`

**Linters and Code Quality:**
- `bandit` (1.9.2) - Security linter for finding common security issues
- `ruff` (0.14.6) - Fast modern linter with auto-fix capabilities
- `flake8` (7.3.0) - Style guide enforcement (PEP 8)
- `pylint` (3.3.4) - Comprehensive code analysis (errors, style, code smells)
- `pycodestyle` (2.14.0) - Python style guide checker (PEP 8)
- `pyflakes` (3.4.0) - Simple program checker for Python source files

**Type Checking:**
- `mypy` (1.14.1) - Static type checker for Python

**Code Formatters:**
- `black` (24.10.0) - Opinionated code formatter
- `autopep8` (2.3.2) - Auto-formatter for PEP 8 compliance
- `isort` (6.0.0) - Import statement organizer

**Code Analysis:**
- `vulture` (2.14) - Dead code detector
- `radon` (6.0.1) - Code complexity analyzer (cyclomatic complexity, maintainability index)

**Additional Development Tools:**
- `CodeChecker` (6.26.2) - Source code analyzer framework
- `pygmentize` (Pygments 2.19.2) - Syntax highlighter
- `tabulate` (0.9.0) - Pretty-print tabular data
- `pip` (25.3) - Python package installer

## PHP Static Analysis Tools

Location: `S:\Composer\Bin`

**Linters and Code Quality:**
- `parallel-lint` (1.4.0) - Check syntax of PHP files in parallel
- `phpcs` (PHP_CodeSniffer 4.0.1) - Detect violations of coding standards
- `phpcbf` (PHP_CodeSniffer 4.0.1) - Automatically fix coding standard violations
- `phpmd` (2.15.0) - PHP Mess Detector - looks for potential problems
- `phplint` (9.6.3) - Validator and documentator for PHP files
- `phpmnd` (3.6.0) - PHP Magic Number Detector

**Type Checking and Static Analysis:**
- `psalm` (6.13.1) - Static analysis tool for finding errors in PHP applications
- `psalm-language-server` (6.13.1) - Language server protocol implementation for Psalm
- `psalm-plugin` (6.13.1) - Plugin system for Psalm
- `psalter` (6.13.1) - Automated refactoring tool for Psalm
- `psalm-refactor` (6.13.1) - Code refactoring tool (alias for psalter)
- `psalm-review` (6.13.1) - Review tool for Psalm

**Code Metrics:**
- `pdepend` (2.16.2) - Software metrics and quality measurement
- `phploc` (7.0.2) - Measure the size and analyze the structure of PHP projects
- `phpcpd` (6.0.3) - Copy/Paste Detector for PHP code

**Security:**
- `security-checker` (Enlightn 2.0.0) - Check for security vulnerabilities in dependencies

**Additional Tools:**
- `php-parse` (nikic/php-parser 5.6.2) - PHP parser written in PHP
- `yaml-lint` (Symfony YAML 7.4.0) - YAML file validator

## Code Style Guidelines

- Use ASCII characters only in all source files, documentation, and commit messages
- Use concise style - avoid verbose explanations
- No emojis in code or documentation

## Recent Changes (Last 30 Days)

**vm-spot-price.py:**
- Added `--vm-sizes` parameter for multi-VM comparison (comma-separated list)
- Auto-extracts series name from VM size (e.g., D4pls_v5 -> Dplsv5)
- `--return-region` now outputs "region vmsize price unit" format for PowerShell integration
- `--return-region-json` outputs JSON format for reliable PowerShell parsing (recommended)
- Progress output suppressed in --return-region mode for clean scripting
- Added `--exclude-regions` and `--exclude-regions-file` to filter out regions (file option can be specified multiple times)
- Added `--exclude-vm-sizes` and `--exclude-vm-sizes-file` to filter out VM sizes
- Exclusion files support comments (lines starting with #)
- **ARM VM Support**: Added `is_arm_vm()` function to detect ARM-based VMs (D4ps_v5, D4pls_v5, etc.)
- ARM VMs skip productName API filter (uses different naming in Azure) with client-side Windows filtering
- Added `--exclude-arm` parameter to exclude ARM VMs from results
- **SKU Pattern Exclusion**: Added `--exclude-sku-patterns` and `--exclude-sku-patterns-file` to exclude VM sizes by pattern (# = digits wildcard, e.g., "D#ps_v6" excludes D4ps_v6, D8ps_v6, etc.)
- **Single-Query Mode**: Per-core search now uses single API call with client-side filtering. Triggered by `--no-burstable`, `--burstable-only`, `--general-compute`, `--latest`, or `--min-cores`/`--max-cores`. Multi-query mode used only for explicit `--series`.
- **Filter Flags Trigger Per-Core Mode**: `--no-burstable`, `--burstable-only`, `--general-compute`, `--latest` now trigger per-core mode even without `--min-cores`/`--max-cores`. Uses `--cpu` as exact core count.
- **Logging Default**: Changed default log level from DEBUG to WARNING. Use `--log-level DEBUG` to enable debug output.
- Added `--top` parameter to control number of results displayed (default: 20, use 0 for all results)
- Added `--show-deprecation-warnings` to show library deprecation warnings (suppressed by default)
- **All VM Series Mode**: Added `--all-vm-series` parameter to query API without any VM series filters. Only region and spot/non-spot filters are sent to API. Use `--cpu` for client-side core count filtering. Useful for discovering what VM types the API returns without predefined series constraints.
- **Windows VM Support**: Added `--windows` parameter to search for Windows VMs instead of Linux (default). Windows VMs cost ~8-10% more due to license fees.

**blob-storage-price.py:**
- Major security improvements: input validation, SSL verification, error handling
- Enhanced logging capabilities

**change-ip-to-static.ps1:**
- Security hardening with input validation and improved error handling

**monitor-stddev.py:**
- Added `--test` option to verify URL connectivity and detect Cloudflare/CAPTCHA blocking before starting monitoring
- User-agent header handling improvements (strip prefix if exists)
- Code refactoring and minor fixes

**monitor-eviction.py:**
- Simplified eviction handling function
- Minor code fixes

**create-spot-vms.ps1:**
- Refactored to be fully generic (removed Fishtest-specific logic)
- Added `-RequestQuota` switch to automatically attempt quota increases via Azure Support API (with version fallback)
- Added `-CustomData` parameter for passing cloud-init scripts
- Added `-InitScriptUrl` for downloading init scripts
- Added `-NoPublicIP` switch (defaults to creating a public IP now)
- Added `-UseNatGateway` switch (defaults to false)
- Added `-BlockSSH` switch (creates NSG but blocks inbound 22)
- Implemented cryptographically strong password generation (28 chars, alphanumeric + -_)
- Returns generated password in result object
- **Full ARM64 Support**: Auto-detects ARM VMs and uses ARM64 Ubuntu images
- Added `-UseLTS` and `-PreferServer` switches for image selection
- **Public IP Quota Check**: Pre-flight check for Standard Public IP quota (default limit: 20/region)
- Expanded `Get-VMFamilyName` with comprehensive VM family patterns (D/F/B/E series, v5/v6/v7, Intel/AMD/ARM)
- **Orphan IP Cleanup**: Added `Remove-OrphanedPublicIPs` function and `-CleanupOrphans` switch
- **Smart Retry Logic**: Differentiates quota errors (stop immediately) from propagation errors (retry with delay)
- **Request-PublicIPQuotaIncrease**: Programmatic IP quota increase via Azure Quota REST API
- **Feature Flag Detection**: Detects VM sizes requiring feature flag registration (preview/restricted SKUs like v7 series) and returns `FeatureFlagRequired=true` and `UnsupportedVMSize=true` in result object
- **Orphaned Disk Cleanup**: Automatically deletes orphaned OS disks before VM creation to prevent `PropertyChangeNotAllowed` errors when security type differs (TrustedLaunch vs Standard)
- **Security Type Conflict Handling**: Detects `securityProfile.securityType` conflict errors, cleans up disk, and retries automatically
- **Infrastructure-Only Mode**: Added `-CreateInfrastructureOnly` switch (requires `-UseNatGateway`). Creates only shared infrastructure (RG, VNet, Subnet, NAT Gateway) without any VMs. Returns JSON with resource details for orchestration. Useful for multi-worker setups where infrastructure should be created once before spawning parallel workers.
- **Race Condition Handling**: NAT Gateway creation catch block now checks if gateway was created by concurrent worker (handles `CanceledAndSupersededDueToAnotherOperation` error gracefully)
- **Environment Variable Support for Credentials**: Added support for environment variables as fallback for credentials:
  - `AZURE_VM_USERNAME` or `AZURE_ADMIN_USERNAME` for admin username
  - `AZURE_VM_PASSWORD` or `AZURE_ADMIN_PASSWORD` for admin password
  - `AZURE_SSH_PUBLIC_KEY` for SSH public key
- Command line parameters take precedence over environment variables

**create-192core-vm.ps1:**
- PowerShell script for creating 192-core Spot VMs with SSH enabled
- Automatically finds cheapest 192-core VM and region using vm-spot-price.py
- Pre-checks spot quota in 40 major regions BEFORE running pricing API query (saves time by excluding regions without quota)
- Excludes ARM VMs (x64 only)
- Excludes restricted regions: paired/DR regions (australiacentral2, francesouth, germanynorth, etc.) and Azure Extended Zones city names (portland, losangeles, seattle, etc.)
- Progress indicator with spinner, elapsed time, and ETA during pricing API query
- Handles VM size prefix correctly (prevents double "Standard_" prefix)
- Requires three environment variables (exits with error if missing):
  - `AZURE_SSH_PUBLIC_KEY` - SSH public key
  - `AZURE_VM_USERNAME` - Admin username
  - `AZURE_VM_PASSWORD` - Admin password
- Parameters: `-VMName`, `-Location`, `-VMSize`, `-MinCores`, `-MaxCores`, `-ResourceGroupName`, `-WhatIf`
- Usage: `pwsh create-192core-vm.ps1 [-VMName myvm] [-Location eastus] [-VMSize Standard_E192as_v5]`

**Azure Extended Zones Note:**
The Azure Retail Prices API returns armRegionName values that include both standard Azure region IDs (eastus, westus2) and Azure Extended Zone metro locations (losangeles, portland, phoenix). Extended Zones are small-footprint Azure extensions in metropolitan areas for low-latency workloads. Currently only Los Angeles and Perth are GA. These city names are NOT valid for standard ARM operations (resource groups, VNets, VMs), so create-192core-vm.ps1 filters them out to ensure only valid region IDs are used.

**create-192core-vm.cmd:**
- Simple batch wrapper for create-192core-vm.ps1
- Usage: `create-192core-vm.cmd [vmname] [location] [vmsize]`

**preview-vm-exclusions.txt:**
- New exclusion file for VM sizes requiring feature flag registration
- Includes AMD v7 series (D#als_v7, D#as_v7, F#als_v7, etc.) which require Microsoft.Compute/DALV7Series
- Use with: `--exclude-sku-patterns-file preview-vm-exclusions.txt`

**fishtest-spot-orchestrator.ps1 (linux-fishtest-scripts):**
- Updated to use `--return-region-json` for reliable JSON parsing
- Added `Test-PublicIPQuota` function to check Standard Public IP quota
- `Get-AllSpotQuotas` now shows both Spot vCPU and Public IP quotas side-by-side
- IP quota warning in `Find-CheapestSpotVM` before VM creation attempt
- Expanded `Get-VMFamilyName` with comprehensive VM family patterns
- **Orphan IP Cleanup**: Added `Remove-OrphanedPublicIPs` function, runs at start of each cycle
- **IP Quota Blacklisting**: Regions with no available IPs are added to blacklist

**Other:**
- Fixed typo in .gitattributes (badh -> bash)
- Updated documentation in monitor-stddev.md and README.md

## Repository Structure Notes

**Untracked Directories and Files:**
The following items are intentionally untracked in this repository:
- `azure-scripts-reports/` - This is a separate git repository cloned into this directory for storing analysis reports. It is a different repository than azure-scripts and should remain untracked.
- `CLAUDE.md` - Project-specific AI assistant instructions (this file)
- `GEMINI.md` - Project-specific AI assistant instructions
- `.claude/` - AI assistant configuration
- `run-gemini-apikey.cmd` - Local API key configuration
- `example-run.cmd` - Local example configuration
- `.scannerwork/` - SonarQube scanner working directory