# Zip-Project.ps1
# Run this script inside your project folder.
# It creates: ProjectFolder\ProjectFolderName.zip

Add-Type -AssemblyName System.IO.Compression.FileSystem

$projectPath = [System.IO.Path]::GetFullPath((Get-Location).Path)
$projectName = Split-Path $projectPath -Leaf
$parentPath  = Split-Path $projectPath -Parent
$zipPath     = Join-Path $projectPath ($projectName + ".zip")

$tempRoot      = Join-Path $env:TEMP ("ZipProject_" + [Guid]::NewGuid().ToString("N"))
$stagingPath   = Join-Path $tempRoot $projectName
$gitignorePath = Join-Path $projectPath ".gitignore"

# Counters
$script:CopiedFileCount    = 0
$script:SkippedFileCount   = 0
$script:SkippedFolderCount = 0
$script:CreatedFolderCount = 0

# Common exclusions even if .gitignore does not exist
$defaultExcludedFolders = @(
    ".vs",
    "bin",
    "obj",
    "packages",
    "node_modules",
    ".git",
    "TestResults",
    "_ReSharper.Caches",
    ".idea",
    "publish"
)

$defaultExcludedFilePatterns = @(
    "*.user",
    "*.rsuser",
    "*.suo",
    "*.cache",
    "*.pdb",
    "*.exe",
    "*.dll",
    "*.zip",
    "*.nupkg",
    "*.log",
    "*.tmp"
)

$defaultExcludedFileNames = @(
    "Zip-Project.ps1",
    "Zip-Project.bat"
)

function Write-Step {
    param([string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Done {
    param([string]$Message)
    Write-Host "[DONE] $Message"
}

function Write-Skip {
    param([string]$Message)
    Write-Host "[SKIP] $Message"
}

function Convert-ToRelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $baseUri = New-Object System.Uri(($BasePath.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri($TargetPath)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', '\')
}

function Get-GitIgnoreRules {
    param([string]$Path)

    $rules = @()

    if (-not (Test-Path $Path)) {
        Write-Step "No .gitignore found."
        return $rules
    }

    Write-Step "Reading .gitignore rules..."

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line.StartsWith("#")) { return }

        # Ignore negation rules for now (!something)
        if ($line.StartsWith("!")) { return }

        $rules += $line
    }

    Write-Done ("Loaded {0} .gitignore rule(s)." -f $rules.Count)
    return $rules
}

function Test-DefaultFolderExcluded {
    param([string]$FolderName)

    return $defaultExcludedFolders -contains $FolderName
}

function Test-DefaultFileExcluded {
    param([string]$FileName)

    if ($defaultExcludedFileNames -contains $FileName) {
        return $true
    }

    foreach ($pattern in $defaultExcludedFilePatterns) {
        if ($FileName -like $pattern) {
            return $true
        }
    }

    return $false
}

function Convert-GitIgnoreToWildcard {
    param([string]$Rule)

    $r = $Rule.Trim()

    if ($r.StartsWith("/")) {
        $r = $r.Substring(1)
    }

    if ($r.EndsWith("/")) {
        $r = $r.TrimEnd("/")
        return @("$r", "$r\*", "*\$r", "*\$r\*")
    }

    # Safer wildcard handling
    return @($r, "*\$r", "$r")
}

function Test-GitIgnoreMatch {
    param(
        [string]$RelativePath,
        [bool]$IsDirectory,
        [string[]]$GitIgnoreRules
    )

    $normalPath = $RelativePath.Replace('/', '\').TrimStart('\')

    foreach ($rule in $GitIgnoreRules) {
        $patterns = Convert-GitIgnoreToWildcard -Rule $rule

        foreach ($pattern in $patterns) {
            if ($normalPath -like $pattern) {
                return $true
            }
        }

        # folder-name-only rule like bin or obj
        if ($IsDirectory -and ($normalPath.Split('\') -contains $rule.Trim('/'))) {
            return $true
        }
    }

    return $false
}

function Copy-FilteredContent {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$ProjectRoot,
        [string[]]$GitIgnoreRules
    )

    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        $script:CreatedFolderCount++
    }

    Get-ChildItem -LiteralPath $SourcePath -Force | ForEach-Object {
        $item = $_
        $target = Join-Path $DestinationPath $item.Name
        $relativePath = Convert-ToRelativePath -BasePath $ProjectRoot -TargetPath $item.FullName

        if ($item.PSIsContainer) {
            if (Test-DefaultFolderExcluded -FolderName $item.Name) {
                $script:SkippedFolderCount++
                Write-Skip "Folder excluded: $relativePath"
                return
            }

            if (Test-GitIgnoreMatch -RelativePath $relativePath -IsDirectory $true -GitIgnoreRules $GitIgnoreRules) {
                $script:SkippedFolderCount++
                Write-Skip "Folder excluded by .gitignore: $relativePath"
                return
            }

            Write-Step "Entering folder: $relativePath"
            Copy-FilteredContent -SourcePath $item.FullName -DestinationPath $target -ProjectRoot $ProjectRoot -GitIgnoreRules $GitIgnoreRules
            Write-Done "Finished folder: $relativePath"
        }
        else {
            if (Test-DefaultFileExcluded -FileName $item.Name) {
                $script:SkippedFileCount++
                Write-Skip "File excluded: $relativePath"
                return
            }

            if (Test-GitIgnoreMatch -RelativePath $relativePath -IsDirectory $false -GitIgnoreRules $GitIgnoreRules) {
                $script:SkippedFileCount++
                Write-Skip "File excluded by .gitignore: $relativePath"
                return
            }

            Write-Step "Copying file: $relativePath"
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
            $script:CopiedFileCount++
            Write-Done "Copied file: $relativePath"
        }
    }
}

try {
    Write-Step "Starting project zip process..."
    Write-Step "Project path: $projectPath"

    if (-not (Test-Path $projectPath -PathType Container)) {
        throw "Project path does not exist or is not a folder: $projectPath"
    }

    Write-Done "Project folder validated."

    $gitIgnoreRules = Get-GitIgnoreRules -Path $gitignorePath

    if (Test-Path $zipPath) {
        Write-Step "Removing old ZIP: $zipPath"
        Remove-Item -LiteralPath $zipPath -Force
        Write-Done "Old ZIP removed."
    }
    else {
        Write-Step "No existing ZIP found."
    }

    if (Test-Path $tempRoot) {
        Write-Step "Removing old temporary folder: $tempRoot"
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
        Write-Done "Old temporary folder removed."
    }

    Write-Step "Creating staging folder..."
    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
    $script:CreatedFolderCount++
    Write-Done "Staging folder created: $stagingPath"

    Write-Step "Copying filtered project content..."
    Copy-FilteredContent -SourcePath $projectPath -DestinationPath $stagingPath -ProjectRoot $projectPath -GitIgnoreRules $gitIgnoreRules
    Write-Done "Finished copying filtered project content."

    Write-Step "Creating ZIP archive..."
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingPath, $zipPath)
    Write-Done "ZIP archive created."

    Write-Host ""
    Write-Host "========== SUMMARY =========="
    Write-Host "ZIP file         : $zipPath"
    Write-Host "Copied files     : $script:CopiedFileCount"
    Write-Host "Skipped files    : $script:SkippedFileCount"
    Write-Host "Skipped folders  : $script:SkippedFolderCount"
    Write-Host "Created folders  : $script:CreatedFolderCount"
    Write-Host "============================="
}
finally {
    if (Test-Path $tempRoot) {
        Write-Step "Cleaning temporary files..."
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
        Write-Done "Temporary files cleaned."
    }

    Write-Done "Process completed."
}