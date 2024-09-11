#!/usr/bin/env ruby

require 'open3'
require 'google/cloud/translate/v2'
require 'optparse'
require 'tempfile'

# usage: ./translate.rb --input input_video.mkv --output translated_subtitles.srt --language es --stream 0:s:0
#
#   --input: Path to the .mkv video file.
#   --output: Path to save the translated .srt file (containing the translated subtitles)
#   --stream: which stream to use as source language (for example '0:s:0' for first subtitle track)
#   --language: target language for the translation (for example 'es' for Spanish)

# extract the first subtitle track from an MKV video
def extract_subtitles(video_path, output_srt, stream)
  puts "extracting subtitles from #{video_path} to #{output_srt.path}"
  command = "ffmpeg -i #{video_path} -map #{stream} #{output_srt.path}"
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
  input_srt.each_line do |line|
    if line.strip =~ /^\d/ || line.strip !~ /[A-Za-z]+/
      translated_lines << line
    else
      # Translate the subtitle line
      puts "Translating: #{line.strip}"
      translated_text = translate.translate(line.strip, to: target_language)
      translation_count += 1
      translated_lines << translated_text.text + "\n"
    end
  end

  # Save the translated subtitles
  File.open(output_srt, 'w') do |file|
    translated_lines.each { |line| file.write(line) }
  end

  puts "Translated subtitles saved to #{output_srt}. Made #{translation_count} API calls."
end

# gather the CLI options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ./translate.rb [options]"

  opts.on("-i", "--input INPUT", "Path to the input MKV video file") do |v|
    options[:input] = v
  end

  opts.on("-o", "--output OUTPUT", "Path to save the translated SRT file") do |t|
    options[:output] = t
  end

  opts.on("-l", "--language LANGUAGE", "Target language for translation (for example 'es' for Spanish)") do |l|
    options[:language] = l
  end

  # see https://trac.ffmpeg.org/wiki/Map for details on what "0:s:0" implies
  opts.on("-s", "--stream STREAM", "Which subtitle stream to use (for example '0:s:0')") do |s|
    options[:stream] = s
  end
end.parse!

# extract and translate subtitles
Tempfile.create(%w[original .srt], '/tmp') do |original_srt|
  extract_subtitles options[:input], original_srt, options[:stream]
  translate_subtitles original_srt, options[:output], options[:language]
end