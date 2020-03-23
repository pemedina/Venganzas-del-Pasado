class Post < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: %i[slugged finders]

  has_many :comments, dependent: :destroy
  has_many :audios,   dependent: :destroy
  has_many :media,    dependent: :destroy
  belongs_to :contributor, class_name: 'User'
  accepts_nested_attributes_for :media

  # TODO: Rails6
  # attr_accessible :title, :content, :created_at, :media_attributes
  # attr_accessible :title, :content, :created_at, :media_attributes, :status, :as => :admin

  validates :title, presence: true
  validate :validate_status

  delegate :alias, to: :contributor, prefix: true, allow_nil: true

  scope :published, -> { where(status: 'published') }
  scope :waiting, -> { where(status: 'waiting') }
  scope :lifo, -> { order('created_at DESC') }
  scope :this_month, -> { where(created_at: Date.today.beginning_of_month..Date.today.end_of_month) }

  # Class methods
  class << self
    def statuses
      %w[published draft deleted pending waiting]
    end

    def created_on(year, month = nil, day = nil)
      date = Date.new year.to_i

      if month.present?
        date = date.change(month: month.to_i)
        if day.present?
          date = date.change(day: day.to_i)
          range_date = date.beginning_of_day..date.end_of_day
        else
          range_date = date.beginning_of_month.beginning_of_day..date.end_of_month.end_of_day
        end
      else
        range_date = date.beginning_of_year.beginning_of_day..date.end_of_year.end_of_day
      end

      where(created_at: range_date)
    end

    def post_count_by_month
      published
        .select('YEAR(created_at) AS year, MONTH(created_at) AS month, COUNT(*) AS count')
        .group('year, month')
        .order('year DESC, month DESC')
    end

    def create_from_audio_file(filename)
      if File.exist?(filename) && filename =~ /lavenganza_(\d{4})-(\d{2})-(\d{2}).mp3/
        day = Regexp.last_match(3)
        mon = Regexp.last_match(2)
        year = Regexp.last_match(1)
        title = "La venganza será terrible del #{day}/#{mon}/#{year}"
        Post.find_or_create_by(title: title) do |post|
          post.created_at = Time.zone.parse('#{year}-#{mon}-#{day} 03:00:00')
          post.status     = 'published'
          post.content    = ''
          audio           = Audio.find_or_initialize_by(url: "http://venganzasdelpasado.com.ar/#{year}/lavenganza_#{year}-#{mon}-#{day}.mp3")
          audio.bytes     = File.size(filename)
          post.audios << audio
        end
      end
    end

    def new_contribution(params, user)
      # Elimina de params los media vacíos
      if params[:media_attributes].present?
        params[:media_attributes] = params['media_attributes'].select { |_k, v| v['asset'].present? }
      end
      post = new(params)
      post.status = 'pending'
      post.created_at += 4.hours # a las 4 de la mañana, para que no interfiera con los automáticos
      post.contributor = user
      # Agrega un media vacío si no hay ninguno, para que falle la validación
      post.media << Medium.new if post.media.empty?
      post
    end

    def has_status(status)
      where('status = ?', status)
    end

    def last_updated
      published.order('updated_at DESC').first
    end

    def contributions
      where('contributor_id IS NOT NULL').order('updated_at DESC')
    end
  end # Class methods

  def publish_contribution
    media.each do |medium|
      filename = "lavenganza_#{created_at.strftime('%Y-%m-%d')}_#{medium.id}.mp3"
      year = created_at.year
      dest_dir = "/var/www/venganzasdelpasado.com.ar/#{year}"
      dest_file = "#{dest_dir}/#{filename}"

      # Copy MP3 to local store
      FileUtils.mkdir_p dest_dir
      FileUtils.copy_file medium.asset.path, dest_file

      # Upload to S3
      system "/usr/bin/s3cmd -c /home/jschwindt/.s3cfg --acl-public put #{medium.asset.path} s3://s3.schwindt.org/dolina/#{year}/#{filename}"

      # Create Audio record
      audios << Audio.new(url: "http://venganzasdelpasado.com.ar/#{year}/#{filename}", bytes: File.size(dest_file))

      # Remove media
      medium.destroy
    end

    # Change status to published
    self.status = 'published'
    save
  end

  def approve_contribution!
    self.status = 'waiting'
    save!
  end

  def creation_date
    created_at.to_datetime
  end

  def published?
    status == 'published'
  end

  def pending?
    status == 'pending'
  end

  def previous
    Post.lifo.published.where('created_at < ?', created_at).first
  end

  def next
    Post.lifo.published.where('created_at > ?', created_at).last
  end

  def description
    if content.present?
      desc = content.gsub(%r{</?[^>]+?>}, '') # remove html tags
                    .gsub(/[_#*\r\n-]+/, ' ') # remove some markdown
                    .truncate(200, separator: ' ', omission: '')
      desc.gsub(/\s+/, ' ').strip
    else
      "#{title} de Alejandro Dolina"
    end
  end

  protected

  def validate_status
    unless Post.statuses.include?(status)
      errors.add(:status, I18n.t('activerecord.errors.models.post.attributes.status.inclusion'))
    end
  end
end
