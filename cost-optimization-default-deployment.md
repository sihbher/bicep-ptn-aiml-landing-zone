# Cost Optimization: Reduce Default Deployment Costs (AI Search + VM)

## Summary

The default landing zone deployment incurs significant costs from two primary resources that are over-provisioned for dev/test and bootstrap scenarios:

1. **AI Foundry AI Search** — deployed with **3 replicas** by the AVM module (not configurable), costing ~$1,008/month instead of ~$336/month with 1 replica.
2. **Jumpbox VM (`Standard_D8s_v5`)** — an 8-vCPU / 32 GB RAM Windows VM deployed by default, costing ~$420/month when a smaller `Standard_D2s_v5` (2 vCPU / 8 GB) at ~$105/month is sufficient for bootstrap tasks.

Combined, these two changes can save **~$987/month (~$11,844/year)**.

---

## 1. AI Foundry AI Search — Reduce Replica Count from 3 to 1

### Current State

The deployment creates **two separate Azure AI Search instances**:

| Instance | Resource Name Pattern | SKU | Replica Count | Configured In | Monthly Cost |
|---|---|---|---|---|---|
| Application AI Search | `srch-{token}` | `standard` | **1** ✅ | `main.bicep` (direct) | ~$336 |
| AI Foundry AI Search | `srch-aif-{token}` | `standard` | **3** ❌ | AVM module (internal) | ~$1,008 |

At `standard` SKU pricing (~$336/month per Search Unit):

| Configuration | Search Units | Estimated Monthly Cost |
|---|---|---|
| Current (3 replicas × 1 partition) | 3 SU | **~$1,008/month** |
| Proposed (1 replica × 1 partition) | 1 SU | **~$336/month** |
| **Savings** | | **~$672/month (~$8,064/year)** |

> Note: 3 replicas provide an SLA for read queries, but this is not required for dev/test scenarios and is often unnecessary for initial production deployments. A single replica provides no SLA but is fully functional. Replicas can be scaled up at any time without downtime.

### The Problem

The `aiSearchConfiguration` parameter of the AVM module (`avm/ptn/ai-ml/ai-foundry:0.6.0`) only exposes:
- `existingResourceId` — use an existing resource
- `name` — resource name
- `privateDnsZoneResourceId` — DNS zone for private endpoints
- `roleAssignments` — RBAC

**There is no `sku` or `replicaCount` property** in `aiSearchConfiguration`. The AVM module hardcodes the AI Search configuration internally.

### Architecture

```
main.bicep
├── searchService (Application AI Search)
│   ├── sku: 'standard'
│   ├── replicaCount: 1          ← Already optimized ✅
│   └── Directly configured in main.bicep (line ~2139)
│
└── aiFoundry (modules/ai-foundry/main.bicep)
    └── avm/ptn/ai-ml/ai-foundry:0.6.0
        └── AI Foundry AI Search (srch-aif-*)
            ├── replicaCount: 3   ← Created by AVM internally ❌
            └── NOT configurable via aiSearchConfiguration
```

### Recommended Fix

#### Option A: "Bring Your Own" Pattern (Preferred — No AVM dependency)

Create the AI Foundry's AI Search as a standalone resource in `main.bicep` with explicit `replicaCount: 1`, then pass its resource ID to the AVM module via `existingResourceId`.

**Steps:**
1. Add a new AI Search module deployment in `main.bicep` for the AI Foundry instance:
   ```bicep
   module aiFoundrySearchService 'br/public:avm/res/search/search-service:0.11.1' = if (deployAiFoundry) {
     name: 'aiFoundrySearchService'
     params: {
       name: aiFoundrySearchServiceName
       location: location
       sku: 'standard'
       replicaCount: 1
       publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
       tags: _tags
     }
   }
   ```

2. Update `varAfAiSearchCfgComplete` (line ~1569) to always pass `existingResourceId`:
   ```bicep
   var varAfAiSearchCfgComplete = {
     existingResourceId: deployAiFoundry ? aiFoundrySearchService.outputs.resourceId : null
     name: aiFoundrySearchServiceName
     privateDnsZoneResourceId: _networkIsolation ? _dnsZoneSearchId : null
     roleAssignments: []
   }
   ```

3. This gives us full control over SKU, replicaCount, identity, auth, and shared private link resources for the AI Foundry AI Search, independent of the AVM module defaults.

#### Option B: Request AVM Module Enhancement (Long-term)

File an issue on [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules) requesting that `aiSearchConfiguration` expose `sku` and `replicaCount` properties.

---

## 2. Jumpbox VM — Downsize from `Standard_D8s_v5` to `Standard_D2s_v5`

### Current State

The jumpbox VM is deployed with:

| Setting | Current Value | Location |
|---|---|---|
| VM Size | `Standard_D8s_v5` (8 vCPU, 32 GB RAM) | `main.bicep` param `vmSize` (line ~355) + `main.parameters.json` |
| OS Disk | 250 GB, `Standard_LRS` | `main.bicep` (line ~641) |
| OS Image | Windows 11 Enterprise (`win11-25h2-ent`) | `main.bicep` params (lines ~357-367) |
| Bastion Host | `Standard` SKU | `main.bicep` (line ~586) |
| Condition | `deployVM && _networkIsolation` | Only deployed in isolated mode |

**Estimated monthly costs:**

| Component | Current | Proposed | Savings |
|---|---|---|---|
| VM (`Standard_D8s_v5` → `Standard_D2s_v5`) | ~$420/month | ~$105/month | **~$315/month** |
| OS Disk (250 GB Standard_LRS) | ~$10/month | ~$10/month (no change) | $0 |
| Bastion Host (Standard SKU) | ~$208/month | ~$208/month (no change) | $0 |
| NAT Gateway + Public IP | ~$38/month | ~$38/month (no change) | $0 |
| **VM Subtotal** | **~$676/month** | **~$361/month** | **~$315/month** |

> Note: Bastion Standard SKU is necessary for native client connections (`az network bastion tunnel`). Downgrading Bastion to Basic SKU would save ~$70/month but loses native client and file transfer support, which are critical for jumpbox usage. **Do NOT downgrade Bastion.**

### Rationale

The jumpbox VM is used for:
- Running `azd provision` / `azd deploy` from inside the VNet
- Running `az` CLI commands and `git` operations
- Bootstrapping component repos per `manifest.json`

These tasks are lightweight and do not require 8 vCPUs or 32 GB RAM. A `Standard_D2s_v5` (2 vCPU / 8 GB) is more than sufficient.

The `install.ps1` custom script extension installs:
- Azure CLI, azd, Git, PowerShell
- Clones repos and sets up azd environments

None of these operations need high compute.

### Recommended Fix

1. **Change the default `vmSize` parameter** in `main.bicep`:
   ```bicep
   @description('Size of the test VM')
   param vmSize string = 'Standard_D2s_v5'
   ```

2. **Update `main.parameters.json`** to match:
   ```json
   "vmSize": { "value": "Standard_D2s_v5" }
   ```

3. **Optionally reduce OS disk** from 250 GB to 128 GB (saves ~$3/month, minor):
   ```bicep
   osDisk: {
     caching: 'ReadWrite'
     diskSizeGB: 128
     managedDisk: {
       storageAccountType: 'Standard_LRS'
     }
   }
   ```

Users who need a larger VM for specific workloads can override `vmSize` via:
```bash
azd env set VM_SIZE Standard_D8s_v5
```

---

## Combined Cost Impact Summary

| Resource | Current Monthly | Proposed Monthly | Monthly Savings | Annual Savings |
|---|---|---|---|---|
| AI Foundry AI Search (3 → 1 replicas) | ~$1,008 | ~$336 | **~$672** | **~$8,064** |
| Application AI Search (1 replica) | ~$336 | No change | $0 | $0 |
| Jumpbox VM (D8s_v5 → D2s_v5) | ~$420 | ~$105 | **~$315** | **~$3,780** |
| OS Disk (250 GB) | ~$10 | No change | $0 | $0 |
| Bastion Host (Standard) | ~$208 | No change | $0 | $0 |
| NAT Gateway + Public IP | ~$38 | No change | $0 | $0 |
| **Total** | **~$2,020** | **~$1,033** | **~$987/month** | **~$11,844/year** |

> Prices are approximate East US pay-as-you-go estimates. Actual costs vary by region and discounts.

---

## Acceptance Criteria

### AI Search
- [ ] AI Foundry's AI Search instance deploys with `replicaCount: 1` by default
- [ ] Application AI Search remains unchanged (`standard` SKU, `replicaCount: 1`)
- [ ] Both `networkIsolation = true` and `networkIsolation = false` deployment modes work
- [ ] AI Foundry connections and agent service functionality remain intact
- [ ] Private endpoint and DNS zone configuration for AI Foundry Search is preserved in isolated mode
- [ ] Optionally: parameterize `aiFoundrySearchReplicaCount` to allow users to override

### VM
- [ ] Default `vmSize` changed to `Standard_D2s_v5` in both `main.bicep` and `main.parameters.json`
- [ ] Bastion SKU remains `Standard` (no changes — required for native client support)
- [ ] `deployVM` flag continues to gate all VM-related resources correctly
- [ ] `install.ps1` / custom script extension works correctly on the smaller VM
- [ ] Users can override `vmSize` via parameter or `azd env set`
- [ ] VM role assignments remain unchanged

---

## Risk Assessment

| Change | Risk | Mitigation |
|---|---|---|
| AI Search 3→1 replicas | No SLA for read queries | Scale up replicas when SLA needed; functional behavior identical |
| VM D8s→D2s | Slower bootstrap for large installs | Users override `vmSize` for heavier workloads |
| Bastion unchanged | None | Keeping Standard SKU — no regression |
| OS Disk unchanged | None | 250 GB preserved |
