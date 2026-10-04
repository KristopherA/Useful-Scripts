<#
.SYNOPSIS
    Identify likely service accounts (and risky account settings) in Active Directory.

.DESCRIPTION
    Read-only LDAP sweep of a single AD domain using System.DirectoryServices
    (no RSAT / ActiveDirectory module required). Detections:
      - Name pattern (broad vendor/behavioral coverage; see $nameInner)
      - OU hint (OUs whose name contains "service account")
      - Description hint ("Service Account" in description)
      - sMSA (msDS-ManagedServiceAccount)
      - gMSA (msDS-GroupManagedServiceAccount)
      - dMSA (msDS-DelegatedManagedServiceAccount, Windows Server 2025+) with schema probe
      - User accounts with an SPN (Kerberoastable)
      - Unconstrained delegation (UAC TRUSTED_FOR_DELEGATION)
      - Password not required (UAC PASSWD_NOTREQD)
      - Kerberos pre-auth disabled (UAC DONT_REQ_PREAUTH, AS-REP roastable)
      - Reversible password encryption
      - AzureADSSOACC computer account (Seamless SSO)
    Extras:
      - Disabled users are excluded EXCEPT krbtgt and krbtgt_* (RODC / Entra Kerberos)
      - SensitiveGroups column: transitive membership in privileged groups, resolved
        by well-known SIDs/RIDs so it works in any AD language
      - Stats: total accounts + hits for SPN, no pre-auth, password not required,
        unconstrained delegation

    Scope: one domain only (the current domain by default, from RootDSE). It does
    not enumerate other domains in the forest.

    Name-based matching is intentionally broad (e.g. *test*, *temp*, *task*,
    *config*) and will produce false positives; treat results as leads to review.

.PARAMETER DomainDN
    Distinguished name of the domain to scan, e.g. "DC=example,DC=com".
    Defaults to the defaultNamingContext of the current domain.

.PARAMETER ExportCsv
    Also export results and stats to CSV.

.PARAMETER OutputDirectory
    Folder for CSV exports. Default: current directory.

.EXAMPLE
    .\Find-ServiceAccounts.ps1

.EXAMPLE
    .\Find-ServiceAccounts.ps1 -DomainDN "DC=example,DC=com" -ExportCsv -OutputDirectory C:\Reports

.NOTES
    Requirements: Windows PowerShell 5.1+ on a domain-joined machine, running as
    any authenticated domain user (read access to the directory).
#>
[CmdletBinding()]
param (
    [string]$DomainDN,
    [switch]$ExportCsv,
    [string]$OutputDirectory = "."
)

# Get domain base DN (parameter overrides RootDSE)
if ($DomainDN) {
    $domainDN = $DomainDN
} else {
    $root = [ADSI]"LDAP://RootDSE"
    $domainDN = [string]$root.defaultNamingContext
}
Write-Host "`n[*] Domain base DN: $domainDN"

# Common attributes
$attributes = @(
    "samaccountname","distinguishedname","whencreated",
    "pwdlastset","admincount","managedby","servicePrincipalName",
    "description","userAccountControl"
)

# UAC flags
$UAC_DISABLED                      =   2
$UAC_PASSWD_NOTREQD                =  32
$UAC_ENCRYPTED_TEXT_PWD_ALLOWED    = 128
$UAC_TRUSTED_FOR_DELEGATION        = 524288
$UAC_DONT_REQ_PREAUTH              = 4194304

# Results
$results = @()

# -------- Helper: safe property access ----------
function Get-PropValue {
    param(
        $props,
        [Parameter(Mandatory)][string]$name,
        [switch]$AsDateTimeFileTime
    )
    if (-not $props -or -not $props.Contains($name)) { return $null }
    $val = $props[$name][0]
    if ($AsDateTimeFileTime -and $val) {
        try { return [DateTime]::FromFileTime($val) } catch { return $null }
    }
    return $val
}

function Convert-LDAPResult {
    param ($entry)
    $p = $entry.Properties
    [PSCustomObject]@{
        sAMAccountName        = Get-PropValue $p 'samaccountname'
        WhenCreated           = [datetime](Get-PropValue $p 'whencreated')
        PwdLastSet            = Get-PropValue $p 'pwdlastset' -AsDateTimeFileTime
        AdminCount            = Get-PropValue $p 'admincount'
        ManagedBy             = Get-PropValue $p 'managedby'
        Description           = Get-PropValue $p 'description'
        DistinguishedName     = Get-PropValue $p 'distinguishedname'
        servicePrincipalName  = if ($p.Contains('serviceprincipalname')) { @($p['serviceprincipalname']) -join '; ' } else { $null }
        userAccountControl    = Get-PropValue $p 'useraccountcontrol'
        MatchReason           = $null
        SensitiveGroups       = ''   # filled later
    }
}

# -------- LDAP search helper (adds properties one by one; AddRange is unreliable) ----------
function Invoke-LdapSearch {
    param (
        [string]$filter,
        [string]$searchRoot = $domainDN,
        [string[]]$propsToLoad = $attributes
    )
    $searcher = New-Object DirectoryServices.DirectorySearcher
    $searcher.SearchRoot = "LDAP://$searchRoot"
    $searcher.Filter = $filter
    $searcher.PageSize = 1000
    $searcher.CacheResults = $false
    $searcher.ReferralChasing = "All"
    $searcher.PropertiesToLoad.Clear()
    foreach ($p in $propsToLoad) { [void]$searcher.PropertiesToLoad.Add($p) }
    $searcher.FindAll()
}

# Build a user filter that excludes disabled users, but always includes krbtgt and ANY krbtgt_*
function New-UserFilter {
    param([Parameter(Mandatory)][string]$Inner)
    $krbExceptions = '(|(sAMAccountName=krbtgt)(sAMAccountName=krbtgt_*))'
    "(&(objectCategory=person)(objectClass=user)(|(!(userAccountControl:1.2.840.113556.1.4.803:=2))$krbExceptions)$Inner)"
}

# Pipeline-friendly converter + tagger
function Convert-AndTag {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true)]
        $Entry,
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )
    process {
        if ($null -ne $Entry) {
            $obj = Convert-LDAPResult $Entry
            $obj.MatchReason = $Reason
            $script:results += $obj
        }
    }
}

# dMSA schema probe (Windows Server 2025+)
function Test-DMSASupport {
    try {
        $schemaNC = ([ADSI]"LDAP://RootDSE").schemaNamingContext
        $schemaSearcher = New-Object DirectoryServices.DirectorySearcher("LDAP://$schemaNC")
        $schemaSearcher.Filter = "(lDAPDisplayName=msDS-DelegatedManagedServiceAccount)"
        [void]$schemaSearcher.PropertiesToLoad.Add("lDAPDisplayName")
        $schemaSearcher.SearchScope = "Subtree"
        $hit = $schemaSearcher.FindOne()
        return ($null -ne $hit)
    } catch {
        return $false
    }
}

# ========== 1) Name-based detection ==========
Write-Host "`n[*] Running name-based detection..."

# Expanded patterns (case-insensitive by LDAP).
$nameInner = '(|' +
             # Baseline patterns and common org conventions
             '(sAMAccountName=svc_*)' +
             '(sAMAccountName=svc-*)' +
             '(sAMAccountName=ldap-*)' +
             '(sAMAccountName=ldap_*)' +
             '(sAMAccountName=_ldap*)' +
             '(sAMAccountName=srvc_*)' +
             '(sAMAccountName=sa_*)' +
             '(sAMAccountName=sa-*)' +
             '(sAMAccountName=app_*)' +
             '(sAMAccountName=_app*)' +
             '(sAMAccountName=MSOL_*)' +
             '(sAMAccountName=adsync*)' +
             '(sAMAccountName=srv_*)' +
             '(sAMAccountName=srv-*)' +
             '(sAMAccountName=_srv*)' +
             '(sAMAccountName=*_svc*)' +
             '(sAMAccountName=*backup*)' +
             '(sAMAccountName=*service*)' +
             '(sAMAccountName=*sysprep*)' +
             '(sAMAccountName=scom_*)' +
             '(sAMAccountName=_scom*)' +
             '(sAMAccountName=*sccm*)' +

             # SharePoint / SQL (both underscore and hyphen)
             '(sAMAccountName=SP_*)' +
             '(sAMAccountName=SP13_*)' +
             '(sAMAccountName=SP-*)' +
             '(sAMAccountName=SQL_*)' +
             '(sAMAccountName=SQL-*)' +

             # App stacks / infra identities / PAM
             '(sAMAccountName=adfs_*)' +
             '(sAMAccountName=pam_*)' +
             '(sAMAccountName=*cyberark*)' +
             '(sAMAccountName=*thycotic*)' +
             '(sAMAccountName=iis_*)' +

             # VMware / virtualization
             '(sAMAccountName=*vcenter*)' +
             '(sAMAccountName=*vmware*)' +
             '(sAMAccountName=*vcsa*)' +
             '(sAMAccountName=*nsxt*)' +
             '(sAMAccountName=*vrops*)' +
             '(sAMAccountName=*vrlcm*)' +
             '(sAMAccountName=*vpxd*)' +

             # EDR / monitoring / backup vendors
             '(sAMAccountName=*splunk*)' +
             '(sAMAccountName=*nessus*)' +
             '(sAMAccountName=*tenable*)' +
             '(sAMAccountName=*rapid7*)' +
             '(sAMAccountName=*insightvm*)' +
             '(sAMAccountName=*tanium*)' +
             '(sAMAccountName=*crowdstrike*)' +
             '(sAMAccountName=*falcon*)' +
             '(sAMAccountName=*carbonblack*)' +
             '(sAMAccountName=*sentinelone*)' +
             '(sAMAccountName=*veeam*)' +
             '(sAMAccountName=*rubrik*)' +
             '(sAMAccountName=*cohesity*)' +
             '(sAMAccountName=*mcafee*)' +
             '(sAMAccountName=*commvault*)' +
             '(sAMAccountName=*netbackup*)' +
             '(sAMAccountName=*qualys*)' +
             '(sAMAccountName=*solarwinds*)' +
             '(sAMAccountName=*quest*)' +
             '(sAMAccountName=*prtg*)' +
             '(sAMAccountName=*zabbix*)' +
             '(sAMAccountName=*nagios*)' +

             # Cloud / identity
             '(sAMAccountName=*azuread*)' +
             '(sAMAccountName=aad*)' +
             '(sAMAccountName=*okta*)' +
             '(sAMAccountName=duo*)' +
             '(sAMAccountName=o365_*)' +
             '(sAMAccountName=*sailpoint*)' +

             # Databases / enterprise middleware
             '(sAMAccountName=*oracle*)' +
             '(sAMAccountName=*database*)' +
             '(sAMAccountName=*tomcat*)' +
             '(sAMAccountName=*jboss*)' +
             '(sAMAccountName=*weblogic*)' +

             # Behavioral / workload-ish
             '(sAMAccountName=*restore*)' +
             '(sAMAccountName=*batch*)' +
             '(sAMAccountName=*task*)' +
             '(sAMAccountName=*config*)' +
             '(sAMAccountName=_install*)' +
             '(sAMAccountName=install_*)' +
             '(sAMAccountName=*integration*)' +
             '(sAMAccountName=*ingest*)' +
             '(sAMAccountName=*transfer*)' +
             '(sAMAccountName=*monitor*)' +
             '(sAMAccountName=*scanner*)' +
             '(sAMAccountName=*vulnscan*)' +
             '(sAMAccountName=*vulnscanner*)' +
             '(sAMAccountName=*print*)' +
             '(sAMAccountName=*printer*)' +
             '(sAMAccountName=*spool*)' +
             '(sAMAccountName=*proxy*)' +
             '(sAMAccountName=*gateway*)' +
             '(sAMAccountName=*temp*)' +
             '(sAMAccountName=*test*)' +
             '(sAMAccountName=*migrate*)' +
             ')'

$nameFilter = New-UserFilter -Inner $nameInner
Invoke-LdapSearch -filter $nameFilter | Convert-AndTag -Reason "Name pattern"

# ========== 2) OU-based detection ==========
Write-Host "`n[*] Scanning OUs for service-related names..."
$keywords = @("service account","service accounts","serviceaccounts")
$ouSearcher = New-Object DirectoryServices.DirectorySearcher
$ouSearcher.SearchRoot = "LDAP://$domainDN"
$ouSearcher.Filter = "(objectClass=organizationalUnit)"
$ouSearcher.PageSize = 1000
[void]$ouSearcher.PropertiesToLoad.Add("name")
[void]$ouSearcher.PropertiesToLoad.Add("distinguishedname")

$ouDNs = @()
foreach ($ou in $ouSearcher.FindAll()) {
    $name = $ou.Properties["name"][0]
    $dn = $ou.Properties["distinguishedname"][0]
    if ($keywords | Where-Object { $name -match $_ }) { $ouDNs += $dn }
}
Write-Host "[*] Found $($ouDNs.Count) matching OUs."
foreach ($ouDN in $ouDNs) {
    try {
        Write-Host "[*] Querying users in: $ouDN"
        $allUsersInOu = New-UserFilter -Inner "(cn=*)"
        Invoke-LdapSearch -filter $allUsersInOu -searchRoot $ouDN | Convert-AndTag -Reason "OU hint"
    } catch {
        Write-Warning "Failed to query OU: $ouDN"
        Write-Warning $_.Exception.Message
    }
}

# ========== 3) Description-based detection (USERS ONLY) ==========
Write-Host "`n[*] Looking for user accounts where description contains 'Service Account'..."
$descInnerUsers = '(|(description=*Service Account*)(description=*Service Accounts*))'
$descFilterUsers = New-UserFilter -Inner $descInnerUsers
Invoke-LdapSearch -filter $descFilterUsers | Convert-AndTag -Reason "Description hint"

# ========== 4) sMSA detection ==========
Write-Host "`n[*] Finding msDS-ManagedServiceAccount accounts..."
Invoke-LdapSearch -filter "(objectClass=msDS-ManagedServiceAccount)" | ForEach-Object {
    $p = $_.Properties
    $results += [PSCustomObject]@{
        sAMAccountName        = Get-PropValue $p 'samaccountname'
        WhenCreated           = [datetime](Get-PropValue $p 'whencreated')
        PwdLastSet            = Get-PropValue $p 'pwdlastset' -AsDateTimeFileTime
        AdminCount            = $null
        ManagedBy             = $null
        Description           = Get-PropValue $p 'description'
        DistinguishedName     = Get-PropValue $p 'distinguishedname'
        servicePrincipalName  = $null
        userAccountControl    = $null
        MatchReason           = "MSA"
        SensitiveGroups       = ''
    }
}

# ========== 5) gMSA detection ==========
Write-Host "`n[*] Finding msDS-GroupManagedServiceAccount accounts..."
Invoke-LdapSearch -filter "(objectClass=msDS-GroupManagedServiceAccount)" | ForEach-Object {
    $p = $_.Properties
    $results += [PSCustomObject]@{
        sAMAccountName        = Get-PropValue $p 'samaccountname'
        WhenCreated           = [datetime](Get-PropValue $p 'whencreated')
        PwdLastSet            = Get-PropValue $p 'pwdlastset' -AsDateTimeFileTime
        AdminCount            = $null
        ManagedBy             = $null
        Description           = Get-PropValue $p 'description'
        DistinguishedName     = Get-PropValue $p 'distinguishedname'
        servicePrincipalName  = $null
        userAccountControl    = $null
        MatchReason           = "gMSA"
        SensitiveGroups       = ''
    }
}

# ========== 6) dMSA detection ==========
Write-Host "`n[*] Finding Delegated Managed Service Account (dMSA) objects..."
$hasDmsaSchema = Test-DMSASupport
if (-not $hasDmsaSchema) {
    Write-Host "[*] dMSA not supported in this forest. Skipping."
} else {
    $dmsaFilter = "(|(objectClass=msDS-DelegatedManagedServiceAccount)(msDS-DelegatedMSAState=*))"
    $dmsaHits = Invoke-LdapSearch -filter $dmsaFilter
    if ($null -eq $dmsaHits -or $dmsaHits.Count -eq 0) {
        Write-Host "[*] No dMSA objects found."
    } else {
        Write-Host "[*] Found $($dmsaHits.Count) dMSA object(s)."
        $dmsaHits | ForEach-Object {
            $results += (Convert-LDAPResult $_ | ForEach-Object {
                $_.MatchReason = "dMSA"
                $_
            })
        }
    }
}

# ========== 7) Users with SPN ==========
Write-Host "`n[*] Finding user accounts with SPN..."
$spnInner = '(servicePrincipalName=*)'
$spnFilter = New-UserFilter -Inner $spnInner
Invoke-LdapSearch -filter $spnFilter -propsToLoad ($attributes + "servicePrincipalName") | Convert-AndTag -Reason "Has SPN"

# ========== 8) Users with UNCONSTRAINED DELEGATION ==========
Write-Host "`n[*] Finding user accounts with UNCONSTRAINED DELEGATION..."
$unconstrainedInner = "(userAccountControl:1.2.840.113556.1.4.803:=$UAC_TRUSTED_FOR_DELEGATION)"
$unconstrainedFilter = New-UserFilter -Inner $unconstrainedInner
Invoke-LdapSearch -filter $unconstrainedFilter | Convert-AndTag -Reason "Unconstrained delegation"

# ========== 9) Users with PASSWORD NOT REQUIRED ==========
Write-Host "`n[*] Finding user accounts with PASSWORD NOT REQUIRED..."
$pwdNotRequiredInner = "(userAccountControl:1.2.840.113556.1.4.803:=$UAC_PASSWD_NOTREQD)"
$pwdNotRequiredFilter = New-UserFilter -Inner $pwdNotRequiredInner
Invoke-LdapSearch -filter $pwdNotRequiredFilter | Convert-AndTag -Reason "Password not required"

# ========== 10) Users with KERBEROS PRE-AUTH DISABLED ==========
Write-Host "`n[*] Finding user accounts with Kerberos pre-authentication disabled..."
$noPreAuthInner = "(userAccountControl:1.2.840.113556.1.4.803:=$UAC_DONT_REQ_PREAUTH)"
$noPreAuthFilter = New-UserFilter -Inner $noPreAuthInner
Invoke-LdapSearch -filter $noPreAuthFilter | Convert-AndTag -Reason "Kerberos pre-auth disabled"

# ========== 11) Users with REVERSIBLE PASSWORD ENCRYPTION ==========
Write-Host "`n[*] Finding user accounts with password stored using reversible encryption..."
$revEncInner = "(userAccountControl:1.2.840.113556.1.4.803:=$UAC_ENCRYPTED_TEXT_PWD_ALLOWED)"
$revEncFilter = New-UserFilter -Inner $revEncInner
Invoke-LdapSearch -filter $revEncFilter | Convert-AndTag -Reason "Reversible password encryption"

# ========== 12) AzureADSSOACC computer account ==========
Write-Host "`n[*] Checking for AzureADSSOACC computer account..."
$aadSsoFilter = '(&(objectClass=computer)(|(sAMAccountName=AzureADSSOACC)(sAMAccountName=AzureADSSOACC$)))'
$aadSsoHits = Invoke-LdapSearch -filter $aadSsoFilter
if ($aadSsoHits -and $aadSsoHits.Count -gt 0) {
    Write-Host "[*] Found AzureADSSOACC computer account."
    $aadSsoHits | ForEach-Object {
        $results += (Convert-LDAPResult $_ | ForEach-Object {
            $_.MatchReason = "AzureADSSOACC"
            $_
        })
    }
} else {
    Write-Host "[*] AzureADSSOACC computer account not found."
}

# ========== Final Output (with language-agnostic SensitiveGroups via SIDs) ==========

# Build language-agnostic sensitive group SID map (once)
function Get-TargetSensitiveGroupSIDs {
    # Domain + root-domain SIDs
    $domainSid = (New-Object System.Security.Principal.SecurityIdentifier(
        ([ADSI]"LDAP://$domainDN").objectSid[0], 0)).Value

    $rootDomain = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().RootDomain
    $rootSid = (New-Object System.Security.Principal.SecurityIdentifier(
        $rootDomain.GetDirectoryEntry().objectSid[0], 0)).Value

    $builtinBase = 'S-1-5-32' # BUILTIN

    # Well-known RIDs (stable across languages)
    $sids = [ordered]@{
        'Domain Admins'          = "$domainSid-512"
        'Cert Publishers'        = "$domainSid-517"
        'Key Admins'             = "$domainSid-526"
        'Schema Admins'          = "$rootSid-518"
        'Enterprise Admins'      = "$rootSid-519"
        'Enterprise Key Admins'  = "$rootSid-527"
        'Account Operators'      = "$builtinBase-548"
        'Server Operators'       = "$builtinBase-549"
        'Print Operators'        = "$builtinBase-550"
        'Backup Operators'       = "$builtinBase-551"
    }

    # Groups without fixed RIDs: best-effort lookup by common English names
    $nameHints = @(
        'DnsAdmins','DHCP Administrators',
        'Organization Management','Exchange Windows Permissions','Exchange Trusted Subsystem'
    )
    foreach ($hint in $nameHints) {
        try {
            $ds = New-Object DirectoryServices.DirectorySearcher("LDAP://$domainDN")
            $ds.Filter = "(&(objectClass=group)(|(cn=$hint)(sAMAccountName=$hint)))"
            $ds.PageSize = 1
            [void]$ds.PropertiesToLoad.Add('objectSid')
            $hit = $ds.FindOne()
            if ($hit) {
                $sid = (New-Object System.Security.Principal.SecurityIdentifier($hit.Properties['objectsid'][0],0)).Value
                if (-not $sids.ContainsValue($sid)) { $sids[$hint] = $sid }
            }
        } catch {}
    }

    return $sids
}

$TargetGroupSIDs = Get-TargetSensitiveGroupSIDs

# 1) Deduplicate
$final = $results | Sort-Object -Property DistinguishedName -Unique

# 2) Enrich with transitive sensitive group membership using tokenGroups (SID-based)
function Get-SensitiveGroupsForDN {
    param([Parameter(Mandatory)][string]$DistinguishedName)

    try {
        $de = New-Object DirectoryServices.DirectoryEntry("LDAP://$DistinguishedName")
        $de.RefreshCache(@("tokenGroups"))
        $sidProps = $de.Properties["tokenGroups"]
        if (-not $sidProps) { return @() }

        $memberSids = foreach ($sidBytes in $sidProps) {
            try { (New-Object System.Security.Principal.SecurityIdentifier($sidBytes,0)).Value } catch { $null }
        }

        # Intersect tokenGroups with our target SIDs
        $hits = foreach ($kv in $TargetGroupSIDs.GetEnumerator()) {
            if ($memberSids -contains $kv.Value) { $kv.Key }
        }
        return $hits | Sort-Object -Unique
    } catch { return @() }
}

# Enrich in-place (guard for missing property)
foreach ($obj in $final) {
    $sg = Get-SensitiveGroupsForDN -DistinguishedName $obj.DistinguishedName

    if ($obj.PSObject.Properties.Match('SensitiveGroups').Count -eq 0) {
        $obj | Add-Member -NotePropertyName SensitiveGroups -NotePropertyValue '' -Force
    }
    $obj.SensitiveGroups = if ($sg) { $sg -join ', ' } else { '' }
}

Write-Host "`n[*] Total unique service accounts identified: $($final.Count)`n"

$final | Format-Table `
    sAMAccountName, WhenCreated, PwdLastSet, AdminCount, ManagedBy, `
    Description, DistinguishedName, servicePrincipalName, userAccountControl, MatchReason, SensitiveGroups -AutoSize

# ========== Stats (Hits only + total) ==========
$riskReasons = @(
    "Has SPN",
    "Kerberos pre-auth disabled",
    "Password not required",
    "Unconstrained delegation"
)

$grouped = $results |
    Where-Object { $riskReasons -contains $_.MatchReason } |
    Group-Object MatchReason

$stats = @(
    [PSCustomObject]@{ Category = "Total service accounts"; Hits = $final.Count }
)

$stats += foreach ($reason in $riskReasons) {
    $g = $grouped | Where-Object { $_.Name -eq $reason }
    [PSCustomObject]@{
        Category = $reason
        Hits     = if ($g) { $g.Count } else { 0 }
    }
}

Write-Host "`n[ Stats ]"
$stats | Format-Table Category, Hits -AutoSize
Write-Host ""

# ========== Optional CSV Export ==========
if ($ExportCsv) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $csvMain  = Join-Path $OutputDirectory "ServiceAccounts_$timestamp.csv"
    $csvStats = Join-Path $OutputDirectory "ServiceAccounts_Stats_$timestamp.csv"
    $final | Export-Csv -Path $csvMain -NoTypeInformation -Encoding UTF8
    $stats | Export-Csv -Path $csvStats -NoTypeInformation -Encoding UTF8
    Write-Host "[*] CSVs exported: $csvMain, $csvStats" -ForegroundColor Green
}
