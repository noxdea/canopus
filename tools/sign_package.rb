# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "optparse"
require "tempfile"

module CanopusPackageSignature
  ALGORITHM = "RSA-SHA256"
  SIGNATURE_FILE = "signature.json"
  MANIFEST_FILE = "manifest.json"

  class Error < StandardError; end

  module_function

  def sign(package, private_key_path)
    package = package_directory(package)
    key = OpenSSL::PKey.read(File.binread(private_key_path))
    raise Error, "an RSA private key is required" unless key.is_a?(OpenSSL::PKey::RSA) && key.private?

    payload = File.binread(File.join(package, MANIFEST_FILE))
    signature = {
      "version" => 1,
      "algorithm" => ALGORITHM,
      "manifest" => MANIFEST_FILE,
      "key_id" => Digest::SHA256.hexdigest(key.public_key.to_der),
      "signature" => Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, payload))
    }
    atomic_write(File.join(package, SIGNATURE_FILE), JSON.pretty_generate(signature) + "\n")
    signature
  rescue Errno::ENOENT => error
    raise Error, error.message
  rescue ArgumentError, OpenSSL::OpenSSLError, JSON::ParserError => error
    raise Error, "cannot sign package: #{error.message}"
  end

  def verify(package, public_key_path)
    package = package_directory(package)
    metadata = JSON.parse(File.read(File.join(package, SIGNATURE_FILE)))
    raise Error, "unsupported package signature" unless metadata["version"] == 1 && metadata["algorithm"] == ALGORITHM && metadata["manifest"] == MANIFEST_FILE

    key = OpenSSL::PKey.read(File.binread(public_key_path)).public_key
    raise Error, "an RSA public key is required" unless key.is_a?(OpenSSL::PKey::RSA)
    raise Error, "package signature key does not match" unless metadata["key_id"] == Digest::SHA256.hexdigest(key.to_der)

    payload = File.binread(File.join(package, MANIFEST_FILE))
    signature = Base64.strict_decode64(metadata.fetch("signature"))
    valid = key.verify(OpenSSL::Digest::SHA256.new, signature, payload)
    raise Error, "package signature is invalid" unless valid

    verify_manifest(package, JSON.parse(payload))
    true
  rescue Errno::ENOENT, JSON::ParserError, ArgumentError => error
    raise Error, "cannot verify package: #{error.message}"
  rescue OpenSSL::OpenSSLError => error
    raise Error, "cannot verify package: #{error.message}"
  end

  def package_directory(package)
    package = File.realpath(package)
    raise Error, "package must be a directory" unless File.directory?(package)

    package
  rescue Errno::ENOENT => error
    raise Error, error.message
  end
  private_class_method :package_directory

  def verify_manifest(package, manifest)
    raise Error, "invalid package manifest" unless manifest["algorithm"] == "SHA-256" && manifest["files"].is_a?(Hash)

    manifest["files"].each do |relative, digest|
      raise Error, "invalid manifest entry" unless relative.is_a?(String) && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      path = File.expand_path(relative, package)
      raise Error, "manifest path escapes package" unless path.start_with?(package + File::SEPARATOR) && !File.symlink?(path)
      raise Error, "manifest file is missing: #{relative}" unless File.file?(path)
      raise Error, "manifest hash mismatch: #{relative}" unless Digest::SHA256.file(path).hexdigest == digest
    end
  end
  private_class_method :verify_manifest

  def atomic_write(path, content)
    Tempfile.create([".signature-", ".json"], File.dirname(path)) do |file|
      file.write(content)
      file.flush
      file.fsync
      file.close
      File.rename(file.path, path)
    end
  rescue SystemCallError => error
    raise Error, "cannot write package signature: #{error.message}"
  end
  private_class_method :atomic_write
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |flags|
    flags.banner = "Usage: ruby tools/sign_package.rb --package PATH --private-key PATH | --verify --public-key PATH"
    flags.on("--package PATH", "Package directory") { |value| options[:package] = value }
    flags.on("--private-key PATH", "RSA private key used for signing") { |value| options[:private_key] = value }
    flags.on("--public-key PATH", "RSA public key used for verification") { |value| options[:public_key] = value }
    flags.on("--verify", "Verify the package signature and manifest") { options[:verify] = true }
  end
  parser.parse!
  abort parser.to_s unless options[:package] && (options[:private_key] || (options[:verify] && options[:public_key]))

  begin
    if options[:verify]
      CanopusPackageSignature.verify(options[:package], options[:public_key])
      puts "Package signature and manifest verified."
    else
      CanopusPackageSignature.sign(options[:package], options[:private_key])
      puts "Package signature written to #{File.join(options[:package], CanopusPackageSignature::SIGNATURE_FILE)}."
    end
  rescue CanopusPackageSignature::Error, OpenSSL::OpenSSLError, Errno::ENOENT => error
    warn "package signature: #{error.message}"
    exit 1
  end
end
