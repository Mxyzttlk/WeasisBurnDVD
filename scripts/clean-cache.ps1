$cacheDirs = Get-ChildItem "$env:USERPROFILE\.weasis\cache-*" -Directory -ErrorAction SilentlyContinue
if ($cacheDirs) {
    foreach ($d in $cacheDirs) {
        Write-Host "Removing: $($d.FullName)"
        Remove-Item -Recurse -Force $d.FullName
    }
    Write-Host "Cache cleaned."
} else {
    Write-Host "No cache directories found."
}
