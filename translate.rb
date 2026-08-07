#!/usr/bin/env ruby

require 'cgi'
require 'json'
require 'net/http'
require 'open3'
require 'google/cloud/translate/v2'
require 'optparse'
require 'tempfile'
require 'fileutils'
require 'uri'

# usage examples:
#   Single file:
#     ./translate.rb --input-file input_video.mkv --output translated_subtitles.srt --language es --stream 0:s:0
#
#   Whole folder (all .mkv files):
#     ./translate.rb --input-folder /path/to/folder --output /path/to/output_folder --language es --stream 0:s:0
#
# Options:
#   --input-file: Path to a single .mkv video file.
#   --input-folder: Path to a folder containing .mkv files to process.
#   --output: For --input-file, path to save the translated .srt file.
#             For --input-folder, optional path to an output directory (defaults to the input folder).
#   --stream: Which stream to use as source language (for example '0:s:0' for first subtitle track)
#   --language: Target language for the translation (for example 'es' for Spanish)

# extract the first subtitle track from an MKV video
def extract_subtitles(video_path, output_srt, stream)
  puts "extracting subtitles from #{video_path} to #{output_srt.path}"
  command = "ffmpeg -y -i \"#{video_path}\" -map #{stream} \"#{output_srt.path}\""
  puts "Command: #{command}"
  if system(command)
    puts "Subtitles extracted successfully to #{output_srt.path}"
  else
    puts "Error extracting subtitles"
    exit(1)
  end
end

class SubtitleTranslator
  attr_reader :service_name

  def initialize(target_language)
    @target_language = target_language
    @cache = {}
    @translation_count = 0
    @cache_hit_count = 0
    @service_name = determine_service
    @openai_model = ENV['OPENAI_MODEL'] || 'gpt-4o-mini'
    @openai_temperature = (ENV['OPENAI_TEMPERATURE'] || '0.1').to_f
    @client = build_client
    puts "Using #{@service_name.to_s.capitalize} for translation."
  end

  def translate(input_io, output_path)
    cues = parse_cues(input_io.read)
    translations = {}
    pending_lines = []

    cues.each_with_index do |cue, cue_index|
      next unless cue[:number]
      cue[:text].each_with_index do |line, line_index|
        next unless translatable_line?(line)
        key = [cue_index, line_index]
        if @cache.key?(line)
          translations[key] = @cache[line]
          @cache_hit_count += 1
        else
          pending_lines << { key: key, text: line }
        end
      end
    end

    translate_batches(pending_lines).each { |key, text| translations[key] = text }
    translated_output = cues.map.with_index do |cue, cue_index|
      next cue[:original] unless cue[:number]
      text = cue[:text].map.with_index { |line, line_index| translations.fetch([cue_index, line_index], line) }
      ([cue[:number], cue[:timing]] + text).join("\n")
    end.join("\n\n") + "\n"

    File.open(output_path, 'w:UTF-8') do |file|
      file.write(translated_output)
    end

    puts "Translated subtitles saved to #{output_path}. Made #{@translation_count} API calls; #{@cache_hit_count} cache hits."
  end

  private

  def parse_cues(content)
    normalized_content = content.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    normalized_content.split(/\r?\n\r?\n+/).filter_map do |block|
      lines = block.lines.map { |line| CGI.unescapeHTML(line.chomp) }
      next if lines.empty?
      if lines.length >= 2 && lines[0] =~ /^\d+$/ && lines[1].include?('-->')
        { number: lines[0], timing: lines[1], text: lines[2..] }
      else
        { original: block }
      end
    end
  end

  def translatable_line?(line)
    line.match?(/[A-Za-z]+/)
  end

  def translate_batches(pending_lines)
    results = {}
    batch = []
    batch_size = 0
    # Keep JSON responses comfortably below the model's output-token limit.
    max_batch_size = (ENV['TRANSLATION_BATCH_SIZE'] || '6000').to_i
    pending_lines.each do |entry|
      entry_size = entry[:text].bytesize + 30
      if !batch.empty? && batch_size + entry_size > max_batch_size
        results.merge!(translate_batch(batch))
        batch = []
        batch_size = 0
      end
      batch << entry
      batch_size += entry_size
    end
    results.merge!(translate_batch(batch)) unless batch.empty?
    results
  end

  def translate_batch(entries)
    prompt = entries.each_with_index.map { |entry, index| "[[S#{index}]] #{entry[:text]}" }.join("\n")
    puts "Translating #{entries.length} subtitle line(s) in one request"
    translated = translate_text(prompt)
    @translation_count += 1
    log_translation_response(translated, entries.length)

    parsed = parse_json_translation(translated, entries)
    puts "Translation response format: JSON" if parsed
    partial_json = parse_partial_json_translation(translated, entries)
    if partial_json && partial_json.length < entries.length
      missing_entries = entries.reject { |entry| partial_json.any? { |key, _| key == entry[:key] } }
      puts "JSON response omitted #{missing_entries.length} subtitle line(s); retrying only those lines."
      parsed = partial_json + translate_batch(missing_entries).to_a
      puts "Translation response format: JSON with targeted retry"
    end

    if parsed.nil?
      normalized_translation = normalize_markers(translated)
      marker_parsed = entries.each_with_index.map do |entry, index|
        marker = "[[S#{index}]]"
        next_marker = index == entries.length - 1 ? nil : "[[S#{index + 1}]]"
        pattern = next_marker ? /#{Regexp.escape(marker)}\s*(.*?)\s*(?=#{Regexp.escape(next_marker)})/m : /#{Regexp.escape(marker)}\s*(.*)\z/m
        match = normalized_translation.match(pattern)
        break nil unless match
        # Providers may wrap long responses. Keep one translated line per original
        # line so the cue's layout remains stable as well as its timing.
        translated_text = match[1].strip.gsub(/\s*\r?\n\s*/, ' ')
        [entry[:key], translated_text]
      end
      puts "Translation response format: markers" if marker_parsed
      parsed = marker_parsed

      # Some provider responses preserve the order but omit the markers. Only use
      # that response when there is exactly one non-empty output line per input
      # line; otherwise failing is safer than shifting subtitles between cues.
      sequential_parsed = sequential_translation(normalized_translation, entries)
      puts "Translation response format: sequential lines" if sequential_parsed
      parsed ||= sequential_parsed
    end
    abort "Translation response did not preserve subtitle markers." unless parsed

    parsed.each do |key, translated_text|
      entry = entries.find { |candidate| candidate[:key] == key }
      @cache[entry[:text]] = translated_text
    end
    parsed.to_h
  end

  def log_translation_response(response, expected_lines)
    response_text = response.to_s
    puts "Translation response details: expected_lines=#{expected_lines}, bytes=#{response_text.bytesize}, lines=#{response_text.lines.length}, starts_with=#{response_text[0, 80].inspect}, ends_with=#{response_text[-80, 80].inspect}"
    return unless ENV['TRANSLATION_DEBUG'] == '1'

    puts "Translation response (debug):"
    puts response_text
  end

  def parse_json_translation(text, entries)
    translations = parse_json_payload(text, entries.length)
    return nil unless translations
    return nil unless entries.each_index.all? { |index| translations.key?(index.to_s) || translations.key?("S#{index}") || translations.key?("[[S#{index}]]") }

    entries.each_with_index.map do |entry, index|
      translated_text = translations[index.to_s] || translations["S#{index}"] || translations["[[S#{index}]]"]
      return nil unless translated_text.is_a?(String) && !translated_text.strip.empty?
      [entry[:key], translated_text.strip.gsub(/\s*\r?\n\s*/, ' ')]
    end
  end

  def parse_partial_json_translation(text, entries)
    translations = parse_json_payload(text, entries.length)
    return nil unless translations

    entries.each_with_index.filter_map do |entry, index|
      translated_text = translations[index.to_s] || translations["S#{index}"] || translations["[[S#{index}]]"]
      next unless translated_text.is_a?(String) && !translated_text.strip.empty?
      [entry[:key], translated_text.strip.gsub(/\s*\r?\n\s*/, ' ')]
    end
  end

  def parse_json_payload(text, expected_length)
    json_text = text.to_s.strip.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '')
    json_start = [json_text.index('{'), json_text.index('[')].compact.min
    json_end = [json_text.rindex('}'), json_text.rindex(']')].compact.max
    return nil unless json_start && json_end && json_end >= json_start

    translations = JSON.parse(json_text[json_start..json_end])
    translations = translations['translations'] if translations.is_a?(Hash) && translations['translations'].is_a?(Hash)
    if translations.is_a?(Array)
      return nil unless translations.length == expected_length
      translations = translations.each_index.to_h { |index| [index.to_s, translations[index]] }
    end
    return nil unless translations.is_a?(Hash)
    translations
  rescue JSON::ParserError
    nil
  end

  def normalize_markers(text)
    text.to_s
      .gsub(/\[\[?\s*S(\d+)\s*\]?\]/i, '[[S\\1]]')
      .gsub(/^\s*S(\d+)\s*[:\-]\s*/i, '[[S\\1]] ')
  end

  def sequential_translation(text, entries)
    return nil if text.match?(/\[?\[?\s*S\d+/i)

    lines = text.lines.map(&:strip).reject { |line| line.empty? || line.match?(/\A```/) }
    return nil unless lines.length == entries.length

    entries.each_with_index.map do |entry, index|
      [entry[:key], lines[index].gsub(/\s*\r?\n\s*/, ' ')]
    end
  end

  def translate_text(text)
    case @service_name
    when :openai
      translate_with_openai(text)
    when :google
      translate_with_google(text)
    else
      raise "Unsupported translation service: #{@service_name}"
    end
  end

  def translate_with_openai(text)
    messages = [
      { role: "system", content: "You are a concise subtitle translator. Translate each subtitle line into #{@target_language}. Return only a JSON object whose keys are the numeric subtitle indexes and whose values are the translations. Preserve the number of entries and do not add explanations." },
      { role: "user", content: "Translate these indexed subtitle lines. Return JSON such as {\"0\": \"translation\", \"1\": \"translation\"}.\n#{text}" }
    ]

    response = openai_chat_completion(messages)
    response.dig("choices", 0, "message", "content")&.strip || ''
  rescue StandardError => e
    abort "OpenAI translation error: #{e.message}"
  end

  def translate_with_google(text)
    translation = @client.translate(text, to: @target_language)
    translation.text
  rescue StandardError => e
    abort "Google Cloud translation error: #{e.message}"
  end

  def determine_service
    override = ENV['TRANSLATION_SERVICE']&.downcase
    openai_available = ENV['OPENAI_API_KEY']
    google_available = ENV['GOOGLE_CLOUD_KEY'] && ENV['GOOGLE_CLOUD_PROJECT']

    case override
    when 'openai'
      return :openai if openai_available
      abort "Requested OpenAI service via TRANSLATION_SERVICE but OPENAI_API_KEY is missing."
    when 'google'
      return :google if google_available
      abort "Requested Google service via TRANSLATION_SERVICE but GOOGLE_CLOUD_KEY/GOOGLE_CLOUD_PROJECT are missing."
    end

    return :openai if openai_available
    return :google if google_available

    abort "Missing translation credentials. Set OPENAI_API_KEY or GOOGLE_CLOUD_KEY/GOOGLE_CLOUD_PROJECT."
  end

  def build_client
    case @service_name
    when :openai
      nil
    when :google
      Google::Cloud::Translate::V2.new(
        key: ENV['GOOGLE_CLOUD_KEY'],
        project: ENV['GOOGLE_CLOUD_PROJECT']
      )
    end
  end

  def openai_chat_completion(messages)
    uri = URI.parse("https://api.openai.com/v1/chat/completions")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
    request.body = {
      model: @openai_model,
      temperature: @openai_temperature,
      max_tokens: 8192,
      response_format: { type: "json_object" },
      messages: messages
    }.compact.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    body = response.body
    parsed = parse_openai_response(body, response)

    if response.is_a?(Net::HTTPSuccess)
      return parsed if parsed
      raise "OpenAI response was not JSON: #{sanitize_body(body)}"
    end

    message = parsed&.dig("error", "message") || response.message
    message = sanitize_body(body) if message.nil? || message.empty?
    raise "OpenAI API error: #{message}"
  end

  def parse_openai_response(body, response)
    content_type = response["Content-Type"] || response["content-type"]
    return nil unless content_type&.include?("application/json")

    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  def sanitize_body(body)
    body.to_s.strip.gsub(/\s+/, ' ')[0, 200]
  end
end

# gather the CLI options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ./translate.rb [options]"

  opts.on("-f", "--input-file FILE", "Path to the input MKV video file") do |v|
    options[:input_file] = v
  end

  opts.on("-F", "--input-folder FOLDER", "Path to a folder containing MKV files to translate") do |v|
    options[:input_folder] = v
  end

  opts.on("-S", "--input-srt FILE", "Path to an input SRT file to translate (skips ffmpeg extraction)") do |v|
    options[:input_srt] = v
  end

  opts.on("-o", "--output OUTPUT", "For file mode: path to save the translated SRT file. For folder mode: output directory (optional)") do |t|
    options[:output] = t
  end

  opts.on("-l", "--language LANGUAGE", "Target language for translation (for example 'es' for Spanish)") do |l|
    options[:language] = l
  end

  # see README.md for details on what the STREAM value means
  opts.on("-s", "--stream STREAM", "Which subtitle stream to use (for example '0:s:0')") do |s|
    options[:stream] = s
  end
end.parse!

# validate input options
modes = [options[:input_file], options[:input_folder], options[:input_srt]].compact
if modes.size != 1
  abort "Please specify exactly one of --input-file, --input-folder, or --input-srt."
end

if options[:language].nil?
  abort "--language is required."
end

# --stream is only required for video inputs (file or folder)
if (options[:input_file] || options[:input_folder]) && options[:stream].nil?
  abort "--stream is required when using --input-file or --input-folder."
end

# process SRT file mode
translator = nil
if options[:input_srt]
  unless File.file?(options[:input_srt])
    abort "Input SRT file not found: #{options[:input_srt]}"
  end
  if options[:output].nil?
    abort "--output is required when using --input-srt."
  end
  translator ||= SubtitleTranslator.new(options[:language])
  File.open(options[:input_srt], 'r') do |srt|
    translator.translate(srt, options[:output])
  end
  exit 0
end

# process single file mode
if options[:input_file]
  unless File.file?(options[:input_file])
    abort "Input file not found: #{options[:input_file]}"
  end
  if options[:output].nil?
    abort "--output is required when using --input-file."
  end
  output_path = options[:output]
  Tempfile.create(%w[original .srt], '/tmp') do |original_srt|
    extract_subtitles options[:input_file], original_srt, options[:stream]
    translator ||= SubtitleTranslator.new(options[:language])
    translator.translate(original_srt, output_path)
  end
  exit 0
end

# process folder mode
folder = options[:input_folder]
unless Dir.exist?(folder)
  abort "Input folder not found: #{folder}"
end

# Determine output directory
output_dir = options[:output] && !options[:output].empty? ? options[:output] : folder
FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)

# Collect MKV files in the folder (non-recursive)
video_files = Dir.glob(File.join(folder, '*.{mkv,MKV}')).uniq
if video_files.empty?
  puts "No MKV files found in folder: #{folder}"
  exit 0
end

translator ||= SubtitleTranslator.new(options[:language])
video_files.each do |video_path|
  base = File.basename(video_path, File.extname(video_path))
  output_srt = File.join(output_dir, base + '.' + options[:language] + '.srt')
  Tempfile.create(%w[original .srt], '/tmp') do |original_srt|
    extract_subtitles video_path, original_srt, options[:stream]
    SubtitleTranslator.new(options[:language]).translate(original_srt, output_srt)
  end
end

puts "Done. Translated #{video_files.size} file(s)."
