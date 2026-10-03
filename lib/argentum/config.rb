require 'fileutils'

module Argentum
  module Config
    module_function

    def media_dir     = File.expand_path(ENV.fetch('ARGENTUM_MEDIA_DIR', './media'))
    def data_dir      = File.expand_path(ENV.fetch('ARGENTUM_DATA_DIR', './data'))
    def scan_interval = integer('ARGENTUM_SCAN_INTERVAL', 60, min: 0)
    def ffmpeg_threads = integer('ARGENTUM_FFMPEG_THREADS', 1, min: 1)
    # A file modified more recently than this is assumed to still be arriving
    # (e.g. sent over LocalSend) and is left alone until it has been quiet this long.
    def settle_seconds = integer('ARGENTUM_SETTLE_SECONDS', 20, min: 0)
    def extensions    = %w[.mp4 .m4v .mov .mkv .webm .avi]

    def settled?(stat) = stat.mtime <= Time.now - settle_seconds

    # Fail at boot, with the variable's name, rather than on first use deep in a
    # background thread (a bad thread count would otherwise fail every ingest).
    def validate!
      scan_interval
      ffmpeg_threads
      settle_seconds
    end

    def integer(name, default, min:)
      raw = ENV.fetch(name, default.to_s)
      n = Integer(raw.strip, 10, exception: false) # base 10: "010" is ten, not octal eight
      raise ArgumentError, "#{name} must be an integer >= #{min} (got #{raw.inspect})" unless n && n >= min

      n
    end

    # Resolve symlinks before serving or processing: a link in the media folder
    # must not expose unrelated files from the container's filesystem.
    def media_path(rel)
      root = File.realpath(media_dir)
      path = File.realpath(File.join(root, rel))
      path if path.start_with?(root + File::SEPARATOR)
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
      nil
    end

    # ---- branding ----
    def title   = ENV.fetch('ARGENTUM_TITLE', '').strip.then { |t| t.empty? ? 'argentum' : t }
    def tagline = ENV.fetch('ARGENTUM_TAGLINE', 'family video library').strip

    # dark | light | system — the initial theme; viewers can toggle and their choice is remembered.
    def theme = ENV.fetch('ARGENTUM_THEME', 'dark').then { |t| %w[dark light system].include?(t) ? t : 'dark' }

    # ARGENTUM_LOGO: an http(s) URL, a path to an image file, or "none". Blank = built-in icon.
    def logo_setting = ENV.fetch('ARGENTUM_LOGO', '').strip
    def logo_file
      v = logo_setting
      return nil if v.empty? || v == 'none' || v.match?(%r{\Ahttps?://})

      path = File.expand_path(v)
      File.file?(path) ? path : nil
    end

    def logo_url
      v = logo_setting
      return nil if v == 'none'
      return v if v.match?(%r{\Ahttps?://})

      logo_file ? '/brand/logo' : '/icon.svg'
    end

    def thumbs_dir   = File.join(data_dir, 'thumbs')
    def stills_dir   = File.join(data_dir, 'stills')
    def previews_dir = File.join(data_dir, 'previews')
    def hls_dir      = File.join(data_dir, 'hls')

    def ensure_dirs!
      [data_dir, thumbs_dir, stills_dir, previews_dir, hls_dir].each { |d| FileUtils.mkdir_p(d) }
    end
  end
end
