# ruby-translate-subtitles

ruby script that takes a video file with subtitles, extracts the subtitles, translates it to another language + saves the translated subtitles

⚠️ **Dependency**: `ffmpeg` is required for extracting subtitles from video sources; install it with `brew install ffmpeg` before running the script.

## Translation services

Translation happens through either OpenAI (default) or Google Cloud Translate. The script chooses the provider by inspecting your environment:

- Set `OPENAI_API_KEY` to use the OpenAI API by default.
- If you prefer Google Cloud, also set `GOOGLE_CLOUD_KEY` and `GOOGLE_CLOUD_PROJECT`; the tool will fall back to Google when OpenAI credentials are missing.
- You can force the provider by setting `TRANSLATION_SERVICE=openai` or `TRANSLATION_SERVICE=google`, but the mapped credentials must still be available.

If neither credential set is present, the script aborts with an error indicating the missing variables.

Subtitles are translated in batches rather than with one API request per line. Each line is tagged while it is translated, so the original subtitle cue numbers and timestamps are copied back unchanged. The default batch size is 6,000 characters; set `TRANSLATION_BATCH_SIZE` to adjust it if a provider has a smaller or larger request limit.

## How to use

1. Clone this repo
1. Make sure you have the desired translation provider credentials configured in your environment (see the "Translation services" section above).
1. Run the script

Single video file:
```
./translate.rb --input-file input_video.mkv --output translated_subtitles.srt --language es --stream 0:s:0
```

Single SRT file (no video, no ffmpeg extraction):
```
./translate.rb --input-srt input_subtitles.srt --output translated_subtitles.srt --language es
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
