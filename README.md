# ruby-translate-subtitles

ruby script that takes a video file with subtitles, extracts the subtitles, translates it to another language + saves the translated subtitles

## How to use

1. Clone this repo
1. Create a [Google Cloud account](https://cloud.google.com/cloud-console?hl=en). Then make a new project, download API credentials, add a billing method, and activate the Cloud Translation API.
1. Set a local environment variable `GOOGLE_CLOUD_KEY` with your Google Cloud API key.
1. Set a local environment variable `GOOGLE_CLOUD_PROJECT` with your Google Cloud project name.
1. Run the script

Single file:
```
./translate.rb --input-file input_video.mkv --output translated_subtitles.srt --language es --stream 0:s:0
```

Folder (all .mkv files in a folder):
```
./translate.rb --input-folder /path/to/folder --output /path/to/output_folder --language es --stream 0:s:0
```

Options:

  `--input-file`: Path to a single `.mkv` video file.
  
  `--input-folder`: Path to a folder containing `.mkv` files to process. All `.mkv` files in that folder (non-recursive) will be translated.
  
  `--output`: For `--input-file`, path to save the translated `.srt` file (containing the translated subtitles). For `--input-folder`, optional path to an output directory. If omitted, `.srt` files are written next to their source videos.
  
  `--stream`: which stream to use as source language (for example '0:s:0' for first subtitle track. see "Format of the stream argument" section below) 
  
  `--language`: target language for the translation (for example 'es' for Spanish)

Note: The previous `--input` option has been replaced by `--input-file` and `--input-folder`.

### Format of the stream argument

The value you send here determines which subtitles are used as the source content.
Ultimately, it gets passed to `ffmpeg` in the `-map` arg.
ffmpeg requires the value to be in this format:

```
input_index:stream_type:stream_index
```

* `input_index` refers to which input file since ffmpeg allows multiple. this should be 0 when translating one video.
* `stream_type` is always `s`. it refers to the subtitle stream type.
* `stream_index` refers to which subtitle track we want to use as the source content, starting at 0 for the first track.

See [ffmpeg docs](https://trac.ffmpeg.org/wiki/Map) for more.