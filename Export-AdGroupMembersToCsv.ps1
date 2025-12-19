<#
.SYNOPSIS
Exports Active Directory groups and their members to a CSV file.

.DESCRIPTION
Writes one CSV row per (Group, Member) relationship. Optionally expands nested group
membership (recursive) and can include groups that have zero members.

Requires:
  - RSAT / ActiveDirectory PowerShell module
  - Sufficient permissions to read group/member objects

.PARAMETER OutputPath
CSV output file path.

.PARAMETER SearchBase
Distinguished Name of an OU/container to scope group search (optional).
Example: "OU=Groups,DC=contoso,DC=com"

.PARAMETER GroupFilter
LDAP-style filter used by Get-ADGroup -Filter (PowerShell AD filter syntax).
Default is "*" (all groups).
Examples:
  - "Name -like 'APP-*'"
  - "GroupCategory -eq 'Security'"

.PARAMETER Recursive
If set, expands nested group membership (Get-ADGroupMember -Recursive).

.PARAMETER IncludeEmptyGroups
If set, outputs a row for groups with no members (member fields blank).

.PARAMETER Server
Optional domain controller / AD Web Service endpoint.
Examples: "dc01.contoso.com" or "contoso.com"

.EXAMPLE
.\Export-AdGroupMembersToCsv.ps1 -OutputPath .\ad-group-members.csv

.EXAMPLE
.\Export-AdGroupMembersToCsv.ps1 -OutputPath .\app-groups.csv -SearchBase "OU=Groups,DC=contoso,DC=com" -GroupFilter "Name -like 'APP-*'" -Recursive
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath "ad-group-members.csv"),

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$SearchBase,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$GroupFilter = "*",

  [Parameter(Mandatory = $false)]
  [switch]$Recursive,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeEmptyGroups,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Server
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
  Import-Module ActiveDirectory -ErrorAction Stop
} catch {
  throw "ActiveDirectory module not found. Install RSAT / AD PowerShell module and re-run. Underlying error: $($_.Exception.Message)"
}

# Build common parameter splat for AD cmdlets
$adCommon = @{}
if ($PSBoundParameters.ContainsKey("Server")) {
  $adCommon["Server"] = $Server
}

Write-Verbose "Searching AD groups. Filter: [$GroupFilter] SearchBase: [$SearchBase]"

$getGroupsParams = @{
  Filter          = $GroupFilter
  ResultPageSize  = 500
  ResultSetSize   = $null
  Properties      = @("Description", "GroupCategory", "GroupScope", "ManagedBy", "Mail", "WhenCreated", "WhenChanged")
}
if ($PSBoundParameters.ContainsKey("SearchBase")) {
  $getGroupsParams["SearchBase"] = $SearchBase
}

$groups = Get-ADGroup @getGroupsParams @adCommon | Sort-Object -Property Name

if (-not $groups) {
  Write-Warning "No groups matched the provided filter/search base."
  return
}

# Overwrite output file if it exists
if (Test-Path -LiteralPath $OutputPath) {
  Remove-Item -LiteralPath $OutputPath -Force
}

$wroteHeader = $false
$total = @($groups).Count
$i = 0

foreach ($group in $groups) {
  $i++
  Write-Progress -Activity "Exporting group members" -Status "$i / $total : $($group.Name)" -PercentComplete ([int](($i / $total) * 100))

  $members = @()
  try {
    $members = Get-ADGroupMember -Identity $group.DistinguishedName -Recursive:$Recursive @adCommon
  } catch {
    # Keep going, but record the error as a row
    $errRow = [pscustomobject]@{
      GroupName               = $group.Name
      GroupSamAccountName     = $group.SamAccountName
      GroupDistinguishedName  = $group.DistinguishedName
      GroupCategory           = $group.GroupCategory
      GroupScope              = $group.GroupScope
      GroupMail               = $group.Mail
      GroupManagedBy          = $group.ManagedBy
      GroupWhenCreated        = $group.WhenCreated
      GroupWhenChanged        = $group.WhenChanged
      GroupDescription        = $group.Description

      MemberName              = $null
      MemberSamAccountName    = $null
      MemberObjectClass       = $null
      MemberDistinguishedName = $null

      Notes                   = "ERROR: $($_.Exception.Message)"
    }

    if (-not $wroteHeader) {
      $errRow | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
      $wroteHeader = $true
    } else {
      $errRow | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8 -Append
    }
    continue
  }

  if ((-not $members -or @($members).Count -eq 0) -and $IncludeEmptyGroups) {
    $row = [pscustomobject]@{
      GroupName               = $group.Name
      GroupSamAccountName     = $group.SamAccountName
      GroupDistinguishedName  = $group.DistinguishedName
      GroupCategory           = $group.GroupCategory
      GroupScope              = $group.GroupScope
      GroupMail               = $group.Mail
      GroupManagedBy          = $group.ManagedBy
      GroupWhenCreated        = $group.WhenCreated
      GroupWhenChanged        = $group.WhenChanged
      GroupDescription        = $group.Description

      MemberName              = $null
      MemberSamAccountName    = $null
      MemberObjectClass       = $null
      MemberDistinguishedName = $null

      Notes                   = "No members"
    }

    if (-not $wroteHeader) {
      $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
      $wroteHeader = $true
    } else {
      $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8 -Append
    }

    continue
  }

foreach ($member in $members) {
    $row = [pscustomobject]@{
      GroupName               = $group.Name
      GroupSamAccountName     = $group.SamAccountName
      GroupDistinguishedName  = $group.DistinguishedName
      GroupCategory           = $group.GroupCategory
      GroupScope              = $group.GroupScope
      GroupMail               = $group.Mail
      GroupManagedBy          = $group.ManagedBy
      GroupWhenCreated        = $group.WhenCreated
      GroupWhenChanged        = $group.WhenChanged
      GroupDescription        = $group.Description

      MemberName              = $member.Name
      MemberSamAccountName    = $member.SamAccountName
      MemberObjectClass       = $member.objectClass
      MemberDistinguishedName = $member.DistinguishedName

      Notes                   = $null
    }

    if (-not $wroteHeader) {
      $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
      $wroteHeader = $true
    } else {
      $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8 -Append
    }
  }
}

Write-Progress -Activity "Exporting group members" -Completed
Write-Host "Done. Wrote CSV to: $OutputPath"

