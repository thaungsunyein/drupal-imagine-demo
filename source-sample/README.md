# Imagine content sample

A small slice of the Imagine content folder, so the migrations run on a fresh
clone without the full media set: the English *Alice's Adventures in
Wonderland* (public domain), chapter 1 only, with its narration, two scene
images and the cover. Same layout as the full folder:

- `classics/<book>/bible.json`, `cover.webp`, `narration/<n>.mp3`, `scenes/<n>-<k>.webp`
- `text/<book>.json`

Docker Compose mounts this folder by default (`IMAGINE_SOURCE=./source-sample`).
Point `IMAGINE_SOURCE` in `.env` at the full content folder to import all 12
chapters in English, French and German.
