function New-BootstrapTF
{
    [CmdletBinding()]
    [Alias()]
    [OutputType([int])]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0)]
        $Subscription,

        # Param2 help description
        [Parameter(Mandatory=$true
                   )]
        $Tenant,

        # Param2 help description
        [Parameter(Mandatory=$true
                   )]
        $prefix,

        # Param2 help description
        [Parameter(Mandatory=$true
                   )]
        $region,

        # Param2 help description
        [Parameter(Mandatory=$true
                   )]
        $TFPath
    )

    Begin
    {
        If( -not (Get-AzContext))
        {
            Write-Verbose "Not Connected to Azure...logging in"
            Connect-AzAccount
        }
    }
    Process
    {
        $rgName = "$prefix-tfstate"
        $saName = $prefix + "tfstate"
        $spnDisplayName = $prefix + '-terraform'
        $kvName = $prefix + "-keyvault"

        Write-Host "Using Subscription:" $(Get-AzContext).Subscription.Name -ForegroundColor Green

        If( -not (Get-AzKeyVault -VaultName $kvName))
        {
            Write-Verbose "Creating Azure Keyvault $kvName"
            New-AzKeyVault -Name $kvName -ResourceGroupName $rgName -Location $region -Sku Standard
            Set-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $rgName -ObjectId $(Get-AzADUser).Id -PermissionsToSecrets set,get,list
        }
        else
        {
            Write-Verbose "Keyvault Already Exists"
        }

        If( -not (Get-AzADServicePrincipal -DisplayName $spnDisplayName))
        {
            $spn = New-AzADServicePrincipal -Scope /subscriptions/$Subscription -DisplayName $spnDisplayName
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($spn.Secret)
            $spnSecretValue = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            Write-Host "SPN: " $spn.ApplicationId -ForegroundColor Green
            Write-Host "SPN Secret: $UnsecurePassword" -ForegroundColor Green

            Set-AzKeyVaultSecret -VaultName $kvName -Name "TerraformServicePrincipalName" -SecretValue $(ConvertTo-SecureString $spn.ApplicationId -AsPlainText -Force)
            Set-AzKeyVaultSecret -VaultName $kvName -Name "TerraformServicePrincipalSecret" -SecretValue $spn.Secret
        }
        else
        {
            Write-Verbose "SPN Already Exists"
            $spn = Get-AzADServicePrincipal -DisplayName $spnDisplayName
            $spnSecret = Get-AzKeyVaultSecret -VaultName $kvName -Name 'TerraformServicePrincipalSecret'
            $spnSecretPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($spnSecret.SecretValue)
            $spnSecretValue = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($spnSecretPtr)
        }

        $env:ARM_CLIENT_ID=$spn.ApplicationId
        $env:ARM_CLIENT_SECRET=$spnSecretValue
        $env:ARM_SUBSCRIPTION_ID=$Subscription
        $env:ARM_TENANT_ID=$Tenant
        
        If( -not (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue))
        {
            Write-Verbose "Resource Group $rgName doesn't exist. Creating..."
            New-AzResourceGroup -Name $rgName -Location $region
        }
        else
        {
            Write-Verbose "Resource Group $rgName already exists."
        }

        If( -not (Get-AzStorageAccount -Name $saName -ResourceGroupName $rgName -ErrorAction SilentlyContinue))
        {
            Write-Verbose "Storage Account $saName doesn't exist. Creating..."
            $storageAccount = New-AzStorageAccount -ResourceGroupName $rgName -Name $saName -Location $region -SkuName Standard_LRS
            New-AzStorageContainer -Name $saName -Permission Off -Context $storageAccount.Context
        }
        else
        {
            Write-Verbose "Storage Account $saName already exists"
            $storageAccount = Get-AzStorageAccount -Name $saName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
            If( -not (Get-AzStorageContainer -Name $saName -Context $storageAccount.Context -ErrorAction SilentlyContinue))
            {
                Write-Verbose "Storage Container $saName doesn't exist. Creating..."
                New-AzStorageContainer -Name $saName -Permission Off -Context $storageAccount.Context
            }
            else
            {
                Write-Verbose "Storage Container $saName already exists"
            }
        }

        Set-Location $TFPath

        $string = @"
terraform {
  backend "azurerm" {
    resource_group_name  = "$rgName"
    storage_account_name = "$saName"
    container_name       = "$saName"
    key                  = "terraform.tfstate"
  }
}
"@ | Set-Content terraform-backend.tf

        $string = @"
provider "azurerm" {
  version = "~>2.0"
  features {}
}

resource "azurerm_resource_group" "rg" {
  name = "tftest"
  location = "$region"
}
"@ | Set-Content main.tf

    }
    End
    {

        Start-Sleep -Seconds 30
       & terraform init
    }
}
