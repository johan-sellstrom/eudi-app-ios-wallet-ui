# Status

## 2026-05-15

- [x] Sync `main` with the latest changes from `upstream/main`.
  - Plan: create the tracking issue, fetch upstream, merge upstream into local `main`, verify the build, then push the synced branch.
  - Completed: merged `upstream/main` and verified `EUDI Wallet Dev` with an arm64 iOS Simulator build.

- [ ] Align Xcode marketing versions to `2026.05.2`.
  - Plan: update Xcode build settings so the app and ID provider extension share `CFBundleShortVersionString`, verify the Release Dev build settings and an archive/build path, then push the change.
