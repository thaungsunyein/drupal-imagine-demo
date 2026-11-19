<?php

declare(strict_types=1);

namespace Drupal\imagine_migrate\Plugin\migrate\source;

use Drupal\migrate\Attribute\MigrateSource;
use Drupal\migrate\MigrateException;
use Drupal\migrate\Plugin\MigrationInterface;

/**
 * One row per media file that exists on disk.
 *
 * Configuration:
 * - kind: 'narration' (narration/<n>.mp3 per chapter, every language),
 *   'scene' (scenes/<n>-<k>.webp, only books with their own artwork) or
 *   'cover' (cover.webp, every book).
 *
 * Missing files produce no row, so a chapter without narration simply ends
 * up with an empty narration field.
 *
 * The annotation is kept for Drupal 10, which has no MigrateSource attribute.
 *
 * @MigrateSource(
 *   id = "imagine_asset",
 *   source_module = "imagine_migrate"
 * )
 */
#[MigrateSource(id: 'imagine_asset')]
final class ImagineAsset extends ImagineSourceBase {

  private const KINDS = ['narration', 'scene', 'cover'];

  /**
   * {@inheritdoc}
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, MigrationInterface $migration) {
    if (!in_array($configuration['kind'] ?? NULL, self::KINDS, TRUE)) {
      throw new MigrateException(sprintf('imagine_asset: "kind" must be one of %s.', implode(', ', self::KINDS)));
    }
    parent::__construct($configuration, $plugin_id, $plugin_definition, $migration);
  }

  /**
   * {@inheritdoc}
   */
  protected function initializeIterator(): \Iterator {
    $imagine = $this->imagine();
    $rows = [];
    foreach ($this->selectedBooks() as $bookId => $bible) {
      $candidates = match ($this->configuration['kind']) {
        'cover' => [['cover.webp', NULL]],
        'narration' => array_map(
          fn(array $chapter) => ['narration/' . $chapter['index'] . '.mp3', $chapter['index']],
          $imagine->chapters($bookId),
        ),
        // Translations borrow the original's artwork, so only books without
        // 'artworkFrom' have scene files of their own.
        'scene' => isset($bible['artworkFrom']) ? [] : array_map(
          fn(array $scene) => [$scene['relative'], $scene['chapter']],
          $imagine->scenes($bookId),
        ),
      };
      foreach ($candidates as [$relative, $chapterIndex]) {
        $path = $imagine->assetPath($bookId, $relative);
        if ($path === NULL) {
          continue;
        }
        $rows[] = [
          'asset_id' => $bookId . '/' . $relative,
          'path' => $path,
          'filename' => basename($path),
          'book_id' => $bookId,
          'chapter_index' => $chapterIndex,
          'language' => $bible['language'],
        ];
      }
    }
    return new \ArrayIterator($rows);
  }

  /**
   * {@inheritdoc}
   */
  public function fields(): array {
    return [
      'asset_id' => $this->t('Path relative to classics/, e.g. alice-in-wonderland/scenes/1-0.webp'),
      'path' => $this->t('Absolute path on disk'),
      'filename' => $this->t('File name'),
      'book_id' => $this->t('Book id'),
      'chapter_index' => $this->t('Chapter number, or NULL for covers'),
      'language' => $this->t('Language of the book'),
    ];
  }

  /**
   * {@inheritdoc}
   */
  public function getIds(): array {
    return ['asset_id' => ['type' => 'string']];
  }

}
