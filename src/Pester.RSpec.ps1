function Find-File {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [String[]] $Path,
        [String[]] $ExcludePath,
        [Parameter(Mandatory=$true)]
        [string] $Extension
    )


    $files =
        foreach ($p in $Path) {
            if ([String]::IsNullOrWhiteSpace($p))
            {
                continue
            }

            if ((& $script:SafeCommands['Test-Path'] $p)) {
                # This can expand to more than one path when wildcard is used, those paths can be folders or files.
                # We want to avoid expanding to paths that are not matching our filters, but also want to ensure that if
                # user passes in MyTestFile.ps1 without the .Tests.ps1 it will still run.

                # So at this step we look if we expanded the path to more than 1 item and use stricter rules with filtering.
                # Or if the file was just a single file, we won't use stricter filtering for files.

                # This allows us to use wildcards to get all .Tests.ps1 in the folder and all child folders, which is very useful.
                # But prevents a rare scenario where you provide C:\files\*\MyTest.ps1, because in that case only .Tests.ps1 would be included.

                $items = & $SafeCommands['Get-Item'] $p
                $resolvedToMultipleFiles = $null -ne $items -and 1 -lt @($items).Length

                foreach ($item in $items) {
                    if ($item.PSIsContainer) {
                        # this is an existing directory search it for tests file
                        & $SafeCommands['Get-ChildItem'] -Recurse -Path $item -Filter "*$Extension" -File
                    }
                    elseif ("FileSystem" -ne $item.PSProvider.Name) {
                        # item is not a directory and exists but is not a file so we are not interested
                    }
                    elseif ($resolvedToMultipleFiles) {
                        # item was resolved from a wildcarded path only use it if it has test extension
                        if ($item.FullName -like "*$Extension")
                        {
                            # add unresolved path to have a note of the original path used to resolve this
                            & $SafeCommands['Add-Member'] -Name UnresolvedPath -Type NoteProperty -Value $p -InputObject $item
                            $item
                        }
                    }
                    else {
                        # this is some file, that was either provided directly, or resolved from wildcarded path as a single item,
                        # we don't care what type of file it is, or if it has test extension (.Tests.ps1) we should try to run it
                        # to allow any file that is provided directly to run
                        if (".ps1" -ne $item.Extension) {
                            & $SafeCommands['Write-Error'] "Script path '$item' is not a ps1 file." -ErrorAction Stop
                        }

                        # add unresolved path to have a note of the original path used to resolve this
                        & $SafeCommands['Add-Member'] -Name UnresolvedPath -Type NoteProperty -Value $p -InputObject $item
                        $item
                    }
                }
            }
            else {
                # this is a path that does not exist so let's hope it is
                # a wildcarded path that will resolve to some files
                & $SafeCommands['Get-ChildItem'] -Recurse -Path $p -Filter "*$Extension" -File
            }
        }

    Filter-Excluded -Files $files -ExcludePath $ExcludePath | & $SafeCommands['Where-Object'] { $_ }
}

function Filter-Excluded ($Files, $ExcludePath) {

    if ($null -eq $ExcludePath -or @($ExcludePath).Length -eq 0) {
        return @($Files)
    }

    foreach ($file in @($Files)) {
        # normalize backslashes for cross-platform ease of use
        $p = $file.FullName -replace "/","\"
        $excluded = $false

        foreach ($exclusion in (@($ExcludePath) -replace "/","\")) {
            if ($excluded) {
                continue
            }

            if ($p -like $exclusion) {
                $excluded = $true
            }
        }

        if (-not $excluded) {
            $file
        }
    }
}

function Add-RSpecTestObjectProperties {
    param ($TestObject)

    # adds properties that are specific to RSpec to the result object
    # this includes figuring out the result
    # formatting the failure message and stacktrace

    $TestObject.Result = if ($TestObject.Skipped) {
        "Skipped"
    }
    elseif ($TestObject.Passed) {
        "Passed"
    }
    elseif ($TestObject.ShouldRun -and (-not $TestObject.Executed -or -not $TestObject.Passed)) {
        "Failed"
    }
    else {
        "NotRun"
    }

    foreach ($e in $TestObject.ErrorRecord) {
        $r = ConvertTo-FailureLines $e
        $e.PSObject.Properties.Add([Pester.Factory]::CreateNoteProperty("DisplayErrorMessage", [string]($r.Message -join [Environment]::NewLine)))
        $e.PSObject.Properties.Add([Pester.Factory]::CreateNoteProperty("DisplayStackTrace", [string]($r.Trace -join [Environment]::NewLine)))
    }
}

function Add-RSpecBlockObjectProperties ($BlockObject) {
    foreach ($e in $BlockObject.ErrorRecord) {
        $r = ConvertTo-FailureLines $e
        $e.PSObject.Properties.Add([Pester.Factory]::CreateNoteProperty("DisplayErrorMessage", [string]($r.Message -join [Environment]::NewLine)))
        $e.PSObject.Properties.Add([Pester.Factory]::CreateNoteProperty("DisplayStackTrace", [string]($r.Trace -join [Environment]::NewLine)))
    }
}

function PostProcess-RspecTestRun ($TestRun) {

    Fold-Run $Run -OnTest {
        param($t)

        ## decorate
        # we already added the RSpec properties as part of the plugin

        ### summarize
        $TestRun.Tests.Add($t)

        switch ($t.Result) {
            "NotRun" {
                $null = $TestRun.NotRun.Add($t)
            }
            "Passed" {
                $null = $TestRun.Passed.Add($t)
            }
            "Failed" {
                $null = $TestRun.Failed.Add($t)
            }
            "Skipped" {
                $null = $TestRun.Skipped.Add($t)
            }
            default { throw "Result $($t.Result) is not supported."}
        }

    } -OnBlock {
        param ($b)

        ## decorate

        # we already processed errors in the plugin step to make the available for reporting

        $b.Result = if ($b.Skip) {
            "Skipped"
        }
        elseif ($b.Passed) {
            "Passed"
        }
        elseif ($b.ShouldRun -and (-not $b.Executed -or -not $b.Passed)) {
            "Failed"
        }
        else {
            "NotRun"
        }

        ## sumamrize

        # a block that has errors would write into failed blocks so we can report them
        # later we can filter this to only report errors from AfterAll
        if (0 -lt $b.ErrorRecord.Count) {
            $TestRun.FailedBlocks.Add($b)
        }

    } -OnContainer {
        param ($b)

        ## decorate

        # here we add result
        $b.result = if ($b.Skipped) {
            "Skipped"
        }
        elseif ($b.Passed) {
            "Passed"
        }
        elseif ($b.ShouldRun -and (-not $b.Executed -or -not $b.Passed)) {
            "Failed"
        }
        else {
            "NotRun"
        }

        foreach ($e in $b.ErrorRecord) {
            $r = ConvertTo-FailureLines $e
            $e.PSObject.Properties.Add([Pester.Factory]::CreateNoteProperty("DisplayErrorMessage", [string]($r.Message -join [Environment]::NewLine)))
            $e.PSObject.Properties.Add([Pester.Factory]::CreateNoteProperty("DisplayStackTrace", [string]($r.Trace -join [Environment]::NewLine)))
        }

        ## summarize
        if (0 -lt $b.ErrorRecord.Count) {
            $TestRun.FailedContainers.Add($b)
        }

        $TestRun.Duration += $b.Duration
        $TestRun.UserDuration += $b.UserDuration
        $TestRun.FrameworkDuration += $b.FrameworkDuration
        $TestRun.DiscoveryDuration += $b.DiscoveryDuration
    }

    $TestRun.PassedCount = $TestRun.Passed.Count
    $TestRun.FailedCount = $TestRun.Failed.Count
    $TestRun.SkippedCount = $TestRun.Skipped.Count
    $TestRun.NotRunCount = $TestRun.NotRun.Count

    $TestRun.TotalCount = $TestRun.Tests.Count

    $TestRun.FailedBlocksCount = $TestRun.FailedBlocks.Count
    $TestRun.FailedContainersCount = $TestRun.FailedContainers.Count

    $TestRun.Result = if (0 -lt ($TestRun.FailedCount + $TestRun.FailedBlocksCount + $TestRun.FailedContainersCount)) {
        "Failed"
    }
    else {
        "Passed"
    }
}

function Get-RSpecObjectDecoratorPlugin () {
    New-PluginObject -Name "RSpecObjectDecoratorPlugin" `
        -EachTestTeardownEnd {
        param ($Context)

        # TODO: consider moving this into the core if those results are just what we need, but look first at Gherkin and how many of those results are RSpec specific and how many are Gherkin specific
        #TODO: also this is a plugin because it needs to run before the error processing kicks in, this mixes concerns here imho, and needs to be revisited, because the error writing logic is now dependent on this plugin
        Add-RSpecTestObjectProperties $Context.Test
    } -EachBlockTeardownEnd {
        param($Context)
        #TODO: also this is a plugin because it needs to run before the error processing kicks in (to be able to report correctly formatted errors on scrren in case teardown failure), this mixes concerns here imho, and needs to be revisited, because the error writing logic is now dependent on this plugin
        Add-RSpecBlockObjectProperties $Context.Block
    }
}

function New-PesterConfiguration {
    [CmdletBinding()]
    param()

    [PesterConfiguration]@{}
}

function Remove-RSpecNonPublicProperties ($run){
    # $runProperties = @(
    #     'Configuration'
    #     'Containers'
    #     'ExecutedAt'
    #     'FailedBlocksCount'
    #     'FailedCount'
    #     'NotRunCount'
    #     'PassedCount'
    #     'PSBoundParameters'
    #     'Result'
    #     'SkippedCount'
    #     'TotalCount'
    #     'Duration'
    # )

    # $containerProperties = @(
    #     'Blocks'
    #     'Content'
    #     'ErrorRecord'
    #     'Executed'
    #     'ExecutedAt'
    #     'FailedCount'
    #     'NotRunCount'
    #     'PassedCount'
    #     'Result'
    #     'ShouldRun'
    #     'Skip'
    #     'SkippedCount'
    #     'Duration'
    #     'Type' # needed because of nunit export path expansion
    #     'TotalCount'
    # )

    # $blockProperties = @(
    #     'Blocks'
    #     'ErrorRecord'
    #     'Executed'
    #     'ExecutedAt'
    #     'FailedCount'
    #     'Name'
    #     'NotRunCount'
    #     'PassedCount'
    #     'Path'
    #     'Result'
    #     'ScriptBlock'
    #     'ShouldRun'
    #     'Skip'
    #     'SkippedCount'
    #     'StandardOutput'
    #     'Tag'
    #     'Tests'
    #     'Duration'
    #     'TotalCount'
    # )

    # $testProperties = @(
    #     'Data'
    #     'ErrorRecord'
    #     'Executed'
    #     'ExecutedAt'
    #     'ExpandedName'
    #     'Id' # needed because of grouping of data driven tests in nunit export
    #     'Name'
    #     'Path'
    #     'Result'
    #     'ScriptBlock'
    #     'ShouldRun'
    #     'Skip'
    #     'Skipped'
    #     'StandardOutput'
    #     'Tag'
    #     'Duration'
    # )

    Fold-Run $run -OnRun {
        param($i)
        # $ps = $i.PsObject.Properties.Name
        # foreach ($p in $ps) {
        #     if ($p -like 'Plugin*') {
        #         $i.PsObject.Properties.Remove($p)
        #     }
        # }

        $i.PluginConfiguration = $null
        $i.PluginData = $null
        $i.Plugins = $null

    } -OnContainer {
        param($i)
        # $ps = $i.PsObject.Properties.Name
        # foreach ($p in $ps) {
        #     if ($p -like 'Own*') {
        #         $i.PsObject.Properties.Remove($p)
        #     }
        # }

        # $i.FrameworkData = $null
        # $i.PluginConfiguration = $null
        # $i.PluginData = $null
        # $i.Plugins = $null

    } -OnBlock {
        param($i)
        # $ps = $i.PsObject.Properties.Name
        # foreach ($p in $ps) {
        #     if ($p -eq 'FrameworkData' -or $p -like 'Own*' -or $p -like 'Plugin*') {
        #         $i.PsObject.Properties.Remove($p)
        #     }
        # }

        $i.FrameworkData = $null
        $i.PluginData = $null

    } -OnTest {
        param($i)
        # $ps = $i.PsObject.Properties.Name
        # foreach ($p in $ps) {
        #     if ($p -eq 'FrameworkData' -or $p -like 'Plugin*') {
        #         $i.PsObject.Properties.Remove($p)
        #     }
        # }

        $i.FrameworkData = $null
        $i.PluginData = $null
    }
}

function New-PesterContainer {
    <#
    .SYNOPSIS
    Generates ContainerInfo-objects used as for Invoke-Pester -Container

    .DESCRIPTION
    Pester 5 supports running tests files and scriptblocks using parameter-input.
    To use this feature, Invoke-Pester expects one or more ContainerInfo-objects
    created using this funciton, that specify test containers in the form of paths
    to the test files or scriptblocks containing the tests directly.

    A optional Data-dictionary can be provided to supply the containers with any
    required parameter-values. This is useful in when tests are generated dynamically
    based on parameter-input. This method enables complex test-solutions while being
    able to re-use a lot of test-code.

    .PARAMETER Path
    Specifies one or more paths to files containing tests. The value is a path\file
    name or name pattern. Wildcards are permitted.

    .PARAMETER ScriptBlock
    Specifies one or more scriptblocks containing tests.

    .PARAMETER Data
    Allows a dictionary to be provided with parameter-values that should be used during
    execution of the test containers defined in Path or ScriptBlock.

    .EXAMPLE
    ```powershell
    $container = New-PesterContainer -Path 'CodingStyle.Tests.ps1' -Data @{ File = "Get-Emoji.ps1" }
    Invoke-Pester -Container $container
    ```

    This example runs Pester using a generated ContainerInfo-object referencing a file and
    required parameters that's provided to the test-file during execution.

    .EXAMPLE
    ```powershell
    $sb = {
        Describe 'Testing New-PesterContainer' {
            It 'Useless test' {
                "foo" | Should -Not -Be "bar"
            }
        }
    }
    $container = New-PesterContainer -ScriptBlock $sb
    Invoke-Pester -Container $container
    ```

    This example runs Pester agianst a scriptblock. New-PesterContainer is used to genreated
    the requried ContainerInfo-object that enables us to do this directly.

    .LINK
    https://pester.dev/docs/commands/New-PesterContainer

    .LINK
    https://pester.dev/docs/commands/Invoke-Pester

    .LINK
    https://pester.dev/docs/usage/data-driven-tests
    #>
    [CmdletBinding(DefaultParameterSetName="Path")]
    param(
        [Parameter(Mandatory, ParameterSetName = "Path")]
        [String[]] $Path,

        [Parameter(Mandatory, ParameterSetName = "ScriptBlock")]
        [ScriptBlock[]] $ScriptBlock,

        [Collections.IDictionary[]] $Data
    )

    # it seems that when I don't assign $Data to $dt here the foreach does not always work in 5.1 :/ some vooodo
    $dt = $Data
    # expand to ContainerInfo user can provide multiple sets of data, but ContainerInfo can hold only one
    # to keep the internal logic simple.
    $kind = $PSCmdlet.ParameterSetName
    if ('ScriptBlock' -eq $kind) {
        # the @() is significant here, it will make it iterate even if there are no data
        # which allows scriptblocks without data to run
        foreach ($d in @($dt)) {
            foreach ($sb in $ScriptBlock) {
                New-BlockContainerObject -ScriptBlock $sb -Data $d
            }
        }
    }

    if ("Path" -eq $kind) {
        # the @() is significant here, it will make it iterate even if there are no data
        # which allows files without data to run
        foreach ($d in @($dt)) {
            foreach ($p in $Path) {
                # resolve the path we are given in the same way we would resolve -Path on Invoke-Pester
                $files = @(Find-File -Path $p -ExcludePath $PesterPreference.Run.ExcludePath.Value -Extension $PesterPreference.Run.TestExtension.Value)
                foreach ($file in $files) {
                    New-BlockContainerObject -File $file -Data $d
                }
            }
        }
    }
}
