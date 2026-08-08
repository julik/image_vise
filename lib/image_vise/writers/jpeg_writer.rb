class ImageVise::JPGWriter < Struct.new(:quality, keyword_init: true)
  JPG_EXT = 'jpg'

  def write_image!(magick_image, _, render_to_path)
    q = self.quality
    magick_image.format = JPG_EXT
    # The block receives the Magick::Image::Info to configure. RMagick used to
    # instance_eval a zero-arity block against it, but that was removed in RMagick 5 -
    # a zero-arity block now silently runs in the caller's scope and the setting is lost.
    magick_image.write(render_to_path) { |info| info.quality = q }
  end
end
