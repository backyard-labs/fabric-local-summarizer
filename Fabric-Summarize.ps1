#requires -Version 5.1
<##
.SYNOPSIS
    Interactively summarizes web pages, YouTube transcripts, local documents,
    and local audio/video with Fabric, using a selected local Ollama chat model.

.DESCRIPTION
    The elapsed time measures the Fabric processing call only; it excludes
    time spent choosing the source/model and loading a local text file.

    Web-page scraping uses Fabric's configured Jina integration. YouTube
    transcript retrieval requires yt-dlp. Audio/video transcription uses
    Fabric's separate transcription capability/model; -m selects the Ollama
    model used for the summarize pattern, and does not guarantee local
    transcription. Review your Fabric transcription configuration if local
    processing is required.

    Plain-text input accepts text-based files such as .txt, .md, .vtt, .srt,
    .log, and .csv. PDF input requires pdftotext. DOCX input requires Pandoc.
    Extracted document text is piped to Fabric.
#>

$ErrorActionPreference = 'Stop'

# Soft alert for local text and extracted documents. This is a practical
# safeguard, not a model-specific context limit; adjust it if desired.
$LongInputWarningChars = 8000

function Read-RequiredInput {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        Write-Host 'Please enter a value.' -ForegroundColor Yellow
    }
}

function Read-LocalFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $manualChoice = (Read-Host "Press Enter to browse for a file, or type P to enter its path").Trim()
    if ($manualChoice -match '^(?i:p|path)$') {
        return Read-RequiredInput 'Enter the local file path'
    }
    if (-not [string]::IsNullOrWhiteSpace($manualChoice)) {
        Write-Host 'Opening the file picker.' -ForegroundColor DarkCyan
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = $Title
        $dialog.Filter = $Filter
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        $dialog.RestoreDirectory = $true
        $documentsFolder = [Environment]::GetFolderPath('MyDocuments')
        if (Test-Path -LiteralPath $documentsFolder -PathType Container) {
            $dialog.InitialDirectory = $documentsFolder
        }

        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    }
    catch {
        Write-Host "File picker could not open: $($_.Exception.Message)" -ForegroundColor Yellow
        return Read-RequiredInput 'Enter the local file path instead'
    }
    finally {
        if ($null -ne $dialog) { $dialog.Dispose() }
    }
}

function Get-OllamaModels {
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw "Ollama was not found in PATH. Open a terminal where 'ollama list' works, then run this script again."
    }

    $lines = @(& ollama list 2>&1)
    $ollamaExitCode = $LASTEXITCODE
    if ($ollamaExitCode -ne 0) {
        throw "'ollama list' failed with exit code $ollamaExitCode. Make sure Ollama is running."
    }

    $models = @(
        $lines |
            Select-Object -Skip 1 |
            ForEach-Object {
                $line = [string]$_
                if ($line -match '^\s*(\S+)\s+') { $Matches[1] }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($models.Count -eq 0) {
        throw "No Ollama models were listed. Run 'ollama pull <model>' first."
    }
    return $models
}

function Read-ModelChoice {
    param([Parameter(Mandatory = $true)][string[]]$Models)

    Write-Host "`nLocal Ollama models:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Models.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $Models[$i])
    }

    while ($true) {
        $answer = (Read-Host 'Select a model number').Trim()
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Models.Count) {
            return $Models[$number - 1]
        }
        Write-Host ('Enter a number from 1 to {0}.' -f $Models.Count) -ForegroundColor Yellow
    }
}

function Get-LocalText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()

    $textExtensions = @('.txt', '.text', '.md', '.markdown', '.vtt', '.srt', '.log', '.csv')
    if ($extension -notin $textExtensions) {
        throw "Option 3 expects a plain-text file ($($textExtensions -join ', ')). For PDF or Word .docx, choose option 4."
    }
    return [System.IO.File]::ReadAllText($resolvedPath)
}

function Get-DocumentText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
    switch ($extension) {
        '.pdf' {
            if (-not (Get-Command pdftotext -ErrorAction SilentlyContinue)) {
                throw 'PDF extraction needs pdftotext (provided by Poppler) in PATH. Install it, reopen PowerShell, and try again; or extract the PDF to .txt and use option 3.'
            }
            $text = @(& pdftotext -enc UTF-8 $resolvedPath - 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "pdftotext failed: $($text -join [Environment]::NewLine)" }
            return ($text -join [Environment]::NewLine)
        }
        '.docx' {
            if (-not (Get-Command pandoc -ErrorAction SilentlyContinue)) {
                throw 'Word .docx extraction needs Pandoc in PATH. Install it, reopen PowerShell, and try again; or save/export the document as .txt and use option 3.'
            }
            $text = @(& pandoc $resolvedPath -t plain 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "Pandoc failed: $($text -join [Environment]::NewLine)" }
            return ($text -join [Environment]::NewLine)
        }
        default {
            throw 'Option 4 supports PDF and Word .docx files. Choose option 3 for plain-text files.'
        }
    }
}

function Add-FabricOutputLine {
    param([Parameter(Mandatory = $true)]$Line)

    $rendered = [string]$Line
    [void]$script:FabricOutput.Add($rendered)
    Write-Host $rendered
}

try {
    if (-not (Get-Command fabric -ErrorAction SilentlyContinue)) {
        throw "Fabric was not found in PATH. Open a terminal where 'fabric --version' works, then run this script again."
    }

    Write-Host 'Fabric Summarizer' -ForegroundColor Cyan
    Write-Host 'Choose the content you want to summarize:'
    Write-Host '  [1] Web page URL'
    Write-Host '  [2] YouTube video URL (summarize its transcript)'
    Write-Host '  [3] Local text, transcript, or notes (plain text only)'
    Write-Host '      Examples: .txt, .md, .vtt, .srt, .log, .csv; PDF/Word use option 4.'
    $pdfToolStatus = if (Get-Command pdftotext -ErrorAction SilentlyContinue) { 'available' } else { 'needs pdftotext' }
    $wordToolStatus = if (Get-Command pandoc -ErrorAction SilentlyContinue) { 'available' } else { 'needs Pandoc' }
    Write-Host ("  [4] PDF or Word .docx document (PDF: {0}; Word: {1})" -f $pdfToolStatus, $wordToolStatus)
    Write-Host '  [5] Local audio or video file (transcribe, then summarize)'

    $sourceType = ''
    while ($sourceType -notin @('1', '2', '3', '4', '5')) {
        $sourceType = (Read-Host 'Select source type [1-5]').Trim()
        if ($sourceType -notin @('1', '2', '3', '4', '5')) {
            Write-Host 'Enter a number from 1 to 5.' -ForegroundColor Yellow
        }
    }

    $source = $null
    $textInput = $null
    switch ($sourceType) {
        '1' {
            $source = Read-RequiredInput 'Enter the web page URL'
            $fabricArgs = @('-u', $source, '-p', 'summarize')
        }
        '2' {
            if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
                throw "yt-dlp was not found in PATH. Install it, open a new terminal, and confirm 'yt-dlp --version' works."
            }
            $source = Read-RequiredInput 'Enter the YouTube video URL'
            $fabricArgs = @('-y', $source, '-p', 'summarize')
        }
        '3' {
            $textFileFilter = 'Text files (*.txt;*.text;*.md;*.markdown;*.vtt;*.srt;*.log;*.csv)|*.txt;*.text;*.md;*.markdown;*.vtt;*.srt;*.log;*.csv|All files (*.*)|*.*'
            $source = Read-LocalFilePath -Filter $textFileFilter -Title 'Select a plain-text file to summarize'
            if ([string]::IsNullOrWhiteSpace($source)) {
                Write-Host 'Cancelled; no file was selected.'
                return
            }
            $textInput = Get-LocalText -Path $source
            if ([string]::IsNullOrWhiteSpace($textInput)) {
                throw 'The selected file did not yield any text to summarize.'
            }
            $fabricArgs = @('-p', 'summarize')
        }
        '4' {
            Write-Host '  [1] PDF (.pdf)'
            Write-Host '  [2] Word document (.docx)'
            $documentType = ''
            while ($documentType -notin @('1', '2')) {
                $documentType = (Read-Host 'Select document type [1-2]').Trim()
                if ($documentType -notin @('1', '2')) { Write-Host 'Enter 1 or 2.' -ForegroundColor Yellow }
            }
            if ($documentType -eq '1' -and -not (Get-Command pdftotext -ErrorAction SilentlyContinue)) {
                throw 'PDF option is unavailable because pdftotext is not installed. Install Poppler and ensure pdftotext is in PATH, or extract the PDF to .txt and use option 3.'
            }
            if ($documentType -eq '2' -and -not (Get-Command pandoc -ErrorAction SilentlyContinue)) {
                throw 'Word option is unavailable because Pandoc is not installed. Install Pandoc and ensure it is in PATH, or export the document to .txt and use option 3.'
            }
            $expectedExtension = if ($documentType -eq '1') { '.pdf' } else { '.docx' }
            if ($documentType -eq '1') {
                $documentFilter = 'PDF files (*.pdf)|*.pdf|All files (*.*)|*.*'
                $pickerTitle = 'Select a PDF document to summarize'
            }
            else {
                $documentFilter = 'Word documents (*.docx)|*.docx|All files (*.*)|*.*'
                $pickerTitle = 'Select a Word document to summarize'
            }
            $source = Read-LocalFilePath -Filter $documentFilter -Title $pickerTitle
            if ([string]::IsNullOrWhiteSpace($source)) {
                Write-Host 'Cancelled; no file was selected.'
                return
            }
            if ([System.IO.Path]::GetExtension($source).ToLowerInvariant() -ne $expectedExtension) {
                throw "The selected document type requires a $expectedExtension file."
            }
            $textInput = Get-DocumentText -Path $source
            if ([string]::IsNullOrWhiteSpace($textInput)) {
                throw 'No text was extracted from the selected document. It may contain scanned images; use OCR to create searchable text, then retry.'
            }
            $fabricArgs = @('-p', 'summarize')
        }
        '5' {
            Write-Host "`nAudio/video transcription uses Fabric's separate transcription model, not the selected Ollama chat model. Depending on your configuration, the media may be sent to an external provider and could incur charges." -ForegroundColor Yellow
            $transcriptionConsent = (Read-Host 'Continue with transcription? [y/N]').Trim()
            if ($transcriptionConsent -notmatch '^(?i:y|yes)$') {
                Write-Host 'Cancelled before sending the media for transcription.'
                return
            }
            $source = Read-RequiredInput 'Enter the local audio/video file path'
            $resolvedMediaPath = (Resolve-Path -LiteralPath $source -ErrorAction Stop).Path
            $media = Get-Item -LiteralPath $resolvedMediaPath
            $fabricArgs = @('--transcribe-file', $resolvedMediaPath)
            if ($media.Length -gt 25MB) {
                if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
                    throw 'This media file is larger than 25 MB. Install ffmpeg and put it in PATH so Fabric can split larger media files, then retry.'
                }
                $fabricArgs += '--split-media-file'
            }
            $fabricArgs += @('-p', 'summarize')
        }
    }

    if ($null -ne $textInput -and $textInput.Length -gt $LongInputWarningChars) {
        $approxTokens = [math]::Ceiling($textInput.Length / 4.0)
        Write-Host "`nLong input warning" -ForegroundColor Yellow
        Write-Host ('This file contains {0:N0} characters (roughly {1:N0} tokens at 4 characters per token).' -f $textInput.Length, $approxTokens) -ForegroundColor Yellow
        Write-Host 'The estimate varies by text and language. Fabric instructions and the requested summary also use the model context window.' -ForegroundColor Yellow
        Write-Host 'A long input may exceed the context available to the selected Ollama model or produce an incomplete summary.' -ForegroundColor Yellow
        $continueWithLongInput = (Read-Host 'Continue and send this full text to Fabric? [y/N]').Trim()
        if ($continueWithLongInput -notmatch '^(?i:y|yes)$') {
            Write-Host 'Cancelled before sending the text to Fabric.'
            return
        }
    }

    $models = Get-OllamaModels
    $selectedModel = Read-ModelChoice -Models $models
    $fabricArgs += @('-V', 'Ollama', '-m', $selectedModel)

    Write-Host "`nSource: $source" -ForegroundColor DarkCyan
    Write-Host "Model:  Ollama/$selectedModel" -ForegroundColor DarkCyan
    Write-Host 'Starting Fabric. Elapsed time will be shown when it finishes.' -ForegroundColor DarkCyan
    Write-Host ''

    $script:FabricOutput = [System.Collections.Generic.List[string]]::new()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $fabricExitCode = 0
    try {
        if ($null -ne $textInput) {
            $textInput | & fabric @fabricArgs 2>&1 | ForEach-Object { Add-FabricOutputLine -Line $_ }
        }
        else {
            & fabric @fabricArgs 2>&1 | ForEach-Object { Add-FabricOutputLine -Line $_ }
        }
        $fabricExitCode = $LASTEXITCODE
    }
    finally {
        $timer.Stop()
    }

    Write-Host ''
    if ($fabricExitCode -eq 0) {
        Write-Host ('Fabric completed in {0:N1} seconds.' -f $timer.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    else {
        Write-Host ('Fabric exited with code {0} after {1:N1} seconds.' -f $fabricExitCode, $timer.Elapsed.TotalSeconds) -ForegroundColor Red
        Write-Host 'Summary was not saved because Fabric did not complete successfully.' -ForegroundColor Yellow
        exit $fabricExitCode
    }

    $saveChoice = (Read-Host 'Save the output to a Markdown file? [y/N]').Trim()
    if ($saveChoice -match '^(?i:y|yes)$') {
        $outputPath = Read-RequiredInput 'Enter the output file path'
        $fullOutputPath = [System.IO.Path]::GetFullPath($outputPath)
        $parent = Split-Path -Parent $fullOutputPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "Output folder does not exist: $parent"
        }

        $report = @(
            '# Fabric Summary'
            ''
            "- Source: $source"
            "- Model: Ollama/$selectedModel"
            ('- Fabric elapsed time: {0:N1} seconds' -f $timer.Elapsed.TotalSeconds)
            ''
            '## Output'
            ''
            $script:FabricOutput
        )
        $mayWrite = $true
        if (Test-Path -LiteralPath $fullOutputPath -PathType Leaf) {
            $overwrite = (Read-Host "File already exists. Overwrite it? [y/N]").Trim()
            $mayWrite = $overwrite -match '^(?i:y|yes)$'
        }
        if ($mayWrite) {
            $report | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8
            Write-Host "Saved: $fullOutputPath" -ForegroundColor Green
        }
        else {
            Write-Host 'Save cancelled; the existing file was left unchanged.'
        }
    }

}
catch {
    Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}