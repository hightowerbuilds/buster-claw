# Bundled Messages adapter

`imsg` v0.15.6, source revision `9cbb8ab62071287c41e4d0dee5ccb8765f0b664d`:
https://github.com/openclaw/imsg

The desktop build stages its checksum-pinned, upstream-signed macOS executable
and adjacent Swift resource bundles under the application's `priv/messages/`.
The optional injected helper is excluded. `stage_messages_adapter.sh` verifies
the downloaded archive and executable before including them in a release.

Notices included here correspond to the pinned Package.resolved:

| Component | Version | Revision |
|---|---|---|
| imsg | 0.15.6 | 9cbb8ab62071287c41e4d0dee5ccb8765f0b664d |
| Commander | 0.2.4 | bd219c4ee9032fee3e009856f81fcc6ec09a85f4 |
| SQLite.swift | 0.16.0 | 964c300fb0736699ce945c9edb56ecd62eba27a3 |
| PhoneNumberKit | 5.0.9 | 15c27dbf811e96b9fe48525389ffe042adb9f8cb |

CSQLite in that lockfile is a Linux-only dependency; this is the macOS artifact.
