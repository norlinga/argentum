require 'test_helper'

module Argentum
  class ConfigTest < TestCase
    include Rack::Test::Methods

    def app = App

    def test_title_falls_back_when_blank
      with_env('ARGENTUM_TITLE' => '   ') { assert_equal 'argentum', Config.title }
      with_env('ARGENTUM_TITLE' => ' Home Movies ') { assert_equal 'Home Movies', Config.title }
    end

    def test_theme_only_accepts_known_values
      with_env('ARGENTUM_THEME' => 'light') { assert_equal 'light', Config.theme }
      with_env('ARGENTUM_THEME' => 'neon') { assert_equal 'dark', Config.theme }
    end

    def test_logo_url_variants
      logo = File.join(TEST_ROOT, 'logo.png')
      File.write(logo, 'png')
      { nil => '/icon.svg', '' => '/icon.svg', 'none' => nil,
        'https://example.com/l.png' => 'https://example.com/l.png',
        logo => '/brand/logo', '/no/such/file.png' => '/icon.svg',
        'javascript:alert(1)' => '/icon.svg' }.each do |setting, want|
        with_env('ARGENTUM_LOGO' => setting) do
          want.nil? ? assert_nil(Config.logo_url) : assert_equal(want, Config.logo_url, setting.inspect)
        end
      end
    end

    def test_brand_logo_route
      logo = File.join(TEST_ROOT, 'logo.png')
      File.write(logo, 'png')
      with_env('ARGENTUM_LOGO' => logo) do
        get '/brand/logo'
        assert_equal ['png', 'image/png'], [last_response.body, last_response.media_type]
      end
      with_env('ARGENTUM_LOGO' => nil) do
        get '/brand/logo'
        assert_equal 404, last_response.status
      end
    end

    def test_layout_reflects_branding
      with_env('ARGENTUM_TITLE' => 'Our <Films>', 'ARGENTUM_TAGLINE' => '', 'ARGENTUM_THEME' => 'system') do
        get '/'
        body = last_response.body
        assert_includes body, '<title>Our &lt;Films&gt;</title>'
        refute_includes body, 'brand-tagline'
        refute_includes body, '<html lang="en" data-theme'
      end
    end

    def test_scan_interval
      assert_equal 60, Config.scan_interval
      with_env('ARGENTUM_SCAN_INTERVAL' => '0') { assert_equal 0, Config.scan_interval }
      with_env('ARGENTUM_SCAN_INTERVAL' => ' 010 ') { assert_equal 10, Config.scan_interval, 'base 10, not octal' }
      %w[soon -5 1.5].each do |value|
        with_env('ARGENTUM_SCAN_INTERVAL' => value) do
          err = assert_raises(ArgumentError) { Config.scan_interval }
          assert_includes err.message, 'ARGENTUM_SCAN_INTERVAL must be an integer >= 0'
        end
      end
    end

    def test_ffmpeg_threads_must_be_positive
      assert_equal 1, Config.ffmpeg_threads
      with_env('ARGENTUM_FFMPEG_THREADS' => '2') { assert_equal 2, Config.ffmpeg_threads }
      %w[0 -1 auto].each do |value|
        with_env('ARGENTUM_FFMPEG_THREADS' => value) { assert_raises(ArgumentError) { Config.ffmpeg_threads } }
      end
    end

    def test_settle_seconds
      with_env('ARGENTUM_SETTLE_SECONDS' => nil) { assert_equal 20, Config.settle_seconds }
      with_env('ARGENTUM_SETTLE_SECONDS' => 'x') { assert_raises(ArgumentError) { Config.settle_seconds } }
      with_env('ARGENTUM_SETTLE_SECONDS' => '30') do
        refute Config.settled?(Struct.new(:mtime).new(Time.now - 10))
        assert Config.settled?(Struct.new(:mtime).new(Time.now - 31))
      end
    end

    def test_validate_names_the_bad_variable
      Config.validate!
      with_env('ARGENTUM_FFMPEG_THREADS' => 'auto') do
        err = assert_raises(ArgumentError) { Config.validate! }
        assert_equal 'ARGENTUM_FFMPEG_THREADS must be an integer >= 1 (got "auto")', err.message
      end
    end

    # Otherwise any web page a family member opens could e.g. POST /duplicates/remove to the LAN address.
    def test_cross_origin_writes_are_rejected
      v = create_video
      host = { 'HTTP_HOST' => 'nas.local:4567' }
      post "/videos/#{v.id}/favorite", {}, host.merge('HTTP_ORIGIN' => 'http://evil.example')
      assert_equal 403, last_response.status
      put "/videos/#{v.id}", { title: 'pwned' }, host.merge('HTTP_ORIGIN' => 'http://nas.local:9999')
      assert_equal 403, last_response.status
      v.reload
      refute v.favorite
      refute_equal 'pwned', v.title
    end

    def test_same_origin_and_originless_writes_are_allowed
      v = create_video
      post "/videos/#{v.id}/favorite", {}, 'HTTP_HOST' => 'nas.local:4567', 'HTTP_ORIGIN' => 'http://nas.local:4567'
      assert last_response.ok?
      post "/videos/#{v.id}/favorite" # no Origin header (curl, old clients)
      assert last_response.ok?
      get "/videos/#{v.id}", {}, 'HTTP_ORIGIN' => 'http://evil.example' # reads are never blocked
      assert last_response.ok?
    end
  end
end
