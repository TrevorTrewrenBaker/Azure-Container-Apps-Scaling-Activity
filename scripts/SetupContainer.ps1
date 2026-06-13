# Ensure Docker is running
Write-Host "=== Pre-Setup Checks ===" -ForegroundColor DarkYellow

# Check Docker
try {
    docker info 2>$null | Out-Null
    Write-Host "Docker is running." -ForegroundColor Green
} catch {
    Write-Host "ERROR: Docker is not running or not installed." -ForegroundColor Red
    Write-Host "Please start Docker Desktop and ensure it is in 'Linux Containers' mode." -ForegroundColor Yellow
    exit 1
}

# Verify the existence of the docker file
# Get the directory where this script is located
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The Dockerfile is in the sibling folder 'azure-scaling-lab'
# So we go up one level from 'scripts', then down into 'azure-scaling-lab'
$ProjectRoot = Join-Path $ScriptDir "..\azure-scaling-lab"

# Change to that directory
Set-Location $ProjectRoot

Write-Host "Switched to project root: $(Get-Location)" -ForegroundColor Green
Write-Host "Verifying Dockerfile exists..." -ForegroundColor Yellow
if (-not (Test-Path "Dockerfile")) {
    Write-Host "ERROR: Dockerfile not found in $(Get-Location). Please check your folder structure." -ForegroundColor Red
    exit 1
}

# Check Azure Login
Write-Host "Checking Azure Login status..." -ForegroundColor Blue
try {
    $profile = az account show --query "user.name" -o tsv 2>$null
    if (-not $profile) {
        Write-Host "ERROR: Not logged in to Azure. Please run 'az login' first." -ForegroundColor Red
        exit 1
    }
    Write-Host ("Logged in as: " + $profile) -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to check Azure profile." -ForegroundColor Red
    exit 1
}



# Define Variables
$RG = "rgazurescalinglab"
$LOC = "australiaeast"
$ACR = "acrazurescalinglab"
$APP_NAME = "azurescalinglabapp"
$IMAGE_TAG = "v1.0.0"

# Check Git for Unique Tag
Write-Host "Checking Git for unique tag..." -ForegroundColor Blue
try {
    $gitHash = git rev-parse --short HEAD 2>$null
    if ($gitHash) {
        $IMAGE_TAG = $gitHash
        Write-Host ("Using Git commit hash: " + $IMAGE_TAG) -ForegroundColor Green
    } else {
        Write-Host "Git commit not found. Using fallback tag: v1.0.0" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Git command failed. Using fallback tag: v1.0.0" -ForegroundColor Yellow
}

$FULL_IMAGE_NAME = "$ACR.azurecr.io/ai-inference:$IMAGE_TAG"

Write-Host "`n=== Module 1: Infrastructure Setup ===" -ForegroundColor DarkYellow

# 1. Create Resource Group
Write-Host "Creating Resource Group: $RG in $LOC..." -ForegroundColor Cyan
az group create --name $RG --location $LOC --query "id" --output none 2>$null | Out-Null

# 2. Create ACR
Write-Host "Checking/Creating ACR: $ACR..." -ForegroundColor Cyan
try {
    $acrCheck = az acr show --name $ACR --resource-group $RG --query "id" --output none 2>$null
    if (-not $acrCheck) {
        az acr create --resource-group $RG --name $ACR --sku Basic --admin-enabled false --query "id" --output none 2>$null
        Write-Host "ACR Created successfully." -ForegroundColor Green
    } else {
        Write-Host "ACR already exists. Skipping creation." -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR: Failed to create ACR." -ForegroundColor Red
    exit 1
}

# 3. Login to ACR
Write-Host "Logging into ACR..." -ForegroundColor Cyan
az acr login --name $ACR | Out-Null

# 4. Build Image
Write-Host "Building Docker image: $FULL_IMAGE_NAME..." -ForegroundColor Cyan
try {
    docker build -t $FULL_IMAGE_NAME .
    Write-Host "Image built successfully." -ForegroundColor Green
} catch {
    Write-Host "ERROR: Docker build failed. Ensure Dockerfile exists in current directory." -ForegroundColor Red
    exit 1
}

# 5. Push Image
Write-Host "Pushing image to ACR..." -ForegroundColor Cyan
try {
    docker push $FULL_IMAGE_NAME
    Write-Host "Image pushed successfully." -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to push image to ACR." -ForegroundColor Red
    exit 1
}

Write-Host "`n=== Module 2: Deploy to Azure Container Apps ===" -ForegroundColor DarkYellow

# 6. Deploy to ACA
Write-Host "Deploying Container App: $APP_NAME..." -ForegroundColor Cyan
try {
    az containerapp up `
        --name $APP_NAME `
        --resource-group $RG `
        --image $FULL_IMAGE_NAME `
        --ingress external `
        --target-port 3000 `
        --query "properties.configuration.ingress.fqdn" `
        --output none 2>$null | Out-Null
    
    Start-Sleep -Seconds 15
    
    $fqdn = az containerapp show --name $APP_NAME --resource-group $RG --query "properties.configuration.ingress.fqdn" --output tsv
    Write-Host "Deployment Successful!" -ForegroundColor Green
    Write-Host ("Your app is running at: https://" + $fqdn) -ForegroundColor Cyan
    Write-Host "You can now run load tests or configure scaling rules." -ForegroundColor Yellow
} catch {
    Write-Host "ERROR: Failed to deploy to Azure Container Apps." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host "`n=== Setup Complete ===" -ForegroundColor Green
Write-Host "Next Step: Run the scaling investigation commands." -ForegroundColor White