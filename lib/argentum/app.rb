require 'sinatra/base'

module Argentum
  class App < Sinatra::Base
    PAGE_SIZE = 48

    set :root, File.expand_path('../..', __dir__)
    set :views, File.join(root, 'views')
    set :public_folder, File.join(root, 'public')
    set :erb, escape_html: true
    set :host_authorization, permitted_hosts: [] # LAN app: accept any Host header
    # Refuse cross-site writes (no sessions here, so Sinatra's default :drop_session reaction is a no-op).
    set :protection, except: :http_origin
    use Rack::Protection::HttpOrigin

    helpers do
      def partial(name, locals = {}) = erb(name, layout: false, locals: locals)
      def htmx? = request.env['HTTP_HX_REQUEST'] == 'true'

      def video!(id)
        halt(404, 'Not found') unless id.to_s.match?(/\A[1-9]\d*\z/)

        Video[id.to_i] || halt(404, 'Not found')
      end

      # Thumbnail URL with a cache-buster so a newly chosen still shows immediately.
      def thumb_url(v)
        path = Ingest.thumb_path(v.id)
        "/thumbs/#{v.id}.jpg?t=#{File.exist?(path) ? File.mtime(path).to_i : 0}"
      end

      def serve(path, type)
        halt 404 unless path && File.file?(path)
        send_file path, type: type
      end

      def tag_style(name) = "--h:#{Tag.hue(name)}"

      def nav_on?(key)
        case key
        when :home then request.path_info == '/'
        when :library then request.path_info == '/library' && params[:fav] != '1'
        when :fav then request.path_info == '/library' && params[:fav] == '1'
        end
      end

      def human_size(bytes)
        return '—' unless bytes
        units = %w[B KB MB GB TB]
        e = bytes.positive? ? [(Math.log(bytes) / Math.log(1024)).floor, units.size - 1].min : 0
        format(e.zero? ? '%d %s' : '%.1f %s', bytes.to_f / 1024**e, units[e])
      end

      def library_path(page: nil, **overrides)
        params_h = { q: @q, tag: @tag, fav: (@fav ? 1 : nil), sort: @sort }.merge(overrides)
        params_h[:page] = page if page
        qs = params_h.reject { |_, v| v.nil? || v.to_s.empty? }
        "/library?#{Rack::Utils.build_query(qs)}"
      end
    end

    # ---- pages ----------------------------------------------------------

    get '/' do
      @continue = Video.continue_watching
      @mix = Video.home_mix
      @recent = Video.ready.eager(:tags).order(Sequel.desc(:created_at)).limit(6).all
      erb :home
    end

    get '/library' do
      @q = params[:q].to_s.strip
      @tag = params[:tag].to_s.strip
      @fav = params[:fav] == '1'
      @sort = %w[newest popular least title random].include?(params[:sort]) ? params[:sort] : 'newest'
      @page = [params[:page].to_i, 1].max
      ds = Video.ready.eager(:tags).search(q: @q, tag: @tag, fav: @fav, sort: @sort)
      @videos = ds.limit(PAGE_SIZE + 1).offset((@page - 1) * PAGE_SIZE).all
      @more = @videos.size > PAGE_SIZE
      @videos = @videos.first(PAGE_SIZE)
      return partial(:_cards, videos: @videos, next_url: (@more ? library_path(page: @page + 1) : nil)) if htmx?

      @tags = Tag.counts
      erb :library
    end

    get '/videos/:id' do
      @video = video!(params[:id])
      @related = @video.related
      erb :video
    end

    # ---- video editing & interaction (HTMX fragments) --------------------

    get('/videos/:id/info')   { partial(:_info, v: video!(params[:id])) }
    get('/videos/:id/player') { partial(:_player, v: video!(params[:id])) } # polled while processing
    get('/videos/:id/edit') { partial(:_edit, v: video!(params[:id])) }

    put '/videos/:id' do
      v = video!(params[:id])
      title = params[:title].to_s.strip
      v.update(title: title.empty? ? v.title : title, description: params[:description].to_s.strip)
      v.set_tags(params[:tags])
      if params[:thumb].to_s.match?(/\A\d+\z/) && params[:thumb].to_i != v.thumb_index
        Ingest.choose_thumbnail(v, params[:thumb].to_i) if File.file?(Ingest.still_path(v.id, params[:thumb].to_i))
      end
      partial(:_info, v: v)
    end

    post '/videos/:id/favorite' do
      v = video!(params[:id])
      v.update(favorite: !v.favorite)
      partial(:_fav, v: v)
    end

    post '/videos/:id/view' do
      v = video!(params[:id])
      Video.where(id: v.id).update(view_count: Sequel[:view_count] + 1, last_viewed_at: Time.now)
      204
    end

    post '/videos/:id/progress' do
      v = video!(params[:id])
      position = params[:position].to_f
      position = 0.0 unless position.finite?
      position = [position, 0].max
      position = [position, v.duration].min if v.duration && v.duration.positive?
      v.update(position: position, last_viewed_at: Time.now)
      204
    end

    post '/videos/:id/reprocess' do
      v = video!(params[:id])
      v.update(status: 'pending', error: nil) if v.status == 'error'
      Worker.enqueue(v.id)
      return redirect("/videos/#{v.id}") unless htmx?

      # Stay on the page: a ready video keeps playing while it's regenerated;
      # anything else swaps its stage over to the "being prepared" poller.
      html = partial(:_info, v: v, notice: 'Reprocessing queued — new thumbnail choices appear once it finishes.')
      html += partial(:_player, v: v, oob: true) unless v.ready?
      html
    end

    post '/videos/:id/restore' do
      v = video!(params[:id])
      Dedupe.restore!(v)
      htmx? ? '' : redirect("/videos/#{v.id}")
    end

    # ---- duplicates ------------------------------------------------------

    get '/duplicates' do
      @page_title = 'Duplicates'
      Thread.new { Argentum.safely('fingerprint backfill') { Dedupe.backfill! } } if Dedupe.unfingerprinted.count.positive?
      @unfingerprinted = Dedupe.unfingerprinted.count
      @groups = Dedupe.groups
      @ignored = Video.ignored.order(:title).all
      erb :duplicates
    end

    post '/duplicates/remove' do
      ids = Array(params[:ids]).map(&:to_i)
      remove = Array(params[:remove]).map(&:to_i) & ids
      Dedupe.remove!(remove)
      kept = Video.where(id: ids - remove).all
      partial(:_dupe_done, removed: remove.size, kept: kept) +
        partial(:_ignored, videos: Video.ignored.order(:title).all, oob: true)
    end

    post '/duplicates/dismiss' do
      Dedupe.dismiss!(Array(params[:ids]).map(&:to_i).uniq)
      ''
    end

    post '/reprocess' do
      Worker.reprocess_all
      partial(:_status, outstanding: Worker.outstanding, scanning: false)
    end

    post '/scan' do
      Thread.new { Argentum.safely('manual scan') { Scanner.scan! } }
      partial(:_status, outstanding: Worker.outstanding, scanning: true)
    end

    get '/status' do
      partial(:_status, outstanding: Worker.outstanding, scanning: false)
    end

    # ---- media ---------------------------------------------------------

    get '/media/:id' do
      v = video!(params[:id])
      serve(v.abs_path, Rack::Mime.mime_type(File.extname(v.rel_path), 'video/mp4'))
    end

    get '/brand/logo' do
      path = Config.logo_file
      halt 404 unless path
      cache_control :public, max_age: 3600
      send_file path, type: Rack::Mime.mime_type(File.extname(path), 'image/png')
    end

    get('/thumbs/:id.jpg')    { serve(Ingest.thumb_path(params[:id].to_i), 'image/jpeg') }
    get('/stills/:id/:n.jpg') { serve(Ingest.still_path(params[:id].to_i, params[:n].to_i), 'image/jpeg') }
    get('/previews/:id.mp4')  { serve(Ingest.preview_path(params[:id].to_i), 'video/mp4') }

    get '/hls/:id/:file' do
      file = params[:file]
      halt 404 unless file.match?(/\A[\w.-]+\z/)
      type = file.end_with?('.m3u8') ? 'application/vnd.apple.mpegurl' : 'video/mp2t'
      serve(File.join(Ingest.hls_path(params[:id].to_i), file), type)
    end
  end
end
