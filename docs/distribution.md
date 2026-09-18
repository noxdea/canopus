# Packaging

`tools/package.rb` creates a source-based macOS app, Linux launcher and desktop
file, or Windows launcher and shortcut installer. By default the package
includes Canopus sources and assets but not Ruby or gem dependencies; a staged
relocatable Ruby can be included explicitly with `--ruby-root`.

```sh
ruby tools/package.rb --platform mac --output /tmp/Canopus.app --ruby /path/to/ruby
ruby tools/package.rb --platform linux --output /tmp/canopus-linux --ruby /usr/bin/ruby
ruby tools/package.rb --platform windows --output /tmp/canopus-windows --ruby ruby.exe
ruby tools/package.rb --platform mac --output /tmp/Canopus-bundled.app --ruby-root /path/to/staged-ruby
ruby tools/package_test.rb
```

Packages can be signed after building with an RSA release key. The signer only
stores a public key fingerprint and a signature over `manifest.json`; the
private key stays outside the package and CI logs.

```sh
ruby tools/sign_package.rb --package /tmp/canopus-linux --private-key release.pem
ruby tools/sign_package.rb --package /tmp/canopus-linux --verify --public-key release.pub
```

Verification also checks every SHA-256 entry in the manifest. This is a
credential-free integrity check; macOS notarization and Windows Authenticode
still require platform credentials and are release-environment work.

The output path must not exist and must be outside the source tree. Without
`--ruby-root`, build for the Ruby executable available on the destination
machine. With `--ruby-root`, the directory must be a relocatable CRuby staging
root containing `bin/ruby` (or `bin/ruby.exe`); it is copied into the package's
`runtime/` directory and launchers use that relative executable. The staged root
must include Canopus's production gems and must not contain symlinks. The
installed package does not require Bundler.

macOS's system Ruby is generally too old. Linux requires its Wayland/EGL/OpenGL
or X11/GLX libraries, XKB, and `zenity` for file dialogs. Move a Linux package to
its final location before installing its generated desktop file. On Windows, run
`Create-Shortcut.ps1` from the package to create a shortcut.

Every package includes `manifest.json` with SHA-256 entries for its files. These
packages are unsigned and do not bundle security updates for Ruby. Signing,
notarization, and automatic updates require separate platform-specific release
work. See [ADR 005](adr/005-windows-runtime.md) for the
Windows/YJIT runtime decision.
