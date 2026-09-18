# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "rubygems/package"
require "tmpdir"
require "zlib"
require_relative "update"

def archive_package(path, files)
  Zlib::GzipWriter.open(path) do |gzip|
    Gem::Package::TarWriter.new(gzip) do |tar|
      files.each do |name, contents|
        tar.add_file_simple(name, 0o644, contents.bytesize) { |entry| entry.write(contents) }
      end
    end
  end
end

Dir.mktmpdir("canopus-update-") do |directory|
  key = OpenSSL::PKey::RSA.new(2048)
  public_key = File.join(directory, "public.pem")
  File.write(public_key, key.public_key.to_pem)
  archive = File.join(directory, "package.tar.gz")
  files = {"package.json" => '{"name":"canopus","version":"0.5.0"}\n', "manifest.json" => '{"version":"0.5.0","algorithm":"SHA-256","files":{}}\n'}
  archive_package(archive, files)
  feed = {"channel" => "stable", "platform" => "linux", "version" => "0.5.0", "url" => "https://example.invalid/package.tar.gz",
    "size" => File.size(archive), "sha256" => Digest::SHA256.file(archive).hexdigest}
  feed["key_id"] = Digest::SHA256.hexdigest(key.public_key.to_der)
  feed["signature"] = Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, CanopusUpdater.signed_payload(feed)))
  raise "feed check failed" unless CanopusUpdater.check(feed, public_key: public_key, channel: "stable", platform: "linux", current_version: "0.4.0") == feed
  begin
    old_feed = feed.merge("version" => "0.4.0")
    old_feed["signature"] = Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, CanopusUpdater.signed_payload(old_feed)))
    CanopusUpdater.check(old_feed, public_key: public_key, channel: "stable", platform: "linux", current_version: "0.4.0")
    raise "old feed accepted"
  rescue CanopusUpdater::Error
    # Expected: the signature no longer matches the modified version.
  end

  install = File.join(directory, "installed")
  FileUtils.mkdir_p(install)
  File.write(File.join(install, "old.txt"), "old")
  staged = File.join(directory, "staged")
  CanopusUpdater.send(:extract, archive, staged)
  CanopusUpdater.send(:replace, install, staged)
  raise "update was not activated" unless File.read(File.join(install, "package.json")).include?("0.5.0")
  raise "rollback fixture missing" unless !File.exist?(File.join(install, "old.txt"))

  rollback = File.join(directory, "rollback")
  FileUtils.mkdir_p(rollback)
  File.write(File.join(rollback, "old.txt"), "old")
  begin
    CanopusUpdater.send(:replace, rollback, File.join(directory, "missing-stage"))
    raise "failed activation was accepted"
  rescue CanopusUpdater::Error
    raise "rollback did not restore install" unless File.read(File.join(rollback, "old.txt")) == "old"
  end

  unsafe_archive = File.join(directory, "unsafe.tar.gz")
  archive_package(unsafe_archive, {"../escaped.txt" => "nope"})
  begin
    CanopusUpdater.send(:extract, unsafe_archive, File.join(directory, "unsafe"))
    raise "unsafe archive was accepted"
  rescue CanopusUpdater::Error
    raise "archive escaped staging directory" if File.exist?(File.join(directory, "escaped.txt"))
  end
end
puts "Update feed verification and staged replacement passed."
