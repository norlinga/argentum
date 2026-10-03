module Argentum
  class Tag < Sequel::Model(DB[:tags])
    def self.normalize(raw)
      raw.to_s.split(',').map { |t| t.downcase.strip.gsub(/\s+/, ' ') }.reject(&:empty?).uniq
    end

    # Stable hue (0-359) per tag name so a tag keeps its colour everywhere.
    # Mirrored by tagHue() in argentum.js — keep the two in sync.
    def self.hue(name)
      h = name.to_s.each_codepoint.reduce(0) { |acc, cp| (acc * 31 + cp) % 1_000_003 }
      (h * 137.508 % 360).floor
    end

    # Tags with the number of ready videos carrying them, most used first.
    def self.counts(limit: 40)
      DB[:tags].join(:taggings, tag_id: :id).join(:videos, id: :video_id)
               .where(Sequel[:videos][:status] => 'ready')
               .group(Sequel[:tags][:name])
               .select(Sequel[:tags][:name], Sequel.function(:count, Sequel[:videos][:id]).as(:n))
               .order(Sequel.desc(:n), :name).limit(limit).all
    end
  end

  class Video < Sequel::Model(DB[:videos])
    STOPWORDS = %w[the and for with from our video videos mov mp4 img vid mvi clip].freeze

    many_to_many :tags, join_table: :taggings, left_key: :video_id, right_key: :tag_id, order: :name

    dataset_module do
      def ready = where(status: 'ready')
      def ignored = where(status: 'ignored')

      def search(q: nil, tag: nil, fav: false, sort: 'newest')
        ds = self
        ds = ds.where(favorite: true) if fav
        if tag && !tag.empty?
          ds = ds.where(id: DB[:taggings].join(:tags, id: :tag_id).where(Sequel[:tags][:name] => tag)
                                         .select(Sequel[:taggings][:video_id]))
        end
        q.to_s.split.each do |token|
          pat = "%#{db.dataset.escape_like(token)}%"
          tagged = DB[:taggings].join(:tags, id: :tag_id).where(Sequel.ilike(Sequel[:tags][:name], pat))
                                .select(Sequel[:taggings][:video_id])
          ds = ds.where(Sequel.|(Sequel.ilike(:title, pat), Sequel.ilike(:description, pat),
                                 Sequel.ilike(:rel_path, pat), { id: tagged }))
        end
        case sort
        when 'popular' then ds.order(Sequel.desc(:view_count), Sequel.desc(:last_viewed_at))
        when 'least'   then ds.order(:view_count, Sequel.desc(:mtime))
        when 'title'   then ds.order(Sequel.function(:lower, :title))
        when 'random'  then ds.order(Sequel.function(:random))
        else ds.order(Sequel.desc(:mtime), Sequel.desc(:id))
        end
      end
    end

    def abs_path = Config.media_path(rel_path)
    def ready? = status == 'ready'
    def tag_names = tags.map(&:name)

    def set_tags(names)
      names = Tag.normalize(names.is_a?(Array) ? names.join(',') : names)
      DB.transaction do
        DB[:taggings].where(video_id: id).delete
        names.each do |n|
          tag = Tag.find_or_create(name: n)
          DB[:taggings].insert(video_id: id, tag_id: tag.id)
        end
        DB[:tags].where(id: DB[:tags].left_join(:taggings, tag_id: :id).where(Sequel[:taggings][:tag_id] => nil)
                                       .select(Sequel[:tags][:id])).delete
      end
      associations.delete(:tags)
    end

    def title_tokens
      title.downcase.scan(/[a-z]{3,}/) - STOPWORDS
    end

    def duration_label
      return nil unless duration
      s = duration.to_i
      h, m, sec = s / 3600, s % 3600 / 60, s % 60
      h.positive? ? format('%d:%02d:%02d', h, m, sec) : format('%d:%02d', m, sec)
    end

    def resumable?
      duration && position > 5 && position < duration - 10
    end

    def progress_pct
      resumable? ? (position / duration * 100).round : 0
    end

    # Videos sharing tags (weighted heavier) or title words with this one.
    def related(limit: 6)
      my_tags = tags.map(&:id)
      my_words = title_tokens
      return [] if limit <= 0 || (my_tags.empty? && my_words.empty?)

      matches = my_words.map { |word| Sequel.ilike(:title, "%#{word}%") }
      unless my_tags.empty?
        matches << { id: DB[:taggings].where(tag_id: my_tags).select(:video_id) }
      end
      candidates = Video.ready.exclude(id: id).where(Sequel.|(*matches)).eager(:tags).order(:id)
      best = []
      last_id = 0
      loop do
        batch = candidates.where { id > last_id }.limit(128).all
        break if batch.empty?

        batch.each do |v|
          score = (v.tags.map(&:id) & my_tags).size * 3 + (v.title_tokens & my_words).size * 2
          next unless score.positive?

          best << [score, v]
          best.sort_by! { |s, row| [-s, -row.view_count, row.id] }
          best.pop if best.size > limit
        end
        last_id = batch.last.id
      end
      best.map(&:last)
    end

    # Home page mix: mostly well-watched/favourite videos (lightly shuffled) with a few
    # rarely-seen ones sprinkled in so there's something to be surprised by.
    def self.home_mix(total: 16, surprises: 4)
      ranked = ready.eager(:tags).order(Sequel.desc(:view_count), Sequel.desc(:favorite),
                           Sequel.desc(:last_viewed_at), Sequel.function(:random))
                    .limit(total - surprises + 6).all
      popular = ranked.sample(total - surprises).sort_by { |v| ranked.index(v) }
      surprise = ready.eager(:tags).exclude(id: popular.map(&:id))
                      .order(Sequel.function(:random)).limit(surprises).all
      mix = popular.dup
      surprise.each_with_index do |v, i|
        mix.insert([2 + i * 3, mix.size].min, v)
      end
      mix
    end

    def self.continue_watching(limit: 6)
      ready.eager(:tags).where { (position > 5) & (position < duration - 10) }
           .order(Sequel.desc(:last_viewed_at)).limit(limit).all
    end
  end
end
