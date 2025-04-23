require 'spec_helper'

describe ImageVise::ThumbOp do
  it 'refuses invalid arguments' do
    expect { described_class.new }.to raise_error(ArgumentError)
    expect { described_class.new(width: nil, height: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(width: -5, height: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(width: 5, height: 0) }.to raise_error(ArgumentError)
  end
  
  it 'applies the crop with different gravities' do
    %w( s sw se n ne nw c).each do |gravity|
      image = Magick::Image.read(test_image_path)[0]
      crop = described_class.new(width: 32, height: 32)

      crop.apply!(image)

      expect(image.columns).to be <= 32
      expect(image.rows).to be <= 32
      examine_image(image, "thumb")
    end
  end
end
