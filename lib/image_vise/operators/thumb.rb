# Quickly generates a thumbnail using the RMagick #thumbnail! method.
# This is faster than using some more sophisticated resize methods.
#
# The corresponding Pipeline method is `thumb`.
class ImageVise::ThumbOp < Struct.new(:width, :height, keyword_init: true)
  def initialize(*)
    super
    raise ArgumentError, "the :width and :height parameters must be set" unless (self.width && self.height)
    self.width = self.width.to_i
    self.height = self.height.to_i
    raise ArgumentError, ":width must be positive" unless self.width.positive?
    raise ArgumentError, ":height must be positive" unless self.height.positive?
  end

  def apply!(image)
    image.thumbnail!(width, height)
  end

  ImageVise.add_operator 'thumb', self
end
