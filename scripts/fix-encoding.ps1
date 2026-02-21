$filePath = "E:\Weasis Burn\templates\splash-loader.ps1"
$content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
[System.IO.File]::WriteAllText($filePath, $content, $utf8Bom)
Write-Host "Done: saved with UTF-8 BOM"
