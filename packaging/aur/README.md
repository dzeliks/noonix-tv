# AUR packages

Two packages, each in its own folder with a `PKGBUILD` and `.SRCINFO`:

- `noonix-tv` builds the tagged release from source. It needs Qt 6.8+, mpv, SDL3 and Rust, and
  fetches cxx-qt's CMake helpers and the Rust crates while building. No app keys are built in, so
  setup asks for a TMDB key.
- `noonix-tv-bin` unpacks the release AppImage (x86_64 or aarch64) into `/opt/noonix-tv`. It has
  the app keys of the release build. The app's own updater only runs inside an AppImage, so pacman
  updates it.

## A new release

1. Once the release is published: `./bump.sh <version>` (both versions, the AppImages' sums from
   the release's `SHA256SUMS`, `.SRCINFO`).
2. Build and check each one: `makepkg -f`, then `namcap PKGBUILD *.pkg.tar.zst`.
3. `./publish.sh` pushes both to the AUR (or name one: `./publish.sh noonix-tv-bin`).

The first time: make an account on [aur.archlinux.org](https://aur.archlinux.org/register) and add
this machine's public SSH key (`~/.ssh/id_ed25519.pub`) under My Account › SSH Public Key. The first
push makes the package.
