$RESOURCE_GROUP='AKS_RG'
$AKS_NAME='AKSPRD01'
$IDENTITY_RESOURCE_NAME='azure-alb-identity'
$AGFC_NAME='AGW-C01'
$FRONTEND_NAME='AGW-FE01'
$VNET_NAME='PROD-VNET'
$VNET_RESOURCE_GROUP='AKS_RG'
$ALB_SUBNET_NAME='AGW-SN01'
$IDENTITY_RESOURCE_NAME='azure-alb-identity'
$ASSOCIATION_NAME='AGW-AS01'
$RESOURCE_NAME='AGW-C01' #AGFC NAME 
$RESOURCE_ID =$(az network alb show --resource-group $RESOURCE_GROUP --name $RESOURCE_NAME --query id -o tsv)

$mcResourceGroup=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query "nodeResourceGroup" -o tsv)
$mcResourceGroupId=$(az group show --name $mcResourceGroup --query id -otsv)

Write-Output "Creating identity $IDENTITY_RESOURCE_NAME in resource group $RESOURCE_GROUP"
az identity create --resource-group $RESOURCE_GROUP --name $IDENTITY_RESOURCE_NAME
$principalId="$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query principalId -otsv)"

Write-Output "Waiting 60 seconds to allow for replication of the identity..."
Start-Sleep 60

Write-Output "Apply Reader role to the AKS managed cluster resource group for the newly provisioned identity"
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $mcResourceGroupId --role "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader role

Write-Output "Set up federation with AKS OIDC issuer"
$AKS_OIDC_ISSUER="$(az aks show -n "$AKS_NAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)"
az identity federated-credential create --name "azure-alb-identity" --identity-name "$IDENTITY_RESOURCE_NAME" --resource-group $RESOURCE_GROUP --issuer "$AKS_OIDC_ISSUER" --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"


az network vnet subnet update --resource-group $VNET_RESOURCE_GROUP  --name $ALB_SUBNET_NAME --vnet-name $VNET_NAME --delegations 'Microsoft.ServiceNetworking/trafficControllers'
$ALB_SUBNET_ID=$(az network vnet subnet list --resource-group $VNET_RESOURCE_GROUP --vnet-name $VNET_NAME --query "[?name=='$ALB_SUBNET_NAME'].id" --output tsv)
Write-Output $ALB_SUBNET_ID




helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller --version 0.4.023971 --set albController.podIdentity.clientID=$(az identity show -g $RESOURCE_GROUP -n azure-alb-identity --query clientId -o tsv)

helm upgrade alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller --version 0.4.023971 --set albController.podIdentity.clientID=$(az identity show -g $RESOURCE_GROUP -n azure-alb-identity --query clientId -o tsv)


kubectl get pods -n azure-alb-system
kubectl get gatewayclass azure-alb-external -o yaml
##Skip if done via portal 
#az network alb create -g $RESOURCE_GROUP -n $AGFC_NAME

az network alb frontend create -g $RESOURCE_GROUP -n $FRONTEND_NAME --alb-name $AGFC_NAME

$resourceGroupId=$(az group show --name $RESOURCE_GROUP --query id -otsv)
$principalId=$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query principalId -otsv)

# Delegate AppGw for Containers Configuration Manager role to RG containing Application Gateway for Containers resource
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $resourceGroupId --role "fbc52c3f-28ad-4303-a892-8a056630b8f1" 

# Delegate Network Contributor permission for join to association subnet
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $ALB_SUBNET_ID --role "4d97b98b-1d4f-4787-a291-c67834d212e7" 

az network alb association create -g $RESOURCE_GROUP -n $ASSOCIATION_NAME --alb-name $AGFC_NAME --subnet $ALB_SUBNET_ID
kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/https-scenario/end-to-end-ssl-with-backend-mtls/deployment.yaml

kubectl apply -f .\gateway.yaml

kubectl get gateway gateway-01 -n test-infra -o yaml

#$RESOURCE_ID ='/subscriptions/xxx/resourcegroups/AKS_RG/providers/Microsoft.ServiceNetworking/trafficControllers/AGW-C01'

kubectl apply -f .\http_route.yaml
kubectl get httproute https-route -n test-infra -o yaml

kubectl apply -f .\backend.yaml
kubectl get backendtlspolicy -n test-infra mtls-app-tls-policy -o yaml

$fqdn=$(kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.addresses[0].value}')
$fqdn

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
Invoke-WebRequest https://$fqdn/
Invoke-WebRequest http://$fqdn/
