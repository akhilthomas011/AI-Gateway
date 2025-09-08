# Expects:
# $aiservices_config = @(@{ location = 'eastus' }, @{ location = 'westeurope' })
$aiservices_config = @(@{ location = 'uaenorth' })
$currency_code = 'USD'

function Build-PricingTable {
    param(
        [Parameter(Mandatory)] $json_data,
        [Parameter(Mandatory)] [System.Collections.IList] $table_data
    )
    foreach ($item in $json_data.Items) {
        $null = $table_data.Add([pscustomobject]@{
            Region       = $item.armRegionName
            SKU          = $item.armSkuName
            'Retail Price' = [decimal]::Round([decimal]$item.retailPrice * 1000, 6)
        })
    }
}

$table_data = [System.Collections.ArrayList]::new()

foreach ($aiservice in $aiservices_config) {
    $aiservice_resource_location = $aiservice['location']

    $filter = "productName eq 'Azure OpenAI'  and armRegionName eq '$aiservice_resource_location'"
    $encodedFilter = [System.Uri]::EscapeDataString($filter)
    $uri = "https://prices.azure.com/api/retail/prices?currencyCode=$currency_code&`$filter=$encodedFilter"


    try {
        $prices = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 60 -ErrorAction Stop
        Build-PricingTable -json_data $prices -table_data $table_data
    } catch {
        Write-Warning "Failed to fetch prices for ${aiservice_resource_location}: $($_.Exception.Message)"
    }

    #$table_data | Format-Table -Property Region, SKU, 'Retail Price' -AutoSize
    $table_data | Where-Object { $_.SKU -like 'gpt 4.1 Outp glbl' } # | Format-Table -Property Region, SKU, 'Retail Price' -AutoSize
}





eastus o1 mini output Data Zone                      4.84









# Get AAD token for Logs Ingestion (Azure Monitor)
$accessToken = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($accessToken)) {
    Write-Error "Failed to acquire access token via Az CLI."
    return
}

$ingestUri = "$pricing_dcr_endpoint/dataCollectionRules/$pricing_dcr_immutable_id/streams/$pricing_dcr_stream?api-version=2023-01-01"
$headers = @{
    Authorization = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

foreach ($aiservice in $aiservices_config) {
    $aiservice_resource_location = $aiservice['location']

    $filter = "productName eq 'Azure OpenAI' and unitOfMeasure eq '1K' and armRegionName eq '$aiservice_resource_location'"
    $encodedFilter = [System.Uri]::EscapeDataString($filter)
    $uri = "https://prices.azure.com/api/retail/prices?currencyCode=$currency_code&`$filter=$encodedFilter"

    try {
        $prices = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 60 -ErrorAction Stop
    } catch {
        Write-Warning "Failed to fetch prices for ${aiservice_resource_location}: $($_.Exception.Message)"
        continue
    }

    if (-not $prices -or -not $prices.Items) { continue }

    foreach ($deployment in $models_config) {
        $inputItem  = $prices.Items | Where-Object { $_.skuName -eq $deployment.inputTokensMeterSku } | Select-Object -First 1
        $outputItem = $prices.Items | Where-Object { $_.skuName -eq $deployment.outputTokensMeterSku } | Select-Object -First 1

        $input_tokens_price  = if ($inputItem)  { [decimal]::Round([decimal]$inputItem.retailPrice * 1000, 6) }  else { $null }
        $output_tokens_price = if ($outputItem) { [decimal]::Round([decimal]$outputItem.retailPrice * 1000, 6) } else { $null }

        Write-Host "Adding model $($deployment.name) with input/output tokens price $input_tokens_price / $output_tokens_price"

        $body = @(
            @{
                TimeGenerated     = (Get-Date).ToUniversalTime().ToString("o")
                Model             = $deployment.name
                InputTokensPrice  = $input_tokens_price
                OutputTokensPrice = $output_tokens_price
            }
        )

        try {
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Method Post -Uri $ingestUri -Headers $headers -Body $json -ErrorAction Stop
            Write-Host "Upload succeeded for model $($deployment.name)"
        } catch {
            Write-Warning "Upload failed for model $($deployment.name): $($_.Exception.Message)"
        }
    }
}

