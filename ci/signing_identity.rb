require "base64"
require "fileutils"
require "open3"
require "openssl"
require "tmpdir"
require "time"

# No private material or password is printed. This verifies match's actual
# decrypted output, including its historical PEM files with a .p12 extension.
module YKCamSigning
  def self.run!(*arguments)
    output, errors, result = Open3.capture3(*arguments)
    raise "#{File.basename(arguments.first)} failed during identity verification: #{errors}" unless result.success?
    output
  end

  def self.certificate_fingerprint(value)
    data = if value.is_a?(OpenSSL::X509::Certificate)
             value.to_der
           elsif value.respond_to?(:string)
             value.string
           else
             value
           end
    raise "Unsupported profile certificate representation" unless data.is_a?(String)
    # plist's <data> StringIO buffer can retain UTF-8 while OpenSSL DER is
    # ASCII-8BIT. Parse the certificate and hash canonical binary DER so Ruby
    # encoding labels cannot make the same certificate compare unequal.
    canonical_der = OpenSSL::X509::Certificate.new(data.b).to_der.b
    OpenSSL::Digest::SHA256.hexdigest(canonical_der)
  rescue OpenSSL::X509::CertificateError
    raise "Profile contains an invalid X.509 certificate"
  end

  def self.verify_profile_certificate!(certificates, expected:)
    expected_fingerprint = certificate_fingerprint(expected)
    fingerprints = certificates.map { |item| certificate_fingerprint(item) }
    unless fingerprints.include?(expected_fingerprint)
      # Certificate fingerprints are public metadata; never log certificate
      # contents, private keys or passwords while diagnosing a true mismatch.
      raise "Profile is not bound to the verified existing certificate (expected SHA256 #{expected_fingerprint}; profile SHA256 #{fingerprints.join(', ')})"
    end
  end

  def self.verify_identity(raw:, cert_id:, apple_certificate:, keychain:)
    certificate = OpenSSL::X509::Certificate.new(File.binread(File.join(raw, "#{cert_id}.cer")))
    expected = OpenSSL::X509::Certificate.new(Base64.strict_decode64(apple_certificate))
    raise "Saved certificate does not match Apple certificate #{cert_id}" unless certificate.to_der == expected.to_der
    raise "Saved certificate expired or is not yet valid" unless certificate.not_before <= Time.now && certificate.not_after > Time.now
    private_data = File.binread(File.join(raw, "#{cert_id}.p12"))
    key = if private_data.include?("-----BEGIN")
            OpenSSL::PKey.read(private_data)
          else
            OpenSSL::PKCS12.new(private_data, "").key
          end
    raise "Saved certificate and private key do not match" unless key && certificate.check_private_key(key)
    subject = certificate.subject.to_a.to_h { |name, value, _type| [name, value] }
    team_id = subject.fetch("OU")
    raise "Distribution certificate has no valid Team ID" unless team_id.match?(/\A[A-Z0-9]{10}\z/)
    raise "Expected an Apple Distribution certificate" unless subject.fetch("CN").match?(/\A(?:Apple|iPhone) Distribution:/)
    fingerprint = OpenSSL::Digest::SHA1.hexdigest(certificate.to_der).upcase
    identities = run!("security", "find-identity", "-v", "-p", "codesigning", keychain)
    raise "The saved private key is not a trusted codesigning identity in the temporary keychain" unless identities.scan(/\b[0-9A-Fa-f]{40}\b/).map(&:upcase).include?(fingerprint)
    Dir.mktmpdir("ykcam-signing-probe-", ENV.fetch("RUNNER_TEMP")) do |directory|
      probe = File.join(directory, "probe")
      FileUtils.cp("/bin/echo", probe)
      run!("codesign", "--force", "--sign", fingerprint, "--keychain", keychain, "--timestamp=none", probe)
      run!("codesign", "--verify", "--strict", probe)
    end
    { team_id: team_id, fingerprint: fingerprint, certificate: certificate }
  end

  def self.verify_profile(path:, bundle_id:, identity:)
    # Enforce the CMS content signature before parsing the downloaded profile.
    cms = OpenSSL::PKCS7.new(File.binread(path))
    raise "Provisioning profile content signature is invalid" unless cms.verify([], OpenSSL::X509::Store.new, nil, OpenSSL::PKCS7::NOVERIFY)
    profile = FastlaneCore::ProvisioningProfile.parse(path)
    raise "Profile belongs to a different Team" unless profile.fetch("TeamIdentifier").include?(identity.fetch(:team_id))
    raise "Profile is not for iOS" unless profile.fetch("Platform").include?("iOS")
    raise "Profile is not App Store distribution" if profile["ProvisionsAllDevices"] || profile.key?("ProvisionedDevices")
    raise "Profile is expired" unless Time.parse(profile.fetch("ExpirationDate").to_s) > Time.now
    entitlements = profile.fetch("Entitlements")
    prefixes = profile.fetch("ApplicationIdentifierPrefix")
    raise "Profile has the wrong or wildcard Bundle ID" unless prefixes.map { |prefix| "#{prefix}.#{bundle_id}" }.include?(entitlements["application-identifier"])
    raise "Profile enables debugging" unless entitlements["get-task-allow"] == false
    raise "Profile entitlement Team mismatch" unless entitlements["com.apple.developer.team-identifier"] == identity.fetch(:team_id)
    verify_profile_certificate!(profile.fetch("DeveloperCertificates"), expected: identity.fetch(:certificate))
    profile
  end
end
