require 'openssl'
require 'jwt'
require 'json'
require 'digest'

class ImageVise::ImageRequest < Struct.new(:src, :pipeline, keyword_init: true)
  class Src < Struct.new(:fetcher, :params)
    def params
      super.map do |(k, v)|
        [k.to_sym, v]
      end.to_h
    end
  end

  class InvalidRequest < ArgumentError; end
  class SignatureError < InvalidRequest; end
  class URLError < InvalidRequest; end
  class MissingParameter < InvalidRequest; end
  
  # Initializes a new ImageRequest from a JWT token
  def self.from_token(jwt_token:, secrets:)
    # Try each secret until one works (key rotation support)
    decoded_claims = nil
    last_error = nil
    
    Array(secrets).each do |secret|
      begin
        claims = JWT.decode(jwt_token, secret, true, { algorithm: 'HS256' })
        decoded_claims = claims.first # JWT.decode returns [claims, header]
        break # Successfully decoded, exit the loop
      rescue JWT::DecodeError, JWT::VerificationError => e
        last_error = e
        next # Try next secret
      end
    end
    
    # If we couldn't decode with any secret, raise the last error
    unless decoded_claims
      raise InvalidRequest.new("Invalid JWT token: #{last_error.message}")
    end

    Measurometer.increment_counter('image_vise.params.valid_signatures', 1)

    # Pick up the URL and validate it
    source_definition = decoded_claims.fetch("ivise.src")
    src = Src.new(source_definition.fetch("f"), source_definition.fetch("p"))

    pipeline_definition = decoded_claims.fetch("ivise.pipe")
    new(src: src, pipeline: ImageVise::Pipeline.from_array_of_operator_params(pipeline_definition))
  rescue KeyError => e
    raise InvalidRequest.new("Missing required claim: #{e.message}")
  end

  def to_path_params(signing_secret)
    claims = {
      "ivise.src" => {"f" => src.fetcher, "p" => src.params},
      "ivise.pipe" => pipeline.to_params
    }
    JWT.encode(claims, signing_secret, 'HS256')
  end

  def to_h
    {pipeline: pipeline.to_params, src_url: src_url_string}
  end
  
  def src_url_string
    case src.fetcher
    when 'http'
      src.params[:url] || src.params['url']
    when 'file'
      "file://#{src.params[:path] || src.params['path']}"
    else
      src.fetcher.to_s
    end
  end
  
  def cache_etag
    Digest::SHA1.hexdigest(JSON.dump(to_h))
  end
end
