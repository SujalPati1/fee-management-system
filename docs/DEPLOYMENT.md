# Deployment guide

These steps build the whole system from nothing. They were tested end to end on a fresh resource group; the times are from that run. Commands are for **Git Bash** unless marked PowerShell.

The order matters in two places, both found by that test:

1. **Function code before API Management.** API Management stores the Function's host key, and a new Function App has no key until code is deployed and its host has started. So `infra/main.bicep` (core) is deployed first, then the code, then `infra/gateway.bicep`.
2. **Logic App role before the first run.** Azure caches a managed identity's token for about 24 hours and it cannot be refreshed ([Microsoft](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations)). Give the Logic App its role, then wait about 5 minutes before running it. In the test, a run made 30 seconds after the role was assigned got a token without the role, and every later run kept getting 403, even after the Logic App was deleted and recreated under the same name; a Logic App under a new name worked first time. If it happens to you, wait a day, or redeploy with a different `suffix`.

## 0. What you need

- An Azure subscription in a region your policy allows (this project uses **East Asia**, where the Azure SQL free offer is available), with permission to create resources.
- In Microsoft Entra ID: permission to register applications and to invite guest users (the default for members).
- A Microsoft 365 mailbox to send the reminders from.
- Tools: [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.9x with Bicep (`az bicep install`), [Node.js 24](https://nodejs.org/), [Azure Functions Core Tools 4](https://learn.microsoft.com/azure/azure-functions/functions-run-local), [sqlcmd](https://learn.microsoft.com/sql/tools/sqlcmd/go-sqlcmd-utility) (`winget install Microsoft.Sqlcmd`), Git, and optionally Postman.

## 1. Get the code and run the tests

```bash
git clone https://github.com/SujalPati1/fee-management-system.git
cd fee-management-system
npm ci
npm test              # 15 tests, all should pass
```

## 2. Sign in to Azure

```bash
az login
az account show --query "{subscription:name, tenant:tenantId, user:user.name}"
```

If your organisation requires multi-factor authentication for changes, `az` tells you the exact `az login --tenant ... --claims-challenge ...` command to run.

## 3. Entra ID: app registrations and roles (PowerShell)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
./scripts/entra-setup.ps1
```

It creates the **Fee API** app (scope `access_as_user`, roles `FeeAdmin`, `Student`, `Reminders.Read`), the **Fee Client** app that Postman signs in through, pre-authorizes both clients, and makes you a `FeeAdmin`. It prints the **Tenant ID**, the **Fee API appId** and the **Fee Client appId**; keep them. The script is safe to run again.

## 4. Resource group

```bash
az group create --name rg-feemgmt-eastasia --location eastasia
```

## 5. Core resources (about 3 minutes)

Pick a 6-character suffix of lowercase letters and digits if `k7x2pq` is taken; it makes the public names unique.

```bash
UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv)
OID=$(az ad signed-in-user show --query id -o tsv)
az deployment group what-if -g rg-feemgmt-eastasia -f infra/main.bicep \
  -p suffix=k7x2pq sqlAdminLogin="$UPN" sqlAdminObjectId="$OID" feeApiClientId=<Fee API appId>
az deployment group create -g rg-feemgmt-eastasia -n core -f infra/main.bicep \
  -p suffix=k7x2pq sqlAdminLogin="$UPN" sqlAdminObjectId="$OID" feeApiClientId=<Fee API appId>
```

You should see `"provisioningState": "Succeeded"` and outputs such as `functionAppName` (`func-feemgmt-k7x2pq`) and `sqlServerName` (`sql-feemgmt-k7x2pq`). This creates Log Analytics, Application Insights, Storage, the Flex Consumption Function App and the free-offer Azure SQL database (Entra ID sign-in only, you as admin).

## 6. Database (about 1 minute)

Allow your computer through the SQL firewall, then run the scripts. The first connection can fail with error 40613 while a new or paused database starts; run it again after a minute.

```bash
MYIP=$(curl -s https://api.ipify.org)
az sql server firewall-rule create -g rg-feemgmt-eastasia -s sql-feemgmt-k7x2pq -n dev-machine \
  --start-ip-address "$MYIP" --end-ip-address "$MYIP"

SQL="sqlcmd -S sql-feemgmt-k7x2pq.database.windows.net -d FeeManagement --authentication-method ActiveDirectoryDefault -l 120 -b"
$SQL -i sql/001_schema.sql
$SQL -i sql/002_seed.sql -v OwnerEmail="<your mailbox>" Student1Email="<inbox you own>" \
     Student2Email="<inbox you own>" AdminName="<your name>" AdminObjectId="$OID"
$SQL -i sql/003_bulk_5000.sql
$SQL -i sql/005_grant_function.sql -v FunctionAppName=func-feemgmt-k7x2pq
```

Every seed student gets one of the three emails you pass, so reminders only ever reach inboxes you own. You should see `001_schema: done`, `002_seed: done`, `003_bulk_5000: inserted 5000 rows`, `005_grant_function: done`. All scripts are safe to run again.

## 7. Function code (about 1.5 minutes)

```bash
npm run deploy -- func-feemgmt-k7x2pq
curl https://func-feemgmt-k7x2pq.azurewebsites.net/api/health
```

The deploy lists five functions and ends with `The deployment was successful!`; health answers `{"status":"ok","database":"ok",...}`.

## 8. API Management and the Logic App (about 4 minutes)

```bash
az deployment group create -g rg-feemgmt-eastasia -n gateway -f infra/gateway.bicep \
  -p suffix=k7x2pq feeApiClientId=<Fee API appId> publisherEmail="$UPN"
```

Outputs: `feeApiBaseUrl` (`https://apim-feemgmt-k7x2pq.azure-api.net/fees`) and `logicAppPrincipalId`.

## 9. Give the Logic App its role, then wait 5 minutes (PowerShell)

```powershell
./scripts/entra-setup.ps1 -ReminderPrincipalId <logicAppPrincipalId>
```

Do not run the Logic App during the next 5 minutes (see the note at the top). The Outlook step below takes about that long anyway.

## 10. Authorize the Outlook connection (once, in the portal)

Portal > resource group > **office365** (API connection) > **Edit API connection** > **Authorize** > sign in with the mailbox that sends the reminders > **Save**. If Save then reports "failed to edit API connections", check the real state; the sign-in from Authorize is already stored:

```bash
az resource show -g rg-feemgmt-eastasia -n office365 --resource-type Microsoft.Web/connections \
  --query "{status:properties.overallStatus, user:properties.authenticatedUser.name}"
```

`"status": "Connected"` is what you want.

## 11. Student logins (optional, for testing as a student)

Invite each account that should sign in as a student, accept the invitation from its inbox, give it the `Student` role and link it to a student row:

```bash
az rest --method post --url https://graph.microsoft.com/v1.0/invitations \
  --headers Content-Type=application/json \
  --body '{"invitedUserEmailAddress":"<email>","invitedUserDisplayName":"Fee Demo - <name>","inviteRedirectUrl":"https://myapps.microsoft.com/?tenantid=<Tenant ID>","sendInvitationMessage":true}' \
  --query "{oid:invitedUser.id,status:status}"
```
```powershell
./scripts/entra-setup.ps1 -StudentObjectIds <oid1>,<oid2>
```
```bash
$SQL -i sql/006_link_student_login.sql -v StudentID=1 Email="<email>" EntraObjectId=<oid1>
# or add a new student row:
$SQL -i sql/004_add_student.sql -v Name="<name>" Course="MBA" TotalFee=50000.00 PaidAmount=10000.00 \
     DueDate=2026-10-01 Email="<email>" EntraObjectId=<oid>
```

The portal alternative for the role: **Enterprise applications > Fee API > Users and groups > Add user/group > choose the user > Select a role: Student > Assign**.

## 12. Try it

API key for Postman (never commit it):

```bash
S=$(az account show --query id -o tsv)
az rest --method post --url "https://management.azure.com/subscriptions/$S/resourceGroups/rg-feemgmt-eastasia/providers/Microsoft.ApiManagement/service/apim-feemgmt-k7x2pq/subscriptions/postman-demo/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv
```

In Postman, import `postman/fee-management.postman_collection.json` and `postman/fee-management.postman_environment.json`, put the key in `subscriptionKey`, and if your names or app IDs differ, update the collection variables `baseUrl`, `tenantId`, `clientId`, `scope` and `logicAppUrl`. Then **Authorization > Get New Access Token**, choose an account, **Use Token**, and run folder 1 (as the admin) or 2 (as a student).

From the command line (Postman CLI), with your own admin token:

```bash
TOKEN=$(az account get-access-token --scope "api://<Fee API appId>/access_as_user" --query accessToken -o tsv)
postman collection run postman/fee-management.postman_collection.json -e postman/fee-management.postman_environment.json \
  --env-var subscriptionKey=<key> --env-var accessToken="$TOKEN" -i "1 Admin (sign in as FeeAdmin)"
```

Run the reminders now (sends real emails to the overdue students):

```bash
az rest --method post --url "https://management.azure.com/subscriptions/$S/resourceGroups/rg-feemgmt-eastasia/providers/Microsoft.Logic/workflows/logic-feemgmt-k7x2pq/triggers/Daily_at_9am_India/run?api-version=2019-05-01"
az rest --method get --url "https://management.azure.com/subscriptions/$S/resourceGroups/rg-feemgmt-eastasia/providers/Microsoft.Logic/workflows/logic-feemgmt-k7x2pq/runs?api-version=2019-05-01&\$top=1" --query "value[0].properties.status"
```

Or in the portal: **logic-feemgmt-k7x2pq > Overview > Run > Run trigger**, then **Runs history**. Without a manual run, the workflow runs every day at 09:00 India time.

## Updating

- Code: `npm test && npm run deploy -- func-feemgmt-k7x2pq`.
- Infrastructure: re-run step 5 or 8 (`what-if` first). Re-running step 8 also refreshes the Function key that API Management holds. Afterwards check that the Outlook connection still says `Connected` (the command in step 10); if it does not, authorize it again.
- A single API Management policy can be updated on its own, without redeploying step 8:
  `az rest --method put --url ".../apis/fee-api/policies/policy?api-version=2024-05-01" --body @policy.json`, where `policy.json` is `{"properties":{"format":"rawxml","value":"<the XML>"}}`.

## Clean up

```bash
az group delete --name rg-feemgmt-eastasia --yes
```

Then delete the **Fee API** and **Fee Client** app registrations in Entra ID (this also removes their role assignments) and remove the guest accounts. A deleted API Management instance keeps its name reserved for a while; use a new suffix if you deploy again soon.
