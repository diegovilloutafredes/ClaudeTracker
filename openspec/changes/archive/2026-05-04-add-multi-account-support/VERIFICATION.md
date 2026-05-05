# Multi-account verification checklist

Manual UI checks deferred from the `add-multi-account-support` apply session. Walk through these on a build of v1.18.0 or later. Each step says (a) what to click, (b) what to look for, (c) how to inspect persistent state when applicable.

## Helper: dump the persisted account roster

Open `Terminal.app` (Cmd+Space → "Terminal"), paste, hit Enter:

```bash
python3 - <<'PY'
import plistlib, json, os
p = os.path.expanduser('~/Library/Containers/com.claudetracker.app/Data/Library/Preferences/com.claudetracker.app.plist')
with open(p, 'rb') as f:
    d = plistlib.load(f)
acc = d.get('accounts')
active = d.get('activeAccountID')
arr = json.loads(acc) if isinstance(acc, bytes) else []
print(f"active ID:   {active}")
print(f"total accts: {len(arr)}")
print(f"history keys:")
for k in sorted(d.keys()):
    if k.startswith('usageHistory'):
        size = len(d[k]) if isinstance(d[k], (bytes, bytearray)) else '?'
        print(f"  {k}  ({size} bytes)")
print()
for a in arr:
    mark = "✓" if a['id'] == active else " "
    print(f" {mark} {a.get('label','?'):28} {a.get('email','—')}")
    print(f"     id  = {a['id']}")
    print(f"     ds  = {a['dataStoreIdentifier']}")
    print()
PY
```

## 1. Add a second account

- Menu bar icon → click the **chevron** in the popover header → **Add account**.
- Sign in with a different Claude account.
- Window auto-closes; popover should show the new account's usage.

**Verify:** run the helper above. Expect `total accts: 2`, two distinct `dataStoreIdentifier` UUIDs, each with the right email.

## 2. Survive relaunch

- Popover → **Quit**.
- Re-open: `open /Applications/ClaudeTracker.app` (or click the app in `/Applications`).
- Open the popover.

**Verify:** the picker still lists both accounts, the previously active one is still active, **no re-login prompt** appears.

## 3. Switch accounts mid-poll

- Popover → chevron → switch to the other account.

**Verify:** popover content and menu bar label update within ~1 s, **no reset notification toast fires**, and the log shows the switch:

```bash
tail -10 ~/Library/Containers/com.claudetracker.app/Data/Library/Logs/ClaudeTracker/claudetracker.log
```

You should see a `switched active account to …` line followed by `poll: next in …s` lines for the new account.

## 4. Rename → picker reactivity

- Settings → click the **pencil** next to one account → type a new name → **Save**.
- Open the popover.

**Verify:** the chevron picker label shows the new name immediately. (This was a regression earlier; the fix is the defensive `var copy = accounts; copy[idx].label = trimmed; accounts = copy` reassign in `renameAccount`.)

## 5. Remove the active account (with another present)

- Settings → trash icon on the **currently active** account → confirm.

**Verify:** the app switches to the surviving account; its usage appears in the popover. Then re-run the helper script:

- `total accts: 1` — only the survivor remains.
- `history keys:` — only one `usageHistory.<id>` entry; the removed account's namespaced history key is gone.
- `activeAccountID` — points to the survivor.

## 6. Remove the only account + re-add (the data-store-leak check)

- Settings → trash the remaining account → confirm.
- Popover should show the **empty state** with the **"Add a Claude account"** button.
- Click it → sign in to the **same account you just removed**.

**Critical:** the login page should show the **actual claude.ai login form** — username/password (or SSO buttons). It should NOT auto-sign-you-in instantly with the old session.

If it auto-signs-in, the per-identifier `WKWebsiteDataStore` was not actually deleted by `WKWebsiteDataStore.remove(forIdentifier:)` and we have a leak. If the login form appears, the data store was correctly wiped.

## 6b. Pace + charts + notifications didn't regress

- After switching back into one of the accounts, leave it open a few minutes.
- Confirm the popover **pace line** appears (5-Hour and 7-Day rows) and updates as utilization changes.
- Switch to the **Charts** tab — historical data for the active account should render.
- Trigger a test reset/pace toast: Settings → Window Resets → **Test**, and Settings → Pace Alerts → **Test**.

If anything in 5 or 6 fails, open `~/Library/Logs/ClaudeTracker/claudetracker.log` and look for `migration:`, `data store remove failed:`, or any `error` lines.
