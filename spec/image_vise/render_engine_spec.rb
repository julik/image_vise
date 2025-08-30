require_relative '../spec_helper'
require 'rack/test'

describe ImageVise::RenderEngine do
  include Rack::Test::Methods

  let(:app) { ImageVise::RenderEngine.new }
  before :each do
    ImageVise.reset_cache_lifetime_seconds!
  end

  # Helper method to create ImageRequest with new structure
  def create_image_request(url, pipeline)
    uri = URI(url)
    fetcher = case uri.scheme
              when 'http', 'https'
                'http'
              when 'file'
                'file'
              else
                raise ArgumentError, "unsupported URL scheme: #{uri.scheme}"
              end
    
    params_hash = case fetcher
                  when 'http'
                    { url: url }
                  when 'file'
                    { path: uri.path }
                  else
                    {}
                  end
    
    src = ImageVise::ImageRequest::Src.new(fetcher, params_hash)
    ImageVise::ImageRequest.new(src: src, pipeline: pipeline)
  end

  context 'when the subclass is configured to raise exceptions' do
    after :each do
      ImageVise.reset_allowed_hosts!
      ImageVise.reset_secret_keys!
    end

    it 'raises an exception instead of returning an error response' do
      class << app
        def raise_exceptions?
          true
        end
      end

      p = ImageVise::Pipeline.new.crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request('http://unknown.com/image.jpg', p)
      expect(app).to receive(:handle_generic_error).and_call_original
      expect {
        get image_request.to_path_params('l33tness')
      }.to raise_error(/No keys set/)
    end
  end

  context 'when requesting an image' do
    before :each do
      parsed_url = URI.parse(public_url)
      ImageVise.add_allowed_host!(parsed_url.host)
    end

    after :each do
      ImageVise.reset_allowed_hosts!
      ImageVise.reset_secret_keys!
    end

    it 'halts with 400 when the requested image cannot be opened by ImageMagick' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')
      uri.path = '/___nonexistent_image.jpg'

      p = ImageVise::Pipeline.new.crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      bad_data = StringIO.new('totally not an image')
      expect(ImageVise::FetcherHTTP).to receive(:fetch_to_tempfile).and_return(bad_data)
      expect(app).to receive(:handle_request_error).and_call_original

      get image_request.to_path_params('l33tness')

      expect(last_response.status).to eq(400)
      expect(last_response['Cache-Control']).to match(/public/)
      expect(last_response.body).to include('unknown')
    end

    it 'halts with 400 when a file:// URL is given and filesystem access is not enabled' do
      uri = 'file://' + test_image_path
      ImageVise.deny_filesystem_sources!
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.fit_crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(403)
      expect(last_response.body).to include('filesystem access is disabled')
    end

    it 'responds with 403 when upstream returns it, and includes the URL in the error message' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')
      uri.path = '/forbidden'

      p = ImageVise::Pipeline.new.crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(403)
      expect(last_response.headers['Content-Type']).to eq('application/json')
      parsed = JSON.load(last_response.body)
      expect(parsed['errors'].to_s).to include("Unfortunate upstream response")
      expect(parsed['errors'].to_s).to include(uri.to_s)
    end

    it 'replays upstream error response codes that are selected to be replayed to the requester' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      [404, 403, 503, 504, 500].each do | error_code |
        allow_any_instance_of(Patron::Session).to receive(:get_file).and_return(double(status: error_code))

        p = ImageVise::Pipeline.new.crop(width: 10, height: 10, gravity: 'c')
        image_request = create_image_request(uri.to_s, p)

        get image_request.to_path_params('l33tness')

        expect(last_response.status).to eq(error_code)
        expect(last_response.headers).to have_key('Cache-Control')
        expect(last_response.headers['Cache-Control']).to match(/public/)

        expect(last_response.headers['Content-Type']).to eq('application/json')
        expect(last_response['X-Content-Type-Options']).to eq('nosniff')

        parsed = JSON.load(last_response.body)
        expect(parsed['errors'].to_s).to include("Unfortunate upstream response")
      end
    end

    it 'sets very far caching headers and an ETag, and returns a 304 if any ETag is set' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.fit_crop(width: 10, height: 35, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      req_path = image_request.to_path_params('l33tness')

      get req_path, {}
      expect(last_response).to be_ok
      expect(last_response['ETag']).not_to be_nil
      expect(last_response['Cache-Control']).to match(/public/)

      get req_path, {}, {'HTTP_IF_NONE_MATCH' => last_response['ETag']}
      expect(last_response.status).to eq(304)

      # Should consider _any_ ETag a request to rerender something
      # that already exists in an upstream cache
      get req_path, {}, {'HTTP_IF_NONE_MATCH' => SecureRandom.hex(4)}
      expect(last_response.status).to eq(304)
    end

    it 'allows for setting a custom cache lifetime' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      ImageVise.cache_lifetime_seconds = '900'
      p = ImageVise::Pipeline.new.fit_crop(width: 10, height: 35, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      req_path = image_request.to_path_params('l33tness')

      get req_path, {}
      expect(last_response).to be_ok
      expect(last_response['Cache-Control']).to match(/max-age=900/)
    end

    it 'uses the correct default cache lifetime if one is not specified' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.fit_crop(width: 10, height: 35, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      req_path = image_request.to_path_params('l33tness')

      get req_path, {}
      expect(last_response).to be_ok
      expect(last_response['Cache-Control']).to match(/max-age=2592000/)
    end

    it 'responds with an image that passes through all the processing steps' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.geom(geometry_string: '512x335').fit_crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(200)

      expect(last_response.headers['Content-Type']).to eq('image/jpeg')
      expect(last_response['X-Content-Type-Options']).to eq('nosniff')

      expect(last_response.headers).to have_key('Content-Length')
      parsed_image = Magick::Image.from_blob(last_response.body)[0]
      expect(parsed_image.columns).to eq(10)
    end

    it 'properly decodes the image request if its JWT representation contains masked slashes and plus characters' do
      ImageVise.add_secret_key!("this is fab")
      
      # Create a JWT request instead of HMAC
      src = ImageVise::ImageRequest::Src.new('shadericon', { url: 'shadericon://CPGP_Fireball?c=d9c8e3396f630c352341602c6c2abd2f035711c' })
      pipeline = ImageVise::Pipeline.new.sharpen(radius: 0.5, sigma: 0.5)
      req = ImageVise::ImageRequest.new(src: src, pipeline: pipeline)

      # We do a check based on the raised exception - the request will fail
      # at the fetcher lookup stage. That stage however takes place _after_ the
      # JWT has been validated, which means that the slash within the
      # JWT payload has been taken into account
      allow(app).to receive(:raise_exceptions?).and_return(true)
      expect {
        get req.to_path_params('this is fab')
      }.to raise_error(ImageVise::UnknownFetcher)
    end

    it 'calls all of the internal methods during execution' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.geom(geometry_string: '512x335').fit_crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      expect(app).to receive(:parse_env_into_request).and_call_original
      expect(app).to receive(:process_image_request).and_call_original
      expect(app).to receive(:image_rack_response).and_call_original
      expect(app).to receive(:permitted_format?).and_call_original

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(200)
    end

    it 'picks the image from the filesystem if that is permitted' do
      uri = 'file://' + test_image_path
      ImageVise.allow_filesystem_source!(File.dirname(test_image_path) + '/*.*')
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.fit_crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(200)
      expect(last_response.headers['Content-Type']).to eq('image/jpeg')
    end

    it 'URI-decodes the path in a file:// URL for a file with a Unicode path' do
      utf8_file_path = File.dirname(test_image_path) + '/картинка.jpg'
      FileUtils.cp_r(test_image_path, utf8_file_path)
      uri = 'file://' + ImageVise::FetcherFile.encode_file_uri_path(utf8_file_path)

      ImageVise.allow_filesystem_source!(File.dirname(test_image_path) + '/*.*')
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.fit_crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness')
      File.unlink(utf8_file_path)
      expect(last_response.status).to eq(200)
      expect(last_response.headers['Content-Type']).to eq('image/jpeg')
    end

    it 'allows requests with query parameters (JWT does not validate query params)' do
      uri = 'file://' + ImageVise::FetcherFile.encode_file_uri_path(test_image_path)

      p = ImageVise::Pipeline.new.fit_crop(width: 10, height: 10, gravity: 'c')
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness'), {'extra' => '123'}

      expect(last_response.status).to eq(200)
    end

    it 'returns the processed JPEG image as a PNG if it had to get an alpha channel during processing' do
      uri = URI.parse(public_url)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.geom(geometry_string: '220x220').ellipse_stencil
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(200)

      expect(last_response.headers['Content-Type']).to eq('image/png')
      expect(last_response.headers).to have_key('Content-Length')

      examine_image_from_string(last_response.body)
    end

    it 'permits a PSD file by default' do
      uri = URI.parse(public_url_psd)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.geom(geometry_string: '220x220').ellipse_stencil
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(200)
    end

    it 'destroys all the loaded PSD layers' do
      uri = URI.parse(public_url_psd_multilayer)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.geom(geometry_string: '220x220')
      image_request = create_image_request(uri.to_s, p)

      class << app
        def raise_exceptions?; true; end
      end

      # For each layer loaded into the ImageList
      expect(ImageVise).to receive(:destroy).and_call_original.exactly(5).times

      get image_request.to_path_params('l33tness')

      expect(last_response.status).to eq(200)
    end

    it 'outputs a converted TIFF file as a PNG' do
      uri = URI.parse(public_url_tif)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('l33tness')

      p = ImageVise::Pipeline.new.geom(geometry_string: '220x220')
      image_request = create_image_request(uri.to_s, p)

      class << app
        def source_file_type_permitted?(type); true; end
      end

      get image_request.to_path_params('l33tness')
      expect(last_response.status).to eq(200)
      expect(last_response.headers['Content-Type']).to eq('image/jpeg')
    end

    it 'processes a 1.5mb PSD with a forced conversion to JPEG' do
      uri = URI.parse(public_url_psd)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('1337ness')

      p = ImageVise::Pipeline.new.geom(geometry_string: 'x220').force_jpg_out(quality: 85)
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('1337ness')

      expect(last_response.headers['Content-Type']).to eq('image/jpeg')
      expect(last_response.status).to eq(200)

      examine_image_from_string(last_response.body)
    end

    it 'sets a customized Expires: cache lifetime set via the pipeline' do
      uri = URI.parse(public_url_psd)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('1337ness')

      p = ImageVise::Pipeline.new.geom(geometry_string: 'x220').expire_after(seconds: 20)
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('1337ness')

      expect(last_response.headers['Cache-Control']).to eq("public, no-transform, max-age=20")
    end

    it 'converts a PNG into a JPG applying a background fill' do
      uri = URI.parse(public_url_png_transparency)
      ImageVise.add_allowed_host!(uri.host)
      ImageVise.add_secret_key!('h00ray')

      p = ImageVise::Pipeline.new.background_fill(color: 'white').geom(geometry_string: 'x220').force_jpg_out(quality: 5)
      image_request = create_image_request(uri.to_s, p)

      get image_request.to_path_params('h00ray')

      expect(last_response.status).to eq(200)
      expect(last_response.headers['Content-Type']).to eq('image/jpeg')

      examine_image_from_string(last_response.body)
    end
  end
end
