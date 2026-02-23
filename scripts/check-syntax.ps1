$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile('E:\Weasis Burn\app\pacs-burner.ps1', [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) {
    Write-Host "NO ERRORS"
} else {
    foreach ($e in $errors) {
        Write-Host "Line $($e.Extent.StartLineNumber): $($e.Message)"
    }
}
