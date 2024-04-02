## LICENSE

GNU AFFERO GENERAL PUBLIC LICENSE
Version 3, 19 November 2007

Copyright (C) 2024 Miguel Vaz

This is a Powershell script project licensed under the GNU Affero General Public License v3.0 (AGPL-3.0) with the following additional disclaimers.

** Disclaimer of Warranty**
THIS PROJECT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THIS PROJECT OR THE USE OR OTHER DEALINGS IN THE PROJECT.

** Disclaimer of Support**
This Project is currently provided without any form of support.

Please refer to LICENSE file for more information.


# File System Monitoring and Replication Tool

## Overview
This project aims to create a robust file system monitoring and replication tool using a PowerShell script. The tool's objective is to monitor a source folder and replicate its changes to a replica folder. Users provide three parameters: the path to the source folder, the path to the replica folder, and the path to a log file for recording output and events.

## Usage Example
```powershell
Sync-FoldersOneWay -source "C:\MyStuff" -replica "E:\MyStuff" -logPath C:\path\to\log
```

## Limitations with FileSystemWatcher Class and reasons for Its Non-Utilization
When implementing this solution, some limitations were encountered with the FileSystemWatcher class provided by .NET. 
These limitations included:
Unordered events. Even with synchronous call attempts to try delegating handlers synchronously, the result did not guarantee the order of events. 
Missing events due to the fact that event handlers were busy while other similar events triggered (classic producer-consumer problem)
The inability to know determine what notify filter was triggered in what event. A possible workaround (if not for the unordered events) would have been to create multiple FileSystemWatcher filters, each one for each Notify Filter. 

Additionally, it did not provide comprehensive information about some file system events, particularly for operations like file moves or replacements. 
The lack of detailed information and an out-of-order event made it challenging to accurately track these operations.

## Solution Approach
To address these limitations, instead of relying on the NTFS change journal, Win32 API calls are used instead to directly read directory changes. Specifically, a PowerShell version of the **ReadDirectoryChangesExW** function is implemented, providing extended information. This approach allows more control over the monitoring process and to access detailed information about file system events in real-time in an as ordered as possible fashion.


## Monitored File System Operations
In this implementation, focus was on monitoring all typical file system operations:

*  Adding a New File: Detecting when a new file is created inside the monitored directory.
*  Changing File Content: Monitoring changes to the content of existing files.
*  Copying a File: Detecting when a file is being copied, including identifying when the copy operation has finished before synchronization starts for that file.
*  Move Operations: Tracking file movements within the file system, both within the same directory and across different directories.
*  Remove Operations: Detecting when files or directories are deleted from the monitored location.
*  Replace Operations: Monitoring when a file is replaced with another file of the same name.

## Additional Features
In addition to these operations, other relevant file system conditions are also captured, that could eventually impact the process, like checking the replica's free space and creating a sync audit process for folders where activity happened, to double-check synchronization woo's in case something goes wonky.

## Implementation Details
As the synchronization process starts, the monitoring starts immediately in case changes are made while the source folder is being processed. Please note that large source folders could take a while. In this implementation, a separate PowerShell runspace running in a separate thread is responsible of gathering the file system events. This separate runspace employs a ConcurrentQueue to gather events and synchronize that information between runspaces without interfering with its synchronous ability to gather events, given a sufficiently large buffer. By using a separate thread, we prevent blocking the main execution thread, ensuring as smooth operation as possible of the monitoring and replication tasks.

## Support for Long Paths
This project also aims to support long paths by leveraging DOS device paths, which should, in theory, support network drives as well.

## OS Requirements:
*  Windows:
	*  Minimum supported client	Windows 10, version 1709 [desktop apps only]
	*  Minimum supported server	Windows Server 2019 [desktop apps only]

*  Linux: 
	*  Not currently supported


## Contributions and License
By leveraging these techniques and the power of Win32 API calls, this project hopes to become a robust file system monitoring and replication tool.
There is ample opportunity for improvement, particularly in terms of performance optimizations, and there may be undiscovered bugs. Therefore, we warmly welcome contributions from the community to further enhance and improve this project under the terms of the provided AGPL-3.0 license.

For any questions or comments regarding this project, feel free to contact me at:
[System.Text.Encoding]::Default.GetString([System.Convert]::FromBase64String('aG1pZ3VlbCBkb3QgdmF6IGF0IG91dGxvb2suY29t'))

We hope you find this project valuable. Please enjoy using and contributing to it!