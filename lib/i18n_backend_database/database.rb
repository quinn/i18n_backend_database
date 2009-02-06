require 'digest/md5'
require 'base64'

module I18n
  module Backend
    class Database < I18n::Backend::Simple
      attr_accessor :locale
      attr_accessor :cache_store

      def initialize(options = {})
        init_translations
        store   = options.delete(:cache_store)
        @cache_store = store ? ActiveSupport::Cache.lookup_store(store) : Rails.cache
      end

      def locale=(code)
        @locale = Locale.find_by_code(code)
      end

      def cache_store=(store)
        @cache_store = ActiveSupport::Cache.lookup_store(store)
      end

      # handles the lookup and addition of translations to the database
      #
      # on an initial translation, the locale is checked to determine if
      # this is the default locale.  if it is, we'll create a complete
      # transaction record for this locale with both the key and value.
      #
      # if the current locale is checked, and it differs from the default
      # locale, we'll create a transaction record with a nil value.  this
      # allows for the lookup of untranslated records in a given locale.
      #
      # on hits, we simply return the stored value.
      # Rails.cache -> Database -> I18n.load_path
      #
      # on misses, we update the cache and database, and return the key:
      # Rails.cache -> Database -> I18n.load_path -> Database -> Rails.cache
      def translate(locale, key, options = {})
        @locale = locale_in_context(locale)

        # handle bulk lookups
        return key.map { |k| translate(locale, k, options) } if key.is_a? Array

        original_key = key
        key = "#{options[:scope].join('.')}.#{key}" if options[:scope]

        # pull out hash lookup options
        reserved = :scope, :default
        count, scope, default = options.values_at(:count, *reserved)
        options.delete(:default)
        values = options.reject { |name, value| reserved.include?(name) }

        cache_key = build_cache_key(@locale, generate_hash_key(key))

        # check cache for key and return value if it exists
        value = @cache_store.read(cache_key)
        return interpolate(locale, pluralize(locale, value, count), values) if value

        # check database for key and return value if it exists
        translation = @locale.translation_from_key(cache_key)
        return interpolate(locale, pluralize(locale, translation.value, count), values) if translation

        # check default i18n load paths and return value if it exists
        value = lookup(locale, original_key, scope)
        value = value[:other] if value.is_a?(Hash)
        value = default(locale, default, options) if value.nil?

        if scope && value.nil?
          # throw to escape from recursive default lookup
          raise I18n::MissingTranslationData.new(locale, key, options)
        end

        # create the database and cache records
        value = @locale.create_translation(cache_key, (value || key)).value
        @cache_store.write(cache_key, value, :raw => true)

        value = pluralize(locale, value, count)
        value = interpolate(locale, value, values)
        value || key
      end

      def available_locales
        Locale.available_locales
      end

      def reload!
        # get's called on initialization
        # let's not do anything yet
      end

      protected
        # keep a local copy of the locale in context for use within the translation
        # routine, and also accept an arbitrary locale for one time locale lookups
        def locale_in_context(tmp_locale=nil)
          if @locale && tmp_locale
            # the passed locale is different than the cache
            unless @locale.code == tmp_locale.to_s
              Locale.find_by_code(tmp_locale.to_s)
            else
              @locale
            end
          elsif @locale
            # synch cache with I18n.locale
            unless @locale.code == I18n.locale.to_s
              Locale.find_by_code(I18n.locale.to_s)
            else
              @locale
            end
          else
            Locale.find_by_code(I18n.locale.to_s)
          end
        end

        # locale:"key"
        def build_cache_key(locale, key)
          "#{locale.code}:#{key}"
        end

        def generate_hash_key(key)
          Base64.encode64(Digest::MD5.hexdigest(key))
        end
    end
  end
end