<?php

declare(strict_types=1);

namespace Drupal\imagine_migrate;

/**
 * Reads the Imagine content folder.
 *
 * Layout (same as the Imagine app's content/ directory):
 * - classics/<book>/bible.json   book metadata and one section per chapter
 * - classics/<book>/cover.webp
 * - classics/<book>/narration/<n>.mp3
 * - classics/<book>/scenes/<n>-<k>.webp   only on books with their own artwork
 * - text/<book>.json             chapter text as paragraphs.
 *
 * This class knows the file layout; the source plugins only shape rows.
 */
final class ImagineSource {

  /**
   * Decoded bibles keyed by book id, loaded once.
   *
   * @var array<string, array>|null
   */
  private ?array $books = NULL;

  public function __construct(private readonly string $dir) {}

  /**
   * Returns every book's decoded bible.json.
   *
   * @return array<string, array>
   *   Bibles keyed by book id.
   */
  public function books(): array {
    if ($this->books === NULL) {
      $this->books = [];
      foreach (glob($this->dir . '/classics/*/bible.json') ?: [] as $file) {
        $bible = $this->readJson($file);
        if (isset($bible['id'])) {
          $this->books[$bible['id']] = $bible;
        }
      }
      ksort($this->books);
    }
    return $this->books;
  }

  /**
   * Returns a book's chapters: bible section joined with its text.
   *
   * @return list<array{index: int, section: array, text: array|null}>
   *   One entry per chapter section, in bible order. 'text' is NULL when the
   *   text file has no chapter with that index.
   */
  public function chapters(string $bookId): array {
    $bible = $this->books()[$bookId] ?? NULL;
    if ($bible === NULL) {
      return [];
    }

    $texts = [];
    $textFile = $this->dir . '/text/' . $bookId . '.json';
    if (is_file($textFile)) {
      foreach ($this->readJson($textFile)['chapters'] ?? [] as $chapter) {
        $texts[(int) $chapter['index']] = $chapter;
      }
    }

    $chapters = [];
    foreach ($bible['sections'] ?? [] as $section) {
      if (($section['kind'] ?? 'chapter') !== 'chapter') {
        continue;
      }
      $index = (int) $section['index'];
      $chapters[] = [
        'index' => $index,
        'section' => $section,
        'text' => $texts[$index] ?? NULL,
      ];
    }
    return $chapters;
  }

  /**
   * Returns the absolute path of a book's file, or NULL if it is missing.
   *
   * @param string $bookId
   *   The book id, e.g. 'alice-in-wonderland'.
   * @param string $relative
   *   Path inside the book folder, e.g. 'narration/1.mp3'.
   */
  public function assetPath(string $bookId, string $relative): ?string {
    $path = $this->dir . '/classics/' . $bookId . '/' . $relative;
    return is_file($path) ? $path : NULL;
  }

  /**
   * Returns the book whose artwork this book uses.
   *
   * Translations set 'artworkFrom' to the original; originals use their own.
   */
  public function artworkBook(string $bookId): string {
    return $this->books()[$bookId]['artworkFrom'] ?? $bookId;
  }

  /**
   * Lists a book's own scene images in chapter, then position, order.
   *
   * @return list<array{relative: string, chapter: int, position: int}>
   *   'relative' is the path inside the book folder, e.g. 'scenes/1-0.webp'.
   */
  public function scenes(string $bookId): array {
    $scenes = [];
    foreach (glob($this->dir . '/classics/' . $bookId . '/scenes/*.webp') ?: [] as $file) {
      if (preg_match('/^(\d+)-(\d+)\.webp$/', basename($file), $m)) {
        $scenes[] = [
          'relative' => 'scenes/' . basename($file),
          'chapter' => (int) $m[1],
          'position' => (int) $m[2],
        ];
      }
    }
    usort($scenes, fn(array $a, array $b) => [$a['chapter'], $a['position']] <=> [$b['chapter'], $b['position']]);
    return $scenes;
  }

  /**
   * Decodes a JSON file, failing loudly on broken JSON.
   */
  private function readJson(string $file): array {
    return json_decode((string) file_get_contents($file), TRUE, 512, JSON_THROW_ON_ERROR);
  }

}
