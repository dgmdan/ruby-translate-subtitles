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
    @openai_model = ENV['OPENAI_MODEL'] || 'gpt-3.5-turbo'
    @openai_temperature = (ENV['OPENAI_TEMPERATURE'] || '0.1').to_f
    @client = build_client
    puts "Using #{@service_name.to_s.capitalize} for translation."
  end

  def translate(input_io, output_path)
    translated_lines = []

    input_io.each_line do |raw_line|
      line = normalize_line(raw_line)

      if line =~ /^\d/ || line !~ /[A-Za-z]+/
        translated_lines << line + "\n"
      elsif @cache.key?(line)
        translated_lines << @cache[line] + "\n"
        @cache_hit_count += 1
      else
        puts "Translating: #{line}"
        translated_text = translate_line(line)
        @translation_count += 1
        translated_lines << translated_text + "\n"
        @cache[line] = translated_text
      end
    end

    File.open(output_path, 'w:UTF-8') do |file|
      translated_lines.each { |line| file.write(line) }
    end

    puts "Translated subtitles saved to #{output_path}. Made #{@translation_count} API calls. #{@cache_hit_count} cache hits."
  end

  private

  def normalize_line(raw_line)
    line = raw_line.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').chomp
    CGI.unescapeHTML(line)
  end

  def translate_line(line)
    case @service_name
    when :openai
      translate_with_openai(line)
    when :google
      translate_with_google(line)
    else
      raise "Unsupported translation service: #{@service_name}"
    end
  end

  def translate_with_openai(line)
    messages = [
      { role: "system", content: "You are a concise translator." },
      { role: "user", content: "Translate the following text into #{@target_language}: #{line}" }
    ]

    response = openai_chat_completion(messages)
    response.dig("choices", 0, "message", "content")&.strip || ''
  rescue StandardError => e
    abort "OpenAI translation error: #{e.message}"
  end

  def translate_with_google(line)
    translation = @client.translate line, to: @target_language
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
      max_tokens: 1024,
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
video_files = Dir.glob(File.join(folder, '*.{mkv,MKV}'))
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
