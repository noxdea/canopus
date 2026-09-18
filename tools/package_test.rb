# frozen_string_literal: true

require "tmpdir"
require "open3"
require_relative "package"
require "fileutils"

Dir.mktmpdir("canopus-package-") do |directory|
  %w[mac linux windows].each do |platform|
    output = File.join(directory, platform == "mac" ? "Canopus Test.app" : "Canopus #{platform}")
    launcher = CanopusPackage.build(platform: platform, output: output)
    metadata = JSON.parse(File.read(File.join(output, "package.json")))
    raise "runtime must not be bundled" unless metadata["bundled_ruby"] == false
    manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
    raise "manifest algorithm" unless manifest["algorithm"] == "SHA-256"
    raise "manifest missing package metadata" unless manifest["files"].key?("package.json")
    case platform
    when "mac"
      raise "missing mac document types" unless File.read(File.join(output, "Contents", "Info.plist")).include?("CFBundleDocumentTypes")
    when "linux"
      raise "missing Linux installer" unless File.executable?(File.join(output, "Install.sh")) && File.executable?(File.join(output, "Uninstall.sh"))
      raise "missing Linux MIME associations" unless File.read(File.join(output, "share", "applications", "canopus.desktop")).include?("text/markdown")
      raise "Linux installer missing ownership marker" unless File.read(File.join(output, "Install.sh")).include?("canopus-installed")
      raise "Linux installer missing manifest entry" unless manifest["files"].key?("Install.sh")
    when "windows"
      raise "missing Windows installer" unless File.file?(File.join(output, "Install.ps1")) && File.file?(File.join(output, "Uninstall.ps1"))
      installer = File.read(File.join(output, "Install.ps1"))
      raise "missing Windows ProgID" unless installer.include?("Canopus.Document") && installer.include?("Copy-Item -Path")
      raise "Windows installer missing ownership marker" unless installer.include?("CanopusManaged")
      raise "Windows installer missing manifest entry" unless manifest["files"].key?("Install.ps1")
    end
    if platform == "windows"
      raise "missing shortcut installer" unless File.file?(File.join(output, "Create-Shortcut.ps1"))
      raise "unsafe launcher argument forwarding" unless File.read(launcher).include?("%*")
      raise "Windows launcher requires unsupported YJIT" if File.read(launcher).include?("--yjit")
      next
    end
    output_text, status = Open3.capture2e(launcher, "--version")
    raise "packaged #{platform} executable failed: #{output_text}" unless status.success? && output_text.strip == metadata["version"]
    png = File.join(directory, "#{platform}.png")
    output_text, status = Open3.capture2e(launcher, "--headless", png, "--size", "320x200", "--project", directory)
    raise "packaged render failed: #{output_text}" unless status.success? && File.binread(png, 8) == "\x89PNG\r\n\x1a\n".b
    begin
      CanopusPackage.build(platform: platform, output: File.dirname(launcher))
      raise "existing output accepted"
    rescue ArgumentError
      # Existing packages are never overwritten implicitly.
    end
  end
end
Dir.mktmpdir("canopus-ruby-root-") do |directory|
  root = File.join(directory, "ruby")
  FileUtils.mkdir_p(File.join(root, "bin"))
  FileUtils.cp(RbConfig.ruby, File.join(root, "bin", "ruby"))
  output = File.join(directory, "bundled")
  CanopusPackage.build(platform: "linux", output: output, ruby_root: root)
  metadata = JSON.parse(File.read(File.join(output, "package.json")))
  raise "bundled runtime metadata" unless metadata["bundled_ruby"] && metadata["ruby"] == "runtime/bin/ruby"
  raise "bundled launcher path" unless File.read(File.join(output, "bin", "canopus")).include?("../runtime/bin/ruby")
end
puts "Package layouts, launchers, and headless rendering passed (Windows runtime not executed)."
