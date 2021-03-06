module DiasporaFederation
  module Salmon
    # Represents a Magic Envelope for Diaspora* federation messages.
    #
    # When generating a Magic Envelope, an instance of this class is created and
    # the contents are specified on initialization. Optionally, the payload can be
    # encrypted ({MagicEnvelope#encrypt!}), before the XML is returned
    # ({MagicEnvelope#envelop}).
    #
    # The generated XML appears like so:
    #
    #   <me:env>
    #     <me:data type="application/xml">{data}</me:data>
    #     <me:encoding>base64url</me:encoding>
    #     <me:alg>RSA-SHA256</me:alg>
    #     <me:sig key_id="{sender}">{signature}</me:sig>
    #   </me:env>
    #
    # When parsing the XML of an incoming Magic Envelope {MagicEnvelope.unenvelop}
    # is used.
    #
    # @see https://cdn.rawgit.com/salmon-protocol/salmon-protocol/master/draft-panzer-magicsig-01.html
    class MagicEnvelope
      include Logging

      # encoding used for the payload data
      ENCODING = "base64url".freeze

      # algorithm used for signing the payload data
      ALGORITHM = "RSA-SHA256".freeze

      # mime type describing the payload data
      DATA_TYPE = "application/xml".freeze

      # digest instance used for signing
      DIGEST = OpenSSL::Digest::SHA256.new

      # XML namespace url
      XMLNS = "http://salmon-protocol.org/ns/magic-env".freeze

      # the payload entity of the magic envelope
      # @return [Entity] payload entity
      attr_reader :payload

      # the sender of the magic envelope
      # @return [String] diaspora-ID of the sender
      attr_reader :sender

      # Creates a new instance of MagicEnvelope.
      #
      # @param [Entity] payload Entity instance
      # @param [String] sender diaspora-ID of the sender
      # @raise [ArgumentError] if either argument is not of the right type
      def initialize(payload, sender=nil)
        raise ArgumentError unless payload.is_a?(Entity)

        @payload = payload
        @sender = sender
      end

      # Builds the XML structure for the magic envelope, inserts the {ENCODING}
      # encoded data and signs the envelope using {DIGEST}.
      #
      # @param [OpenSSL::PKey::RSA] privkey private key used for signing
      # @return [Nokogiri::XML::Element] XML root node
      def envelop(privkey)
        raise ArgumentError unless privkey.instance_of?(OpenSSL::PKey::RSA)

        build_xml {|xml|
          xml["me"].env("xmlns:me" => XMLNS) {
            xml["me"].data(Base64.urlsafe_encode64(payload_data), type: DATA_TYPE)
            xml["me"].encoding(ENCODING)
            xml["me"].alg(ALGORITHM)
            xml["me"].sig(Base64.urlsafe_encode64(sign(privkey)), key_id)
          }
        }
      end

      # Encrypts the payload with a new, random AES cipher and returns the cipher
      # params that were used.
      #
      # This must happen after the MagicEnvelope instance was created and before
      # {MagicEnvelope#envelop} is called.
      #
      # @see AES#generate_key_and_iv
      # @see AES#encrypt
      #
      # @return [Hash] AES key and iv. E.g.: { key: "...", iv: "..." }
      def encrypt!
        AES.generate_key_and_iv.tap do |key|
          @payload_data = AES.encrypt(payload_data, key[:key], key[:iv])
        end
      end

      # Extracts the entity encoded in the magic envelope data, if the signature
      # is valid. If +cipher_params+ is given, also attempts to decrypt the payload first.
      #
      # Does some sanity checking to avoid bad surprises...
      #
      # @see XmlPayload#unpack
      # @see AES#decrypt
      #
      # @param [Nokogiri::XML::Element] magic_env XML root node of a magic envelope
      # @param [String] sender diaspora-ID of the sender or nil
      # @param [Hash] cipher_params hash containing the key and iv for
      #   AES-decrypting previously encrypted data. E.g.: { iv: "...", key: "..." }
      #
      # @return [Entity] reconstructed entity instance
      #
      # @raise [ArgumentError] if any of the arguments is of invalid type
      # @raise [InvalidEnvelope] if the envelope XML structure is malformed
      # @raise [InvalidSignature] if the signature can't be verified
      # @raise [InvalidEncoding] if the data is wrongly encoded
      # @raise [InvalidAlgorithm] if the algorithm used doesn't match
      def self.unenvelop(magic_env, sender=nil, cipher_params=nil)
        raise ArgumentError unless magic_env.instance_of?(Nokogiri::XML::Element)

        raise InvalidEnvelope unless envelope_valid?(magic_env)

        sender ||= sender(magic_env)
        raise InvalidSignature unless signature_valid?(magic_env, sender)

        raise InvalidEncoding unless encoding_valid?(magic_env)
        raise InvalidAlgorithm unless algorithm_valid?(magic_env)

        data = read_and_decrypt_data(magic_env, cipher_params)

        logger.debug "unenvelop message from #{sender}:\n#{data}"

        new(XmlPayload.unpack(Nokogiri::XML::Document.parse(data).root), sender)
      end

      private

      # the payload data as string
      # @return [String] payload data
      def payload_data
        @payload_data ||= XmlPayload.pack(@payload).to_xml.strip.tap do |data|
          logger.debug "send payload:\n#{data}"
        end
      end

      def key_id
        sender ? {key_id: Base64.urlsafe_encode64(sender)} : {}
      end

      # Builds the xml root node of the magic envelope.
      #
      # @yield [xml] Invokes the block with the
      #   {http://www.rubydoc.info/gems/nokogiri/Nokogiri/XML/Builder Nokogiri::XML::Builder}
      # @return [Nokogiri::XML::Element] XML root node
      def build_xml
        Nokogiri::XML::Builder.new(encoding: "UTF-8") {|xml|
          yield xml
        }.doc.root
      end

      # create the signature for all fields according to specification
      #
      # @param [OpenSSL::PKey::RSA] privkey private key used for signing
      # @return [String] the signature
      def sign(privkey)
        subject = MagicEnvelope.send(:sig_subject, [payload_data, DATA_TYPE, ENCODING, ALGORITHM])
        privkey.sign(DIGEST, subject)
      end

      # @param [Nokogiri::XML::Element] env magic envelope XML
      private_class_method def self.envelope_valid?(env)
        (env.instance_of?(Nokogiri::XML::Element) &&
          env.name == "env" &&
          !env.at_xpath("me:data").content.empty? &&
          !env.at_xpath("me:sig").content.empty?)
      end

      # @param [Nokogiri::XML::Element] env magic envelope XML
      # @param [String] sender diaspora-ID of the sender or nil
      # @return [Boolean]
      private_class_method def self.signature_valid?(env, sender)
        subject = sig_subject([Base64.urlsafe_decode64(env.at_xpath("me:data").content),
                               env.at_xpath("me:data")["type"],
                               env.at_xpath("me:encoding").content,
                               env.at_xpath("me:alg").content])

        sender_key = DiasporaFederation.callbacks.trigger(:fetch_public_key, sender)
        raise SenderKeyNotFound unless sender_key

        sig = Base64.urlsafe_decode64(env.at_xpath("me:sig").content)
        sender_key.verify(DIGEST, sig, subject)
      end

      # reads the +key_id+ from the magic envelope
      # @param [Nokogiri::XML::Element] env magic envelope XML
      # @return [String] diaspora-ID of the sender
      private_class_method def self.sender(env)
        key_id = env.at_xpath("me:sig")["key_id"]
        raise InvalidEnvelope, "no key_id" unless key_id # TODO: move to `envelope_valid?`
        Base64.urlsafe_decode64(key_id)
      end

      # constructs the signature subject.
      # the given array should consist of the data, data_type (mimetype), encoding
      # and the algorithm
      # @param [Array<String>] data_arr
      # @return [String] signature subject
      private_class_method def self.sig_subject(data_arr)
        data_arr.map {|i| Base64.urlsafe_encode64(i) }.join(".")
      end

      # @param [Nokogiri::XML::Element] magic_env magic envelope XML
      # @return [Boolean]
      private_class_method def self.encoding_valid?(magic_env)
        magic_env.at_xpath("me:encoding").content == ENCODING
      end

      # @param [Nokogiri::XML::Element] magic_env magic envelope XML
      # @return [Boolean]
      private_class_method def self.algorithm_valid?(magic_env)
        magic_env.at_xpath("me:alg").content == ALGORITHM
      end

      # @param [Nokogiri::XML::Element] magic_env magic envelope XML
      # @param [Hash] cipher_params hash containing the key and iv
      # @return [String] data
      private_class_method def self.read_and_decrypt_data(magic_env, cipher_params)
        data = Base64.urlsafe_decode64(magic_env.at_xpath("me:data").content)
        data = AES.decrypt(data, cipher_params[:key], cipher_params[:iv]) unless cipher_params.nil?
        data
      end
    end
  end
end
