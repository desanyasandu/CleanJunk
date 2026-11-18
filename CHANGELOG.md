# Changelog

## 1.1.0
- New **Find big files** window: lists the 40 largest files and folders on the system drive, with Open location / Copy path. Read-only.
- New items: Gradle caches, NuGet/Yarn caches, Delivery Optimization cache, scattered `.dmp`/`.etl` files, Windows component cleanup (DISM), Docker unused data, Windows.old.
- Crash dumps now also cover `C:\Windows\Minidump` and `LiveKernelReports`.
- Text mode: `-BigFiles` lists the largest files and folders.

## 1.0.0
- First public release.
- Window with tick boxes, grouped Safe / Optional, live "will be freed" total, progress bar and log.
- Text mode (`-Console`) and scan-only mode (`-ScanOnly`).
- Skips files changed in the last 24 hours by default (`-MinAgeHours`, or the checkbox).
- Never follows junctions or symlinks while scanning or deleting.
- Works on the Windows system drive, whatever its letter.
