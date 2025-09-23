#!/usr/bin/env ruby

require 'cgi'
require 'open3'
require 'google/cloud/translate/v2'
require 'optparse'
require 'tempfile'
require 'fileutils'

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

# translate subtitles using Google Translate API
def translate_subtitles(input_srt, output_srt, target_language)
  translate = Google::Cloud::Translate::V2.new
  translated_lines = []
  translation_count = 0
  cache_hit_count = 0
  @translations_cache ||= {}

  input_srt.each_line do |line|
    # "unescape" HTML entities like &amp;
    line = CGI.unescapeHTML line.strip

    if line =~ /^\d/ || line !~ /[A-Za-z]+/
      translated_lines << line
    elsif @translations_cache.key? line
      translated_lines << @translations_cache[line]
      cache_hit_count += 1
    else
      # Translate the subtitle line
      puts "Translating: #{line}"
      translated_text = translate.translate line, to: target_language
      translation_count += 1
      translated_lines << translated_text.text + "\n"
      @translations_cache[line] = translated_text.text
    end
  end

  # Save the translated subtitles
  File.open(output_srt, 'w') do |file|
    translated_lines.each { |line| file.write(line) }
  end

  puts "Translated subtitles saved to #{output_srt}. Made #{translation_count} API calls. #{cache_hit_count} cache hits."
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
if options[:input_srt]
  unless File.file?(options[:input_srt])
    abort "Input SRT file not found: #{options[:input_srt]}"
  end
  if options[:output].nil?
    abort "--output is required when using --input-srt."
  end
  File.open(options[:input_srt], 'r') do |srt|
    translate_subtitles srt, options[:output], options[:language]
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
    translate_subtitles original_srt, output_path, options[:language]
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

video_files.each do |video_path|
  base = File.basename(video_path, File.extname(video_path))
  output_srt = File.join(output_dir, base + '.' + options[:language] + '.srt')
  Tempfile.create(%w[original .srt], '/tmp') do |original_srt|
    extract_subtitles video_path, original_srt, options[:stream]
    translate_subtitles original_srt, output_srt, options[:language]
  end
end

puts "Done. Translated #{video_files.size} file(s)."