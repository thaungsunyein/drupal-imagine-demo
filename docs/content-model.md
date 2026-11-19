# Content model

All of this is configuration in `config/sync/`, exported with `drush cex`. A fresh site gets it with `drush cim`, so nothing here is built by hand on the server.

Languages: English (default), French, German. Books, chapters, audio and image media are translatable. Fields marked **shared** are untranslatable: every language version of a node points at the same value. They hold facts about the book (which book, which position, which pictures), not words.

## Book (`node.book`)

One node per edition, so *Alice's Adventures in Wonderland* is the English original with French and German translations of the same node.

| Field | Type | Notes |
|---|---|---|
| `title` | Title | Translated title, e.g. *Alice au pays des merveilles* |
| `field_author` | Plain text | |
| `field_first_published` | Integer | Year |
| `field_translator` | Plain text | Empty on the original |
| `field_source_edition` | Plain text, long | Public-domain edition the text comes from |
| `field_source_url` | Link (external) | e.g. Project Gutenberg |
| `field_description` | Formatted text, long | |
| `field_cover` | Media reference → Image | |
| `field_sdg_targets` | Term reference → SDG, unlimited | **Shared.** Imagine is tagged 4.6 and 17.17 |

## Chapter (`node.chapter`)

| Field | Type | Notes |
|---|---|---|
| `title` | Title, labelled "Editorial title" | |
| `field_book` | Content reference → Book | **Shared** |
| `field_index` | Integer | **Shared.** 1–12; with `field_book`, the chapter's identity |
| `field_source_ref` | Plain text | Chapter reference in the source edition |
| `field_synopsis` | Formatted text, long | |
| `field_mood` | Plain text | |
| `field_act` | Plain text | |
| `body` | Formatted text with summary | Chapter text, `basic_html` |
| `field_narration` | Media reference → Audio | Per language: each language has its own narration |
| `field_scenes` | Media reference → Image, unlimited | **Shared.** French and German reuse the English illustrations |

## SDG (`taxonomy_term.sdg`)

Hierarchical: goals at the top, targets underneath. Imported from the UN SDG API (`unstats.un.org/SDGAPI`).

| Field | Type | Notes |
|---|---|---|
| `name` | Term name | Goal or target title |
| `field_sdg_code` | Plain text | `4`, `4.6`, `17.17` |

## Media

Core's **Audio** (`field_media_audio_file`) and **Image** (`field_media_image`) types, unchanged. Narration MP3s become audio media; covers and scene illustrations become image media.
