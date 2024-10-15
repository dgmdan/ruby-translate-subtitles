# ruby-translate-subtitles

ruby script that takes a video file with subtitles, extracts the subtitles, translates it to another language + saves the translated subtitles

## How to use

1. Clone this repo
1. Create a [Google Cloud account](https://cloud.google.com/cloud-console?hl=en). Then make a new project, download API credentials, add a billing method, and activate the Cloud Translation API.
1. Set a local environment variable `GOOGLE_CLOUD_KEY` with your Google Cloud API key.
1. Set a local environment variable `GOOGLE_CLOUD_PROJECT` with your Google Cloud project name.
1. Run the script:
```
./translate.rb --input input_video.mkv --output translated_subtitles.srt --language es --stream 0:s:0
```

  `--input`: Path to the .mkv video file.
  
  `--output`: Path to save the translated .srt file (containing the translated subtitles)
  
  `--stream`: which stream to use as source language (for example '0:s:0' for first subtitle track)
  
  `--language`: target language for the translation (for example 'es' for Spanish)
