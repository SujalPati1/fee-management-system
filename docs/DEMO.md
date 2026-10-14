# Demo script (5-10 minutes)

The recording shows **API functionality**, **fee reminders being sent** and **secure admin operations**. This order covers all three in about eight minutes.

## Before recording (5 minutes beforehand)

1. Wake everything: open `https://func-feemgmt-k7x2pq.azurewebsites.net/api/health` and wait for `{"status":"ok"}` (up to two minutes if the database was paused).
2. Postman: environment **Fee Management (Azure)** selected, `subscriptionKey` filled in. Get two tokens ready: one signed in as a guest student (Authorization > Get New Access Token), and know how to switch to your admin account.
3. Open in browser tabs: the README architecture diagram, the Logic App **logic-feemgmt-k7x2pq** (Overview), the inbox of an overdue student (Gmail 1 for Rohan, ID 1), and Application Insights **appi-feemgmt-k7x2pq**.
4. Do not run the rate-limit folder before the demo; it uses up the key for a minute.

## Recording

| Time | Show | Say |
|---|---|---|
| 0:00 | README diagram | "Students and admins call API Management with an API key and an Entra ID token. APIM checks the key, the rate limit, the token and the role, then calls the Function, which checks the token again and reads Azure SQL with its managed identity. A Logic App sends overdue reminders through Outlook every morning." |
| 1:00 | Postman, signed in as **guest student 1** | Run *Own fee record*: 200, status `Overdue`, balance `60000.00`. Run *Another student's record*: 403. *Admin list*: 403. "A student only ever sees their own row: the Function compares the token's object ID with the row." |
| 2:30 | Postman, signed in as **you (FeeAdmin)** | *List overdue students*: 4 rows. *Get student 4*: balance exactly `0.10` ("money is handled in whole paise, so there are no floating-point errors"). *List page 2*: total 5,020 ("5,000+ records, 50 per page"). |
| 3:30 | Postman, admin | *Update student 4: overpayment*: 422. *More than 2 decimals*: 400. *Pay the last 0.10*: 200, now `Paid`. *Restore*: back to `Overdue`. "Admin operations need the FeeAdmin role and a row in the Administrators table; only fee fields can change." |
| 4:30 | Postman, folder 3 and 4 | No API key: 401. No token: 401. Made-up token: 401. Rate limit: the 31st call gets 429 with Retry-After. |
| 5:30 | Logic App > Run > **Run trigger**, then Runs history | Open the run: *Get overdue students* (managed identity through APIM) > *Too many overdue?* no > *For each* > four *Send reminder* steps, all green. "It also runs automatically at 09:00 India time, with retry policies on both steps." |
| 6:30 | Gmail inbox | The reminder email: name, balance, due date, days overdue. |
| 7:00 | Application Insights > Logs | `AppRequests \| summarize count() by Name, ResultCode`: the 200s, 401s, 403s and 422s you just caused. "No names, emails or amounts are logged." |
| 7:45 | Code (optional) | `src/lib/fee.ts` (status rules, paise), `infra/apim/api-policy.xml` (key, rate limit, token), `infra/main.bicep` and `infra/gateway.bicep` (everything is code). |

## If something goes wrong on camera

- **503 "The database is starting up"**: the database was paused. Wait 30 seconds and send the request again.
- **401 on every request**: the Postman token expired (they last about an hour). Get a new one.
- **429**: the rate limit; wait a minute.
