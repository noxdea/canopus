# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "open-uri"
require "rubygems/package"
require "rubygems/version"
require "securerandom"
require "tmpdir"
require "uri"
require "zlib"

module CanopusUpdater
  FIELDS = %w[channel platform version url size sha256].freeze
  ALGORITHM = "RSA-SHA256"
  MAX_DOWNLOAD = 512 * 1024 * 1024
  MAX_EXTRACTED = 1 * 1024 * 1024 * 1024

  class Error < StandardError; end

  module_function

  def signed_payload(feed)
    JSON.generate(FIELDS.to_h { |field| [field, feed.fetch(field)] })
  end

  def check(feed, public_key:, channel:, platform:, current_version:)
    feed = feed.is_a?(String) ? JSON.parse(feed) : feed
    raise Error, "update feed must be an object" unless feed.is_a?(Hash)
    raise Error, "unsupported update channel" unless feed["channel"] == channel
    raise Error, "unsupported update platform" unless feed["platform"] == platform
    validate_feed!(feed)
    verify_signature!(feed, public_key)
    raise Error, "update version is invalid" unless Gem::Version.new(feed["version"]) > Gem::Version.new(current_version)

    feed
  rescue JSON::ParserError, ArgumentError => error
    raise Error, "invalid update feed: #{error.message}"
  end

  def apply(feed:, public_key:, channel:, platform:, current_version:, install_dir:)
    release = check(feed, public_key: public_key, channel: channel, platform: platform, current_version: current_version)
    install_dir = File.realpath(install_dir)
    raise Error, "install directory must be a directory" unless File.directory?(install_dir)

    Dir.mktmpdir(".canopus-update-", File.dirname(install_dir)) do |directory|
      archive = File.join(directory, "package.tar.gz")
      download(release.fetch("url"), archive, expected_size: release.fetch("size"))
      raise Error, "update archive hash mismatch" unless Digest::SHA256.file(archive).hexdigest == release.fetch("sha256")
      staged = File.join(directory, "package")
      extract(archive, staged)
      replace(install_dir, staged)
    end
    release
  rescue Errno::ENOENT, Errno::EACCES, SystemCallError => error
    raise Error, "update failed: #{error.message}"
  end

  def validate_feed!(feed)
    raise Error, "update feed is missing fields" unless FIELDS.all? { |field| feed.key?(field) }
    raise Error, "update URL must use HTTPS" unless feed["url"].is_a?(String) && URI(feed.fetch("url")).scheme == "https"
    raise Error, "invalid update size" unless feed["size"].is_a?(Integer) && feed["size"].between?(1, MAX_DOWNLOAD)
    raise Error, "invalid update hash" unless feed["sha256"].is_a?(String) && feed["sha256"].match?(/\A[0-9a-f]{64}\z/)
    raise Error, "invalid update signature" unless feed["signature"].is_a?(String) && feed["key_id"].is_a?(String)
    Gem::Version.new(feed.fetch("version"))
    true
  rescue URI::InvalidURIError => error
    raise Error, "invalid update URL: #{error.message}"
  end
  private_class_method :validate_feed!

  def verify_signature!(feed, public_key)
    key = OpenSSL::PKey.read(File.binread(public_key)).public_key
    raise Error, "an RSA public key is required" unless key.is_a?(OpenSSL::PKey::RSA)
    raise Error, "update signing key does not match" unless feed["key_id"] == Digest::SHA256.hexdigest(key.to_der)

    signature = Base64.strict_decode64(feed.fetch("signature"))
    raise Error, "update signature is invalid" unless key.verify(OpenSSL::Digest::SHA256.new, signature, signed_payload(feed))
  rescue OpenSSL::OpenSSLError, ArgumentError => error
    raise Error, "invalid update signature: #{error.message}"
  end
  private_class_method :verify_signature!

  def download(url, destination, expected_size:)
    uri = URI(url)
    raise Error, "update URL must use HTTPS" unless uri.scheme == "https"
    request = Net::HTTP::Get.new(uri.request_uri)
    bytes = 0
    File.open(destination, "wb", 0o600) do |file|
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        response = http.request(request) do |body|
          raise Error, "update download failed: #{body.code}" unless body.is_a?(Net::HTTPSuccess)
          if body["content-length"] && body["content-length"].to_i != expected_size
            raise Error, "update size does not match feed"
          end
          body.read_body do |chunk|
            bytes += chunk.bytesize
            raise Error, "update download is too large" if bytes > expected_size || bytes > MAX_DOWNLOAD
            file.write(chunk)
          end
        end
        raise Error, "update download failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      end
    end
    raise Error, "update size does not match feed" unless bytes == expected_size
  rescue URI::InvalidURIError, SocketError, IOError, OpenSSL::OpenSSLError, Net::OpenTimeout, Net::ReadTimeout => error
    raise Error, "update download failed: #{error.message}"
  end
  private_class_method :download

  def extract(archive, destination)
    FileUtils.mkdir_p(destination)
    seen, total = {}, 0
    Zlib::GzipReader.open(archive) do |gzip|
      Gem::Package::TarReader.new(gzip).each do |entry|
        name = entry.full_name.to_s
        raise Error, "unsafe update archive path" if name.empty? || name.include?("\0") || name.start_with?("/") || name.split("/").include?("..")
        raise Error, "duplicate update archive path" if seen[name]
        seen[name] = true
        path = File.expand_path(name, destination)
        raise Error, "unsafe update archive path" unless path.start_with?(destination + File::SEPARATOR)
        if entry.directory?
          FileUtils.mkdir_p(path)
        elsif entry.file?
          total += entry.size
          raise Error, "update archive is too large" if total > MAX_EXTRACTED
          FileUtils.mkdir_p(File.dirname(path))
          mode = entry.header.mode.to_i & 0o777
          mode = 0o644 if mode.zero?
          File.open(path, "wb", mode) { |file| IO.copy_stream(entry, file) }
        else
          raise Error, "unsupported update archive entry"
        end
      end
    end
    raise Error, "update archive is missing package metadata" unless File.file?(File.join(destination, "package.json")) && File.file?(File.join(destination, "manifest.json"))
    destination
  rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError => error
    raise Error, "invalid update archive: #{error.message}"
  end
  private_class_method :extract

  def replace(install_dir, staged)
    backup = "#{install_dir}.backup-#{Process.pid}-#{SecureRandom.hex(4)}"
    File.rename(install_dir, backup)
    begin
      File.rename(staged, install_dir)
    rescue SystemCallError => error
      File.rename(backup, install_dir) rescue nil
      raise Error, "cannot activate update: #{error.message}"
    end
    FileUtils.rm_rf(backup)
  end
  private_class_method :replace
end

if $PROGRAM_NAME == __FILE__
  platform = RUBY_PLATFORM.match?(/darwin/) ? "mac" : RUBY_PLATFORM.match?(/mswin|mingw/) ? "windows" : "linux"
  options = {channel: "stable", platform: platform}
  parser = OptionParser.new do |flags|
    flags.banner = "Usage: ruby tools/update.rb --feed URL --public-key PATH --install-dir PATH --current-version VERSION"
    flags.on("--feed URL", "Signed update feed URL") { |value| options[:feed] = value }
    flags.on("--public-key PATH", "RSA public key used to verify the feed") { |value| options[:public_key] = value }
    flags.on("--install-dir PATH", "Existing package directory") { |value| options[:install_dir] = value }
    flags.on("--current-version VERSION", "Installed package version") { |value| options[:current_version] = value }
    flags.on("--channel NAME", "Update channel (default: stable)") { |value| options[:channel] = value }
    flags.on("--platform NAME", "Package platform") { |value| options[:platform] = value }
  end
  parser.parse!
  abort parser.to_s unless %i[feed public_key install_dir current_version].all? { |key| options[key] }

  begin
    feed = URI(options.fetch(:feed)).open(&:read)
    release = CanopusUpdater.apply(feed: feed, public_key: options.fetch(:public_key), channel: options.fetch(:channel),
      platform: options.fetch(:platform), current_version: options.fetch(:current_version), install_dir: options.fetch(:install_dir))
    puts "Updated Canopus to #{release.fetch("version")}."
  rescue CanopusUpdater::Error, OpenSSL::OpenSSLError, Errno::ENOENT => error
    warn "update: #{error.message}"
    exit 1
  end
end
