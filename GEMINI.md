# GEMINI.md

This file provides guidance when working with code in this repository.

## Repository Overview

GEMINI.md and CLAUDE.md must be untracked. Do not add these files in any location to the repository.

A collection of Python, PowerShell, and Bash utilities for Azure cost optimization, monitoring, and infrastructure automation.

## Scripts

**Python (cost/monitoring):**
- `vm-spot-price.py` - Find cheapest Azure regions for spot VMs
- `blob-storage-price.py` - Compare blob storage pricing across regions
- `monitor-eviction.py` - Handle Azure spot VM evictions gracefully
- `monitor-stddev.py` - Website health monitoring with statistical analysis (see monitor-stddev.md)

**PowerShell (infrastructure):**
- `change-ip-to-static.ps1` - Convert dynamic public IPs to static
- `create-spot-vms.ps1` - Automated spot VM deployment
- `set-storage-account-content-headers.ps1` - Configure static website headers

**Bash (Linux VMs):**
- `azure-swap.bash` - Dynamic swap provisioning using Azure temporary storage

## Running Scripts

```bash
# VM spot pricing (single SKU)
python vm-spot-price.py --cpu 4 --sku-pattern "B#s_v2"
python vm-spot-price.py --sku-pattern "B4ls_v2" --series-pattern "Bsv2" --return-region

# VM spot pricing (multi-VM comparison - find cheapest across multiple sizes)
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5,F4s_v2,D4as_v5,D4s_v5" --return-region

# Exclude specific regions or VM sizes
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions "centralindia,eastasia"
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-regions-file regions1.txt --exclude-regions-file regions2.txt
python vm-spot-price.py --vm-sizes "D4pls_v5,D4ps_v5" --exclude-vm-sizes "D4pls_v5"

# PowerShell integration (--return-region outputs: "region vmsize")
# $result = python vm-spot-price.py --vm-sizes "D4pls_v5,F4s_v2" --return-region
# $region, $vmSize = $result -split ' '
# New-AzVM -Location $region -Size $vmSize -Priority Spot ...

# Blob storage pricing
python blob-storage-price.py
python blob-storage-price.py --blob-types "General Block Blob v2"

# Website monitoring
python monitor-stddev.py --url "https://example.com" --azure-blob-storage-connection-string "..." --azure-blob-storage-container-name '$web'
python monitor-stddev.py --url "https://example.com" --test

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

**create-spot-vms.ps1:**
- Major update with enhanced reliability and features
- Added automatic Azure Support ticket creation for spot quota increases (`-RequestQuota`)
- Added support for custom cloud-init data (`-CustomData`) and initialization scripts (`-InitScriptUrl`)
- Added Network Security Group (NSG) management with SSH blocking option (`-BlockSSH`)
- Added support for NAT Gateway (`-UseNatGateway`) and public IP opt-out (`-NoPublicIP`)
- Improved password generation (cryptographically strong) if not provided

**azure-swap.bash:**
- Renamed from `azure_swap_fixed.bash` to `azure-swap.bash`
- Code cleanup and variable standardization
- Improved comments and documentation

**vm-spot-price.py:**
- Added `--vm-sizes` parameter for multi-VM comparison (comma-separated list)
- Auto-extracts series name from VM size (e.g., D4pls_v5 -> Dplsv5)
- `--return-region` now outputs "region vmsize" format for PowerShell integration
- Progress output suppressed in --return-region mode for clean scripting
- Added `--exclude-regions` and `--exclude-regions-file` to filter out regions (file option can be specified multiple times)
- Added `--exclude-vm-sizes` and `--exclude-vm-sizes-file` to filter out VM sizes
- Exclusion files support comments (lines starting with #)

**blob-storage-price.py:**
- Major security improvements: input validation, SSL verification, error handling
- Enhanced logging capabilities

**change-ip-to-static.ps1:**
- Security hardening with input validation and improved error handling

**monitor-stddev.py:**
- Added `--test` argument to verify URL connectivity and detect Cloudflare/CAPTCHA blocking
- Improved User-agent header handling (strip prefix if exists)
- Code refactoring and minor fixes

**monitor-eviction.py:**
- Simplified eviction handling function
- Minor code fixes

**Other:**
- Fixed typo in .gitattributes (badh -> bash)
- Updated documentation in monitor-stddev.md and README.md

## Repository Structure Notes

**Untracked Directories and Files:**
The following items are intentionally untracked in this repository:
- `azure-scripts-reports/` - This is a separate git repository cloned into this directory for storing analysis reports. It is a different repository than azure-scripts and should remain untracked.
- `CLAUDE.md` - Project-specific AI assistant instructions
- `GEMINI.md` - Project-specific AI assistant instructions (this file)
- `.claude/` - AI assistant configuration
- `run-gemini-apikey.cmd` - Local API key configuration
- `example-run.cmd` - Local example configuration
- `.scannerwork/` - SonarQube scanner working directory
