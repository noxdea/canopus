# frozen_string_literal: true

require "json"
require "fileutils"
require "openssl"
require "tmpdir"
require_relative "sign_package"

Dir.mktmpdir("canopus-signature-") do |directory|
  package = File.join(directory, "package")
  FileUtils.mkdir_p(package)
  File.write(File.join(package, "canopus.txt"), "package\n")
  manifest = {"version" => "0.0.0", "algorithm" => "SHA-256", "files" => {"canopus.txt" => Digest::SHA256.file(File.join(package, "canopus.txt")).hexdigest}}
  File.write(File.join(package, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

  key = OpenSSL::PKey::RSA.new(2048)
  private_key = File.join(directory, "private.pem")
  public_key = File.join(directory, "public.pem")
  File.open(private_key, "w", 0o600) { |file| file.write(key.to_pem) }
  File.write(public_key, key.public_key.to_pem)

  CanopusPackageSignature.sign(package, private_key)
  raise "signature did not verify" unless CanopusPackageSignature.verify(package, public_key)

  File.open(File.join(package, "canopus.txt"), "a") { |file| file << "tampered\n" }
  begin
    CanopusPackageSignature.verify(package, public_key)
    raise "tampered package was accepted"
  rescue CanopusPackageSignature::Error => error
    raise unless error.message.include?("manifest hash mismatch")
  end
end
puts "Package signing and verification passed."
