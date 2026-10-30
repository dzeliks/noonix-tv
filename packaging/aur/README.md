# AUR packages

Two packages, each in its own folder with a `PKGBUILD` and `.SRCINFO`:

- `noonix-tv` builds the tagged release from source. It needs Qt 6.8+, mpv, SDL3 and Rust, and
  fetches cxx-qt's CMake helpers and the Rust crates while building. No app keys are built in, so
  setup asks for a TMDB key.
- `noonix-tv-bin` unpacks the release AppImage into `/opt/noonix-tv`. It has the app keys of the
  release build. The app's own updater only runs inside an AppImage, so pacman updates it.

## A new release

1. Set `pkgver` (and `pkgrel=1`) in both PKGBUILDs.
2. In `noonix-tv-bin`, put the new AppImage's sha256 in `sha256sums` (from the release's
   `SHA256SUMS`).
3. Build and check each one: `makepkg -f`, then `namcap PKGBUILD *.pkg.tar.zst`.
4. Write `.SRCINFO` again: `makepkg --printsrcinfo > .SRCINFO`.
5. Copy the folder into the AUR git repository (`ssh://aur@aur.archlinux.org/<name>.git`),
   commit and push.
