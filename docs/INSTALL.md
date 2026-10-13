# Installing and updating DirectorLink

DirectorLink is an independent project, not affiliated with Control4 or Snap One.

You need **Composer Pro**, Control4's setup tool, to add DirectorLink to your Control4 project, and later to update it. After that, DirectorLink runs on its own: the app, scenes and schedules never need Composer. Its settings, such as Remote Access for using the app away from home, are set in Composer too.

## 1. Download DirectorLink

Download DirectorLink from **[GitHub Releases](https://github.directorlink.io/releases)**.

Each release keeps its own `DirectorLink.c4z`, `openapi.json`, release notes, and SHA-256 checksums so users can upgrade or downgrade to a specific version.

## 2. Get Composer Pro

DirectorLink is installed like any other Control4 driver: with Composer Pro, on a Windows computer on the same network as your controller.

- **You need an active Control4 account with access to Composer Pro.** Composer asks you to sign in with it, and it can't connect to your controller without it. Control4 gives these accounts to its dealers and installers.
- **Download Composer Pro from https://composer.directorlink.io.** It lists the Composer installers on Control4's own servers, newest first. Choose the newest **Composer Pro** release and install it.
- **No Composer Pro account?** Ask your Control4 installer to add DirectorLink for you and to set what you want on (Remote Access, Sonos and the others in step 3). It takes a few minutes and needs no reboot.

## 3. Add the driver to Composer

1. Open Composer Pro and connect to your Director.
2. In the top menu, choose **Driver → Add or Update Driver**.
3. Select `DirectorLink.c4z`.
4. Go to **System Design**.
5. Select any room in the project tree. DirectorLink only needs one instance in the project; the room is not functionally important.
6. Open the **Search** tab in the Items pane.
7. Make sure **Local** drivers are included and search for **DirectorLink**.
8. Double-click or drag **DirectorLink** into the selected room.
9. Select the DirectorLink device and check its Properties.

A successful install shows:

- **Status:** `Ready`
- **Version:** the installed DirectorLink release
- **API Status:** `Online - port 41999`. If it says `Port 41999 taken by another driver`, another driver took the port when the controller started: restart the controller (DirectorLink also asks for the port again every minute)
- **Pairing Code:** 8 digits shown as `1234 5678`, with **Pairing Status** `Ready until HH:MM - works once`
- **API Keys:** how many keys exist
- **Door Control:** `Disabled` until you allow opening doors and gates from the app
- **Relay Hold:** `Not allowed`, so doors and gates are only pulsed (a short press, like their Open button). `Allowed` also lets API clients hold any relay closed, which holds a door or gate open, and opens a Relay Door or Gate Controller set to hold its relay
- **Alarm Status:** `Off`, so DirectorLink does not watch the alarm. `On` shows admins, and members allowed to see it, in the app whether each partition of the alarm is armed, in alarm, has open zones or trouble, and (1.13) tells the home's TVs when it goes off, nothing else. Read-only: DirectorLink never arms or disarms
- **Remote Access** and **Remote Status**: reaching the home from anywhere with an account
- **Direct HTTPS:** `Off`. `On` (the only switch, since 1.12.2) also serves the API over HTTPS on port 28443 under a name of the home's own (`….dlhome.cc`, listed publicly in certificate logs, whose DNS record is the controller's LAN address), so that every device, iPhones and iPads too, reaches the controller directly at home; it needs Remote Access and the home linked to an account, because the certificate comes through DirectorLink's servers. **Direct HTTPS Status** says what it does; the app shows it in Settings → Controller → Direct connection at home
- **Schedules** (`On`, or `Paused` to stop every DirectorLink schedule), **Schedule Status** (what is on and what runs next) and **Last Automation** (the last scene DirectorLink ran, when and why); the action **Print Schedules and Scenes** lists them all in the Lua output
- **Sonos:** `Off`, so DirectorLink looks for no Sonos speaker. `On` shows each Sonos room in the app, in the Control4 room of the same name, with play, pause, skip, volume and the Sonos favorites, rooms that play together in groups (join, leave, the group's volume), and scenes that start a favorite at a volume, set the volume, resume or pause; **Sonos Address** (optional) names one player when the search finds none, and **Sonos Players** shows what was found ([`SONOS.md`](SONOS.md))
- **Jewish Calendar:** `Off`, so DirectorLink works out no Shabbat or holiday times. `On` gives schedules and the app Shabbat and holiday times, the Hebrew date and the weekly reading, from the project's location; **Calendar Status** shows what it works out
- **Log Level** and **Inventory** (rooms and devices found)

Actions: **New Pairing Code**, **Revoke All API Keys** (every key, invitation and scene link), **Print Schedules and Scenes**, **Refresh Project** (reads the project again after changes in Composer; DirectorLink is also meant to do it by itself a few seconds after Composer's changes, which has not yet been seen on a real controller), **Reset Remote Identity** (a last resort: the controller becomes a new home for DirectorLink's servers, and the owner links it again), and **Remove All Scene Links** (every scene's link for automations stops working at once). If a copy of the project's data got into the wrong hands, run Revoke All API Keys, and have the home's owner use **Replace the remote secret** in the app (Settings → Account, at home). A DirectorLink backup file together with its password counts as such a copy.

If the status shows an error, open `GET /v1/logs` ([`../api/README.md`](../api/README.md)) or capture the DirectorLink Lua log and open a GitHub issue.

## 4. Pair the owner's device

Open **https://app.directorlink.io**, enter the controller IP (or tap **Find my controller**, in Chromium browsers on computers and Android) and the **Pairing Code** from the DirectorLink properties. The device gets an admin key.

> **Pair from a computer or an Android phone, not from an iPhone or iPad.** On iPhone and iPad every browser (Safari, Chrome, Edge, …) uses Apple's WebKit, which blocks a secure page such as app.directorlink.io from reaching the controller's plain `http://` address on the home network, and offers no permission to allow it. Pairing cannot work there. iPhones and iPads join through the account instead: on a paired computer at home, sign in and use Settings → Account → **Link this home**. Then, on the iPhone, sign in with the same account and tap **Join from another device**; the computer shows the request, and you approve it there by typing the code the iPhone shows (1.7.0). This is the way for the app added to the Home Screen, which iOS never opens links in. **Add my other device** still makes a QR code and a link, which **Join with an invitation** takes too. Since 1.12.0 a link opened in Safari recommends joining in the Home Screen app, and a Safari tab that joined can move there (Settings → Account → **Move to the Home Screen app**).

A code is valid for 15 minutes and works once, and only on the home network. Five wrong codes lock pairing for that device for a minute; twenty close the code. The app never sends the code: it pairs with CPace, so neither the code nor its new key can be read or taken on the network (with a DirectorLink before 1.3.0 it warns first, and only **Pair anyway** sends the code). The API console pairs the same way, and its own key lasts a day. A new DirectorLink shows one right away; later, run the Composer action **New Pairing Code** on DirectorLink (an installer can read it out for the homeowner). Other devices and family members do not pair: an admin adds them (Settings → Users → **Add a user**, with a link for their Google or Apple account or a pairing code at home), your own other devices join with **Add my other device** (Settings → Account), or an admin creates a key (API console → Keys).

## Updating DirectorLink

DirectorLink does not update itself: driver updates go through Composer (ADR-035).

Update the installed driver manually through Composer Pro using the `DirectorLink.c4z` asset from the desired GitHub Release. Admins see in the app when a newer release is out (Settings → Controller, and a notice on Home), with a download of its `DirectorLink.c4z` and the steps in Composer.

**Important:** before updating, make sure the local file is named exactly `DirectorLink.c4z`. Do not select `DirectorLink (1).c4z`, `DirectorLink (2).c4z`, etc. A real Director snapshot showed those suffixed filenames can be installed as separate driver files instead of replacing the canonical package. A browser adds the suffix when an older `DirectorLink.c4z` is already in the download folder, so delete that one before downloading (or download into an empty folder).

To downgrade, download `DirectorLink.c4z` from an older release and install that version through Composer Pro. Release notes say when a downgrade is not safe.

Do not remove and re-add the project instance unless a release specifically requires it. Removing it deletes everything DirectorLink keeps: have an admin make a backup in the app first (Settings → Controller → Backup, [`BACKUP.md`](BACKUP.md)), or turn on automatic backups to the account there (1.6.0).
