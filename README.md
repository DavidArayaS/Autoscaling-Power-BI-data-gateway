# Autoscaling Power BI On-Premises Data Gateway on Azure VMSS

A step-by-step guide to deploy an Azure Virtual Machine Scale Set (VMSS) running the Power BI On-Premises Data Gateway, auto-scale based on CPU load, and automatically join new nodes into a gateway cluster.

---

## Table of Contents

1. [Prerequisites](#prerequisites)  
2. [Create Service Principal](#create-service-principal)  
3. [Provision VMSS & External Load Balancer](#provision-vmss--external-load-balancer)  
4. [Configure NSG Outbound Rule (Port 443)](#configure-nsg-outbound-rule-port-443)  
5. [Install & Register Primary Gateway Manually](#install--register-primary-gateway-manually)  
6. [Enable “Distribute Requests…” on the Cluster](#enable-distribute-requests-on-the-cluster)  
7. [Grant SP as Gateway Admin](#grant-sp-as-gateway-admin)  
8. [Configure VMSS Autoscale Rules](#configure-vmss-autoscale-rules)  
9. [Upload & Parameterize Automation Script](#upload--parameterize-automation-script)  
10. [Add Custom Script Extension to VMSS](#add-custom-script-extension-to-vmss)  
11. [Test Scale-Out & Auto-Join](#test-scale-out--auto-join)  

---

## Prerequisites

- Azure subscription with **Owner** or **Contributor** rights  
- Power BI **tenant admin** access  
- Local workstation with Azure CLI (`az`) and PowerShell 7+ (`pwsh`)  
- GitHub repo or Azure Storage Account for hosting automation script  
- [CPU Stress tool (Sysinternals)](https://learn.microsoft.com/en-us/sysinternals/downloads/cpustres)  

---

## Create Service Principal

1. **Create AAD App & SP**  
   ```bash
   az ad app create      --display-name "pbi-gateway-autoscaler"      --password "<StrongP@ssw0rd>"      --credential-description "Gateway automation"
   ```
2. **Get its object and app (client) IDs**  
   ```bash
   APP_ID=$(az ad app show --id http://pbi-gateway-autoscaler --query appId -o tsv)
   SP_ID=$(az ad sp show --id $APP_ID --query objectId -o tsv)
   ```
3. **Grant Power BI API permissions**  
   ```bash
   az rest -Method POST      -Uri https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignedTo      -Body '{
       "principalId":"'$SP_ID'",
       "resourceId":"<PowerBiServicePrincipalId>",
       "appRoleId":"<GatewayAdminAppRoleId>"
     }'
   ```
   > You can also add via Power BI Admin Portal under **Gateway installers** → **Gateway admins**.

---

## Provision VMSS & External Load Balancer

1. **Create a public LB**  
   ```bash
   az network lb create      --resource-group MyRG      --name pbi-gw-lb      --sku Standard      --public-ip-address pbi-gw-pip      --frontend-ip-name FE      --backend-pool-name BE
   ```
2. **Create VMSS** (placeholder script)  
   ```bash
   az vmss create      --resource-group MyRG      --name pbi-gw-vmss      --image Win2019Datacenter      --admin-username your-user    --admin-password "<YourP@ssw0rd>"      --instance-count 1      --vm-sku Standard_F4s_v2      --lb pbi-gw-lb      --backend-pool-name BE      --nsg MyGatewayNSG
   ```
  

---

## Configure NSG Outbound Rule (Port 443)

Ensure your NSG allows outbound HTTPS:

```bash
az network nsg rule create   --resource-group MyRG   --nsg-name MyGatewayNSG   --name AllowOutbound443   --priority 100   --direction Outbound   --access Allow   --protocol Tcp   --destination-port-ranges 443   --destination-address-prefixes Internet
```

---

## Install & Register Primary Gateway Manually

1. **RDP to one VM** (e.g. `pbi-gw-vmss_0`)  
2. **Download & install gateway**  
   - Go to https://go.microsoft.com/fwlink/?linkid=2116849  
   - Run: `PBIDGatewayInstaller.exe /quiet /norestart`  
3. **Run Setup UI** once to register as **Primary**  
   - Sign in with your **user account** (MFA-enabled)  
4. **Install Sysinternals CPU Stress**  
   ```powershell
   Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/CPUStres.zip' -OutFile C:\Temp\CPUStres.zip
   Expand-Archive C:\Temp\CPUStres.zip -DestinationPath C:\Temp\CPUStres
   ```

---

## Enable “Distribute Requests…” on the Cluster

1. In the Power BI Service → **Manage gateways**  
2. Select **autoscaling-data-gw** → **Settings**  
3. Check **“Distribute requests across all active gateways in this cluster”**  

---

## Grant SP as Gateway Admin

1. In **Manage gateways** → **On-premises data gateways**  
2. Select **autoscaling-data-gw** → **Manage users**  
3. Add **pbi-gateway-autoscaler** as **Admin**  

---

## Configure VMSS Autoscale Rules

Use **min=1**, **default=1**, **max=10**, scale‐out @ ≥70% CPU (10 min), scale‐in @ ≤40% CPU (15 min):

```bash
az monitor autoscale create   --resource-group MyRG   --resource pbi-gw-vmss   --resource-type Microsoft.Compute/virtualMachineScaleSets   --name pbi-gw-autoscale   --min 2 --max 10 --count 2

az monitor autoscale rule create   --resource-group MyRG --autoscale-name pbi-gw-autoscale   --condition "Percentage CPU > 70 avg 10m"   --scale out 1 --cooldown 20m

az monitor autoscale rule create   --resource-group MyRG --autoscale-name pbi-gw-autoscale   --condition "Percentage CPU < 40 avg 15m"   --scale in 1 --cooldown 30m
```

---

## Upload & Parameterize Automation Script

1. **Copy** the [Powershell Script](https://github.com/DavidArayaS/Autoscaling-Power-BI-data-gateway/blob/dfb4423974dd0978f38c66560b0ee126aaa094b0/install-pbigw.ps1) to a **public blob** container  
2. Make it **anonymous-read** or use a SAS URL  
3. Ensure it contains your **tenant**, **SP**, **cluster ID**, and **recovery key**  

---

## Add Custom Script Extension to VMSS

```bash
az vmss extension set   --publisher Microsoft.Compute   --name CustomScriptExtension   --version 1.10   --resource-group MyRG   --vmss-name pbi-gw-vmss   --settings '{"fileUris":["https://<storage>.blob.core.windows.net/scripts/install-pbigw-vmss.ps1"],"commandToExecute":"powershell.exe -ExecutionPolicy Bypass -File install-pbigw.ps1"}'
```

---

## Test Scale-Out & Auto-Join

1. **Trigger CPU load** on a node:  
   ```powershell
   C:\Temp\CPUStres\CPUStres.exe /C /T 4
   ```
2. **Monitor VMSS instances** (should add a new VM in ~15 min)  
3. **Verify** new node shows up in **Manage gateways → autoscaling-data-gw** as `<VMNAME>-node`  
4. **Kill stress** and watch it scale back in  

---

**You now have a fully automated, autoscaling Power BI Data Gateway cluster on Azure VMSS!**
