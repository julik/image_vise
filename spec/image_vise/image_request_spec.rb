require 'spec_helper'

describe ImageVise::ImageRequest do
  let(:test_secret) { 'this_is_a_test_secret_key' }
  let(:secrets) { [test_secret] }
  
  describe '.from_token' do
    it 'creates an ImageRequest from a valid JWT token' do
      src = ImageVise::ImageRequest::Src.new('http', { url: 'http://bucket.s3.aws.com/image.jpg' })
      pipeline = ImageVise::Pipeline.new.thumb(width: 150, height: 150)
      request = ImageVise::ImageRequest.new(src: src, pipeline: pipeline)
      
      jwt_token = request.to_path_params('secret123')
      
      image_request = described_class.from_token(
        jwt_token: jwt_token,
        secrets: ['secret123']
      )
      
      expect(image_request).to be_kind_of(described_class)
      expect(image_request.src.fetcher).to eq('http')
      expect(image_request.src.params[:url]).to eq('http://bucket.s3.aws.com/image.jpg')
    end

    it 'supports key rotation by trying multiple secrets' do
      src = ImageVise::ImageRequest::Src.new('http', { url: 'http://example.com/image.jpg' })
      pipeline = ImageVise::Pipeline.new.thumb(width: 100, height: 100)
      request = ImageVise::ImageRequest.new(src: src, pipeline: pipeline)
      
      # Sign with the first secret
      jwt_token = request.to_path_params('current_secret')
      
      # Verify with multiple secrets (current first, then previous)
      image_request = described_class.from_token(
        jwt_token: jwt_token,
        secrets: ['current_secret', 'previous_secret', 'legacy_secret']
      )
      
      expect(image_request).to be_kind_of(described_class)
      expect(image_request.src.fetcher).to eq('http')
      expect(image_request.src.params[:url]).to eq('http://example.com/image.jpg')
    end

    it 'fails when no secret matches' do
      src = ImageVise::ImageRequest::Src.new('http', { url: 'http://example.com/image.jpg' })
      pipeline = ImageVise::Pipeline.new.thumb(width: 100, height: 100)
      request = ImageVise::ImageRequest.new(src: src, pipeline: pipeline)
      
      jwt_token = request.to_path_params('correct_secret')
      
      expect {
        described_class.from_token(
          jwt_token: jwt_token,
          secrets: ['wrong_secret1', 'wrong_secret2']
        )
      }.to raise_error(described_class::InvalidRequest, /Invalid JWT token/)
    end
  end

  describe '#to_path_params' do
    it 'generates a JWT token for path parameters' do
      source_definition = ImageVise::ImageRequest::Src.new('http', { url: 'http://example.com/image.jpg' })
      pipeline = double(to_params: [[:crop, { width: 100, height: 100 }]])
      
      image_request = described_class.new(src: source_definition, pipeline: pipeline)
      
      path_params = image_request.to_path_params(test_secret)
      
      # Verify it's a valid JWT token
      decoded = JWT.decode(path_params, test_secret, true, { algorithm: 'HS256' })
      expect(decoded.first).to include('ivise.src', 'ivise.pipe')
    end

    it 'includes source and pipeline information in the JWT' do
      source_definition = ImageVise::ImageRequest::Src.new('file', { path: '/tmp/image.jpg' })
      pipeline = double(to_params: [[:thumb, { width: 150, height: 150 }]])
      
      image_request = described_class.new(src: source_definition, pipeline: pipeline)
      
      path_params = image_request.to_path_params(test_secret)
      decoded = JWT.decode(path_params, test_secret, true, { algorithm: 'HS256' })
      claims = decoded.first
      
      expect(claims['ivise.src']).to eq({ "f" => 'file', "p" => { "path" => '/tmp/image.jpg' } })
      expect(claims['ivise.pipe']).to eq([["thumb", {"width" => 150, "height" => 150}]])
    end
  end

  describe '#to_h' do
    it 'returns a hash with pipeline params and source URL' do
      source_definition = ImageVise::ImageRequest::Src.new('http', { url: 'http://example.com/image.jpg' })
      pipeline = double(to_params: { crop: { width: 100, height: 100 } })
      
      image_request = described_class.new(src: source_definition, pipeline: pipeline)
      
      result = image_request.to_h
      
      expect(result).to include(:pipeline, :src_url)
      expect(result[:pipeline]).to eq({ crop: { width: 100, height: 100 } })
      expect(result[:src_url]).to be_a(String)
    end
  end

  describe '#cache_etag' do
    it 'generates a consistent hash based on the request parameters' do
      source_definition = ImageVise::ImageRequest::Src.new('http', { url: 'http://example.com/image.jpg' })
      pipeline = double(to_params: { crop: { width: 100, height: 100 } })
      
      image_request = described_class.new(src: source_definition, pipeline: pipeline)
      
      etag1 = image_request.cache_etag
      etag2 = image_request.cache_etag
      
      expect(etag1).to eq(etag2)
      expect(etag1).to be_a(String)
      expect(etag1.length).to eq(40) # SHA1 hex digest length
    end

    it 'generates different etags for different parameters' do
      source1 = ImageVise::ImageRequest::Src.new('http', { url: 'http://example.com/image1.jpg' })
      source2 = ImageVise::ImageRequest::Src.new('http', { url: 'http://example.com/image2.jpg' })
      pipeline = double(to_params: { crop: { width: 100, height: 100 } })
      
      image_request1 = described_class.new(src: source1, pipeline: pipeline)
      image_request2 = described_class.new(src: source2, pipeline: pipeline)
      
      expect(image_request1.cache_etag).not_to eq(image_request2.cache_etag)
    end
  end

  describe 'Src class' do
    it 'converts string keys to symbols in params' do
      src = ImageVise::ImageRequest::Src.new('http', { 'url' => 'http://example.com/image.jpg', 'width' => '100' })
      
      expect(src.params).to eq({ url: 'http://example.com/image.jpg', width: '100' })
      expect(src.params.keys).to all(be_a(Symbol))
    end

    it 'handles empty params' do
      src = ImageVise::ImageRequest::Src.new('http', {})
      
      expect(src.params).to eq({})
    end
  end
end
