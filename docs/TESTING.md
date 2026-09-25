# C4Bridge Alpha Test

## Current release

`v0.1.0-alpha.8`

This build validates the one-owner pairing flow.

## 1. Update C4Bridge

Use a local file named exactly:

```text
C4Bridge.c4z
```

Update the existing C4Bridge instance.

Because the separate update/reload issue is still open, if the running version does not change, record the lifecycle properties before rebooting/re-adding.

Expected:

- Bridge Version: `0.1.0-alpha.8`
- Pairing Code: 8 digits
- Pairing Status: ready
- API Token: `Hidden - use Pairing Code`
- API Status: `Online - pairing enabled`

## 2. Pair a browser

1. Open `https://app.c4bridge.io`.
2. Enter the Director IP.
3. Enter the 8-digit **Pairing Code** from Composer.
4. Click **Pair & connect**.
5. Allow Chrome Local Network Access if prompted.

Expected:

- browser connects;
- project data loads;
- Composer's Pairing Code changes immediately after success;
- Pairing Status increments the paired-browser count;
- the long owner credential is not displayed to the user.

## 3. Reconnect without Composer

Reload the page or close/reopen it.

Expected:

- the browser shows **Paired in this browser**;
- no pairing code is needed;
- **Connect** uses the saved owner credential.

## 4. Invalid code

From a different browser/private window, enter a wrong code.

Expected:

- pairing is rejected;
- the long owner credential is never returned;
- repeated failures are rate-limited.

## 5. Existing controls

Confirm one already-known light still works with:

- On
- Off

Percentage dimming on the tested KNX path is deferred and is not part of alpha.8 acceptance.
