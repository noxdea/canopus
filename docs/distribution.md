# Packaging

`tools/package.rb` creates a source-based macOS app, Linux launcher and desktop
file, or Windows launcher and shortcut installer. The package includes Canopus
sources and assets, but not Ruby, native binaries, or gem dependencies.

```sh
ruby tools/package.rb --platform mac --output /tmp/Canopus.app --ruby /path/to/ruby
ruby tools/package.rb --platform linux --output /tmp/canopus-linux --ruby /usr/bin/ruby
ruby tools/package.rb --platform windows --output /tmp/canopus-windows --ruby ruby.exe
ruby tools/package_test.rb
```

The output path must not exist and must be outside the source tree. Build for the
Ruby executable available on the destination machine. Canopus requires CRuby
3.1 or newer and its runtime gems installed for that Ruby. The installed package
does not require Bundler.

macOS's system Ruby is generally too old. Linux requires its Wayland/EGL/OpenGL
or X11/GLX libraries, XKB, and `zenity` for file dialogs. Move a Linux package to
its final location before installing its generated desktop file. On Windows, run
`Create-Shortcut.ps1` from the package to create a shortcut.

These packages are unsigned and do not bundle security updates for Ruby. Signing,
notarization, automatic updates, and a relocatable Ruby runtime require separate
platform-specific release work. See [ADR 005](adr/005-windows-runtime.md) for the
Windows/YJIT runtime decision.
