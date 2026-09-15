# Android

No root needed. Install [Syncthing-Fork](https://f-droid.org/packages/com.github.catfriend1.syncthingfork/) from F-Droid. The original Syncthing app is discontinued; the fork is the maintained one.

1. Open the app, allow storage access, note the device ID under Menu > Show device ID.
2. On the server: `docker exec cubby cubby add phone DEVICE-ID`.
3. In the app, Devices > + : paste the server's device ID, name it, set Addresses to `tcp://SERVER_IP:22000`.
4. Accept the "Cubby" folder when the app offers it and pick a directory under internal storage, for example `/storage/emulated/0/Cubby`.
5. Folder > Ignore Patterns: paste [client/stignore](../client/stignore).
6. Settings > Run Conditions: choose Wi-Fi only and whether to sync on battery. Exempt the app from battery optimisation so it survives in the background.

Photos and other apps' files can be shared into the Cubby directory with the system share sheet.
