# frozen_string_literal: true

require "fileutils"
require "digest"
require "optparse"
require "rbconfig"
require "cgi"
require "json"
require "shellwords"

module CanopusPackage
  module_function

  def build(platform:, output:, ruby: nil, ruby_root: nil, source: File.expand_path("..", __dir__))
    raise ArgumentError, "platform must be mac, linux, or windows" unless %w[mac linux windows].include?(platform)
    output, source = File.expand_path(output), File.realpath(source)
    raise ArgumentError, "output cannot contain control characters" if output.match?(/[\x00-\x1f\x7f]/)
    raise ArgumentError, "output must not already exist" if File.exist?(output) || File.symlink?(output)
    raise ArgumentError, "output cannot be inside the source tree" if output.start_with?(source + File::SEPARATOR)
    raise ArgumentError, "mac output must end in .app" if platform == "mac" && !output.end_with?(".app")
    ruby ||= platform == "windows" ? "ruby.exe" : RbConfig.ruby
    raise ArgumentError, "Ruby executable cannot contain quotes or control characters" if ruby.empty? || ruby.match?(/["\x00-\x1f\x7f]/)
    version = File.read(File.join(source, "lib", "canopus", "version.rb"))[/VERSION\s*=\s*["']([^"']+)/, 1]
    raise ArgumentError, "cannot read Canopus version" unless version
    entries = %w[lib exe assets LICENSE.txt README.md CHANGELOG.md].filter_map do |name|
      path = File.join(source, name)
      path if File.exist?(path)
    end
    entries.each do |path|
      candidates = [path, *Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)]
      raise ArgumentError, "source distribution contains symlinks" if candidates.any? { |candidate| File.symlink?(candidate) }
    end
    application_root = File.join(output, platform == "mac" ? "Contents/Resources/canopus" : "share/canopus")
    FileUtils.mkdir_p(application_root)
    entries.each { |entry| FileUtils.cp_r(entry, application_root, preserve: true) }
    bundled_ruby = ruby_root && bundle_ruby(ruby_root, output)
    case platform
    when "mac"
      executable = File.join(output, "Contents", "MacOS", "canopus")
      shell_launcher(executable, ruby, "../Resources/canopus/exe/canopus", bundled_ruby && "../Resources/runtime/#{bundled_ruby}")
      File.write(File.join(output, "Contents", "Info.plist"), <<~PLIST)
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>Canopus</string>
          <key>CFBundleDisplayName</key><string>Canopus</string>
          <key>CFBundleExecutable</key><string>canopus</string>
          <key>CFBundleIdentifier</key><string>org.rubifex.canopus</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>#{CGI.escapeHTML(version)}</string>
          <key>CFBundleVersion</key><string>#{CGI.escapeHTML(version)}</string>
          <key>NSHighResolutionCapable</key><true/>
          <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
          <key>CFBundleDocumentTypes</key>
          <array><dict>
            <key>CFBundleTypeName</key><string>Text Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>txt</string><string>md</string><string>markdown</string><string>rb</string><string>json</string><string>xml</string></array>
            <key>LSItemContentTypes</key>
            <array><string>public.plain-text</string><string>net.daringfireball.markdown</string><string>public.json</string><string>public.xml</string></array>
          </dict></array>
        </dict></plist>
      PLIST
    when "linux"
      executable = File.join(output, "bin", "canopus")
      shell_launcher(executable, ruby, "../share/canopus/exe/canopus", bundled_ruby && "../runtime/#{bundled_ruby}")
      desktop = File.join(output, "share", "applications", "canopus.desktop")
      FileUtils.mkdir_p(File.dirname(desktop))
      quoted = executable.gsub(/[\\"`$%]/) { |character| character == "%" ? "%%" : character == "\\" ? "\\" * 4 : "\\" * 2 + character }
      File.write(desktop, <<~DESKTOP)
        [Desktop Entry]
        Type=Application
        Name=Canopus
        Comment=Pure Ruby text editor
        Exec="#{quoted}" %F
        Terminal=false
        Categories=Development;TextEditor;
        MimeType=text/plain;text/markdown;application/json;application/xml;text/x-ruby;
        StartupNotify=true
      DESKTOP
      write_linux_installers(output)
    when "windows"
      executable = File.join(output, "canopus.cmd")
      command = bundled_ruby ? "%~dp0runtime\\#{bundled_ruby.tr('/', '\\')}" : ruby.gsub('%', '%%')
      File.write(executable, "@echo off\r\nsetlocal DisableDelayedExpansion\r\n\"#{command}\" \"%~dp0share\\canopus\\exe\\canopus\" %*\r\nexit /b %errorlevel%\r\n")
      File.write(File.join(output, "Create-Shortcut.ps1"), <<~POWERSHELL.gsub("\n", "\r\n"))
        param([string]$Destination = [Environment]::GetFolderPath('Desktop'))
        $ErrorActionPreference = 'Stop'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path $Destination 'Canopus.lnk'))
        $shortcut.TargetPath = Join-Path $PSScriptRoot 'canopus.cmd'
        $shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
        $shortcut.Description = 'Canopus text editor (requires CRuby 3.1+)'
        $shortcut.Save()
      POWERSHELL
      write_windows_installers(output, version)
    end
    metadata = {name: "canopus", version: version, platform: platform, ruby: bundled_ruby ? "runtime/#{bundled_ruby}" : ruby, bundled_ruby: !bundled_ruby.nil?}
    File.write(File.join(output, "package.json"), JSON.pretty_generate(metadata) + "\n")
    write_manifest(output, version)
    executable
  end

  def bundle_ruby(root, output)
    root = File.realpath(root)
    raise ArgumentError, "ruby root must be a directory" unless File.directory?(root)
    raise ArgumentError, "package output cannot be inside ruby root" if output.start_with?(root + File::SEPARATOR)
    files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).reject { |path| [".", ".."].include?(File.basename(path)) }
    raise ArgumentError, "ruby root contains symlinks" if files.any? { |path| File.symlink?(path) }
    relative = if File.file?(File.join(root, "bin", "ruby"))
      "bin/ruby"
    elsif File.file?(File.join(root, "bin", "ruby.exe"))
      "bin/ruby.exe"
    else
      raise ArgumentError, "ruby root must contain bin/ruby or bin/ruby.exe"
    end
    destination = File.join(output, "runtime")
    FileUtils.mkdir_p(destination)
    Dir.children(root).each { |entry| FileUtils.cp_r(File.join(root, entry), destination, preserve: true) }
    relative
  end

  def write_manifest(output, version)
    files = Dir.glob(File.join(output, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
      next unless File.file?(path) && !File.symlink?(path)

      [path.delete_prefix(output + File::SEPARATOR), Digest::SHA256.file(path).hexdigest]
    end.to_h
    File.write(File.join(output, "manifest.json"), JSON.pretty_generate(version: version, algorithm: "SHA-256", files: files) + "\n")
  end

  def shell_launcher(path, ruby, relative, bundled = nil)
    FileUtils.mkdir_p(File.dirname(path))
    command = bundled ? '"$here/' + bundled + '"' : Shellwords.escape(ruby)
    File.write(path, <<~SH)
      #!/bin/sh
      set -eu
      here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      exec #{command} --yjit "$here/#{relative}" "$@"
    SH
    File.chmod(0o755, path)
  end

  def write_linux_installers(output)
    File.write(File.join(output, "Install.sh"), <<~SH)
      #!/bin/sh
      set -eu
      package=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      root=${XDG_DATA_HOME:-"$HOME/.local/share"}/canopus
      applications=${XDG_DATA_HOME:-"$HOME/.local/share"}/applications
      desktop="$applications/canopus.desktop"
      marker="$root/.canopus-installed"
      if [ -e "$root" ]; then
        printf '%s\n' "Canopus is already installed in $root; run Uninstall.sh first" >&2
        exit 1
      fi
      if [ -e "$desktop" ] && ! grep -q '^# canopus-managed$' "$desktop"; then
        printf '%s\n' "Refusing to replace existing desktop entry: $desktop" >&2
        exit 1
      fi
      mkdir -p "$root" "$applications"
      cp -R "$package/." "$root/"
      printf '%s\n' canopus-installed > "$marker"
      cat > "$desktop" <<DESKTOP
      # canopus-managed
      [Desktop Entry]
      Type=Application
      Name=Canopus
      Comment=Pure Ruby text editor
      Exec="$root/bin/canopus" %F
      Terminal=false
      Categories=Development;TextEditor;
      MimeType=text/plain;text/markdown;application/json;application/xml;text/x-ruby;
      StartupNotify=true
      DESKTOP
      command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$applications" || true
      printf '%s\n' "Installed Canopus in $root"
    SH
    File.chmod(0o755, File.join(output, "Install.sh"))
    File.write(File.join(output, "Uninstall.sh"), <<~SH)
      #!/bin/sh
      set -eu
      root=${XDG_DATA_HOME:-"$HOME/.local/share"}/canopus
      applications=${XDG_DATA_HOME:-"$HOME/.local/share"}/applications
      marker="$root/.canopus-installed"
      [ -f "$marker" ] && grep -qx canopus-installed "$marker" || {
        printf '%s\n' "Canopus install marker is missing: $root" >&2
        exit 1
      }
      rm -rf -- "$root"
      desktop="$applications/canopus.desktop"
      if [ -f "$desktop" ] && grep -q '^# canopus-managed$' "$desktop"; then
        rm -f -- "$desktop"
      fi
      command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$applications" || true
      printf '%s\n' "Uninstalled Canopus"
    SH
    File.chmod(0o755, File.join(output, "Uninstall.sh"))
  end

  def write_windows_installers(output, version)
    installers = {
      "Install.ps1" => <<~POWERSHELL,
        param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'Canopus'))
        $ErrorActionPreference = 'Stop'
        $package = Split-Path -Parent $MyInvocation.MyCommand.Path
        if (Test-Path -LiteralPath $Destination) { throw "Destination already exists: $Destination" }
        $progId = 'Canopus.Document'
        $class = "Registry::HKEY_CURRENT_USER\\Software\\Classes\\$progId"
        if (Test-Path -LiteralPath $class) { throw "ProgID already exists; uninstall first: $progId" }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Copy-Item -Path (Join-Path $package '*') -Destination $Destination -Recurse -Force
        New-Item -Force -Path "$class\\shell\\open\\command" | Out-Null
        Set-ItemProperty -Path $class -Name '(Default)' -Value 'Canopus document'
        Set-ItemProperty -Path "$class\\shell\\open\\command" -Name '(Default)' -Value ('"' + $Destination + '\\canopus.cmd" "%1"')
        Set-ItemProperty -Path $class -Name 'FriendlyTypeName' -Value 'Canopus document'
        Set-ItemProperty -Path $class -Name CanopusManaged -Value 1
        foreach ($extension in @('.txt', '.md', '.markdown', '.rb', '.json', '.xml')) {
          $openWith = "Registry::HKEY_CURRENT_USER\\Software\\Classes\\$extension\\OpenWithProgids"
          New-Item -Force -Path $openWith | Out-Null
          New-ItemProperty -Force -Path $openWith -Name $progId -Value '' | Out-Null
        }
        $uninstall = 'Registry::HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Canopus'
        New-Item -Force -Path $uninstall | Out-Null
        Set-ItemProperty -Path $uninstall -Name DisplayName -Value 'Canopus'
        Set-ItemProperty -Path $uninstall -Name DisplayVersion -Value '#{version}'
        Set-ItemProperty -Path $uninstall -Name InstallLocation -Value $Destination
        Set-ItemProperty -Path $uninstall -Name UninstallString -Value ('powershell.exe -ExecutionPolicy Bypass -File "' + $Destination + '\\Uninstall.ps1"')
        Write-Output "Installed Canopus in $Destination"
      POWERSHELL
      "Uninstall.ps1" => <<~POWERSHELL
        param([string]$Destination = $PSScriptRoot)
        $ErrorActionPreference = 'Stop'
        $progId = 'Canopus.Document'
        $uninstall = 'Registry::HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Canopus'
        $record = Get-ItemProperty -Path $uninstall -ErrorAction SilentlyContinue
        if (!$record -or $record.InstallLocation -ne $Destination) { throw "Canopus install record does not match: $Destination" }
        $class = "Registry::HKEY_CURRENT_USER\\Software\\Classes\\$progId"
        $owner = Get-ItemProperty -Path $class -Name CanopusManaged -ErrorAction SilentlyContinue
        if ($owner.CanopusManaged -ne 1) { throw "Canopus ProgID is not managed by this installer" }
        foreach ($extension in @('.txt', '.md', '.markdown', '.rb', '.json', '.xml')) {
          $openWith = "Registry::HKEY_CURRENT_USER\\Software\\Classes\\$extension\\OpenWithProgids"
          Remove-ItemProperty -Path $openWith -Name $progId -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $class -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $uninstall -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        Write-Output 'Uninstalled Canopus'
      POWERSHELL
    }
    installers.each do |name, contents|
      path = File.join(output, name)
      File.write(path, contents.gsub("\n", "\r\n"))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |flags|
    flags.banner = "Usage: ruby tools/package.rb --platform mac|linux|windows --output PATH [--ruby PATH|--ruby-root DIRECTORY]"
    flags.on("--platform NAME") { |value| options[:platform] = value }
    flags.on("--output PATH") { |value| options[:output] = value }
    flags.on("--ruby PATH", "System Ruby executable when no runtime is bundled") { |value| options[:ruby] = value }
    flags.on("--ruby-root DIRECTORY", "Relocatable Ruby root containing bin/ruby") { |value| options[:ruby_root] = value }
  end
  parser.parse!
  abort parser.to_s unless options[:platform] && options[:output]
  puts CanopusPackage.build(**options)
end
