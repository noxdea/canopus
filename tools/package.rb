# frozen_string_literal: true

require "fileutils"
require "optparse"
require "rbconfig"
require "cgi"
require "json"
require "shellwords"

module CanopusPackage
  module_function

  # Packages the source distribution; never downloads or bundles Ruby or gems.
  def build(platform:, output:, ruby: nil, source: File.expand_path("..", __dir__))
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
    runtime = File.join(output, platform == "mac" ? "Contents/Resources/canopus" : "share/canopus")
    FileUtils.mkdir_p(runtime)
    entries.each { |entry| FileUtils.cp_r(entry, runtime, preserve: true) }
    case platform
    when "mac"
      executable = File.join(output, "Contents", "MacOS", "canopus")
      shell_launcher(executable, ruby, "../Resources/canopus/exe/canopus")
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
        </dict></plist>
      PLIST
    when "linux"
      executable = File.join(output, "bin", "canopus")
      shell_launcher(executable, ruby, "../share/canopus/exe/canopus")
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
        MimeType=text/plain;
        StartupNotify=true
      DESKTOP
    when "windows"
      executable = File.join(output, "canopus.cmd")
      File.write(executable, "@echo off\r\nsetlocal DisableDelayedExpansion\r\n\"#{ruby.gsub('%', '%%')}\" \"%~dp0share\\canopus\\exe\\canopus\" %*\r\nexit /b %errorlevel%\r\n")
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
    end
    File.write(File.join(output, "package.json"), JSON.pretty_generate({name: "canopus", version: version, platform: platform, ruby: ruby, bundled_ruby: false}) + "\n")
    executable
  end

  def shell_launcher(path, ruby, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~SH)
      #!/bin/sh
      set -eu
      here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      exec #{Shellwords.escape(ruby)} --yjit "$here/#{relative}" "$@"
    SH
    File.chmod(0o755, path)
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |flags|
    flags.banner = "Usage: ruby tools/package.rb --platform mac|linux|windows --output PATH [--ruby PATH]"
    flags.on("--platform NAME") { |value| options[:platform] = value }
    flags.on("--output PATH") { |value| options[:output] = value }
    flags.on("--ruby PATH", "System Ruby executable; no runtime is bundled") { |value| options[:ruby] = value }
  end
  parser.parse!
  abort parser.to_s unless options[:platform] && options[:output]
  puts CanopusPackage.build(**options)
end
