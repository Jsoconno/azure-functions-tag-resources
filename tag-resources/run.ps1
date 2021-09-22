param($eventGridEvent, $TriggerMetadata)

function Test-TagUpdate {
    param(
        $ResourceID
    )

    $Tag = @{"Test" = "Test"}

    try {
        Update-AzTag -ResourceId $ResourceID -Operation Merge -Tag $Tag -ErrorAction SilentlyContinue
        $Resource = Get-AzResource -ResourceId $ResourceID -ErrorAction SilentlyContinue
        $Resource.ForEach{
            if ($_.Tags.ContainsKey("Test")) {
                $_.Tags.Remove("Test")
            }
            $_ | Set-AzResource -Tags $_.Tags -ErrorAction SilentlyContinue -Force
        }
        Get-AzTag -ResourceId $ResourceID
        Remove-AzTag -Name "Test"
        Return "Pass"
    } catch {
        Write-Host $Error[0]
        Return "Fail"
    }
}

function Get-ParentResourceId {
    param(
        $ResourceID
    )

    $ResourceIDList = $ResourceID -Split '/'
    $IgnoreList = @('subscriptions', 'resourceGroups', 'providers')

    for ($ia=$ResourceIDList.length-1; $ia -ge 0; $ia--) {
        $CurrentResourceIDList = $ResourceIDList[0..($ia)]
        $CurrentResourceID = $CurrentResourceIDList -Join '/'
        $CurrentHead = $CurrentResourceIDList[-1]
        if (!($IgnoreList -Contains $CurrentHead)) {
            Write-Host "Trying to get tags for $($CurrentResourceID)" 
            try {
                $Tags = Get-AzTag -ResourceId $CurrentResourceID -ErrorAction silentlycontinue
                if ($Null -ne $Tags) {
                    Write-Host "Found tags for resource $($CurrentResourceID)"
                    try {
                        $TestResult = Test-TagUpdate -ResourceId $CurrentResourceID
                        if ($TestResult -eq "Pass") {
                            Break
                        }
                    } catch {
                        "Test for tagging resource failed: $CurrentResourceID.  Continuing search."
                    }
                }
            } catch {
                Write-Host $Error[0]
                Write-Host "$($CurrentResourceID) cannot be tagged.  Searching for parent."
            }
        } else {
            Write-Host "Skipping $($CurrentResourceID)"
        }
    }

    Return $CurrentResourceID
}

$caller = $eventGridEvent.data.claims.name
$lastOperation = $eventGridEvent.data.authorization.action

if ($null -eq $caller) {
    if ($eventGridEvent.data.authorization.evidence.principalType -eq "ServicePrincipal") {
        $caller = (Get-AzADServicePrincipal -ObjectId $eventGridEvent.data.authorization.evidence.principalId).DisplayName
        if ($null -eq $caller) {
            Write-Host "MSI may not have permission to read the applications from the directory"
            $caller = $eventGridEvent.data.authorization.evidence.principalId
        }
    }
}

# Write-Host "Authorization Action: $($eventGridEvent.data.authorization.action)"
Write-Host "Authorization Scope: $($eventGridEvent.data.authorization.scope)"
Write-Host "Operation Name: $lastOperation"
Write-Host "Caller: $caller"
$resourceId = $eventGridEvent.data.resourceUri
Write-Host "ResourceId: $resourceId"

if (($null -eq $caller) -or ($null -eq $resourceId)) {
    Write-Host "ResourceId or Caller is null"
    exit;
}

$ignore = @("providers/Microsoft.Resources/deployments", "providers/Microsoft.Resources/tags")

foreach ($case in $ignore) {
    if ($resourceId -match $case) {
        Write-Host "Skipping event as resourceId contains: $case"
        exit;
    }
}

# Get first taggable resource
$resourceId = Get-ParentResourceId -ResourceId $resourceId

$tags = (Get-AzTag -ResourceId $resourceId).Properties

if (-not ($tags.TagsProperty.ContainsKey('CreatedBy')) -or ($null -eq $tags)) {
    $tag = @{
        CreatedBy = $caller;
        CreatedDate = $(Get-Date);
        LastOperation = $lastOperation;
    }
    Update-AzTag -ResourceId $resourceId -Operation Merge -Tag $tag
    Write-Host "Added CreatedBy tag with user: $caller"
}
else {
    Write-Host "Tag already exists"
    $tag = @{
        LastModifiedBy = $caller;
        LastModifiedDate = $(Get-Date);
        LastOperation = $lastOperation;
    }
    Update-AzTag -ResourceId $resourceId -Operation Merge -Tag $tag
    Write-Host "Added or updated ModifiedBy tag with user: $caller"
}