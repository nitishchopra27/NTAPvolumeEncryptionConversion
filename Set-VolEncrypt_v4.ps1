<#
.SYNOPSIS
  This script automates volume encryption conversion process
.DESCRIPTION
  This script performs the following tasks:
  Get list of nodes in a cluster
  Parse through each node and gets count of active encryption conversion jobs on each node
  If number of volumes being encrypted on this node are 4, then move to another node
  Else start additional encryption jobs on this node
  Save the logs in a log file
.PARAMETER clusterName
  This script takes cluster name as a parameter for -clusterName
.NOTES
  Version:        4.0
  Author:         Nitish Chopra
  Creation Date:  31/10/2019
  Purpose/Change: Automate volume encryption conversion process
.EXAMPLE
  Run the script and provide an input
  
  .\Set-VolEncrypt_v4.ps1 -clusterName 192.168.0.21
  .\Set-VolEncrypt_v4.ps1 -clusterName snowy
#>
#---------------------------------------------------------[Script Parameters]------------------------------------------------------
[CmdletBinding()]
Param (
  [Parameter(Mandatory=$True,ValueFromPipeLine=$True,ValueFromPipeLineByPropertyName=$True,HelpMessage="NetApp storage cluster name/Ip addr")]
  [string]$clusterName
)
#-----------------------------------------------------------[Functions]------------------------------------------------------------
function Check-LoadedModule {
  Param(
    [parameter(Mandatory = $true)]
    [string]$ModuleName
  )
  Begin {
    Write-Log -Message "*** Importing Module: $ModuleName"
  }
  Process {
    $LoadedModules = Get-Module | Select Name
    if ($LoadedModules -notlike "*$ModuleName*") {
      try {
        Import-Module -Name $ModuleName -ErrorAction Stop
      }
      catch {
        Write-Log -Message "Could not find the Module on this system. Error importing Module" -Severity Error
        Break
      }
    }
  }
  End {
    If ($?) {
      Write-Log -Message "Module $ModuleName is imported Successfully" -Severity Success
    }
  }
}
function Connect-Cluster {
  Param (
    [parameter(Mandatory = $true)]
    [string]$strgCluster
  )
  Begin {
    Write-Log -Message "*** Connecting to storage cluster $strgCluster"
  }
  Process {
    try {
      Add-NcCredential -Name $strgCluster -Credential $ControllerCredential
      Connect-nccontroller -Name $strgCluster -HTTPS -Timeout 600000 -ErrorAction Stop | Out-Null
    }
    catch {
      Write-Log -Message "Failed Connecting to Cluster $strgCluster : $_." -Severity Error
      Break
    }
  }
  End {
    If ($?) {
      Write-Log -Message  "Connected to $strgCluster" -Severity Success
    }
  }
}
function Write-Log {
  [CmdletBinding()]
  Param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Message,
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('Information','Success','Error')]
    [string]$Severity = 'Information'
  )
  Process {
    [pscustomobject]@{
    #"Time" = (Get-Date -f g);
    "Severity" = $Severity;
    "Message" = $Message;
    } | Export-Csv -Path $scriptLogPath -Append -NoTypeInformation
  }
}
function StartEncrypt {
    [CmdletBinding()]
    Param(
    [Parameter(Mandatory=$True, HelpMessage="The vserver name")]
    [String]$VserverName,
    [Parameter(Mandatory=$True, HelpMessage="The volume name")]
    [String]$VolumeName
    )
    #'------------------------------------------------------------------------------
    #'Encrypt the volume
    #'------------------------------------------------------------------------------
    Try{
    $command  = @("volume", "encryption", "conversion", "start", "-vserver", $VserverName, "-volume", $VolumeName)
    $api      = $("<system-cli><args><arg>" + ($command -join "</arg><arg>") + "</arg></args></system-cli>")
    $output   = Invoke-NcSystemApi -Request $api -ErrorAction Stop
    Write-Log -Message $("Executed Command`: " + $([String]::Join(" ", $command))) -Severity Information
    }
    Catch{
    Write-Log -Message $("Failed Executing Command`: $command. Error " + $_.Exception.Message) -Severity Error
    Throw "Failed Encrypting volume ""$VolumeName"" on vserver ""$VserverName"""  
    }
    $output
}
#----------------------------------------------------------[Declarations]----------------------------------------------------------
#Any Global Declarations go here
[String]$scriptPath     = $PSScriptRoot
[String]$logName        = "Set_VolEncrypt_log.csv"
[String]$scriptLogP     = $scriptPath + "\Logs"
[String]$scriptLogPath  = $scriptPath + "\Logs\" + (Get-Date -uformat "%Y-%m-%d-%H-%M") + "-" + $logName
#---------------------------------------------------------[Initialisations]--------------------------------------------------------
#Set Error Action to Silently Continue
$ErrorActionPreference = 'SilentlyContinue'
[String]$username = 'admin'
[String]$password = ''
$ssPassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$ControllerCredential = New-Object System.Management.Automation.PsCredential($username,$ssPassword)
#-----------------------------------------------------------[Execution]------------------------------------------------------------
# Create Log Directory
if ( -not (Test-Path $scriptLogP) ) {
  Try{
    New-Item -Type directory -Path $scriptLogP -ErrorAction Stop | Out-Null
  }
  Catch{
    Exit -1;
  }
}
Write-Log -Message "Start Execution of script to encrypt volumes" -Severity Information

#Import Module DataONTAP
Check-LoadedModule DataONTAP
# Connect to the storage cluster
Connect-Cluster $clusterName
# Get nodes in the cluster
try {
    [string]$getNodes = "(Get-NcNode).Node"
    $nodes = Invoke-Expression $getNodes -ErrorAction Stop
    Write-Log -Message "Executed Command`: $getNodes" -Severity Success
}
catch {
    Write-Log -Message $("Failed Executing Command`: $getNodes. Error " + $_.Exception.Message) -Severity Error
}
# Parse through each node
$nodes | % {
    Write-Log -Message "------------------------------------------------------------------------------------------"
    $node = $_
    Write-Log -Message "Running Encryption queries for Node`: $node" -Severity Information
    $activeEncJobs = $null
    $remainingActJobs = $null
    # get count of active encryption conversion jobs on this node
    try {
        # create a hash table with node and volume as (Name, Value), group-by node
        $encattribs = Get-NcVol -Template
        Initialize-NcObjectProperty $encattribs VolumeIdAttributes

        # empty hash table
        $volEmptyHash = @{}
        
        # populate hash table with volume name and hosting Node name
        [string]$encJobs11 = 'Get-NcVolumeEncryptionConversion |'
        $encJobs11 += ' %{$volEmptyHash.Add($_.Name, '
        $encJobs11 += '((Get-NcVol -Volume $_.Name -Attributes $encattribs).VolumeIdAttributes).Node)}'
        Get-NcVolumeEncryptionConversion | %{$volEmptyHash.Add($_.Volume, `
            ((Get-NcVol -Volume $_.Volume -Attributes $encattribs).VolumeIdAttributes).Node)}
        Write-Log -Message "Executed Command`: $encJobs11" -Severity Success

        # change the hash table column names to 'Volume' and 'Node'
        [string]$encJobs12 = '$volEmptyHash = $volEmptyHash.keys | select @{n=''Volume'';e={$_}},@{n=''Node'';e={$volEmptyHash.$_}}'
        $volEmptyHash = $volEmptyHash.keys | select @{n='Volume';e={$_}},@{n='Node';e={$volEmptyHash.$_}}
        Write-Log -Message "Executed Command`: $encJobs12" -Severity Success

        # get the volumes encrypting at this time grouped by 'Node' volumn
        [string]$encJobs14 = '$volumesEnc = $volEmptyHash | Group-Object Node -AsHashTable -AsString'
        $volumesEnc = $volEmptyHash | Group-Object Node -AsHashTable -AsString
        Write-Log -Message "Executed Command`: $encJobs14" -Severity Success

        # Count the volumes on this node where encryption job is running
        [string]$encJobs15 = '$volEncInfo = $volEmptyHash | Group-Object Node'
        $volEncInfo = $volEmptyHash | Group-Object Node
        Write-Log -Message "Executed Command`: $encJobs15" -Severity Success

        $activeEncJobs = ($volEncInfo | Where-Object { $_.Name -like "*$node*"}).Count
        Write-Log -Message "$node is running`: $($volumesEnc.$node.Volume.count) : encryption jobs" -Severity Information
    }
    catch {
        Write-Log -Message $("Failed Executing Command`: $encJobs11. Error " + $_.Exception.Message) -Severity Error
    }
    # if number of volumes being encrypted on this node are 4, then move to another node
    if ($activeEncJobs -eq 4) {
        Write-Log -Message "Can't start new jobs on node $node. Already $activeEncJobs jobs are running" -Severity Information
    }
    # else start additional encryption jobs on this node
    else {
        $remainingActJobs = 4 - $activeEncJobs
        Write-Log -Message "Going to start $remainingActJobs encryption jobs on $node" -Severity Success
        try {
            # get the list of volumes which are not encrypted
            $volattribss = Get-NcVol -Template
            Initialize-NcObjectProperty $volattribss -Name VolumeIdAttributes
            [string]$volumesCmd = "Get-NcVol -Query @{VolumeIdAttributes=@{Node=""$node""};"
            $volumesCmd += 'Encrypt=$false;Name="!*root*";VolumeStateAttributes=@{IsNodeRoot=$false}}'
            $volumesCmd += " -Attributes $volattribss | Sort-Object -Property Aggregate"
            $volumes = Get-NcVol -Query @{VolumeIdAttributes=@{Node="$node"};`
                       Encrypt=$false;Name="!*root*";VolumeStateAttributes=@{IsNodeRoot=$false}}`
                       -Attributes $volattribss | Sort-Object -Property Aggregate
            Write-Log -Message "Executed command`: $volumesCmd" -Severity Success
        }
        catch {
            Write-Log -Message $("Failed Executing Command`: $volumesCmd. Error " + $_.Exception.Message) -Severity Error
        }
        # if volumes to be encrypted are more than 0, encrypt them
        if ($volumes.count -gt 0) {
         # if current running encryption jobs are more than 0
         # get the unique volumes in arrays (volumes that are not encrypted), (volumes that are encrypting)
         # start encryption jobs
         if ($($volumesEnc.$node.Volume.count) -ne 0) {
            # list of volumes that are not running encryption job
            [string]$volListJoin = $null
            [string]$volListCmd = "Compare-Object -ReferenceObject $($volumes.Name)"
            $volListCmd += " -DifferenceObject $($volumesEnc.$node.Volume) -PassThru"
            $volumesList = Compare-Object -ReferenceObject $($volumes.Name) -DifferenceObject $($volumesEnc.$node.Volume) -PassThru
            $volumesRem = $volumesList | Select-Object -First $remainingActJobs
            $volListJoin = $volumesRem -join " ; "
            Write-Log -Message "Encryption jobs will be run on following volumes`: $volListJoin" -Severity Information
            # start encryption job
            $volumesRem | ForEach-Object {
                $vol = $_
                $vsv = $(($volumes | where-object {$($_.Name) -like $vol}).Vserver)
                StartEncrypt -VserverName $vsv -VolumeName $($vol)
            }
         }
         # if the current running encryption jobs are 0, select volumes and run encryption jobs
         else {
            [string]$volListJoin = $null
            $volumesRem = $volumes | Select-Object -First $remainingActJobs
            $volListJoin = $volumesRem -join " ; "
            Write-Log -Message "Encryption jobs will be run on following volumes`: $volListJoin" -Severity Information
            # start encryption job
            $volumesRem | ForEach-Object {
                StartEncrypt -VserverName $($_.Vserver) -VolumeName $($_.Name)
            }
         }
        }
        else {
            Write-Log -Message "No volumes on $node need encryption process started" -Severity Information
        }
    }
}