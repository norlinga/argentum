require 'sequel'

module Argentum
  Config.ensure_dirs!

  DB = Sequel.sqlite(File.join(Config.data_dir, 'argentum.db'), timeout: 10_000)
  DB.run 'PRAGMA journal_mode=WAL'

  DB.create_table?(:videos) do
    primary_key :id
    String   :rel_path, null: false, unique: true
    String   :title, null: false
    String   :description, text: true
    Float    :duration
    Integer  :width
    Integer  :height
    Integer  :size
    Integer  :mtime
    String   :vcodec
    String   :acodec
    String   :status, null: false, default: 'pending' # pending processing ready error missing ignored
    String   :error, text: true
    TrueClass :hls_ready, null: false, default: false
    Integer  :view_count, null: false, default: 0
    TrueClass :favorite, null: false, default: false
    Float    :position, null: false, default: 0.0
    Time     :last_viewed_at
    Time     :created_at
    Time     :ingested_at
    index :status
    index :view_count
  end

  DB.alter_table(:videos) { add_column :thumb_index, Integer } unless DB[:videos].columns.include?(:thumb_index)
  # Perceptual hashes of the stills, used to spot re-encodes of the same video.
  DB.alter_table(:videos) { add_column :fingerprint, String, text: true } unless DB[:videos].columns.include?(:fingerprint)

  # Pairs the user has said are *not* duplicates (a_id < b_id).
  DB.create_table?(:dupe_dismissals) do
    Integer :a_id, null: false
    Integer :b_id, null: false
    primary_key %i[a_id b_id]
  end

  DB.create_table?(:tags) do
    primary_key :id
    String :name, null: false, unique: true
  end

  DB.create_table?(:taggings) do
    foreign_key :video_id, :videos, null: false, on_delete: :cascade
    foreign_key :tag_id, :tags, null: false, on_delete: :cascade
    primary_key %i[video_id tag_id]
  end
end
