# Quick Git Push Function
# Add this to your PowerShell profile or run it in your terminal

function push {
    param(
        [string]$message = "Update"
    )
    
    # Handle empty strings
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "Update"
    }
    
    Write-Host "Adding all changes..." -ForegroundColor Cyan
    git add .
    
    Write-Host "Committing with message: '$message'" -ForegroundColor Cyan
    git commit -m $message
    
    Write-Host "Pushing to origin master..." -ForegroundColor Cyan
    git push origin master
    
    Write-Host "Done!" -ForegroundColor Green
}

# Usage:
# push                    -> commits with "Update"
# push "Your message"     -> commits with your custom message
