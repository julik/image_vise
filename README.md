# A thumbnailing server

`ImageVise` is an image-from-url-as-a-service server for use either standalone or within a larger Rails/Rack
framework. The main uses are:

* Image resizing on request
* Applying image filters

It is implemented as a Rack application that responds to any URL and accepts a JWT (JSON Web Token) in the path
component. The JWT token contains the source image information and processing pipeline operations.

A request to `ImageVise` looks like this:

    /eyJhbGciOiJIUzI1NiJ9.eyJpdmlzZS5zcmMiOnsiZiI6Imh0dHAiLCJwIjp7InVybCI6Imh0dHA6Ly9leGFtcGxlLmNvbS9pbWFnZS5qcGcifX0sIml2aXNlLnBpcGUiOltbImNyb3AiLHsid2lkdGgiOjEwMCwiSGVpZ2h0IjoxMDB9XV19.xyz...

The JWT token contains the following claims:
- `ivise.src` - Source image information with `f` (fetcher type) and `p` (parameters)
- `ivise.pipe` - Array of processing pipeline operations

## JWT-Based Request System

ImageVise uses JWT (JSON Web Token) based requests for secure and flexible image processing. JWT requests provide a modern, secure way to handle image processing requests with built-in validation and expiration support.

### JWT Request Format

JWT requests use a single path component containing the JWT token:

    /eyJhbGciOiJIUzI1NiJ9.eyJpdmlzZS5zcmMiOnsiZiI6Imh0dHAiLCJwIjp7InVybCI6Imh0dHA6Ly9leGFtcGxlLmNvbS9pbWFnZS5qcGcifX0sIml2aXNlLnBpcGUiOltbImNyb3AiLHsid2lkdGgiOjEwMCwiSGVpZ2h0IjoxMDB9XV19.xyz...

The JWT token contains the following claims:
- `ivise.src` - Source image information with `f` (fetcher type) and `p` (parameters)
- `ivise.pipe` - Array of processing pipeline operations

## ImageMagick version

The modernized image_vise works with rmagick 6, which supports modern ImageMagick versions (including version 7). The workarounds are no longer required - install modern ImageMagick using your preferred package management tool. For example, with homebrew:

```
$ brew install imagemagick
bundle install
```

## Using ImageVise within a Rails application

Mount ImageVise in your `routes.rb`:

```ruby
mount '/images' => ImageVise
```

and add an initializer (like `config/initializers/image_vise_config.rb`) to set up the permitted hosts

```ruby
ImageVise.add_allowed_host! your_application_hostname
ImageVise.add_secret_key! ENV.fetch('IMAGE_VISE_SECRET')
```

You might want to define a helper method for generating signed URLs as well, which will look something like this:

```ruby
def thumb_url(source_image_url)
  path = ImageVise.image_path(fetcher: 'http', fetcher_params: {url: source_image_url}, secret: ENV.fetch('IMAGE_VISE_SECRET')) do |pipeline|
     # For example, you can also yield `pipeline` to the caller
    pipeline.fit_crop width: 128, height: 128, gravity: 'c'
  end
  '/images' + path
end
```

### JWT-Based URL Generation

For JWT-based requests, you can use the new `ImageVise::ImageRequest` class directly:

```ruby
def thumb_url_jwt(source_image_url)
  # Create source definition
  src = ImageVise::ImageRequest::Src.new('http', { url: source_image_url })
  
  # Create pipeline
  pipeline = ImageVise::Pipeline.new
  pipeline.fit_crop width: 128, height: 128, gravity: 'c'
  
  # Create request and generate JWT token
  request = ImageVise::ImageRequest.new(src: src, pipeline: pipeline)
  jwt_token = request.to_path_params(ENV.fetch('IMAGE_VISE_SECRET'))
  
  '/images/' + jwt_token
end
```

To preserve your sanity, make the route to the ImageVise engine terminal and do _not_ perform rewrites
on it in your webserver configuration - for instance, JWT tokens can contain slashes.

## Using ImageVise within a Rack application

Mount ImageVise under a script name in your `config.ru`:

```ruby
map '/images' do
  run ImageVise
end
```

and add the initialization code either to `config.ru` proper or to some file in your application:

    ImageVise.add_allowed_host! your_application_hostname
    ImageVise.add_secret_key! ENV.fetch('IMAGE_VISE_SECRET')

You might want to define a helper method for generating signed URLs as well, which will look something like this:

```ruby
def thumb_url(source_image_url)
  path_param = ImageVise.image_path(fetcher: 'http', fetcher_params: {url: source_image_url}, secret: ENV.fetch('IMAGE_VISE_SECRET')) do |pipe|
    pipe.fit_crop width: 256, height: 256, gravity: 'c'
    pipe.sharpen sigma: 0.5, radius: 2
    pipe.ellipse_stencil
  end
  # Output a URL to the app
  '/images' + path
end
```

## Processing files on the local filesystem instead of remote ones

The `file` fetcher takes a plain filesystem path as its `path` parameter, see "JWT File Processing" below.

If your image locations travel through your application as `file://` URLs, convert between the two
using `encode_file_uri_path` (which percent-encodes every path component, keeping the separators intact)
and `uri_to_path`:

    src_url = 'file://' + ImageVise::FetcherFile.encode_file_uri_path(File.expand_path(my_pic))
    path = ImageVise::FetcherFile.uri_to_path(src_url)

Note that you need to permit certain glob patterns as sources before this will work, see below.

### JWT File Processing

For JWT-based file processing:

```ruby
# Create source definition for local file
src = ImageVise::ImageRequest::Src.new('file', { path: '/path/to/local/image.jpg' })

# Create pipeline
pipeline = ImageVise::Pipeline.new
pipeline.fit_crop width: 300, height: 300

# Create request and generate JWT token
request = ImageVise::ImageRequest.new(src: src, pipeline: pipeline)
jwt_token = request.to_path_params(ENV.fetch('IMAGE_VISE_SECRET'))
```

## Operators and pipelining

ImageVise processes an image using _operators_. Each operator is just like an adjustment layer in Photoshop, except
that it can also resize the canvas. If you are familiar with node-based compositing systems like Shake, Nuke or Fusion
the pipeline is a node DAG with only one connection arrow going all the way. The operations are always applied in a
destructive way, so that the additional intermediate versions don't have to be deallocated manually after processing.

Each Operator is described in the pipeline using a tuple (Array) of roughly this structure:

    [<operator_name>, {"<operator_param1>": <operator_param1_value>}]

You can have an unlimited number of such Operators per thumbnail, and they all get encoded in the URL (well,
technically, you _are_ limited - by the URL length supported by your web server).

For example, you can use the pipeline to apply a sharpening operator _after_ resising an image (for the lack
of decent image filtering choices in ImageMagick proper).

Here is an example pipeline, JSON-encoded (this is what is passed in the URL):

```json
[
  ["auto_orient", {}],
  ["geom", {"geometry_string": "512x512"}],
  ["fit_crop", {"width": 32, "height": 32, "gravity": "se"}],
  ["sharpen", {"radius": 0.75, "sigma": 0.5}],
  ["ellipse_stencil", {}]
]
```

The same pipeline can be created using the `Pipeline` DSL:

```ruby
pipe = Pipeline.new.
  auto_orient.
  geom(geometry_string: '512x512').
  fit_crop(width: 32, height: 32, gravity: 'se').
  sharpen(radius: 0.75, sigma: 0.5).
  ellipse_stencil
```
and can then be applied to a `Magick::Image` object:

```ruby
image = Magick::Image.read(my_image_path)[0]
pipe.apply!(image)
```

## Caching

The app is _designed_ to be run behind a frontline HTTP cache. The easiest is to use `Rack::Cache`, but this might
be instance-local depending on the storage backend used. A much better idea is to run ImageVise behind a long-caching
CDN.

## JWT Secret Keys

JWT requests are signed using HS256 algorithm with your configured secret keys:

```ruby
# Add secret keys for signing JWT tokens
ImageVise.add_secret_key!('your_secret_key_here')
```

A single `ImageVise` server can maintain multiple signature keys, so that you will be able to generate thumbnails from
multiple applications all using different keys for their signatures. JWT requests will be validated against the key used for signing.

### Key Rotation Support

ImageVise supports key rotation for JWT verification. When verifying JWT tokens, the system will try each key until verification succeeds:

```ruby
# Add multiple secret keys for key rotation
ImageVise.add_secret_key!('current_secret_key')
ImageVise.add_secret_key!('previous_secret_key')  # For backward compatibility
ImageVise.add_secret_key!('legacy_secret_key')    # For older tokens

# When generating new tokens, use the current secret
# When verifying tokens, all keys are tried until one succeeds
```

**Important Notes:**
- **Signing**: Always uses the secret provided to `image_path` (single secret)
- **Verification**: Tries **all** secret keys until one succeeds
- **Key Order**: Add new keys first, then old keys for proper rotation
- **Backward Compatibility**: Old tokens signed with previous keys will continue to work

## Hostname and filesystem validation

By default, `ImageVise` will refuse to process images from URLs on "unknown" hosts. To mark a host as "known"
tell `ImageVise` to

```ruby
ImageVise.add_allowed_host!('my-image-store.ourcompany.co.uk')
```

If you want to permit images from the local server filesystem to be accessed, add the glob pattern
to the set of allowed filesystem patterns:

```ruby
ImageVise.allow_filesystem_source!(Rails.root + '/public/*.jpg')
```

Note that these are _glob_ patterns. The image path will be checked against them using `File.fnmatch`.

## Handling errors within the rendering Rack app

By default, the Rack app within ImageVise swallows all exceptions and returns the error message
within a machine-readable JSON payload. If that doesn't work for you, or you want to add error
handling using some error tracking provider, either subclass `ImageVise::RenderEngine` or prepend
a module into it that will intercept the errors. See error handling in `examples/` for more.

## State

Except for the HTTP cache no state is stored (`ImageVise` does not care whether you store
your images using Dragonfly, CarrierWave or some custom handling code). All the app needs is the full URL.

## Running the tests, versioning, contributing

By default, `bundle exec rake` will run RSpec and will also open the generated images using the `$ open` command available
on your CLI. If you want to skip viewing those images, set the `SKIP_INTERACTIVE` environment variable to any value.

The gem version is specified in `image_vise.rb`. When contributing, please follow:

* Check out the latest master to make sure the feature hasn't been implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

### Copyright

Copyright (c) 2016 WeTransfer. See LICENSE.txt for further details.
The licensing terms also apply to the `waterside_magic_hour.jpg` test image.
The `worker_in_tube.jpg` is used with permission from Arcadis Nederland B.V.

The sRGB color profiles are [downloaded from the ICC](http://www.color.org/srgbprofiles.xalter) and it's
use is governed by the terms present in the LICENSE.txt
