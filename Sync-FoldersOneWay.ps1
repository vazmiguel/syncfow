Function Sync-FoldersOneWay {

<#
## LICENSE

GNU AFFERO GENERAL PUBLIC LICENSE
Version 3, 19 November 2007

Copyright (C) 2024 Miguel Vaz
Contact: ( [System.Text.Encoding]::Default.GetString([System.Convert]::FromBase64String('aG1pZ3VlbCBkb3QgdmF6IGF0IG91dGxvb2suY29t')) )

This is a Powershell script project licensed under the GNU Affero General Public License v3.0 (AGPL-3.0) with the following additional disclaimers.

** Disclaimer of Warranty**
THIS PROJECT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THIS PROJECT OR THE USE OR OTHER DEALINGS IN THE PROJECT.

** Disclaimer of Support**
The Community Project is provided without any form of support. 
You are responsible for obtaining your own technical support for any issues you may encounter while using this project.

Please refer to LICENSE file for more information.
#>
	
<#
.SYNOPSIS

Synchronizes two folders from source to replica (one way synchronization)

.DESCRIPTION

Synchronizes data and metadata for files and folders between two folders, source and replica.
Provides main synchronization and synchronization monitoring unless -noSyncMonitor is used.

.PARAMETER source
Specifies the source path

.PARAMETER replica
Specifies the destination path

.PARAMETER logpath
Specifies the path for the main synchronization transcript log.

.PARAMETER loglevel
Specifies the desired detail level of logging. Ex: INFO/VERBOSE

.PARAMETER namespaceConvention
Specifies the path naming convention. Win32 file namespaces help with paths exceeding the long path limit

.PARAMETER keepNewerFiles
Specifies if synchronization process should keep or replace newer files found inside the replica. Defaults to replace.

.PARAMETER keepOtherFiles
Specifies if synchronization process should keep or remove any files found inside the replica that dont have association with the source. Defaults to remove.

.PARAMETER noSyncMonitor
Disables synchronization monitoring during and after main synchronization process. Defaults to keep updating replica in realtime (experimental)

.PARAMETER noSyncLogOutput
Disables or supresses output logs of synchronizations, Eventually usefull for very large source folders. Defaults to showing logs.

.PARAMETER syncAuditInterval
Time interval in seconds to perform a synchronization audit on target folders where files where changed. If no file is changed no audit is performed.

.INPUTS
By parameter. You cannot pipe objects to Sync-FoldersOneWay.

.OUTPUTS
To transcript log. You cannot pipe objects from Sync-FoldersOneWay.

.EXAMPLE
#Performs full main synchronization with active monitoring.
Sync-FoldersOneWay -source C:\Path\to\your\source\folder -replica E:\Path\to\replica -logPath "C:\Path\to\log\transcriptLog_$((Get-Date).ToString('dd-MM-yyyy_HH.mm.ss')).txt"

.EXAMPLE
#Performs full main synchronization but disables active  synchronization monitoring during and after main synchronization
Sync-FoldersOneWay -source C:\Path\to\your\source\folder -replica E:\Path\to\replica -logPath "C:\Path\to\log\transcriptLog_$((Get-Date).ToString('dd-MM-yyyy_HH.mm.ss')).txt" -noSyncMonitor

.LINK

#>

[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory=$true, HelpMessage='Source target should be a Directory.', ValueFromPipeline=$false)]
	[ValidateScript({ if(-not (Test-Path -Type Container -LiteralPath $_) ) { throw "Cannot reach the source target $($_) " } return $true })][System.IO.DirectoryInfo]$source,
	[Parameter(Mandatory=$true, HelpMessage='Replica target should be a Directory.', ValueFromPipeline=$false)][System.IO.DirectoryInfo]$replica,
	[Parameter(Mandatory=$false, ValueFromPipeline=$false)][ValidateSet('INFO','VERBOSE')]$loglevel = "INFO",
	[Parameter(Mandatory=$false, ValueFromPipeline=$false)][ValidateSet('WIN32','OS')]$namespaceConvention = 'WIN32', #set to true (default) uses win32 file namespace \\?\ and bypasses maximum path length Limitation
	[Parameter(Mandatory=$true, HelpMessage='Log path should be a file', ValueFromPipeline=$false)]
	[ValidateScript({ 
		if($replica.Name -ne $source.Name) { $replica = [System.IO.DirectoryInfo][IO.Path]::Combine($replica.FullName,$source.name)		}
		if( $(([System.IO.FileInfo]$_).Directory.Fullname) -eq [IO.Path]::Combine([System.IO.DirectoryInfo]$replica.Parent.FullName,$replica.Name) ) { throw "Please specify a logPath different from the replica path. " }
		if( $(([System.IO.FileInfo]$_).Directory.Fullname) -eq [IO.Path]::Combine([System.IO.DirectoryInfo]$source.Parent.FullName,$source.Name) ) { throw "Please specify a logPath different from the source path. "	}
		if(-not (Test-Path -Type Container ([System.IO.FileInfo]$_).Directory) ) { throw "Cannot reach the specified path directory for $($_) "	} return $true })]
		[System.IO.FileInfo]$logPath,
	[switch]$keepNewerFiles = $false,
	[switch]$keepOtherFiles = $false,												#files on the replica target that do not exist on the source target
	[switch]$noSyncMonitor = $false,												#Experimental feature to monitor new source changes and replicate them immediately during or after main synchronization is finished.
	[switch]$noSyncLogOutput = $false,												#use to bypass output performance penalties
	$syncAuditInterval = 5															#in seconds. (optional)
)



$filters = {

filter script:start-sourceMonitorSync {
[CmdletBinding()]
param([Parameter(Mandatory=$true, ValueFromPipeline=$false)]$source,[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$replica)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters

if(test-shellReplicaOpenedFolders) {
	#warn user if PS 5.x has replica folders opened in Windows Explorer (not an issue in PS Core)
	break;
}


filter script:start-ProcessReadDirectoryChanges {
param($source, [switch]$quiet=$false)

$script:eventQueue = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject[]]]::new()
$script:eventQueueBackup = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject[]]]::new()
$script:mySourceIdentifier = "ProcessDirectoryChanges"

$eventHelperCode = {

	$notifyFilters = [NotifyFilter]::FILE_NOTIFY_CHANGE_FILE_NAME -bor [NotifyFilter]::FILE_NOTIFY_CHANGE_DIR_NAME -bor [NotifyFilter]::FILE_NOTIFY_CHANGE_ATTRIBUTES -bor [NotifyFilter]::FILE_NOTIFY_CHANGE_SIZE -bor [NotifyFilter]::FILE_NOTIFY_CHANGE_LAST_WRITE -bor [NotifyFilter]::FILE_NOTIFY_CHANGE_LAST_ACCESS -bor [NotifyFilter]::FILE_NOTIFY_CHANGE_CREATION -bor [NotifyFilter]::FILE_NOTIFY_CHANGE_SECURITY

	$source = $eventHelper.source
	$hDirectory = [Win32Api]::CreateFile($source.FullName,  # Specify the directory path
	[FileAccessRights]::FILE_LIST_DIRECTORY,       # Desired access: read data from the directory
	[ShareMode]::FILE_SHARE_READ -bor [ShareMode]::FILE_SHARE_WRITE -bor [ShareMode]::FILE_SHARE_DELETE, # Share mode
	[IntPtr]::Zero,             # Security attributes (none)
	[CreationDisposition]::OPEN_EXISTING,             # Open existing directory
	[FlagsAndAttributes]::FILE_FLAG_BACKUP_SEMANTICS,
	[IntPtr]::Zero              # Template file (none)
	)

	$eventHelper.directoryHandle = $hDirectory

	if ($hDirectory -eq [System.IntPtr]::Zero -or $hDirectory.ToInt32() -eq -1 ) {
		#Handle error if FindFirstChangeNotification fails
		Write-Host "Error initializing file system monitoring."
	} else {
			#$fniStructure = [Win32Api+FILE_NOTIFY_INFORMATION]::New()
			$fniStructure = [Win32Api+FILE_NOTIFY_EXTENDED_INFORMATION]::New()
			$fniType = $fniStructure.GetType()

			#$bufferSize = [System.Runtime.InteropServices.Marshal]::SizeOf([Type]$fniType)
			$bufferSize = 262144
			$outerId = 0
			$innerId = 0
		
			$getNextfswEvent = {
				$outerId++
				$buffer = [byte[]]::new($bufferSize)
				$pin = [System.Runtime.InteropServices.GCHandle]::Alloc($buffer, [System.Runtime.InteropServices.GCHandleType]::Pinned)
				$bufferPointer = $pin.AddrOfPinnedObject()
				$lpBytesReturned = [UInt32]0
				#$success = [Win32Api]::ReadDirectoryChangesW($hDirectory, $bufferPointer, $bufferSize, $true, $notifyFilters, [ref] $lpBytesReturned, [System.IntPtr]::Zero, [System.IntPtr]::Zero)	#synchronous
				$success = [Win32Api]::ReadDirectoryChangesExW($hDirectory, $bufferPointer, $bufferSize, $true, $notifyFilters, [ref] $lpBytesReturned, [System.IntPtr]::Zero, [System.IntPtr]::Zero, [Win32Api+READ_DIRECTORY_NOTIFY_INFORMATION_CLASS]::ReadDirectoryNotifyExtendedInformation) #synchronous
				$eventInfoCol = @()
				#Write-Host "lpBytesReturned is $lpBytesReturned"
				if($success) {
					$fni = $null
					$offset = [UInt32]0
					if($pin.IsAllocated) {
						do {
							$innerId++
							$timeGenerated = [datetime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fffffff")
							$newintptr = [System.IntPtr]::Add($bufferPointer, $offset)
							$fni = [System.Runtime.InteropServices.Marshal]::PtrToStructure($newintptr, [System.Type]$fniType)
							if($fni) {
								$filename = [System.Text.Encoding]::Unicode.GetString($fni.FileNameBytes, 0, $fni.FileNameLength)
								$eventInfoCol += $fni | Select-Object @{N="TimeGenerated";E={$timeGenerated}}, 
															@{N="OuterId";E={$outerId}}, 
															@{N="InnerId";E={$innerId}}, 
															@{N="Action";E={[FileAction]($_.Action)}}, 
															@{N="RelativeName";E={$fileName}}, 
															CreationTime,LastModificationTime,LastChangeTime,LastAccessTime,AllocatedLength,FileSize,FileAttributes,FileId,ParentFileId
							}
							$offset += $fni.NextEntryOffset;
						} while($fni.NextEntryOffset -ne 0)
						$pin.Free()
						$eventQueue.Enqueue($eventInfoCol)
						#$eventQueueBackup.Enqueue($eventInfoCol)
						
					}
				}
			}
			while((-not $eventHelper.resetEvent.WaitOne(0))) { .$getNextfswEvent }
	}
}

$script:eventHelper = [hashtable]::Synchronized(@{
	source = $source
	directoryHandle = $null
	jobHandle = $null
	powershellInstance = $null
	resetEvent = New-Object System.Threading.ManualResetEvent($false)  
})

	$runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
	$runspace.ApartmentState = 'STA'
	$runspace.ThreadOptions = 'UseNewThread'
	$runspace.Name = 'ReadDirectoryChangesW'
	$runspace.Open()
	$runspace.SessionStateProxy.SetVariable("eventQueue",$eventQueue)
	#$runspace.SessionStateProxy.SetVariable("eventQueueBackup",$eventQueueBackup)
	$runspace.SessionStateProxy.SetVariable("eventHelper",$eventHelper)

	$powershell = [PowerShell]::Create()
	$null = $PowerShell.AddScript($eventHelperCode)
	$powershell.Runspace = $runspace
	$eventHelper.jobHandle = $powershell.BeginInvoke()
	$eventHelper.powershellInstance = $powershell

	if (-not $quiet) { write-Log -level 'INFO' -backgroundcolor Yellow "ReadDirectoryChangesW started for $($source.FullName)" }

	$script:timer = New-Object System.Timers.Timer
	$timer.Interval = 100
	$timer.AutoReset = $true

	$script:objectEventLog = [hashtable]::Synchronized(@{})
	$script:eventInfoInnerHistory = [ordered]@{}
	$script:maxEventInfoInnerHistory = 64

	$processChanges = {
		$eventInfo = $null
		# "Peek" at the queue and process notifications if there are any
		while ($eventQueue.Count -gt 0) {
			if ($null -ne $syncAuditTimer -and $syncAuditTimer.Enabled) { $syncAuditTimer.Stop() }
			if ($eventQueue.TryDequeue([ref]$eventInfo)) {

				$processFni = {
					foreach($fni in $eventInfo) {
						
						#purge history to keep it at $maxEventInfoInnerHistory events
						if ($eventInfoInnerHistory.count -gt $maxEventInfoInnerHistory) { $eventInfoInnerHistory.RemoveAt(0) }
						$eventInfoInnerHistory.Add($fni.InnerId,$fni)
						$eventIdentifier = $fni.InnerId
						$sourceObjectRelativePath = $fni.RelativeName
						$changeType = $fni.Action
						$sourceObjectPath = [IO.Path]::Combine($source.FullName, $fni.RelativeName)
						$sourceObjectProperties = [System.IO.DirectoryInfo]$sourceObjectPath
						$sourceObjectAttributeInfo = $sourceObjectProperties.Attributes
						$sourceObjectType = if ($sourceObjectAttributeInfo -lt 0) { $null } elseif ($sourceObjectAttributeInfo -eq [System.IO.FileAttributes]::Archive ) { 'File' } else { 'Folder' }
						#$sourceObjectMap = if($null -ne $sourceObjectType) { get-ObjectMap -direction Source -type $sourceObjectType -objectList $sourceObjectPath -path $source.FullName -enumerate }
					
						write-Log -level 'VERBOSE' -ForeGroundColor Cyan -message "Started $changeType - $eventIdentifier - $sourceObjectPath"
							
						$replicaObjectPath = [IO.Path]::Combine($replica,$sourceObjectRelativePath)
						$replicaObjectAttributeInfo = ([System.IO.DirectoryInfo]$replicaObjectPath).Attributes
						$replicaObjectType = if ($replicaObjectAttributeInfo -lt 0) { $null } elseif ($replicaObjectAttributeInfo -eq [System.IO.FileAttributes]::Archive ) { 'File' } else { 'Folder' }
						#$replicaObjectMap = if($null -ne $replicaObjectType) { get-ObjectMap -direction Replica -type $replicaObjectType -objectList $replicaObjectPath -path $replica -enumerate }
		
						$fniExtraProps = [pscustomobject]@{sourceObjectType=$sourceObjectType;replicaObjectType=$replicaObjectType;}
						foreach ($property in $fniExtraProps.PSObject.Properties) { $fni.PSObject.Properties.Add($property) }

						#the old name will be placed on the eventInfo inside the object containing the FILE_ACTION_RENAMED_NEW_NAME action
						if($fni.Action -eq 'FILE_ACTION_RENAMED_OLD_NAME') { 
							continue; 
						} elseif ($fni.Action -eq 'FILE_ACTION_RENAMED_NEW_NAME' ) {
							$oldNameInfo = ($eventInfo | Where-Object Action -eq 'FILE_ACTION_RENAMED_OLD_NAME')
							$eventInfoRes = $oldNameInfo,$fni
						} else {
							$eventInfoRes = $fni
						}
		
						if ($null -eq $objectEventLog[$sourceObjectPath]) {
							$objectEventLog.Add($sourceObjectPath, 
								[pscustomobject]@{
									LastUpdatedTime=$null;
									sourceObjectPath=$sourceObjectPath;
									FILE_ACTION_ADDED=[pscustomobject]@{Count=0; eventInfo=@();};
									FILE_ACTION_REMOVED=[pscustomobject]@{Count=0; eventInfo=@();};
									FILE_ACTION_MODIFIED=[pscustomobject]@{Count=0; eventInfo=@();};
									FILE_ACTION_RENAMED_NEW_NAME=[pscustomobject]@{Count=0; eventInfo=@();};
									WAIT_OBJECT_0=[pscustomobject]@{Count=0; eventInfo=@();};
									sourceObjectMap=$sourceObjectMap;
									replicaObjectMap=$replicaObjectMap;
								}
							)
						}
		
						$thisObjectEvent = $objectEventLog[$sourceObjectPath]
						$thisObjectEvent.LastUpdatedTime = [datetime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fffffff")
						$thisObjectEvent.$changeType.Count += 1
						$thisObjectEvent.$changeType.eventInfo += $eventInfoRes
						#$thisObjectEvent.sourceObjectMap = $sourceObjectMap
						#$thisObjectEvent.replicaObjectMap = $replicaObjectMap
						write-Log -level 'VERBOSE' -ForeGroundColor Cyan -message "Inner $($fni.InnerId):$($fni.Action)`t$($fni.RelativeName) sourceObjectType: $sourceObjectType changeType: $changeType"		
						write-Log -level 'VERBOSE' -message "Starting switch process"
						switch ($sourceObjectType) {
							'Folder' {
								write-Log -level 'VERBOSE' -message "Entered switch process Folder"

								switch($changeType) {
									'FILE_ACTION_ADDED' {

										$thisObjectEventInfo = $thisObjectEvent.$changeType.eventInfo | Select-Object -Last 1
										$thisFileId = $thisObjectEventInfo.FileId
										$thisInnerId = $thisObjectEventInfo.InnerId
										$thisOuterId = $thisObjectEventInfo.OuterId
										
										filter get-movedObject {
										param($outerId, $innerId, $fileId)
											$eventInfoInnerHistory.Values | Where-Object { $_.OuterId -ge ($outerId - 1) -and $_.InnerId -lt $innerId } | Where-Object FileId -eq $fileId | Where-Object Action -eq ([FileAction]::FILE_ACTION_REMOVED)

										}
										write-Log -level 'VERBOSE' -message "Entered switch process File - FILE_ACTION_ADDED"
										
										#Moved files are a set of two operations: 1. remove 2. add
										$sourceObjectMovedFromInfo = get-movedObject -outerId $thisOuterId -innerId $thisInnerId -fileId $thisFileId
										$isMoved = !!($sourceObjectMovedFromInfo)
										if($isMoved) {
											write-Log -level 'VERBOSE' -message "Entered Folder - FILE_ACTION_ADDED - (moved from within source) $sourceObjectPath"
											$replicaOldPath = [IO.Path]::Combine($replica.FullName, $sourceObjectMovedFromInfo.RelativeName)
											$replicaNewPath = [IO.Path]::Combine($replica.FullName, $thisObjectEvent.$changeType.eventInfo.RelativeName)
											#Write-Host "Move-Item -LiteralPath $replicaOldPath -Destination $replicaNewPath -Force"
											Move-Item -LiteralPath $replicaOldPath -Destination $replicaNewPath -Force -ErrorAction SilentlyContinue
											write-Log -level 'INFO' -message "Moved FileId $thisFileId to $replicaNewPath"
											#Remove both old and new source objects
											$objectEventLog.Remove([IO.Path]::Combine($source.FullName, $sourceObjectMovedFromInfo.RelativeName))
											$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
										} else {
											if($thisObjectEventInfo.CreationTime -eq $thisObjectEventInfo.LastAccessTime) {
												#new folder
												write-Log -level 'VERBOSE' -message "Entered Folder - FILE_ACTION_ADDED - (create) $sourceObjectPath"
												if([int]([System.IO.DirectoryInfo]$replicaObjectPath).Attributes -lt 0) {
													$toCreate = [System.IO.DirectoryInfo]$replicaObjectPath
													$toCreate.Create()
													write-Log -level 'INFO' -message "Created $replicaObjectPath folder"
													$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)		
												}
											} elseif($thisObjectEventInfo.CreationTime -lt $thisObjectEventInfo.LastAccessTime) {
												#existing folder - moved to source from outside of source  - needs to be created and then fully synchronized
												write-Log -level 'VERBOSE' -message "Entered Folder - FILE_ACTION_ADDED - (moved from outside source) $sourceObjectPath"

												if([int]([System.IO.DirectoryInfo]$replicaObjectPath).Attributes -lt 0) {
													$toCreate = [System.IO.DirectoryInfo]$replicaObjectPath
													$toCreate.Create()
													
													$objectsToSync = (get-Summary -direction "Source" -path $sourceObjectPath).Values
													#1. Create folder structure on replica:
													sync-Objects -type Folder -objectsToSync $objectsToSync -replica $replicaObjectPath	#folder structure first
													#2. Synchronize files and file metadata on replica:
													sync-Objects -type File -objectsToSync $objectsToSync -replica $replicaObjectPath -syncMetadata
													#3. Synchronize folder metadata on replica:
													sync-Objects -type Folder -objectsToSync $objectsToSync -replica $replicaObjectPath -syncMetadata
													#4. cleanUp objectEventLog
													foreach ($object in $objectsToSync) {
														$objectEventLog.Remove($object.FullName)
													}
												}
											}
											
										}
									}
									'FILE_ACTION_MODIFIED' {
										
										$thisObjectEventInfo = $thisObjectEvent.$changeType.eventInfo | Select-Object -Last 1
										$thisFileId = $thisObjectEventInfo.FileId
										$thisInnerId = $thisObjectEventInfo.InnerId
										$thisOuterId = $thisObjectEventInfo.OuterId
										$lastFolderUpdateInnerId = ($eventInfoInnerHistory.Values | Where-Object { $_.InnerId -lt $thisInnerId -and $_.FileAttributes -eq ([FileAttributes]::FILE_ATTRIBUTE_DIRECTORY) -and $_.Action -eq ([FileAction]::FILE_ACTION_MODIFIED) } | Select-Object -Last 1).InnerId
										
										if($null -eq $lastFolderUpdateInnerId) { $lastFolderUpdateInnerId = 0 }

										filter get-addedObjects {
										param($outerId, $innerId, $fileId)
											$eventInfoInnerHistory.Values | Where-Object { $_.InnerId -gt $lastFolderUpdateInnerId -and $_.InnerId -lt $innerId } | Where-Object ParentFileId -eq $fileId | Where-Object Action -eq ([FileAction]::FILE_ACTION_ADDED)
										}
										filter get-removedObjects {
										param($outerId, $innerId, $fileId)
											#$lastFolderUpdateInnerId = ($eventInfoInnerHistory.Values | Where-Object { $_.OuterId -ge ($outerId - 1) -and $_.InnerId -lt $innerId -and $_.FileAttributes -eq [FileAttributes]::FILE_ATTRIBUTE_DIRECTORY } | Select-Object -Last 1).InnerId
											$eventInfoInnerHistory.Values | Where-Object { $_.InnerId -gt $lastFolderUpdateInnerId -and $_.InnerId -lt $innerId } | Where-Object ParentFileId -eq $fileId | Where-Object Action -eq ([FileAction]::FILE_ACTION_REMOVED)
										}
										$sourceObjectsAdded = get-addedObjects -outerId $thisOuterId -innerId $thisInnerId -fileId $thisFileId
										foreach ($objectAdded in $sourceObjectsAdded) {
											#Already added in File - FILE_ACTION_ADDED
											$objectEventLog.Remove([IO.Path]::Combine($source.FullName,$objectAdded.RelativeName))
										}
										#Should remove here to not interfere with move (REMOVED + ADD) operations
										$sourceObjectsRemoved = get-removedObjects -outerId $thisOuterId -innerId $thisInnerId -fileId $thisFileId
										foreach($objectRemoved in $sourceObjectsRemoved) {
											$objectRelativeName = $objectRemoved.RelativeName
											$sourceObjectRemovedPath = [IO.Path]::Combine($source.FullName,$objectRelativeName)
											$replicaObjectRemovePath = [IO.Path]::Combine($replica.FullName,$objectRelativeName)

											if($objectRemoved.FileAttributes -eq [FileAttributes]::FILE_ATTRIBUTE_DIRECTORY) {
												$toDelete = [System.IO.DirectoryInfo]$replicaObjectRemovePath
												if(-not ([int]([System.IO.DirectoryInfo]$toDelete).Attributes -lt 0)) {
													$toDelete.Delete($true)	#recursive deletion on specified folder
													write-Log -level 'INFO' -message "Deleted $replicaObjectRemovePath"
												}
											} else {
												$toDelete = [System.IO.FileInfo]$replicaObjectRemovePath
												if(-not ([int]([System.IO.FileInfo]$toDelete).Attributes -lt 0)) { 
													$toDelete.Delete()
													write-Log -level 'INFO' -message "Deleted $replicaObjectRemovePath"
												}
											}
											$objectEventLog.Remove($sourceObjectRemovedPath)
										}
										
										$sourceObjectMap = if($null -ne $sourceObjectType) { get-ObjectMap -direction Source -type $sourceObjectType -objectList $thisObjectEvent.sourceObjectPath -path $source -enumerate }
										sync-Objects -type $($sourceObjectType) -objectsToSync $sourceObjectMap -syncMetadata -replica $replica -Verbose:$VerbosePreference -ErrorAction SilentlyContinue -metadataLog
										$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
										
									}
									'FILE_ACTION_RENAMED_NEW_NAME' {
										#overrides replicaObjectPath with the old name
										$oldRelativeName = ($thisObjectEvent.FILE_ACTION_RENAMED_NEW_NAME.eventInfo | Where-Object Action -eq FILE_ACTION_RENAMED_OLD_NAME).RelativeName
										$newRelativeName = ($thisObjectEvent.FILE_ACTION_RENAMED_NEW_NAME.eventInfo | Where-Object Action -eq FILE_ACTION_RENAMED_NEW_NAME).RelativeName
										$replicaObjectPath = [IO.Path]::Combine($replica.FullName,$oldRelativeName)
										$newreplicaObjectPath = [IO.Path]::Combine($replica.FullName,$newRelativeName)
										Rename-Item -Path $replicaObjectPath -NewName $newreplicaObjectPath -Verbose:$VerbosePreference -ErrorAction SilentlyContinue
										write-Log -level 'INFO' -noOutput:$noSyncLogOutput -message "Renamed $replicaObjectPath to $newreplicaObjectPath"
										$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
									}
								}
							}
							'File' {
								write-Log -level 'VERBOSE' -message "Entered switch process File. changeType is $changeType"
								switch($changeType) {
			
									'FILE_ACTION_ADDED' {

										$thisObjectEventInfo = $thisObjectEvent.$changeType.eventInfo | Select-Object -Last 1
										$thisFileId = $thisObjectEventInfo.FileId
										$thisInnerId = $thisObjectEventInfo.InnerId
										$thisOuterId = $thisObjectEventInfo.OuterId

										filter get-movedObject {
											param($outerId, $innerId, $fileId)
												$eventInfoInnerHistory.Values | Where-Object { $_.OuterId -ge ($outerId - 1) -and $_.InnerId -lt $innerId } | Where-Object FileId -eq $fileId | Where-Object Action -eq ([FileAction]::FILE_ACTION_REMOVED)
		
										}
										write-Log -level 'VERBOSE' -message "Entered switch process File - FILE_ACTION_ADDED"
										
										#Moved files are removed from source first
										$sourceObjectMovedFromInfo = get-movedObject -outerId $thisOuterId -innerId $thisInnerId -fileId $thisFileId
										$isMoved = !!($sourceObjectMovedFromInfo)
										if($isMoved) {
											write-Log -level 'VERBOSE' -message "Entered File - FILE_ACTION_ADDED - (moved) $sourceObjectPath"
											$replicaOldPath = [IO.Path]::Combine($replica.FullName, $sourceObjectMovedFromInfo.RelativeName)
											$replicaNewPath = [IO.Path]::Combine($replica.FullName, $thisObjectEvent.$changeType.eventInfo.RelativeName)
											#Write-Host "Move-Item -LiteralPath $replicaOldPath -Destination $replicaNewPath -Force"
											Move-Item -LiteralPath $replicaOldPath -Destination $replicaNewPath -Force -ErrorAction SilentlyContinue
											write-Log -level 'INFO' -message "Moved FileId $thisFileId to $replicaNewPath"
											#Remove both old and new source objects
											$objectEventLog.Remove([IO.Path]::Combine($source.FullName, $sourceObjectMovedFromInfo.RelativeName))
											#$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
										} else {
											if($thisObjectEventInfo.FileSize -eq 0) {
												write-Log -level 'VERBOSE' -message "Entered File - FILE_ACTION_ADDED - (create) $sourceObjectPath"
												if([int]([System.IO.FileInfo]$replicaObjectPath).Attributes -lt 0) {
													$toCreate = [System.IO.FileInfo]$replicaObjectPath
													$handle = $toCreate.Create()	
													if($null -ne $handle) {
														$handle.Close()
														$handle.Dispose()
														write-Log -level 'VERBOSE' -message "Created $replicaObjectPath file."
													}
												}
											} else {
												#file moved from out of the source folder and to the source folder
												#handled by FILE_ACTION_MODIFIED
											}
											
										}
									}
									'FILE_ACTION_MODIFIED' {
										$thisObjectEventInfo = $thisObjectEvent.$changeType.eventInfo | Select-Object -Last 1
										$thisFileId = $thisObjectEventInfo.FileId
										$thisInnerId = $thisObjectEventInfo.InnerId
										$thisOuterId = $thisObjectEventInfo.OuterId
										$lastFileUpdateInnerId = ($eventInfoInnerHistory.Values | Where-Object { $_.InnerId -eq ($thisInnerId - 1) -and $_.FileId -eq $thisFileId }).InnerId

										if($objectEventLog[$thisObjectEvent.sourceObjectPath].FILE_ACTION_ADDED.Count -eq 1) {
											$objectEventLog.Remove($thisObjectEvent.sourceObjectPath) #ignore first write / copy start . Ignore moved files
										} else {
											if($thisObjectEventInfo.FileSize -gt 0 -and (($thisObjectEventInfo.LastModificationTime -ne $thisObjectEventInfo.LastAccessTime) -or ($null -eq $lastFileUpdateInnerId))) {
												#when replacing a file the first modified event should have a filesize of 0 and LastModificationTime=LastAccessTime until replace is finished so event is ignored
												#existing file modifications should have LastModificationTime=LastAccessTime but generates a single FILE_ACTION_MODIFIED event which is not ignored
												$sourceObjectMap = if($null -ne $sourceObjectType) { get-ObjectMap -direction Source -type $sourceObjectType -objectList $thisObjectEvent.sourceObjectPath -path $source -enumerate }
												sync-Objects -type $($sourceObjectType) -objectsToSync $sourceObjectMap -syncMetadata -replica $replica -Verbose:$VerbosePreference -ErrorAction SilentlyContinue
												$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
											}
										}
										
										$parentFolderRelativeName = (get-ObjectParent -path $sourceObjectPath).FullName.Replace($source.fullname,'')

										#$global:gParentFolderRelativeName += $parentFolderRelativeName
										#To be used in SyncFolder Audit Process
										if($null -eq $global:syncAuditFolderCollection[$parentFolderRelativeName]) {
											$folderParents = $syncAuditFolderCollection.keys | Where-Object { $_ -ne $parentFolderRelativeName -and $parentFolderRelativeName.StartsWith($_) }
											$childFolders = $syncAuditFolderCollection.keys | Where-Object { $_ -ne $parentFolderRelativeName -and $_.StartsWith($parentFolderRelativeName) }
											
											if(-not $folderParents) {
												$global:syncAuditFolderCollection.Add($parentFolderRelativeName, $sourceObjectProperties)
											} 
											if($childFolders) {
												$childFolders | ForEach-Object { $syncAuditFolderCollection.Remove($_) }
											}
										}
									}
									'FILE_ACTION_RENAMED_NEW_NAME' {
										#overrides replicaObjectPath with the old name
										$oldRelativeName = ($thisObjectEvent.FILE_ACTION_RENAMED_NEW_NAME.eventInfo | Where-Object Action -eq ([FileAction]::FILE_ACTION_RENAMED_OLD_NAME)).RelativeName
										$newRelativeName = ($thisObjectEvent.FILE_ACTION_RENAMED_NEW_NAME.eventInfo | Where-Object Action -eq ([FileAction]::FILE_ACTION_RENAMED_NEW_NAME)).RelativeName
										$replicaObjectPath = [IO.Path]::Combine($replica.FullName,$oldRelativeName)
										$newreplicaObjectPath = [IO.Path]::Combine($replica.FullName,$newRelativeName)
										Rename-Item -Path $replicaObjectPath -NewName $newreplicaObjectPath -Verbose:$VerbosePreference -ErrorAction SilentlyContinue
										write-Log -level 'INFO' -noOutput:$noSyncLogOutput -message "Renamed $replicaObjectPath to $newreplicaObjectPath"
										$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
										#write-Log -level 'VERBOSE' -noOutput:$noSyncLogOutput -message "Removed objectEvent $sourceObjectPath"
									}
								}
							}
							$null {
								#removed file or folder events should end up here
								switch($changeType) {
									'FILE_ACTION_REMOVED' {
										$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
									}
								}
							}
						}
					}			
				}
				.$processFni
			}
		}
		if($null -ne $syncAuditTimer -and -not $syncAuditTimer.Enabled) { $syncAuditTimer.Start() }
	}

	Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action $processChanges -SourceIdentifier $mySourceIdentifier #-SupportEvent
	$timer.Start()

}

filter script:stop-ProcessReadDirectoryChanges {
param([switch]$quiet=$false)
	if($null -ne $eventHelper -and $null -ne $eventHelper.powershellInstance -and $eventHelper.powershellInstance.Runspace.RunspaceStateInfo.State -ne 'Closed') {
		#no need to wait for final event before ReadDirectoryChangesW can be released before calling EndInvoke.
		if(-not $eventHelper.resetEvent.WaitOne(0)) {
			$null = $eventHelper.resetEvent.Set()
			$null = [Win32Api]::CancelIoEx($eventHelper.directoryHandle, [IntPtr]::Zero)
		}

		$null = $eventHelper.powershellInstance.EndInvoke($eventHelper.jobHandle)
		$eventHelper.powershellInstance.Runspace.Close()
		$eventHelper.powershellInstance.Runspace.Dispose()
		$timer.Stop()
		$timer.Dispose()

		if (-not $quiet) { 
			write-Log -level 'INFO' -ForeGroundColor Yellow "ReadDirectoryChanges stopped for $($source.FullName)" -NoNewLine
			Write-Host ""
		}
	}

	if($mySourceIdentifier) {
		Get-EventSubscriber -SourceIdentifier $mySourceIdentifier -Force -ErrorAction SilentlyContinue | Unregister-Event -Force	#-force will show/remove hidden eventsubscribers
		Get-Job -Name $mySourceIdentifier -ErrorAction SilentlyContinue | Remove-Job
	}
}

#change script scope loglevel accordingly
if($VerbosePreference -eq 'Continue' -and $script:loglevel) {
	$script:loglevel = "VERBOSE"
} else {
	$script:loglevel = "INFO"
}


start-ProcessReadDirectoryChanges -source $source -quiet

$script:objectEventLog = [hashtable]::Synchronized(@{})

write-Log -level 'INFO' -backgroundcolor Green -foregroundcolor Black -message "Synchronization monitoring started. Listening to filesystem changes on $($source.fullname)..."
write-Log -level 'INFO' -backgroundcolor Green -foregroundcolor Black -message "Use `"stop-sourceMonitorSync`" to stop monitoring." -NoNewLine
Write-Host ""

}
filter script:stop-sourceMonitorSync {
param([switch]$quiet=$false)
	
	if($null -ne (Get-Command stop-ProcessReadDirectoryChanges -ErrorAction SilentlyContinue) ) {
		stop-ProcessReadDirectoryChanges -quiet:$quiet
	}
	
	if(-not $quiet) {
		if($logPath) { 
			write-Log -level 'INFO' -message "Transcript stopped, output file is $logPath"
			$global:logPath = $null
		}
	}
	Get-EventSubscriber *SyncAudit* | Unregister-Event -Verbose:$VerbosePreference
	Get-Job -Name *SyncAudit* | Remove-Job -Verbose:$VerbosePreference
	try { Stop-Transcript ;  } catch {}

}
filter script:write-Log {
param(
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$level,
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$message,
	[switch]$noOutput=$false,
	$ForegroundColor = "Yellow",
	$BackGroundColor = $host.UI.RawUI.BackgroundColor,
	[switch]$NoNewLine = $false
)

#TODO: Improve loglevel output for WARN, ERROR
if(-not $noOutput -and $level -le [logType]::$loglevel) {
	$messageStructure = ([datetime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fffffff") + " [$level] $message")
	$endMessage = "$([char]27)[?25l $([char]27)[${12}G$messageStructure" 
	Write-Host -BackGroundColor $backgroundcolor -ForegroundColor $ForegroundColor $endMessage -NoNewline:$NoNewLine
}
}
filter script:trace-Command {
param($commandName, $boundParams)
	$PSBoundParameterString = if($boundParams.Keys) { [string]($boundParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) }
	write-Log -level 'VERBOSE' -message "Entering $commandName Params: $PSBoundParameterString"
}
filter script:test-Elevated {
	$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = [System.Security.Principal.WindowsPrincipal]($identity)
	return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
filter script:test-shellReplicaOpenedFolders {
#fetch windows explorer opened handles to replica folders then  if any warn the user about it
$shellOpenedFolders = (@((New-Object -com shell.application).Windows()).Document.Folder).Self.Path
$normalizedPaths = foreach ($folder in $shellOpenedFolders) { get-NormalizedPath -path $folder }
$shellOpenedReplicaFolders = $normalizedPaths | Where-Object FullName -like "$($replica.Fullname)*"
if($shellOpenedReplicaFolders.Count -gt 0 -and $host.Version.Major -le 5) {
	write-Log  -backgroundcolor Green -foregroundcolor Black -level 'INFO' -message "WARNING: Using Powershell 5.x or lower may result in 'by design' object handle issues when replica folders are opened in Windows Explorer resulting in 'cannot access/being used by another process' errors"
	$shellOpenedReplicaFolders | ForEach-Object {
		write-Log  -backgroundcolor Red -foregroundcolor Black -level 'INFO' -message "ACTION: Please close your Windows Explorer handle to $($_) and try again."
	}
	return $true
} else {
	return $false
}
}
filter script:test-syncRequirements {
param([Parameter(Mandatory=$true, ValueFromPipeline=$false)]$sourceSummary, [Parameter(Mandatory=$true, ValueFromPipeline=$false)]$replica)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
$outcome = $false

if($IsLinux) { 
	Write-Host -ForegroundColor Red "Synchronization requirement failed - Linux environment is not currently supported due to some features being used.";
	return $false
}

if( (-not $noSyncMonitor) -and -not ([System.Environment]::OSVersion.Version.Major -ge 10 -and [System.Environment]::OSVersion.Version.Build -ge 1709) ) {

	Write-Host -ForegroundColor Red "Synchronization monitoring requirement failed - Minimum supported client	Windows 10, version 1709 [desktop apps only]."
	Write-Host -ForegroundColor Red "Synchronization monitoring requirement failed - Minimum supported server	Windows Server 2019 [desktop apps only]."
	Write-Host -ForegroundColor Cyan "Use -noSyncMonitor to skip active monitoring."
	return $false
}


if($host.Version.Major -le 5) {
	write-Log  -backgroundcolor Green -foregroundcolor Black -level 'INFO' -message "WARNING: Using Powershell Core 7.x or greater is recommended for better compatibility and performance."
}

if(-not (test-Elevated)) { 
	#It is optional but recommended to run Powershell as administrator
	$outcome = $true
}

if(test-shellReplicaOpenedFolders) {
	return $false
}

$sourceSummaryLen = 1KB + ($sourceSummary.Values | Measure-Object -Property Length -Sum).Sum	#1KB eventually gives divided by zero protection
$replicaDriveName = $($replica.Root.ToString() -replace '.*(\w)\:\\','$1')
$replicaFreeLen = 1KB + (Get-PSDrive $replicaDriveName).Free

Write-Verbose "sourceSummary $sourceSummaryLen replicaFreeLen $replicaFreeLen replicaRoot $($replica.Root.ToString() -replace '\:\\','')"

if($replicaFreeLen -lt $sourceSummaryLen) {
	write-Log  -backgroundcolor Red -foregroundcolor Black -level 'INFO' -message "Not enough space in replica. Required: $("{0:N2}" -f ($sourceSummaryLen / 1024 / 1024)) MB. Available: $("{0:N2}" -f ($replicaFreeLen / 1024 / 1024)) MB"
	return $false
} else { $outcome = $true }

return $outcome

}
filter script:set-syncEnvironment {
[CmdletBinding()]
param ($source,$replica,$logPath,$loglevel,$namespaceConvention)



$definitions = {

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

		public static class Win32Api
		{
			// Windows API functions
			[DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
			public static extern IntPtr FindFirstChangeNotification(string lpPathName, bool bWatchSubtree, uint dwNotifyFilter);

			[DllImport("kernel32.dll", SetLastError = true)]
			public static extern bool FindNextChangeNotification(IntPtr hChangeHandle);

			[DllImport("kernel32.dll", SetLastError = true)]
			public static extern bool FindCloseChangeNotification(IntPtr hChangeHandle);

			[DllImport("kernel32.dll", SetLastError = true)]
			public static extern uint WaitForMultipleObjects(uint nCount, IntPtr[] lpHandles, bool bWaitAll, uint dwMilliseconds);

			[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
			public static extern IntPtr CreateFile(
				string lpFileName,
				uint dwDesiredAccess,
				uint dwShareMode,
				IntPtr lpSecurityAttributes,
				uint dwCreationDisposition,
				uint dwFlagsAndAttributes,
				IntPtr hTemplateFile
			);

			[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
			public static extern bool ReadDirectoryChangesW(
				IntPtr hDirectory,
				IntPtr lpBuffer,
				uint nBufferLength,
				bool bWatchSubtree,
				uint dwNotifyFilter,
				out uint lpBytesReturned,
				IntPtr lpOverlapped,
				IntPtr lpCompletionRoutine
			);

			[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
			[return: MarshalAs(UnmanagedType.Bool)]
			public static extern bool ReadDirectoryChangesExW(
				IntPtr hDirectory,
				IntPtr lpBuffer,
				uint nBufferLength,
				[MarshalAs(UnmanagedType.Bool)] bool bWatchSubtree,
				uint dwNotifyFilter,
				out uint lpBytesReturned,
				IntPtr lpOverlapped,
				IntPtr lpCompletionRoutine,
				uint ReadDirectoryNotifyInformationClass
			);

			[DllImport("kernel32.dll", SetLastError=true)]
			public static extern bool CancelIoEx(IntPtr hFile, IntPtr lpOverlapped);
		
			[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
			public struct FILE_NOTIFY_INFORMATION
			{
				public uint NextEntryOffset;
				public uint Action;        
									// FILE_ACTION_ADDED,              0x00000001, The file was added to the directory.
									// FILE_ACTION_REMOVED,            0x00000002, The file was removed from the directory.
									// FILE_ACTION_MODIFIED,           0x00000003, The file was modified. This can be a change in the time stamp or attributes.
									// FILE_ACTION_RENAMED_OLD_NAME,   0x00000004, The file was renamed and this is the old name.
									// FILE_ACTION_RENAMED_NEW_NAME,   0x00000005, The file was renamed and this is the new name.
				public uint FileNameLength;
				[MarshalAs(UnmanagedType.ByValArray, SizeConst = 1024)]
				public byte[] FileNameBytes;
			}

			[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
			public struct FILE_NOTIFY_EXTENDED_INFORMATION
			{
				public uint NextEntryOffset;
				public uint Action;
				public long CreationTime;
				public long LastModificationTime;
				public long LastChangeTime;
				public long LastAccessTime;
				public long AllocatedLength;
				public long FileSize;
				public uint FileAttributes;
				public UnionField DUMMYUNIONNAME;
				public long FileId;
				public long ParentFileId;
				public uint FileNameLength;
				[MarshalAs(UnmanagedType.ByValArray, SizeConst = 1024)]
				public byte[] FileNameBytes;
			}

			[StructLayout(LayoutKind.Explicit)]
			public struct UnionField
			{
				[FieldOffset(0)]
				public uint ReparsePointTag;

				[FieldOffset(0)]
				public uint EaSize;
			}

			public enum READ_DIRECTORY_NOTIFY_INFORMATION_CLASS : uint
			{
				ReadDirectoryNotifyInformation = 1,
				ReadDirectoryNotifyExtendedInformation = 2,
				ReadDirectoryNotifyFullInformation = 3,
				ReadDirectoryNotifyMaximumInformation = 4
			}
		}
'@
Add-Type -TypeDefinition $code
# Windows API constants
# $WAIT_FAILED = [UInt32]::MaxValue
# $INFINITE = [UInt32]::MaxValue

Add-Type -TypeDefinition @'

		public enum FileAction: uint {
			WAIT_OBJECT_0 = 0x00000000,
			FILE_ACTION_ADDED = 0x00000001,
			FILE_ACTION_REMOVED = 0x00000002,
			FILE_ACTION_MODIFIED = 0x00000003,
			FILE_ACTION_RENAMED_OLD_NAME = 0x00000004,
			FILE_ACTION_RENAMED_NEW_NAME = 0x00000005
		}
		public enum NotifyFilter: uint   {
			FILE_NOTIFY_CHANGE_FILE_NAME = 0x00000001,
			FILE_NOTIFY_CHANGE_DIR_NAME = 0x00000002,
			FILE_NOTIFY_CHANGE_ATTRIBUTES = 0x00000004,
			FILE_NOTIFY_CHANGE_SIZE = 0x00000008,
			FILE_NOTIFY_CHANGE_LAST_WRITE = 0x00000010,
			FILE_NOTIFY_CHANGE_LAST_ACCESS = 0x00000020,
			FILE_NOTIFY_CHANGE_CREATION = 0x00000040,
			FILE_NOTIFY_CHANGE_SECURITY = 0x00000100
		}

		public enum DesiredAccess: uint {
			GENERIC_ALL = 0x10000000,		//All possible access rights
			GENERIC_EXECUTE = 0x20000000,	//Execute access
			GENERIC_WRITE = 0x40000000,		//Write access
			GENERIC_READ = 0x80000000		//Read access
		}
		public enum ShareMode: uint  {
			LOCK = 0x00000000,
			FILE_SHARE_DELETE = 0x00000004,
			FILE_SHARE_READ = 0x00000001,
			FILE_SHARE_WRITE = 0x00000002
		}
		public enum CreationDisposition: uint  {
			CREATE_NEW = 1,
			CREATE_ALWAYS = 2,
			OPEN_EXISTING = 3,
			OPEN_ALWAYS = 4,
			TRUNCATE_EXISTING = 5
		}
		public enum FlagsAndAttributes: uint  {
			FILE_ATTRIBUTE_ARCHIVE = 0x20,
			FILE_ATTRIBUTE_ENCRYPTED = 0x4000,
			FILE_ATTRIBUTE_HIDDEN = 0x2,
			FILE_ATTRIBUTE_NORMAL = 0x80,
			FILE_ATTRIBUTE_OFFLINE = 0x1000,
			FILE_ATTRIBUTE_READONLY = 0x1,
			FILE_ATTRIBUTE_SYSTEM = 0x4,
			FILE_ATTRIBUTE_TEMPORARY = 0x100,
			FILE_FLAG_BACKUP_SEMANTICS = 0x02000000,
			FILE_FLAG_DELETE_ON_CLOSE = 0x04000000,
			FILE_FLAG_NO_BUFFERING = 0x20000000,
			FILE_FLAG_OPEN_NO_RECALL = 0x00100000,
			FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000,
			FILE_FLAG_OVERLAPPED = 0x40000000,
			FILE_FLAG_POSIX_SEMANTICS = 0x01000000,
			FILE_FLAG_RANDOM_ACCESS = 0x10000000,
			FILE_FLAG_SESSION_AWARE = 0x00800000,
			FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000,
			FILE_FLAG_WRITE_THROUGH = 0x80000000
		}
		public enum FileAccessRights: uint  {
			FILE_ADD_FILE = 0x2,
			FILE_ADD_SUBDIRECTORY = 0x4,
			FILE_ALL_ACCESS = 0x1F01FF,
			FILE_APPEND_DATA = 0x4,
			FILE_CREATE_PIPE_INSTANCE = 0x4,
			FILE_DELETE_CHILD = 0x40,
			FILE_EXECUTE = 0x20,
			FILE_LIST_DIRECTORY = 0x1,
			FILE_READ_ATTRIBUTES = 0x80,
			FILE_READ_DATA = 0x1,
			FILE_READ_EA = 0x8,
			FILE_TRAVERSE = 0x20,
			FILE_WRITE_ATTRIBUTES = 0x100,
			FILE_WRITE_DATA = 0x2,
			FILE_WRITE_EA = 0x10,
			STANDARD_RIGHTS_READ = 0x20000,
			STANDARD_RIGHTS_WRITE = 0x20000
		}
		public enum FileAttributes : uint {
			FILE_ATTRIBUTE_READONLY = 0x00000001,
			FILE_ATTRIBUTE_HIDDEN = 0x00000002,
			FILE_ATTRIBUTE_SYSTEM = 0x00000004,
			FILE_ATTRIBUTE_DIRECTORY = 0x00000010,
			FILE_ATTRIBUTE_ARCHIVE = 0x00000020,
			FILE_ATTRIBUTE_DEVICE = 0x00000040,
			FILE_ATTRIBUTE_NORMAL = 0x00000080,
			FILE_ATTRIBUTE_TEMPORARY = 0x00000100,
			FILE_ATTRIBUTE_SPARSE_FILE = 0x00000200,
			FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400,
			FILE_ATTRIBUTE_COMPRESSED = 0x00000800,
			FILE_ATTRIBUTE_OFFLINE = 0x00001000,
			FILE_ATTRIBUTE_NOT_CONTENT_INDEXED = 0x00002000,
			FILE_ATTRIBUTE_ENCRYPTED = 0x00004000,
			FILE_ATTRIBUTE_INTEGRITY_STREAM = 0x00008000,
			FILE_ATTRIBUTE_VIRTUAL = 0x00010000,
			FILE_ATTRIBUTE_NO_SCRUB_DATA = 0x00020000,
			FILE_ATTRIBUTE_EA = 0x00040000,
			FILE_ATTRIBUTE_PINNED = 0x00080000,
			FILE_ATTRIBUTE_UNPINNED = 0x00100000,
			FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x00040000,
			FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000
		}

'@


Add-Type -TypeDefinition @"
public enum logType
{
	INFO,
	VERBOSE
}
"@

}

.$definitions



#Matches sync logLevel to the VerbosePreference
$script:logLevel = if($VerbosePreference -eq "Continue") { "VERBOSE" } else { "INFO" }
trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
$script:synchronizedFiles = 0
$script:synchronizedFolders = 0
$script:skipped = 0
$script:removed = 0

#quietly cleanup any other previous file/folder fsw for the session
stop-sourceMonitorSync -quiet

if($host.Version.Major -le 5) {
	$source = [System.IO.DirectoryInfo]$source.FullName.Replace('\\?\','') #if no dos device path replace, using PS 5 results in "The path is not of a legal form." . Removes long path support for PS5.Not an issue in Core
	$replica = [System.IO.DirectoryInfo]$replica.FullName.Replace('\\?\','')
}

#always bases replica on the source child basename whether specified or not
$source = get-NormalizedPath -path $source
$replica = get-NormalizedPath -path $replica

if ($replica.Name -ne $source.name)  {
	$replicaTargetPath = [IO.Path]::Combine($replica.fullname, $source.name)
} else {
	$replicaTargetPath = $replica.fullname
}
If (-not (Test-Path $replicaTargetPath)) {
	$toCreate = [System.IO.DirectoryInfo]$replicaTargetPath
	$handle = $toCreate.Create()
	if($null -ne $handle) {
		$handle.Close()
		$handle.Dispose()
		#$objectEventLog.Remove($thisObjectEvent.sourceObjectPath)
	}
}
$replica = get-NormalizedPath  -path $replicaTargetPath

[PSCustomObject]@{
	source = $source
	replica = $replica
	logPath = $logPath
}

}
filter script:get-NormalizedPath {
[CmdletBinding()]
param([Parameter(Mandatory=$true, ValueFromPipeline=$false)][System.IO.DirectoryInfo]$path)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
#Makes every folder end with the right slash
$path = [System.IO.DirectoryInfo][IO.Path]::Combine($path.FullName,' ').TrimEnd()

if ($namespaceConvention -eq 'WIN32' -and -not $path.FullName.StartsWith('\\?\')) { 
	[System.IO.DirectoryInfo](('\\?\' + $path)) 
} else {
	$path
}
}
filter script:get-ObjectParent {
param([Parameter(Mandatory=$true, ValueFromPipeline=$false)]$path)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
if($path.GetType() -ne [System.IO.DirectoryInfo]) { $path = get-NormalizedPath -path $path }
if($null -ne $path.Parent) {
	get-NormalizedPath $path.Parent.FullName
} else {
	get-NormalizedPath $path.FullName	#Root folders have no parent so fullname is returned instead
}

}
filter script:get-ObjectInfo {
param([Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Folder','File')]$type, [Parameter(Mandatory=$true, ValueFromPipeline=$false)]$object)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
switch ($type) {
	'Folder' { 
		$objInfo = [System.IO.DirectoryInfo]($object) 
	}
	'File' { 
		$objInfo = [System.IO.FileInfo]($object) 
	}
}

if (-not ([int]$objInfo.Attributes -lt 0)) { $objInfo }	#faster alternative to test-path

}
filter script:get-ObjectList {
param(
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Folder','File')]$type, 
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$path
)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
if($path.GetType() -ne [System.IO.DirectoryInfo]) { $path = get-NormalizedPath -path $path }

if ([Type]::GetType('System.IO.EnumerationOptions')) {
	$enumerationOptions = [System.IO.EnumerationOptions]::New()
	#$enumerationOptions.AttributesToSkip = ([System.IO.FileAttributes]::Hidden, [System.IO.FileAttributes]::System)
	$enumerationOptions.AttributesToSkip = 0
	$enumerationOptions.RecurseSubdirectories = $true
	$enumerationOptions.IgnoreInaccessible = $true
} else {
	#PS 5.0
	$enumerationOptions = [System.IO.SearchOption]::AllDirectories
}

switch ($type) {
	'Folder' {
		[System.IO.Directory]::EnumerateDirectories($path.Fullname,'*',$enumerationOptions)
	}
	'File' {
		[System.IO.Directory]::EnumerateFiles($path.Fullname,'*',$enumerationOptions) 
	}
}

}
filter script:get-ObjectMap {
[CmdletBinding()]
param(
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Source','Replica')]$direction,
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Folder','File')]$type,
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$path, 								#either source or replica
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][AllowNull()]$objectList,  			#expected: array of fullname path strings
	[switch]$relativeTargetIncludesParent=$false,
	[switch]$enumerate=$false
)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters

$objectSummary = [ordered]@{}

if($relativeTargetIncludesParent) { $path = get-ObjectParent -path $path }
#set the relativeTarget to always be based on source or replica base folders
if($direction -eq 'Source') { $path = $source } else { $path = $replica }

$progress = 0

foreach ($object in $objectList) {
	if($firstSync) { 
		if($PSStyle) { 
			$PSStyle.Progress.MaxWidth = 180 
			Write-Progress -Activity "Mapping $direction $type objects..." -status $object -currentoperation $null -percentcomplete (($progress/$objectList.count)*100) 
		} #PS Core progress is faster.
	}
	$objectInfo = get-ObjectInfo -type $type -object $object
	if ($null -ne $objectInfo) {
		$relativeTarget = $objectInfo.FullName.Replace($path.FullName,[String]::Empty)	
		$summary = $objectInfo | Select-Object @{N="Type";E={$type}}, Mode, Fullname, Length, Name, @{N="RelativeTarget";E={$relativeTarget}}, @{N="LastWriteFileTimeUTC";E={ $_.LastWriteTimeUtc.ToFileTimeUTC() }}, @{N="LastAccessFileTimeUTC";E={ $_.LastAccessTimeUtc.ToFileTimeUTC() }}, @{N="CreationTimeFileTimeUTC";E={ $_.CreationTimeUtc.ToFileTimeUTC() }}
		$metadataHashProperties = $summary.PSObject.Properties.Where({$_.Name -in "Type","Mode","RelativeTarget","Length","LastWriteFileTimeUTC","LastAccessFileTimeUTC","CreationTimeFileTimeUTC"}).Value
		$memStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($metadataHashProperties))
		$metadataHash = (Get-FileHash -InputStream $memStream -Algorithm MD5).Hash
		$summary.PSObject.Properties.Add([PSNoteProperty]::new('MetadataHash', $metadataHash))
		$summaryIdentifier = $relativeTarget + "`t[$metadataHash]"
		$objectSummary.Add($summaryIdentifier, $summary)
	}
	$progress ++;
}
if($enumerate) { $($objectSummary.GetEnumerator()).Value } else { return $objectSummary }
}
filter script:get-ObjectSummary {
param(
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Source','Replica')]$direction, 
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Folder','File')]$type, 
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$path)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
if($path.GetType() -ne [System.IO.DirectoryInfo]) { $path = get-NormalizedPath -path $path }
$objectList = get-ObjectList -type $type -path $path
return (get-ObjectMap -direction $direction -objectList $objectList -type $type -path $path)

}
filter script:get-Summary {
param(
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Source','Replica')]$direction, 
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$path
)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
if($path.GetType() -ne [System.IO.DirectoryInfo]) { $path = get-NormalizedPath -path $path }
$folderSummary = get-ObjectSummary -direction $direction -type 'Folder' -path $path
$fileSummary = get-ObjectSummary -direction $direction -type 'File' -path $path

return ($folderSummary + $fileSummary)
}
filter script:get-DateFromFileTimeUTC {
param($filetime=$(throw "time required"))
	[datetime]::FromFileTimeUTC($filetime)
}
filter script:sync-Objects {
[CmdletBinding()]
param(
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][ValidateSet('Folder','File')]$type, 
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)][AllowNull()]$objectsToSync,
	[Parameter(Mandatory=$true, ValueFromPipeline=$false)]$replica,
	[switch]$relativeTargetIncludesParent=$false,
	[switch]$syncMetadata = $false,
	[switch]$metadataLog=$false
)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
$progress=0

if($relativeTargetIncludesParent) { $path = get-ObjectParent -path $replica } else { $path = $replica }
$progressValue = $ProgressPreference
$ProgressPreference = "SilentlyContinue"

foreach ($object in ($objectsToSync | Where-Object {$_.Type -eq $type})) {

	if($object.Type -eq "Folder") {
		$destinationItem = [System.IO.DirectoryInfo][IO.Path]::Combine($path.FullName,$object.RelativeTarget)
		$destination = $destinationItem -replace "(.*)(\\|\/)$($object.Name)",'$1$2'
		if($destinationItem.Attributes -lt 0) {
			$copiedItem = Copy-Item -LiteralPath $object.FullName -Destination $destination -Force -Verbose:$VerbosePreference -WhatIf:$WhatIfPreference -PassThru -ErrorAction SilentlyContinue
			if($null -ne $copiedItem) { $script:synchronizedFolders +=1 }
		} else {
			$copiedItem = $destinationItem
		}
	} else {
		$destination = [IO.Path]::Combine($path.FullName,$object.RelativeTarget)
		if(-not $keepNewerFiles) {
			write-Log -level 'INFO' -noOutput:$noSyncLogOutput -message "Synchronizing $destination" -NoNewLine
			$copiedItem = Copy-Item -LiteralPath $object.FullName -Destination $destination -Force -Verbose:$VerbosePreference -WhatIf:$WhatIfPreference -PassThru #-ErrorAction SilentlyContinue
			if($null -ne $copiedItem) { 
				$script:synchronizedFiles += 1
				write-Log -level 'INFO' -noOutput:$noSyncLogOutput -message "Synchronized  $destination"
			}
		} else {
			$replicaFile = $replicaSummary.Values.Where({$_.RelativeTarget -eq $object.RelativeTarget})
			$fileExists = !!($replicaFile)
			$isNewerFile = ($replicaFile.LastWriteFileTimeUTC -gt $object.LastWriteFileTimeUTC) -or ($replicaFile.LastAccessFileTimeUTC -gt $object.LastAccessFileTimeUTC) -or ($replicaFile.CreationTimeFileTimeUTC -gt $object.CreationTimeFileTimeUTC)
			if ($fileExists -and $isNewerFile) {
				write-Log -level 'INFO' -noOutput:$noSyncLogOutput -message "Skipping $($object.FullName) in favor of newer file $destination"
				$script:skipped += 1
				continue; #keep newer file
			} else {
				#synchronize not newer files
				write-Log -level 'INFO' -noOutput:$noSyncLogOutput -message "Synchronizing $destination" -NoNewLine
				$copiedItem = Copy-Item -LiteralPath $object.FullName -Destination $destination -Force -Verbose:$VerbosePreference -WhatIf:$WhatIfPreference -PassThru #-ErrorAction SilentlyContinue
				if($null -ne $copiedItem) { 
					$script:synchronizedFiles += 1
					write-Log -level 'INFO' -noOutput:$noSyncLogOutput -message "Synchronized  $destination"
				}
			}
		}
	}
	
	if($copiedItem -and $syncMetadata) {
		$isOutOfSync = $object.MetadataHash -ne (get-ObjectMap -direction Replica -objectList $copiedItem -type $type -path $replica -enumerate).MetadataHash
		if($isOutOfSync) {
			sync-Metadata -from $object -to $copiedItem -metadataLog:$metadataLog
		} else {
			Write-Verbose "$($copiedItem.FullName) - Skipped syncing (already synced)"
		}
	}
	$progress++
}
$ProgressPreference = $progressValue
}
filter script:sync-Metadata {
[CmdletBinding()]
param([Parameter(Mandatory=$true, ValueFromPipeline=$false)]$from, [Parameter(Mandatory=$true, ValueFromPipeline=$false)]$to, [switch]$metadataLog=$false)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters

$fromExists = -not ([int]([System.IO.FileInfo]$from.FullName).Attributes -lt 0)
$toExists = -not ([int]([System.IO.FileInfo]$to.FullName).Attributes -lt 0)

if($fromExists -and $toExists) {
	$to.LastWriteTimeUtc = get-DateFromFileTimeUTC -filetime $from.LastWriteFileTimeUTC
	$to.LastAccessTimeUtc = get-DateFromFileTimeUTC -filetime $from.LastAccessFileTimeUTC
	$to.CreationTimeUtc = get-DateFromFileTimeUTC -filetime $from.CreationTimeFileTimeUTC
	if($to.Attributes -eq [FileAttributes]::FILE_ATTRIBUTE_DIRECTORY -and $metadataLog) { 
		write-Log -level 'INFO' -ForeGroundColor DarkYellow -message "Synchronized  $($to.Fullname) metadata."
	}
}

}
filter script:restore-Replica {
param($otherFiles)

trace-Command -commandName $MyInvocation.MyCommand.Name -boundParams $PSBoundParameters
$script:removed = 0
if($null -ne $otherFiles) {
	if (-not $keepOtherFiles) {
		if($otherFiles.count -gt 0) {
			$items = Get-Item -LiteralPath $otherFiles.FullName -ErrorAction SilentlyContinue
			foreach ($item in $items) {
				write-Log -level 'INFO' -message "Replica removal of item $($item.FullName)"
				$item | Remove-Item -Verbose:$VerbosePreference -WhatIf:$WhatIfPreference -recurse -Force -ErrorAction SilentlyContinue
			}
			$script:removed = $otherFiles.count - (Get-Item -LiteralPath $otherFiles.FullName -ErrorAction SilentlyContinue).count
		}
	} else {
		write-Log -level 'INFO' -message "Skipping other files. Remove parameter keepOtherFiles to remove other files."
	}
}

#restore metadata for base level directory
write-Log -level 'VERBOSE' -message "Checking metadata for replica base level directory $($replica.FullName)"
$sourceMetadata = get-ObjectMap -direction Replica -objectList $source -type 'Folder' -path $source -enumerate

try {
	sync-Metadata -from $sourceMetadata -to $replica
} catch {
	Write-Host "MESSAGE: Unable to change properties on Replica basefolder '$($replica.BaseName)'"-ForegroundColor Cyan
	Write-Host "ACTION: Please open powershell as administrator or close any opened handles to $($replica.fullname)"-ForegroundColor Cyan
	Write-Host "REASON: $($_.Exception.InnerException.Message)" -ForeGround Red
}
}

}

#Load filters by dot-sourcing
.$filters

$syncEnvironment = set-syncEnvironment -source $source -replica $replica -logPath $logPath -loglevel $loglevel -namespaceConvention $namespaceConvention

$ErrorActionPreference = "SilentlyContinue"
Remove-Variable -Name 'source','replica','logPath'
Set-Variable -Name "source" -Value $syncEnvironment.source -Scope Script #-Option constant
Set-Variable -Name "replica" -Value $syncEnvironment.replica -Scope Script #-Option constant
Set-Variable -Name "logPath" -Value $syncEnvironment.logPath -Scope Script #-Option constant
$ErrorActionPreference = "Continue"
Start-Transcript -Path $logPath -Verbose:$VerbosePreference

write-Log -level INFO -message "Source target: $($source.FullName)"
write-Log -level INFO -message "Replica target: $($replica.FullName)"

$script:firstSync = $true
$global:syncAuditFolderCollection = @{}	#folders with changes. Used to feed into the SyncAudit process to audit only changed folders instead of having to read the entire source summary

#Keeps track of changes actively as soon as the process starts
if(-not $noSyncMonitor) {
		Start-sourceMonitorSync -source $source -replica $replica | Out-Null
}

$syncProcess = {
	if ($null -ne $syncAuditTimer -and $syncAuditTimer.Enabled) { $syncAuditTimer.Stop() }
	if($firstSync) {
		write-Log -level INFO -message "Initializing. Please wait..."
		$sourcePaths = $source
		$replicaPaths = $replica
	} elseif($global:syncAuditFolderCollection.Count -eq 0) {
		$sourcePaths = $null
		$replicaPaths = $null
		#write-Log -level INFO -message "syncAuditFolderCollection -eq 0. 0 audit"
	} else {
		#write-Log -level INFO -message "syncAuditFolderCollection audit start"
		$relativePaths = $global:syncAuditFolderCollection.Keys
		$global:syncAuditFolderCollection = @{}
		$sourcePaths = foreach ($relativePath in $relativePaths) {
			$sp = [IO.Path]::Combine($source,$relativePath)
			#quick check if directory still exists
			[System.IO.DirectoryInfo]$sp | Where-Object Attributes -eq ([FileAttributes]::FILE_ATTRIBUTE_DIRECTORY)
		}
		$replicaPaths = foreach ($relativePath in $relativePaths) {
			$rp = [IO.Path]::Combine($replica,$relativePath)
			[System.IO.DirectoryInfo]$rp | Where-Object Attributes -eq ([FileAttributes]::FILE_ATTRIBUTE_DIRECTORY)
		}
	}
	
	if($firstSync) { write-Log -level INFO -message "Verifying source $($source.FullName)" }
	$sourceSummary = foreach ($path in $sourcePaths) { get-Summary -direction "Source" -path $path }
	if($sourceSummary) {
		$hasRequirements = test-syncRequirements -sourceSummary $sourceSummary -replica $replica	
		if ($hasRequirements) {
			if($firstSync) { write-Log -level INFO -message "Verifying replica $($replica.FullName)" }
			$replicaSummary = foreach ($path in $replicaPaths) { get-Summary -direction "Replica" -path $path }
			$objectsToSync = $sourceSummary[($sourceSummary.Keys.Where({$_ -notin $replicaSummary.Keys}))]
			#1. Create folder structure on replica:
			sync-Objects -type Folder -objectsToSync $objectsToSync -replica $replica	#folder structure first
			#2. Synchronize files and file metadata on replica:
			sync-Objects -type File -objectsToSync $objectsToSync -replica $replica -syncMetadata
			#3. Synchronize folder metadata on replica:
			sync-Objects -type Folder -objectsToSync $objectsToSync -replica $replica -syncMetadata
			#4. cleanUp replica (files in replica not in source):
			$otherFiles = $replicaSummary.Values.Where({$_.RelativeTarget -notin $sourceSummary.Values.RelativeTarget})
			restore-Replica -otherFiles $otherFiles
		}
	}
	$script:firstSync = $false
	if ($null -ne $syncAuditTimer -and -not $syncAuditTimer.Enabled) { $syncAuditTimer.Start() }
}
.$syncProcess

write-Log -level INFO -message "Synchronized $(0 + $script:synchronizedFiles) file(s)"
write-Log -level INFO -message "Synchronized $(0 + $script:synchronizedFolders) folder(s)"
write-Log -level INFO -message "Skipped $(0 + $script:skipped) file(s)"
write-Log -level INFO -message "Removed $(0 + $script:removed) item(s)"	#items = files + folders
write-Log -level INFO -message "Ending Job at $((Get-Date).ToString('dd_mm_yyyy_hh_mm_ss'))"

if(-not $noSyncMonitor -and ($null -ne (Get-EventSubscriber -SourceIdentifier "ProcessDirectoryChanges" -ErrorAction SilentlyContinue))) {
	write-Log -level INFO -message "Reminder: Actively monitoring changes on $($source.fullname)..."

	#syncAudit complements the active monitoring if syncAuditInterval is set. Used to backup the syncMonitor in case something goes wonky.
	if($null -ne $syncAuditInterval) {
		$script:syncAuditTimer = New-Object System.Timers.Timer
		$syncAuditTimer.Interval = $syncAuditInterval * 1000	#miliseconds
		$syncAuditTimer.AutoReset = $true
		$null = Register-ObjectEvent -InputObject $syncAuditTimer -EventName Elapsed -Action $syncProcess -SourceIdentifier "SyncAuditEvery$($syncAuditInterval)Seconds" #-SupportEvent
		
	}
}

}