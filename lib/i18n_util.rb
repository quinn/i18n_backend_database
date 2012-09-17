class I18nUtil

  DEFAULT_TRANSLATION_PATH  = 'config/translations'

  @@verbose,@@current_load_source = nil,nil

  def self.verbose?
    @@verbose
  end

  def self.verbose=(value)
    @@verbose = value
  end

  def self.current_load_source(ensure_saved = true)
    @@current_load_source.save! if @@current_load_source and ensure_saved
    @@current_load_source
  end

  def self.set_current_load_source(path)
    path = path.to_s[(Rails.root.to_s.length + 1)..-1] if path.to_s.index(Rails.root.to_s) == 0
    @@current_load_source = TranslationSource.find_by_path(path) || TranslationSource.new({:path => path}, without_protection: true) unless @@current_load_source and @@current_load_source.path == path
    if block_given?
      yield
      @@current_load_source = nil
    end
    @@current_load_source
  end
  
  def self.load_default_locales(path = nil)
    path ||= 'config/locales.yml'
    puts "LOAD LOCALES: #{path}" if verbose?
    raise 'Locales file not found' unless (full_path = Rails.root + path).exist?

    YAML::load_file(full_path).each do |code, options|
      raise "name for locale code #{code} is blank!" if (name = options['name']).blank?

      if (locale = I18n::Backend::Locale.where(:code => code).first).nil?
        puts "...CREATE - #{code} - #{name}" if verbose?
        I18n::Backend::Locale.create!({:code => code, :name => name}, without_protection: true)
      elsif locale.name == name
        puts "...EXISTS - #{code} - #{name}" if verbose?
      else
        puts "...UPDATE - #{code} - #{name}" if verbose?
        locale.update_attributes!(:name => name)
      end
    end
  end
  
  def self.load_default_localizations
    I18nUtil.load_from_yml File.join(File.dirname(__FILE__), "../data", "default_localized_translations.yml")
  end

  # Create tanslation records from the YAML file.  Will create the required locales if they do not exist.
  def self.load_from_yml(file_name)
    set_current_load_source(file_name) do
      puts "LOAD YAML: #{file_name}" if verbose?
      data = YAML::load(IO.read(file_name))
      data.each do |code, translations|
        if locale = I18n::Backend::Locale.find_by_code(code)
          translations_array = extract_translations_from_hash(translations)
          translations_array.each do |key, value|
            pluralization_index = 1
            key.gsub!('.one', '') if key.ends_with?('.one')
            if key.ends_with?('.other')
              key.gsub!('.other', '')
              pluralization_index = 0
            end
            if value.is_a?(Array)
              value.each_with_index do |v, index|
                create_translation(locale, key, index, v) unless v.nil?
              end
            else
              create_translation(locale, key, pluralization_index, value)
            end
          end
        end
      end
    end
  end

  # Finds or creates a translation record and updates the value
  def self.create_translation(locale, key, pluralization_index, value)
    if translation = locale.translations.find_by_key_and_pluralization_index(Translation.hk(key), pluralization_index) # find existing record by hash key
      puts "...UPDATE #{locale.code} : #{key} : #{pluralization_index}" if verbose?
    elsif locale != (default_locale = I18n::Backend::Locale.default_locale) and not default_locale.translations.find_by_key_and_pluralization_index(Translation.hk(key), pluralization_index)
      puts "...SKIP   #{locale.code} : #{key} : #{pluralization_index}" if verbose?
    else
      translation = locale.translations.build(:key => key, :pluralization_index => pluralization_index)
      puts "...ADD    #{locale.code} : #{key} : #{pluralization_index}" if verbose?
    end
    if translation
      translation.value = value
      translation.source = current_load_source
      translation.save!
    end
  end

  def self.extract_translations_from_hash(hash, parent_keys = [])
    (hash || {}).inject([]) do |keys, (key, value)|
      full_key = parent_keys + [key]
      if value.is_a?(Hash)
        # Nested hash
        keys += extract_translations_from_hash(value, full_key)
      elsif !value.nil?
        # String leaf node
        keys << [full_key.join("."), value]
      end
      keys
    end
  end

  # Create translation records for all existing locales from translation calls with the application. 
  # Ignores errors from tranlations that require objects.
  def self.seed_application_translations(dir='app')
    last_source = nil
    translated_objects(dir).each do |match,source|
      if match =~ /#\{/ # skip any strings that have substitution patterns
        puts "WARNING: MATCH:#{match} -- CONTAINS A RUBY SUBSTITUTION IN #{source.path}"
        next
      end
      next if I18n::Backend::Locale.default_locale.translations.find_by_key_and_pluralization_index(Translation.hk(match),1)

      begin
        interpolation_arguments= match.scan(/\%\{(.*?)\}/).flatten
        options = interpolation_arguments.inject({}) { |options,arg|  options[arg.to_sym] = nil; options }

        puts "SOURCE: #{source.path}" if verbose? and source != last_source
        set_current_load_source((last_source = source).full_path.to_s)
        I18n.t(match, options) # default locale first
      rescue
        puts "WARNING:#{$!} MATCH:#{match} OPTIONS:#{options} ARGS:#{interpolation_arguments} IN #{source.path}"
      end

    end
  end

  def self.translated_objects(dir=nil)
    assets = []
    dir ||= 'app'
    Dir.glob("#{dir}/*").each do |item|
      if File.directory?(item)
        assets += translated_objects(item) unless item.ends_with?('i18n_backend_database') # ignore self
      elsif item.ends_with?('.rb') || item.ends_with?('.erb') || item.ends_with?('.rhtml') # TODO what about things like HAML?
        set_current_load_source(item) do
          File.readlines(item).each_with_index do |line,index|
            begin
              assets += line.scan(/(I18n\.t|\Wt)(\(|\s*)'([^']*)'/).collect{|pair| [pair.last,current_load_source(false)]}
              assets += line.scan(/(I18n\.t|\Wt)(\(|\s*)"([^"]*)"/).collect{|pair| [pair.last,current_load_source(false)]}
              assets += line.scan(/(I18n\.t|\Wt)(\(|\s*)%\(([^\)]*)\)"/).collect{|pair| [pair.last,current_load_source(false)]}
              assets += line.scan(/(I18n\.t|\Wt)(\(|\s*)%\[([^\]]*)\]"/).collect{|pair| [pair.last,current_load_source(false)]}
            rescue
              puts "WARNING:#{$!} in file #{item} with line '#{line}'"
            end
          end
        end
      end
    end
    assets.uniq
  end

  # Populate translation records from the default locale to other locales if no record exists.
  def self.synchronize_translations(exclusions)
    set_current_load_source(nil)
    non_default_locales = I18n::Backend::Locale.non_defaults
    puts "CHECKING FOR MISSES - #{non_default_locales.collect{|locale| locale.code}}" if verbose?
    I18n::Backend::Locale.default_locale.translations.each do |translation|
      next if exclusions.detect{|pattern| translation.raw_key =~ pattern}

      non_default_locales.each do |locale|
        unless locale.translations.exists?(:key => translation.key, :pluralization_index => translation.pluralization_index)
          value = translation.value =~ /^---(.*)\n/ ? translation.value : nil # well will copy across YAML, like symbols
          locale.translations.create!(:key => translation.raw_key, :value => value, :pluralization_index => translation.pluralization_index)
          puts "...MISSING #{locale.code} : #{translation.raw_key} : #{translation.pluralization_index}" if verbose?
        end
      end
    end
  end

  def self.google_translate
    set_current_load_source(nil)
    Locale.non_defaults.each do |locale|
      locale.translations.untranslated.each do |translation|
        default_locale_value = translation.default_locale_value
        unless needs_human_eyes?(default_locale_value)
          interpolation_arguments= default_locale_value.scan(/\{\{(.*?)\}\}/).flatten

          if interpolation_arguments.empty?
            translation.value = GoogleLanguage.translate(default_locale_value, locale.code, Locale.default_locale.code)
            translation.source = current_load_source
            translation.save!
          else
            placeholder_value = 990 # at least in :es it seems to leave a 3 digit number in the postion on the string
            placeholders = {}

            # replace %{interpolation_arguments} with a numeric place holder
            interpolation_arguments.each do |interpolation_argument|
              default_locale_value.gsub!("%{#{interpolation_argument}}", "#{placeholder_value}")
              placeholders[placeholder_value] = interpolation_argument
              placeholder_value += 1
            end

            # translate string
            translated_value = GoogleLanguage.translate(default_locale_value, locale.code, Locale.default_locale.code)

            # replace numeric place holders with %{interpolation_arguments}
            placeholders.each {|placeholder_value,interpolation_argument| translated_value.gsub!("#{placeholder_value}", "%{#{interpolation_argument}}") }
            translation.value = translated_value
            translation.source = current_load_source
            translation.save!
          end
        end
      end
    end
  end

  def self.needs_human_eyes?(value)
    return true if value.index('%')         # date formats
    return true if value =~ /^---(.*)\n/    # YAML
  end
  
  def self.process_translation_locales(locales_codes, &action)
    if locales_codes.empty?
      puts 'Nothing to do.'
    else
      locales_codes.each do | locale_code |
        raise "Locale '#{locale_code}' not found"  unless locale = I18n::Backend::Locale.find_by_code(locale_code)
        action.call(locale)
      end
    end
  end

  def self.export_translations(locale,suffix = '.yml')
    puts "EXPORTING - #{locale.code}" if verbose?
    translation_path = "#{DEFAULT_TRANSLATION_PATH}/#{locale.code}#{suffix}"
    source_options = ['source_id is null']
    if previous_translations_source = TranslationSource.find_by_path(translation_path)
      source_options << "source_id = #{previous_translations_source.id}"
    end

    set_current_load_source(full_path = Rails.root + translation_path) do
      full_path.dirname.mkdir unless full_path.dirname.exist?

      translations = Translation.where(:locale_id => locale.id).where(source_options.join(' or '))
      return puts "No translations found for '#{locale.code}'" if translations.empty?

      exports,blank_count = [],0
      translations.each do |translation|
        if translation.value.blank?
          blank_count += 1
        else
          puts "...EXPORT - #{translation.raw_key} - #{translation.pluralization_index}" if verbose?
          exports << {'key' => translation.raw_key,'value' => translation.value,'pluralization_index' => translation.pluralization_index}
          translation.source = current_load_source
          translation.save!
        end
      end

      puts "#{translations.length - blank_count} EXPORTED..." if verbose?
      puts "WARNING: #{blank_count} BLANKS FOUND!" if verbose?

      `cp #{full_path} #{full_path}.bak-#{Time.now.strftime('%Y%m%d%H%M%S')}` if File.exists?(full_path)
      File.open(full_path,'w'){|file| file.write exports.to_yaml}
    end

  end

  def self.import_translations(locale)
    puts "IMPORTING - #{locale.code}" if verbose?
    full_path = Rails.root + "#{DEFAULT_TRANSLATION_PATH}/#{locale.code}.yml"
    return puts "No translation file found for '#{locale.code}'" unless full_path.exist?

    set_current_load_source(full_path) do
      return puts "No translations found for '#{locale.code}'" unless translations = YAML::load_file(full_path)

      translations.each do |translation|
        create_translation(locale,translation['key'],translation['pluralization_index'],translation['value'].blank? ? nil : translation['value'])
      end

      puts "#{translations.length} IMPORTED..." if verbose?
    end
  end

end
