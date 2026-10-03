ENV['APP_ENV'] = 'test'

require 'tmpdir'
require 'fileutils'

# Config is read from ENV on every call, but the DB connection is opened when
# argentum/db is required — so point both dirs at a throwaway tree first.
TEST_ROOT = Dir.mktmpdir('argentum-test')
ENV['ARGENTUM_DATA_DIR']  = File.join(TEST_ROOT, 'data')
ENV['ARGENTUM_MEDIA_DIR'] = File.join(TEST_ROOT, 'media')
%w[ARGENTUM_TITLE ARGENTUM_TAGLINE ARGENTUM_LOGO ARGENTUM_THEME ARGENTUM_SCAN_INTERVAL
   ARGENTUM_FFMPEG_THREADS].each { |k| ENV.delete(k) }
# Tests write a file and scan it at once; the settle tests opt back in with with_env.
ENV['ARGENTUM_SETTLE_SECONDS'] = '0'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'rack/test'
require 'argentum'

Minitest.after_run { FileUtils.rm_rf(TEST_ROOT) }

module Argentum
  # Real media files generated with ffmpeg's lavfi sources, built once per run.
  module Fixtures
    DIR = File.join(TEST_ROOT, 'fixtures')
    SPECS = {
      # Browser-friendly: ingest remuxes it with `-c copy`.
      'h264.mp4' => %w[-f lavfi -i testsrc=duration=4:size=320x240:rate=24
                       -f lavfi -i sine=frequency=440:duration=4
                       -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest],
      # The same footage in another codec/resolution: must be transcoded, and is a duplicate of h264.mp4.
      'reencode.mkv' => :reencode,
      'h264_mp3.mkv' => :mp3,
      # Different footage, same length: must NOT be grouped with the above.
      'other.mp4' => %w[-f lavfi -i mandelbrot=size=320x240:rate=24 -t 4
                        -c:v libx264 -pix_fmt yuv420p],
      'audio_only.m4a' => %w[-f lavfi -i sine=frequency=440:duration=2 -c:a aac]
    }.freeze

    module_function

    def available? = system('ffmpeg -version > /dev/null 2>&1') && system('ffprobe -version > /dev/null 2>&1')

    def path(name)
      FileUtils.mkdir_p(DIR)
      out = File.join(DIR, name)
      return out if File.file?(out)

      args = SPECS.fetch(name)
      args = ['-i', path('h264.mp4'), '-c:v', 'mpeg4', '-q:v', '4', '-s', '160x120', '-c:a', 'aac'] if args == :reencode
      args = ['-i', path('h264.mp4'), '-c:v', 'copy', '-c:a', 'libmp3lame'] if args == :mp3
      ok = system('ffmpeg', '-y', '-v', 'error', *args, out)
      raise "could not build fixture #{name}" unless ok

      out
    end
  end

  class TestCase < Minitest::Test
    @@seq = 0

    def setup
      super
      DB[:taggings].delete
      DB[:tags].delete
      DB[:dupe_dismissals].delete
      DB[:videos].delete
      FileUtils.rm_rf(Config.media_dir)
      FileUtils.mkdir_p(Config.media_dir)
      [Config.thumbs_dir, Config.stills_dir, Config.previews_dir, Config.hls_dir].each { |d| FileUtils.rm_rf(d) }
      Config.ensure_dirs!
      Worker::MUTEX.synchronize do
        Worker::QUEUE.clear
        Worker::QUEUED.clear
      end
    end

    def teardown
      Scanner.instance_variable_get(:@rescan)&.kill # a pending settle rescan must not outlive its test
      super
    end

    def create_video(tags: nil, **attrs)
      @@seq += 1
      v = Video.create({ rel_path: "clip#{@@seq}.mp4", title: "Clip #{@@seq}", status: 'ready',
                         created_at: Time.now, mtime: @@seq, size: 1000 }.merge(attrs))
      v.set_tags(tags) if tags
      v
    end

    # Put a file into the media dir (copying a fixture, or writing raw content).
    def add_media(rel, from: nil, content: 'x')
      dest = File.join(Config.media_dir, rel)
      FileUtils.mkdir_p(File.dirname(dest))
      from ? FileUtils.cp(from, dest) : File.write(dest, content)
      dest
    end

    def queued_ids = Worker::MUTEX.synchronize { Worker::QUEUED.to_a }

    def require_ffmpeg!
      skip 'ffmpeg/ffprobe not installed' unless Fixtures.available?
    end

    def with_env(vars)
      old = vars.keys.to_h { |k| [k, ENV[k]] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end
