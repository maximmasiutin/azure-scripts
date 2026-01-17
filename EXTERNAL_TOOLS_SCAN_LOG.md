# External Tools Scan Log

## 2026-01-17 13:03 - create-192core-vm.ps1 Security Scan

### Trivy (v0.67.2)
- **Start:** 2026-01-17 13:03:23
- **Status:** Completed
- **Findings:** No vulnerabilities, secrets, or misconfigurations detected

### PSScriptAnalyzer
- **Start:** 2026-01-17 13:11
- **Status:** Completed
- **Findings:** 32 warnings (PSAvoidUsingWriteHost) - all are style warnings about using Write-Host

### detect-secrets (v1.5.45)
- **Start:** 2026-01-17 13:11:08
- **Status:** Completed
- **Findings:** 1 potential secret at line 30 - FALSE POSITIVE (example password in documentation comment)

## 2026-01-17 13:19 - All PowerShell Scripts Batch Scan

### Files Scanned
- set-storage-account-content-headers.ps1
- change-ip-to-static.ps1
- register-preview-features.ps1
- create-spot-vms.ps1

### Trivy (v0.67.2)
- **Start:** 2026-01-17 13:19:37
- **Status:** Completed
- **Findings:** All 4 files clean - no vulnerabilities, secrets, or misconfigurations

### PSScriptAnalyzer
- **Start:** 2026-01-17 13:19
- **Status:** Completed
- **Findings:** All 4 files passed with no warnings or errors (PSAvoidUsingWriteHost suppressed via attributes)

### detect-secrets (v1.5.45)
- **Start:** 2026-01-17 13:19
- **Status:** Completed
- **Findings:** 1 finding in create-spot-vms.ps1 at line 570 - FALSE POSITIVE (alphabet string for password generation)

### Manual Code Review - Issues Fixed
- **change-ip-to-static.ps1**: Removed dead code (lines 405-410) - `$Help` variable referenced but not defined in param block
- **create-192core-vm.ps1**: Removed dead code (line 88) - regex assignment immediately overwritten by subsequent if block

## 2026-01-17 13:35 - create-192core-vm.ps1 Enhancements

### Issues Fixed (from runtime testing)
1. **Double "Standard_" prefix**: VM size was showing as `Standard_Standard_D192s_v6`
   - Fixed by checking if VM size already has prefix before adding
2. **Restricted region selection**: Script selected `australiacentral2` which doesn't support VNets/quotas
   - Added exclusion list for restricted regions: australiacentral2, francesouth, germanynorth, norwaywest, southafricawest, switzerlandwest, uaecentral, westindia
3. **No progress indicator**: Script appeared hung during long API queries
   - Added spinner animation with elapsed time and ETA, updates every 5 seconds
